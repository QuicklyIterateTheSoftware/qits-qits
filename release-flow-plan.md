# Releasing as a domain process: integrate, stamp, push

## Addendum, 2026-08-01: two processes, and only one of them releases

**SHIPPED. This addendum supersedes the body's API where the two disagree; everything else in the
body — the protected ref, the push option, the nine-step flow, the calver stamp, the bumpers — is
what shipped.** The body folds releasing into "integrate". The user flagged that as a mistake (the
parked item in the 2026-07-31 handoff), and the design pass split it in two:

- **`POST /workspaces/api/workspaces/{id}/release` `{summary}` → `{version, commitSha, branch}`.**
  Merges the workspace's branch into the repository's default branch — **the target is not a
  parameter, it is always `main`** — with the calver stamp, the manifest bump and one two-parent
  `release(<version>): <summary>` commit, pushed with `-o qits.release`. **The one door into
  `main`**, and the only versioned one.
- **`POST /workspaces/api/workspaces/{id}/integrate` `{summary}` → `{commitSha, branch,
  targetBranch}`.** Merges the workspace's branch into **its parent branch** — a `task/…` landing
  on the `epic/…` it forked from — as one plain two-parent `integrate(<source>): <summary>` commit.
  No version, no bump, no `qits.release`, no event; the response carries no `version` field for the
  same reason. Releasing is what the epic then does with `/release`.

Integrating a workspace whose parent resolves to `main` is refused **409 with `reason:
RELEASE_REQUIRED`**, naming the endpoint that does write it; `/branches/merge` and
`/workspaces/{id}/merge` raise the same reason on a main target. `reason` joins the 409 family
(`CONFLICT`, `MERGE_CONFLICT`, `NOT_FAST_FORWARD`, `ALREADY_INTEGRATED`, `PUSH_REJECTED`) and the
whole enum is now declared in `docs/openapi.yml` via `api/ApiError` — the body's "OpenAPI declares
no 4xx anywhere" note is closed.

**`SoftwareRelease` shipped with it** (software-release-event-plan.md, SHIPPED): a release — never
an integrate — publishes `{projectId, repository, branch, version}` the instant the push is
accepted. First live event `1faa0164-7747-4cf9-9bb5-a996c0db6898`.

Live proof of the split, 2026-08-01 on qits-stt: release → `2026.801.55529`, merge commit
`eed05301`, two parents, three poms bumped, ordinary CI run, `SoftwareRelease` on the bus; integrate
on an `epic/aj-proof`-parented workspace → `05638f5c` on the epic branch, `main` byte-identical, no
event; integrate on a main-parented workspace → 409 `RELEASE_REQUIRED`.

The body below is the historical design and is left as written.

---

Today `main` is written by whoever types `git push`. This feature makes releasing a thing the
platform *does* rather than a thing a person remembers to do: **`main` becomes protected, and the
workspaces API's "integrate" becomes the one door into it.** Integrating a workspace merges its
branch into `main`, and the merge commit itself carries the version bump — one commit, one
conventional-commit subject, `release($version): what changed`. Then it is pushed, through the
ordinary git host, where the ordinary post-receive fires and the ordinary CI pipeline builds it.

That last sentence is the feature's best property and it is deliberate: **the release is a push
like any other push.** Nothing downstream learns a new trick. qits-ci does not grow a release
trigger, qits-cd does not grow a release path; the merge commit lands on `main` and the existing
machinery builds and deploys it because that is what it already does with commits on `main`.

A release here is exactly two things — a version bump and a merge to `main`. **Producing or
publishing an artifact is not in scope** and is named again at the bottom, because the temptation
to grow this into "release = publish" is strong and would be wrong: the pipeline that already
publishes images from a green `main` push keeps that job, unchanged.

Execution is by Opus 5 subagents, one per workstream — parallel across repos, sequential inside
one, the pattern the last four features used.

## What exists, measured (not assumed)

Four findings reshaped this design. Each was read out of the code, and two were run.

**1. The git host runs no hooks, because it runs no git.** `GitHostRoutes`
(`services/qits-artifacts/service/src/main/java/eu/wohlben/qits/githost/GitHostRoutes.java`) is
JGit's `ReceivePack` driven in-process from raw Vert.x routes — no CGI, no `git http-backend`, no
subprocess. A `pre-receive` script in a bare repo's `hooks/` **would never execute**, and
`GIT_PUSH_OPTION_*` is not a concept on this path. The bare repos' `hooks/` directories hold only
git's stock `.sample` files. So protection is not a hook file; it is `rp.setPreReceiveHook(…)`, a
Java lambda, next to the `setPostReceiveHook(…)` that already notifies CI (line ~236).

**2. Push options are the only bypass channel that works from everywhere.** Three network doors
reach the git host: `localhost:8080` through the gateway, `qits-artifacts:8080` direct on
qits-net, and `127.0.0.1:8081` host-mapped past the gateway entirely. A header cannot serve all
three — the gateway strips the entire `X-Qits-` prefix unconditionally (`EdgeHeaders`), so an
`X-Qits-Force-Push` would be *present* on qits-net and *absent* through the front door: a bypass
whose behaviour depends on which door you used. Push options ride inside the pack protocol and are
identical through all three. JGit delivers them as `rp.getPushOptions()` in-process.

