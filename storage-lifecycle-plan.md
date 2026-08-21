# Storage lifecycle plan

Why: wohlben.eu (150 GB disk) ran full on 2026-08-21, five days after the
2026-08-16 reset. Hand-deleting images freed enough to continue. Nothing
on the platform deletes anything it stores, so it fills again in about a
week. This doc records what uses the disk, how fast it grows, and the
lifecycle we need so this cannot recur.

## Measured 2026-08-21 05:45 UTC (after the hand cleanup)

Disk: 116 GB used / 150 GB, 29 GB free. Everything of note is under
`/var/lib/docker` (43 GB volumes) and `/var/lib/containerd` (70 GB: the
dockerd image store + BuildKit cache). Host paths outside docker total
< 2 GB (journal 449 MB, /root 887 MB, container logs < 1 MB each).

| # | Store | Size | Reclaimable now | Grows by | Who writes it | Who deletes it |
|---|-------|------|-----------------|----------|---------------|----------------|
| 1 | Registry blobs — `qits_artifacts.blob_chunk` in Postgres | 16 GB (17 GB on disk) | 0 without a policy | ~2.7 GB/day (5.6 / 0.9 / 0.7 / 2.8 / 4.0 / 2.0 GB per day since the reset) | every CI push (sha tag per commit, calver tag per release, `latest` for build images) | nobody |
| 2 | Host image store (dockerd, containerd snapshotter) | 43.5 GB | 19.3 GB (55 dangling images; 24 of 131 tags in use) | one full image per deploy + per workspace image rebuild + bootstrap rebuilds | deployer pulls, CI step pulls, bootstrap builds | nobody |
| 3 | Host BuildKit cache (default builder, used by CI builds) | 35.1 GB | 16.7 GB | ~7 GB/day | CI `docker buildx build` through the containers daemon | nobody (no `keep-storage`) |
| 4 | Bootstrap builder container `qits-bootstrap-builder-v40` state volume | 13.7 GB | 11.1 GB | per bootstrap run | `qits-cli bootstrap` image builds | nobody |
| 5 | Dead bootstrap builder volumes (`builder0`, `v20`, `v30`) | 6.2 GB | 6.2 GB | one per builder version bump | bootstrap | nobody |
| 6 | Postgres WAL | 3.8 GB | — | bounded (`max_wal_size` = 4 GB) | postgres | postgres |
| 7 | Mirror — `qits_platform_mirror` (proxied maven/npm blobs 464 MB + npm packuments 568 MB) | 0.7 GB | — | slow (5–6 MB/day after the first fill) | pull-through cache | nobody |
| 8 | Orphan volumes (`qits-maven-cache` 298 MB, `qits_workspace_*-improvement{,-2}` 69 MB, `qits-maven-seed`, 6 anonymous) | ~0.4 GB | 0.4 GB | one per deleted workspace / old boot | workspaces, bootstrap | nobody |
| 9 | Live data volumes (`qits-stt-data` 844 MB, `qits_shared_m2` 642 MB, `qits_workspace_adhoc-changes` 780 MB, others < 100 MB) | ~2.4 GB | — | with use | apps | n/a |

Instantly reclaimable without any policy: roughly 53 GB (rows 2–5, 8).
Rows 1–3 are the ones that refill the disk.

### Row 1 in detail — the registry never forgets

`qits_artifacts` holds 1089 blobs, 232 manifests, 270 tags, all
`PROMOTED`. Heap bloat is nil (27 dead tuples): the 16 GB is live data.

- Tags per image (sha / calver): qits-workspaces 47/0, qits-projects 23/0,
  workspace 16/6, projects-daemon 13/8, qits-platform-edge 14/4,
  qits-deployments 12/5, workspace-base 9/5. Only 4 manifests are untagged
  — deletion has to be tag-driven, not "untagged manifests" driven.
- Size lives in few blobs: 17 blobs of 100–500 MB = 4.4 GB, 281 blobs of
  10–100 MB = 10 GB, 790 blobs < 10 MB = 83 MB. The 100–500 MB class is
  nine ~380 MB layers — one per `workspace-base` build (layer 13 of that
  image, 398 MB) — plus a 920 MB `userflows-base` layer pushed today.
