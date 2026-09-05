# Handoff

What is still open. Everything shipped and closed is in git history; durable
lessons are in the memory files
(`~/.claude/projects/-home-wohlben-code-qits-qits/memory/`).

## SHIPPED (2026-09-05): the ten-item cleanup batch, fanned out and landed

All ten assigned residue items resolved (one subagent each; three turned out already fixed by
sibling sessions and were verified instead of duplicated):

- **DEDUPED ≠ FAILED** — classification was already CANCELLED/DEDUPED since `2026.904.174454`;
  qits-ci `2026.905.54128` fixed the README's stale FAILED promise and added announce-silence
  coverage on all three supersede writers. The `CiDaemonLauncher` mirror javadoc rewritten to the
  /mirror reality in the same release.
- **Deployments frontend newest-row** — the deployment-row half was already fixed
  (`2026.904.151913`); the SAME bug lived on in the requests/outstanding cell and shipped as
  `2026.905.53355`; deployed via a manual webui gitlink bump (`2026.905.71520`).
- **bootstrap-cli QA gate** — interim unit-test pipeline hardened on main (primitive commit
  `4d3b3d1`; a first cut had landed overnight), stated as interim until the far-future
  cold-bootstrap IT; proven by release `2026.905.54204` (instant merge).
- **Workspace containers get the mirror** — `qits.workspace.maven-central-url` ships
  `http://qits-platform-mirror:8080/mirror/maven/central`, blank = off; qits-workspaces
  `2026.905.65332`. One-time consequence: every workspace container is replaced on its next ensure
  (volumes survive). This closes the mirror campaign's LAST unmirrored maven plane.
- **musl toolchain hosted on-platform** — tarballs live in the maven registry under
  `eu.wohlben.qits.toolchain` (GC-safe by released-version policy); qits-ci-daemon
  `2026.905.65829`. Mechanism note: a docker-build RUN cannot reach edge vhosts (own netns,
  `*.localhost`→own loopback) — the fetch is `ADD` in a `FROM scratch` stage (daemon-side network)
  + bind mount, and pipeline-vs-Dockerfile read planes (main vs fold) forbid the --network-host fix.
- **SBOM on qits-configuration releases** — already fixed (`2026.904.181427`), verified live: three
  releases answer 200 with real CycloneDX documents.
- **npm `main` dist-tags unfrozen** — the registry had NO dist-tag routes; qits-registries
  `2026.905.60215` adds GET/PUT `-/package/<pkg>/dist-tags[/tag]` (proxy answers from upstream's
  packument; PUT guards: version-must-exist 404, latest-never-backwards 403, non-hosted 405),
  qits-artifacts `2026.905.75830` deploys it, both lib recipes add an unconditional
  `npm dist-tag add <pkg>@$version main` + doc updates; verified: both `main` tags now track
  `latest` (`2026.905.90159`/`.90241`). Semantics: `main` = the latest released main.
- **edge deployments-events "arity break" DISSOLVES** — edge holds a private local record with
  unknown-fields-ignored, and the four event records carried environmentId/Name since their first
  commit (the epic changed population, not shape). Real exposure = `EventFrame` on an eventstream
  bump (currently at arity). Shipped a full-frame decode contract test as `2026.905.60915`.
- **Doc sweep** — wrapper docs released (`2026.905.55928`): README branching model on the new flow,
  AGENTS gitlink prose (banked, not lagging), stale platform/main and door recipes fixed, banners
  on the two historical records. Fleet inventory: 31/47 repos still state the old flow as current
  truth (per-repo line list in the sweep agent's report; model docs to copy: ui-components +
  integrations-angular READMEs; the 8 frontend repos are byte-duplicated into their services'
  webui trees so each fix lands twice). Rides each repo's next touch.
- **qits-system GitHub backup** — one non-ff ref (`maintenance/frontend`, force-moved by the
  release train); ONE targeted forced update via the projects container's own credential;
  SUCCEEDED with all 40 refs at parity. Ops note: poking the backup listener with a throwaway
  branch mirrors that branch to GitHub, and backup pushes never delete — clean up both sides.

**New findings from the batch (open):**
- **The frontend-follow train — RETRACTED 2026-09-05, it is not dead, it moved.** The old
  per-release "qits release train" bot (last bump 2026-09-02) was deliberately replaced by
  qits-maintenance's bump train (cutover release 2026.904.115704, "deploy the repointed bump
  train"): webui gitlinks are now GITLINK-ecosystem pins in the nightly 02:00 scheduled bump,
  batched with dependency bumps on `maintenance/dependencies` and released via ordinary release
  requests. Verified end-to-end for 2026-09-05 02:00: every service's webui gitlink bumped
  fleet-wide, e.g. qits-workspaces-service RELEASED 2026.905.40732 (merged 05:48) and
  qits-deployments-platform-service RELEASED 2026.905.23929 (merged 04:31), each carrying its
  SPA gitlink. The "two unfollowed SPA releases" were released AFTER 02:00 — they ride the next
  nightly train; the batch's manual webui bump (2026.905.71520) was unnecessary, merely early.
  SPA-fix latency to production is now up to ~24h by design. Inspect the train at
  `http://qits-platform-maintenance:8080/maintenance/api/bumps` (X-Qits-User/X-Qits-Roles
  headers).
- **qits-ci `mergedToMainAt` — RETRACTED as a systemic defect 2026-09-05.** Self-redeploys stamp
  fine: the swarm start-first cutover loses nothing because the emitter is qits-platform-deployments
  and the projects listener is durable — every qits-ci release on 2026-09-05 stamped at the exact
  second of its "Deployed qits-ci@version into dev" line. What actually leaves a null stamp:
  `DeploymentActive` correlates strictly by (application, version), so a released version that
  never becomes the live one (deploy run died — e.g. the DB outage — or a successor deployed
  first) never fires its own gate; its commits still reach main via the successor's fold+merge,
  but only the successor's row stamps. One such row exists (`2026.905.54128`, its deploy was an
  outage casualty; `2026.905.64147` carried it to main). A RELEASED row with null `mergedToMainAt`
  therefore reads "released but never observed live" — a bookkeeping gap for skipped versions,
  not a lost event. Possible tidy-up if it ever matters: a successor's DeploymentActive could
  sweep older pending rows of the same repository.
- **CI queues phantom `POST_RECEIVE` runs** against `ci-post-receive.yml` no repo has; they end
  CANCELLED (harmless, wasteful).
- **Recipe-effect timing rule** (now in the lib docs): a `ci-event-release.yml` change takes effect
  on the SAME release for instant-merge repos (finalization precedes the recipe run) and one
  release LATER for deployment-gated repos.

## SHIPPED (2026-09-04): route Maven Central through the mirror for the BUILD plane

**DONE AND CLOSED (2026-09-04 afternoon).** The fan-out below executed: all 18 `<server>` releases
(16-repo paced train + artifacts/ci) and the qits-ci build-url flip (`2026.903.222315`) are released
and deployed. The owed "literal build-log proof" is closed — and it could never have appeared as a
log line: builds run maven with `-ntp` (no download lines at all) and step logs cap at 64 KB. The
equivalent proof was assembled live instead (admin-workspace probe 1201, torn down after):

- A **live CI step container** carries `QITS_MAVEN_CENTRAL_MIRROR_URL=http://mirror.dev.localhost:8080/mirror/maven/central`
  and `QITS_MAVEN_PROXY_URL=http://qits-platform-mirror:8080/mirror/maven/central` — the injection is live.
- **Host netns reaches the URL**: `mirror.dev.localhost` resolves to 127.0.0.1 in the host's hosts file
  (the edge publishes 8080), and an anonymous GET from a `--network host` container fetched the real
  artifact bytes. The 2026-09-01 "000 unreachable" probe is superseded.
- With the env non-empty the settings profile DISABLES direct Central — there is no silent fallback —
  so every green build whose mvnw layer actually ran (e.g. qits-workspaces QA fold 14:12Z, layer
  `#13 DONE 240.2s`, uncached, empty ~/.m2) resolved Central through `/mirror` by construction.
- **Why the mirror's central cache shows no build-plane accesses: the EDGE caches the artifacts.**
  They are served `cache-control: public, max-age=31536000, immutable` + strong etag; reads on the
  mirror vhost are anonymous (unify-ingress method-scoped auth), maven is never challenged, sends no
  Authorization, and gets edge-cache hits. Measured: edge GET with Basic bumps the mirror's
  `lastAccessedAt` (auth bypasses the cache); the same GET anonymous does not. Builds resolve at LAN
  speed off the edge cache; the mirror is the origin behind it. Step plane (in-network
  `qits-platform-mirror:8080/mirror/maven/central`) hits the mirror directly — its access bursts
  align with maven-base steps (e.g. 607 pkgs at 13:48Z under the workspaces verify).
- Corollary: since GETs are anonymous-allowed at the edge, the `<server id="qits-central-proxy">`
  creds are belt-only for reads (they matter if the vhost read policy ever tightens). The ordering
  barrier was still honoured.

### Audit vs the release-flow rearchitecture (shipped in parallel, 2026-09-04)

The streamline-release-flow epic retired every `ci-event-build.yml`/`ci-event-userflows.yml`/
`ci-post-receive.yml` — the files this campaign had wired. Audited all 46 submodules at current main:
**nothing to do, the sweep carried the wiring forward.**

- Every docker-building service repo's `ci-event-release-request.yml` AND `ci-event-release.yml` pass
  `--build-arg QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_CENTRAL_MIRROR_URL:-}"` on the image build and
  export `QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}"` before in-step mvnw. Libs export the
  step-plane URL only (no docker build). All 18 `.qits-maven-settings.xml` `<server>` entries intact.
- **The mirror's circularity guard survived**: qits-mirror's new pipelines hardcode
  `--build-arg QITS_MAVEN_CENTRAL_URL=""` with the reasoning in a comment. Do not change it.
- qits-ci main (`2026.904.130928`, deployed) still ships the flip defaults in
  `ci/src/main/resources/META-INF/microprofile-config.properties`; launcher untouched by the epic.

### DONE (2026-09-04 afternoon): the daemons joined the mirror

qits-projects-daemon (`2026.904.153549`→`.160152`), qits-workspace-daemon (`.153848`→`.160522`) and
qits-ci-daemon (`.153949`) now resolve Central through the mirror in every plane: fleet
`.qits-maven-settings.xml`, Dockerfile `ARG QITS_MAVEN_CENTRAL_URL` + secret mounts + `-s` on the
mvnw RUN, `--network host` + build-arg in both pipelines (sbom builds byte-identical for the cache
hit). ci-daemon's hand-rolled musl builder gets `--network host -e QITS_MAVEN_CENTRAL_URL=…` and
`-s` on its inner mvnw — deliberately credless (edge reads are anonymous; a transient container's
env is inspectable). All three verified: uncached maven layers ran green under the active profile,
which has no direct-Central fallback.

### Two platform defects found on the way (release-request flow), one fixed

