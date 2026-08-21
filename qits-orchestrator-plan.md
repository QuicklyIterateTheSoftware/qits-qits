# qits-platform-orchestrator — technical processes, first one: garbage collection

Decided 2026-08-21. Companion to `storage-lifecycle-plan.md` (the measured
problem). One platform service runs *technical processes* — multi-step
jobs that only send requests to other services and record what happened.
The first and only process is **gc**: the unified deletion run across the
platform. No containers, no socket; it orchestrates, the owners delete.

Repos: `services/qits-platform-orchestrator` (Quarkus, platform tier,
segment `/orchestrator`) and `frontends/qits-platform-spa-orchestrator`
(its UI, embedded by Quinoa at `service/src/main/webui`). Both are
submodules here since 2026-08-21.

Naming note: qits-containers' own docs call it "THE CONTAINER
ORCHESTRATOR". That word now has two meanings on the platform; the
containers repo keeps its prose, this service is "the orchestrator" in
navigation and conversation.

## Who deletes what (ownership decisions)

| Store | Owner of the deletion API | Why |
|---|---|---|
| Registry blobs / tags / manifests (PG `qits_artifacts`) | qits-artifacts — existing GC engine (`gc/` module, plan + sweep) | already there; stays the only deletion path (no `DELETE /v2`) |
| Host image store | **qits-containers** | it holds the docker socket for the platform and its rows know every live container's image. The deployer also has a socket but is kept minimal on purpose ("must survive the platform being down"). |
| Orphan volumes (managed-without-row, dead buildx state volumes, anonymous) | qits-containers | same socket; `VolumeReconcile` is the seam, `volume-gc-grace` was declared for this |
| CI BuildKit cache (host default builder) and the bootstrap builder container's cache | **qits-containers, not qits-ci** — qits-ci has NO socket (steps get the host socket bind-mounted by containers). The policy value (keep-storage) belongs to the orchestrator's process config; the mechanics need the socket. | |
| Dead bootstrap builder state volumes | qits-containers (volume class `buildx_buildkit_*_state` without a builder container) | |
| Mirror cache | already evicts nightly on its own; not a step in v1 | |
| Postgres WAL | capped by `max_wal_size`; nothing to do | |

Pins (what must never be deleted) are read ONCE per run by the orchestrator
and handed to every deleter — one platform-wide pin set
(`priority-feature.md:101`). A deleter that receives no pin set, or one
marked incomplete, refuses. This moves the fail-closed read from
qits-artifacts' own (currently 401-ing, credential-less) pin readers into
the orchestrator, which is the one component that holds an idp client for
every peer. qits-artifacts keeps its HTTP readers as the no-body fallback.

## Contracts (pinned — every repo builds against these)

### qits-containers — new, `@RolesAllowed("qits:system")`, audience as today

`GET /containers/api/gc/usage` → `docker system df` as JSON:
```
{"images":{"count","active","sizeBytes","reclaimableBytes"},
 "containers":{...}, "volumes":{...}, "buildCache":{...}}
```

`POST /containers/api/gc/images` body
```
{"dryRun": bool, "minAge": "PT6H",
 "keep": ["qits/qits-ci:<sha>", "sha256:<id>", ...],       // exact tag, or tag suffix after a "/", or image id
 "keepPrefixes": ["qits/build-images/", ...]}               // same suffix rule, prefix match on the part after the "/"
```
→ `{"dryRun", "examined", "bytesReclaimed", "removed":[{"id","tags":[],"sizeBytes","reason"}], "kept":[{"id","tags","sizeBytes","reason"}], "failed":[{"id","tags","error"}]}`
Rules, in order: in use by any container (running or not) → kept `in-use`;
named by a live `ct_container` row → kept `live-row`; any tag matches
`keep`/`keepPrefixes` → kept `pinned`; created inside `minAge` → kept
`too-young` (protects an image built but not yet pushed by a CI step);
otherwise removed — dangling and tagged alike. `keep` entries: `a:b`
matches a local tag equal to it or ending in `/a:b`; `sha256:…` matches
the image id. Docker CLI only (`image ls --format json --no-trunc`,
`ps -a --no-trunc --format`, `image rm <id>`), every call with a timeout
and an output bound, per the repo's law. No `docker image prune -a`.

