# qits-platform-artifacts → PostgreSQL for everything

Status: planned 2026-08-09, not started. Queued behind other in-flight work; every file/line
reference below was verified on 2026-08-09 and must be re-checked against the tree before
execution.

Prerequisite: `postgres-resource-provisioning-plan.md` must be live first — it hardens the
postgres deployment, moves qits-deployments onto PostgreSQL, and ships the `resources:`
provisioning mechanism this plan now relies on. Amended 2026-08-09 to match it.

## Goal and context

Make qits-platform-artifacts a stateless container: all state — metadata AND blob bytes — in
PostgreSQL, no volume, no disk. (Note: the live repo is `services/qits-platform-artifacts`;
`services/qits-artifacts` is a stale pre-rename leftover holding only `target/` dirs.)

Today the state is split:
- Metadata: file-H2 (~750 MB, 85% npm packument CLOBs) via Hibernate/Panache + Flyway on the
  named `artifacts` datasource — 13 H2 migrations, 16 Panache repositories, JPQL only.
- Blob bytes: content-addressed files (~5.4 GiB) at `<blobs-dir>/<sha[0:2]>/<sha>`, behind ONE
  class: `artifacts/.../control/BlobStore.java`. Everything is a blob: OCI layers/manifests,
  npm tarballs, maven artifacts, git packfiles (JGit DFS), daemon binaries, docs files,
  CI screenshots/videos.

The target database exists: `images/qits-oci-postgresql` (postgres 18.4 behind the mirror),
live at `prod-qits-oci-postgresql:5432` on qits-net + its per-app network. artifacts is
platform-plane, so it already joins that network — no gateway change. Hardening (volume,
randomized password, tuning) and role/database provisioning land in the prerequisite
`postgres-resource-provisioning-plan.md`, not here.

Decisions already taken (user):
- Blob bytes go INTO PostgreSQL. Chunked bytea rows (design below), no external blob service.
- Tests use Zonky embedded-postgres (real PG binaries as Maven artifacts, no docker) — keeps
  the repo's "clone alone builds and tests green, mvn verify, no docker" rule.
- PG stays `deployment_target: environment`; artifacts dials `prod-qits-oci-postgresql:5432`.

Naming, unified: role `qits_artifacts`, database `qits_artifacts` — provisioned by
qits-deployments' `resources:` mechanism, declared as `resources: postgresql:db:qits_artifacts`
in artifacts' deployments.yml. Env contract is the generic
`QITS_RESOURCE_DB_URL` / `_USERNAME` / `_PASSWORD` (injected by the deployer); artifacts maps
them onto its datasource in its own shipped config defaults.

## Part I — storage engine (code, services/qits-platform-artifacts)

### 1. Blob bytes: chunked bytea, not Large Objects

Large objects need autocommit-off and a transaction spanning every read/write — a 1 GiB pull
over a slow client would pin a pooled connection and an open transaction for the whole
transfer. They also live in the shared `pg_largeobject` catalog with an external GC
(`vacuumlo`) — a second garbage collector outside the service's one-funnel design. Chunked
rows need only plain JDBC and give seek by arithmetic.

Chunk size 1 MiB: a 1 GiB layer is 1024 round trips; heap per in-flight transfer ≈ 1–3 MiB;
one chunk serves ~16 JGit block reads (git_pack_file.block_size ≤ 64 KiB). `STORAGE EXTERNAL`
on the chunk column skips TOAST compression (content is already compressed).

Schema (part of the new PG lineage V1):

```sql
-- Content is addressed by a surrogate id so STAGING and PROMOTED share one byte table and
-- promote is a flip, never a copy. FK cascade makes "discard staging" one statement.
create table blob_content (
    content_id  uuid primary key,
    state       varchar(16) not null check (state in ('STAGING','PROMOTED')),
    started_at  timestamptz not null
);
create table blob_chunk (
    content_id  uuid not null references blob_content (content_id) on delete cascade,
    seq         integer not null,
    bytes       bytea not null,
    primary key (content_id, seq)
);
alter table blob_chunk alter column bytes set storage external;

-- stored_at replaces file mtime for the GC grace window; dedupe does NOT refresh it
-- (parity with promote()'s no-op on Files.exists).
create table blob (
    id          varchar(64) primary key check (id ~ '^[0-9a-f]{64}$'),
    content_id  uuid not null unique references blob_content (content_id),
    size_bytes  bigint not null,
    chunk_size  integer not null,
    stored_at   timestamptz not null
);
create index idx_blob_content_staging on blob_content (started_at) where state = 'STAGING';
```