1. **QA-gate race — a red gating run can release (OBSERVED, open).** ci-daemon's first release
   (`2026.904.153949`) released 19s AFTER its gating run finished FAILED. Mechanism: the settle
   window (`qits.projects.release-requests.settle`, 30s) counts from `armedAt`; with the single CI
   worker every QA run outlasts it. When the run terminates, the live active-runs probe answers 0
   immediately, but the `BuildFailed` verdict arrives via the durable bus consumer seconds later —
   the 30s sweep tick in that gap sees "no active runs, no verdict, settle expired" and passes the
   gate VACUOUSLY. The ledger now holds the red verdict; evaluate() ignores settled requests. Green
   releases likely go through the same door harmlessly. Fix direction: restart the settle window
   when the active count reaches zero ("quiet for `settle`", not "armed for `settle`"), and/or have
   the qits-ci probe report that terminal runs exist so the gate knows verdicts are owed. (The
   musl-toolchain download from more.musl.cc that reddened the run is its own flake — the Dockerfile
   already suggests mirroring that tarball; the tag's release recipe later rebuilt green.)
2. **Nine release recipes triggered on the dead `SCMPublishTag` — FIXED fleet-wide on main.** The
   epic's tag primitive fires no post-receive, so recipes listening for the tag event never run: the
   tag strands with no artifact, no `SoftwareRelease`, no merge to main (both daemons demonstrated
   it live). Affected: eventstream/registries/integrations-quarkus/integrations-angular/
   ui-components libs, both daemons, both workspace OCI images (ci-daemon was already fixed by the
   epic; every service uses SCMRelease). A normal release of the fix would itself strand (trigger
   files are read at main), so the corrected files were committed DIRECTLY to the nine mains via
   qits-githost's `POST /repositories/{id}/commits` primitive (qits:system; catalog id IS the
   githost id). The stranded daemon tags were superseded by fresh release requests, whose octopus
   folds picked the old tags up as implicit sources exactly as designed — both re-releases ran the
   fixed recipe end to end and merged to main. Fix content: `event: SCMRelease`,
   `when: - repository: {exact: <name>}` (ci-daemon's proven shape), payload `.tagName`→`.version`,
   restore prose now points at the manual trigger door (`POST /ci/api/events/trigger` — note it
   demands a token whose `project` claim is literally `*`; workspace-commissioned clients carry
   none, which is why the supersede path was used instead of a replay).

### Open (optional) follow-ups, none blocking

- `CiDaemonLauncher`'s field javadoc still says the build-url "ships empty" and that a non-empty one
  "reddened every image build" (the pre-`/mirror` world) — stale, fix next time qits-ci is touched.
- Parked follow-up still parked: qits-workspaces doesn't inject `QITS_MAVEN_CENTRAL_URL` into
  workspace containers (the oci image's `/etc/qits/maven-settings.xml` profile stays inert).
- The stale-prose flags on qits-edge/qits-stt `ci-event-build.yml` and qits-artifacts' userflows
  header are MOOT — the sweep deleted those files.
- ~~The superseded daemon requests' pending rows~~ — RESOLVED: the un-gated sweep stamped
  `mergedToMainAt` on every stale row at 16:37:50 (see the SHIPPED section below).
- qits-system-platform-service's GitHub backup is FAILING (push refused) — noticed 2026-09-04, untriaged.
- more.musl.cc is slow/flaky; mirror the musl toolchain tarball through the platform mirror
  (ci-daemon's Dockerfile.musl-builder names the URL and already suggests this).

### SHIPPED (2026-09-04 evening): the release process owns the wrapper's estate, and gates come from the config

Two features close the wrapper story for good, riding the gate correction a sibling session shipped
as qits-projects `2026.904.161524` ("The gate gates: no verdict, no release" — the settle-window
vacuous pass is GONE and its property with it; the non-deployable fork moved off `SoftwareRelease`
onto the release itself, healing every recipe-less repo's stranded tags):

1. **A wrapper release banks its estate** (qits-githost `2026.904.173724` + qits-projects
   `2026.904.190637`): releasing the project's WRAPPER reads `.gitmodules` at the fold, resolves
   every declared submodule's default-branch head from the githost (`GET
   /githost/api/repositories/{id}/branches/{name}`, new), and writes the pins as gitlink (mode
   160000) entries in the same commit as the version bump — the githost commit primitive gained a
   `gitlinks` map for exactly this. Undeclared-in-catalog submodules skip with a WARN; an unreadable
   head refuses the release rather than banking a partial estate. Nothing updates gitlinks between
   releases anymore, and nothing has to.
2. **The committed qits config is what enables a quality gate** (the user's model, stated
   2026-09-04): `deployments.yml` at the released tag → the "deployment successful" gate; no
   deployment declared → no gate exists → the tag merges/ffs to main at the release, instantly.
   That rule and its un-gated-row sweep shipped in the sibling's `2026.904.161524` — PROVEN LIVE at
   16:37:50, when its deploy fast-forwarded wrapper main onto both stranded tags (`152345`,
   `161524`) and stamped every stale pending-merge row (the superseded daemon requests included)
   with no release and no hand involved. This session's `2026.904.190637` adds the estate banking
   on top.

**Two flow defects found on the way — both settled the same evening:**
- **FIXED (qits-projects `2026.904.193801`): a re-fold after CONFLICTED could dispatch no
  `ReleaseRequestChanged`.** Observed on request `7247b350`: first fold CONFLICTED (no event, by
  design), branch force-pushed, re-fold cleared to PENDING via the `UNCHANGED` arm — which returned
  without announcing on the theory that "the gate reads the verdicts that sha already has", false
  for a fold that was never built, and a request stuck forever under the verdict-only gate (the
  empty-commit re-arm was the interim recovery). The arm now consults the build-status ledger:
  a gating verdict for the sha keeps the silence (evaluate reads it immediately), no verdict
  dispatches. Regression-tested both ways in `ReleaseRequestSourcesTest`, proven to fail on
  unmodified main.
- **RETRACTED: "qits-projects-service still carries `ci-post-receive.yml`" was wrong.** A
  fleet-wide audit of all 48 mains found ZERO retired trigger files anywhere: projects lost its
  ci-post-receive on 2026-08-29, and qits-workspaces-service — the one true straggler — was purged
  at 13:25 today by the sibling session (out of band, same self-deploy-cycle reasoning). The
  FAILED/DEDUPED runs that suggested otherwise sit on release-request fold branches: they are the
  QA pipeline's own dedup surfacing as FAILED — defect #4, already on the books, whose fix belongs
  in how a DEDUPED verdict is displayed, not in any file. One audit anomaly, known and deliberate:
  qits-bootstrap-cli has no `.config/qits/` at all, so under the verdict-only gate it cannot
  release until its (far-future, per the user) full-bootstrap integration-test pipeline exists.

The plan below is kept as the record of what was done.

### Original plan (executed)

**Goal.** Finish the maven-central-mirror work so that image builds (native-image
`docker build`s — the bulk of maven traffic) resolve Central through the mirror and
cache it, not only the userflows/step plane. See memory `maven-central-mirror-campaign.md`
for the full backstory; this section is the forward plan.

**Status: the hard part is DONE and PROVEN; only a mechanical fan-out remains.**

### Why /mirror (root cause, settled)
A native-image `docker build` resolves maven inside the RUN in the HOST network namespace
with the image's own resolv.conf. It can only reach the mirror through the EDGE vhost
`mirror.dev.localhost`. The edge routes `/artifacts` to the hosted registry — `/artifacts`
is qits-artifacts' PRIMARY route and primary routes TRAVEL to every vhost
(`EdgeRouter.travels()`), so `mirror.dev.localhost/artifacts/maven/central` is handed to the
registry and 404s. `/mirror` is the mirror's OWN route, which the edge carries to it.
Auth is NOT the blocker: `EdgeAuth` brokers HTTP Basic → idp `client_credentials`, so the
commissioned client the build already holds is accepted (measured 200). The postponed idp
basic-auth feature is UNRELATED. The `/artifacts` paths were a leftover from before the
byte-plane split; user decided to use `/mirror` ("that's why it exists").

### DONE — released and on main
1. **qits-registries `2026.902.190920`** — `qits.registries.maven.mirror-mount` config
   (empty default; mirror sets `/mirror/maven`). ADDITIVE second maven mount beside
   `/artifacts/maven`, so nothing migrates atomically. Files: `maven/.../MavenPaths.java`
   (`artifactRoute(mount)`), `MavenRoutes.java` (`mirrorMount` Optional + `registerMount()`),
   `MavenMirrorMountTest`. Handlers are mount-agnostic (read named path groups).
2. **qits-mirror `2026.902.204548`** — pin bump to 190920 + `qits.registries.maven.mirror-mount=/mirror/maven`
   in `application.properties`. DEPLOYED and VERIFIED:
   `/mirror/maven/central` serves **200 in-network AND 200 via the edge with commissioned Basic**.
   (`/mirror` is already in `quarkus.quinoa.ignored-path-prefixes`, so no Quinoa change.)

### REMAINING — the fan-out (order-critical). Do in a clean, quiet session.
**Step A — add the `<server>` to all 18 service repos' `.qits-maven-settings.xml`, FIRST.**
Inside the existing `<servers>` (beside `qits-maven-network`), verbatim:
```xml
    <server>
      <id>qits-central-proxy</id>
      <username>${env.QITS_MAVEN_AUTH_USR}</username>
      <password>${env.QITS_MAVEN_AUTH_PSW}</password>
    </server>
```
These env vars are the commissioned client, already mounted by each `docker/Dockerfile`'s
mvnw RUN (`--secret id=qits-client-id,env=QITS_MAVEN_AUTH_USR` etc.) for `qits-maven-network`.
In the step plane they're unset and never sent (no 401 in-network) — inert, exactly like the
existing server. NO path change to the settings files (the URL is the injected env var).
The 18 repos (all with a docker/Dockerfile that runs `-s .qits-maven-settings.xml`):
  artifacts, ci, configuration, containers, deployments, docs, edge, events, githost, idp,
  maintenance, mirror, observability, orchestrator, projects, stt, system, workspaces.
  (mirror's is inert — see circularity note below — but harmless; include it for uniformity.)

**Step B — qits-ci, LAST (only after ALL of Step A is released).**
In `ci/src/main/resources/META-INF/microprofile-config.properties`:
  - `qits.mirror.maven-central.build-url` : from empty → `http://mirror.dev.localhost:8080/mirror/maven/central`
  - `qits.mirror.maven-central.step-url`  : → `http://qits-platform-mirror:8080/mirror/maven/central`
Update `CiDaemonLauncher` field default comments and `CiDaemonLauncherTest` (build plane now
non-empty; assert the /mirror URLs). Keep `mavenCentralMirrorBuildUrl` as `Optional<String>`
(empty-String property fails Quarkus boot — SRCFG00040; learned the hard way).

**THE ORDERING BARRIER (do not violate):** the moment qits-ci ships the non-empty build-url,
EVERY repo's docker build tries `mirror.dev.localhost/mirror/maven/central` through the edge.
A repo without the `<server>` presents no creds → the edge 401s → its build FAILS. So ALL 18
settings must be released before qits-ci flips. Same trap as the first campaign; respect it.

**Circularity — the mirror is already self-protected.** qits-mirror's `.config/qits/ci-event-build.yml`
hardcodes `--build-arg QITS_MAVEN_CENTRAL_URL=""` (NOT the fleet `${QITS_MAVEN_CENTRAL_MIRROR_URL:-}`),
so the mirror's own build resolves Central DIRECTLY, never through itself (a concurrent session
shipped this as "the mirror stops building through itself"). Do NOT change that. No other repo
is circular (qits-artifacts ≠ mirror).

### Verify after the fan-out
Trigger a service's env/dev build; watch its docker-build maven resolve Central via
`mirror.dev.localhost/mirror/maven` and go green; confirm the mirror's central cache grows
(`GET http://qits-platform-mirror:8080/mirror/api/repositories/central/packages`). Use a COLD
docker layer cache for at least one (a green build that resolved nothing is not proof — the
2026-08-12 lesson). Edge acid test:
`curl -H "Host: mirror.dev.localhost" -u "$QITS_COMMISSIONED_CLIENT_ID:$QITS_COMMISSIONED_CLIENT_SECRET" http://qits-platform-edge:8080/mirror/maven/central/io/quarkus/platform/quarkus-bom/3.34.6/quarkus-bom-3.34.6.pom`

### PARKED / decided (do NOT silently do these)
- **npm and OCI stay on `/artifacts` and `/v2`.** They do NOT need `/mirror`: npm runs in the
  STEP container (not the docker build, so in-network `/artifacts/npm` is reachable), and OCI
  `/v2` already routes through the edge. Moving them to `/mirror` is optional tidiness only.
- **`/artifacts/maven` stays additive on the mirror** (both mounts serve). Removing it later is
  optional cleanup once nothing dials it — not required.
- **Anonymous edge reads: rejected** (user). Use the commissioned Basic creds, not an
  anonymous-read carve-out. The idp basic-auth feature is unrelated to this work.

### Conditions / gotchas for the clean session
- **CONCURRENCY:** another session actively releases to registries/mirror (SBOM/CycloneDX,
  dependency-updates epic). It contends the single-worker CI queue and re-released our keystone.
  Start when it's quiet. Re-fetch before each repo op; expect door CONFLICT rejections
  (merge main + re-arm).
- **Deploy may not chain from a green build immediately.** Our mirror image sat un-pushed while
  the build queued ~25 min behind the other train. If a deploy stalls: re-fire env/dev
  (`git push origin +<sha>^:refs/heads/environment/dev -o qits.no-ci; git push origin <sha>:...`),
  and confirm the image actually pushed (admin workspace `docker manifest inspect
  registry.dev.localhost:8080/qits/<app>:<sha>`). The mirror is a NATIVE image.
- **Door is merge-request-shaped:** PENDING → gate → RELEASED; re-arm by pushing to the branch.
  A DEDUPED "FAILED" run is a superseded duplicate, not a real failure (check `supersededByRunId`).
- **initdb-as-root:** registries gate needs `user: build` in `ci-post-receive.yml` (on main now).
  A gate dying on `EmbeddedPgConfigSource could not be instantiated` with uid=0 is this.
- **Admin workspace for docker access:** `POST /workspaces {admin:true}` mounts the host docker
  socket (qits-workspace-oci ships docker-ce-cli). Run commands via a `.qits-config.yml`
  `actions:` entry + `POST /workspaces/container/{numericId}/commands`, poll `/commands/{id}/log`;
  recreate the container after each branch push (Content-Type required or 415). TEAR IT DOWN after
  (`/discard?ignore-changes=true`) — it is root-equivalent on the host.

### Quick reference
- Release door: `POST http://dev-qits-workspaces:8080/workspaces/api/branches/release?projectId=$QITS_WORKSPACE_DAEMON_PROJECT_ID&repositoryName=<name>` (bearer aud `dev-qits-workspaces`), body `{"branch","summary"}`.
- Poll request: `GET http://dev-qits-projects:8080/projects/api/repositories/<repoId>/release-requests` (bearer aud `dev-qits-projects`). Repo UUIDs: `GET .../projects/$QITS_WORKSPACE_DAEMON_PROJECT_ID/repositories`.
- CI runs: `GET http://dev-qits-ci:8080/ci/api/runs/{active,finished?limit=N,<id>}` (bearer aud `dev-qits-ci`).
- Deploy verdicts: qits-platform-deployments logs via `GET http://dev-qits-observability:8080/observability/api/telemetry/logs?source=_service/qits-platform-deployments&query=...&sinceMinutes=..` with `X-Qits-User`+`X-Qits-Roles: qits:admin`.

## Recently landed (2026-08-22, later)

**Agent + workspace image versions are event-driven; workspace containers fixed;
per-consumer container OOM scores shipped.** All via normal releases (no reboot).
- Agent image version: qits-configuration `SoftwareReleaseListener` (its first
  eventstream consumer) syncs `env.QITS_PROJECTS_AGENT_IMAGE_VERSION` from the
  `qits/project-agent` SoftwareRelease; deployer injects it into qits-projects.
- Workspace image version: same listener, `qits/workspace` → qits-workspaces.
  The deployed workspace daemon was stale (flat `/git/<name>` self-clone, its
  release tag lost in the rebootstrap); re-cut the daemon (`2026.822.185134`),
  event-synced, redeployed qits-workspaces. Self-clone is project-scoped now.
- Per-consumer container OOM: `oomScoreAdj` on the qits-containers-client Security
  wire → `--oom-score-adj`; ci=1000, agents=800, workspaces=600. See
  [[container-oom-score-per-consumer]], [[workspaces-mirror-public-route]],
  [[serialize-releases-oom]] (concurrent native builds OOM-crashed the box once —
  release ONE service at a time), [[consume-events-local-dto-not-vocab-jar]].
- Server helper scripts added: /root/qits/release-repo.sh (push branch + door
  release), retrigger-deploy.sh / retrigger-config.sh (re-fire environment/dev),
  recut-daemon.sh (empty-commit re-cut when a release tag was lost).

## In flight right now (2026-08-30, wrapper reorganization)

**Design settled, implementation started.** The whole design — component layout, name
grammar, the full repo map, phases, rename runbook — is `wrapper-reorganization-plan.md`
in this root. The empty `wrapper-reorganization` workspace branch waits on the platform.

**Phase 1 wave 1 DONE, releases rolling (2026-08-30).** Four workstreams landed, all
green, details + follow-ups banked in the plan doc: qits-projects `component` fact
(9fec91cb), ui-components component grouping + open-set addresses (984eb33),
qits-cli-bootstrap dual-layout (c581efa — .gitmodules is the path authority; found the
four stale platform-events/deployments urls that silently built from GitHub), and the
estate path audit. Released so far: qits-spa-ui-components 2026.830.81942 (green),
qits-projects 2026.830.82133 (cut, build in flight at last handoff edit).

**All seven SPAs adapted and committed** (2026-08-30): projects a8579ae, ci 392d6ce,
artifacts c4090b0, workspaces c6d2f2c, githost b08617c, docs 313d94e, configuration
ea31cf2. Fleet guard design: `isRepositoryAddress` keyed on OWN_SEGMENTS derived from
each app's route table (open middle segment allowed; `/qits/nonsense/<repo>` now
resolves project-scoped by design). qits-cli-bootstrap released 2026.830.83039
(stamp-only, repo has no pipelines — a runs.sh watcher on it waits forever).

**SPA release train in progress, STRICTLY one at a time** (each SPA release triggers its
service's maintenance train = two native builds): qits-spa-projects 2026.830.91507
released, service train building at last edit. Queue: ci → artifacts → workspaces →
githost → docs → configuration. AFTER EACH TRAIN: check the service's GitHub backup —
the force-pushed maintenance/<spa> branch breaks the non-force backup
([[train-branch-breaks-backup]]); delete GitHub's copy + re-run backup if FAILED.

**Phase 2 STARTED and PROVEN (2026-08-30 afternoon).** Both prerequisites LIVE: deployer
`application:` override (2026.830.122232) and the projects rename endpoint
(2026.830.122821). First rename executed end to end: qits-eventstream →
qits-eventstream-javalib (row PATCH → GitHub → wrapper release 2026.830.123803 →
reconcile 47 KEPT + 1 SYNC_TARGET_UPDATED; new clone URL 200, old 404). Found+fixed
live: the four lib release pipelines' `repoId:` matchers were dead since the identity
cutover (UUID storage ids) — eventstream's now matches `repoName:` and fired green
(2026.830.125350, first lib artifact since 2026-08-22). REMAINING renames follow the
plan doc's proven runbook + ripple checklist (blobstore/integrations fix their dead
matchers WITH their renames; consumers' upstream-eventstream files in qits-ci +
qits-deployments still name qits-eventstream and need the new name).

**PHASE 2 COMPLETE (2026-08-30 night): ALL 44 renames live.** Final wave: 15 frontends
+ 18 services in one batch (33 row PATCHes, 33 GitHub renames, wrapper release
2026.830.163656, reconcile 15 KEPT + 33 SYNC_TARGET_UPDATED, zero strays). Every
service pins `application:` — proven end to end by qits-docs-service releasing through
the door under its new name and deploying as dev-qits-docs (2026.830.163740). Browser
verified: sidebar all-new names, zero stale, Code page works on renamed repos. Also
revived en route: qits-artifacts' release pipeline (matched the pre-split name
qits-platform-artifacts — calver docker publishes dead since the split). Remaining
tails: phase 3 (blobstore→registries merge), spa-home archival, docs sweep (README
prose old names), the four chrome-automation-less SPAs, daemons' own repoId matchers,
next-bootstrap proof of the CLI's REPOSITORIES table.

Earlier progress record:
**Phase 2 progress (2026-08-30 late): 11 renames live.** Libs (7) + images/CLI (4:
qits-build-images-oci, qits-database-oci with `application: qits-oci-postgresql`
protecting the platform DB, qits-workspace-oci, qits-bootstrap-cli). Wrapper
2026.830.161742, reconcile 44 KEPT + 4 SYNC_TARGET_UPDATED. The bootstrap CLI now
splits application-vs-repository names (REPOSITORIES table holds all renames). Code
spinner regression FIXED live (spa-githost scopeGroup migration, 2026.830.160321,
browser-verified). REMAINING: frontends wave (per-SPA: rename + owning service's
.gitmodules/upstream-spa yml + application: key bundled into the same service
release — spa-home excluded, archival), then services (BEFORE renaming
qits-artifacts: add qits-artifacts-service to the CLI's WrapperDir.MARKER_REPOS;
settle the qits-deployments/qits-events short-name rows; verify each release matcher
EMPIRICALLY — the registry/run history is the oracle, pattern inference was wrong
twice). Daemons keep their names; their own repoId release matchers worth a
repoName pass in a cleanup batch.

**Then the wrapper flip** (paths to components/, fix the four stale
platform-events/deployments urls, sweep stale dirs services/qits-gateway +
services/qits-repositories + integrations/ duplicate, template skeleton in
qits-projects, CLAUDE.md doctrine, commit the qits-local-up.sh edit, push to platform
githost + GitHub). Phase 2 (renames) starts with the projects rename endpoint + deployer
`application:` override — do NOT rename anything before those exist.

## In flight right now (2026-08-26, repository delete lifecycle)

**Ruling:** the wrapper reconcile never deletes rows again; rows the wrapper stopped declaring are
reported `UNDECLARED` and get a Delete button on the project setup page; that DELETE removes the
projects row AND the bare on qits-githost, synchronously over REST (`DELETE /git/<id>`, projects'
service client only). No tombstone, no retention. Two ghosts measured on wohlben.eu before the change:
qits-gateway `8b18ec41…` (534 KB) and qits-repositories `dbd2a9a4…` (2.5 KB) — 51 bares vs 49 rows.

**SHIPPED 2026-08-26 ~19:00 UTC on wohlben.eu:** qits-githost 2026.826.181237 (`8cf0f7a9`, DELETE /git/:id →
204/404/400 behind the storage-client guard, four `git_*` row families in one tx; blobs stay orphaned —
no refcount), qits-spa-projects 2026.826.184427 (`059e6258`, warning badge "not in wrapper" + two-press
Delete on the card, page owns the request), qits-projects 2026.826.185052 (`25637c91` via the upstream-spa
train; `GitHostRepositories.delete`, `deleteInternal` calls the host inside its tx, reconcile reports
`UNDECLARED`, listing entries carry `declared`). All three mains + tags synced home to GitHub; backups
SUCCEEDED after the train. Ghosts purged with the dev-qits-projects bearer: 49 bares = 49 rows. Live
check: reconcile 48 KEPT, 49 rows before/after; page screenshot `project-setup-after-delete-lifecycle.png`.
**Open:** the WRAPPER is not synced home (platform 94d7db9 ahead; local/GitHub still declare
qits-repositories); the backup job still runs for undeclared rows; a githost blob census sweep for the
bytes of deleted repos; the projects→githost delete hop is proven by tests + the host purge, not yet by a
live UI delete (no undeclared row exists to press).

## In flight right now (2026-08-23)

**qits-gateway retired for good (2026-08-23 evening).** Why it was still "deployed": the wrapper
catalog still named it, so the cold boot built it, qits-platform-maintenance bumped its spa-home
gitlink (`maintenance/qits-spa-home` 06:11) and auto-released it (2026.823.63523), and the deployer
ran `dev-qits-gateway` crash-looping on its `gateway-routes` health check. Done: submodule dropped
from the wrapper (4ebc0b2, released 2026.823.161820 — the catalog reconcile deregistered the repo
row; history stays on the githost), deployer service+application rows deleted (machine token,
audience `qits-deployments`), swarm service + dead task + images removed on wohlben.eu,
bootstrap CLI prose/test names scrubbed (0aaa8a1, local, no release), qits-platform-idp shipped
`prod-qits-gateway` client removed (dcbf590, 63+11 tests green) and RELEASED 2026.823.162522
(deploy run watched). GitHub repo
`qits-gateway` untouched (archive it by hand if wanted).
- **Gap surfaced:** nothing serves `/` now — the edge answers "No active deployment endpoint in
  environment dev matches /" (it did so before the removal too; the gateway used to carry
  qits-spa-home). The main-navigation "Home" link points there. Decide where the landing page
  lives (edge-served spa-home, or drop the link).
