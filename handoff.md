# Handoff

What is still open. Everything shipped and closed is in git history; durable
lessons are in the memory files
(`~/.claude/projects/-home-wohlben-code-qits-qits/memory/`).

## Platform state

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
- **Likely casualty: qits-platform-dns on 5353** — Windows mDNS holds UDP
  5353 on the now-shared stack. If the service sits 0/1 with a bind error,
  set QITS_DNS_PORT to a free port (e.g. 5354) in the wrapper `.env` and
  redeploy dns.
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
  qits-spa-docs (no recipes, 0.0.0), qits-repositories (empty stub),
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
- **qits-repositories** is an empty stub — remove it.
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