(`varchar(64)`, not `char(64)` — PG `char` pads. The check constraint restates the
path-traversal defence; `isValidId` stays in code.)

Staging lives in PG too — no temp files anywhere. Stage = fresh STAGING `content_id`
accumulating chunks; promote = insert `blob` row + flip state (zero byte movement); dedupe =
PK conflict + cascade-delete of the redundant staging. Orphaned staging (process died
mid-upload — the tmp-dir-litter analogue) is swept by
`delete from blob_content where state='STAGING' and started_at < now() - :ttl`, new key
`qits.artifacts.staging-ttl=P1D`, guarded by an in-process `Set<UUID>` of open stages so live
uploads are never cut. Runs at startup, from `OciUploadSessions.sweep()` (the existing lazy
hook), and at the head of a GC sweep.

OCI upload sessions stay in-memory (the running `MessageDigest` is JVM state; the spec permits
session expiry; single replica is the accepted posture — `OciUploadSessions.java` javadoc
already says so). Multi-replica door left open: staged bytes are now shared, so a future
replica could adopt a session by re-hashing staged chunks.

### 2. BlobStore API evolution

Kept unchanged for callers: `stage(InputStream,long)`, `stageIncremental()` (same 8 KiB
hash-while-stream loop with cap enforcement), `promote(StagedBlob)`, `exists`, `open(String)`
(now streams chunks — `BlobService.java` and `OciManifestFootprints.java` compile untouched),
`size`, package-private `delete(String, SweepGuard)` (same result enum), `lastWrittenAt`,
`blobGracePeriod`. Changed record: `StagedBlob(String sha256, long size, UUID contentId)` —
`tempPath` replaced by the surrogate id.

Removed: `locate()` (existed only for `sendFile`) and `newStagingFile()`. Replacements:

```java
/** Random-access read for the git host. Chunk-backed; caches the last-read chunk. */
public SeekableByteChannel openChannel(String blobId)   // 404 semantics of requireExisting

/** Read-write staging for writers that must read back: git packs, the docs tar. */
public ScratchBlob stageScratch()

public interface ScratchBlob extends Closeable {
  UUID contentId();
  void write(byte[] buf, int off, int len);   // append; flushes full chunks to blob_chunk
  int read(long position, ByteBuffer dst);    // flushed chunks from DB, unflushed tail from memory
  InputStream openRead();                     // forward stream over everything written
  long size();
  void close();                               // discards staging unless promote() adopted contentId
}
```

- `BlobChunkChannel implements SeekableByteChannel`: `read` computes `seq = position /
  chunk_size`, fetches one chunk per autocommit SELECT unless cached, copies, advances;
  `write`/`truncate` throw; `close()` is a no-op — nothing pins a connection while JGit thinks.
- `BlobStorePackBlobStore.TempFileBlob` → `StagedChunksBlob` over `ScratchBlob` (JGit's writes
  are append-only; positional reads come from flushed chunks + the in-memory tail). The
  `PackBlobStore` port and `QitsDfsObjDatabase` change zero lines — the test-source
  `InMemoryPackBlobStore` already proved the port is FS-independent.
- Serving: new `service/.../registry/BlobSender.send(store, blobId, rc, what)` — streams
  chunk-sized slices to `HttpServerResponse` on the calling worker thread, checking
  `writeQueueFull()` after EVERY write and parking on `drainHandler`; aborts on dead
  connections like today's `sendFile` failure handler. Caller sets Content-Type/Length/ETag
  from `BlobStore.size()` and ends HEADs before calling — same shape as today.
- Call-site edits, mechanical and identical: `path = locate(x); size = Files.size(path)` →
  `size = blobStore.size(x)`; `response.sendFile(path)` → `BlobSender.send(...)`. Sites:
  `RegistryRoutes` blob serve + manifest serve, `NpmRoutes`, `MavenRoutes`, `DaemonRoutes`,
  `DocsRoutes`. Seventh site: `MavenChecksums` gains `hexDigest(InputStream, String)`, the
  `Path` overload is deleted, caller wraps `blobStore.open(id)`.
- Trade-off, named: `sendFile` released the worker for the transfer; `BlobSender` holds it.
  Uploads already hold workers for whole transfers and `quarkus.vertx.max-worker-execute-time=
  PT30M` exists for exactly that. Add `quarkus.vertx.worker-pool-size=40` (documented) for
  concurrency headroom; an event-loop chunk-pump is the recorded future option.

### 3. Concurrency: writeLock/ATOMIC_MOVE → advisory locks