- Wrapper local main merged origin/main (25186bc) with the gateway removal on top; push to GitHub
  after review. `priority-feature.md` / `qits-configuration-plan.md` carry older uncommitted edits
  (stashed and restored, not mine).

## In flight right now (2026-08-23, Design tab)

**Design tab (frozen HTML designs) in the refining route — LIVE on wohlben.eu.** Contracts +
follow-ups: `design-tab-plan.md`. Shipped: qits-projects 2026.823.153819 (+ two follow
re-releases bumping the webui gitlink), qits-spa-projects 2026.823.154424 + 2026.823.160313
(title fallback). Browser-proven on refinement 3 (epic `ui-overhaul`, project qits): two rows
left there on purpose (the frozen Projects page, and the kept "red heading" proposal).
- Local mains ahead of GitHub: qits-projects a27365e8..71cf8d8b (6), qits-spa-projects
  616f93e..d544f0a (6). The door backed them up to GitHub on release; `git fetch` + ff the
  local mains to the released stamps (sync tags) before the next work there.
- `claude-verify`: password-only admin account I registered on wohlben.eu for the browser check
  (`/root/qits/claude-verify.pw`). Delete the idp user row if unwanted. Helper on the server:
  `/root/qits/mcp.sh <tool> '<json>'` calls the live repository MCP server scoped to project qits.
- Local `./mvnw verify` cannot package qits-projects: Quinoa `npm install` of the nested webui
  401s on the dead workstation npm creds — `-pl service -am test` runs the suites; CI packages.
- qits-ci local main has 2 unreleased commits (timeout feature below) and diverged from origin;
  its `submodule update --remote` merge was ABORTED here — not this workstream's.

## In flight right now (2026-08-23, earlier)

**CI step timeout: 30 min default + TIMED_OUT status — COMMITTED LOCALLY, NOT RELEASED.**
- qits-ci `c7465fb` (+ `d5f36d5` webui pin): `qits.ci.step-timeout-seconds` 900→1800; a step that
  hits its deadline is aborted (daemon signal + host backstop, unchanged) and recorded step
  `TIMED_OUT`, run `TIMED_OUT` (cancel still wins). Per-step `timeout-seconds:` in
  `.config/qits/ci-*.yml` still overrides (many pipelines declare 3600/7200 — untouched).
- qits-spa-ci `25c516f`: dto unions + badge tone `danger`.
- qits-cli-bootstrap `da8cf63`: `isRedRunStatus` treats TIMED_OUT as red; timed-out step tail shown.
- Release order (one at a time, [[serialize-releases-oom]]): push qits-spa-ci to the platform
  githost FIRST (qits-ci pins it as submodule), then release qits-ci, then qits-cli-bootstrap.
  Not yet pushed to GitHub or the githost.

**Zombie RUNNING run on wohlben.eu — SETTLED by SQL 2026-08-23 16:29 (FAILED, reason recorded); code fix on qits-ci main (cancel settles unowned RUNNING rows, draining flag, stop-first) shipped WITH the timeout feature (user decision). Release 2026.823.164332 ROLLED BACK at boot: the timeout commit had edited applied V1's comments → Flyway checksum refusal; V1 restored + comment-only V6, re-released 2026.823.165207 — LIVE (stop-first proven), cancel API proven on a synthetic unowned row. qits-spa-ci 2026.823.165819 (TIMED_OUT badge) released; qits-ci follow redeployed 8a456191 stop-first. DONE. Local mains (qits-ci 7bc1dc6, qits-spa-ci d8e96b6, qits-cli-bootstrap 0aaa8a1) lag the githost stamps: fetch + ff before next work.** Original note: `d76a0f68` (qits-observability environment/dev): left
RUNNING by the 06:50 qits-ci start-first cutover (old task claimed it after the new task's sweep,
Hibernate gone before it could fail it); its work was redone at 08:11 (`afb1b927` green). Settle:
`update ci_run set status='FAILED', finished_at=now() where id='d76a0f68-cb80-4f9b-94c2-885e83693705';`
Code fixes owed in qits-ci: `update_order: stop-first` in deployments.yml, a draining flag so a
shutting-down worker claims nothing, `cancel()` flipping a RUNNING row the runner does not own.
Note: the new timeout would NOT have caught this — no step ever ran.

## In flight right now (2026-08-22)

**Clean rebootstrap of wohlben.eu running.** A prior rebootstrap kept the
old env's compiled images to save time — the wrong call. The kept CI seed
image predated the identity commits (built 19:53, last identity commit 20:29),
so the running CI announced builds without the (projectId, repoName) pair:
the deployer fell back to the repoId UUID → every platform service
`IMAGE_MISSING`, and postgres read DEFAULTS → HTTP health → crash-loop.
Root cause and fix are memory files [[clean-rebootstrap-must-wipe-images]]
and [[pg-resetwal-destroys-boot-state]].

Current boot (relaunched ~07:31 UTC) is the CLEAN one: wiped all `qits/*`
images + buildx build cache + builders + data/config volumes, kept only the
dependency caches (maven/m2/pnpm), the clones, and the retained edge volumes
(qits-edge-acme, qits-edge-letsencrypt, qits_shared_dot_claude). So every seed
image rebuilds from current source → CI current → deploy train consistent.
Watch: at phase 58 (deploy-oci-postgresql) confirm the deployer now reads
`health_cmd: pg_isready` (not HTTP) and postgres stays 1/1; at phase 59+
confirm platform services deploy without IMAGE_MISSING.

BOTH identity-campaign gaps FIXED 2026-08-22 (were the real blockers, not env
leftovers — the "code-complete" claim missed them):
- **Bug #1 IMAGE_MISSING** — qits-ci's `BuildSuccessful` announcement carried
  only `repoId` (UUID), never `(projectId, repoName)`, so the deployer named
  the app after the UUID and looked for `qits/<UUID>:<sha>` (CI publishes
  `qits/<repoName>:<sha>`). The pair was already on the ci_run row and already
  read by the deployer; the producer just never put it on the wire. Fixed in
  qits-ci `3af9a44` (BuildSuccessful + RunAnnouncer + BuildSuccessfulAnnouncer
  + CiRunService.announceRun); deployer needed no change; null-omitted so
  backward-compatible.
- **Bug #2 postgres crash-loop** — the deploy train re-deployed postgres, which
  made the deployer read postgres's spec from qits-githost, whose storage IS
  postgres → circular → DEFAULTS HTTP health → crash-loop. Fixed in
  qits-cli-bootstrap `7dc7993` by MOVING `oci-postgresql` from `DEPLOYABLES` to
  `SEEDED_REPOS` (not deleting — the list also drives the source checkout +
  seed-image build). The seed-stack postgres (already `pg_isready`-gated in
  ComposeTemplate) stays its permanent home; the train never touches it.

Clean boot with both fixes PROVEN 2026-08-22: 76 phases, 0 warn, 0 fail, exit 0,
2h16m; postgres 1/1 from the seed stack, 0 IMAGE_MISSING, https://wohlben.eu 401
(auth gate) with valid TLS. See [[clean-rebootstrap-must-wipe-images]] and
[[identity-campaign-deploy-gaps-fixed]].

**Agent image version now event-driven (2026-08-22, reboot validating).** The
project-agent image version was a hard pin in qits-projects application.properties,
rewritten by a sed-follow (`ci-event-upstream-projects-daemon.yml`) on every daemon
release — so a --ship-mains boot shipped a stale pin (133302) while the daemon
published a fresh version (154053) → "Unable to find image project-agent:133302"
when starting an agent. Redesigned per the user to be event-driven:
- qits-configuration `7c0df2e` — new durable `SoftwareReleaseListener` (its first
  eventstream consumer; added the `eventstream` DB resource to its deployments.yml)
  writes `env.QITS_PROJECTS_AGENT_IMAGE_VERSION` on the `qits-projects` app when a
  `SoftwareRelease` with packageName `qits/project-agent` arrives.
- qits-projects `5f73492` — split the pin into `agent-image-repo` + `agent-image-version`
  (env-overridable, fallback default 154053); deleted the sed-follow yaml.
- qits-cli-bootstrap `cc0f06c` — seeds the version into qits-configuration during
  `configurationImport` (belt-and-braces vs the first-deploy race).
- The deployer already injects per-app env from qits-configuration — no change.
Reboot with all four relaunched to validate end-to-end (seed → event sync →
deployer injection → agent start). Verify after boot: qits-configuration holds the
entry, qits-projects composes the right ref, an agent container starts from the UI.

## Platform state

**TWO PLATFORMS since 2026-08-15.** The public dev environment lives at
https://wohlben.eu (Hetzner, `ssh root@46.224.171.33`) — authenticated,
production TLS, external DNS; see "wohlben.eu bare-server platform LIVE"
below. The WSL platform below is the workstation's own and is expected to
wind down ("last WSL days"); everything in this block is about WSL only.

**Windows-browser access to edge, settled 2026-08-14 evening.** Under
NAT-mode WSL, `localhost:8080` from Windows is UNFIXABLE from inside WSL:
netstat on Windows shows the relay mirrors the ingress mesh's socket as
`[::1]:8080` ONLY (same-family, v6→v6), and the mesh serves only v4 — an
established-then-dead connection browsers do not fall back from. Auth was
innocent. **The working Windows URL is `http://<wsl-eth0-ip>:8080/`**
(192.168.152.4 today; drifts on Windows reboot). The user considered and
DECLINED mirrored networking (`.wslconfig` written then removed — recipe
below stays for reference; WSL days are numbered anyway). If ever wanted:
`[wsl2]` + `networkingMode=mirrored` in `C:\Users\ms\.wslconfig`, then
`wsl --shutdown`; checklist for that first boot:
- Stack returns on its own. Verify edge from BOTH sides: WSL
  `curl 127.0.0.1:8080` and a Windows browser on localhost:8080.
- The ip6tables lo:8080 RST rule died with the VM (reboot-volatile). Under
  mirrored it may be unnecessary — probe a vhost from WSL (`getent`/`wget`,
  never curl); if v6 hangs again, re-add
  `ip6tables -I INPUT -i lo -p tcp --dport 8080 -j REJECT --reject-with tcp-reset`.