- The 3.4 GB `workspace`/`workspace-base` images have 28–30 layers; each
  rebuild re-pushes whatever changed, so the registry cost of an image
  family is (rebuilds × changed layers), not (tags × image size).
- `accessed_at` IS maintained on `oci_tag`, `oci_manifest`,
  `maven_artifact` (40 of 270 tags read after their write; latest read
  05:36 today). An LRU / last-pulled policy has the data it needs.
- Manifests reference layers only through the manifest JSON; there is no
  layer-reference table, so blob GC = parse every live manifest, mark,
  sweep. Maven/npm/docs/daemon rows reference blobs by `blob_id` columns.
- Postgres will not shrink the heap file after deletes (plain VACUUM
  reuses the space). Steady-state is what matters; a one-time
  `VACUUM FULL blob_chunk` needs 2× the table size free — do it once, early.

### Row 2 in detail — the host keeps every image ever pulled

131 image tags, 24 referenced by a container, 17 by a swarm service.
Per family on the host: workspace 3.47 GB × 9 tags, workspace-base
3.4 GB × 6, userflows-base 5.38 GB × 5 tags (but one image), project-agent
3.47 GB, graalvm builder 2.89 GB + 4 dangling twins (345 MB unique each),
plus 5–12 sha/calver tags for every service (≈0.3–0.4 GB each, shared
layers). Dangling: 55, including two 5.38 GB and four 2.89 GB — the
bootstrap rebuilds `graalvmce-musl-builder` and `userflows-base` with the
same tag every run and the old one dangles.

Three kinds of host image, three owners:

- deploy images (`registry…/qits/<svc>:<sha|calver>`): pulled by swarm on
  each deploy; only the running one and its predecessor (rollback) matter.
- step/build images (`qits/build-images/*:latest`, `qits-oci-push/*`,
  graalvm builder): consumed by bare local tag by CI; their rebuilds
  dangle the predecessor.
- workspace / agent images (`workspace`, `workspace-base`, `project-agent`):
  pulled per workspace container; a rebuilt base keeps the old one.

### Row 3 in detail — BuildKit cache classes (default builder, 35 GB)

Largest classes: 5.8 GB in 39 untitled layers; webui `dist` mounts
(qits-spa-* per service) 3.5 + 2.8 + 2.2 + 1.7 + 1.6 + 1.6 + 1.2 GB;
`ubi9-quarkus-mandrel-builder-image:jdk-25` pulled TWICE — 2.8 GB via
quay.io directly AND 2.4 GB via `mirror.dev.localhost:8080/quay/...` (two
refs, two cache keys, one image); `COPY . .` build contexts 2.7 GB × 35;
local source contexts 2.5 GB × 21; `COPY --from=build …/target` 2.2 +
1.5 GB; apt/zlib/musl mounts ~3.5 GB. Shared 14.6 GB, private 20.5 GB,
reclaimable 16.7 GB.

Row 4 (bootstrap builder, 13.7 GB) is the same shape: mandrel 4.4 GB +
graalvmce 2.7 GB + postgres 0.5 GB pulls, plus the image build layers.

## Existing mechanisms (what the code already has)

Surveyed 2026-08-21. Paths are under the superproject.

- **qits-artifacts has a complete GC engine, never scheduled, never run.**
  Module `services/qits-artifacts/gc/` (~5 kLOC, 98 tests). Trigger is
  REST only: `GET /artifacts/api/gc/plan` (dry run) and
  `POST /artifacts/api/gc/sweep` (`GcPlanController`), plus the SPA
  cleanup page. Policy (`OwnArtifactsStrategy`): keep what a live pin
  names → keep the last 2 calver releases per image → delete the rest once
  unaccessed for longer than the type window (`oci-images` P30D,
  `npm-packages` P30D, `maven`/`daemon-binaries`/`docs` P90D);
  `OciImagesGcAdapter` also keeps each image's newest build tag and
  collects untagged manifests; blobs go through `BlobSweep` with a P7D
  grace (`qits.artifacts.gc.blob-grace-period`). Pins come from
  `CdHttpDeploymentPins` (deployments `/platform-deployments/api/pins`)
  and `CiHttpDaemonPins` (ci `/ci/api/daemon`); an unreadable pin source
  aborts the whole run — correct, but see below.