`POST /containers/api/gc/volumes` body `{"dryRun": bool, "minAge": "PT24H"}`
→ `{"dryRun","removed":[{"name","reason"}],"kept":[{"name","reason"}],"failed":[{"name","error"}]}`
Only dangling volumes (`volume ls -q -f dangling=true`) are candidates.
Removed classes: `managed-no-row` (label `qits.containers.managed=volume`,
no row, `CreatedAt` older than `minAge`), `buildx-state`
(`^buildx_buildkit_.*_state$`, no container named `buildx_buildkit_*`
uses it), `anonymous` (`^[0-9a-f]{64}$`, older than `minAge`). Everything
else dangling is kept with reason `unmanaged`. Rows are never touched.

`POST /containers/api/gc/build-cache` body `{"dryRun": bool, "keepStorageBytes": n}`
→ `{"dryRun","host":{"reclaimedBytes","detail"},"builders":[{"container","reclaimedBytes","detail","error"}]}`
Host: `docker builder prune --force --keep-storage <n>` (dry run:
`docker buildx du` totals into `detail`, no prune; `reclaimedBytes` is 0
on a dry run because a `du` cannot say what a keep-storage prune would
free). Builders: every container named `buildx_buildkit_*` gets
`docker exec <c> buildctl prune --keep-storage <MB>` (the buildctl flag is
in megabytes — converted, rounded up; dry run: `buildctl du`). Shipped
with one additive field, `host.error` (null on success). Absent-field
defaults: `dryRun` absent ⇒ dry run; `minAge` absent ⇒ no age
protection; `keepStorageBytes` absent on a real run ⇒ 400. The
orchestrator always sends all of them.

### qits-artifacts — pins may arrive in the request

`POST /artifacts/api/gc/plan` (new; GET stays) and `POST /artifacts/api/gc/sweep`
accept an optional JSON body:
```
{"pins": {"deployments": <verbatim body of GET /platform-deployments/api/pins>,
          "ciDaemon":    <verbatim body of GET /ci/api/daemon>}}
```
With a body: the engine uses these instead of its HTTP readers; a missing
member = that pin source "unanswered" = plan not executable, sweep aborts
(unchanged fail-closed rule). `GcPinSource.source` reads
`"supplied: qits-platform-deployments"` / `"supplied: qits-ci"`, `url`
empty. Without a body: today's behaviour. Roles: `POST /gc/plan` is
`qits:admin` OR `qits:system` (read-only, machines may ask), the sweeps
stay `qits:system` + `AdminWriteGuard`. A `{"pins":[]}` deployments
answer is an answer (nothing pinned); an absent/null member is
"unanswered"; a malformed body is 400, never a silent fallback.

### qits-platform-orchestrator — `/orchestrator/api`, roles `qits:admin` (people) or `qits:system` (machines)

```
GET  /processes                      → [{kind, name, description, steps:[{id,name,target,dependsOn[]}]}]
GET  /processes/{kind}/runs?limit=20 → [{id, kind, trigger, dryRun, status, startedAt, finishedAt, summary}]
POST /processes/{kind}/runs  {dryRun}→ 202 {id}   (409 while a run of that kind is active)
GET  /runs/{id}                      → run + steps:[{id,name,target,dependsOn,status,startedAt,finishedAt,
                                        httpStatus, request:{method,url,body}, response, error, summary}]
```
`status` ∈ PENDING, RUNNING, SUCCEEDED, FAILED, SKIPPED (run: RUNNING,
SUCCEEDED, FAILED). `trigger` ∈ manual, scheduled. Steps run in
declaration order; a failed step marks every transitive dependent SKIPPED
with `error = "skipped: <step> failed"`; independent steps still run; the
run is FAILED if any step is FAILED. `response` and `request.body` are the
peer's JSON bodies as STRINGS (a 1 MiB-truncated body is not JSON; the
UI pretty-prints a string that still parses). `summary` is one human line per step
(e.g. "12 images, 9.4 GB removed").

The **gc** process (kind `gc`), steps and edges:

| id | target | call | dependsOn |
|---|---|---|---|
| `usage.before` | containers | `GET /containers/api/gc/usage` | — |
| `pins.deployments` | deployments | `GET /platform-deployments/api/pins` | — |
| `pins.ci` | ci | `GET /ci/api/daemon` | — |
| `artifacts.plan` | artifacts | `POST /artifacts/api/gc/plan {pins}` | pins.deployments, pins.ci |
| `artifacts.sweep` | artifacts | `POST /artifacts/api/gc/sweep {pins}`; SKIPPED("dry run") when dryRun | artifacts.plan |
| `containers.images` | containers | `POST /containers/api/gc/images` keep = deployments pins as `qits/<app>:<sha>` + config prefixes | pins.deployments |
| `containers.volumes` | containers | `POST /containers/api/gc/volumes` | usage.before |
| `containers.build-cache` | containers | `POST /containers/api/gc/build-cache` | usage.before (needs no pins; runs after images by declaration order) |
| `usage.after` | containers | `GET /containers/api/gc/usage` | artifacts.sweep, containers.images, containers.volumes, containers.build-cache |

Config (`qits.orchestrator.*`): `targets.{artifacts,containers,ci,deployments}-url`
(defaults `http://qits-<name>:8080`; the live platform injects
`dev-qits-*` for tier services), `gc.cron` (`0 0 3 * * ?`, read in `gc.time-zone`, UTC), `gc.enabled`,
`gc.dry-run`, `gc.image-keep-prefixes` (`qits/build-images/,qits/graalvmce-musl-builder`),
`gc.image-min-age` (PT6H), `gc.volume-min-age` (PT24H),
`gc.build-cache-keep-bytes` (20 GB), `gc.call-timeout` (PT120S).
Outbound auth: four named `quarkus-oidc-client`s (`artifacts`,
`containers`, `ci`, `deployments`), `client-id=qits-platform-orchestrator`,
`grant.type=client`, audience per peer, `client-enabled=false` in the
image, enabled by extras. Calls also send `X-Qits-User: qits-platform-orchestrator`
+ `X-Qits-Roles: qits:system` (the deployer's two-track shape).
Persistence: PG `qits_platform_orchestrator`, tables `op_run`, `op_step`.
Scheduler: `@Scheduled(cron="{qits.orchestrator.gc.cron}")`, skip when a
run is active — the mirror's shape.

### qits-platform-spa-orchestrator

Angular 21, baseHref `/orchestrator/`, `QitsMainLayout` shell, nav submenu
with a `qits-picker` of technical processes (one option: Garbage
collection) → `/processes/gc`. Process page: Run now / Dry run buttons, the
run list (status badge, trigger, when, summary), and the selected run as
**cards connected by lines**: one card per step, laid out in columns by
dependency depth, an SVG overlay draws a line from each card to each
dependent; card tone by status — pending/running yellow-ish (warning/info),
succeeded green, failed red, skipped grey; click a card to see request,
response JSON and error. Polls `GET /runs/{id}` every 2 s while RUNNING.

### Registration

- cli-bootstrap `PlatformModel`: `DEPLOYABLES` (+ `PLATFORM_SERVICES`),
  `SEEDED_REPOS` += `platform-orchestrator`, `platform-spa-orchestrator`;
  `IDP_CLIENT_APPS` += `platform-orchestrator` with roles
  `qits:system,qits-platform:system`; `ComposeTemplate` extras block for
  the orchestrator (machine audience, four oidc-client env groups, target
  URLs, observability URL).
- `deployments.yml`: `deployment_target: platform`, `routes: /orchestrator`,
  `navigation: Orchestrator:12`, `resources: postgresql:db`,
  `health_path: /orchestrator/q/health/ready`.
- Wrapper `.gitmodules`: both entries (done 2026-08-21).

Known debt carried forward: a platform-tier service calling tier services
by configured URL (same debt as qits-configuration); no eventstream /
causation in v1; no size budget in the artifacts GC yet (L1.4 of the
storage plan).

## Work packages

- WP-A qits-containers gc endpoints (usage, images, volumes, build-cache) + tests on the faked driver.
- WP-B qits-artifacts: supplied pins on plan/sweep.
- WP-C qits-platform-orchestrator service (domain, executor, gc definition, REST, scheduler, Quinoa, Dockerfile, CI ymls, deployments.yml).
- WP-D qits-platform-spa-orchestrator.
- WP-E cli-bootstrap registration.
- WP-F rollout on wohlben.eu — DONE 2026-08-21 (see status log).

## Status log

- 2026-08-21: plan written; submodules added; WP-A…E in flight.
- 2026-08-21: WP-A containers b4c5db0 green (269 tests); WP-B artifacts a53df66 green (237); WP-D SPA a9d9c37 green (78); WP-E bootstrap d47255b green (424). WP-C service fa1b21d + e1dc42a green (17 domain + 7 service + 9 packaged IT); SPA follow-up 4542550 (pretty-print string bodies). Nothing pushed yet; the service's webui gitlink still points at the SPA seed commit until the SPA is pushed.
- 2026-08-21 WP-F LIVE on wohlben.eu. Order that worked: `PUT /git/<repo>`
  for both new repos (bearer dev-qits-artifacts, aud dev-qits-githost) →
  mains seeded at the GitHub seed commits → containers/artifacts/cli-bootstrap
  released through the door (.81434/.81446/.81451) → wrapper released
  (.81529) → `POST /projects/api/projects/{id}/repositories/reconcile`
  adopted both repos with their GitHub twins → SPA released (.81549) →
  service webui gitlink bumped to the SPA's release merge → service
  released (.81625) → deployer created the platform service + PG db from
  `resources: postgresql:db`; health 200. idp client: 40 entries imported
  into qits-configuration (`POST /configuration/api/import`) + the same
  env-added on the live idp; secret recorded in `.qits-bootstrap.env`.
  First dry run SUCCEEDED, every call 200. First real run SUCCEEDED:
  images 44.5→39.4 GB, 3 dead builder volumes gone. Two live defects
  fixed + released: containers needed `docker-buildx-plugin` (.82604),
  multi-tag images must be untagged by ref + buildx needs a writable
  `BUILDX_CONFIG` (.84336); orchestrator: a dry-run skip must not skip its
  dependents (.84404). Artifacts GC policy applied via extras:
  `oci-images` window P7D, blob grace P2D (redeployed through the
  build-succeeded replay). GitHub holds every stamp via the platform backup.
- 2026-08-21 second real run after the two fixes: 21 images / 18.9 GB
  removed (0 failed), host build cache 4.0 GB pruned, usage.after ran;
  host 116 GB → 109 GB used since the morning (registry reclaim starts
  when identities age past P7D). Open tuning: `build-cache-keep-bytes`
  is per cache — 20 GB leaves the 13.7 GB bootstrap builder untouched.
- 2026-08-21 afternoon, "still too large" review (109 GB → target 50–60):
  hand steps — `docker buildx rm` of the bootstrap builder (13 GB),
  `docker buildx prune --all --keep-storage 10GB` (host cache 37→21 GB),
  artifacts window P2D / grace P1D → 81 GB used within minutes. Code
  wave released through the door: containers .102707 (`image ls --all`
  so the 55 dangling images are collected; host prune `--all`;
  `builderKeepStorageBytes`), orchestrator .102416 (host keep 10 GiB,
  builder keep 1 GiB), cli-bootstrap .103111 (LAST phase
  `teardown-bootstrap-builder`, `QITS_KEEP_BUILDER=1` for the dev loop;
  `ensureBuilder` sweeps stale name-bump builders), qits-oci-postgresql
  .102402 (`max_wal_size` 1 GB; DB restarted once, all services held).
  Registry blobs (17 GB) age out over the next two days; then a one-time
  `VACUUM FULL blob_chunk` returns the heap file.
- 2026-08-21 13:05 UTC final run of the day with every fix deployed
  (containers .102707, orchestrator .105603 — gc at 03:00 UTC daily):
  64 images / 54.7 GB removed (the 55 dangling among them), host cache
  5 GB pruned, registry 104 identities condemned (4.8 GiB, blobs sweep
  after the P1D grace). Host: 116 GB (morning) → **68 GB used, 77 GB
  free**. Tomorrow's run takes the registry blobs; then `VACUUM FULL
  blob_chunk` once.
