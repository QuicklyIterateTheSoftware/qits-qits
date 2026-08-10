# PostgreSQL resource provisioning — prerequisite to qits-artifacts-postgresql-plan.md

Status: **ROLLED OUT 2026-08-09.** The re-bootstrap runbook ran the same day: the platform is
live on provisioned PostgreSQL databases end to end, every service pipeline-deployed, the
deployer self-hosted on PG. Three defects were found and fixed during the live run (patient
health gate; DbRetry around the self-cutover; `health_path` pinned in the deployer's spec —
the rename-era correction had lived only in a DB row the reset erased). A fourth landed right
after: SCMRelease payloads now carry `repositoryName` beside the row id, because reconciled
repos get per-instance UUID ids no committed config can name. Remaining defect register lives
in the session log / memory: eventstream subscriber restart fragility (docker-restarted
containers never redial the bus; fresh deploys do), silent no-match in CI event triggers,
SoftwareRelease still UUID-only, the SCMRelease-vs-upload pin race, and a gitlink-reachability
unwrap preflight. The section below is retained as the original implementation record.

Original status: implemented 2026-08-09 — and extended the same day to the whole
platform. WP-0 through WP-4 are committed locally, and the datasource sweep followed: every
H2 datasource EXCEPT qits-platform-artifacts is now PostgreSQL on the local mains —
qits-deployments (platformdeployments), qits-ci (ci + eventstream), qits-workspaces
(workspaces + eventstream), qits-projects (projects + epics), qits-events, qits-platform-dns,
qits-platform-idp, and libs/qits-eventstream. All JVM suites and native builds are green.
Nothing is pushed or released — the live platform still runs H2 everywhere. Do NOT push any
of these mains to the platform git host before the re-bootstrap runbook below runs. artifacts
deliberately stays on H2 until its own plan (qits-artifacts-postgresql-plan.md) executes.

Sweep facts the runbook now depends on:
- ci and platform-idp are CORE seeds: the CLI provisions qits_ci, qits_ci_eventstream and
  qits_platform_idp create-only (PG_CI_PASSWORD / PG_CI_EVENTSTREAM_PASSWORD /
  PG_PLATFORM_IDP_PASSWORD in .qits-bootstrap.env); ownership moves to the deployer's
  pd_resource registry at each app's first pipeline deploy. qits_deployments alone stays
  CLI-converged (ALTER-always) because the deployer self-registers that credential.
- projects and workspaces KEEP their data volumes (git mirrors + credentials; workspace
  data-dir); ci, idp and events lost theirs — their images declare no disk state.
- qits-eventstream is a released Maven artifact (2026.802.154015). The PG build is installed
  locally in ~/.m2 UNDER THE SAME VERSION (overwriting the H2 jar); the platform repo still
  serves the H2 jar. The re-bootstrap's publish-qits-eventstream phase republishes from the
  local checkout into the fresh platform repo, which resolves this. A clean-~/.m2 build of
  ci or workspaces before the re-bootstrap fails on the H2 jar — expected, not a regression.
- qits-platform-dns flipped too but has no bootstrap presence; it gained a deployments.yml
  (platform target) and needs a health answer before its first-ever deploy — open follow-up.
- The run-args lines for flipped services carry NO datasource env (the deployer injects it);
  only the seed compose blocks for ci/idp spell the triples, because no deployer exists yet
  at seed-stack time. ComposeTemplateTest.onlyArtifactsStillCarriesAFileDatabase guards that
  artifacts is the only H2 line left.

## Goal

Provisioning rides the deployment flow instead of a standing operator: a repo declares
resources in `.config/qits/deployments.yml`; qits-deployments idempotently creates
role+database on the platform's postgres BEFORE the cutover, generates and persists
credentials in its own registry, and injects them as generic env vars into the container it
starts. The deployer itself is adopter #1: its own store moves from file-H2 to PostgreSQL,
migrated by unwrap + re-bootstrap (no H2→PG data migration for it).

Decisions (user, fixed):
- Generic env contract `QITS_RESOURCE_<NAME>_URL/_USERNAME/_PASSWORD`; apps map the vars in
  their own shipped config defaults. Deployer stays framework-agnostic.