**3. Today's merge never reaches receive-pack at all.** `WorkspaceService.mergeIntoTarget`
(`services/qits-workspaces/domain/.../control/WorkspaceService.java:1455-1508`) does
`git worktree add` *inside the bare origin* and merges there, which advances `refs/heads/<target>`
by direct filesystem write. There is no push, so **post-receive never fires and no CI run is
created**. Any integrate flow that keeps that shortcut has to hand-post the CI intake and
duplicate qits-artifacts' job. This is the single biggest mechanical decision below.

**4. No repository in this platform has both stacks.** Machine-checked: `git ls-files` finds
**zero** tracked `package.json` in all 13 maven repos. Every service's web UI is a *gitlink* to a
separate SPA repo (`160000 commit` at `service/src/main/webui`). "A repo may have both" is a
non-case today — the engine still handles it, deterministically, because doing so costs one `if`.

Two smaller facts that the implementation trips over if it does not know them:

- `GitExecutor.exec` calls `p.waitFor()` with **no timeout at all**. Every git call in workspaces
  today is unbounded. That is survivable for local filesystem operations; it is not survivable for
  a *network* push, which this feature introduces.
- `TechnicalProcessRegistry.beginForRepository(repoId, kind)` is an existing repo-scoped mutex —
  used by qits-projects' pull/sync/push, and **not** by the merge path, which is unguarded today.

## The version format — ruled, with the comparators run

The requested shape is `$year.$month.$day-HHMMSS`. It cannot be used as written, and the reason is
worse than "npm dislikes leading zeros". Both stacks' real comparators were run — npm's bundled
`semver`, and Maven's `ComparableVersion` from `maven-artifact-3.9.12`.

### The measured failures

```
                        npm semver          measured
2026.07.31-193059       INVALID     leading zero in the "07" numeric identifier
2026.7.31-193059        VALID       fixed... at 19:30:59
2026.7.31-093059        INVALID     SAME FORMAT, 09:30:59 — leading zero in the PRERELEASE
```

That middle pair is the landmine. `-HHMMSS` before 10:00 is an all-digit identifier with a leading
zero, which semver §9 forbids and which is therefore neither a valid numeric identifier nor a
valid alphanumeric one. **The format works every afternoon and is invalid every morning** — a bug
that passes every daytime test and detonates on the first early release, in 42% of the day.

The prerelease semantics are the second, quieter failure. Measured, over a package whose versions
are all of the dashed form:

```
semver.maxSatisfying(['2026.7.31-93059','2026.7.31-193059','2026.8.1-93059'], '*')  ->  null
semver.satisfies('2026.8.1-93059', '^2026.7.31-193059')                             ->  false
semver.satisfies('2026.8.1-93059', '>=2026.7.31')                                   ->  false
```

`null`. A package every one of whose versions is a prerelease resolves to **nothing** under `*`,
and a consumer's caret range stops matching the moment the day rolls over — because a range only
admits prereleases sharing its exact `[major,minor,patch]` tuple. Publishing is out of scope here,
but this version string is the one that *would* be published, and it would quietly freeze every
consumer at its pinned day.

And the two stacks disagree about the same string:

```
                                       semver          ComparableVersion
2026.7.31-193059  vs  2026.7.31        -1 (BEFORE)     a > b   (AFTER)
2026.7.31-t093059 vs  2026.7.31        -1 (BEFORE)     a > b   (AFTER)
```

A dashed suffix is a *prerelease* to npm and an *unknown qualifier* to Maven, and unknown
qualifiers sort **after** the release. One string, two opposite meanings. No amount of care fixes
that; it is what the dash means in each ecosystem.

### The ruling: `YYYY.MMDD.HHMMSS`, one canonical string for both stacks

Keep every digit the user asked for; move only the punctuation. Fold month+day into one numeric
identifier and the time into another:

```
version = year "." (month*100 + day) "." (hour*10000 + minute*100 + second)

2026-07-31 19:30:59  ->  2026.731.193059
2026-07-31 09:30:59  ->  2026.731.93059
2026-01-01 00:00:00  ->  2026.101.0
2026-12-31 23:59:59  ->  2026.1231.235959
```

Expressed as integer arithmetic, not string formatting — which is why **no leading zero can exist
by construction**. There is no zero-padding step to forget.

Measured, both comparators, both orderings correct in every case:

```
                                          semver     ComparableVersion
2026.731.93059   < 2026.731.193059        OK         OK    same day, 09:30 -> 19:30
2026.731.193059  < 2026.801.93059         OK         OK    cross-day
2026.1231.235959 < 2027.101.0             OK         OK    cross-year
2026.115.0       < 2026.203.0             OK         OK    Jan 15 -> Feb 3
1.0.0-SNAPSHOT   < 2026.731.193059        —          OK    today's placeholder -> first release
semver.satisfies('2026.801.93059', '^2026.731.193059')     -> true
semver.maxSatisfying([...all three...], '*')               -> 2026.801.93059
```

Why this wins, beyond passing:

- It is a **release version, not a prerelease.** Caret and tilde ranges work, `npm outdated` and
  `npm update` work, `latest` resolution works, `maxSatisfying` returns a version instead of null.
