# Splitting the release event: SCMRelease, then SoftwareRelease

Status: **SHIPPED AND OBSERVED (2026-08-01)** — supersedes `software-release-event-plan.md`
(SHIPPED this morning) and amends `release-flow-plan.md` and `release-train-hops-plan.md`. Every
decision below is settled, the three scale-marked ones included; the measured chain is the next
section and the design that produced it follows unchanged.

## What it does, measured

Two canaries, both live, both walked end to end from a doc-line commit. Nothing below is inferred:
every id, version and sha was read from an API after the fact.

**The npm chain** — `libs/qits-spa-ui-components`, one workspace, one README commit, one release:

    POST /workspaces/{1701}/release  →  200 {2026.801.85149, 21655ba4, task/ao-npm-proof}
      release commit 21655ba4, two parents: main 1964a787 + task ab854a1a
      tag object 69f6181f = refs/tags/2026.801.85149, annotated, peels to 21655ba4,
        message "release(2026.801.85149): say what each pipeline publishes"
      → SCMRelease c5edabb5  {qits-spa-ui-components, 2026.801.85149, task/ao-npm-proof}
        → release run 9e62191e  EVENT, ci-event-release.yml, triggerEventId c5edabb5
          checks out the tag, builds, publishes @qits/ui-components@2026.801.85149 with tag latest
          dist-tags {latest: 2026.801.85149, main: 2026.801.85149-main.g21655ba}
          → BuildSuccessful 99c733d8   parent c5edabb5
          → SoftwareRelease 0bdbe98d   parent c5edabb5
             {qits-spa-ui-components, 2026.801.85149, npm, "@qits/ui-components"}
            → bump run 5d42b91f  EVENT on qits-spa-home, ci-event-upstream-ui-components.yml,
              triggerEventId 0bdbe98d → force-push maintenance/qits-spa-ui-components @ 9e8666cc,
              pin ^2026.801.85149
              → ONE run e55d9131, TWO steps — tests SUCCESS, release SUCCESS
                "released 2026.801.85249 as dd021e83 from maintenance/qits-spa-ui-components"
                → SCMRelease 8e1520bf  {qits-spa-home, 2026.801.85249}
                   tag object f169542a = refs/tags/2026.801.85249 on spa-home, peels to dd021e83
                  → NOTHING. spa-home has no release pipeline, so no SoftwareRelease, so no
                    consumer wakes. `?parentId=8e1520bf` is empty.

Elapsed: 60 seconds, release call to the last event.

**The docker chain** — `services/qits-stt`, same shape, no consumer:

    POST /workspaces/{1702}/release  →  200 {2026.801.85448, ccd55834, task/ao-docker-proof}
      tag object 7ec49abb = refs/tags/2026.801.85448, annotated, peels to ccd55834
      → SCMRelease 7bb9fc99
        → release run df62403a  EVENT, ci-event-release.yml, triggerEventId 7bb9fc99
          HEAD /v2/qits/qits-stt/manifests/2026.801.85448 → 200
          → BuildSuccessful 8ab8faf4   parent 7bb9fc99
          → SoftwareRelease f99998d3   parent 7bb9fc99
             {qits-stt, 2026.801.85448, docker, "qits/qits-stt"}
            → NOTHING. No repository declares a trigger on it.
      and beside it, unchanged: post-receive run 02eef2e6 on the release commit pushed
      qits/qits-stt:ccd55834 and qits-cd deployment cce9225a went ACTIVE. The version tag is a
      new coordinate beside the sha, not a replacement for it.

**The causation shape is a fork, not a line.** A release pipeline's green run yields **N+1**
children of one `SCMRelease`: one `BuildSuccessful` plus one `SoftwareRelease` per declared
artifact, all siblings, all at the run's finish instant. `?parentId=<SCMRelease>` is therefore the
whole answer to "what did this release produce".

**The train now stops one event earlier in kind.** It used to stop at a repository that matched
nothing. It stops at a repository with **no release pipeline** — the artifact statement is never
made, so there is nothing to match. Same halt, stated in the vocabulary of publishing rather than
of subscribing.