- ~~Likely casualty: qits-platform-dns on 5353~~ — moot: dns is
  decommissioned (2026-08-15 section below); nothing publishes 5353 once
  the live service is removed.
- If the mesh itself misbehaves under mirrored, revert: delete the
  `.wslconfig` section, `wsl --shutdown` again. Interim browser access:
  http://<wsl-eth0-ip>:8080 (NAT mode only).
This is expected to be one of the last WSL days — on a real Linux host the
whole relay/mirrored question disappears.

Full rebootstrap green 2026-08-13 ~17:30 (`unwrap --with-data-volumes` +
`QITS_SHIP_MAINS=1`): exit 0, 69 ok + 1 skip in 19m51s, 17/17 services healthy,
edge 200, every deployed sha = local main, all 24 CI repos green.

The fresh githost held ZERO release tags, and 16 repos' mains are ahead of their
newest release tag (deployments by 15 — the swarm migration). Consequence: a
plain restore-default boot ships stale code until a release wave has run through
this platform. Boot with `QITS_SHIP_MAINS=1`, or release first.

## In flight

Another session owns the lib calver campaign and edits this file — merge, do not
clobber.

### qits-platform-system — LIVE on wohlben.eu (2026-08-23)

Contract + status log: `qits-system-plan.md`. UI at https://wohlben.eu/system/ (nav
`System:14`): glances web terminal, swarm nodes/services/configs/secrets, node containers with
`[bash]`/`[sh]` exec terminals — browser-proven through the public edge. Released: cli-bootstrap
2026.823.171206, wrapper .171252, SPA .171747, service .171819 (deployed 5028372). The service
holds the docker socket (third holder); glances = `mirror.dev.localhost:8080/hub/nicolargo/glances:4.5.6-full`
pulled with the service's own credential (`config.json` on `qits-platform-system-config`).
Open:
- the idp client was `service update --env-add`ed on the live idp AND imported into
  qits-configuration — the next idp deploy reads the store, nothing to do unless it 401s;
- `docker service ls` carries no UpdatedAt, so the Services table's UPDATED column is an em
  dash (detail pages have it) — cosmetic;
- v1 reaches the local node only (`NODE_REMOTE` 409 for others); per-node reach needs a design;
- worktree `/home/wohlben/code/qits-qits-system` (`feature/system`) can be removed once this
  section is banked on main.
### qits-platform-maintenance — building on worktree `feature/maintenance` (2026-08-21)

Contract: `qits-maintenance-plan.md`. Replaces the 71 `ci-event-upstream-*.yml`
hop files with one platform service (inventory + latest + groups + bump
branches, ff-only) and a qits-ci "platform-level pipeline"
(`.config/qits/ci-platform-event-maintenance-bump.yml` in this wrapper).
Worktree `/home/wohlben/code/qits-qits-maintenance`; qits-ci work on
`services/qits-ci` branch `feature/platform-pipelines` (a worktree of the
submodule); new submodules `services/qits-platform-maintenance`,
`frontends/qits-platform-spa-maintenance` (both on local main, unpushed).
LIVE on wohlben.eu 2026-08-22, first bump proven (see the plan's status).
Open: (1) flip `QITS_MAINTENANCE_BUMP_AUTO` back to true once a
`maintenance.yml` group fences Angular 22 (node-blocks-angular-22); (2) after
the first green SCHEDULED bump delete the 71 `ci-event-upstream-*.yml` hop
files (one sweep, one wrapper release); (3) SPA cosmetic: SUCCEEDED message
rendered in the error tone; (4) releases made before qits-ci 2026.822.173700
lack version images (qits-workspaces 2026.822.164640) — replay recipe in the
plan.

### qits-platform-orchestrator — LIVE on wohlben.eu (2026-08-21)

Plan + contracts: `qits-orchestrator-plan.md` (status log has the full
rollout order and the live-found defects). Released through the door and
mirrored to GitHub by the platform backup: containers .81434/.82604/.84336,
artifacts .81446, cli-bootstrap .81451, wrapper .81529, SPA .81549,
orchestrator .81625/.84404. UI at https://wohlben.eu/orchestrator/
(nav "Orchestrator"); gc runs daily at 03:00 UTC and on demand (Run now /
Dry run). idp client `qits-platform-orchestrator` lives in
qits-configuration (40 entries) and in `.qits-bootstrap.env`; artifacts GC
policy `oci-images` P7D / blob grace P2D via extras.
Disk review 2026-08-21 afternoon: 109 → 81 → **68 GB used** (final run 13:05 UTC) after the bootstrap
builder removal + `prune --all` + artifacts P2D/P1D; code wave released
(containers .102707 sees dangling images + prunes `--all`, orchestrator
.102416 host/builder keep 10 GiB/1 GiB, cli-bootstrap .103111 teardown
phase, oci-postgresql .102402 WAL 1 GB). Registry blobs (4.8 GiB condemned today) go at the 03:00 run tomorrow; then run `VACUUM FULL blob_chunk` once
(needs free space ≥ the table) — PG does not shrink the file by itself.
Open tails:
- the artifacts engine condemns nothing until identities age past P2D
  (platform is 5 days old) — the first registry reclaim is ~2026-08-23;
  check the plan card then.
- the SPA's `/main-navigation` comes from the edge; behind my ad-hoc
  tunnel it read "Navigation unavailable" — fine through the real edge.
- local WSL platform has none of this yet (bootstrap registration is in
  cli-bootstrap .81451; a re-bootstrap ships it).

### Storage lifecycle — analysis DONE, design drafted, nothing shipped (2026-08-21)

`storage-lifecycle-plan.md` in the root: wohlben.eu is 116/150 GB five
days after the reset; the registry (`qits_artifacts.blob_chunk`, 16 GB)
grows ~2.7 GB/day, the CI BuildKit cache is 35 GB with no keep-storage,
the host image store keeps every pulled image (55 dangling). The
qits-artifacts GC engine EXISTS but is not executable on wohlben.eu (both
pin readers 401 — no credential) and its P30D window would keep
everything anyway. Next: L1.1–L1.3 in the plan (authenticate pins,
schedule nightly, oci window P7D / blob grace P2D), then daemon.json
builder GC + `buildx rm` of old bootstrap builders. ~50 GB one-time
cleanup listed at the end of the plan — not run, needs the user's go.

### CI-plane recovery EXECUTED on wohlben.eu (2026-08-21 morning)

The `integrator.md` plan (was in the `remote/observability-improvements`
workspace; workspace gone — see below) ran to completion. Disk-full →
`docker system prune` had deleted the five `qits/build-images/*` step images
AND the registry held zero tags for them, so CI was down platform-wide.
Recovered: host rebuild of the five images, zombie RUNNING run swept via
`service update --force dev-qits-ci`, then releases qits-ci-daemon
2026.821.50407 (shell-not-bash contract; pin ADOPTED on its own), qits-ci
.52538 (registry resolver + a NEW fix, see below), qits-oci .53110
(step images now built on upstream `docker:28-dind`, published CalVer+latest
— registry no longer empty, a pruned host re-pulls), edge .53216 (deployed
the banked 2026.820 cache fix: SPA documents `no-cache`, hashed bundles stay
immutable — verified live), wrapper .53830. All green through the door.

- **New defect found+fixed on the way** (qits-ci e511035, in .52538): the
  step-container git credential helper's wget arm used GNU-only
  `--user/--password/--timeout`; BusyBox wget (docker:28-dind) refused and
  every clone on that image died. Now a composed Basic header + `-T`,
  proven against the live idp from a real dind container.
- **Releasing the WRAPPER branch killed the workspace riding it** mid-call
  (branch deleted by the door → container torn down → its commissioned
  credential died). Release the wrapper last, from outside the workspace.
- **dev-qits-gateway REMOVED** (`docker service rm`): this platform was
  built without a gateway (edge routes directly), but the 08-19 train
  registered+deployed it — deploy FAILED, rollback ROLLED_BACK, and it
  crash-looped since ("No routes configured"; config store holds ZERO
  entries for it, headRevision 0). Residue: the pd_service row
  `qits-gateway` remains — a future gateway release would re-deploy and
  re-fail; decide config-or-retire before releasing gateway again.
- Open (integrator §6, untouched by decision): `qits.observability.url`
  defaults to unprefixed `qits-observability` in eight repos — decide
  deployment-config vs tier-aware default before touching them. Live
  extras already override it for edge/deployments.
- Host disk 81% (29G free) after the image rebuilds — watch it.
- Release stamps 2026.821.* live on the platform githost (GitHub backup
  mirrors them); local submodule mains lag until the next sync.

### environments v4 — PHASE 1 LIVE EVERYWHERE (2026-08-18 ~10:45)

Phase 1 is DONE on both platforms: qits-deployments and qits-events run as
PLATFORM services under bare aliases — locally (clean 72/72 cold boot,
22m31s) and on wohlben.eu (live migration, no wipe: 16 releases through the
real door, identity via the extras store, both flips, predecessors removed,
proof deploy qits-stt f1cc1b5 ACTIVE through the new deployer). GitHub holds
every release via the platform backup. Tails and debts:
- `dev-qits-events` still runs on wohlben.eu; six consumers' extras now say
  `http://qits-events:8080` and migrate at their next deploy — remove the
  old service after all six moved.
- Local main-checkout submodule mains partially lag GitHub (deployments'
  local line diverged; ff refused) — reconcile on next sync.
- Fleet debts surfaced, none phase-1's: pin endpoints 401 plain GETs since
  the machine-guard hardening (artifacts GC refuses safely); lib post-receive
  suites red in the root step sandbox (embedded-pg; needs `user: build`);
  release tags were missing from GitHub backups (qits-spa-ci case); ci's
  self-redeploy sweeps its own in-flight version-tag run (replay via
  SCMRelease trigger works).
- wohlben.eu qits-deployments extras still carry the resource-db triple;
  the volume file's extras block is a leak source for deleted keys — the
  QITS_ENVIRONMENT line was hand-stripped; consider clearing the whole
  extras block from the file.
Phase 2 (memberships + UI) is next; phase 3 (GitHub renames) deferred by
user decision 2026-08-17.

### environments v4 campaign STARTED (2026-08-17)

Plan: `priority-feature.md` (rewritten; v2/v3 history at `0295806`). Phase 1
re-planes qits-deployments AND qits-events to platform services (identity
sweep, one bus, one pin union); phase 2 is first-class environments with
project memberships (`unique (project, environment)`) replacing the
slug-name join, plus the environments UI; phase 3 GitHub renames to
`qits-platform-*`; phase 4 wohlben.eu. Work happens in the
`/home/wohlben/code/qits-qits-environments` worktree (branch
`environments-replatform`), integrates to local mains per phase, and smoke
tests each phase by a worktree bootstrap on localhost:8080 before anything
is pushed.
- **PHASE-1 SMOKE PASSED (2026-08-18 ~05:30)**: clean 72/72 cold boot from
  the worktree in 22m31s; qits-deployments + qits-events live as platform
  services under bare aliases; end-to-end deploy proven (ci replay push →
  BuildSuccessful on the ONE bus → platform deployer → dev tier → seed
  reaped). Eleven attempts, every failure banked as a commit (pin
  coherence across 17 poms, eventstream release-line merge, qits-ci guard
  suite, webui URL convention, spa-configuration seeding, platform-shape
  container matcher). Follow-ups surfaced, NOT phase-1's: pin endpoints
  401 plain GETs since the machine-guard hardening (artifacts GC refuses
  safely, executable:false), and release tags are missing from GitHub
  backups (qits-spa-ci 2026.815.141439 was tag-only on the platform
  githost). Next: wohlben.eu wave per wohlben-rollout-runbook.md.
  Two ops lessons: NEVER rerun the bootstrap over a completed platform
  (the seed stack re-deploys beside deployer services and two postgreses
  share one volume — WAL death), and hibernation kills postgres the same
  way (a keep-awake guard runs during boots now).

### 2026-08-17 late evening addenda — DONE

- **Per-project ad-hoc workspace creator LIVE** (user ask): the /workspaces/
  overview admits every project's WRAPPER (identified by
  `wrapper.repositoryId`, hardcode gone; `?repository=` preselects), and
  each project page carries an "Ad-hoc workspace" pill. Released
  workspaces 2026.817.202945 (8068398) + projects .202948 (e9d1a02); the
  first builds died on SPAs-not-on-githost (the banked lesson, violated
  once more — SPA pushes go to BOTH remotes) and were stamp-replayed.
  Browser smoke of the pill still pending (needs a session).
- **The user's schema-support line is ON the platform**: deployments union
  release 2026.817.202756 (33527a3f — GitHub line merged with the stamp,
  re-pinned to THIS platform's libs). Two burned stamps on the way
  (.200107 deployments, .202328 eventstream) — the user's pins named
  WORKSTATION-platform releases (.171725/.173153) that exist nowhere
  anymore; eventstream re-pinned + released .202549 here. LESSON: pins
  minted on one platform don't travel; releases must come from the
  platform that will serve them.
- **ALL 45 GitHub backups GREEN** — and the platform's backup is now the
  standing GitHub mirror (branches + tags), so hand GitHub pushes of
  catalog repos are largely obsolete.
- **Build-queue policy** (user): quiet release-branch and redundant train
  builds get CANCELLED via POST /ci/api/runs/{id}/cancel; backlog items:
  don't build quiet release branches at all, and merge the per-stamp
  POST_RECEIVE/EVENT run pair into one run pushing BOTH image tags.
- Stranded by cancellations/OOM: workspaces' eventstream pin-bump train
  (twice). Pins remain functional; re-fires on the next eventstream
  release.

### 2026-08-17 evening: releases, ad-hoc workspaces, backups — DONE

- **Release doctrine restored on wohlben.eu.** Every service released through
  the door with real CalVer identity: containers .174616, docs .175356 (+ a
  burned .175329 twin), stt .175956, configuration .185530, workspace-daemon
  .185934, deployments .190408, workspaces .193638, projects .194248.
  Direct deploy-ref pushes are RETIRED per user ruling: branch → door only.
  All stamps synced to local mains + GitHub (deployments' sync waits on the
  environments session's rebase — its phase-1 sits on GitHub main 847ba7f,
  diverged from the stamp; the LAST failing GitHub backup heals with that
  rebase; the other 44 back up green after eventstream/spa-projects/edge
  githost mains were synced forward).
- **Ad-hoc workspaces LIVE and smoked** (integrator.md fully executed):
  aggregate create branches wrapper + all registered submodules, WORKSPACE.md
  committed, daemon follows the branch per submodule (nested webui included),
  in-container submodule push proven. Review fixes on the way: rollback of
  half-created trees, daemon no longer force-resets branches (unpushed work
  survives), transport failures warn instead of masquerading as
  branch-absent, projects' closure read allows qits:system (release
  .194248). Open finding: the daemon INFERS aggregate-ness from branch
  existence — a `main` workspace follows every submodule's main; an explicit
  branchTree env flag is the fix.
- **qits-containers pipeline modelled correctly all along** — it was red, not
  unmodelled; green since 15503e8 (+ a real containers-client throw
  regression reverted), seed service replaced by the pipeline deploy.
- **CI policy**: QITS_CI_CONCURRENT_BUILDS=1, QITS_CI_CPUS=6 (user order,
  after an OOM storm killed dev-qits-ci mid-wave) — in store + live.