Per-blob `pg_advisory_xact_lock(hashtextextended(:sha, 0))` inside both transactions —
the exact writeLock semantics ("check-and-move cannot interleave with check-and-unlink"),
and correct across replicas, which the in-process lock never was.

- promote (one short JDBC tx): advisory lock; `insert into blob ... on conflict (id) do
  nothing`; inserted → flip `blob_content` to PROMOTED; conflict (dedupe) → delete the staged
  `blob_content` (cascades chunks); return `!inserted`.
- delete (one short JDBC tx): advisory lock; `select ... for update` → gone = ALREADY_GONE;
  `stored_at` inside grace = WITHIN_GRACE_WINDOW; `guard.stillUnreferenced` (in-memory set
  test, same as today) = STILL_REFERENCED; else delete row + content (cascade) = DELETED.

### 4. Transactions and threading

Blob bytes bypass Hibernate and JTA entirely: `BlobStore` injects
`@io.quarkus.agroal.DataSource("artifacts") AgroalDataSource` and speaks hand-written JDBC.
No `@ActivateRequestContext` needed (it runs on raw Vert.x workers today with no context —
preserved, not patched); no 1 MiB byte[] entities in a Hibernate session; no interference
with the services' `@Transactional` row work.

- Chunk writes: autonomous single-statement autocommit inserts — one connection borrow of
  microseconds per chunk; a 1 GiB push never holds one long transaction pinning a connection
  and bloating the WAL-visibility horizon. Crash mid-upload leaves committed STAGING chunks =
  exactly what the staging sweep exists for.
- Chunk reads: one autocommit SELECT per chunk; never a connection held across a client
  stall, a JGit pause, or a slow docker pull. Content-addressed immutability makes per-chunk
  snapshots safe without a spanning transaction.
- Identity rows keep today's exact shape (staging outside the row transaction; promote before
  the `@Transactional` row write; `CatalogRepository`'s `QuarkusTransaction.requiringNew` +
  `@ActivateRequestContext` pattern untouched). A failure between promote and rows leaves an
  orphan `blob` row = today's orphan file — census-visible, grace-reclaimed.
- Pool: default Agroal max is fine; state `quarkus.datasource.artifacts.jdbc.max-size=20`
  explicitly with a comment saying why nothing needs more (nothing long-holds).

### 5. BlobDiskIndex / LiveBlobCensus / GC

- `BlobDiskIndex` keeps its name and its one public method but becomes
  `select id, size_bytes from blob`. The 60 s cache, `stale` flag, the walk, and
  `invalidate()` (+ both callers) are deleted — the query can never be stale.
- `LiveBlobCensus` changes only javadoc: "on disk" means "promoted blob rows". The byte-exact
  invariant survives over the same map. Orphans survive intact: a `blob` row no identity row
  names is exactly today's row-less file; STAGING content is invisible to the census exactly
  as `tmp/` was. Git pack blobs remain row-less and structurally unreachable — unchanged.
- GC invariants untouched: "a blob becomes a candidate only by losing its last identity row";
  recursive OCI manifest closure via `blobStore.open` (untouched); the narrow doors
  (`BlobReclaim`, `*RegistryCollection`) unchanged in API. The H2 "SHUTDOWN COMPACT" caveat
  becomes "DELETE returns space via autovacuum" — record in `GcRules`' note and the README.

### 6. Flyway: fresh PostgreSQL lineage