- It carries **no qualifier**, so the semver/Maven disagreement has nothing to disagree about.
  Maven sees three integer items and compares them numerically; that is the least surprising
  behaviour Maven has.
- **One string, both stacks.** No per-stack divergence to keep in sync, and no chance of the two
  drifting apart later.
- Ordering is **total and chronological** at every scale — same second upward.
- Migration from today's uniform `1.0.0-SNAPSHOT` / `0.0.0` placeholders is monotonic.

Readability is the price: `2026.731.193059` reads as "2026, 7/31, 19:30:59" but takes a beat
longer than the dashed form. That is the whole cost, and it buys correctness in both ecosystems.
See ⚖ 1 — the alternative is priced there, not hidden.

**Collision and monotonicity.** One second is the resolution, so two integrates of the same repo in
the same second would collide. They cannot: the repo lease serializes integrates, and the push is
a fast-forward compare-and-swap (below), so the loser is rejected rather than silently equal. The
stamp is taken from the clock **once**, at the start of the integrate, and threaded through — never
recomputed per file, or a slow bump would write two versions into one commit.

## Push protection, and an honest bypass

The standing posture is "qits-net is trusted; no speculative security schemes". This is not a lock
and must not pretend to be one — **it is a seatbelt against reflex**, against the muscle memory of
`git push …/artifacts/git/qits-ci main` that every doc in this tree currently teaches. Anything
with the `qits-repositories` volume mounted can still move a ref by writing a file, and that is
fine: those are platform components, not accidents.

**The mechanism.** A `PreReceiveHook` in `eu.wohlben.qits.githost`, registered on the `ReceivePack`
in `GitHostRoutes.service(...)`:

- **The protected ref is whatever `HEAD` points at** — `repo.getFullBranch()` on the bare. That is
  `refs/heads/main` for every repo here, it is per-repo without a table or a config write, it needs
  no cross-service read of qits-projects' `Repository.mainBranch`, and it is semantically the right
  answer ("the repo's default branch") rather than a hardcoded string.
- **Creates are allowed; updates and deletes are guarded.** An empty repo has no default branch to
  protect, and blocking the seeding push buys no safety. This alone keeps `qits-local-up.sh`'s
  first-run push working untouched.
- **Non-fast-forward and delete of the protected ref are rejected** unless overridden — the
  force-push and the accidental `:main` are exactly what a seatbelt is for.

**The bypass, one named option and one token** *(revised 2026-07-31 — the user replaced the
original well-known `qits.override` option with a token, deliberately trading the seatbelt
framing for a latch that defaults to locked)*:

- `-o qits.release` — "this is an integrate-produced release". Fast-forward only. The integrate
  flow sends this and nothing else does. Not a secret: it is the sanctioned domain door, and the
  hook's fast-forward-only restriction is what bounds it.
- `-o qits.token=<value>` — "push anyway": allows any update including non-fast-forward and
  delete, **iff** the value equals the git host's configured push token
  (`qits.repositories.git.push-token`). **Default: unset — and unset means NO token matches**;
  an empty configured value likewise matches nothing (never "empty allows empty"). With
  protection on and no token configured, direct pushes to the default branch are simply
  impossible; the deployment that wants the dev-loop/bootstrap escape configures a token and
  presents it. Push options are the carrier because they travel identically through all three
  doors (the gateway strips `X-Qits-*` headers; options ride the POST body).

The logs stay honest and the rollout measurable: every accepted `qits.release` and every accepted
token push is logged at INFO (the token value never echoed), so "how much direct-to-main pushing
is still happening" remains a question with an answer.

Push options need `setAllowPushOptions(true)` on **both** `ReceivePack` instances — the one in
`service(...)` that receives them, and the one in `infoRefs(...)` (line ~197) that advertises the
capability. A client only sends `-o` if the advertisement offered it, so missing the second call
produces the confusing failure where the option is silently never seen.

**Per-repo or platform-wide: both, in that order.** A platform-wide property
`qits.repositories.git.protect-default-branch` with a per-repo override in the bare's own config
(`[qits] protectDefaultBranch = false`), read via `repo.getConfig().getBoolean(…)`. The bare's
config needs no table — qits-artifacts owns none by design — and travels with the volume.

**The rollout is the real design here, and it is ordered, not a flag day:**

```
  X ships the hook with the property defaulting to FALSE
      -> inert. A broken hook cannot brick the host that serves its own redeploy.
  AB teaches every legitimate pusher the option
      -> qits-local-up.sh's push loop, the docs that tell humans to push main.
  AC flips the default to TRUE and proves both paths live
      -> integrate succeeds; a bare `git push … main` is refused with a message
         naming the integrate endpoint AND the override option.
```

Shipping it inert first is not caution for its own sake. Agent X's own change is delivered *by a
push to qits-artifacts, which is the service that would refuse it* — a protection bug that lands
enabled could reject the push that fixes it. Default-off makes that impossible.

**The gateway needs no change.** `PublicPaths` already allowlists `/artifacts/git/` whole and
method-agnostic; push options travel in the POST body. Naming this explicitly because the
neighbouring `/v2` entry documents the opposite trap — widening an allowlist without a guard — and
this feature does the reverse: it adds a guard behind an allowlist that already exists.

## The integrate flow