**Native reflection held on the first real emission.** `SoftwareRelease` had never been serialized
by the deployed qits-ci binary before `0bdbe98d`; `bus/EventWireReflection` had it registered and
the payload came out with all four fields and no `eventId`. That was the one residual risk in the
whole rollout and it is closed.

### Rollout, as executed

All four steps of the plan below ran in order, over about four hours:

1. Trigger files pushed while inert — `qits-spa-ui-components` `1964a78`, `qits-stt` `6398740` (AN).
2. Outbox drained; it was empty at cutover (AL).
3. qits-workspaces `efe5acf` deployed — the rename, the tag dance, the 409 (AL). qits-artifacts
   `a4fae38` (AK) and qits-ci `97a1f0d` (AM) landed ahead of it.
4. qits-events `298936d` — `V4__delete_old_software_release.sql`, deleting the three rows that
   carried the old meaning (AO). One of them was the parent of a surviving `BuildSuccessful`; that
   edge dangles on purpose, and the reader takes an unresolvable parent as a chain start.

### The uniqueness guarantee, and what AL found about it

`VERSION_ALREADY_RELEASED` is the 409 a release gets when the version's tag already exists — added
to the reason enum and to `api/ApiError`, and deliberately **not** `PUSH_REJECTED`: it is
retryable, and a second later it simply works. It fires from either end, because `git tag -a` in the
shared ref store refuses the name before the flow moves anything, and the non-forced push covers a
writer that arrives later.

⚖3 asked whether the tag becomes that guarantee. It does — and AL found the case is **reachable,
not theoretical**. The plan's own reachability estimate below ("comfortably over a second") holds
for a real service and fails for a small one: `ReleaseControllerTest`'s two concurrent releases
stamp one version on most runs, because the lease runs them back to back and a release of a small
repository is well under a second. The test was renamed to say so —
`twoConcurrentReleasesAreSerializedAndOnlyTheClockCanRefuseOne` — and now asserts the pair of
outcomes (at least one lands; any refusal is `VERSION_ALREADY_RELEASED`) instead of "both land",
which is what it asserted before the tag existed.

## The flaw, and why the live hop did not catch it

`SoftwareRelease` fires the instant the release *push* is accepted. It therefore announces "source
control has this version" while every consumer reads it as "the package exists and I can install
it". Those are different moments and the gap between them is an upstream build.

This morning's release-train hop worked only because the upstream CI publish happened to land
before the downstream bump step ran `npm ci`. That was timing, not design. The train's own record
(`release-train-hops-plan.md`) reads as a success story, which is exactly what makes the race easy
to reintroduce — so it is recorded here rather than quietly patched there.

## The redesign

Two events, each meaning one thing.

**`SCMRelease`** — published by qits-workspaces the moment the release push is accepted. Same
payload as today's `SoftwareRelease` (`{projectId, repository, branch, version}`). It means: source
control has this release. It does not mean anything is published.

**`SoftwareRelease`** — published by qits-ci when a repository's **release pipeline** goes green.
It means: this artifact is in qits-artifacts and you can consume it. Its payload gains the **exact
package name** and the **package type**, and it is emitted **once per artifact** — a repo that
publishes three artifacts emits three events.

Between them sits the release pipeline, which each repository owns: check out the released tag,
build, publish. The framework never learns how to publish anything.

Downstream bump pipelines keep triggering on `SoftwareRelease`. Its meaning is now true, so the
race is gone by construction rather than by luck.

## What exists, measured (not assumed)

Seven findings reshaped this plan. Each was read at a cited line or run against the live platform.

**1. A tag cannot reach CI today, and it dies in one line.**
`CiPostReceiveNotifier.java:59-71` skips every command whose ref does not start with `refs/heads/`.
The intake wire has no room for one either — `:78-81` posts exactly
`{repoId, branch, oldSha, newSha}`, where `branch` is already the short name. And if a tag string
did arrive, qits-ci would insert a run row *before* any config lookup, then build the refspec
`+refs/heads/refs/tags/v1:…`, fail the fetch with exit 128, and delete the row: **a transient
QUEUED row and an invisible discard**.

Trap for whoever touches it: the prefix strip and the filter are one mechanism. Naively removing
the check turns `"refs/tags/v1".substring(11)` into `"1"`.

