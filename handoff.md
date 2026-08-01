# Handoff: 2026-08-01 evening → next session

Start here. What shipped today, how to verify it landed, and where the work picks up. The map, not
the territory — reasoning lives in the plan docs named inline.

This morning's handoff is in git history (`git show 9bbee7c:handoff.md`): the integrate/release
split, the release event, the finished-runs rail, and the release train's first live hop. All of it
still stands, with one rename running through it — see below.

## The headline: the release event split in two

`scm-release-split-plan.md`, **SHIPPED AND OBSERVED**. The plan doc carries the full measured chain
with every id; this is the shape.

One event used to fire when the release *push* was accepted and every consumer read it as "the
package exists". Between those two statements sits a whole build. This morning's hop worked on
timing, not design. Now there are two events, each meaning one thing:

- **`SCMRelease`** — qits-workspaces, the instant the push is accepted. Payload unchanged
  (`{projectId, repository, branch, version}`). It means source control has this version.
- **`SoftwareRelease`** — qits-ci, when a repository's **release pipeline** goes green. Payload is
  `{repository, version, packageType, packageName}` and it is emitted **once per declared
  artifact**. It means the artifact is in qits-artifacts and you can install it.

Between them sits a release pipeline each repository owns: check out the released tag, build,
publish. The framework still knows nothing about publishing — `artifacts:` in the pipeline file is a
**declaration**, and qits-ci announces on the strength of it.

Five workstreams:

- **AK** qits-artifacts `a4fae38` — the tag mechanics measured on the real host (JGit accepts an
  annotated tag push), and the **`latest` guard**: a whole publish is refused **403** when it would
  move `latest` backwards. That closes the foot-gun a `-main.g<sha>` prerelease would otherwise fire.
  (Head is now `7e91db0e`, the styling fix on top.)
- **AM** qits-ci `97a1f0d` — `artifacts:` in a pipeline file, and the per-artifact
  `SoftwareRelease` fan-out on a green declared event-run, `parentId` = the triggering event.
- **AL** qits-workspaces `efe5acf` — the class rename (the wire name *is* the class name), the
  annotated tag pushed **atomically with `main`**, and **409 `VERSION_ALREADY_RELEASED`** when the
  version's tag already exists.
- **AN** — the two canary release pipelines, landed inert first because the bus has no replay:
  `libs/qits-spa-ui-components` `1964a78` and `services/qits-stt` `6398740`. Post-receive now
  publishes `<version>-main.g<sha7>` with an explicit `--tag main`.
- **AO** (this pass) — qits-events `298936d`, the V4 migration deleting the three rows that carried
  the old meaning, then the live proof of both chains.

### The proof, in one paragraph each

**npm.** A doc commit on `qits-spa-ui-components`, released as `2026.801.85149` (`21655ba4`).
Annotated tag `refs/tags/2026.801.85149` (object `69f6181f`) peels to the release commit and carries
its subject. `SCMRelease c5edabb5` → release run `9e62191e` (`EVENT`,
`ci-event-release.yml`, `triggerEventId c5edabb5`) checks out the tag and publishes; dist-tags end at
`{latest: 2026.801.85149, main: 2026.801.85149-main.g21655ba}` — **`latest` moved forward**. The run
yields two siblings under the same parent: `BuildSuccessful 99c733d8` and
`SoftwareRelease 0bdbe98d`. spa-home's bump trigger (now on `SoftwareRelease`, matching
`repository`) fires → run `5d42b91f` → force-push `maintenance/qits-spa-ui-components` `9e8666cc`
→ ONE run `e55d9131` with tests + release → spa-home releases `2026.801.85249` (`dd021e83`, tagged).
spa-home has no release pipeline, so **no `SoftwareRelease(qits-spa-home)`** and nothing wakes.
60 seconds, release call to last event.

**docker.** Same on `qits-stt`: `2026.801.85448` (`ccd55834`), tag object `7ec49abb`,
`SCMRelease 7bb9fc99` → release run `df62403a` →
`HEAD /v2/qits/qits-stt/manifests/2026.801.85448` = **200**, and
`SoftwareRelease f99998d3 {docker, "qits/qits-stt"}`. Beside it, unchanged: the ordinary
post-receive run `02eef2e6` pushed `qits/qits-stt:ccd55834` and deployment `cce9225a` went ACTIVE.
No repository consumes stt's artifact, so the train stops there.

