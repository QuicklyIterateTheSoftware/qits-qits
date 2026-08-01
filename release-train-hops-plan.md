# The release train's hops: a release walks into its consumers, and rolls on

## Addendum, 2026-08-01: the hop is a release, so the endpoint is `/branches/release`

Both dependencies this plan waited on have shipped, and one of them renamed the hop's endpoint.
release-flow split its one action in two (release-flow-plan.md's 2026-08-01 addendum):
**release** = branch → `main`, versioned, the only door; **integrate** = branch → the branch's
*parent* branch, a plain merge that stamps nothing and publishes nothing. A maintenance hop merges
into `main` and must produce a version and a `SoftwareRelease` — so a hop is a **release**.

Amendments to the frozen contract, and nothing else in this plan moves:

- **Agent AE builds `POST /workspaces/api/branches/release?repositoryId=<repoId>`**
  `{branch, summary}` → `{version, commitSha, branch}` — not `/branches/integrate`. Same flow, same
  409 family, same summary validation, same ACTIVE-workspace resolution and source-branch deletion,
  same 404/400. It is the branch-keyed sibling of `/workspaces/{id}/release`, which is the endpoint
  it now resolves over.
- **Agent AF's maintenance step calls `/branches/release`**, and the step's own name and log wording
  should say "release", not "integrate" — the run log is the hop's receipt and the word is now load-
  bearing. `/branches/integrate` would be the *wrong* call: it targets the parent branch and 409s
  `RELEASE_REQUIRED` when that parent is `main`.
- The 409 family gained `reason` as a structural field, `RELEASE_REQUIRED` among the values, and the
  enum is declared in qits-workspaces' `docs/openapi.yml`. The "409 already integrated → success"
  rule keys on `reason: ALREADY_INTEGRATED`, not on message text.
- `SoftwareRelease` is **SHIPPED and observed live** (first event
  `1faa0164-7747-4cf9-9bb5-a996c0db6898`, payload
  `{"branch":"task/aj-release-proof","projectId":"…","repository":"qits-stt","version":"2026.801.55529"}`).
  The seed's field names and the "`repository` is the repo id string" / "never match on `branch`"
  readings this plan pinned are all confirmed by the wire.

Everything below is unchanged, including the workstream split (AD ∥ AE → AF → AG) and the rollback
hazard AF gates on; read `/branches/integrate` in the body as `/branches/release`.

---

The follow-up that closes the loop the last four features each built one arc of. A repository
releases (release-flow-plan.md's integrate), the release announces itself
(software-release-event-plan.md's `SoftwareRelease`), a consumer's event pipeline hears it
(ci-event-triggers-plan.md, SHIPPED) — and then, today, the train stops, because nothing turns the
consumer's bump into the consumer's *own* release. This plan builds the two hops that make it roll:
a **bump pipeline** that writes the released version into the consumer's manifest and force-pushes a
`maintenance/<upstream>` branch, and a **maintenance leg in the consumer's ordinary post-receive
pipeline** — a new **step-level branch filter** scopes the integrate step to those pushes — that
runs after the regular tests and, on green, calls integrate, which releases the consumer and
publishes the next `SoftwareRelease`.

Status: **SHIPPED AND OBSERVED (2026-08-01)** — all four workstreams landed and one full hop ran
live, end to end, in 67 seconds. AD qits-ci `6922da6`, AE qits-workspaces `416d814`, AF
qits-spa-home `2633238`, AG the run below.

The measured chain, in the order it happened (ids from the APIs):

    workspace 1651 ag-train-hop on qits-spa-ui-components, branch task/ag-train-hop
    release  → 2026.801.63140  dc2047f5c21995c4084174f7acee732136f2a9fd
    event    → SoftwareRelease 064158b0-837f-40aa-aa3c-d287d34f929e  06:31:40.546Z
               {"branch":"task/ag-train-hop","repository":"qits-spa-ui-components",
                "version":"2026.801.63140"}
    upstream CI run 2ba7eb5b (main@dc2047f5) SUCCESS
               → publish-if-absent put @qits/ui-components@2026.801.63140 in the registry;
                 dist-tags.latest moved 0.0.4 → 2026.801.63140 (the CalVer switchover, by design)
    bump run 32acd2b9 on qits-spa-home  EVENT / SoftwareRelease / triggerEventId 064158b0
               its BuildSuccessful 59934bf8 carries parentId 064158b0 (walked via ?parentId=)
               → force-pushed maintenance/qits-spa-ui-components at
                 0fe77803d3f8ceefd95ddc6a529b77daac48dd8c — exactly one commit over main,
                 bump(@qits/ui-components@2026.801.63140): follow the qits-spa-ui-components release
                 committed as qits release train <release-train@qits.local>;
                 all 720 lockfile `resolved` origins localhost:8081
    maintenance run 8c3081c9 — ONE run, TWO step rows:
               step 0 SUCCESS (the regular tests, unscoped)
               step 1 SUCCESS "released 2026.801.63247 as 421a70fe… from
                               maintenance/qits-spa-ui-components"
    qits-spa-home main tip 421a70feec267bdc35f335940e35f1cbff9af995
               release(2026.801.63247): bump(@qits/ui-components@2026.801.63140): follow the …
               parents 2633238c + 0fe77803, pin ^2026.801.63140, source branch deleted
    event    → SoftwareRelease f81ecac8-028a-4b11-adce-4634982265e7 (qits-spa-home, 2026.801.63247)
               ?parentId= is EMPTY and no run anywhere carries it as triggerEventId —
               the train stopped at the declared edge, structurally
    the filter observed in BOTH directions: on the ordinary main push that followed
               (run de530cb7) step 1 is SKIPPED with output `[step not bound to branch main]`

Causation came out as designed: **two chains, not one.** 064158b0 → 59934bf8 is the whole first
chain; the force-push is the boundary; the maintenance run and f81ecac8 are fresh roots. Recorded as
correct, not as a gap.

The second probe, by hand: a superseded hop (an unreachable sha force-pushed away while its run sat
QUEUED) was **discarded, no row** — qits-ci logged `Commit b834265d… is no longer reachable in
qits-spa-home — no CI run recorded`. Re-pushing the already-released bump commit gave the
409 path: run 922c51ea SUCCESS, step 1 `maintenance/qits-spa-ui-components is already released -
nothing to do`, `main` byte-identical. Note the 409 path leaves the branch in place (nothing was
released, so nothing was cleaned up); the next hop's force-push overwrites it.

**One contract doubt, found by that probe and reported rather than adjusted.** The maintenance step
takes its release summary from `git log -1 --format=%s`, and `/branches/release` caps `summary` at
100 characters. A `bump(…)` subject is ~83 and fits, but the *release* subject it composes into —
`release(2026.801.63247): bump(@qits/ui-components@2026.801.63140): follow the qits-spa-ui-components release`
— is **108**. The real train never re-reads its own release subject, so this is unreachable in the
designed flow; it bites only a maintenance branch cut from a release commit, which is what the probe
did, and it surfaces as a plain 400 constraint violation with no `reason` (the step prints it and
goes red, as its comment promises). The headroom arithmetic in "The commit convention" below
measured the bump subject and not the composition.

Status before today, kept for the record: DESIGN, SETTLED WITH REVISION (2026-07-31) — both ⚖
decisions were answered by the user;
the first came back as a counter-proposal (branch matching moves from the pipeline to the **step**)
and this document is revised to that shape throughout. Implementation stays deliberately queued
behind two things: **release-flow-plan.md's Z/AB/AC** (X and Y are on their mains — measured below
— Z's integrate endpoint is not) and the **`SoftwareRelease` event** (seeded, not implemented).
Everything here is designed against those plans' frozen contracts as written; what this plan
assumes from each is listed explicitly, because the assumptions are load-bearing.

The demonstration chain is one hop wide and honest about it: `qits-spa-ui-components` integrates →
`SoftwareRelease` → **qits-spa-home** bumps, pushes `maintenance/qits-spa-ui-components`, tests,
integrates, releases → `SoftwareRelease(qits-spa-home)` → the train stops, deliberately, at a named
edge of the real dependency graph (see "Loops and where the demo stops").

Execution is by Opus 5 subagents, one per workstream, letters continuing the platform sequence:
release-flow burned X–AC, so this plan starts at **AD**.

## What this plan assumes from the plans it rides on

**From release-flow-plan.md (workstreams X–AC, mid-flight):**

- `POST /workspaces/api/workspaces/{id}/integrate` `{summary}` → `{version, commitSha, branch}`,
  synchronous, with the 409 family (conflict + file list; "main moved, retry"; "already
  integrated"). **Workspace-keyed** — which is exactly the seam this plan has to widen; see the
  contract interaction below.
- The nine-step flow: repo lease, `merge-tree` preflight, detached worktree, `--no-ff --no-commit`
  merge, `YYYY.MMDD.HHMMSS` stamp, in-JVM bump, one two-parent commit
  `release(<version>): <summary>`, fast-forward push with `-o qits.release`, cleanup.
- `ProtectedRefHook` — **shipped and read, not assumed** (Agent X landed;
  `services/qits-artifacts/.../githost/ProtectedRefHook.java`): the guarded ref is exactly what
  `HEAD` points at, every other ref `continue`s past the loop untouched. **A force-push to
  `maintenance/*` passes with protection ON, no option, no token** — creates, updates,
  non-fast-forwards and deletes of non-default refs are simply not the hook's business. The
  maintenance branch mechanism rests on that measured fact.
- Agent Y's bump engine is on qits-workspaces' main (measured: `VersionStamp`, `VersionBumper`,
  `NpmVersionBumper` exist, CLAUDE.md documents them). Integrating qits-spa-home will bump its own
  three npm fields with the splice primitive; nothing here re-does any of that.
- qits-workspaces operates on the **same bare origins the git host serves** (release-flow finding
  3: the old merge advanced refs by direct filesystem write; the new flow pushes to a host holding
  the same volume). Consequence for this plan: a branch force-pushed through receive-pack by a step
  container is visible to qits-workspaces the moment the push lands — no fetch, no sync, no
  workspace container. A bare branch on the origin **suffices mechanically**; what does not suffice
  is the API keying, below.

**From software-release-event-plan.md (SEED):**

- Event name `SoftwareRelease`, payload `{projectId, repository, branch, version}`, published by
  the pushing service (qits-workspaces) immediately after a successful integrate push, through the
  `RunAnnouncer`-style seam. This plan additionally pins one reading the seed leaves implicit:
  **`repository` is the repo id string** (`qits-spa-ui-components`), the same identity every other
  contract on this platform carries. The implementing agent of that feature treats this as a
  consumer already bound to that spelling.
- **`branch` is the SOURCE branch that was integrated** — a workspace name, or, once this plan
  ships, `maintenance/<upstream>`. Consequence: **a bump trigger must never match on `branch`**.
  The canary file's `branch: {exact: main}` pattern is right for `BuildSuccessful` and wrong for
  `SoftwareRelease`; the trigger below matches `repository` alone, and the docs say why.

**Shipped and ridden as-is:** the ci-event trigger engine (matcher DSL `exact`/`prefix`/`exists`,
head-of-`main` convention, provenance columns, `(triggerEventId, repoId, configPath)` dedupe,
`QITS_EVENT_*` env), and causation (the run's `BuildSuccessful` stamps its trigger event as
`parentId`; explicit argument outranks ambient scope).

## The chain, end to end

```
  integrate qits-spa-ui-components ──> release(2026.731.193059) on main
        │                              └─> post-receive: ui-components' own CI runs,
        │                                  publish-if-absent puts @qits/ui-components@2026.731.193059
        │                                  into the hosted npm registry
        └─> SoftwareRelease {repository: qits-spa-ui-components, version: 2026.731.193059}
                │
  HOP 1 (event) ▼  qits-spa-home/.config/qits/ci-event-upstream-ui-components.yml
        bump run: wait for the version in the registry → write ^version into package.json →
        regenerate the lockfile (the origin dance, below) → commit
        bump(@qits/ui-components@2026.731.193059): …
        → FORCE-push maintenance/qits-spa-ui-components          (fresh causation chain from here)
                │
  HOP 2 (push)  ▼  post-receive fires for the maintenance branch — ONE run of the ONE pipeline
        qits-spa-home/.config/qits/ci-post-receive.yml, now two steps:
          step 0 (unscoped)                            the regular tests: npm ci, lint, test, build
          step 1 (branches: [{prefix: maintenance/}])  on green tests only:
            POST /workspaces/api/branches/integrate?repositoryId=qits-spa-home
                 {branch: maintenance/qits-spa-ui-components, summary: <the bump subject>}
        → release(<new version>): bump(@qits/ui-components@…) on qits-spa-home's main
        → SoftwareRelease {repository: qits-spa-home, …}
                │
                ▼
        no consumer declares a trigger for it — the train stops, deliberately (see below)
```

On a push to `main` or any feature branch, the same pipeline runs and step 1 is recorded
**SKIPPED** with a note saying the branch did not bind it. One pipeline, one run per push, and
"integrate only after green tests" falls out of step ordering rather than out of any machinery.

Two features carry it: the step-level branch filter (Decision 1, the platform half) and the two
committed pipeline changes (Decisions 2–3, the repo half). One contract amendment makes hop 2's
last arrow legal (Decision 3's interaction finding).

## Decision 1 — branch filtering is a STEP key (settled with the user, superseding the pipeline-level draft)

The first draft of this plan scoped whole pipelines: a top-level `branches:` key, plus a
`ci-post-receive-*.yml` file family so one repository could carry a test pipeline and a maintenance
pipeline side by side. The user's counter-proposal — **the matcher moves onto the step** — was
accepted (settled decision 1, below), and it wins on this plan's own evidence, not merely by
ruling:

- **Sequencing comes free.** The one thing the family could not express — "integrate only if the
  tests that just ran were green" — is exactly what step order inside a single run already means:
  a step after a failed step is SKIPPED today. The family needed two runs per maintenance push and
  had no way to couple their verdicts short of the future run-dependency feature.
- **The double-run dilemma evaporates.** The draft's ⚖ 1 (pay a redundant full test run per
  maintenance push, or scope the default file and lose feature-branch CI) was an artifact of
  pipeline-level scoping. One pipeline, one run per push, the regular test step tests every push
  including maintenance ones — nothing runs twice and nothing loses coverage.
- **The engine barely changes.** No family discovery, no rows born at discovery, no
  `CiConfigSource` listing verb, no `runQueued` generalization, no restart-window analysis. At run
  level, `CiRunService`'s accept/discard semantics are untouched — nothing is filtered out of
  existence anymore. A filtered *step* is **recorded**, which is more honest than the draft's
  run-level discard: the explorer shows that the pipeline considered the step and why it did not
  run.

### The shape

A new **optional per-step key**, carrying the matcher grammar the draft settled:

```yaml
steps:
  - image: qits/build-images/node-base:latest
    script: |
      # the regular tests — no branches: key, runs on every push
  - image: qits/build-images/node-base:latest
    branches:
      - prefix: maintenance/
    script: |
      # the integrate call
```

- The value is a **list of matcher mappings, OR'd**; a mapping may carry several matcher keys,
  AND'd — the `when:` DSL's composition rule, minus the path level, because the subject is one
  scalar: the run's branch. **Vocabulary: `exact` and `prefix`, nothing else.** `exists` is
  excluded, not merely unused: the branch is always present, and a matcher that can only ever say
  yes is a trap wearing a feature's name. **`regex` stays absent, and the maintenance train is the
  argument for keeping it out**: the user-level requirement "bind to `maintenance/.*`" is spelled
  `prefix: maintenance/` exactly, with no anchoring, escaping or ReDoS questions. The first step
  that genuinely cannot be spelled with `exact`+`prefix` reopens the question in a plan, not in a
  parser.
- **Absent means the step runs on every branch** — today's behaviour, byte-for-byte, the whole
  backward-compatibility clause. **An empty list is a config error**: both readings of `[]`
  ("all branches" and "no branch") already have an unambiguous spelling — omit the key; delete the
  step — and ambiguity with two better spellings is a parse error.
- **The known-key strictness rule applies, and the precedent is exact.** `timeout-seconds` and
  `docker` are already per-step keys in a lenient file where a malformed value is a
  `CONFIG_ERROR` run, never a quiet default; `branches:` joins them, for the sharper of the two
  standing reasons — a silently mis-parsed filter would either run a scoped step everywhere or
  skip it forever, and both directions are silent. Unknown per-step keys stay ignored, unchanged.
- The parse lands the matchers on `CiPipeline.CiStepDecl`, reusing
  `CiEventSelection.Matcher.exact/prefix` — one matcher implementation on the platform, not two.

### Skip semantics, defined against the code rather than waved at

`CiRunService.runSteps` is the entire site, and the definition is three sentences long:

- **Before launching a step's container**, the worker evaluates the step's matchers (when present)
  against `run.branch`. **No match ⇒ one terminal `SKIPPED` row is inserted at the step's index,
  with output** `[step not bound to branch <branch>]` **— and nothing else moves**: `failed` is
  not set, the loop continues, later steps run. A branch-skipped step launches no container and is
  a non-event to the run's verdict — precisely unlike a `FAILED` step, whose `failed = !ok` is
  what stops the loop and turns the run red.
- The two kinds of SKIPPED stay distinguishable **by the output field, which is the smallest
  honest form**: skipped-because-an-earlier-step-failed keeps today's `null` output (the trailing
  remainder loop is untouched); skipped-by-branch carries the bracketed note — the same convention
  `annotate`/`note` already use for every other "why this row reads this way" sentence. No new
  status, no new column, no migration; the explorer already renders SKIPPED, and the note sits in
  the field it already shows.
- **A run whose every step is branch-skipped finishes trivially green** — the existing "config
  present with no steps" precedent, not a new rule. It notifies CD and publishes `BuildSuccessful`
  like any green run. (In the demonstration this case never occurs: the test step is unscoped.)

And the interaction that makes the maintenance leg correct with zero coupling machinery: tests
fail ⇒ the loop stops ⇒ the integrate step is written SKIPPED with null output (never reached).
Tests green on a non-maintenance branch ⇒ integrate SKIPPED with the note. Tests green on
`maintenance/*` ⇒ integrate runs. All three outcomes are rows a person can read in one place.

### `ci-event-*.yml` steps: the key is rejected, loudly

An event-triggered run's branch is the `TRIGGER_BRANCH` constant, `main`, by shipped convention —
so on that path the key has exactly two possible behaviours, and both are the silent failure the
strict parser exists to prevent: `exact: main` is inert decoration, and anything else is a step
that is **always** skipped, indistinguishable at a glance from one that never got its turn.
Allow-but-inert is the trap; `CiEventTriggerParser` therefore rejects any step carrying
`branches:`, naming the file and the reason (a branch *condition over the payload* is what `when:`
already is). The shared `steps:` schema stays shared in the sense that matters — the key means one
thing everywhere it is legal; where it cannot mean anything, it is an error rather than a
different meaning. The same asymmetry argument the two-way rule already made at the top level,
moved down one level.

### Backward compatibility, with the hazard direction stated honestly

An **older qits-ci** ignores an unknown per-step key and **runs the step on every branch** — and
unlike the draft's pipeline-level key, where the leniency direction was merely extra builds, here
it would run qits-spa-home's *integrate step* on every push, feature branches included. Sequencing
forecloses it (Agent AF commits the file only after Agent AD's qits-ci is **deployed** — the
workstream says so in those words), which makes the exposure rollback-shaped, and it gets the
platform's standing answer for that shape: **defence in depth, not the only guard**. The integrate
step's script opens with a one-line assertion that `$QITS_CI_BRANCH` matches `maintenance/*` and
exits red otherwise — free when the filter works, and a loud failed step instead of an accidental
release when it does not.

## Decision 2 — the bump pipeline (repo-side yml, no service code)

`frontends/qits-spa-home/.config/qits/ci-event-upstream-ui-components.yml` — replacing nothing (the
canary of that name lives in qits-spa-workspaces and stays that plan's follow-up):

```yaml
event: SoftwareRelease
when:
  - repository: { exact: qits-spa-ui-components }
    # deliberately NO branch condition: SoftwareRelease.branch is the SOURCE branch that was
    # integrated (a workspace name, or maintenance/<upstream>), never main.
```

### The lockfile is why this step must run npm, and the origin dance is why it may

The consumer bump is a different animal from release-flow's own-version bump, and the difference
rules the mechanism. Y's engine splices because the three npm fields it moves are *this repo's own
version* — no resolution, no integrity. Bumping a **dependency** changes the lockfile's `resolved`
URL *and its `integrity` hash*, and the hash is a fact about tarball bytes that no splice can know.
npm must run; npm can only run where the registry is reachable; the registry is reachable from a
step container. So the bump runs in-container, and it steps around the documented lockfile-origin
trap (release-flow: "the engine must not step in it") with the same measured rewrite line every SPA
pipeline already carries — applied in **both directions**:

```
1. sed the committed lockfile's resolved ORIGINS  → the in-container origin   (the shipped recipe line)
2. npm_config env (registry + @qits scope — env, because spa-home COMMITS an .npmrc that
   outranks ~/.npmrc; the env outranks both, the pipeline's own measured pattern)
   npm install --package-lock-only "@qits/ui-components@^$VERSION"     # caret, matching the tree's pin style
3. sed every resolved origin → http://localhost:8081                  (the committed convention, restored)
4. git add package.json package-lock.json && commit && force-push
```

Step 3 is the line that keeps the commitment honest: the fresh `@qits/ui-components` entry is
written by npm with the container origin, and normalizing *all* origins back to the developer-host
convention is exactly what "the committed lockfile keeps the developer-host origin"
(`docs/project-setup-quinoa-angular.md`) requires. The integrity hashes are what make both rewrites
safe, both ways. The E2E asserts the committed convention held (no `qits-artifacts:8080` origin
survives into the maintenance branch).

### The registry race, named and bounded

`SoftwareRelease` is published at push time; `@qits/ui-components@<version>` reaches the registry
only when the upstream's own post-receive run gets to its publish-if-absent step, minutes later. In
practice the single-threaded run worker resolves this by construction — the upstream's post-receive
run was accepted at push time (one HTTP hop) and the bump run arrives via
bus → trigger-worker → per-repo git fetches, so FIFO puts the publish strictly before the bump on
the same thread. But "in practice" is not a contract: a failed upstream build publishes nothing
ever, and nothing forbids a future parallel worker. So the bump step **polls the registry for the
exact version with a bounded budget** (`npm view @qits/ui-components@$VERSION`, the upstream
pipeline's own probe, against the scoped-registry env) and fails **red and visible** on timeout — a
red bump run pointing at a version that never appeared is precisely the right diagnosis of a broken
upstream build, and at-most-once delivery means nobody retries it silently anyway.

### The branch name: `maintenance/<upstream repo id>`

`maintenance/qits-spa-ui-components`, not `maintenance/@qits/ui-components`. Three reasons, in
descending weight: **one branch per upstream is the collision unit** — qits-spa-home consumes two
`@qits` packages (ui-components `^0.0.4` and angular `^0.0.1`, measured), and two upstreams
releasing concurrently must land on two branches or the second force-push erases the first's
pending hop; the repo id is what makes that per-upstream, and it **arrives in the payload**
(`repository`) with no artifact-name mapping in the script; and repo ids are `[A-Za-z0-9-]` slugs,
so the composed ref passes `CiIdentifiers.requireBranch` and every git tool untweaked, where `@`
and a second `/` invite quoting archaeology. The artifact name belongs to humans and goes in the
commit subject; the repo id belongs to the platform and goes in the ref.

### The commit convention

```
bump(@qits/ui-components@2026.731.193059): follow the qits-spa-ui-components release
```

`bump(<artifact>@<version>): <text>` — the `release(<version>):` family's sibling, machine-locatable
by prefix, carrying the artifact identity the branch name deliberately does not. Worst-case length
(longest artifact in the tree + max version) is ~85 chars, which matters because **the subject is
reused verbatim as the integrate summary** (`@Size(max = 100)` in the frozen request) — the two
contracts compose with headroom, and the eventual main history reads
`release(2026.801.93059): bump(@qits/ui-components@2026.731.193059): follow the …`, a release whose
subject names its cause.

### The force-push, measured against the hook

The step pushes to `$QITS_CI_REPOSITORY_URL` (injected; the step's clone origin) with
`--force HEAD:refs/heads/maintenance/<upstream>`. This works with protection ON: `ProtectedRefHook`
guards only the ref `HEAD` names and lets every other command `continue` — read, not assumed. The
shallow (`--depth 50`) clone push is fine (the server holds every parent). "Deliberately no checks"
is survivable because the shipped machinery already self-cleans the one race it creates: a second
release force-pushing over a maintenance branch whose earlier run is still queued makes the earlier
sha unreachable, and the `GONE` path discards that run — a superseded hop deletes its own evidence
instead of going red against a push that no longer exists.

## Decision 3 — the maintenance leg, and the integrate seam it needs

`frontends/qits-spa-home/.config/qits/ci-post-receive.yml` grows a **second step** — the existing
test step is untouched and unscoped, so the maintenance push's tests are literally *the regular
tests*, not a copy of them:

```yaml
steps:
  - image: qits/build-images/node-base:latest        # existing: sed → npm ci → lint → test → build
    timeout-seconds: 1800
    script: |
      …unchanged…
  - image: qits/build-images/node-base:latest
    branches:
      - prefix: maintenance/
    timeout-seconds: 300
    script: |
      set -eu
      # defence in depth against an unfiltering (older/rolled-back) qits-ci — see Decision 1:
      case "$QITS_CI_BRANCH" in maintenance/*) ;; *) echo "not a maintenance branch"; exit 1;; esac
      summary=$(git log -1 --format=%s)          # the bump subject, ≤100 by construction
      # POST via node (fetch is built in; node-base has no jq and curl is not promised — measured lesson)
      node -e '…' "$QITS_WORKSPACES_URL/workspaces/api/branches/integrate?repositoryId=$QITS_CI_REPO_ID" …
```

The step self-identifies entirely from injected env — `QITS_CI_REPO_ID`, `QITS_CI_BRANCH` (both
measured present) — so the file states no deployment fact. One env var is missing today:
**`QITS_WORKSPACES_URL`**, which Agent AD adds beside the npm pair (`qits.ci.workspaces-url`,
default `http://qits-workspaces:8080` — the qits-net name, the platform's scheme+host+port shape),
so the shipped default is right and **no deployment variable and no run-args change is needed**;
the cd config-cache trap is therefore not tripped.

Status handling in the step: 200 → print the version and sha (the run log is the hop's receipt);
409 "already integrated" → **success** (a replayed post-receive re-runs the pipeline, and the
retry finding its work done is release-flow's own designed answer); every other status → red.
A 409 conflict (main moved a lockfile line under the bump) is a red run that heals itself: the next
upstream release force-pushes a fresh branch cut from the new main.

### The contract interaction — the finding most likely to amend release-flow

**Z's frozen endpoint cannot be called for a maintenance branch, and the gap is keying, not
mechanism.** `POST /workspaces/{id}/integrate` addresses a *workspace*; a maintenance branch is
created by a force-push from a step container and **no workspace row exists or should exist** for
it (a workspace is a container lifecycle, a branch *claim* with an ACTIVE-uniqueness constraint,
and a resolution state machine — all wrong-shaped for a branch a pipeline overwrites at will;
manufacturing one per hop would be ceremony feeding a lifecycle nobody runs). Everything *below*
the endpoint already fits: the nine steps operate on refs in the bare origin (lease by repoId,
preflight, detached worktree, merge, stamp, bump, commit, push), the branch is in that bare the
moment receive-pack accepts it, and qits-workspaces' own `BranchController` javadoc has already
blessed the category — *"the source of an integration needs no workspace of its own (a plain
branch is merged from its origin ref)"* — for the legacy `/branches/merge`, which release-flow
409s for main-targets precisely to point at integrate.

**Recommendation, decided: an additive branch-keyed sibling, landed by this plan as Agent AE, with
a pointer added to release-flow-plan.md rather than a change to Z's frozen surface.**

```
POST /workspaces/api/branches/integrate?repositoryId=<repoId>
     { "branch": "maintenance/qits-spa-ui-components", "summary": "bump(…): …" }
  →  { "version", "commitSha", "branch" }        # the identical Response record
```

- Same flow, same 409 family, same summary validation; 404 for a branch the origin does not have;
  400 for the main branch itself (the existing "cannot integrate into itself" rule).
- **If an ACTIVE workspace does claim the named branch, it is resolved INTEGRATED** — the branch
  endpoint must not become the door that strands a workspace on a branch that just merged; this
  mirrors what the workspace-keyed endpoint does and what `mergeBranch` already arranges today.
- **The source branch is deleted after a successful integrate**, matching the workspace path's
  cleanup. The next hop force-push is a CREATE, which the hook allows by design, so deletion costs
  the train nothing and leaves no stale ref lying about what is pending.
- Implementation note for AE (and for Z, if Z has not landed when this plan starts): keep the flow
  keyed internally by `(repoId, branch)` with the workspace endpoint as a thin resolver over it —
  then the two endpoints are two spellings of one method and cannot drift.

## Loops, and where the demonstrated chain stops

The real graph, measured: `@qits/ui-components` is consumed by **all eight** SPAs (uniform
`^0.0.4`); `@qits/angular` by qits-spa-home; and qits-spa-home is consumed by **qits-gateway as a
git submodule at `src/main/webui`** — a gitlink pin, not a manifest range. That last edge is a
different mechanism entirely (advancing a gitlink, in a repo whose main is protected, inside the
gateway's own prebuilt-bundle pipeline), and it is where the demonstration **deliberately stops**:
`SoftwareRelease(qits-spa-home)` is published and matched by nothing. The stop is structural, not
configured — a repo without a trigger file is not on the train — which is itself the demo's last
assertion: the train halts safely at an undeclared edge. The gitlink hop is named in "out of
scope"; the other seven SPAs are settled decision 2.

**The no-guard decision stands, and this plan adds two loop shapes to the documented footgun.**
(1) *Self-re-release*: a repo whose bump trigger matches its own `SoftwareRelease` re-releases
itself forever — bump, push, test, integrate, release, match, repeat — each hop a new eventId, so
the dedupe constraint never engages (it kills replays, not descendants). The exact matcher is
today's whole defense: qits-spa-home's trigger binds `repository: {exact: qits-spa-ui-components}`
and its own releases carry `qits-spa-home`; a `prefix: qits-spa-` would close the circle. (2) *The
event-free maintenance loop, new with the branch filter*: a step bound to `prefix: maintenance/`
whose script pushes a `maintenance/*` ref re-triggers its own pipeline with no bus involved at
all. The shipped integrate step cannot — it pushes only through integrate (to main, `qits.release`,
fast-forward) — and the config docs Agent AD writes name both shapes where a pipeline author will
read them. The meta-level DAG feature remains the real answer and nothing built here narrows its
options — the provenance trail it will consume is exactly what these runs already record.

## Causation, one paragraph, no machinery

Within hop 1 the shipped stamping does its job: the bump run's `BuildSuccessful` carries the
`SoftwareRelease` eventId as `parentId`, walkable with `?parentId=`. The force-push is a **chain
boundary, accepted as specified**: a push is not an event, the maintenance run is a root, and the
integrate-produced `SoftwareRelease(qits-spa-home)` is a fresh root too (an integrate initiated by
an HTTP call has no ambient cause — the seed plan says the same of human-initiated ones). So one
full train hop is recorded as **two short chains, not one long one**; this plan notes it, designs
nothing for it, and the user has ruled it will be solved differently later. No step script exports
parent ids, no header rides the integrate call, nothing here forecloses that future design.

## Frozen contracts (this plan's own)

- Per-step `branches:` in post-receive pipeline steps — list of matcher mappings, `exact`/`prefix`
  only, entries OR'd, keys within a mapping AND'd, absent = the step runs on every branch,
  `[]` = config error, malformed = `CONFIG_ERROR` run (the `timeout-seconds`/`docker` precedent).
- Skip semantics: a step whose filter does not bind the run's branch is recorded **SKIPPED with
  output `[step not bound to branch <branch>]`**, sets nothing red, blocks nothing after it;
  never-reached steps keep their null-output SKIPPED rows; an all-skipped run is trivially green.
- `branches:` on a step in a `ci-event-*.yml` is a per-file parse error.
- `QITS_WORKSPACES_URL` in every step container, from `qits.ci.workspaces-url`, default
  `http://qits-workspaces:8080`.
- `POST /workspaces/api/branches/integrate?repositoryId=…` `{branch, summary}` →
  `{version, commitSha, branch}`; 409 family as Z; 404 unknown branch; 400 main-into-itself;
  ACTIVE workspace on the branch resolved INTEGRATED; source branch deleted on success.
- The maintenance ref: `maintenance/<upstream repo id>`, force-pushed, one per upstream.
- The bump subject: `bump(<artifact>@<version>): <text>`, ≤100 chars, reused as the integrate
  summary.
- Trigger files for `SoftwareRelease` match `repository`, never `branch`.

An agent that believes one of these is wrong reports back; it does not adjust its side
unilaterally.

## Workstreams (one Opus 5 agent each; letters continue at AD)

### Agent AD — the step-level branch filter (repo: services/qits-ci)

Visibly smaller than the draft's version: no file family, no discovery, no `CiConfigSource`
change, no sweep change, no migration.

- `CiConfigSchema`: parse `branches:` on a step into `CiPipeline.CiStepDecl` (reusing
  `CiEventSelection.Matcher.exact/prefix`), with the known-key strictness (`[]` and malformed
  values are `CiConfigException` → `CONFIG_ERROR` run) and the unknown-key leniency intact.
- `CiEventTriggerParser`: reject any step carrying `branches:`, naming file and reason (Decision
  1's allow-but-inert argument in the message).
- `CiRunService.runSteps`: the pre-launch evaluation — no match ⇒ terminal SKIPPED row at the
  step's index with the bracketed note, `failed` untouched, loop continues. Nothing else moves.
- `QITS_WORKSPACES_URL` in `CiDaemonLauncher` + `qits.ci.workspaces-url` with its default.
- Tests: parser matrix (bind/unbind, AND within a mapping, OR across entries, `[]`, malformed,
  unknown-key leniency unchanged, event-file rejection); `runSteps` semantics — a branch-skipped
  step does not fail the run and does not block later steps (asserted by a later step executing),
  a failed step still writes the remainder SKIPPED with null output, the two SKIPPED forms are
  distinguishable by output, an all-skipped run finishes SUCCESS and announces (the empty-pipeline
  precedent, asserted rather than assumed); one boundary test reading the recorded rows for a run
  with an unscoped step, a bound step and an unbound step.
- Docs: README's config-format section (the step key, the two SKIPPED forms, the event-file
  rejection sentence, both loop-footgun shapes from this plan). `./mvnw verify` green (submodules
  initialised first), push both remotes, pipeline redeploys qits-ci — **the lossy-intake trap is
  half-dead now: `QUEUED` survives the cutover, a `RUNNING` build still dies**; no run row after
  the push ⇒ replay `POST /ci/api/events/post-receive`.

### Agent AE — the branch-keyed integrate (repo: services/qits-workspaces, after release-flow Z)

- `POST /branches/integrate` on `BranchController` exactly as frozen above, as a thin resolver over
  Z's flow (refactor the flow to `(repoId, branch)` keying internally if Z did not already land it
  that way — and report back to release-flow's record either way).
- The ACTIVE-workspace resolution, the source-branch deletion, the three 409s + 404 + 400.
- Tests: `@QuarkusTest` against a `TestOrigin` bare — a plain branch (no workspace) integrates and
  produces the one two-parent `release(…)` commit; an ACTIVE workspace on the branch ends
  INTEGRATED; already-an-ancestor → 409; unknown branch → 404. Regenerate and commit
  `docs/openapi.yml` (the repo requires it on any REST change). `./mvnw verify` green, push both
  remotes, pipeline redeploys qits-workspaces.

### Agent AF — the two pipeline files (repo: frontends/qits-spa-home, after AD is DEPLOYED + AE + SoftwareRelease ships)

"Deployed", not merely merged: an unfiltering qits-ci runs the integrate step on every branch
(Decision 1's compatibility note), so AD's live cutover is a hard precondition — and the step
keeps its one-line branch assertion as defence in depth regardless.

- The **new** `ci-event-upstream-ui-components.yml` (Decision 2: the poll, the two-way origin
  dance, the caret pin, the commit convention, the force-push) and the **edit** to the existing
  `ci-post-receive.yml` — the second, `branches:`-scoped integrate step (Decision 3), the test
  step untouched. The integrate POST goes via `node -e` — node-base has no jq and curl is not to
  be promised, the measured lesson; verify, don't assume.
- The repo's quirks, all three already documented in its own pipeline and honored, not
  rediscovered: it **commits an `.npmrc`** (localhost:8081, right for a developer), so registry
  config must be `npm_config_*` env (a project `.npmrc` outranks `~/.npmrc`); the lockfile origin
  convention is `http://localhost:8081` and must survive the bump byte-convention-identical; the
  repo **ships no image** — qits-gateway builds the bundle in its own pipeline step and packages
  the prebuilt dist, so nothing here touches publishing.
- Both changes land on `main` by push (or by integrate, if AC has flipped protection by then — use
  whatever the door is that week and say which was used). Push both remotes.
- Git identity for the bump commit: `-c user.name`/`-c user.email` naming the train, decided here
  once and written in the file.

### Agent AG — the live chain, end to end (superproject + platform, after everything)

- Preconditions checked, not assumed: protection state (AC), `SoftwareRelease` flowing (a real
  integrate publishes one), AD deployed, AE deployed, AF on spa-home's main.
- Drive one hop: a trivial workspace on qits-spa-ui-components, integrate it through the API.
- Assert, in order: the `SoftwareRelease` row; the bump run (EVENT provenance, its
  `BuildSuccessful` carrying the release's eventId as `parentId`, walked via `?parentId=`);
  `maintenance/qits-spa-ui-components` carrying exactly one `bump(…)` commit whose lockfile
  origins are all `localhost:8081`; the maintenance push's **one run with two step rows — tests
  SUCCESS, integrate SUCCESS**; on an ordinary main push of spa-home, the integrate step row
  **SKIPPED with the branch note** (the filter observed live, in both directions); spa-home's main
  tip `release(<v>): bump(@qits/ui-components@…)…` with two parents and the bumped pin;
  `SoftwareRelease(qits-spa-home)` in the log **followed by no triggered run** — the train stopped
  at the declared edge; and the causation shape (two chains, roots at the push boundary and at the
  second integrate — recorded as correct, not as a gap).
- A second, cheap probe: force-push the maintenance branch again by hand and verify the superseded
  behaviour (`GONE` discard) and the 409-already-integrated-is-success path.
- Plan edits: release-flow-plan.md gains the pointer to the branch-keyed integrate; this plan gains
  its status line and the measured version strings.
- Traps that apply here and nowhere else in this plan: the **cd config cache** (if any run-args do
  change after all, rewrite/restart before the deploy, and hand the core to compose before
  membership changes — the local-up recreate landmine); the **immutable `index.html` cache** if any
  UI is used to verify runs (prefer the APIs; if a browser is used, hard-reload before believing
  it); the lossy-intake replay for any push that yields no row.

**Sequencing: AD ∥ AE (different repos; AE additionally gated on release-flow Z) → AF (needs AD
deployed, AE, and the SoftwareRelease feature) → AG.** Finer splits rejected: AD's parser and
runSteps halves share one repo and one seam; AF's two file changes are one demonstration and one
repo.

## Decisions settled with the user (2026-07-31)

**1 — Branch matching is per-STEP, not per-pipeline** (the user's own counter-proposal, accepted
in place of the recommended pipeline-level `branches:` key and the `ci-post-receive-*.yml` file
family, both dropped outright). A post-receive step may carry `branches:` with the settled matcher
vocabulary; an unbound step is recorded SKIPPED with a note and affects nothing else. The
consequences are worked through in Decision 1: step ordering inside one run replaces the family's
two uncoupled runs, the redundant-test-run dilemma (the original ⚖ 1) dissolves because there is
no second pipeline, the engine keeps today's one-run-per-push semantics untouched at run level,
event-trigger files reject the key, and the old-CI leniency direction flips from harmless to
guarded-by-sequencing-plus-assert.

The original ⚖ 1, for the reasoning record, asked which of two costs to pay under pipeline-level
scoping — a redundant full test run per maintenance push, or scoping the default file to `main`
and losing feature-branch CI on the demo repo. The counter-proposal pays neither, at a price the
draft had weighed and overvalued: a maintenance hop is now a step row inside an ordinary run
rather than a run of its own. The SKIPPED-with-note row is what keeps that visibility honest.

**2 — qits-spa-home only, first.** One full hop observed green end to end (Agent AG) before any
fan-out; the remaining seven SPAs are a mechanical follow-up — copies with one `exact:` value
changed — that needs no plan, only the observed hop. Committing all eight up front would have made
one ui-components release fan out into 8 bump runs, 8 maintenance pushes and 8 releases,
serialized on one worker, as a first live load test with no observation period.

## Out of scope, named so nobody drifts into it

- **Causation across the push boundary.** Accepted lost; the user has ruled it will be solved
  differently later; nothing here designs for it or against it.
- **The gateway hop** — advancing the `src/main/webui` gitlink on `SoftwareRelease(qits-spa-home)`.
  A different mechanism (gitlink, protected main, prebuilt-bundle pipeline) and the named edge
  where the demo stops.
- **The maven consumer bump.** The design's shape transfers (a step that edits `pom.xml` instead of
  the lockfile — and *may* splice, since a pom carries no integrity hash), but it is measured
  moot today: no repo on this platform consumes another's artifact through a maven registry — the
  platform publishes no maven artifacts at all, and every service embeds its SPA as a gitlink. The
  first published jar reopens this as a small follow-up, not a redesign.
- **Pipeline-level branch filtering and the post-receive file family** — designed in this plan's
  first draft, superseded by settled decision 1, and deliberately not kept as a dormant second
  mechanism: one filtering concept, at the step.
- Cycle/self-reference detection (the DAG feature), catch-up/replay on the bus, and run
  dependencies between pipelines — three standing future features this plan leans on not having,
  and narrows no options for. (Step ordering inside one run now covers the train's own sequencing
  need, which removes this plan's only near-term pressure on the run-dependency feature.)
- The canary flip in qits-spa-workspaces (`BuildSuccessful` → `SoftwareRelease`) — named by
  software-release-event-plan.md as its own follow-up; this plan's spa-home trigger is the real
  hop, not a replacement for that housekeeping.
- The other seven SPAs' files (settled decision 2's follow-up), any UI for train hops, and any
  retry/replay machinery for a stranded hop beyond the red runs and 409-semantics already
  specified.
- Publishing anything from qits-spa-home. Its release is a version stamp and a merge; the gateway
  packages the bundle, unchanged and unaware.