- Never auto-drop databases/roles (obsolete-marking is future work).
- The bootstrap CLI provisions via regular JDBC — no psql, no docker exec, no shell.
- Bootstrap order: postgres FIRST, started with a CLI-randomized superuser password from its
  very first boot; then the deployer's role/db via JDBC; then the deployer.
- All generated credentials persist in `.qits-bootstrap.env` (given > kept > generated).
- postgres stays `deployment_target: environment`.
- Migration of the deployer = unwrap + re-bootstrap, with a new unwrap toggle that deletes
  only data volumes and keeps config/auth volumes.

## 1. The `resources:` grammar (flat — the spec parser stays a line reader)

`DeploymentSpecParser` deliberately parses no nesting and no YAML lists (indented lines
rejected; `deploy_branches` is comma-separated for exactly this reason). So:

```
resources: <entry>[, <entry>]*
entry     := postgresql:<name>[:<database>]
name      := [a-z][a-z0-9-]{0,31}       # env-key segment (uppercased, - → _) + registry key
database  := qits_[a-z0-9_]{1,58}       # also the role name (role = database, one identity)
```

- Default database (third segment omitted): `qits_` + application name minus a leading
  `qits-`, dashes→underscores. The parser does not know the application name, so it emits
  `database = null` and `DeployService.register` resolves the default from the repoId.
- Errors, each a sentence naming file+line: unknown type, charset violation, blank entry,
  duplicate name, duplicate database (parser catches literals; DeployService catches
  defaulted collisions after resolution).
- The `qits_` prefix structurally excludes `postgres`, `template0/1`, `pg_*`.
- Tolerance is forever: specs are fetched at the built sha, so once `resources` ships it can
  never become an unknown key again — say so in the parser javadoc in the same commit.

Examples:
```yaml
resources: postgresql:db                                  # qits-deployments → qits_deployments
resources: postgresql:db:qits_artifacts                   # artifacts (default would be qits_platform_artifacts)
resources: postgresql:projects, postgresql:epics:qits_epics   # two databases
```
Third example's env: `QITS_RESOURCE_PROJECTS_*` and `QITS_RESOURCE_EPICS_*`.

## 2. Env contract and host resolution

- URL `jdbc:postgresql://<pg-host>:5432/<database>`; username = role = database; password
  from the registry.
- Environment app: `<pg-host>` = `PdNetworks.alias(envName, "qits-oci-postgresql")`
  (`environments/.../control/PdNetworks.java:67`). Platform-plane app (null env): resolve via
  the existing `EnvironmentService.platformEnvironment()` (worker-safe) → its name yields
  `prod-qits-oci-postgresql` today. No new config key.
- Injection in `DockerDeploymentDriver.buildArgv` BEFORE run-args, via the existing `env()`
  helper — docker keeps the last `-e`, so operators can override per app (the recorded
  precedence rule, with its test twin).

## WP-0 — cli/qits-cli-bootstrap pre-prerequisites (land first, independently useful)

**WP-0a. Fix `BootstrapState.write()` dropping unknown keys** (`BootstrapState.java:75-99`
rebuilds the file from DAEMON_SHA + idp secrets only, contradicting its own comment). Merge
over the map `read()` loaded; add `put(key, value)` / `value(key)` / no-arg `write()`.
Tests: unknown-key round-trip; PG keys survive an idp-secrets rewrite.

**WP-0b. Unwrap toggle.** New flag `--with-data-volumes` on `UnwrapCommand` (mutually
exclusive with `--with-volumes`, which stays the full slate). New phase `volumes-data`:
deletes volumes matching `qits-*-data` (+ `qits-maven-seed`, + the new
`qits-oci-postgresql-data`); keep-patterns win and are checked first: `qits-*-config`
(today exactly `qits-deployments-config` — push token, client secrets, run-args). Anything
matching neither set is kept. Patterns-only-added rule respected; logs kept vs deleted;
honors `--dry-run`.

## WP-1 — images/qits-oci-postgresql (hardening; supersedes artifacts-plan §9.1–9.4)