**2. `ProtectedRefHook` lets every tag through**, annotated or lightweight, create, update or
delete, with or without a push option (`:129-133`; the guarded ref is `repo.getFullBranch()`,
constrained to `refs/heads/*`). One residual unknown: **no test in qits-artifacts pushes a tag**,
so JGit's acceptance is inferred from defaults. One case in the existing `GitHostFixture` settles
it, and it is the first thing to run.

**3. The obvious way to create the tag silently does nothing.** `prepareWorktree` runs
`git worktree add --detach` **on the bare origin**, and qits-workspaces and qits-artifacts mount
the same `qits-repositories` volume. A linked worktree shares the common ref store, so `git tag -a`
inside it writes `refs/tags/…` **straight into the served bare with no push at all** — the
subsequent push reports `[up to date]` and generates **zero ReceiveCommands**. Measured on the
exact topology.

It also breaks the flow's stated safety property — "steps 2–6 move no ref anywhere" — because a
failed push now leaves the tag behind, and the `finally` only removes the worktree.

The dance that works: `git tag -a` → capture the tag-object sha → `git tag -d` (the object
survives) → push `HEAD:refs/heads/main` and `<tagobj>:refs/tags/<version>` in **one** push. One
push is one receive-pack, so both commands ride one pre-receive and one post-receive.

**4. The framework never knew how to publish, so "tooling agnostic" costs zero.** All 22 pipeline
files were read: every publish command already lives in the repo's own `.config/qits/*.yml`. Nine
repos push docker (byte-identically, `:$QITS_CI_SHA`), two publish npm behind a
`npm view || npm publish` guard, eleven publish nothing. Grepping qits-ci and the daemon for
`docker push` / `npm publish` returns two comments. This part of the redesign is already true.

**5. `QITS_EVENT_*` field projection does not exist.** A step gets exactly four variables —
`QITS_EVENT_ID`, `QITS_EVENT_NAME`, `QITS_EVENT_OCCURRED_AT`, `QITS_EVENT_PAYLOAD` — and the
payload is one raw JSON string the step parses itself, as the live trigger file already does. A
payload field does **not** become an env var. Plan around the raw string; do not design a
projection.

**6. The rename is cheaper than it looks.** The wire name is the class name
(`QitsEvent.signature()` returns `getClass().getSimpleName()`), so a class rename is a wire rename.
But **qits-ci needs no code change and no redeploy** — its listener subscribes to `"*"` and filters
locally — and trigger YAML is read from head-of-main at event-arrival time, so changing a trigger
is a **push, not a deploy**. The three existing rows delete cleanly: `parentId` is deliberately not
a foreign key, and the reader treats an unresolvable parent as the start of a chain.

**7. npm's `latest` dist-tag is an unguarded last-write-wins upsert.** `moveTag` does no ordering
check, and a publish with no explicit tag defaults to `latest`. **A bare `npm publish` of a
`-main.g<sha>` prerelease would move `latest` backwards permanently**, and every consumer
installing the package without a range would get a main build. This is the one finding that
threatens the chosen suffix scheme directly.

### Smaller facts the implementation trips over

- **Annotated tags are not free downstream.** The ref resolves to a tag object, not a commit.
  Peeling is free for `show`, `merge-base`, `cat-file -e <sha>^{commit}` and `checkout --detach`,
  but breaks anywhere a sha is stored as a commit id — `CiRun.commitSha` → `BuildSuccessful` →
  `ImageRefs` builds `…:<sha>` while the pipeline tagged the image `$QITS_CI_SHA`, so a mismatch
  surfaces as `IMAGE_MISSING` far from its cause. **Peel at the git-host boundary** if tags ever
  drive runs.
- **A step can already check out a tag with no platform change.** `git fetch origin
  refs/tags/X:refs/tags/X && git checkout --detach X` — verified, lands on the peeled commit.
- **`branches:` has no concept of tags** and can never apply to an event-triggered run — it is a
  parse error in a `ci-event-*.yml`. (It shipped as `5a322d5`, not `6922da6`; the latter is a
  comment-only bump.)