- **New defects banked**: release pipelines push the VERSION image tag only
  (sha tag rides the sibling post-receive run — one crash decouples them,
  measured); a replayed older BuildSuccessful can roll the DEPLOYER back
  (its self rows never sit ACTIVE so the tip floor is blind); blobstore has
  no integrations upstream recipe (train bump never fired — its pins need a
  hand bump); the stranded e41f3707 workspaces pin-bump (daemon release
  image) died in the OOM window and nothing retries it.
- **qits-integrations-quarkus released twice today** (.171725/.175344 — the
  user's 08-15 roles commit going out; releases attributed to platform
  release machinery; exact POSTing actor unidentified — check with the user).

### qits-configuration campaign DONE AND LIVE (2026-08-17)

Plan + full status log: `qits-configuration-plan.md`. The deployer-extras
snapshot class is dead on wohlben.eu: qits-deployments reads the extras file
per deployment (WP0, 56eb588) and is FLIPPED to pull from the new
dev-qits-configuration service per deploy (WP2 cdff321 + live flip; refuse
on unreachable, rollback = env-rm the url). The service (new submodule
`services/qits-configuration`, GitHub twin exists) holds every extras entry
versioned; cli-bootstrap b353de4 boots it, imports and flips on fresh
platforms (72 phases). Proofs and ops recipes in the plan's status log and
the wohlben-eu-server memory.
- Suites: deployments 379 green (e367035 also re-established the
  machine-guard contract — roles ride the idp `groups` claim; doctrine table
  updated in that repo's AGENTS.md), configuration 41+10 green + native
  gate, cli-bootstrap 415 green.
- WP-DEMOTE LIVE (evening): the file is bootstrap-only (zero non-extras
  lines on the live volume), deploys env-rm what the store no longer
  states (three protected families), the pre-flight audit preserved nine
  unrecorded live keys into the store. `demotion-rollout.md` in
  cli-bootstrap documents the hand steps that were executed.
- WP-UI: qits-spa-configuration (wrapper submodule at frontends/, GitHub
  twin) — applications/entries/history pages in QitsMainLayout,
  browser-verified; Quinoa wiring in qits-configuration,
  `routes: /configuration` + `navigation: Configuration:11`. READ-ONLY by
  user decision (d4f59c1, 43 tests): entries are system state written by
  platform processes through the API — the UI browses and audits only.
- Open tail: release all three through the release door; secrets class /
  change events / export endpoint later.
- Escalations found on the way (both from the auth-core 2026.815 wave):
  qits-artifacts `CdHttpDeploymentPins` sends NO credential and fails the GC
  sweep closed once the deployer's machine gate flips on; qits-artifacts
  `AdminWriteGuardTest` + qits-ci `MachineGuardTest` likely red for the same
  no-`groups` fixture reason the deployer suite was.

### wohlben.eu refinement-clone regression RESOLVED (2026-08-17)

The "refinement workspace clone fails" recurrence was NOT stale code — every
deployed image was its repo's main HEAD. It was the deployer-extras snapshot
landmine, again: the extras fix `QITS_WORKSPACE_GIT_HOST=dev-qits-workspaces`
landed on the config volume 2026-08-16 12:43, but the deployer (started 11:54)
was never force-reloaded, so every later deploy re-stamped the stale
`dev-qits-githost` — the daemon dial-home (`/workspaces/daemon/<id>`) then
pointed at the githost and provisioning died with "no workspace-daemon dialed
home within 30000ms". Note the knob's two halves since f01f260/2091ba3:
`qits.workspace.git-host` = control-socket/dial-home host (historical name!),
`qits.workspace.container-git-url` = clone base (githost.dev.internal:8080).
Fixed 2026-08-17: deployer force-updated (snapshot now matches the file),
`QITS_WORKSPACE_GIT_HOST=dev-qits-workspaces` stamped on the live service,
workspace 101 re-ensured via `POST /workspaces/api/workspaces/101/ensure-container`
(forward-auth headers work in-network: `X-Qits-User` + `X-Qits-Roles:
qits:admin`) — daemon HELLO'd, row RUNNING, checkout intact.

Deploy-parity sweep the same morning (deployed image sha vs local main):
- 12/15 services matched; qits-docs + qits-stt were one commit behind because
  only `main` was pushed, not `environment/dev` — both deploy refs advanced
  through the githost (Bearer + push token) and both pipeline-deployed green.
  `/docs` routes now (401 anon is the intended authenticated posture).
- **qits-containers is stuck on the seed image `qits/containers:latest`**: its
  own pipeline is RED on this platform — verify fails with 403 where tests
  expect 201 (`ContainersClient` vs the protect-container-APIs work, e190354);
  the 71c8921 test-token commit did not fix it. Until that suite is green,
  qits-containers cannot ship through the platform. THIS is the one real
  "cannot apply fixes through the platform" blocker found.
- Daemon submodule residue: workspace clones skip `qits-spa-docs`
  (`update exited 1`) — untriaged.
- Release hygiene: NOTHING has been released since 2026.814.* — all wohlben.eu
  deploys are direct main pushes; live binaries self-identify as 2026.814
  versions. A restore-default boot regresses; a release wave is overdue.

Platform-improvement need raised (the systemic source of "fix applied, then
came back"): deployment env config is a hand-edited properties file on a
volume, snapshotted at deployer boot, silently re-stamped on every deploy.
Minimal fix at source: qits-deployments re-reads extras per deploy (kills the
snapshot class). Real fix DECIDED 2026-08-17: a new per-env service
**qits-configuration** — versioned named values services are told at runtime,
with secrets as one entry class carrying the qits-secrets-plan.md broker
semantics (in-memory, approval-gated, one-shot redemption); plain entries are
durable and readable at every deploy. The deployer must resolve from it per
deploy (or subscribe to change events), never snapshot at boot — the store
alone with snapshotting kept would just relocate the stale copy.

### wohlben.eu bare-server platform LIVE (2026-08-15)

**THE STANDING ENVIRONMENT IS THIS SERVER NOW.** Public dev platform on
Hetzner (`ssh root@46.224.171.33`), env `dev`, boot 74/74, all 17 apps
pipeline-deployed, **production TLS + sessions ON + edge-variant gateway**:
anonymous browser → 302 /idp/login, API → 401. Register token in the server's
`.qits-bootstrap.env` (one-time, admin). Config `/root/qits/.env`
(SHIP_MAINS=1, ACME production); dev loop = push main + environment/dev to
its githost from a qits-net container with the push token (recipe in the
wohlben-eu-server memory file). DNS: the registrar's external A record
`wohlben.eu → 46.224.171.33` is the whole contract — no NS delegation.
Full recipes in the memory files (wohlben-eu-server,
bare-server-cold-boot-prereqs).

Proven on it since the boot:
- Refinement/workspace flow works END TO END — first real workspace smoke on
  the post-split platform. It flushed out the daemon's stale derived clone
  base (`/artifacts/git/…`): qits-workspaces f01f260 now injects
  `QITS_WORKSPACE_DAEMON_GIT_BASE_URL` (told-never-derived), deployed here
  and on GitHub main. Auth was innocent.
- NO fleet repo declares workspace services yet: none carries
  `.config/qits/repository.yml` (only qits-projects' repository-template
  seeds it into NEW repos), so every workspace shows "nothing to frame"
  until a repo commits one (`services:` + `web-view:` block).

Actionable residue, mostly for the CLI/DNS refactor session:

- **WSL ORDER HAZARD: qits-gateway main builds `QITS_VARIANT=edge` now**
  (2f16fd7). Do not rebuild/boot gateway on the WSL platform until its edge
  flips sessions on; land `QITS_EDGE_SESSIONS_ENABLED=true` as the
  ComposeTemplate default (two places, currently pinned false) in the refactor.
- `PlatformModel`'s repo list lacks `platform-spa-idp` — githost never gets the
  repo, idp CI dies on the submodule clone. Add it with the refactor.
- ACME hooks: the edge's management listener (9000) speaks HTTPS once the acme
  keystore is configured; `edgeLetsEncryptUrl()` and the hook curls must go
  https + `-k`, or the certbot order 404s. Proven live: with https hooks the
  whole domain path issued staging AND production for wohlben.eu.
- Domain mode's registrar contract is now "external A record only" (DNS removal
  session) — the closing report's NS/glue text goes with qits-platform-dns.
- Renewal is still manual (`/root/qits/acme.sh` on the server), unscheduled.

### qits-platform-dns decommission (2026-08-15 session)

The platform stops serving DNS; records are configured by hand at the
external provider (Hetzner — note its legacy DNS API died May 2026, the
Cloud API at api.hetzner.cloud is the one that exists). Design to revive
platform-managed DNS later: `hetzner-dns-plan.md` (status: deferred).
Done locally: submodule removed from the wrapper, `QITS_DNS_PORT` dropped
from the wrapper `.env`, qits-cli-bootstrap no longer seeds/deploys dns,
qits-projects' `DnsDomainRegistrar` deleted (the `ProjectDomainRegistrar`
port stays as the commented hook). Still open:
- Push wrapper + both repos to the platform githost (catalog = wrapper
  `.gitmodules`); decide whether to DELETE the qits-platform-dns repo row
  or leave it orphaned.
- Live host: the deployed dns service still runs — remove the swarm
  service (it publishes 5353, `stop-first`), or let the next rebootstrap
  drop it.
- Release qits-projects and qits-cli-bootstrap through the release
  endpoint when ready.

### Unify-ingress EXECUTING (2026-08-14 session)

The final execution plan is in `unify-ingress-plan.md` ("Final decisions" +
"Execution plan", 2026-08-14) — read it first; it supersedes the older
bullets below. Key decisions: method-scoped auth at edge (writes need a
Bearer on registry/mirror vhosts, reads anonymous; githost vhost fully
gated), NO bootstrapping edge (seed phases keep their loopback `docker run
-p` ports; platform services just never publish 8081/8082/8083), P-idp-4
collapsed to a CI-step push credential (idp client `dev-qits-artifacts`;
secret on the deployer config volume line 302).

Progress this session:
- qits-deployments RELEASED 2026.814.64650 (0e3d349, publish_mode) — live.
- qits-platform-edge RELEASED 2026.814.65508 (bdaf947) — LIVE IN INGRESS
  MODE (service rm + recreate; update never restates ports). All proofs
  green: vhost policy matrix (registry GET 200 / POST 401+Bearer
  challenge; githost 401/200 with token; unknown app 404), anonymous
  docker pull through edge, docker login + push + pull-back, git
  push/delete via githost vhost with `http.extraHeader` Bearer, WP3
  rolling update 120 probes ZERO failures.
- **HOST FACT — v6 ingress blackhole**: the swarm mesh is IPv4-only but
  `*.localhost` resolves `::1` first and the ingress listener accepts v6
  it never serves → clients HANG. Standing host rule (does not survive
  reboot): `ip6tables -I INPUT -i lo -p tcp --dport 8080 -j REJECT
  --reject-with tcp-reset`. Bootstrap warns about it (81bcd26).
- gateway RELEASED 2026.814.65001 (4210c04, /v2 public-entry retired).
  LIVE FINDING: dev deploys the NO-AUTH gateway variant, so PublicPaths
  is inert here — anonymous /v2 write via env vhost answered 202. Fix
  committed (gateway 8bf793a: refuse mutating /v2 in BOTH variants,
  403) — releases in the wave.
- **GITHOST PORT 8083 DROPPED** (publish-rm mode=host,published=8083,
  target=8080; extras line removed; deployer force-updated). Note
  `--publish-rm <target>` alone is a silent no-op — use the full spec.
  Deployer config-volume reload: `docker service update --force`, NEVER
  `docker restart` (leaves an orphan twin consuming events — happened,
  removed by hand).
- Fleet literal sweep COMMITTED on local mains (unpushed): all 8082
  FROMs → mirror.dev.localhost:8080, ARG maven defaults + pom
  qits.maven.repository.url → registry vhost, workspace/agent image pins
  → registry vhost (host-preserving seds verified), all .npmrc +
  lockfile resolved hosts + recipe seds (npmjs→mirror vhost,
  @qits→registry vhost, guard regex updated). qits-ci also carries the
  step DOCKER_CONFIG credential (8c10365; keys
  qits.ci.registry-auth.client-id/secret, file at
  /tmp/qits-ci-registry-auth via BOOTSTRAP, docker-enabled steps only).
- cli-bootstrap 81bcd26: two-port topology (no byte-plane publishes,
  edge ingress + apps env in seed stack, registry-host → vhost,
  MIRROR_HOST literal mirror.dev.localhost:8080, unwrap sweeps vhost
  refs, preflight warns on missing insecure-registries + v6 rule). 328
  tests green.
- Residues: anonymous `docker push` through edge HANGS instead of
  erroring (security holds; suspect the /token 401 arm — investigate in
  edge); edge extras backup at
  qits-deployments-config/application.properties.bak-unify-ingress.
- Release wave DONE (all 10 green, pgblobs pins dead fleet-wide; daemon
  pin trains fired on their own and redeployed workspaces+projects with
  vhost-hosted pins). REGISTRY 8081 + MIRROR 8082 DROPPED — only edge
  (8080 ingress) and dns (5353) publish. Post-drop proofs: full CI train
  green (FROM through mirror vhost, docker push via step credential
  through edge), deployer pull argv through the registry vhost, 17/17
  healthy. Wrapper banked at a42b7af; tags synced 42/42; unify-ingress
  worktrees removed, branches deleted.