The mechanism follows from finding 3. Today's merge writes `refs/heads/main` directly on disk and
CI never learns. The user's intent says the merge commit is *pushed*, and that the existing
post-receive continuity is a feature. So integrate must go **through receive-pack** — which means
qits-workspaces builds the commit locally and then pushes it over HTTP to the git host, i.e. the
bare origin is pushed to *by a client holding the same filesystem*.

That reads odd for one second and is then obviously right: it is what makes "the only flow into
main" true at the mechanism level rather than as a slogan. Receive-pack is the sole writer of
`main`; the protection hook sees every release; post-receive fires; CI builds. One door, and the
door is the one that was already there.

```
  POST /workspaces/api/workspaces/{id}/integrate  {summary}
        |
        | repo lease (TechnicalProcessRegistry.beginForRepository) — serialize per repo
        v
  [1] preflight        git merge-tree --write-tree <src> <main>     conflicts? -> 409, nothing done
        |
  [2] worktree         git worktree add --detach <tmp> refs/heads/main
        |                                    ^^^^^^^^ DETACHED — no branch ref can move
  [3] merge, no commit git merge --no-ff --no-commit <src>
        |                              conflict -> merge --abort, worktree remove, 409 + files
  [4] stamp            version = YYYY.MMDD.HHMMSS   (taken once)
        |
  [5] bump             detect stack -> rewrite version files in the worktree -> git add
        |
  [6] one commit       git commit -m "release(2026.731.193059): <summary>"
        |                    two parents (merge) + the bump — deliberately ONE commit
  [7] push = the CAS   git push <git-host>/artifacts/git/<repoId> HEAD:refs/heads/main
        |                       -o qits.release          fast-forward only, bounded timeout
        |                       rejected non-ff -> main moved under us -> 409 "retry"
        v
  [8] receive-pack -> pre-receive sees qits.release -> accepts
                   -> post-receive -> POST /ci/api/events/post-receive -> a build, like any push
        |
  [9] worktree remove; workspace -> INTEGRATED; branch cleanup; WorkspaceEventType.INTEGRATED
        v
  200 {version, commitSha, branch}
```

Four properties fall out of that shape, and each is why a step is where it is:

**`--detach` is what makes "no partial state" true.** Steps 2–6 move no ref anywhere. A conflict, a
bump failure, a crash — `main` is untouched, because the only thing that ever moves it is step 7. A
failed integrate needs no unwind, only a worktree removal. Compare today's flow, where the merge
commit lands on `main` the instant it succeeds and a later failure has nowhere to go.

**`--no-commit` is what makes bump-and-merge one commit.** `git merge --no-ff --no-commit` leaves
`MERGE_HEAD` set and the index staged; the bump writes into that same index; the single `git commit`
that follows produces a two-parent merge commit that also contains the version change. No amend, no
second commit, no rebase. The user asked for one commit and git gives it directly.

**The push is the compare-and-swap.** A normal (non-forced) push to `main` is fast-forward-only. If
another integrate won the race, the loser's push is rejected as non-fast-forward and the loser
reports "main moved, retry" — with `main` in a correct state either way. This is why no distributed
lock is needed: git's own ref update is the atomic primitive, and `qits.release` is deliberately
*not* granted force, so the CAS cannot be accidentally defeated. The repo lease still serializes
in-process, which turns the common case from "one fails" into "one waits".

**Conflicts are reported, never half-applied.** Step 1's `merge-tree --write-tree` preflight already
exists in this codebase (`GitExecutor.conflictedFiles` parses its output) and catches the common
case before any worktree exists. Step 3 is the backstop. Both return **409 with the conflicted file
list** — not the 500 that today's `mergeIntoTarget` produces, where `git merge`'s non-zero exit
becomes an exception and the `hasConflicts` flag is effectively dead code.

Three inherited sharp edges this flow must fix rather than inherit:

- **Stale worktrees are never pruned.** No `git worktree prune` exists anywhere in either service; a
  crashed merge leaves `.tmp-merge-<millis>` registered and the *next* merge fails with "already
  checked out". Integrate prunes before adding, and removes in a `finally`.
- **`.tmp-merge-<System.currentTimeMillis()>` collides** within a millisecond. Use the workspace row
  id, which is unique by construction.
- **`GitExecutor` has no timeout.** Step 7 is the first *network* git call in this service; a wedged
  host would pin a request thread forever. Add a timeout overload (`waitFor(duration)` + `destroy`)
  and use it for the push. Local filesystem calls may keep today's behaviour.

## The bump engine

**Where it runs: in qits-workspaces' own JVM, in-process.** Not a step container, not `./mvnw`, not
`npm`. Three reasons, all measured:

- The workspaces runtime image carries `git-core` and `docker-ce-cli` — **no maven, no node.**
  `./mvnw versions:set` would download Maven 3.9.12 into the container on every integrate.
- `npm install --package-lock-only` is actively harmful here: every SPA's committed `.npmrc` pins
  `resolved` URLs, and the CI pipelines already `sed` ~700 of them between `localhost:8081` and the
  qits-net origin. Regenerating a lock inside the platform would commit a lockfile that no longer
  resolves on a developer's host. This is a documented trap, and the engine must not step in it.
- The edit surface is **tiny and exactly known**, so the toolchain buys nothing.

**The edit surface, measured across all 13 maven and 10 npm repos:**