- **On wohlben.eu the plan is NOT EXECUTABLE today** (dry run 05:48 UTC):
  both pin readers get **401** — they are plain `HttpClient`s with no
  credential, written before every in-network read started to
  authenticate (2026-08-14). And even executable, "no type condemned an
  identity": a P30D window on a 5-day-old platform keeps everything.
  At 2.7 GB/day a 30-day window plus 7-day grace is ~100 GB of steady
  state — the existing policy would not have prevented this incident.
- **qits-platform-mirror has a scheduled eviction** (`CacheEvictionSweep`,
  nightly 03:20, windows npm P30D / maven P90D / oci P30D, "no route and
  no button — the only trigger is the clock"). This is the pattern to copy.
- **The OCI registry answers 405 to every `DELETE /v2/*`** by design; the
  GC engine is the only deletion path.
- **Nothing on the host side deletes anything**: no `image prune`,
  `builder prune`, `buildctl prune`, `rmi`, or BuildKit `keep-storage`
  anywhere in the tree. CI recipes argue against `docker rmi` (correct —
  it frees nothing on a cache host). `Docker.java:29` names the bootstrap
  builder `qits-bootstrap-builder-v4` and `ensureBuilder()` never
  `buildx rm`s the predecessor, which is how `builder0`/`v20`/`v30`
  state volumes strand. The deployer (`DeploymentDriver.pull`) pulls and
  never removes. The hand `docker system prune` of 2026-08-21 deleted the
  step images and took CI down platform-wide (handoff) — a reminder that
  host pruning needs a protect list, not a blanket prune.
- **Volumes**: `qits-containers` `VolumeReconcile` removes only managed
  volumes whose row says ABSENT; `qits.containers.volume-gc-grace` is
  declared and explicitly not read. Workspace deletes drop their volume
  through one door (`WorkspaceService` → `deleteVolume`); other paths
  leave orphans.
- **Postgres**: autovacuum is healthy; the store's abandoned-staging
  sweep runs at startup only (`staging-ttl` P1D).

## Lifecycle design

**Decided 2026-08-21: the unified deletion run is a technical process of a
new platform service, `qits-platform-orchestrator` — see
`qits-orchestrator-plan.md` for the pinned contracts (containers gc
endpoints, artifacts supplied pins, the orchestrator API and UI).** The
sections below stay as the policy rationale; ownership of the host-side
APIs is containers (socket holder), not ci.


Principle: every row of the table above gets an owner that deletes on the
clock, with a declared policy, a dry-run plan, and a protect list that is
data (pins, labels) rather than a human's memory. Order of keep-classes
everywhere: pinned → newest N → inside the window → gone.

### L1 — Registry (qits-artifacts) — the big one, mostly config

1. **Make the pin readers authenticate** (code, small): both HTTP pin
   sources present a machine token (client credentials from the idp,
   audiences the deployments and ci services accept). Without this the
   engine is a no-op forever. Keep the abort-on-unreadable rule.
2. **Schedule it** (code, small): `@Scheduled(cron="{qits.artifacts.gc.cron}")`
   + `enabled` + `dry-run` keys, concurrent runs skipped — byte-for-byte
   the mirror's shape. Nightly, after the mirror's slot. The endpoint and
   SPA page stay as the review/emergency doors.
3. **Shrink the windows for prerelease coordinates** (config only):
   `oci-images` P30D → **P7D** (sha tags are per-commit builds; pins, the
   newest build, and the last 2 calvers are kept regardless), blob grace
   P7D → **P2D**. Steady state ≈ 9 days × 2.7 GB ≈ 25 GB. Leave maven /
   docs / daemon at P90D (tiny).
4. **Add a size budget as the backstop** (code, phase 2): per repository
   `qits.artifacts.gc.<type>.budget` — when the live bytes exceed it, the
   planner condemns the oldest unpinned, non-release identities until it
   fits, window or not. This is what turns "probably enough" into "cannot
   fill the disk". Report it in the plan as its own keep/condemn class.
5. **Reclaim the heap once**: after the first real sweep, a one-time
   `VACUUM FULL blob_chunk` (needs ~2× the table free — do it while it
   is small). After that plain autovacuum reuse is enough.
6. **Measure**: expose live bytes, reclaimable bytes, last-run outcome as
   metrics from the GC module; they are the inputs for L6.

### L2 — Host image store — owner: qits-containers (the only socket holder)

Nightly image GC through the containers daemon's Docker client: remove
images that no container or service references AND that are older than
24 h, except a protect list that is data:
- step images — protected by label (`qits.keep=step-image`) or, now that
  step images are published to the registry (2026-08-21), simply
  re-pullable; either way they must not be a blanket-prune casualty again;
- per service, the running deploy and its predecessor (swarm rollback) —
  the deployer already knows these (it is the pin source);
- workspace / agent images a live workspace row names.
Dangling images go unconditionally. The bootstrap adds one step at the end
of its run: remove the dangling predecessors of the images it rebuilds
under a fixed tag (`graalvmce-musl-builder`, `userflows-base`).

### L3 — BuildKit caches — owner: bootstrap (it writes the daemon config)

- Default builder (CI): `/etc/docker/daemon.json` `"builder": {"gc":
  {"enabled": true, "defaultKeepStorage": "20GB"}}` — the bootstrap
  already writes this file (insecure-registries). BuildKit then prunes
  LRU on its own; no cron needed.
- Bootstrap builder: create it with a `buildkitd.toml`
  (`[worker.oci] gc=true, gckeepstorage=<8GB>`), and **`buildx rm` the
  previous named builder** in `ensureBuilder()` (derive the old name from
  the version suffix, or stop suffixing and recreate when driver opts
  differ). Delete the three stranded state volumes on the next run.
- Stop pulling mandrel twice: every Dockerfile references the builder
  image through the mirror vhost only (quay direct + mirror = two cache
  keys for one 2.7 GB image on every builder).

### L4 — Volumes — owner: qits-containers + workspaces

- Read `qits.containers.volume-gc-grace`: a managed volume with no live
  row for longer than the grace goes. Unmanaged volumes stay untouched.
- Bootstrap removes its own leftovers (`qits-maven-cache`,
  `qits-maven-seed`, `qits-edge-acme` when superseded).

### L5 — Postgres and mirror — already bounded

WAL is capped at 4 GB (could drop `max_wal_size` to 1 GB; not worth a
restart). Mirror evicts nightly. No action beyond L1.5.

### L6 — Pressure signal and emergency lever

- A disk watermark metric on the host (`df` + `docker system df`) in
  qits-observability, alarm at 80 %.
- At 90 % the scheduler runs the L1/L2 sweeps out of band with the size
  budget tightened; at 95 % CI refuses new builds (better a red run than a
  full disk that takes the registry down with it).

### Order of work

1. L1.1 + L1.2 + L1.3 (unblocks ~the whole registry growth; one small
   release of qits-artifacts plus an extras change).
2. L3 (two config lines + `buildx rm`; stops 35 + 14 GB of cache growth).
3. L2 (needs the protect list; the deployer's pin endpoint is the source).
4. L4, L1.4, L6.

### One-time cleanup available today (not done — needs a decision)

Safe, ~50 GB: `docker image prune` (dangling only, 55 images);
`docker buildx --builder default prune --keep-storage 15GB`;
`docker exec buildx_buildkit_qits-bootstrap-builder-v40 buildctl prune --keep-storage 4GB`;
`docker volume rm` the three dead builder volumes + `qits-maven-cache`,
`qits-maven-seed`, the two 0-link workspace volumes. Do NOT
`docker system prune -a` / `image prune -a`: it deletes step and
workspace images the platform still pulls by local tag.