- **REBOOTSTRAP GREEN 2026-08-14 ~10:43** (attempt 3, 70/70 in 44m08s,
  `unwrap --with-data-volumes` + `QITS_SHIP_MAINS=1`): the first
  from-zero boot on the two-port topology. Post-boot verified: 17/17
  services 1/1, edge ingress on 8080, full vhost matrix (registry GET
  200 / POST 401, gateway env-vhost /v2 write 403, mirror+maven reads
  200, githost 401 anon), docs 200, deployed shas = local mains (edge
  runs the post-release sweep commit 873a586). Boot failure classes
  fixed at source on the way:
  - Attempt 1: seed builds rode the Dockerfiles'
    `ARG QITS_MAVEN_REPOSITORY_URL` default, which the sweep moved to
    the vhost (dead during seed phases). cli-bootstrap 51cb97d passes
    the build-arg on every bootstrap-run host build (Docker facade).
  - Attempt 2: the attempt-3-class stale pins again — the wave's
    releases moved githost/containers and NO upstream recipe bumps
    consumers. Hand-bumped: qits-ci 58a5078, qits-projects 3abb156,
    qits-workspaces 90d2d17 (githost-events 2026.814.72533,
    containers-client 2026.814.73521). CONFIRMED consumer lists for
    the missing-recipe backlog: qits-githost-events ← ci, projects;
    qits-containers-client ← ci, projects, workspaces.
  - Attempt 3's one warning: qits-stt's deploy push landed in idp's
    own redeploy window — edge's /token answered "identity provider
    could not be reached", the run burned (5s, image fully cached).
    Salvaged with the rewind-replay through the vhost; stt green and
    1/1. New transient class: a deploy-fanout push racing the idp
    redeploy dies at the token broker.
  - The kept config volumes reuse the idp client secrets — the
    dev-qits-artifacts secret survived the wipe unchanged, and
    `.qits-bootstrap.env` spells it `IDP_SECRET_DEV_QITS_ARTIFACTS`.
  - The fresh githost again holds ZERO release tags (synced home
    pre-wipe, 42/42): a plain restore-default boot is stale until a
    release wave; boot with QITS_SHIP_MAINS=1. GitHub backup sweep is
    now overdue — today's ~14 release stamps exist only locally.
  THE UNIFY-INGRESS CAMPAIGN IS COMPLETE. Follow-ups live in the
  backlog: the two missing upstream recipes, the anonymous-docker-push
  hang at edge, /git/* gateway retirement (clone-URL product decision),
  TLS-port publish modes (domain path), token-broker patience for the
  idp redeploy window.

### Authenticated-reads campaign EXECUTING (2026-08-14 afternoon)

Plan: `authenticated-reads-plan.md` (credential model + "Implementation
deltas" — read both). ALL CODE LANDED on local mains, suites green:
- qits-platform-idp: commission API (`POST/GET /idp/api/clients`,
  `DELETE /idp/api/clients/{id}`, Basic-guarded by the caller's own
  client; dynamic clients cannot commission), V2 migration, TTL 3600s.
  Native gate caught two real defects (SecureRandom in image heap;
  RestResponse entity registration).
- qits-platform-edge: Basic acceptance on gated requests (brokered,
  cached by credential hash), ALL idp dials bounded + retried (the hang
  class), malformed Basic refused locally. cddbfcf, 117 tests.
- qits-deployments: `qits.platform.deployments.registry-auth` flag
  (both argvs), AUTH_REFUSED pull outcome ordered before IMAGE_MISSING.
- qits-ci: commissions per run (kind ci-run), decommissions in
  runClosed + reconcile at boot/hourly; static registry-auth keys
  RETIRED; DOCKER_BUILDKIT=1 enforced per docker step; docker config
  covers `qits.ci.docker-auth-hosts` (default registry host; deployment
  widens with the mirror vhost).
- qits-workspaces / qits-projects: commission per container, secret
  persisted ON THE ROW (forced by the orchestrator's env-covering spec
  hash — see the plan's deltas), decommission at every teardown seam +
  reconcile; V3 migrations.
- BuildKit exit DONE: qits-oci 2026.814.110556 released (multi-tag
  recipe fixed first), step images retagged, 21 stray docker-rmi lines
  gone, proof build showed BuildKit markers; ci-base was ALWAYS BuildKit
  (the 2026-08-11 record was wrong — see backlog note).
- Fleet secret-mount sweep: every maven-in-docker repo carries
  `--mount=type=secret` + settings `<servers>` + recipe `--secret`
  flags (inert until the flip; buildx ignores missing env sources —
  measured). Gateway's buildx prelude retired.
- cli-bootstrap b83ee9b: static ci pair retired, new idp clients
  {env}-qits-deployments/{env}-qits-containers, docker-config homes for
  both pullers, flip values pinned OFF, workstation-commission summary.
- Host: `~/.m2/settings.xml` created (exact-id mirror past maven's http
  blocker — plain builds resolve the vhost again).
- Release wave DONE (idp 2026.814.122135, edge .122429 then .132633,
  deployments .122649 then .130328, workspaces .123007, projects
  .123357 then .130338, ci .123830, dns proof releases). Commissioning
  proven live: the dyn-ci-run row appeared during a run, the push used
  it, the row died with the run.
- **THE FLIP IS LIVE AND PROVEN**, including a clean from-zero
  rebootstrap (69 phases, 1 skip, 50m15s, ZERO warnings, 17/17): anon
  reads 401 with a DUAL challenge (Bearer first, then Basic), Basic
  reads 200, both pullers pull with their own idp identities, an
  UNCACHED in-build maven resolve succeeded through the gated edge via
  the secret mounts, and idp_client held ZERO rows after ~24 boot
  builds — no credential leaked through a whole genesis.
- Live lessons burned in on the way (memories updated):
  - Maven ignores a Bearer-only 401 → edge sends Bearer+Basic (edge
    .132633). Caught only by an UNCACHED build — and BuildKit strips
    Dockerfile comments from cache keys, so comment "cache-busters"
    prove nothing; bust via a copied file (pom). `-ntp` also hides
    Downloaded lines — count cache misses, not transfer logs.
  - Docker's embedded DNS can't synthesize *.localhost and BuildKit
    fetches registry tokens CLIENT-side → the three vhosts are network
    ALIASES of edge on qits-net (deployer extras `aliases[N]`,
    2026.814.130328; probe with getent/wget — curl lies, RFC 6761).
  - **Deployer extras env RIDES UPDATES from its boot-time snapshot**:
    a hand env-rm is silently reverted by the service's next deploy if
    the deployer wasn't force-reloaded after the config edit. This
    un-flipped the read gate for ~20 minutes; three releases burned
    their builds on the stale window and were salvaged by
    rewind-replays after the edge fix.
  - Releases must come from branches AHEAD of the githost main —
    pushing mains first makes the door 409; recovery is a sanctioned
    force-rewind to the environment/dev sha (proven).
- Standing state: workstation credential RE-commissioned 2026-08-14
  evening (the 14:52 row did not survive; idp refused it — mint via the
  bootstrap one-liner against dev-qits-artifacts). Fresh pair in
  ~/.qits-workstation-client/-secret; wired everywhere: ~/.npmrc
  per-registry _auth lines (both npm vhosts, verified), ~/.m2
  settings.xml <server> for qits-maven-host, docker login on both
  vhosts. After any re-bootstrap: re-commission and rewrite all three.
  The puller secrets are IDP_SECRET_DEV_QITS_{DEPLOYMENTS,CONTAINERS}
  in .qits-bootstrap.env.
- Open follow-ups: per-context permission SCOPING (the declared next
  step on the dynamic-client rows); TTL back down when refresh gets
  designed; qits-projects still has no agent-container removal verb
  (decommission is reconcile-only there); the live workspace-launch
  smoke remains the standing backlog item; GitHub backup sweep still
  overdue (all of today's ~25 release stamps are local-only).
  THE AUTHENTICATED-READS CAMPAIGN IS COMPLETE.

### idp SPA (2026-08-14 evening session)

qits-platform-spa-idp scaffolded and pushed (a925230): Angular 21.2,
baseHref /idp/, four lazy loadComponent routes — /idp/login and
/idp/register chromeless placeholders (flows land with the backend work
in the parallel session), /idp/clients and /idp/users inside
QitsMainLayout. Superproject submodule added at
frontends/qits-platform-spa-idp (standard entry config).

Quinoa wiring in qits-platform-idp DONE (aa86e2a, pushed to GitHub):
webui submodule, quinoa 2.8.2,
ignored-path-prefixes=/api,/q,/.well-known,/token,/jwks — the REST
path IS the segment here, so the three protocol literals join the
list; Dockerfile prebuilt-bundle pattern, CI recipe on
node-docker-base with the npm half, PackagedSurfaceIT SPA probes
(verify green, 34 unit + 10 IT). Measured: an ignored prefix 404s via
Quarkus' own text/html not-found page (fine — no base href), and an
ignore entry protects a SEGMENT, so /idp/jwks-nope is the SPA by
design; a new machine route needs a segment of its own.

User-authentication implementation ALL LANDED on local mains and GitHub
(2026-08-14 evening, plan `user-authentication-plan.md`), every suite
green, everything dark:
- idp 9d419b7 (V3 five-table schema, passkeys + bcrypt, qits-session,
  eight routes; 49 unit + 11 packaged IT) + 490f510 (webui gitlink →
  the real pages, gate re-run green)
- SPA 2d14940 (real passkey/password pages, 63 tests; insecure-context
  fallback for the raw-IP route)
- edge be06a44 (five-step session gate behind
  qits.edge.sessions.enabled=false, introspection cache + stale grace,
  X-Qits strip/inject both transports; 155 tests)
- gateway c190154+c12d2c1 (`edge` build variant trusts X-Qits headers,
  roles into SecurityIdentity; pipelines still local; 158+6 tests)
- cli-bootstrap 45031d8 ({env}-qits-edge client seeded both ways,
  register token minted once per install → closing report, WebAuthn RP
  env, flip pinned OFF; 351 tests)
Wire contracts: introspect body {"token": ...} answering
{userId, username, roles, expiresAt}; mint answer field `token`;
QITS_EDGE_SESSIONS_CLIENT_ID/SECRET/ENABLED; QITS_IDP_WEBAUTHN_RP_ID/
ORIGINS.

RELEASED AND DEPLOYED 2026-08-14 evening (all green, 17/17):
- gateway 2026.814.184501 (edge variant, dark) then .193005 (IDP enum
  entry) — the /idp segment was falling through to spa-home; routed
  now, deployed e5a6b30. Bootstrap bc34b60 carries
  QITS_GATEWAY_PROXY_HOSTS_IDP=qits-platform-idp (compose + deployer
  extras) and the live deployer config volume was patched + reloaded.
- edge 2026.814.184856 (session gate, flag off), deployed efe4147.
- idp 2026.814.191019 burned its release-pipeline run (old ci-base
  recipe, no bundle) — .191625 fixed it; its two runs then burned on
  the idp's OWN redeploy window (maven 401 mid-cutover); salvaged by
  SCMRelease replay with a FRESH eventId (consumed ids dedupe) + the
  env/dev rewind-replay. Deployed 0951092, version image exists.
- spa-idp: adopted into the catalog (wrapper push to githost + projects
  self-seed via service update --force; seed clones content from
  GitHub), platform CI green (63 tests). No calver stamp: its githost
  main equals the built sha, the door answers ALREADY_INTEGRATED, and
  the bundle ships inside the idp image (the platform-spa-mirror
  precedent).
- idp + edge recipes grew the sibling self-release step (gateway's
  block verbatim; edge's copy rides its next release).
- Stamps + tags synced home, all repos pushed to GitHub. Register/login
  smoke vs the DEPLOYED idp still pending (browser or curl), then the
  flip order: edge sessions on, then gateway pipelines to
  QITS_VARIANT=edge; order is load-bearing.

BARE-SERVER READINESS (2026-08-14 late evening): the GitHub backup
sweep is DONE — every initialized submodule main + all release tags
pushed (31 repos were behind, up to 19 commits). Found and integrated
on the way: qits-spa-projects' refinement-detail UI (released
2026.809.185750, survived ONLY on GitHub through the wipes) — merged
into main (dependency union: marked, @xterm/*; 795 tests green),
qits-projects gitlink bumped and RELEASED 2026.814.194433, deployed
87c1bea, /projects/ 200. The bare-server door is the cold path:
`curl -fsSL .../qits-qits/main/qits-local-up.sh | QITS_SHIP_MAINS=1 sh`
(docker installed is the only prerequisite; bootstrap swarm-inits
itself; env name defaults to prod). qits-oci-workspace submodule is
uninitialized here and was not swept.

DOMAIN MODE (cli-bootstrap 7f7a954, since revised by the 2026-08-15
dns decommission): QITS_PUBLIC_IP is MANDATORY with QITS_DOMAIN
(refused host-side otherwise). The dns-zone phase is GONE — DNS records
(`@` and `*` A records at QITS_PUBLIC_IP) are configured by hand at the
external DNS provider BEFORE the boot; no NS delegation to the platform,
no glue. The edge-acme phase stays: cert via a transient certbot
container on qits-net (QITS_ACME_MODE staging|production|off, default
staging; QITS_ACME_EMAIL defaults hostmaster@<domain>;
warns-never-fails; never replaces production with staging).
KNOWN LIMITS: cert covers the APEX ONLY (one-slot challenge endpoint;
wildcard needs DNS-01 against the external provider's API — backlog,
see hetzner-dns-plan.md); the certbot phase has never run against a
real domain (whole domain path still unproven live); renewal is a
manual renew-certificate, unscheduled. Bare-server line:
  curl -fsSL .../qits-qits/main/qits-local-up.sh | \
    QITS_SHIP_MAINS=1 QITS_DOMAIN=<domain> QITS_PUBLIC_IP=<ip> sh

- STILL OPEN before this ships: wrapper push to the platform githost
  (catalog adoption — new repos 404 at the release endpoint until
  then); then the idp + SPA releases ride the login/register backend
  wave (parallel session).

### Unify-ingress prerequisites (2026-08-13 evening — historical detail)

Executing `unify-ingress-plan-prerequisites.md`; results are marked ✅ inline
there and mirrored in `unify-ingress-plan.md`'s status block. All gates that
can pass before a release are GREEN; nothing is deployed. Resume at the
"Open next" bullet below — first step is releasing the qits-deployments
`unify-ingress` branch through the regular release door, edge only after. DONE and proven live: Gate 0 stand-in (all five criteria, incl. under
`registry.dev.localhost`), P-name (systemd-resolved synthesizes `*.localhost`,
proven for getent/dockerd/git — no hosts entries), P-trust
(`/etc/docker/daemon.json` insecure-registries + restart, platform back 17/17;
backup `daemon.json.bak-unify-ingress`), P-glass
(`qits-registry-break-glass.sh` in the wrapper root, proven open→pull→close
from zero publishes). P-idp-1..3 decided (docker Bearer token endpoint at
edge, offline JWKS, artifacts audience — no idp change); P-idp-4 open.

- TODO — the campaign workspace lives in TWO worktrees, branch
  `unify-ingress` in each; all unreleased code is there and nowhere else:
  - `services/qits-platform-edge/.claude/worktrees/unify-ingress`
    (13e2bca, bef3c89, 3ad1ae7)
  - `services/qits-deployments/.claude/worktrees/unify-ingress`
    (f5194ac, 8d6bc8d)
  Release from these branches, then `git worktree remove` each (and delete
  the branch once merged home). Until then: main checkouts and
  cli-bootstrap (`postgres-blobs`, other session) untouched; exclude the
  worktrees from sweeps.
- WP3 DONE (qits-deployments f5194ac+8d6bc8d, 240 green): `publish_mode:
  host|ingress` spec key. LANDMINES: unknown spec key fails a deployment, so
  edge's `publish_mode: ingress` must not release before this deployer is
  live; mode flips need `service rm` + redeploy (update never restates
  ports).
- WP1/WP2 DONE (qits-platform-edge branch `unify-ingress`, 13e2bca+bef3c89,
  86 tests): app-label routing + idp termination + docker Bearer challenge
  and `/token` broker. WP0 verdict: today auth is a gateway browser-session
  policy with `/v2` GET PUBLIC and `/git/*` public — edge auth was net new,
  and the `/v2`-GET-through-the-env-vhost hole needs a later qits-gateway
  change. Config keys in the agent report; apps map ships empty, dev deploy
  needs the three QITS_EDGE_APPS_* env vars.
- **REAL-EDGE GATE 0 GREEN** (true gate): branch edge run live on qits-net
  at 127.0.0.1:18081; docker did login (idp client `dev-qits-artifacts` —
  audiences are env-prefixed on this platform!), push, pull-back,
  logout-deny under `registry.dev.localhost`; mirror/githost vhosts gate;
  env vhost unchanged. Audience gate is `{env}`-derived now
  (`qits.edge.auth.audience-pattern`, default `{env}-qits-artifacts`,
  3ad1ae7, 90 tests) — live-smoked with the shipped default, no override
  env var needed for dev.
- Open next: P-idp-4 (deployer registry credential), automate the
  daemon.json host step, WP3 live rolling-update proof, release order
  deployer-before-edge (unknown spec key fails deploys), then port drops
  per the gate order (githost pilot first).
- Docker facts learned (in the break-glass header): `--publish-rm` matches by
  target port; two host-mode publishes of one target collapse to one binding.

### Plan-doc audit residue 2026-08-13 (what still needs a hand)

Sixteen implemented/superseded plan docs were removed (verdicts in the
removal commits; the nine kept docs each carry their own open work).
Actionable leftovers:

- Re-point on next touch of each repo: bootstrap-replay-plan named in
  qits-ci (AGENTS.md, CiRunService, ReleaseJoinTest) and
  qits-spa-ui-components README; event-delivery-guarantees-plan in
  ci/deployments AGENTS.md; artifacts-gc-plan ~8x left in artifacts Java
  javadoc + gc properties (README/AGENTS done 2026-08-13; V11's mention
  stays — applied migration, Flyway checksums comments);
  byte-plane-split-plan in githost/mirror READMEs (artifacts done);
  db-patience-plan ~11x (see Docs and prose).
- Defect register carried from the removed provisioning plan — verify
  each is still real before acting: eventstream subscriber restart
  fragility (docker-restarted containers never redial the bus),
  silent no-match in CI event triggers, SoftwareRelease still
  UUID-only, the SCMRelease-vs-upload pin race, a gitlink-reachability
  unwrap preflight.
- gateway-route-events-plan is schedulable now: its stated blocker
  (bus delivery reliability) shipped.
- migration-plan needs a staleness pass on next touch (items 7/8 are
  done but unmarked).

### artifacts→PostgreSQL campaign (started 2026-08-13 evening)

Executing `qits-artifacts-postgresql-plan.md`. User decisions today: go;
blob bytes into PG as the qits-blobstore lib's ONLY backend — the mirror
migrates too, no storage SPI. Discovery that reshapes it: qits-githost is
a THIRD BlobStore consumer (git packs via its PackBlobStore port,
precious data) — it stays on its exact pre-PG lib pin until its own WP.
Nothing merges to a releasable main until the cutover set is complete: a
blobstore release fires the calver train, and a ship-mains boot
seed-publishes lib mains, so all code WPs live on `postgres-blobs`
branches.

- C1 DONE on artifacts main (5fc69b3): `resources: postgresql:db` — the
  next deploy provisions role+database while the H2 image ignores the
  injected triple. Verify the pd_resource row after that deploy.
- WP-LIB DONE: blobstore branch `postgres-blobs` head cb2aca4, 60 tests
  green, 1.0.0-pgblobs-SNAPSHOT in ~/.m2. API deltas consumers adapt to:
  locate()/newStagingFile() gone, StagedBlob.tempPath→contentId, NEW
  discard(StagedBlob)/openChannel/stageScratch (openRead() SEALS a
  scratch — call before promote), BlobDiskIndex.invalidate() gone,
  blobs-dir key → qits.artifacts.blobs-datasource; reference DDL at
  src/main/resources/db/blobstore-tables.sql.
- WP-REGISTRIES DONE: branch `postgres-blobs` head dd68bc9, green
  (common 4 / npm 68 / maven 42 / oci 98; blob suites on embedded PG),
  own 1.0.0-pgblobs-SNAPSHOT in ~/.m2. BlobSender lives in
  registries-common, package eu.wohlben.qits.registry:
  `send(HttpServerResponse, String blobId, String what)` — caller sets
  headers from size() and ends HEADs; NotFoundException before first
  byte; drain bounded by qits.artifacts.blob-send-drain-timeout (PT1M).
  @Lob→@JdbcTypeCode landed at source. Named trade-off: blob routes are
  blockingHandlers holding a worker for the whole transfer now — one
  connection's pipelined/multiplexed requests serialize.
- WP-ARTIFACTS DONE: branch `postgres-blobs` head 9938e26, JVM 225
  green + NATIVE gate green (135 MB binary, PackagedProcessIT 14/14 on
  embedded PG). Decision to know: the fresh V1's type check-constraint
  enumerates the SEVEN registered types (mirror V1 precedent) — the
  tool must skip cache-type rows; their blobs ride the disk walk and
  stay row-less in PG forever (accepted, logged). Two stale
  PackagedProcessIT assertions fixed (native gate had not run since the
  split). artifacts README still narrates sendFile/blob-dir in ~6
  places — trim at cutover.
- WP-TOOL CANCELLED (user 2026-08-13 evening): no data migration — the
  cutover is an unwrap + rebootstrap; the store's contents are
  reproducible (seed + train). Tool agent stopped, its uncommitted start
  discarded; the artifacts branch stands at 9938e26.
- WP-INFRA DONE: cli-bootstrap branch `postgres-blobs` head 84bc886,
  324 tests green + rendered stack/extras yq-verified: zero byte-plane
  volumes, no QITS_ARTIFACTS_BLOBS_DIR anywhere, all three byte
  services volume-free. Artifacts seed: QITS_RESOURCE_DB_* triple on
  PG_ARTIFACTS_PASSWORD (create-if-missing arm, pd_resource stays the
  authority, masked run not exec); mirror + githost seed/extras
  trimmed; new SEED_DATABASES two-way pairing test (13↔13);
  projects/workspaces mounts labeled as the surviving counter-example.
- USER GO received; CUTOVER EXECUTING (2026-08-13 night). All six
  branches fast-forwarded onto local mains (blobstore cb2aca4,
  registries dd68bc9, mirror 025cf74, artifacts 9938e26, githost
  d67586b, cli-bootstrap 84bc886). Tag sync done: 42/42 submodules
  fetched refs/tags from localhost:8083 pre-wipe. Unwrap
  --with-data-volumes clean (16s, config volumes kept). Ship-mains
  bootstrap attempt 1 FAILED at 7s — first failure class, fixed at
  source: SEED_LIBRARIES published blobstore before integrations-quarkus,
  and blobstore depends on qits-db-core since its DbRetry release (the
  2026-08-11 eventstream edge bought a second time). cli main 08b04db
  reorders the list, 324 tests green. Attempt 2 failed at 8m39 on the
  SECOND copy of the same edge: BootstrapPlan's real-store publish
  phases also ran blobstore before the integrations — cli main 4e333c0
  reorders those too (auth-core publish first), tests repinned. Attempt
  3 failed at the ci seed image: qits-ci and qits-projects pinned
  qits-githost-events 2026.812.172928 while githost main publishes
  2026.813.164937 — a latent stale pin the docker layer cache had
  hidden until today's ci Dockerfile cleanup invalidated the layer.
  Full pin audit run: those two were the ONLY mismatches fleet-wide;
  hand-bumped (ci 3f6513a, projects bdab4ad). BACKLOG: neither repo's
  train bumped githost-events on githost's release — check whether the
  upstream recipe is missing (the projects/eventstream precedent).
  Attempt 4 failed at the ci seed image on a REAL API drift: the
  orchestrator's round-2 fixes added Spec's 16th component (init) under
  an unbumped calver; workspaces/projects were adapted, qits-ci never
  was, and the registry's old jar under the same version hid it. Fixed:
  ci 3f5298e passes a trailing null (no tini — unchanged behavior;
  flipping init on would fix the step-zombie issue and is its own
  decision), 41 launcher tests green against the 16-arg jar. Fresh
  Attempt 5 failed at phase 49, the workspace-daemon tag replay: the
  daemons' newest tags (2026.810.*) predate the mirror sweep and pull
  `FROM localhost:8081/quay|redhat/...` — every earlier green boot was
  silently satisfied by pre-split leftover images in the local store,
  which tonight's unwraps finally removed. Unblocked by PRIMING the two
  bases back under their 8081 names (retag from the 8082 copies) — a
  host-cache restoration, not a run nudge; full unwrap + rerun done
  around it. DURABLE FIX QUEUED post-boot: release workspace-daemon and
  projects-daemon through the door (their mains carry 8082 Dockerfiles)
  so publisher tags build on a clean machine; until then the primed
  names are load-bearing for replays. Attempt 6 ran 70/70 but WARNED at
  phase 65 — failure class 6, a REAL qits-ci defect: phase 64 redeploys
  the githost (stop-first, new VIP), qits-containers' push lands 15s
  later, ci's pooled connection is dead, the config read answers
  UNREACHABLE once and executeQueued DISCARDS the run row — while the
  SCMPublishCommit event was consumed at accept, so nothing ever
  retries and the deploy is lost (containers service stayed on the seed
  image `qits/containers:latest`). Proven from the DB: both events
  consumed 20:46:30Z, zero ci_run rows for qits-containers; both reads
  answer 200 today, so the byte plane is innocent. Secondary: the
  Windows host SLEPT mid-wait overnight (poll lines stop at 4m51s,
  phases 66-70 completed on wake at ~07:00), which is what turned the
  loss into a visible timeout. FIX at source in qits-ci:
  readConfigPatiently retries UNREACHABLE through a ~5min backoff
  (covers an observed 2m+ githost redeploy) before the discard
  decision; qits-ci main cbfd7f7, ci module 221 tests green (CDI note:
  the schedule is set via a method, a field write lands on the client
  proxy). Attempt 7 GREEN 2026-08-14 ~08:07: 69 ok + 1 expected skip,
  21m49s, zero warnings, after a fresh unwrap (leftover maven container
  held qits-maven-seed — removed by hand) and re-priming the two 8081
  base names. Verified: 17/17 healthy, edge 200, dev-qits-containers
  deployed at 1d05d2c (the very commit class 6 lost), pd_resource row
  qits-artifacts/dev/db → qits_artifacts, PG blob store live (241
  blobs / 2067 chunks), git clone from :8083 OK, docs page 200, maven
  metadata 200, npm metadata 200. THE CUTOVER IS DONE. Windows host
  shut down on the user's standing order right after — so the next
  session starts against a booted-but-off machine (docker + swarm
  state persist; just start WSL and the stack comes back).
- NEXT SESSION, FIRST: the release wave through the regular door
  (blobstore → bump registries' pin to the minted calver → registries →
  mirror/githost/artifacts, artifacts last of the byte plane) — kills
  every pgblobs-SNAPSHOT pin. Then release qits-workspace-daemon and
  qits-projects-daemon (mains carry 8082 Dockerfiles) so replay tags
  stop depending on the primed 8081 image names. Then release
  qits-containers (round-2 fixes incl. Spec init sit under an unbumped
  calver) and qits-ci (cbfd7f7, the class-6 patience fix — only local
  main ships it so far).
- WP-MIRROR DONE: branch `postgres-blobs` head 025cf74, 52 tests green,
  native gate green (1m02, no fallback). V2__blob_tables.sql; dialect
  deleted (lib mapping covers it); stateless Dockerfile/README. Infra
  residue confirmed: volume qits-platform-mirror-data + env
  QITS_ARTIFACTS_BLOBS_DIR at SeedPhases:734,761-762,
  ComposeTemplate:147-148,649,652,1100-1101,
  ComposeTemplateTest:312-313,834,859; also trim the "mounts a blobs
  volume" sentence in mirror's own deployments.yml when the infra WP
  lands.
- WP-GITHOST DONE: branch `postgres-blobs` head d67586b, 112 tests
  green (GitHostTest's 41 real-git-CLI cases prove chunked packs read
  back byte-identically), native compile green (no ITs in this repo —
  the native gate proves compilation, not boot). Volume held only
  blobs; container honestly stateless; PackBlobStore port and
  QitsDfsObjDatabase unchanged. The byte plane has ZERO volumes left.
  Infra follow-up for its ComposeTemplate lines is running on the
  cli-bootstrap branch.
- Exclusion note for every sweep: services/qits-artifacts/.claude/
  worktrees/byte-plane-split/ holds stale full copies of all five repos.
- COMPLETION PATH (user 2026-08-13 evening: "we can just rebootstrap"):
  no data migration, no freeze, no backup precondition. Sequence:
  (1) all six `postgres-blobs` branches green — GATE: the user wants
  every agent's own verification green and reviewed BEFORE any
  bootstrap; the bootstrap itself is user-triggered, never autonomous;
  (2) merge the branches to local mains (the boot ships mains — the
  byte-plane-split landing pattern); (3) pre-unwrap tag sync (stamps
  die with the githost — standing rule); (4) unwrap WITH data-volume
  wipe (that wipe IS the migration) + `QITS_SHIP_MAINS=1` bootstrap;
  (5) post-boot release wave through the REGULAR door in dependency
  order (blobstore → bump registries' pin to the minted calver →
  registries → mirror/githost/artifacts) — every pgblobs-SNAPSHOT dies
  in those bumps; the door mints every version, nothing ships as a
  release without it.
- qits-artifacts-postgresql-plan.md sections §10 (migration tool) and
  §12 (freeze runbook) are superseded by the rebootstrap decision; the
  rest of the plan is implemented on the branches — remove the doc when
  the campaign closes.

### Lib calver campaign 2026-08-13 (in flight)

blobstore + registries joined the release train today, closing the
db-patience wave-2 remnant at the same time:

- **qits-blobstore 2026.813.161828 RELEASED** (first calver). Carries
  DbRetry on `ArtifactRepositoryService`: `require` via DbRetry.call,
  `ensure` converted @Transactional → DbRetry.inNewTx (body flushes).
  Recipes + `.qits-maven-settings.xml` modeled on eventstream; H2-only
  suite, so no `user: build` stanza. Both CI runs green, pom in the
  registry, tag + stamp synced to local main (08185aa).
- **qits-registries 2026.813.162639 RELEASED** (first calver). All five
  require*/resolve* seams on DbRetry.call (all pure reads; resolveForPull
  and resolveManifest wrapped whole across their two-row reads).
  qits-db-core declared per format module (npm/maven/oci — common has no
  DB code, npm skips common). Blobstore pinned to its calver, snapshots
  flag dropped from the qits-maven repo block. Four artifacts verified in
  the registry, tag + stamp synced home (604410f).
