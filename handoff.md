# Handoff: full local release-train E2E

Updated 2026-08-03. This file is the current restart point; older session material was removed.

## Cold-bootstrap verification complete

- Goal: remove the complete local qits Docker environment and prove that one unassisted invocation
  of the documented `docker run ... qits-local-up.sh` command ends with a healthy environment.
- Scope clarified by the user before deletion: preserve source, images, networks, generated
  bootstrap files, and unrelated Docker resources. Remove only the locally running qits
  environment's containers and its `qits-*`/`qits_*` volumes, then invoke the script once.
- No manual repair is allowed after the bootstrap starts. Any failure must be recorded here and
  fixed in source before restarting the cold test from zero.
- Cold attempt 1 started 2026-08-03 after removing all ten old qits containers and fourteen
  `qits-*`/`qits_*` volumes. Images, `qits-net`, generated files, source, and unrelated Docker
  resources were preserved. Seed builds, dependency publication, compose startup, repository
  creation, and seed readiness all passed without intervention.
- Attempt 1 ended naturally with exit 1. qits-observability CI run `6ffa554b` failed in step 0 with
  exit 128. Its wrapper
  gitlink requested qits-spa-observability commit `9d144a7`, but the fresh platform bare was empty:
  release-train repositories were only pushed after every deployable. Projects, Workspaces, Events,
  Gateway, Artifacts, CI, and CD then failed for the same reason; IDP and STT alone reached ACTIVE.
- Fixed in the root `qits-local-up.sh`: silently seed all release-train histories directly into
  their bare repositories before deployable pushes, avoiding both missing gitlinks and a concurrent
  storm of initial post-receive pipelines. `sh -n`, `git diff --check`, and an isolated bundle/fetch
  proof for the exact missing `9d144a7` commit pass. Cold attempt 2 is the next action.
- Attempt 2 live-proved that fix: Observability, IDP, STT, Projects, Workspaces, and Events reached
  ACTIVE. Gateway then exposed a separate CI persistence race in run `13871670`: H2 closed between
  short CI transactions, and inserting step 0 failed while evaluating the `ci_step.status` check
  constraint (`The database has been closed [90098-240]`). No pipeline step was recorded.
- Source fix in progress: pin `DB_CLOSE_DELAY=-1` on both the compose-seeded and CD-managed CI file
  datasource URLs, matching the lifecycle setting already used by CI's H2 test datasources.
- Attempt 2 ended naturally with exit 1. After the H2 close event, Artifacts, CI, and CD also failed
  while trying to persist step state; the seed CI process stayed up and could reopen the database,
  confirming an intermittent close lifecycle rather than corrupt storage. The datasource fix passes
  `sh -n` and `git diff --check`; cold attempt 3 is next.
- Attempt 3 proved the H2 fix: Gateway run `0f110c32` persisted an ordinary failed step instead of
  losing the database. It exposed the next independent cold-registry defect: Gateway's frontend
  needs `@qits/angular@2026.802.154030`, but the Angular seed path only published historical
  `0.0.1`. Unlike the adjacent UI package path, it never built/published the current `/src` checkout.
- Source fix in progress: after the compatibility publish, build current qits-integrations-angular
  from `/src` and idempotently publish its actual package version.
- Attempt 3 finished with nine deployables ACTIVE and only Gateway absent, then exited 2 at the
  summary because the mounted script was edited after its known failure while the shell was still
  reading it. The attempt was already invalid, but operationally: do not patch the mounted script
  until an invocation has exited. The now-stable source passes `sh -n` and `git diff --check`; cold
  attempt 4 is next.
- Attempt 4 exited 0 without intervention. All ten deployables are ACTIVE at their expected source
  SHAs and all ten containers are healthy. The CD self-handoff referee exited normally. Final probes
  for gateway root/readiness plus Artifacts, CI, CD, Observability, Projects, Workspaces, STT, and
  Events readiness all returned HTTP 200.
- Cold bootstrap is proven from empty qits containers/volumes while preserving images, `qits-net`,
  generated state, source, and unrelated Docker resources. The only root worktree changes are this
  handoff and `qits-local-up.sh`; both user-owned untracked planning files remain untouched.

## Integration in progress: qits-oci

- Started from root `main` at `4903ea4`; user-owned untracked files remain untouched.
- Source worktree: `../qits-qits-oci`, branch `qits-oci` at `acbaeb0`.
- The focused aggregator integration is commit `c35e252`; the following `acbaeb0` only adds
  `network-capture-proxy-plan.md` and is being kept separate until its intended scope is confirmed
  from repository history/state.
- The source worktree's unstaged `handoff.md` is an integrator brief and has been read; it must not
  overwrite this live operational handoff.
- OCI repository was released through Workspaces as `2026.802.194225`; local platform and GitHub
  `main`/tag now point at release commit `036fe5b`.
- GitHub backup contains reconciled `qits-spa-ci/main` at `cebb63e` (84 tests + production build
  green), `qits-ci/main` at `4590758` (255 JVM tests total and reactor verify green),
  `qits-projects/main` at `0e7a1b2`, and released `qits-oci/main` at `036fe5b`.
- Focused aggregator integration is merged on root `main` as `9ceedf5`, with gitlinks advanced to
  those reconciled commits rather than the stale feature tips from the integrator brief.
- All five bootstrap Dockerfiles built locally and all five `latest` tags exist.
- CI `4590758` deployed ACTIVE locally; the prior deployment stayed healthy throughout its native
  build. OCI initially exposed a missing catalog seam: the root bootstrap created the Git origin,
  but Projects' stable platform manifest did not adopt it. Fixed in qits-projects `0e7a1b2`, with
  14/14 focused self-seed tests green; that commit is deployed ACTIVE and the catalog now contains
  stable repository id `qits-oci`.