**No initdb script — provisioning is qits-deployments' job.**
1. Keep `FROM localhost:8081/hub/library/postgres:18.4` and `ENV POSTGRES_PASSWORD=qits-poc`
   as the bare-boot placeholder; README notes it is dead on the platform from the first boot
   (CLI/run-args `-e` override wins).
2. Data volume mounts at **`/var/lib/postgresql`** (postgres-18 layout:
   PGDATA=`/var/lib/postgresql/18/docker`; a `/var/lib/postgresql/data` mount silently loses
   data). Document + prove with a restart-survival check.
3. Tuning via Dockerfile `CMD`: `postgres -c shared_buffers=512MB -c max_wal_size=4GB
   -c wal_compression=lz4 -c checkpoint_completion_target=0.9`. Nothing else.
4. `deployments.yml` unchanged (`environment` target, `health_cmd: pg_isready -U postgres`).
5. README: replace the PoC caveats with the real mechanism.

## WP-2 — services/qits-deployments (the mechanism + its own move to PG)

### 2.1 Parser + DTO
- Sixth key `resources`; extend the unknown-key message; new `resources(...)` parsing §1's
  grammar with `PdIdentifiers` validation.
- `SpecSource.DeploymentSpec` gains `List<ResourceSpec> resources`
  (`record ResourceSpec(String name, String database /* null = default */)`); DEFAULTS empty.
- Resources take the healthCmd route (spec data no row stores): `Target` → `Plan` →
  `StartSpec`.

### 2.2 Validators (PdIdentifiers — stored values, health_path stance)
`requireResourceName` (`[a-z][a-z0-9-]{0,31}`) and `requireDatabaseName`
(`qits_[a-z0-9_]{1,58}`) in `environments/.../PdIdentifiers.java`. Three checkpoints like
health_path: parser, provisioner immediately before SQL assembly, argv.

### 2.3 Registry table + fresh PG Flyway lineage
The deployer flips wholesale to PG (re-bootstrap migration ⇒ the H2 lineage has no remaining
consumer): replace `db/platformdeployments/migration/` with a fresh PG `V1__init.sql` — the
four existing tables translated (identity columns, `text`, V2's platform flag folded in;
keep no-check-constraint and no-partial-unique parity deliberately, documented), plus:

```sql
create table pd_resource (
    id                  varchar(255) not null primary key,
    application_name    varchar(64)  not null,
    environment_name    varchar(64),          -- plain string, not FK; null = platform plane
    resource_name       varchar(64)  not null,
    resource_type       varchar(32)  not null, -- 'postgresql'
    database_name       varchar(64)  not null,
    role_name           varchar(64)  not null,
    password            varchar(128) not null, -- generated hex; this DB is credential-bearing now
    created_at          timestamp(6) with time zone not null,
    last_provisioned_at timestamp(6) with time zone,
    constraint uq_pd_resource unique nulls not distinct (application_name, environment_name, resource_name)
);
```
(`nulls not distinct` needs PG ≥ 15; prod 18.4.) Entity `PdResource` in `deployments/entity`,
repo in `deployments/persistence`. Delete `PdPlatformEnvironmentMigrationTest` with V2; port
`PdSchemaTest` to embedded PG (+ a nulls-not-distinct proof).

### 2.4 Third seam: `ResourceProvisioner` port + `ResourceProvisioning` orchestration
Exactly the SpecSource/DeploymentDriver shape: interface in `deployments/control`
(`ensure(Request) → Result`; Request carries host/port/admin creds/database/role/
storedPassword/freshPassword; Result carries ok/passwordInEffect/detail), impl
`service/pghost/PgResourceProvisioner.java` using plain `DriverManager` (pgjdbc via
`quarkus-jdbc-postgresql`, no second datasource, autocommit on — CREATE DATABASE cannot run
in a transaction block), `@Mock` fake beside FakeSpecSource/FakeDeploymentDriver.

