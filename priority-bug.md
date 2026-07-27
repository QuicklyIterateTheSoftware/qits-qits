# Priority bug: two active workspaces can own the same branch

Status: **fixed, surrogate key externalised, daemon control plane rekeyed.**
Written and resolved 2026-07-27. Repo: `services/qits-workspaces`, uncommitted on `main`. Found
while writing [`migration-path-conventions.md`](migration-path-conventions.md) §1.

**What landed is recorded in [§ Resolution](#resolution) at the bottom.** Everything above it is the
original analysis, unedited — the defect it describes is no longer present.

## The invariant the code states

`WorkspaceService.createWorkspace` says it outright:

```java
// `parent` is the branch to fork from; `branch` is the new branch the workspace owns.
// Each workspace gets its own branch so two workspaces never commit to the same branch.
```

That is the real invariant. A workspace *is* a branch ref plus a container that clones it, so two
active workspaces on one branch means two containers with two checkouts committing and auto-pushing
to the same ref.

## What is actually enforced

Uniqueness is checked on the **workspace id**, which is a label, not the resource:

```java
// WorkspaceService.createWorkspace
if (workspaceRepository.existsActiveByRepositoryAndWorkspaceId(repoId, workspaceId)) {
  throw new BadRequestException("Workspace already exists: " + workspaceId);
}
```

```java
// WorkspaceRepository:32
count("repositoryId = ?1 and workspaceId = ?2 and status = ?3", repositoryId, workspaceId, ACTIVE)
```

**The id is not the branch.** They are separate fields, and the branch only *defaults* to the id:

```java
String newBranch = (branch == null || branch.isBlank()) ? workspaceId : branch;
```

Both are independently settable through the public API — `CreateWorkspaceRequest(String id, String
parent, String branch, String preamble, boolean adoptExisting)`.

**Nothing anywhere checks the branch.** `WorkspaceRepository` has exactly four public methods —
`findActiveByRepositoryAndWorkspaceId`, `findActiveByRepositoryId`,
`existsActiveByRepositoryAndWorkspaceId`, `findByRepositoryId` — and not one of them filters on
`branch`. There is no DB constraint either. The `workspace` table has **no unique constraint of any
kind**, and `V1__init.sql`'s own comment records why: V10 *dropped* the only one there ever was (on
`(repository_id, workspace_id)`), because soft-deleted rows accumulate and would collide with a live
one. Grepping the lineage for `unique` does return a hit — `UQ_workspace_bootstrap_run
(workspace_id_fk, bootstrap_command_id)` in `V2` — but that is a different table and unrelated.

The branch invariant is upheld only **indirectly and incidentally**, by git refusing to create a ref
that already exists:

```java
git.exec(originPath.toFile(), "git", "branch", "--end-of-options", branch, parentBranch);
```

## How to violate it, through the public API

`adoptExisting` skips exactly that ref creation:

```java
if (!(adoptExisting && branchExistsOnOrigin(originPath, newBranch))) {
  createBranchRefOnOrigin(originPath, newBranch, parentBranch);
}
```

So two calls do it:

```http
POST /api/repositories/{repoId}/workspaces
{ "id": "alpha", "branch": "feature/x" }
→ creates ref feature/x, workspace alpha ACTIVE on feature/x

POST /api/repositories/{repoId}/workspaces
{ "id": "beta", "branch": "feature/x", "adoptExisting": true }
→ ref exists, so creation is skipped; workspace beta ACTIVE on feature/x
```

Both rows are `ACTIVE`, in the same repository, on the same branch. The id guard passes because
`alpha != beta`. Nothing else looks.

`adoptExisting` is not an internal flag — `WorkspaceController.create` passes
`request.adoptExisting()` straight from the request body. Its documented purpose is legitimate
("adopt a branch pushed or created outside qits"); the defect is that it is the only thing standing
between the caller and a duplicate, and it was never meant to carry that weight.

## Why it matters

Each workspace gets its own container cloning its branch, and the daemon **auto-pushes committed
work per commit within ~500 ms** (`migration-plan.md` §3.3). Two workspaces on one branch means two
independent checkouts pushing to the same ref: interleaved history, non-fast-forward rejections, and
work that looks committed locally but never lands. The host-side gates that would normally catch
trouble — `isWorkspaceClean`, `isFullyPushed` — are evaluated **per workspace**, so each one
independently believes it is fine.

It also silently breaks the assumption behind branch-scoped operations: `cleanupBranch(repoId,
branch)` and `POST /branches/merge` take a *branch*, not a workspace id, and cannot tell which of the
two owners they are acting for.

## The specified behaviour

Stated so the fix is not re-derived from the symptom. **Two invariants were conflated into one
check, and only the wrong one survived.**