**The one thing that could have broken and did not**: `SoftwareRelease` had never been serialized by
the deployed qits-ci **binary**. `bus/EventWireReflection` had it registered; the first real emission
came out whole. A JVM suite cannot see that class of defect, so it was open until this run.

### What the split changes for a reader of the old docs

- The event AJ and AG observed as `SoftwareRelease` is `SCMRelease` now. `release-flow-plan.md`,
  `release-train-hops-plan.md` and `software-release-event-plan.md` all pre-date the rename; the
  split plan says so and they were not rewritten (their success stories are true and also masked the
  race — both facts stay on the record).
- **The train stops one event earlier in kind.** It used to stop at a repository that matched
  nothing. It stops at a repository with **no release pipeline**: the artifact statement is never
  made, so there is nothing to match.
- **Causation is a fork.** `?parentId=<SCMRelease id>` returns `N+1` children — one
  `BuildSuccessful` plus one `SoftwareRelease` per declared artifact — all at the run's finish
  instant. That query is the whole answer to "what did this release produce".

## Also shipped: the SPAs stop rendering in Times New Roman

Four SPAs carried the Angular scaffold's `styles.css` with **zero rules** in it, so they inherited no
platform typography at all — `qits-spa-artifacts` `1e85926`, `qits-spa-events` `225b7df`,
`qits-spa-observability` `bea5f2f`, `qits-spa-projects` `84691cd`. Fixed by taking the global
stylesheet the other four already had; **all eight are uniform now**. Each rode into its service on
the gitlink.

The related fix was **recommended and deliberately parked**: `index.html` is served
`immutable, max-age=86400` by every SPA, so a returning browser gets a stale page after each deploy
until a hard reload. Doing it per service is a seven-repo rollout; doing it **at the gateway** is one
change and covers every SPA at once. That is the recommendation and nobody has taken it.
**Until it is done, hard-reload before judging any SPA deploy.**

## Next up

Nothing is half-finished. The queue, in order of how ready each item is:

- **AP — fan the release pipelines out.** The two canaries proved the shape; the rest is mechanical
  and needs no design: **8 more docker publishers plus `qits-integrations-angular`** (the second npm
  publisher). One `.config/qits/ci-event-release.yml` per repository, with the publish lines moved
  out of `ci-post-receive.yml` and an `artifacts:` declaration that is **true** — qits-ci cannot
  check it. Note the single run worker: a fan-out release is serialized, not parallel.
- **The decision docs, still uncommitted and undecided** — `workspace-detail-plan.md`,
  `workspace-detail-spec.md`, `artifacts-explorer-plan.md`, `workspace-overview-ux.md`. They sit
  untracked in the superproject working tree and want a decision before they want an implementer.
- **The gateway `index.html` cache header** — see above. One change, seven SPAs' worth of benefit,
  and it is user-facing.
- **Typography tokens in ui-components.** The styling fix copied a stylesheet into four repos;
  the durable form is tokens the library owns and every SPA imports.
- **Tag GC.** Releases now create a permanent annotated tag per version on top of the per-sha images
  and the `-main.g<sha>` prereleases. The intended retention rule (last build per branch while the
  branch exists) was written for images; tags were not in scope and now exist.
- **Docker release-step idempotency.** The npm release pipeline guards with
  `npm view … || publish`, so a redelivered event costs seconds and goes green. The docker one has
  **no such guard**: it would rebuild and re-push the same tag, which the registry accepts. Decide
  whether that is fine (it is a rebuild of an immutable commit) or wants a manifest probe first.

## Parked follow-ups (deliberate, not forgotten)

- **The other six SPAs' train files** — still a fan-out awaiting the user's go. Seven bump runs,
  seven maintenance pushes and seven releases on one serialized worker.
- **`qits-spa-workspaces` is still on the old trigger.** Its
  `.config/qits/ci-event-upstream-ui-components.yml` fires on `BuildSuccessful` from
  qits-spa-ui-components, so it woke **three times** today for builds that were not releases (runs
  `09849e5f`, `78e62984`, `94a2cbb1`) and did nothing each time. Harmless, and now clearly wrong
  — flip it to `SoftwareRelease` matching `repository`, the way spa-home already is.