Provisioner logic (identifiers re-validated immediately before assembly — DDL cannot be
parametrized; existence checks parametrized against pg_catalog; SQLSTATEs 42P04/42710 benign;
passwords never logged):
- role missing → `CREATE ROLE <r> LOGIN PASSWORD '<stored ?: fresh>'`; role exists ∧ stored →
  untouched; role exists ∧ no stored → `ALTER ROLE` to fresh (reconcile).
- db missing → `CREATE DATABASE <d> OWNER <r>` + `REVOKE ALL ON DATABASE <d> FROM PUBLIC`
  (PG 18: public schema already owned by pg_database_owner); db exists →
  `ALTER DATABASE <d> OWNER TO <r>` (heals half-provisioned state).

`ResourceProvisioning.ensureAll(app, envNameOrNull, resources)` — per resource: read row in
`requiringNew()`; outside any transaction resolve host + generate fresh password (32 hex,
SecureRandom — argv/URL/quote-safe) + call the port; upsert row in `requiringNew()` with
passwordInEffect + `last_provisioned_at`. Cross-check: refuse another application's claim on
the same database for the same instance (FAILED, not a silent no-op). Missing admin password
config → failure naming the key.

Idempotency matrix (row = registry, role/db = pg_catalog):

| row | role | db | action | injected pw |
|---|---|---|---|---|
| ✓ | ✓ | ✓ | no-op | stored |
| ✗ | ✗ | ✗ | CREATE both + REVOKE; insert row | fresh |
| ✓ | ✗ | any | self-heal (PG volume reset): CREATE ROLE with stored | stored |
| ✗ | ✓ | any | reconcile (deployer DB reset): ALTER ROLE to fresh; insert row | fresh |
| ✓ | ✓ | ✗ | CREATE DATABASE + REVOKE | stored |

Never any DROP.

### 2.5 Hook + argv
- `DeployService.execute()`: between the STARTING transition and `driver.pull` —
  `ensureAll(...)`; catch → `finish(FAILED, "[resource provisioning failed: …]")` and return.
  Rationale in a comment: a row exists to record failure on; nothing docker-side has happened;
  Plan is plain values so no transaction spans the network call.
- `DeploymentDriver`: `record ResourceBinding(String name, String url, String username,
  String password)`; `StartSpec` gains `List<ResourceBinding> resources`.
- `buildArgv`: after the OTEL pair, before run-args:
  `QITS_RESOURCE_<NAME(upper,-→_)>_URL/_USERNAME/_PASSWORD` via `env()`, with
  `requireResourceName` as the argv belt. Ordering IS the precedence: run-args override.

### 2.6 Deployer's own datasource → PG + boot self-registration
- `environments/.../META-INF/microprofile-config.properties`: db-kind postgresql;
  `jdbc.url=${QITS_RESOURCE_DB_URL}`, `username=${QITS_RESOURCE_DB_USERNAME}`,
  `password=${QITS_RESOURCE_DB_PASSWORD}` — adopter #1 of the generic contract; unset triple
  refuses boot at Flyway. Drop `baseline-on-migrate`.
- New `deployments/control/BootResourceRegistration.java` — `@Observes StartupEvent`,
  warn-only, TEST-skipped (the `DeployService.onStart` shape): if `QITS_RESOURCE_DB_*` +
  `QITS_ENVIRONMENT` are present, upsert its own `pd_resource` row (app `qits-deployments`,
  env name from `QITS_ENVIRONMENT`, resource `db`, database/role parsed from URL/username,
  stored password from env). This makes the next self-deploy hit the no-op row instead of the
  reconcile arm, and survives all containers dying.
- The deployer's own `.config/qits/deployments.yml` gains `resources: postgresql:db`.

### 2.7 Config, poms, native
- `qits.platform.deployments.postgres.admin-username=postgres`; admin-password deliberately
  no default (`Optional<String>`). Postgres app name + port are constants.
- Poms: `quarkus-jdbc-h2` → `quarkus-jdbc-postgresql` (environments/, deployments/);
  `flyway-database-postgresql`; zonky BOM 18.4.0 + per-arch binaries (test scope).
- No new Response entity types → `ApiWireReflection` untouched (state in commit message).
  Native gate: `./mvnw verify -Dnative` + `PdPackagedSurfaceIT`.