1. **At most one ACTIVE workspace per `(repositoryId, branch)`.** This is the business rule. A
   workspace *is* a branch plus a container that clones it, so the branch is the resource being
   claimed. Nothing else about a workspace is exclusive.
2. **`workspaceId` is a surrogate key — a technical detail.** It exists so a row can be selected,
   addressed and referenced. It carries no business meaning, and "unique" is its entire
   specification. It is *not* a second identity to be reconciled with the branch, and pairing it
   with `repositoryId` to identify a row is redundant: a unique id is already unique.

The current code has exactly one uniqueness check and it enforces neither rule properly — it guards
the surrogate, scoped by repository, which is the weakest reading of both.

**Why this is latent rather than live.** In practice `workspaceId` *is* the branch name today.
`createMainWorkspace` sets it with `toWorkspaceSlug(branch)`, and every ordinary create leaves
`branch` blank so it defaults to the id. Under that usage, guarding the id and guarding the branch
happen to coincide — so the check looks correct and is passing tests. It stops coinciding the moment
a caller sets `branch` and `id` independently, which the API allows and the reproduction above does.
The defect is in the model, and the identical values are the disguise.

## The fix

**Enforce the branch rule**, after `newBranch` is resolved from `branch`/`workspaceId` — not before:

```java
if (workspaceRepository.existsActiveByRepositoryAndBranch(repoId, newBranch)) {
  throw new BadRequestException("Branch already has an active workspace: " + newBranch);
}
```

`WorkspaceRepository` needs the finder; it currently has no branch-aware method at all.

**Use the surrogate key that already exists.** No new id needs generating — `Workspace` has had one
since V1:

```java
@Id @GeneratedValue public Long id;                    // Workspace.java:32
@Column(name = "workspace_id", nullable = false)
public String workspaceId;                             // the branch-derived label
```

**The `Long` is already the durable identity everywhere it matters.** `workspace_event`,
`workspace_bootstrap_run` and `workspace_prompt_draft` all FK to `workspace(id)` with
`on delete cascade`. And one port already keys on it *for precisely this reason*:

```java
/**
 * Commands that ran in the workspace with this surrogate row id, oldest first. Keyed by the row
 * id rather than {@code workspaceId} because the latter is reusable once a workspace resolves.
 */
List<WorkspaceCommandDto> commandsFor(Long workspaceRowId);   // WorkspaceCommandHistory:22
```

That javadoc is this bug's diagnosis, written down before anyone noticed it was one. The string id is
**explicitly documented as reusable**; it was never an identifier.

So the change is to *externalise* `Workspace.id` rather than invent anything: it becomes the public
identifier in routes, the daemon control socket, and any port that names a workspace. The string
`workspaceId` stops being an identity and becomes at most a display label — the branch already
carries the human meaning, and the UI's use of it is being removed separately.

What this settles for free:

- `findActiveByRepositoryAndWorkspaceId` no longer needs the repository to disambiguate.
- The daemon control socket's `clients.put(workspaceId, …)` becomes correct rather than
  accidentally-usually-correct (second related finding below).
- Workspace paths lose their repository segment —
  [`migration-path-conventions.md`](migration-path-conventions.md) assumes this.