- **`ci-post-receive.yml` in ui-components has no `branches:` binding on its publish step**, so a
  push to a *task* branch publishes a `-main.g<sha7>` prerelease under the `main` dist-tag. Observed
  today (`2026.801.63140-main.gab854a1`). Harmless — `latest` is guarded and the tag is named `main`
  — but the name is then a lie. One `branches: [{exact: main}]` fixes it.
- The `summary` length composition (a release subject quoting a bump subject reaches 108 against a
  100-char cap) — unreachable in the designed flow, still undecided.
- Tofu chevrons (`▸▾`) in the explorers on hosts without glyph coverage.
- `CausationStampingTest` and `OutboxFlowTest` flakes in qits-eventstream — same outbox race.
- qits-ci README still promises `jq` in step images; `node-base` has none.
- qits-spa-ci / qits-spa-cd have CI recipes but no repos on the platform git host.
- Event-triggered QUEUED rows are discarded (not re-enqueued) at restart.
- DAG cycle detection across trigger files; bus catch-up/replay.

## Operational truths that bite (full versions in auto-memory + repo AGENTS.md files)

- **Two release events, and they are not interchangeable.** `SCMRelease` = source control has the
  version. `SoftwareRelease` = the artifact is published, and it names the exact package. A
  downstream consumer triggers on the **second**. A repository with no release pipeline emits no
  `SoftwareRelease` at all — that is the designed stop, not a break.
- **Three endpoints, two doors.** Release is the only thing that writes `main`:
  `POST /workspaces/api/workspaces/{id}/release` and
  `POST /workspaces/api/branches/release?repositoryId=<repo>` `{branch, summary}`. Both stamp, bump,
  **push an annotated tag named the version atomically with `main`**, publish `SCMRelease`, resolve
  any ACTIVE workspace on the branch INTEGRATED and delete the source branch.
  `POST …/{id}/integrate` merges into the branch's *parent* and refuses a `main` parent with 409
  `RELEASE_REQUIRED`. A direct `git push … main` needs `-o qits.token=local-dev`.
- **409 `VERSION_ALREADY_RELEASED` is retryable** — the version's tag already exists, and a second
  later a fresh stamp simply works. Never treat it like `PUSH_REJECTED`, which is not retryable.
  It is reachable on a small repository: two releases inside one second stamp one version.
- **A release pipeline checks out the tag, not `main`.** An event-triggered run is cloned at the head
  of main, which a later push moves; the tag does not. `git fetch <url> refs/tags/X:refs/tags/X &&
  git checkout --detach X` is the whole mechanism, and it needs no platform change.
- **`artifacts:` is a declaration nobody validates.** qits-ci announces `{repository, version,
  packageType, packageName}` on the strength of two lines in a YAML file. A wrong `name:` produces a
  confident event about a package that does not exist.
- **`@` is a reserved YAML indicator** — `exact: "@qits/ui-components"` must be quoted.
- **npm `latest` is guarded now** (403 on a backwards move), but a prerelease publish still needs
  `--tag main` — the guard refuses the whole publish, so a missing `--tag` is a red build, not a
  silent regression.
- Replays of `POST /ci/api/events/post-receive` are NOT idempotent; a missing run row while the
  worker is busy means QUEUED, not lost. A run whose sha was force-pushed away is discarded outright.
- qits-cd write-wedge: green runs, no deployment row, "database has been closed" in cd logs →
  restart the cd container, replay `POST /cd/api/events/build-succeeded`.
- qits-cd caches its run-args config at boot; restart it after editing the `qits-cd-config` volume.
- Gateway is :8080; :8081 is qits-artifacts direct (and the reason every repo's test port is 0).
  CI filter param is `repositoryId`; cd's is `environmentId`. `/events/api/events` ignores `limit`
  and returns the whole history.
- Never run `qits-local-up.sh` casually (the recreate branch kills the cd-managed core); never DELETE
  the `qits` project (it deletes the platform's own git origins).
- Superproject: many local commits, **none pushed** (the user has not asked). Submodule gitlinks lag
  by design; sync is automated.

How to verify any of it: `/ci/api/runs?repositoryId=<repo>` for builds,
`/cd/api/deployments?environmentId=9fc2480c-3ff9-4f24-9bfe-67abe64afb06` for deployments,
`/events/api/events` and `?parentId=` for the bus, `git ls-remote` on both remotes for shas **and
tags**, `HEAD /v2/<repo>/<image>/manifests/<tag>` on :8081 for a docker artifact, and
`GET /artifacts/npm/npm/<pkg>` for an npm one.