- **Post-hoc verification of a declaration is possible.** Docker:
  `HEAD /v2/<repo>/<image>/manifests/<tag>` gives 200 present / 404 absent. npm: no per-version
  route, so `GET /artifacts/npm/npm/<pkg>` and look for the version key.
- **The outbox persists the event name as a string**, so a row enqueued before the cutover drains
  under the old name afterwards. Drain or clear it as part of the break.
- **`@` is a reserved YAML indicator** and must be quoted in a matcher: `exact: "@qits/ui-components"`.
- **No registry-qualified docker ref is portable** — the registry host is `qits-artifacts:8080` in a
  step container and `localhost:8081` for qits-ci and qits-cd, and an OCI reference cannot carry a
  path prefix. Put unqualified `qits/<application>` plus the tag in the payload.
- **qits-events' idempotency comparison includes `parentId`**, so a deterministic event id must also
  derive `occurredAt` or a replay is a 400.

## Settled by the user

- Artifacts are **declared** in the release pipeline file, not emitted by the step. The reason is
  decisive and worth keeping: a declaration can be **statically analysed into a cross-repo
  dependency DAG without running anything**, which is what the parked cycle-detection work needs.
  This also routes around a hard constraint — the daemon's return channel is only `StepChunk` and
  `StepFinished`, `ci_step.output` holds a rolling 64 KiB tail, and a stdout sentinel is explicitly
  forbidden by design, so an emit-based scheme would have been a two-repo protocol change.
- A repo with **no release pipeline does nothing**. No `SoftwareRelease`. The train stops. This is
  already the behaviour: an unmatched event is a bare `continue` with no log.
- Post-receive **keeps publishing**, suffixed `<lastReleasedVersion>-main.g<sha>`. The base stays
  the last released version; a fresh build-time calver was rejected. The `g` prefix is load-bearing
  — it guarantees the identifier is never purely numeric, so semver's leading-zero rule can never
  fire on an all-digit sha. Verified valid and correctly ordered for every sha shape.
- **No further discriminator** beyond the sha; a rare build error is preferred to a more elaborate
  scheme.
- Migrations may be **destructive** — there is no production. The three existing rows are deleted.
- **Maven is deferred.** The release pipeline of a maven project builds and pushes a docker image
  and nothing else. Nothing here forecloses adding it: `RepositoryType` is the seam, and adding a
  constant plus a route is an extension, not a reopening.
- **GC is out of scope**, with its own reminder. The intended rule — last build per branch while the
  branch exists — makes main prereleases ephemeral, which removes the unbounded-growth objection to
  keeping post-receive publishing.

## The decisions ⚖

All three went the way the recommendation pointed, and all three are now shipped: **⚖1 dropped** —
tag pushes never became a CI trigger, and qits-artifacts and qits-ci needed no triggering change;
**⚖2 both halves built** — the pipelines carry an explicit `--tag main` on the prerelease publish
*and* qits-artifacts refuses a whole publish with 403 when `latest` would move backwards (AK,
`a4fae38`); **⚖3 yes** — the tag is the version-uniqueness guarantee, see the section above. The
arguments are kept below because each one prices an option that was declined.

**⚖1 — drop the tag-push-as-CI-trigger half?** The original sketch had tag pushes as a new trigger
*and* the SCM-release event as a trigger. Finding 1 says the first needs real plumbing in two
services: relax the `R_HEADS` filter, change the intake wire format (they move together), peel
annotated tags before the sha leaves, decide whether two commands in one push become one intake
call or two, and teach `GitConfigFetcher` a tag refspec. The second **works today and costs
nothing**, and a step can fetch and check out the tag itself with one `git fetch`.

*Recommendation: drop it.* The event path is already proven end to end — a live event-triggered run
exists with `triggerType: EVENT` and `triggerEventName: SoftwareRelease`. Keeping the tag half buys
a **second CI run for the same release** and two services' worth of new wire format. With it
dropped, **qits-artifacts and qits-ci need no change at all**, and the tag becomes purely what it is
good at: an immutable checkout target.

