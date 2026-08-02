# Handoff: full local release-train E2E

Updated 2026-08-02. This file is the current restart point; older session material was removed.

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

## In flight now

- Workspaces final main/epic build at `e6b78f6` passed on `qits-net`, including resolving
  `qits-eventstream` from qits-artifacts.
- Release `epic/workspaces-qits-net-release` through the Workspaces REST endpoint, then require its
  `SCMRelease` pipeline and deployment to pass. This creates a tag containing the Maven mirror fix;
  replaying the older Workspaces release is insufficient because release pipelines check out tags.
- Gateway received one last UI-home replay after full-history submodule fixes. Its handler/build/
  release chain must finish and the deployed gateway must contain the newest UI-components release.
- Current active CI state must be checked first with `GET /ci/api/runs/active`; do not assume a
  queued/running run survived without checking its row.

## After the queue is clean

1. Reconcile every platform-generated release `main` and tag back into each local/GitHub repo;
   never overwrite platform release commits.
2. Push/deploy qits-ci `5d43c7c` (interrupted EVENT recovery), merging the current platform main.
3. Verify all ten containers are healthy and the CI queue is empty.
4. Verify final Maven/npm coordinates and all eight wrapper gitlinks/deployed image SHAs.
5. Update this handoff with final run/event/version evidence and commit explicit root gitlinks.
6. Only then integrate `../qits-qits-oci` (build dedupe + four concurrent builds) and run a shorter
   regression train against this known-good serial baseline.

## Preserve

- Root untracked user files: `daemon-artifact-identity-plan.md`, `workspace-overview-ux.md`.
- `services/qits-workspaces/.claude/` is user-owned and untracked.
- Do not reintroduce EventStream as a CI/Workspaces submodule or reactor module.
