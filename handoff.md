# Handoff: full local release-train E2E

Updated 2026-08-02. This file is the current restart point; older session material was removed.

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
- Remaining checkpoint: commit the released OCI and Projects gitlinks plus this handoff explicitly,
  push root `main`, and run the final health/status audit. The unrelated network-capture plan remains
  only on the `qits-oci` worktree branch and is intentionally not integrated.

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