**⚖2 — how is `latest` protected?** Finding 7 is a live foot-gun the moment main builds start
publishing prereleases. Two fixes, not exclusive: the pipeline publishes with an explicit
`--tag main` (correct npm usage, but it is convention in a file nobody lints — the same weakness as
the existing publish guard), and/or the registry refuses to move `latest` to a version sorting below
the one it names (enforcement, and it protects every future pipeline).
*Recommendation: both, and the registry rule is the one to build if only one gets done.*

**⚖3 — does the tag become the version-uniqueness guarantee?** `VersionStamp` documents that two
stamps in the same second cannot collide because the push is a fast-forward compare-and-swap. **That
reasoning does not hold**: the repository lease is held across the whole land operation including
the push, so two releases are sequential, the second builds its worktree from the first's commit,
and its push is a clean fast-forward — the compare-and-swap never fires. Nothing anywhere checks
version uniqueness. Today that yields two commits stamped the same version; **under this redesign
the second release's pipeline finds the version already published, skips, goes green, and emits a
`SoftwareRelease` for an artifact it never published.**

Reachability is very low — a release does worktree-add, merge, bump, commit and an HTTP push,
comfortably over a second. But it is unguarded, and the misleading comment is what stops anyone
checking.
*Recommendation: yes.* A non-forced tag create fails when the ref exists, so the tag we are adding
anyway turns the missing uniqueness constraint into a property of the SCM, for free, failing in the
direction already accepted. Fix the comment in the same change.

## The plumbing, per repo

Assuming ⚖1 lands as recommended:

- **qits-artifacts — nothing**, beyond one `GitHostFixture` test proving JGit accepts a tag push.
  That test is the first thing to run, because a negative answer reopens ⚖1.
- **qits-ci — nothing** for triggering. It gains the `SoftwareRelease` fan-out publish (see below).
- **qits-workspaces — moderate, two sharp edges.** Rename the event class; add the tag via the
  `tag -a` / capture / `tag -d` / push-by-sha dance; the `finally` must clean up a tag that a failed
  push left behind; and the flow's "moves no ref before the push" property needs its comment
  corrected along with `VersionStamp`'s.
- **The publish seam.** `BuildSuccessfulAnnouncer` publishes from `onRunSucceeded`, and the port
  carries six values — **no version, no tag, and `configPath` is not passed through**. So qits-ci
  must learn which runs are release pipelines and what they declared. The triggering event's payload
  *is* available in memory to completion (captured in the worker closure) but is on no column, and
  event-triggered QUEUED rows are deleted at restart rather than requeued. Fan-out itself is safe:
  the outbox enqueues one row per event in its own transaction, and `CausationScope.current()` is a
  non-consuming read, so N siblings under one parent already works.
- **Each publishing repo (9 docker + 2 npm) — cheap.** A `ci-release.yml` with the artifact
  declaration and the publish lines moved into it, plus the `--tag main` fix on the post-receive
  publish. Zero framework change.
- **The 11 non-publishing repos — nothing.**
- **qits-events — one V4 migration** deleting three rows.

## Rollout — done, in this order

Order matters and a mistake is unrecoverable: the bus is at-most-once with no catch-up or replay,
so an event emitted into a window where nothing consumes it is simply lost and looks like a train
that quietly did not roll.

1. Push the trigger-file change (a push, not a deploy — trigger YAML is read from head-of-main at
   event-arrival time).
2. Drain or clear the eventstream outbox volumes, so no pre-cutover row drains under the old name.
3. Deploy the renamed qits-workspaces.
4. Run the V4 migration.

Two canaries carried steps 1–3, not the whole fleet: one npm publisher and one docker publisher.
Fanning the release pipeline out to the remaining eight docker publishers and to
`qits-integrations-angular` is mechanical and is the next piece of work — it needs no design and no
framework change, only one file per repository with the publish lines moved into it.

## Out of scope, named so it stays out

- **Maven**, deferred by the user and thinkable in parallel.
- **GC and retention**, which has its own reminder.
- **Tag pushes as a CI trigger**, per ⚖1 — recorded as a real option that was priced and declined,
  not as an oversight.
- **Rewriting the hops plan's success story.** It shipped and it worked; it also masked this race.
  Both facts stay on the record.