- Workspaces then released `epic/local-oci-integration` as `2026.802.194225` / `036fe5b`. Its CI run
  `d3e002dd` passed. All ten registry probes (five image names × immutable CalVer and `latest`) return
  HTTP 200, and five sibling `SoftwareRelease` events hang from SCMRelease `f74ff547`.
- Root recorded the released OCI and Projects gitlinks in `d18973b` and is backed up on GitHub.
  Final audit: all ten gateway/root/readiness probes return HTTP 200; all ten deployables are ACTIVE,
  including CI `4590758` and Projects `0e7a1b2`; root and the changed submodule mains match GitHub.
  Only the two preserved user-owned root files remain untracked. The unrelated network-capture plan
  remains only on the `qits-oci` worktree branch and is intentionally not integrated.

## Objective

Prove the complete local release train without manual artifact uploads:

1. release an `epic/*` library branch through Workspaces;
2. build/publish Maven or npm artifacts from the library's `SCMRelease`;
3. emit `SoftwareRelease`;
4. consumers bump on `maintenance/<library>`, build, and auto-release;
5. frontend `SCMRelease` updates its service wrapper gitlink;
6. wrapper maintenance builds auto-release and the wrapper release pipeline deploys.

All build-time service access must use `qits-net`; localhost is only for commands run from WSL.

## Proven live

- `qits-userflows` Maven release `2026.802.153255`: release pipeline green; POM/JAR HTTP 200;
  correctly emitted `SoftwareRelease`.
- `qits-eventstream` Maven release `2026.802.154015`: published POM/JAR; qits-ci and
  qits-workspaces both bumped, built maintenance branches, and auto-released.
- `qits-auth-core` Maven release `2026.802.154953`: published POM/JAR; qits-artifacts, qits-cd,
  and qits-ci all bumped, built maintenance branches, and auto-released.
- `@qits/angular` npm release `2026.802.154030`: published and drove qits-spa-home release.
- `@qits/ui-components` npm release `2026.802.154237`: published and drove all eight frontend
  consumers through dependency-bump maintenance releases.
- All eight wrapper handlers eventually created real maintenance gitlink commits. Seven wrappers
  completed their final release pipelines/deployments: artifacts, CD, CI, events, gateway,
  observability, and projects.
- CI queued-event durability was live-proven across CI self-deployment: queued event YAML/payload
  survived and resumed. Commit `5d43c7c` additionally restarts interrupted EVENT runs from their
  persisted snapshot; 173/173 CI module tests pass. That last commit is on GitHub but still needs
  reconciliation/push to the platform after the current train is quiet.

## Defects found and fixed

- EventStream tests raced a manual sweep against scheduler startup; test scheduling is disabled.
- npm publishing was intercepted by proactive OIDC; raw registries now remain tokenless while
  guarded JSON endpoints still authenticate.
- Queued EVENT runs previously lost payload/YAML on CI restart; trigger snapshots are persisted.
- Wrapper handlers false-passed because `ignore=all` affected `git add` and cached diffs. They now
  compare tree SHAs and stage gitlinks using `git update-index --cacheinfo`.
- Handler shell scripts had an errexit comparison trap and a doubled-backslash commit argument.
- Wrapper builds cloned platform-only frontend commits from GitHub. Handler, post-receive, and
  release configs now override submodule URLs to sibling repositories on qits-artifacts.
- Shallow submodule updates could not request platform-only, unadvertised commits. Internal
  submodule updates now fetch full history.
- Workspaces image builds hardcoded the host Maven URL. The POM/Dockerfile now accept the injected
  internal Maven URL, use a repository-ID-specific settings mirror to bypass Maven's HTTP blocker,
  and build with `--network qits-net`.

## Final serial baseline

- CI active queue is empty.
- Workspaces superseding release `2026.802.190025` passed on `qits-net`, including internal Maven
  resolution. Its earlier `181806` release is obsolete because that tag predates the mirror fix.
- Release images now publish both the human version and `$QITS_CI_SHA`. This is required because CD
  deploys the commit-SHA coordinate; version-only images produced green pipelines followed by
  truthful `IMAGE_MISSING` deployments.
- Final release run/deployed SHA pairs, all green and healthy:
  - artifacts `6183f0d5` / `088ad953`
  - CD `6bb069aa` / `a3cfd816`
  - CI `41544dcd` / `80ca0479`
  - events `268e486a` / `2355e5b0`
  - gateway `75a10346` / `a4337f96`
  - observability `f5e34989` / `acc69aed`
  - projects `b9cc9115` / `322c6210`
  - workspaces `58105a3f` / `2e205567`
- The deployed image tags exactly match platform `main` for all eight wrappers. IDP and STT are
  also healthy; all application readiness/root checks used in the audit pass.
- Platform-generated main commits were fast-forwarded into local/GitHub checkouts. Root gitlinks
  must continue to be committed explicitly because `ignore=all` hides their drift.

## Next work

Integrate `../qits-qits-oci` (build dedupe + four concurrent builds) and run a shorter regression
train against this known-good serial baseline. Concurrency/dedupe was deliberately not introduced
mid-test, so failures in the completed evidence remain attributable to release-train behavior.

## Preserve

- Root untracked user files: `daemon-artifact-identity-plan.md`, `workspace-overview-ux.md`.
- `services/qits-workspaces/.claude/` is user-owned and untracked.
- Do not reintroduce EventStream as a CI/Workspaces submodule or reactor module.