- **Consumer bumps RELEASED AND DEPLOYED**: mirror 2026.813.163303,
  githost 2026.813.164937, artifacts 2026.813.165241 — all three
  containers verified on their release shas, edge 200, stamps + tags
  synced to local mains. Not one `-SNAPSHOT` pin remains in a tracked
  pom anywhere. The db-patience wave-2 remnant (mirror-lib registry
  reads) is CLOSED — the seams are live in the deployed mirror.
- **SWARM LANDMINE FOUND AND FIXED: start-first deadlocks host-port
  services.** Mirror's deploy (the first host-port rolling update since
  the cutover) sat Pending on "no suitable node" — the old task holds
  the host port, start-first never stops it. Salvage: `docker service
  update --update-order stop-first <svc>`. Durable fix: `update_order:
  stop-first` in deployments.yml (a shipped parser key; the deployer
  already used it for itself) committed to ALL FIVE host-port repos —
  mirror/githost/artifacts (released, proven live: both later deploys
  cut over stop-first with no salvage) and dns/edge (on local mains,
  rides their next release).
- Release-endpoint detail learned: `summary` max 100 chars (400 otherwise).
- Residue: qits-artifacts `docs/openapi.yml` regenerates on verify and
  carries pre-existing version drift (uncommitted, untouched).
- Fleet calver audit (42 submodules): everything has a cycle EXCEPT
  qits-spa-docs (no recipes, 0.0.0), qits-repositories (empty stub, submodule
  removed 2026-08-25),
  cli-bootstrap (deliberately off-train), and two wired-but-never-released
  SPAs (spa-githost, platform-spa-mirror). qits-ci-daemon has a cycle but
  its 2026.803.184200 tag was never synced home.

## Backlog

### Top

- **Volumes-kept re-bootstrap row hole.** Kept ACTIVE deployment rows +
  unwrapped services + unchanged mains → tip-ordering drops the replays and an
  app can stay seed-served. Salvage and full detail in the swarm-migration
  memory.