New location `artifacts/src/main/resources/db/artifacts/postgresql/` with one `V1__init.sql`:
the current 22-table schema translated (`clob` → `text`; `timestamp(6) with time zone`, named
FKs, and V7's `values (...)` prefill are already valid PG) + the three blob tables + the
current `RepositoryType` check constraint + the mirror-upstream prefill (hub/quay/redhat).
Config: `quarkus.flyway.artifacts.locations=classpath:db/artifacts/postgresql`; drop
`baseline-on-migrate` (every PG database starts empty).

Why not port the 13 H2 files: V2's `execute immediate` + information_schema constraint-name
lookup is unportable and meaningless on PG (no H2-auto-named constraint ever existed there);
no PG database has run the old lineage, so porting buys a false history. The
"unsquashed, never renumber" rule is a property of the H2 lineage's continuity — a new engine
is a new lineage, recorded as a decision in AGENTS.md, not drifted into. The H2 migration
directory is deleted with the driver (git history keeps it; the migration tool ships the
schema for the copy).

`OciMirrorMigrationTest` keeps both assertions (check-constraint re-enumeration; three
prefilled mirror rows) and runs Flyway over the new location against a throwaway embedded-PG
database.

### 7. Tests: Zonky embedded-postgres

- Root pom `dependencyManagement`: import `io.zonky.test.postgres:embedded-postgres-binaries-
  bom:18.4.0` (matches prod 18.4; verify availability at execution time — fall back to 17.x,
  tests only, if 18 binaries are missing). Test deps: `io.zonky.test:embedded-postgres` 2.x +
  explicit `-linux-amd64`, `-linux-arm64v8`, `-darwin-arm64v8` binaries so clone-alone holds
  on other machines.
- `EmbeddedPg` holder (~60 lines, COPIED into artifacts/gc/service test sources — the modules
  share no test classpath by rule; `GcFixture`/`SeededStoreFixture` precedent; the
  qits-deployments repo lands this pattern first via the prerequisite plan — copy from it): one
  `EmbeddedPostgres` per surefire JVM (shutdown hook), creates the module's database on first
  ask, plus a `ConfigSource` (registered via `META-INF/services`, ordinal above the test
  `application.properties`) supplying `quarkus.datasource.artifacts.jdbc.url/username/
  password`. Per-module database names `artifacts` / `artifacts-gc` / `artifacts-svc` mirror
  today's distinct H2 names (two suites in one build must not collide). `clean-at-start`
  stays, now wiping blob tables too.
- Native ITs (`PackagedProcessIT`, `ProtectedGitHostIT`, `OciConformanceIT`): profiles replace
  the file-H2 url + blobs-dir overrides with the embedded-PG url/credentials for a distinct
  `artifacts-it` database, handed to the compiled binary as `-D` flags; the url travels
  through a system property (a `QuarkusTestProfile` instantiates in two classloaders — the
  documented StubIntake trap). The embedded server outlives the binary because the holder's
  lifetime is the surefire JVM.
- Fixtures: `ArtifactsTestSupport.reset()` keeps the FK-ordered repository wipes and replaces
  the directory walk with `delete from blob; delete from blob_content;` (cascade takes
  chunks; no FK ties blob tables to identity tables, order is free); drop
  `diskIndex.invalidate()`. `backdate(blobId, age)` becomes
  `update blob set stored_at = now() - :age`. Same two edits copied into `GcFixture`.
  `BlobStoreTest` path-traversal cases become malformed-id 404 assertions; tmp-emptiness
  assertions become "no STAGING rows after discard". The service module's "unique content per
  RUN" rule stays (dedupe within a run is still real); update the comments that say nothing
  wipes the blobs dir.

### 8. Dependencies, config, Dockerfile

- `artifacts/pom.xml`: `quarkus-jdbc-h2` → `quarkus-jdbc-postgresql`; add
  `org.flywaydb:flyway-database-postgresql` (mandatory with Flyway 10+ under Quarkus 3.x).
  `gc`/`service` poms: zonky test deps (driver arrives transitively as today).
- `artifacts/.../META-INF/microprofile-config.properties`: `db-kind=postgresql`; map the
  datasource onto the generic resource contract —
  `quarkus.datasource.artifacts.jdbc.url=${QITS_RESOURCE_DB_URL}`, `username=${QITS_RESOURCE_DB_USERNAME}`,
  `password=${QITS_RESOURCE_DB_PASSWORD}` (unset vars refuse boot at Flyway before the HTTP
  listener — the Dockerfile's refuse-to-boot stance, now enforced by unresolved config);
  DELETE `qits.artifacts.blobs-dir`; add `qits.artifacts.staging-ttl=P1D`; keep
  `qits.artifacts.gc.blob-grace-period=P7D`.
- `docker/Dockerfile`: drop the `/data` volume + ownership lines + the two-required-vars
  story; required env becomes the generic resource triple `QITS_RESOURCE_DB_URL/_USERNAME/
  _PASSWORD`, normally injected by the deployer's `resources:` mechanism; header
  comment rewritten — the container is stateless, a restart loses only in-flight upload
  sessions, which the OCI spec permits. Note that the one-time H2+disk → PG copy is an ops
  action with its own tool, not this service's boot path.
- Readiness: LET the default Quarkus datasource health check stay on (do not disable). This
  deliberately departs from the recorded "readiness independent of external deps" stance —
  that stance exists for the idp, which is auxiliary. PG IS the store; a ready-but-storeless
  registry would make the deployer cut over onto a dead store. OIDC stays excluded exactly as
  today.
- Native image: `quarkus-jdbc-postgresql` is a fully supported extension (reflection/SCRAM
  handled). Per the repo's own rule the gate is `PackagedProcessIT` against the binary, not
  `mvn verify` — it lands in WP-A1, before any byte moves.

## Part II — platform ops

### 9. PG hardening — SUPERSEDED by postgres-resource-provisioning-plan.md (except backups)

The prerequisite plan lands the image hardening (volume at `/var/lib/postgresql` per the
pg-18 layout, CLI-randomized superuser password from the very first boot, `CMD` tuning) and
replaces the per-service initdb script with qits-deployments' `resources:` provisioning.
There is no initdb script and no `QITS_PG_ARTIFACTS_PASSWORD` env on the postgres image.
What THIS plan still does:

1. **Add `resources: postgresql:db:qits_artifacts` to artifacts' `.config/qits/deployments.yml`
   AHEAD of the code cutover.** The next deploy provisions role+database while artifacts still
   runs on H2 (the injected `QITS_RESOURCE_DB_*` env is simply unused), so credentials exist
   before cutover day. Verify after that deploy: `\l` shows `qits_artifacts` owned by itself;
   the `pd_resource` row exists.
2. Credential lookup for ops and the migration tool: the password lives in the deployer's
   registry, not `.qits-bootstrap.env` —
   `select password from pd_resource where application_name = 'qits-platform-artifacts' and
   resource_name = 'db'` against the `qits_deployments` database. Rotation = manual
   `ALTER ROLE` + row update, or the deployer's reconcile arm.
3. Backups BEFORE the data becomes precious: host-side nightly cron
   `docker exec <pg> pg_dump -U postgres -Fc qits_artifacts` AND `... -Fc qits_deployments`
   (the deployer's store shares the instance now) into a `qits-pg-backups` volume (not the PG
   data volume), keep 7, one restore drill pre-cutover. Layers are already compressed —
   expect the dump near raw size; watch headroom.
4. `health_cmd: pg_isready -U postgres` stays (unchanged, from the prerequisite plan).

### 10. Migration tool: new `migration/` module in qits-platform-artifacts

A separate JVM-only uber-jar, run by hand on the host; never in the service image. Why not a
migration mode in the service: the target image is PG-only and should not carry H2, its
Flyway lineage, or a boots-copies-exits lifecycle fight forever for a one-shot copy. Plain
JDBC, both drivers on its classpath; depends on the `artifacts` module for the PG Flyway
resources so it can pre-apply the schema (making the service's own migrate-at-start a no-op
at first boot).

Interface:

```
java -jar migration-runner.jar    — config via env:
  QITS_MIGRATE_H2_URL        jdbc:h2:file:/data/artifacts/h2/artifacts  (rows/verify only)
  QITS_MIGRATE_BLOBS_DIR     /data/artifacts/blobs
  QITS_MIGRATE_PG_URL        jdbc:postgresql://prod-qits-oci-postgresql:5432/qits_artifacts
  QITS_MIGRATE_PG_USERNAME   qits_artifacts
  QITS_MIGRATE_PG_PASSWORD   <from the pd_resource row — §9.2>
  QITS_MIGRATE_PHASE         schema | blobs | rows | verify | all
Phases:
  schema  apply the service's PG Flyway lineage (same resources, same versions)
  blobs   DISK WALK of the fan-out dirs; per <sha>: skip if PG has it with matching size
          (content-addressed = natural upsert), else stream file → chunk rows, one
          transaction per blob; preserve file mtime into stored_at (fallback now() —
          only DELAYS GC eligibility, never accelerates)
  rows    per-table H2 → PG, PK order, batched, ON CONFLICT DO NOTHING (delta-safe rerun)
  verify  per-table counts H2 vs PG; blob count + bytes disk-walk vs PG; re-hash 32 random
          digests by streaming chunks from PG; re-hash the CI-daemon digest specifically
          (the one blob whose loss is silent and platform-wide)
Exit codes: 0 ok / 1 verification mismatch / 2 error. Every phase rerunnable; reruns are deltas.
```

The blob copy is disk-walk-driven, NOT row-join-driven, and copies everything — three reasons:
~95% of bytes (OCI layers) have no row at all and ARE the registry's content; one "orphan" is
the live CI daemon binary every CI step downloads; and GC's "candidate only by losing its
last identity row" posture means row-less blobs are structurally untouchable — filtering here
would be a silent GC decision this migration has no mandate for. The 124 MiB orphan cost is
immaterial against 5.4 GiB.

Locking constraint that shapes the runbook: the H2 file is exclusively locked by a running
artifacts; blob files are immutable and copyable LIVE. Hence two-phase: warm blob pass with
artifacts serving (15–45 min for ~5.4 GiB over qits-net; `max_wal_size=4GB` matters here),
then a short freeze for rows (~10–20 min, dominated by 660 MB of packument CLOBs) + delta.

Run command (host-side manual ops is the established pattern; `:ro` so the tool is
structurally unable to write the store it reads; use a JRE image already in the host docker
cache so the migration never depends on the registry it is migrating):

```sh
docker run --rm --network qits-net \
  -v qits-platform-artifacts-data:/data:ro \
  -v .../migration/target/migration-runner.jar:/migrate.jar:ro \
  -e QITS_MIGRATE_PHASE=... -e QITS_MIGRATE_PG_URL=... -e ... \
  <cached JRE image> java -jar /migrate.jar
```

### 11. Run-args / deployment config changes (cutover step)

Everything lives in two generated-in-lockstep places: `ComposeTemplate.java` (run-args +
volumes + seed services) and the committed `docker-compose.qits.yml` (regenerated output —
never hand-edited). At cutover, the deployer-side run-args file on the
`qits-deployments-config` volume is edited directly (same transport `pdRunArgs` uses), then
the live deployer is `docker restart`ed (it caches run-args at ITS boot).

`qits-platform-artifacts` line: DROP `-v qits-platform-artifacts-data:/data`, the H2
`QUARKUS_DATASOURCE_ARTIFACTS_JDBC_URL`, and `QITS_ARTIFACTS_BLOBS_DIR`. **Nothing is
added** — the `QITS_RESOURCE_DB_*` triple is injected by the deployer's `resources:`
mechanism (the spec line from §9.1 is already live and provisioned).
KEEP `-p 127.0.0.1:${REGISTRY_PORT}:8080` (the host docker daemon and the deployer pull
through it) and every other `-e` byte-identical. `deployments.yml` already carries the
`resources:` line; `health_path` stays; volumes were never in specs.

### 12. Cutover runbook

Preconditions: prerequisite plan live; `resources:` line deployed and role/db provisioned
(§9.1 verified); backups running with one proven restore; migration jar built; the PG-only
artifacts branch pushed to the platform git host with its sha build green; old ACTIVE
container name + image sha noted (rollback target).

- **A — warm copy (live, no freeze):** `PHASE=schema`, then `PHASE=blobs` repeatedly until
  the delta is seconds; `verify` (blob half).
- **B — freeze + rows (~15–30 min registry downtime):** CI queue empty, nothing in flight
  (artifacts' own pipeline rule: it deploys alone). Extra `pg_dump` now + snapshot the H2 dir
  to the backup volume. `docker stop` artifacts (H2 unlocks). `PHASE=all`. GATE: exit 0 — on
  mismatch `docker start` artifacts and abort, nothing changed. `docker start` artifacts —
  old store serves again; confirm health.
- **C — flip + release:** edit run-args (§11); `docker restart` deployer; release via quiet
  branch push + `POST /workspaces/api/branches/release?repositoryId=qits-platform-artifacts`.
  The pipeline builds/pushes into the OLD store (that's why B restarted it). Deployer pulls
  BEFORE stopping the predecessor (deliberate, for exactly this registry-self-replacement),
  stops old, starts new against PG; Flyway is a no-op (schema pre-applied at the exact
  lineage); health gate on `/artifacts/q/health/ready` — now truth-telling about PG. Failed
  gate auto-removes the successor and restarts the predecessor: back on H2, nothing lost.
  Verify run row + container sha.
- **D — post-cutover delta (MANDATORY, still frozen):** the release pipeline wrote the
  release commit (git host) and the new image (registry) into the old store; the old
  container is now stopped and H2 unlocked — rerun `PHASE=all` against the old volume; the
  upserts carry exactly those writes into PG. Until this runs, nothing but the host image
  cache could redeploy artifacts. Gate: `docker pull` the new release tag through the
  registry.
  Then functional verification: health; mirror pull + hosted pull + scratch push; git clone +
  quiet branch push/delete (post-receive fires); npm install + one proxy fetch; one maven
  fetch; `/artifacts/api/store/summary` totals sane; `GET /artifacts/api/gc/plan` shows no
  anomalous mass-deletion (grace sanity). Unfreeze; one canary CI run end-to-end. Keep the
  stopped old container (it is the rollback body).
- **E — decommission (T+30 days):** after ≥30 clean days (beyond every GC grace window), one
  successful artifacts redeploy on PG, one PG restart with artifacts reconnecting, and
  verified backups: delete the stopped old container, `docker volume rm
  qits-platform-artifacts-data`, delete the H2 snapshot, purge H2 spellings from docs.

Rollback by phase: A/B — free, nothing changed. C before gate — automatic. After C/D —
restore the old run-args line, restart deployer, redeploy the prior release (image in the old
store + host cache; H2 volume untouched since B). Writes to PG since cutover are lost to the
H2 world — hold the freeze through D so that window is ≈ the canary only. The "no rollback
across Flyway migrations" rule does not bite: the old volume's H2 was never touched by the
new lineage.

### 13. Bootstrap (cli/qits-cli-bootstrap) — mostly subsumed by the prerequisite plan

The prerequisite plan lands: `oci-postgresql` in PlatformModel (repoPath, CORE, DEPLOYABLES),
the `seed-postgres` phase (JDBC provisioning via `PgAdmin`, randomized superuser password,
`.qits-bootstrap.env` persistence), the compose service + run-args + volume, the unwrap
patterns, and the `BootstrapState.write()` fix. Residue for THIS plan:

- `seedArtifactsStart`: drop `-v qits-platform-artifacts-data:/data`, the H2 url,
  `QITS_ARTIFACTS_BLOBS_DIR`, and `ensureVolume(qits-platform-artifacts-data)`; add the
  `QITS_RESOURCE_DB_*` triple dialing
  `jdbc:postgresql://${ENV_NAME}-qits-oci-postgresql:5432/qits_artifacts`. Same swap in the
  artifacts compose service block and run-args line (volume declaration removed from the
  template's volumes block).
- `seed-postgres`'s CLI provisioning list gains `qits_artifacts` beside `qits_deployments`
  (seed artifacts boots before the deployer exists, so its credential must be CLI-issued:
  `PG_ARTIFACTS_PASSWORD` in `.qits-bootstrap.env`). **Ownership note:** once the deployer's
  first artifacts deploy runs the resources mechanism, the `pd_resource` row becomes the
  authority; use create-if-missing (no ALTER) semantics for this role in `PgAdmin` so a CLI
  rerun never rotates a password the registry owns — a mismatch self-heals via the deployer's
  reconcile arm on the next artifacts deploy.
- Lands AFTER the cutover; proven with a real `unwrap` + `bootstrap` on a scratch machine
  (a bootstrap of the new CLI against an H2-only artifacts image is incoherent).

## Work packages, ordered

| WP | What | Depends on |
|----|------|-----------|
| C1 | Landed via postgres-resource-provisioning-plan.md (PG hardened, resources: mechanism live). Residue here: add `resources: postgresql:db:qits_artifacts` to artifacts' deployments.yml, deploy, verify role/db + pd_resource row (§9.1) | prerequisite plan live |
| C3 | Backup cron + restore drill (§9.3) | C1 |
| A0 | Code: filesystem-free BlobStore surface, still H2+disk (openChannel/stageScratch/BlobSender/checksum overload; 6+1 call sites; DocsBundle; BlobStorePackBlobStore; delete locate/newStagingFile). Behavior-neutral — releasable early via the normal flow; de-risks serving independently of PG | — |
| A1 | Code: datasource H2→PG (pom swaps, zonky infra, PG V1 lineage with dormant blob tables, test wiring, db-kind flip, url-default removal). Gate: `mvn verify` AND `-Dnative` ITs | A0 |
| A2 | Code: blob bytes into PG (BlobStore internals, BlobChunkChannel, PG ScratchBlob, advisory locks, stored_at grace, staging sweep, BlobDiskIndex one-query, fixture SQL, blobs-dir removal) | A1 |
| A3 | Code: Dockerfile (stateless, three-var contract), delete H2 lineage dir, README/AGENTS.md updates, worker-pool + max-size entries | A2 |
| B | Migration module (schema/blobs/rows/verify) | A1 (schema) |
| CUT | Cutover runbook §12 (A1–A3 released here, from the green branch) | C1, C3, A3, B |
| F | Bootstrap CLI residue (§13), proven by scratch-machine bootstrap | CUT |
| E | Decommission (§12-E) | CUT + 30 days |

Each A-package leaves `mvn verify` green (617 tests, no docker). A1–A3 stay on a branch until
CUT — unreleased work stays on branches; H2 keeps shipping until the cutover releases the
PG-only image through the workspaces endpoint.

## Risk register

| Risk | Mitigation |
|------|-----------|
| Circularity loop: PG down degrades the registry; redeploying PG pulls its image FROM that registry; redeploying artifacts needs PG up (Flyway at boot). Both down = deadlock | Deployer pulls before stopping (routine deploys never enter the loop). Break-glass in the image README: manual `docker run` of the host-cached PG image with volume + password resolves the alias; artifacts reconnects. Ordering rule in both READMEs: PG ACTIVE before any artifacts deploy, never queued together. Post-decommission the rollback target is also PG-backed — the break-glass PG start is the real floor; full bootstrap (F) brings its own seed postgres as last resort |
| PG data loss = platform loss (registry+git+npm+maven+docs in one datadir) — strictly worse blast radius than today's two stores | Backup cron BEFORE cutover; nightly pg_dump -Fc, keep 7, restore drills; the H2 volume is a full secondary fallback until decommission |
| pgjdbc in the native image | Supported extension; the gate is PackagedProcessIT against the binary (A1, before bytes move) — the repo's own rule says mvn verify is not the gate for datasource config |
| Memory/backpressure of chunk streaming | ≤ ~3 MiB transient heap per transfer by construction; BlobSender parks on writeQueueFull() after EVERY chunk (else a fast DB + slow client buffers the blob in Netty) — unit test with a paused reader beside it |
| Worker occupancy: downloads now hold workers where sendFile didn't | PT30M ceiling already set; worker-pool-size=40; event-loop chunk-pump recorded as the future option, doable without touching call sites |
| promote-vs-delete race | Advisory xact locks reproduce writeLock exactly, multi-replica-proof; grace window (stored_at, never refreshed on dedupe) stays the belt over the probe-then-manifest race |
| Staging sweep vs live uploads | In-process open-stage set excludes live stages; P1D TTL dwarfs the PT30M session TTL and worker ceiling |
| Release-pipeline writes stranded in the old store at cutover | Runbook D delta pass, mandatory, gated on docker-pulling the new release tag |
| PG-18 volume layout trap (mount at .../data → data dies silently) | Mount /var/lib/postgresql; restart-survival check landed in the prerequisite plan's verification |
| Run-args edit wrong / deployer restart forgotten (the documented "boots healthy, lost its database" failure) | No default URL + datasource readiness = a datasource-less boot now fails loudly; sha256sum the config file before/after; restart-deployer is a numbered runbook step |
| DB growth semantics: every byte now WAL'd (~2× ingest amplification); git's append-forever lands in PG; conversely GC DELETE finally returns space via autovacuum | max_wal_size=4GB; wal_compression=lz4; ops-facing note in README; backups sized accordingly |
| Zonky 18.4.0 binaries availability | Verify at A1 start; fall back to 17.x binaries (tests only) |
| H2→PG behavioural drift | JPQL-only repositories minimise it; identifier/char/timestamptz differences designed around (varchar, no char); OciConformanceIT (586 tests) is the external falsifier for the OCI surface |
| Seed compose / ComposeTemplate drift | Both change in one commit; the committed compose is regenerated, never hand-edited |
| Bootstrap regression (F changes the only bring-up path) | Real unwrap + bootstrap on a scratch machine, after CUT so the released image is PG-only |

## Verification summary

- Per code WP: `mvn verify` green without docker; A1+A2 also `-Dnative` (PackagedProcessIT,
  ProtectedGitHostIT) and `-Doci.conformance-binary` (586 conformance tests).
- Migration: the tool's own verify phase (counts, bytes, 32 random re-hashes, the CI-daemon
  digest).
- Cutover: runbook D functional checks + canary CI run.
- Bootstrap: scratch-machine unwrap + bootstrap.

## Key files

- `services/qits-platform-artifacts/artifacts/.../control/BlobStore.java`,
  `BlobDiskIndex.java`, `LiveBlobCensus.java`, `MavenChecksums.java`
- `services/qits-platform-artifacts/service/.../githost/persistence/BlobStorePackBlobStore.java`
- `services/qits-platform-artifacts/service/.../registry/RegistryRoutes.java` (+
  Npm/Maven/Daemon/DocsRoutes, `DocsBundle.java`), new `registry/BlobSender.java`
- `services/qits-platform-artifacts/artifacts/src/main/resources/META-INF/microprofile-config.properties`,
  new `db/artifacts/postgresql/V1__init.sql`
- `services/qits-platform-artifacts/docker/Dockerfile`; new `migration/` module; test
  `EmbeddedPg` ×3 + `ArtifactsTestSupport.java` / `GcFixture.java`
- `images/qits-oci-postgresql` — hardening landed via the prerequisite plan; no changes here
- `cli/qits-cli-bootstrap/.../platform/ComposeTemplate.java`, `PlatformModel.java`,
  `.../phases/SeedPhases.java`, `BootstrapState.java`, `UnwrapPhases`;
  `docker-compose.qits.yml` (regenerated)