```
maven   root pom      /project/version
        each module   /project/parent/version      <- modules declare NO <version> of their own
        inter-module  nothing                      <- version-less at use sites; ${project.version}
                                                      in the root's dependencyManagement
        => qits-ci, 5 modules: exactly 6 elements. Zero literal inter-module version strings.

npm     package.json        .version
        package-lock.json   .version
        package-lock.json   .packages[""].version
        => exactly 3 fields. npm ci fails hard (EUSAGE) if they disagree, and compares nothing else.
```

So "the version of a multi-module maven repo" is the reactor's single coordinate: one root
`<version>` plus each child's `<parent><version>`, which the poms duplicate literally *on purpose*
(qits-ci's AGENTS.md: a clone of this repo alone builds green). The duplication is the reason there
is no `<revision>` shortcut — and it is also why the edit is mechanical rather than clever.

**The splice primitive.** One technique, two formats: use a **streaming parser to locate character
offsets**, then replace the exact span in the original text. StAX (`XMLStreamReader.getLocation()`)
for poms, Jackson's `JsonParser` token locations for JSON. Never a DOM/tree round-trip — serializing
a parsed pom reformats the whole file and turns a one-line version bump into an unreviewable diff,
and rewriting `package-lock.json` through a tree would reorder and reflow thousands of lines. The
splice preserves formatting, comments, and key order absolutely, because it only ever touches the
bytes between two offsets. Both formats share the primitive, which is the part worth unit-testing
hardest.

**Detection and scope, ruled:**

- **`pom.xml` at the repo root ⇒ maven.** Bump the root plus every `<module>` transitively. Skip
  `.claude/worktrees/` (real, present in the tree today, and not part of any tracked build).
- **`package.json` at the repo root ⇒ npm.** Bump it, plus `package-lock.json` if present. Also bump
  any `projects/*/package.json` — the Angular library convention, and for the two pnpm repos that
  inner manifest is the *published* one and the real release gate. `pnpm-lock.yaml` has no version
  field to mirror; leave it alone.
- **Both ⇒ bump both, with the same version string.** Unreachable today (finding 4) and one `if`,
  with one test so the behaviour is defined rather than emergent.
- **Neither ⇒ still a release.** The version is computed from the clock regardless of stack; stack
  detection only decides which *files* render it. A repo with no version files gets the same
  `release($version): …` merge commit and no file edits. This keeps "integrate is the only flow into
  main" universal instead of carving out the stub repos, and it is coherent: **the commit is the
  release; the files are one stack's rendering of it.**

**The commit message**, verbatim to the requested shape:

```
release(2026.731.193059): teach the explorer to group runs by repository

Integrates workspace branch `explorer-grouping`.
```

Subject is `release(<version>): <summary>`, the summary taken from the request. Validated non-blank,
single-line, capped (72 is the conventional subject budget; the version scope costs ~24 of it, so
cap the summary at 100 and let it be the whole subject if it must). The body names the integrated
source branch — the merge's parents already record the graph, but the branch *name* does not survive
the merge otherwise, and it is what a human reads.

## The API

`POST /workspaces/api/workspaces/{id}/integrate` — a **new endpoint on `WorkspaceController`**, not
a widening of `merge`. `BranchController`'s own javadoc supplies the rule: things keyed by workspace
identity live on `/workspaces/{id}`, things keyed by branch name live on `/branches`. Integrate is
workspace-keyed. It also earns its own verb because it has a different response (a version, a sha),
different failure modes (conflict, non-fast-forward, stack-detection), and different semantics —
`merge` moves a ref, `integrate` performs a release.

```java
public record IntegrateRequest(@NotBlank @Size(max = 100) String summary) {
  public record Response(String version, String commitSha, String branch) {}
}
```

The target is not a parameter: **the target is always `main` by construction.** That is the feature.
The repo's default branch comes from `RepositoryLookup.require(repoId).mainBranch()`, which
qits-workspaces already fetches from qits-projects.

**The existing merge endpoints keep working, minus one case.** `POST /workspaces/{id}/merge` and
`POST /branches/merge` remain for merging into a *parent* branch (stacked workspaces), and are
**rejected with 409 when the target resolves to the repo's main branch**, with a message naming
`/integrate`. Without that, the "only flow into main" claim is false in the API even if it is true
at the git host — and the git host would then refuse the direct write anyway, producing a worse
error later instead of a clear one now.

**Synchronous.** The whole flow is a local merge, a few file edits and one push to a container on
the same network — seconds. The caller needs the version and the sha to say anything useful, a
conflict is a user-facing error that wants an immediate answer, and an async job would need a status
resource, a polling client and a place to put failures, all to save a second. The bounded push
timeout is what keeps "seconds" honest. `WorkspaceEventType.INTEGRATED` already exists in the enum
and is emitted on the existing SSE stream, so a UI that wants to react without holding the request
open already can.

**Retry semantics.** Integrate is **not idempotent by design** — each call stamps a new version from
the clock, which is correct: two integrates are two releases. Retry safety comes from the flow's
shape instead. A *failed* integrate left `main` untouched (the `--detach` property), so retrying is
clean. A *succeeded* integrate whose response was lost leaves the source branch already merged, so
the retry's preflight finds it is already an ancestor of `main` and returns **409 "already
integrated"** rather than producing an empty second release. The workspace's `INTEGRATED` status is
the durable record either way.

## The named follow-up: SoftwareRelease

Not built here, and specified precisely enough that this design does not foreclose it. After this
feature ships and the `libs/qits-eventstream` extraction settles, **the service that performs the
push gains the qits-eventstream dependency and publishes a `SoftwareRelease` event immediately after
a successful push**, payload `{projectId, repository, branch, version}` — where `branch` is the
*source* branch that was integrated. There is no target field: the target is always `main`.

Two consequences for the work in *this* plan, both cheap and both worth honouring now:

- **The pushing service is the natural publisher**, because only it knows that the push succeeded,
  atomically, with which version. Step 7 is the seam; nothing else in the platform can make that
  statement.
- **Keep the success point a clean publish seam.** Follow the `RunAnnouncer` precedent: a port
  declared in the domain module, implemented in the deployable, so the domain module stays bus-free
  and the extraction rule holds. Concretely: step 7's success should return a small result record
  through one method, not vanish into the middle of a larger one.

One gap to note without closing it: `RepositoryLookup.RepositoryView` is `(String id, String
mainBranch)` today and carries **no `projectId`**, so that payload field will need the view widened
when the event feature lands. Naming it here saves the discovery later.

## Decisions settled with the user (2026-07-31)

**1 — The version shape is `YYYY.MMDD.HHMMSS`** (`2026.731.193059`), as ruled: a real release in
both comparators, totally ordered, leading zeros impossible by construction.

**2 — The two published packages switch to CalVer on their first integrate.** One scheme, no
exceptions; the frozen `^0.0.4` pins are exactly the pressure the SoftwareRelease train exists
to relieve.

**3 — The dev-loop bypass is a TOKEN, not a well-known option** (the user's own design, replacing
the recommended permanent `qits.override`): `-o qits.token=<value>` against
`qits.repositories.git.push-token`, defaulting to unset, where unset disables all direct pushes
to the protected ref — the escape hatch exists only where a deployment deliberately configures
it (local and bootstrap scenarios set one; production may set none). The bypass section above is
revised accordingly, and Agents X, AB, AC carry the token in place of the retired option.

The original decision texts, for the reasoning record:

**⚖ 1 (as posed) — The canonical version shape.** The recommendation is `YYYY.MMDD.HHMMSS`
(`2026.731.193059`), ruled above on measured evidence. The literal requested form
`2026.07.31-193059` is not available at any price — it is invalid semver outright. But a *repaired*
dashed form is: `2026.7.31-t193059`, letter-prefixed so the morning case stays valid. It is more
readable, and it keeps the requested punctuation.

Its priced cost, measured: every version becomes a semver **prerelease**, so
`maxSatisfying(versions, '*')` returns `null`, a consumer's caret range stops matching the day after
it was written, and the same string sorts *before* a bare release in npm and *after* it in Maven. If
those consequences are acceptable because publishing is out of scope, the dashed form is a
legitimate choice and the change is one function, `VersionStamp.of(Instant)`, plus its tests. The
recommendation stands on the range and cross-stack behaviour, not on taste — but the shape of a
version string is a thing the user reads for years, so it should not be settled silently.

**⚖ 2 (as posed) — Do the two published packages switch to CalVer on their first integrate?**
`@qits/ui-components` is at `0.0.4` and `@qits/angular` at `0.0.1`, and these are the only real
versions in the tree — everything else is a `1.0.0-SNAPSHOT` or `0.0.0` placeholder. Integrating
either repo would stamp `2026.731.…` into the manifest that the *existing* publish-if-absent
pipeline reads, so the next green build publishes it. Nothing breaks: all eight SPAs pin
`^0.0.4`, which keeps resolving `0.0.4` — they would simply stop tracking the library until the
release train (which rewrites those pins mechanically) lands.

Recommendation: **include them** — one scheme, no exceptions, and the frozen ranges are exactly the
pressure that makes the release train worth building. The alternative is excluding
`projects/*/package.json` from the bump, which makes integrate a no-op for the two repos where a
version currently means something. Either way the choice should be deliberate, because it changes
the public version identity of two published packages.

**⚖ 3 (as posed, superseded by settled decision 3) — Is `qits.override` transitional or
permanent?** The mechanism is settled; this is about the
user's own workflow. Every document in this tree currently teaches humans and agents to
`git push …/artifacts/git/<repo> main`, and 22 of 26 submodules have never had a second branch. The
rollout keeps that working via `-o qits.override`. The open question is whether, once integrate
covers the workflow, direct-to-main stays available indefinitely as a documented escape hatch, or is
retired so that integrate is genuinely the only door.

Recommendation: **keep it, permanently, and measure it.** A platform whose own bootstrap cannot push
without a running workspaces service has a circular dependency at the worst possible moment, and the
INFO log makes the usage visible rather than assumed. But retiring it is a coherent stricter posture
and is a one-line default change, so it should be the user's call rather than an accident of what
was convenient during rollout.

## Workstreams (one Opus 5 agent each)

Continuing the platform's letter sequence. **A–W are burned** across the shipped features, so this
one starts at **X** and rolls over to the two-letter series — X, Y, Z, then AA, AB, AC.

Three start immediately and share nothing but the frozen contracts above: X is a different repo from
Y/Z, and AA is a different repo from both. Inside qits-workspaces the work is strictly sequential
(one repo, one agent at a time) — Y is split from Z anyway because Y is pure, has no I/O, and its
test suite is the part most worth writing without a service in the way.

**Contract note for all agents: the version format, the two push-option names, the request/response
shapes, and the commit-message format are frozen.** An agent that believes one is wrong reports
back; it does not adjust its side unilaterally.

### Agent X — the git host learns a protected ref (repo: `services/qits-artifacts`)

- `ProtectedRefHook implements PreReceiveHook` in `eu.wohlben.qits.githost`; registered in
  `GitHostRoutes.service(...)` alongside the existing post-receive registration. Protected ref =
  `repo.getFullBranch()`. Creates allowed; update/delete guarded; any guarded update refused
  unless `-o qits.release` (fast-forward only) or a matching `-o qits.token=<value>` accompanies
  it (settled decision 3: token compared against `qits.repositories.git.push-token`, default
  unset = nothing matches, empty never matches).
- `setAllowPushOptions(true)` on **both** `ReceivePack` instances — `service(...)` *and*
  `infoRefs(...)`. Missing the advertisement is the silent-failure mode.
- Config: `qits.repositories.git.protect-default-branch`, **default `false` this workstream**, and
  `qits.repositories.git.push-token` (no default); the per-repo override
  `[qits] protectDefaultBranch` read from the bare's config. Rejection messages name the
  integrate endpoint and say a push token is required (never echoing any configured value) — a
  refusal a human cannot act on is a worse bug than the accidental push.
- Tests: `GitHostTest` gains accept/refuse cases for the release option, the token (matching,
  wrong, absent, configured-empty, unconfigured), create-vs-update,
  non-ff, delete, and the per-repo override. Extend `PackagedProcessIT` — the repo's AGENTS.md is
  explicit that for anything JGit-adjacent the *native* IT, not `mvn verify`, is the gate, and JGit
  has regressed natively before with a blanket 404.
- **Trap, specific to this agent:** the change is delivered by a push to the very service that
  would refuse it. Default-off is what makes that safe — verify the property is off in the shipped
  defaults before pushing, not after.
- Push both remotes; pipeline redeploys qits-artifacts; expect one self-redeploy cutover blip, and
  the lossy-intake trap applies (no run row after the push ⇒ replay
  `POST /ci/api/events/post-receive`).

### Agent Y — the version stamp and the bump engine (repo: `services/qits-workspaces`, domain)

Pure, no I/O beyond reading and writing files under a given directory. No service wiring.

- `VersionStamp.of(Instant)` → the integer-arithmetic formula. Tests: midnight, 09:30:59, Jan 1,
  Dec 31 23:59:59, and a **property test asserting monotonicity** over a year of instants — plus an
  explicit assertion that no output contains a leading-zero identifier, which is the bug this
  format exists to make impossible.
- The splice primitive: StAX-located offsets for XML, Jackson-located offsets for JSON, replacing
  exact spans in the original text. Tests assert **byte-identical output except the version span** —
  formatting, comments and key order all preserved. This is the highest-value suite in the feature.
- `StackDetector` + the two bumpers, against real fixtures copied from this tree: a 5-module maven
  reactor (root `<version>` + 5 `<parent><version>`, and an assertion that **no other** version
  element moved), an SPA (`package.json` + both `package-lock.json` fields, then a check that
  `npm ci`'s agreement rule holds), a pnpm library repo (`projects/<lib>/package.json`, lock
  untouched), a both-stacks repo, and a no-stack repo.
- `./mvnw verify` green. **Commit on main; do not push** — Agent Z pushes the repo once, one
  pipeline run rather than two.

### Agent Z — the integrate flow and its endpoint (repo: `services/qits-workspaces`, after Y)

- The nine-step flow exactly as diagrammed: repo lease, `merge-tree` preflight, `--detach` worktree,
  `--no-ff --no-commit` merge, stamp, bump (Agent Y's engine), one commit, push with
  `-o qits.release`, cleanup in a `finally`.
- Fix the three inherited edges: prune before add, worktree name from the workspace row id, and a
  **timeout overload on `GitExecutor`** used for the push.
- Conflicts → 409 with the file list (not today's 500). Non-fast-forward → 409 "main moved, retry".
  Already-an-ancestor → 409 "already integrated".
- `POST /workspaces/api/workspaces/{id}/integrate`; the 409 on `merge`/`branches/merge` when the
  target resolves to main; `INTEGRATED` status and event; branch cleanup as today.
- New config `qits.artifacts.url` (scheme+host+port, no path — the platform shape) for the push
  target. Keep step 7's success a single-method seam for the future publisher.
- Tests: `@QuarkusTest` against a real bare origin via the existing `TestOrigin` fixture — happy
  path asserting **one commit with two parents carrying both the merge and the bump**; conflict
  leaves `main` byte-identical; a concurrent-integrate test asserting the loser gets 409 and `main`
  is one of the two, never a mix. Regenerate and commit `docs/openapi.yml`
  (`OpenApiSchemaExportTest`) — the repo requires it on any REST change.
- `./mvnw verify` green; push both remotes; pipeline redeploys qits-workspaces. Lossy-intake and
  self-redeploy traps apply.

### Agent AA — the Integrate UI (repo: `frontends/qits-spa-workspaces`, parallel from the start)

Needs only the frozen request/response shapes; no dependency on X, Y or Z landing.

- The SPA is a bare shell today — `app.ts` is `'<router-outlet />'` and `routes[0].children` is
  empty with a comment saying the pages arrive in that slot. So this is the first real page: a
  workspace list for a repository, and an Integrate action taking the summary text.
- Follow the established client pattern from qits-spa-ci/qits-spa-cd: `QITS_API_BASE` empty-string
  token (same-origin, so the session cookie reaches the service; no CORS, no machine token), an
  `@Injectable` api class per service, DTOs in `src/app/api/dto.ts`, `HttpClient` on the fetch
  backend, `HttpTestingController` specs.
- Surface the failure modes as distinct states rather than one red box — conflict (with the file
  list), "main moved, retry", and "already integrated" are three different things a user does three
  different things about. On success, show the version and the commit sha.
- **Trap:** Angular 21 only. The host's node is 22.22.0 and Angular CLI 22 requires ≥22.22.3; the
  SPAs stay on 21 until that moves.
- Push both remotes. Note the webui gitlink loop: this repo is also checked out inside
  `services/qits-workspaces/service/src/main/webui`, and that gitlink is advanced by a separate
  commit in the service repo.

### Agent AB — deployment wiring and the teachable bypass (superproject + live, after X and Z)

- `qits-local-up.sh`: `qits.cd.run-args.qits-workspaces` gains `-e QITS_ARTIFACTS_URL=…`; the
  bootstrap generates (or fixes) a local push token, injects it into qits-artifacts' run-args
  (`-e QITS_REPOSITORIES_GIT_PUSH_TOKEN=…`), and the push loop (line ~484) gains
  `-o qits.token=$TOKEN`. Note the seeding push needs nothing — creates are allowed by design.
- The same values into the **live** `qits-cd-config` volume. **Trap:** cd caches config at boot, so
  restart or rewrite before the next deploy; and the local-up recreate branch kills the cd-managed
  core — hand core off to compose before touching membership.
- Docs that currently teach direct main pushes — `local-platform.md`, `handoff.md`, the affected
  READMEs — learn integrate as the normal path and the configured `-o qits.token=…` as the
  deployment-controlled escape hatch (unset token = no escape hatch, per settled decision 3). This is
  the workstream that makes the rollout survivable; the code without it is a trap for the next
  person.
- Superproject edit left uncommitted for review, per house practice.

### Agent AC — flip protection on, and prove it live (after AB)

- Flip `qits.repositories.git.protect-default-branch` to `true` and redeploy qits-artifacts.
- Prove, in order, on the live platform: (1) a bare `git push … main` is **refused** with a message
  naming integrate and the token requirement; (2) `-o qits.token=<the configured value>` is
  **accepted** and logged, a wrong value is refused, and — on a scratch host config with the
  token UNSET — no value at all is accepted (the default-locked claim, proven not assumed);
  (3) an integrate through the API produces one merge commit whose message is
  `release(<version>): …`, whose parents are two, and whose tree carries the bumped version files;
  (4) that push produced a **normal CI run** in the explorer — the continuity claim, verified rather
  than assumed; (5) a second integrate of an already-integrated workspace returns 409.
- Pick the guinea pig deliberately: a repo with a real stack and low blast radius.
  `qits-spa-workspaces` is the established canary and exercises the npm path; add one maven repo so
  both bumpers are proven live. Do **not** pick qits-artifacts (it serves the push that would test
  it) or qits-workspaces (it performs it).
- Report the measured version strings — this is the first time the format exists outside a test.

**Sequencing: X ∥ Y ∥ AA → Z (after Y) → AB (after X and Z) → AC.** Finer splits were considered
and rejected: the maven and npm bumpers are separable in principle but share the splice primitive
and one pom, so two agents would collide for no gain; and the integrate flow's git mechanics and its
endpoint are one change wearing two hats.

## Out of scope, named so nobody drifts into it

- **Producing or publishing any artifact.** A release is a version bump and a merge to `main`. The
  image publish that already happens on a green `main` build keeps happening, unchanged and
  unaware; no registry push, no npm publish, no `mvn deploy` is added by this feature.
- **`SoftwareRelease`** — specified above as a named follow-up, deliberately not built. This feature
  only keeps the seam clean.
- Tags, changelogs, release notes, GitHub releases, and any rollback or revert-a-release flow.
- Review, approval, or PR mechanics before integrating. Integrate is the door; who may open it is
  today's answer (the gateway session), unchanged.
- Protection of any ref other than the repo's default branch, signed pushes, and per-user push
  authorization — the seatbelt is deliberately not an authorization system.
- Cross-service distributed locking. Git's fast-forward ref update is the CAS; a qits-projects
  `pull` racing an integrate is resolved by the push being rejected, not by a shared lock.
- Branch protection on the GitHub remotes. This feature governs the platform's own git host; the
  GitHub mirrors keep their current behaviour.
- The release train's consumer-side bump (a released library walking into its consumers) — that
  waits on `SoftwareRelease` and belongs to the event-trigger feature that already named it.