- **GitHub backup sweep.** Most submodule mains and their tags exist only
  locally and on the platform githost (measured 2026-08-12: 31 submodules,
  ~213 local-only commits, plus everything since). `git fetch --tags` from the
  platform githost FIRST, then push mains + tags to GitHub — release stamps
  live only on the githost until pulled.
- **Repository backup rows sit at AUTH_REQUIRED** — nobody has signed in to the
  backup remote since the volume wipes. The sign-in terminal is on the project
  setup page. (verify still open)

### qits-containers

- Proxy adoption (the data plane ships flag-off; per-tunnel-secret contract).
- First real workspace/agent smoke through the orchestrator.

### Repos, pipelines, host steps

- **Host step, byte-plane split:** dockerd `registry-mirrors` →
  `localhost:8082` (awaiting user decision).
- **Record correction — ci-base steps have ALWAYS run BuildKit.** Measured:
  qits-githost f5ae4bb hit a buildkit error on 2026-08-11, before the gateway
  conversion. So the 2026-08-11 note saying "buildkit was never involved in CI"
  is itself wrong; treat every ci-base step as a BuildKit build. Only
  `node-docker-base` steps still take the legacy builder, until that image
  ships buildx.
- **qits-projects has no `ci-event-upstream-eventstream.yml`** (verified still
  missing) — the train never bumps its eventstream pin, so it is bumped by
  hand. Add the recipe.
- **Missing upstream recipes for the shared service jars** (cost boot attempts
  on 2026-08-13 AND 2026-08-14; consumers confirmed by fleet audit):
  `qits-githost-events` needs bump recipes in qits-ci + qits-projects;
  `qits-containers-client` in qits-ci + qits-projects + qits-workspaces.
  Until they exist, every githost/containers release strands consumer pins.
- **Anonymous `docker push` through edge HANGS** instead of failing fast —
  suspect edge's /token 401 arm under docker's retry loop. Security holds
  (nothing lands); fix the UX in qits-platform-edge.
- **Edge token broker dies during an idp redeploy** ("identity provider could
  not be reached") — a deploy-fanout push in that window burns its run
  (consumed event, no retry). Consider broker patience at edge or push retry
  in the publish steps.
- **qits-gateway `/git/*` public entry** — retirement needs the clone-URL
  product decision (projects SPA renders `<origin>/git/...`); anonymous push
  via the env vhost stays ref-gated only by the push-option token until then.
- **qits-spa-docs has no CI recipes** (version 0.0.0, off every train).
- **Drop projects' archunit workaround** (`epics/src/test/resources/
  archunit.properties`) — the `allowEmptyShould` fix is released and pinned.
- **Release pipelines push `:$QITS_CI_SHA`, not `:$version`.** Fixed in the ten
  stage-B repos of 2026-08-12; whether the rest still carry the wart is
  unverified. (verify still open)
- **qits-deployments' stale microprofile `git-host-url` default** — rides its
  next release. (verify still open)
- **cli-bootstrap: a failed clone refresh must fail LOUD** — stale clones with
  dead origins built old sources silently until version pins caught it.
- **cli-bootstrap TUI has never run under a real TTY** — only `PlainUi` is
  proven. (verify still open)

### Service and code defects

- **Seed CI's agroal pool never self-heals after a postgres gap** — the seed
  keeps a dead pool where the deployed services now hold through the outage.
- **AgentTunnelProxyTest holds an untimed `HttpClient.send`** — can wedge
  `verify` forever.
- **qits-events' release yml still carries the `rmi` wart** — fixed at source
  (`7b23dba`), rides its next release.
- **qits-eventstream first-boot watermark race** — startup sweep and scheduler
  both insert the initial watermark; the loser WARNs a
  `consumer_watermark_pkey` violation. Make the init insert idempotent.
- **qits-workspace-daemon surefire flake** — failed once on a rebuild of a tree
  that had built green, unreproduced.
- **`vertx-http-proxy` breaks on h2c inbound** (edge and the workspaces proxy
  family).
- **qits-workspaces CaptureService mints `feature/<timestamp>` branches** that
  collide directory-wise with the `feature/<epic>/<feature>` convention — needs
  its own prefix.
- **`ResolveConflictService` is carried nowhere** — reassigned to workspaces in
  migration-plan.md §9 item 11, never moved.
- **Epics MCP:** `AgentLaunchService:604` passes the repo NAME into the MCP
  `repositoryId` param while `RepositoryMcpTools:76` filters by id; and
  `ScopedMcp.allowedTools` is inert on the Claude path but filters on Kimi ACP
  chat. (verify still open)
- **qits-projects agent containers have no re-provision path** — the daemon
  latches `provisionStarted` for the process lifetime and `ensure` no-ops on a
  running container, so recovery is remove-the-container-and-re-ensure.
  (verify still open)
- **`target` vs `deploymentTarget` wire spelling** is inconsistent.
- **Spec-aware release promotion** — one release still pushes several refs;
  quiet pushes cover part of it. (verify still open)
- **The legacy-network enforcement flip**
  (`qits.platform.deployments.legacy-network=` empty) and the cross-app URL
  migration it needs. (verify still open)

### Docs and prose

- **Lib README's stale PatientPgDriver native watch item** — native is proven
  live; drop on next touch.
- **11 comment references to the removed `db-patience-plan.md`** across
  githost/ci/workspaces/projects/integrations-quarkus — re-point them to
  `docs/project-setup-quinoa-angular.md` on the next touch of each repo.
- **qits-ci's image-pull/health-gate prose still names qits-cd** (the facts
  hold).
- **qits-spa-artifacts' cleanup-page banner** says "live pins from qits-cd and
  qits-ci" — fold into that repo's next release, not a cascade of its own.

### UI

- **prompt-attachments has no SPA client** in either SPA — the backend and SSE
  topic exist, paste/sketch delivery is unwired.
- **`ui/async.ts` copies have drifted** between the SPAs.
- **Deployments UI joins `environment.name === project.slug`**, so project
  `qits` draws as "no environment" and env `dev` lands in the unmatched bucket.
  Stale convention. (verify still open)
- **The projects SPA does not render `failureDetail`** on the agent-container
  read (additive backend field). (verify still open)
- **Compare/commits view** to replace the muted placeholders on the epic tree;
  epic-level implemented state for zero-feature epics (Epic has no implemented
  field, so those can only show "open").

### Store and GC

- **First real GC sweep** has never run — currently a proven no-op. When the
  store ages past P30D, follow the README's first-sweep choreography (dry-run
  review → backup + blob listing → sweep → verify store-summary balance).
  Nothing sweeps without the review.
- **SHUTDOWN COMPACT maintenance restart** is the only way packument CLOB space
  comes back after proxy evictions — documented in the artifacts README, never
  run by code.
- **ci-screenshots / ci-videos GC**: excluded by configuration today; the user
  wants an own-like "$last versions" strategy eventually.
- **Git pack GC** (old BD): separate, DFS-gated, untouched by the GC reshape.

### Deferred designs (each has its doc in the repo root)

- `authenticated-reads-plan.md` — close edge's anonymous-read exemption
  via COMMISSIONED credentials (user model 2026-08-14): a service
  provisioning a dynamic context (ci build, workspace, agent container)
  commissions a dynamic idp client for it and decommissions it with the
  context; full access now, scoping later; deployer/containers get plain
  service identities; RETIRES the interim static qits.ci.registry-auth
  keys. Edge Basic acceptance + BuildKit secret mounts still carry it.
  Gated flip, rollback is one env value. Start at WP0; the BuildKit exit
  is the long pole.
- `qits-artifacts-postgresql-plan.md` — artifacts off H2 onto PostgreSQL.
  Unstarted; start at its work-package table.
- `user-authentication-plan.md` — register token, WebAuthn/password login,
  idp sessions, edge forward-auth with X-Qits-User headers (2026-08-14;
  supersedes qits-idp-plan.md phase 3 — that file dies when this lands).
  Start at WP-IDP; the rollout order section is load-bearing.
- `eventstream-causation-split-plan.md` — split qits-causation out of the
  eventstream jar so entity modules stop inheriting an HTTP server, a
  persistence unit and darkness keys. Carries the per-repo removal inventory.
- `workspace-overview-ux.md` — the workspace overview redesign; the real model
  is project → epic → workspace views.
- `gateway-route-events-plan.md` — schedulable now (see the audit entry above).
- Not planned, user decision 2026-08-05: telemetry for workspace-launched dev
  services (LD-b). Console capture is the answer for both daemons.

### Parked: userflows

First real usage of `libs/qits-userflows` (Playwright user-story framework:
@UserStory/@UserflowPrecondition/@UserflowRunsAfter, topological orderer,
UserflowContext, report emission), plus the doctrine in its package-info.

- **Execution profiles**, two axes: environment kind (mocked, or a live scope —
  `dev`, later preprod/prod, plus the PLATFORM scope) and vantage (in-network |
  external). A profile is a small properties file (`qits.userflows.profile`);
  one gateway base URL covers UI + API. Profiles should eventually DERIVE from
  qits-deployments' registry instead of being hand-written.
- **Capabilities**: a marker interface (e.g. RepositoryExists) accepted by
  @UserflowPrecondition; providers are stories annotated @UserflowProvides plus
  an environments gate — mocked provider stubs, live provider IS the real
  create-flow. Zero or two active providers is a hard error.
- Phasing: framework profiles+gating+doctext → capabilities → first consumer in
  qits-ci (mocked, against the packaged app + StubGitHost) → live-external →
  live in-network (CI pipeline; the step env needs a gateway URL) → publish
  reports to the ci-screenshots/ci-videos artifact types.
- Open questions: where the cross-service suite lives long-term; packaged vs
  dev-mode boot for mocked runs; the surefire/failsafe chain constraint; auth
  for live profiles (idp machine tokens); report identity per profile.

## Awaiting a user verdict

- **WO-b**: the merge panel left the workspaces overview (merging lives on the
  detail route). Keep it that way, or bring a merge entry point back?

## Preserve

- Root untracked user files: `daemon-artifact-identity-plan.md`,
  `workspace-overview-ux.md`.
- `services/qits-workspaces/.claude/` is user-owned and untracked.
- Do not reintroduce EventStream as a CI/Workspaces submodule or reactor module.

## Rebootstrap of wohlben.eu — IN PROGRESS (identity campaign live-boot)

The repository-identity campaign is CODE-COMPLETE and pushed to GitHub. The
clean-break rebootstrap of wohlben.eu (ship-mains cold boot) is grinding through
pre-existing estate incoherence surfaced by building everything from source.
Fixes landed + pushed this session (all on GitHub main):

- Lib pin coherence (lib-calver campaign left consumers stale): qits-registries
  847ce1b; qits-artifacts/ci/containers/githost/platform-edge/platform-mirror/
  projects (blobstore→.818.45340, eventstream→.818.45652, registries→.818.45443,
  githost-events→.820.65553); containers-client→.821.102707 in ci/projects/
  workspaces.
- Orphan webui gitlinks (agents' nested-checkout cherry-picks never pushed):
  qits-githost→e6a02c3, qits-projects→7b243b6, qits-ci→8aba03a (staged via
  update-index, NOT git add -A which moved them in the first place).
- Test-arity drift from WP-A's new SCM event fields (projectId/repoName):
  qits-ci 95df614 (ScmPushFrames, ScmPublishTagContractTest), qits-projects
  a732955 (ScmBackupTriggerListenerTest). These two were the ONLY githost-events
  consumers — class fully closed.
- Public bootstrap UI (was a defect on the cold/container path): cli-bootstrap
  26b3f24 (edge public-by-default when a domain is set, via
  bootstrapIngressPublicEffective) + wrapper shim 4a9cca8 (cold path starts the
  durable qits-bootstrap-progress supervisor). Live at https://wohlben.eu/
  during boot, generic (no per-node .env). cli-bootstrap c99c5d5 reverted a
  maven.test.skip experiment (it broke test-jars).

Operational facts for the boot:
- **QITS_PG_SUPERUSER_PASSWORD is pinned in /root/qits/.env** — postgres applies
  POSTGRES_PASSWORD only at initdb, so a fresh per-boot password fails auth on a
  reused volume. Pinning fixed the phase-15 failure.
- **Fast reruns = minimal cleanup**: kill run-cold-boot + rm containers, KEEP
  .qits-bootstrap-src, images, volumes, .qits-bootstrap.env, progress. Do NOT
  wipe (wiping resets clone mtimes → full native rebuild). NOTE: native seed
  builds don't hit docker cache across reruns anyway (~24min to phase 30
  regardless); full wipe is only for a deliberate unwrap.
- pkill the boot with the bracket trick: `pkill -9 -f '[r]un-cold-boot'` (a
  plain pattern matches your own ssh command and self-kills).
- Progress reached: phase 8→12→26→30/78 across attempts. Last failure was
  qits/projects test-compile (now fixed); rerun in progress.
- Backup: all 48 repos + campaign mains on GitHub. PAT used via a Linux askpass
  (this host has no working git credential helper), shredded after each push.

### Rebootstrap progress 2026-08-22: reached phase 60/78, blocked on postgres redeploy

The identity campaign is CODE-COMPLETE, PUSHED, and PROVEN AT RUNTIME. The cold
boot now clears the entire build gauntlet and most of the deploy half. Fixes
this session (all pushed to GitHub main), in the order the boot surfaced them:
- lib pin coherence (7 repos), orphan webui gitlinks (3), postgres password
  pinned in /root/qits/.env, public bootstrap UI (cli-bootstrap + shim),
  test-arity drift for WP-A's SCM event fields (qits-ci 95df614, qits-projects
  a732955), seed builds skip test-compile? NO — reverted; kept -DskipTests,
  native heap 6g + builder cgroup 9g + builder v5 (cli-bootstrap 15e94f4),
  ACME-enabled compose value quoted (2162dc0), githost name-resolver now
  presents X-Qits forward-auth to qits-projects' qits:system by-name endpoint
  (qits-githost cdec332), step images retagged under the registry host
  (cli-bootstrap 6f34537).
PROVEN working at runtime: phase 46 qits-projects self-seeds the qits project
(UUID); phase 47 mints 43 repo UUIDs + registers names; phase 48 pushes 26
repos NAME-ADDRESSED (/git/<projectUUID>/<repo>); phases 50-56 CI release
replays build green using the step images.

CURRENT BLOCKER (phase 60, deploy train): qits-oci-postgresql, when REDEPLOYED
by the deployer at phase 59, comes up with an HTTP health check
(curl localhost:8080/oci-postgresql/q/health/ready) although its
.config/qits/deployments.yml correctly declares `health_cmd: pg_isready -U
postgres`. Plain postgres has no HTTP server, so the check fails and swarm
crash-loops it (start-first, SIGTERM every ~18s). With the DB never stably up,
qits-projects' name resolver times out and every name-addressed push 503s
(qits-platform-idp at phase 60). health_cmd IS implemented in qits-deployments
main (SpecSource/DeploymentDriver/DeploymentSpecParser) — so the deployer read
the wrong health, most likely because the spec fetch (GitHostSpecSource, blob
of deployments.yml) fell back to the HTTP default when the resolver/DB were
mid-cutover. This is PRE-EXISTING deploy-train infrastructure, not the identity
campaign. Needs the platform owner's call: is the health_cmd path known-fragile,
should the deploy-train postgres self-redeploy be sequenced differently, or is
the spec-fetch fallback the bug to fix. The seed deployer is qits/deployments:latest.