### 2.8 Tests
Embedded PG (zonky) mirroring the artifacts plan's wiring (`EmbeddedPg` holder + ConfigSource
per module; per-module databases `pd-deployments`/`pd-svc`). Additions: parser grammar
accept/reject; `PdSchemaTest` on PG; `PdDeploymentFlowTest` — resources provision before
pull, failure → FAILED with no pull/start, spec without key unchanged;
`ResourceProvisioningTest` — five matrix rows, platform-plane host derivation, missing admin
password, collision refusal; `PgResourceProvisionerTest` (plain JUnit vs embedded PG) —
create/rerun/self-heal/reconcile/REVOKE/owner/42P04; `DockerDeploymentDriverTest` — bindings
before run-args, operator override wins, hostile name throws; `PdPackagedSurfaceIT` — binary
refuses to boot without the triple, boots against embedded PG handed in as env.

### 2.9 Trust-rule amendments (same commit as the code)
- README "Trust boundaries": argv contributions now also come from this component's own
  provisioning; the spec's `resources:` line is repository-authored input ending in an argv
  AND in SQL against a SHARED postgres → health_path treatment (strict `qits_`-prefixed
  allowlist, validated at parser, before SQL, at argv). What a repository can NAME is a
  database of its own; the injected VALUES are generated by this component — nothing arriving
  over HTTP contributes a credential to a `docker run`, exactly as before.
- New bullet: provisioning speaks SQL, not shell; `exec` is still not in the vocabulary;
  admin credential comes from deployment config (the trust domain that already holds the
  socket) and is never stored in a row.
- Note: the `platformdeployments` database is credential-bearing now (`pd_resource.password`)
  — treat it with the sensitivity of the qits-deployments-config volume.
- AGENTS: add the identifiers to the PdIdentifiers list; record the fresh-PG-lineage decision.

## WP-3 — cli/qits-cli-bootstrap (JDBC provisioning; postgres first)

### 3.1 pgjdbc in the native CLI
Add `io.quarkus:quarkus-jdbc-postgresql` (native driver registration maintained by Quarkus);
configure NO datasource, inject NO DataSource — plain `DriverManager` for a handful of
idempotent statements. `quarkus.devservices.enabled=false` in the CLI's application.properties.
Fallback if the extension misbehaves datasource-less: plain `org.postgresql:postgresql` +
hand-written native metadata. `mvn verify` stays docker-free (unit-level); the real proof is
a native build + a real bootstrap.

New `platform/PgAdmin.java` (plain JDBC, CLI-owned constant identifiers, passwords masked,
never logged):
- `awaitReady(url, user, password, timeout, ctx)` — `Waiter.await` loop on
  `getConnection` + `select 1` (visible wait, last error shown).
- `ensureRole(conn, role, password)` — exists → `ALTER ROLE … PASSWORD` (converges a drifted
  role back to the recorded value on every rerun); missing → `CREATE ROLE … LOGIN PASSWORD`.
- `ensureDatabase(conn, database, owner)` — check-then-create, OWNER, REVOKE FROM PUBLIC;
  42P04/42710 benign.

### 3.2 PlatformModel
- `repoPath`: `case "oci-postgresql" -> "images/qits-oci-postgresql"` (default arm would
  silently clone `services/…` from GitHub).
- New `dockerfilePath(name)`: default `docker/Dockerfile`; `oci-postgresql -> Dockerfile`
  (root-level; `seedImage` currently hardcodes the docker/ path). `SeedDockerfile.read`
  rewrites the mirror FROM either way.
- `CORE` + `DEPLOYABLES` (right after observability); NOT PLATFORM_SERVICES, NOT SEEDED_REPOS.
- `PlatformModelTest`/`BootstrapPlanTest` updated.

### 3.3 Config
`BootstrapConfig.pgPort()` `@WithDefault("5433")` (`QITS_PG_PORT`) — host-published admin
port, `127.0.0.1`-bound like the registry port; 5433 avoids a host postgres collision.
In-network consumers keep 5432.