- `migration-plan.md` §9 item 17's complaint that `WorkspaceCommandHistory` "is keyed on `Long
  workspaceRowId`, which the daemon does not have" dissolves: once the `Long` is the public id, the
  daemon is given it like any other caller.

Consequences that still need handling, because the string is load-bearing in non-obvious places:

- **`service_event.workspace_id` is a deliberate exception** and should stay one. Its V2 header:
  *"the workspace's string id, not the workspace table's surrogate key, so an event outlives the row
  and there is no FK: this feed is diagnostic history."* Do not FK it to the `Long` as part of this.
- **On-disk paths and container names.** `workspaceId` "becomes a path segment under the repo's
  workspaces dir" — which is why it is slug-validated — and `containerName(workspaceId, repoId)`
  builds a readable container name. Both can keep using the label; neither needs to be the identity.
  Decide deliberately rather than by accident.
- **`WorkspaceService.toWorkspaceSlug` is public** so the capture ingest can *predict* the id it is
  about to create (`CaptureService:57`). That call site should take the created workspace's `id`
  from the return value instead.

**Back it with a DB constraint.** A partial unique index on `(repository_id, branch) WHERE status =
'ACTIVE'` makes the rule structural instead of a service-layer check that the next caller can route
around — which is exactly how this defect arose. Confirm filtered-index support in the H2 version in
use before relying on it. Extend the lineage, never renumber (`AGENTS.md`).

**Check for existing violations first.** A migration adding either constraint fails on data that
already breaks it. Duplicate active workspaces per branch are unlikely given the latency described
above, but duplicate *ids across repositories* are near-certain — every repository tends to have a
workspace called `main`.

## Two related findings, deliberately not folded in

- **`createBranchRefOnOrigin` reports a client error as a server error.** A branch that already
  exists throws `InternalServerErrorException("Failed to create branch: …")` — a 500 where 409 or
  400 is right. This is the *normal*-path guard for the very invariant above, so its status code is
  worth fixing in the same pass, but it is a separate defect.
- **`workspaceId` is not globally unique, and the daemon control socket may assume it is.**
  `DaemonControlSocket` is `@WebSocket(path = "/api/workspace-daemon/{workspaceId}")` and
  `WorkspaceDaemonRegistry:186` does `clients.put(workspaceId, connection)` — keyed on that string
  alone, with no repository component. Since `createMainWorkspace` derives the id from the main
  branch name (falling back to the literal `"main"`), every repository tends to have a workspace
  called `main`. **This needs tracing before it is called a bug** — I have not checked whether
  registration is scoped upstream — but it is a different defect from the one above and should be
  its own investigation. Container naming already handles the collision
  (`WorkspaceContainerFactory.containerName(workspaceId, repoId)` carries a repo prefix), which
  suggests the registry simply was not revisited.

## Confirmed by a failing test

`domain/src/test/java/eu/wohlben/qits/workspaces/control/TwoActiveWorkspacesOneBranchTest.java`
reproduces it against the real `WorkspaceService`, using the repo's own idiom (`TestOrigin.create`
plus `FakeRepositoryLookup.register`). It is **red on purpose** — it asserts the invariant, not the
current behaviour, so it turns green when the fix lands:

```
two ACTIVE workspaces own branch feature-x: [alpha, beta] ==> expected: <1> but was: <2>
```

Two `createWorkspace` calls, distinct ids, same branch, the second with `adoptExisting = true`. The
id-uniqueness guard passes correctly throughout — `alpha != beta` — which is the point: it is
answering the right question about the wrong field.

The test lives in the `branches-merge-cleanup` worktree and is **not yet committed**; land it first
if you want the red-then-green sequence.

Everything else here is quoted from source and re-verified: the guard, `WorkspaceRepository`'s
complete method list (four methods, none branch-aware), the absence of any unique constraint on the
`workspace` table, the `adoptExisting` bypass, and the controller passing it from the request body.

---

## Resolution

All of it in `services/qits-workspaces`, uncommitted on `main`. `mvn verify` green from a clone of
itself alone.

### The invariant

`WorkspaceRepository` gained the branch-aware finders it had none of
(`findActiveByRepositoryAndBranch`, `existsActiveByRepositoryAndBranch`), and `createWorkspace`
checks the branch **after** `newBranch` is resolved from `branch`/`workspaceId` — the placement was
the whole point, since before that line the two fields have not yet been reconciled. A second claim
is now a `ConflictException` (409), not a silent second row.

`createMainWorkspace` was changed too, and this was not in the original plan: its idempotency keyed
on the *derived id*, so a workspace that merely slugged to the same name while owning a different
branch was returned in the main workspace's place. It keys on the branch now — the resource, not the
label.

`createBranchRefOnOrigin`'s 500 became a 409 (the first of the two related findings), by checking
for the ref up front rather than inferring it from git's exit status, which cannot tell "ref exists"
from a broken origin. A genuinely broken origin still 500s.

### The constraint

`V3__one_active_workspace_per_branch.sql`. **The filtered index the plan called for does not exist
in H2** — `create unique index … where …` is a syntax error in 2.4.240, the only target. Verified
against the actual jar rather than assumed, along with the alternative: a `generated always`
`active_branch` column that is the branch for an ACTIVE row and NULL otherwise, with a plain unique
index over `(repository_id, active_branch)`. A unique index ignores NULLs, so resolved rows drop out
of the constraint exactly as the predicate would have dropped them — which is precisely the property
whose absence forced V10 to drop V1's constraint on `(repository_id, workspace_id)`.

Confirmed empirically, not by reasoning: it rejects two ACTIVE rows on one branch; it admits
resolved rows accumulating on that branch, the same branch name in another repository, duplicate
`workspace_id` values across repositories (near-certain in existing data, and untouched by this),
and NULL branches from before V20; and resolving a workspace frees its branch.

The constraint is a real backstop, not decoration: with the service-layer guard temporarily disabled
the duplicate was rejected by the index instead.

### The surrogate key

`Workspace.id` is now the public identifier. Routes address `/api/workspaces/{id}`, with **no
repository segment** — collections take `?repositoryId=`, and create carries `repositoryId` in the
body (`migration-path-conventions.md` §4 item 3 offered a query parameter as the cheaper
alternative; the table's choice was taken). `WorkspaceHistoryController` lost its repository prefix
the same way. `WorkspaceDto` carries `id`. `WorkspaceResolver` resolves by id alone and still
*checks* the repository, which was never only a disambiguator.

Deliberately still keyed on the label, each for its own stated reason: `service_event.workspace_id`
(V2's header — diagnostic history that outlives the row), and container names and on-disk paths
(`containerName(workspaceId, repoId)`, the workspaces dir). The label keeps its ACTIVE-uniqueness
guard so those paths stay unambiguous; what it lost is the claim to be an identity.

`CaptureService` needed no change in the end: it derives a *label* from the branch it just
generated, which is legitimate, and `CaptureResource` already returned `workspace.id`.

### The daemon control plane

`DaemonControlSocket` is now `/api/workspace-daemon/id/{id}` and `WorkspaceDaemonRegistry`'s maps
are keyed `Long` — `clients.put(workspaceId, …)` is correct rather than accidentally-usually-correct.
The daemon still announces its own label in its `Hello`, and the registry keeps it only so events
and log lines read readably.

That pulled the daemon-facing ports along with it, which is the point: `WorkspaceGitStatus`,
`WorkspaceDaemonInfo`, `WorkspaceAgentActivity`, `WorkspaceDaemonLiveness`, `WorkspaceConfigReader`,
`WorkspaceServiceDriver`, `WorkspaceBootstrapDriver`, `WorkspaceDaemonProvisioner`,
`WorkspaceGitSync` and `WorkspaceProcessTracker` all name a workspace by its id. Two of them dropped
a `repoId` parameter entirely — `awaitBootstrap` and `awaitProvision` carried one whose javadoc
already admitted *"the socket-backed impl awaits by `workspaceId` alone and ignores it"*.

Three composite keys collapsed to the id, each of which existed only because the label was not
unique: `ServiceSupervisor.Key(repoId, workspaceId, serviceId)` → `(workspaceRowId, serviceId)`, the
bootstrap runner's in-flight key, and the SSE channel key. The container lifecycle events
(`WorkspaceContainerStarted`, `…Stopping`, `WorkspaceReadyForServices`) carry the row id beside the
label, following `WorkspaceResolved`, which already did.

`WorkspaceContainerFactory` injects the id-addressed `QITS_WORKSPACE_DAEMON_URL`, and the dev-server
proxy is `/service/{id}/{serviceId}/`.

**Running containers keep working.** A daemon learns its URL from env injected once at container
creation, so it keeps dialling whatever it was given until recreated.
`LegacyDaemonControlSocket` serves the old label path for exactly those, resolving the label and
**refusing when more than one active workspace carries it** — strictly better than the silent
collision the unqualified key used to produce, and a refusal names the fix (recreate the container).
It is marked for deletion once no container provisioned against the old URL can still be running.

Two framework facts turned up that the plan could not have known. **websockets-next requires
`@PathParam` parameters to be `String`** — it rejects the endpoint at *build* time, and the failure
arrives as an unloadable test class rather than a compile error, so the socket takes the id as text
and parses it. And the SSE routes needed `@Blocking` once subscribing meant a query (below).

The collision claim itself is still unproven — nobody traced whether registration was scoped
upstream — but it is now unprovable-and-harmless rather than unprovable-and-latent.

**One consequence is left alone:** `CaptureResource` builds an SPA deep link
(`/repositories/{repoId}/workspaces/{workspaceId}/wip`). That is a frontend route, not an API one,
and the SPA is not in this aggregate — it moves when the UI does.

### On the test

`TwoActiveWorkspacesOneBranchTest` was landed from the `branches-merge-cleanup` worktree and
rewritten: as written it asserted that both creates *succeed* and then counted the rows, which the
fix turns into a thrown exception rather than a passing assertion. It now asserts the rejection
directly and covers the cases the constraint has to keep legal (distinct branches, a resolved
workspace freeing its branch, the same branch in another repository, the 409 on an existing ref).
Verified red-then-green: with the new guard disabled, two of its five tests fail.

One pre-existing race surfaced. `ServiceSupervisorProjectionTest` stages its service config *after*
provisioning, while the lifecycle coupler's auto-start runs asynchronously off the provision — so
which of the two wins was a matter of timing, and the extra lookup this change adds was enough to
flip it. The fixture now waits for the service phase to settle before returning, rather than the
test relying on losing a race.

One genuine defect was introduced and caught by the suite: resolving the id inside
`WorkspaceEventsController` put a blocking query on the IO thread, since a `Multi`-returning method
is not dispatched to a worker. It answered 500 until the method was marked `@Blocking`. Recorded in
`AGENTS.md`, because it applies to any lookup added to an SSE route.