### 3.4 New phase `seed-postgres` (before idp-secrets/compose-file/pd-run-args/seed-stack)
Plus `seedImage("oci-postgresql")` in the build block. `seedPostgres()` in order:
1. Resolve `PG_SUPERUSER_PASSWORD` + `PG_DEPLOYMENTS_PASSWORD` given > kept > generated
   (mirrors idpSecrets; `randomSecret()`).
2. **Persist to `.qits-bootstrap.env` BEFORE starting the container** — `POSTGRES_PASSWORD`
   applies only at initdb of a fresh data dir; a password on the volume but not in the state
   file locks the next rerun out.
3. `ensureVolume("qits-oci-postgresql-data")`.
4. Start (skip if the alias already runs): `docker run -d --name <env>-qits-oci-postgresql
   --network qits-net -p 127.0.0.1:${PG_PORT}:5432 -v qits-oci-postgresql-data:/var/lib/postgresql
   -e POSTGRES_PASSWORD=<masked> qits/oci-postgresql:latest` — the randomized password applies
   from the very first boot; `qits-poc` never lives on the platform.
5. `PgAdmin.awaitReady("jdbc:postgresql://127.0.0.1:${PG_PORT}/postgres", …)`.
6. `ensureRole("qits_deployments", …)` + `ensureDatabase("qits_deployments", "qits_deployments")`
   via JDBC. Rerun-safe; reruns converge the role password to the recorded value.

### 3.5 ComposeTemplate + tokens + run-args (regenerate docker-compose.qits.yml in lockstep)
- Tokens: `PG_PORT`, `PG_SUPERUSER_PASSWORD`, `PG_DEPLOYMENTS_PASSWORD`.
- Volumes: drop `qits-deployments-data` (held only the H2); add `qits-oci-postgresql-data`
  with the pg-18 mount-path why-comment.
- New compose service `${ENV_NAME}-qits-oci-postgresql`: image `qits/oci-postgresql:latest`,
  container_name = wire alias, `127.0.0.1:${PG_PORT}:5432`, the volume, the password,
  healthcheck `pg_isready -U postgres`, `restart: unless-stopped`, qits-net, NO depends_on
  (compose-resurrection rule — deployer's refuse-to-boot + restart policy is the retry loop;
  seed-postgres ordering covers the cold path; comment says so). No observability URL (not an
  OTLP app; comment).
- Deployer compose block + run-args line: drop H2 URL + `-v qits-deployments-data:/data`; add
  `QITS_RESOURCE_DB_URL=jdbc:postgresql://${ENV_NAME}-qits-oci-postgresql:5432/qits_deployments`,
  `QITS_RESOURCE_DB_USERNAME=qits_deployments`, `QITS_RESOURCE_DB_PASSWORD=${PG_DEPLOYMENTS_PASSWORD}`,
  `QITS_ENVIRONMENT=${ENV_NAME}`,
  `QITS_PLATFORM_DEPLOYMENTS_POSTGRES_ADMIN_PASSWORD=${PG_SUPERUSER_PASSWORD}`; keep config
  volume + socket + group-add.
- New run-args line: `qits.platform.deployments.run-args.qits-oci-postgresql=
  -p 127.0.0.1:${PG_PORT}:5432 -v qits-oci-postgresql-data:/var/lib/postgresql
  -e POSTGRES_PASSWORD=${PG_SUPERUSER_PASSWORD}` (host publish kept so the CLI can reconnect
  after the deployer replaces the seed container; superuser password platform-wide until
  per-tier config exists — noted).
- `pdRunArgs`: `.mask()` both PG passwords.
- Seed-stack: before `compose up`, if the PG alias is present and not deployer-managed,
  remove it and let compose recreate from the same volume (the seed-artifacts precedent;
  initdb-only password semantics make the recreate safe).

### 3.6 Resulting phase order
… 7 seed-image-platform-artifacts · **8 seed-image-oci-postgresql** · 9 seed-artifacts ·
10-20 unchanged builds · **21 seed-postgres** · 22 idp-secrets (merge-preserving write) ·
23 compose-file · 24 pd-run-args · 25 seed-stack (deployer boots ON PG) · … · environment ·
deploy-observability · **deploy-oci-postgresql** · … · deploy-deployments (self-update; its
spec now carries `resources: postgresql:db` → no-op matrix row, stored credential injected).

The deploy-oci-postgresql cutover replaces the compose-seeded PG under the deployer's feet:
stop-before-start frees volume + host port; same volume mounts into the successor;
`pg_isready` gates; Agroal reconnects after the blip (Plan is plain values — no DB reads
during the docker window). Same self-referential class as the registry pulling before
stopping; note in the DEPLOYABLES ordering comment.

## WP-4 — superproject
Regenerated `docker-compose.qits.yml` in the same commit; `local-platform.md`/README notes
(toggle, PG port, where passwords live).

## Re-bootstrap runbook (the live platform's migration)

Preconditions: all repo changes merged and present in the wrapper checkouts; CLI rebuilt
native; `.qits-bootstrap.env` present (it is the credential continuity).

1. `qits unwrap --dry-run` — read the listing.
2. `qits unwrap --with-data-volumes` — removes containers/images/networks + `qits-*-data`
   volumes (+ `qits-maven-seed`); KEEPS `qits-deployments-config`, `.qits-bootstrap.env`,
   the checkouts, anything non-matching.
3. `qits bootstrap` — full cold boot (images gone → no `QITS_SKIP_BUILD`; hours of native
   builds).

Survives: idp secrets + push token (recorded state), run-args volume (rewritten anyway),
sources. Re-seeded: registry blobs + git repos (re-pushed from checkouts), CI history
(empty), topology/deployment history (fresh, IN PG), idp signing key (new — old tokens
invalid), postgres data dir (fresh initdb, recorded superuser password), the CLI-provisioned
roles/dbs (qits_deployments converged; qits_ci, qits_ci_eventstream, qits_platform_idp
create-only), and — after the sweep — EVERY service's database born fresh in PG: the seed
deployer provisions qits_projects, qits_epics, qits_workspaces, qits_workspaces_eventstream
and qits_events from their `resources:` lines during their deploy phases.
**Destroyed and not rebuilt: qits-projects/workspaces/events/stt application data (the old
H2 rows now have no reader anyway) and any artifacts content not from seeded repos (uploaded
packages, docs, CI screenshots) — the accepted cost of the re-bootstrap decision; enumerate
to the operator before step 2.**

## Verification

1. qits-deployments: `./mvnw clean verify` on a clone (embedded PG, no docker);
   `-Dnative` + `PdPackagedSurfaceIT`.
2. CLI: `./mvnw clean verify`; native package succeeds (pgjdbc-in-binary gate).
3. Scratch-machine bootstrap, then: `\l` shows `qits_deployments` owned by itself;
   `pd_resource` holds the self-registered row; deployer env carries the triple; PG data
   survives `docker restart` (volume-path proof).
4. Deploy a test app with `resources:`: role/db appear before the container; rerun → no-op;
   `docker volume rm` PG volume + redeploy → self-heal (same password); delete the row +
   redeploy → reconcile (rotated password, app healthy).
5. Operator `-e QITS_RESOURCE_DB_URL=…` in run-args wins.
6. `qits unwrap --with-data-volumes --dry-run` lists exactly the data volumes, keeps config.
7. Re-bootstrap with `QITS_SKIP_BUILD=1` reuses all recorded passwords (kept-precedence
   proof; PG comes up on the surviving volume).

## Risk register

| Risk | Mitigation |
|---|---|
| pgjdbc in the CLI native binary | Verify native build first in WP-3; documented fallback (plain driver + manual metadata); real bootstrap is the gate |
| POSTGRES_PASSWORD is initdb-only: surviving volume + lost .qits-bootstrap.env = locked out | Persist secrets BEFORE first start; recovery documented (single-user ALTER ROLE by hand, or data-volume reset) |
| Deployer-on-PG circularity: deploy-oci-postgresql briefly stops the deployer's own DB | Plan-as-plain-values → no DB reads in the docker window; cutover transaction after the gate; Agroal reconnects; crash-between = manual `docker start`, same sweep posture |
| Wrong volume path on pg-18 silently loses data | One template spells it in all three generated places; restart-survival check |
| Reconcile arm rotates a password and strands a recorded one | CLI-managed roles re-converge on rerun (ALTER-always); app roles have the registry row as single authority, no generated file carries them |
| Two repos claiming one database | `qits_` allowlist + registry cross-check → FAILED, never a silent no-op |
| Host-published PG admin port | 127.0.0.1-bound (registry-port posture); superuser password still required |
| Credential-bearing deployer DB + passwords visible in `docker inspect` env | Same trust domain as run-args config (already carries push token + idp secrets); documented |
| zonky 18.4 binaries / arch coverage | Explicit per-arch deps; 17.x fallback (tests only) |
| `unique nulls not distinct` needs PG ≥ 15 | Prod 18.4, embedded 18.x; noted in migration header |
| `resources:` key is forever | Accepted; documented in parser javadoc (deploy_branches lesson in advance) |

## Key files

- `services/qits-deployments/deployments/.../control/{DeploymentSpecParser,SpecSource,DeployService,ResourceProvisioner (new),ResourceProvisioning (new),BootResourceRegistration (new)}.java`
- `services/qits-deployments/environments/.../control/PdIdentifiers.java`; `environments/src/main/resources/db/platformdeployments/migration/` (fresh PG V1); `META-INF/microprofile-config.properties`
- `services/qits-deployments/service/.../dockerhost/DockerDeploymentDriver.java`; new `service/.../pghost/PgResourceProvisioner.java`; test fakes + EmbeddedPg
- `images/qits-oci-postgresql/{Dockerfile,README.md}`
- `cli/qits-cli-bootstrap/.../platform/{PlatformModel,ComposeTemplate,BootstrapState,PgAdmin (new)}.java`, `.../phases/{BootstrapPlan,SeedPhases,PipelinePhases,UnwrapPhases}.java`, `BootstrapConfig`
- `docker-compose.qits.yml` (regenerated)

## Amendments applied to qits-artifacts-postgresql-plan.md

1. §9.1 initdb script: DELETED — artifacts gets its role/db by declaring
   `resources: postgresql:db:qits_artifacts`; no per-service initdb, no
   QITS_PG_ARTIFACTS_PASSWORD on the image.
2. §9.2–9.4 (placeholder password, tuning, volume): landed by the prerequisite plan; the
   placeholder never lives (CLI randomizes from first boot).
3. §9.5–9.6: replaced — role/db appear automatically on the first deploy after artifacts'
   spec gains the resources line; ship that spec line AHEAD of the code cutover (env unused
   while on H2) so the migration tool has credentials before cutover day.
   PG_ARTIFACTS_PASSWORD moves from .qits-bootstrap.env to the pd_resource row (document the
   lookup query). Rotation = manual ALTER ROLE + row update, or the reconcile arm.
4. §9.8 backups: keep; dump `qits_deployments` too.
5. Intro naming + §8/§11: env convention becomes the generic contract — artifacts ships
   `quarkus.datasource.artifacts.jdbc.url=${QITS_RESOURCE_DB_URL}` (etc.) in its config
   defaults; run-args carry NO datasource env; §11's ADD-block deleted; the deployments.yml
   change becomes "add the resources: line".
6. §10 migration tool: QITS_MIGRATE_PG_PASSWORD sourced from the pd_resource row.
7. §12 runbook step C: run-args edit shrinks to dropping H2/blob env + volume; deployer
   restart still required.
8. §13 bootstrap: mostly subsumed by the prerequisite plan. Residue: `seedArtifactsStart`
   swaps H2/blobs env for the QITS_RESOURCE_DB_* triple, and seed-postgres's CLI provisioning
   list gains `qits_artifacts` (seed artifacts boots before the deployer exists → CLI-issued,
   recorded, rerun-converged credential like qits_deployments).
9. §7 zonky: the deployer repo carries the EmbeddedPg pattern first; copy from it.
10. Work packages: C1/C2 collapse to "landed via postgres-resource-provisioning-plan.md";
    C3 stays; F shrinks; CUT's dependency on C2 becomes a dependency on the prerequisite plan
    being live.
