# priority-feature: environments as first-class, cross-application entities — v2, DECIDED

Status: **LIVE since 2026-08-06 ~15:30 — the clean-start bootstrap completed on the
re-model.** All eleven applications healthy and pipeline-deployed (nine `dev` apps incl.
cd via its self-handoff, singletons idp + serviceregistry), zero compose leftovers, the
topology byte-for-byte the pinned design (per-app networks holding app + gateway hub +
both singletons; `qits-platform` singletons-only; `qits-net` the bundle; labels as
amended). The run surfaced five defects, all fixed live and recorded under "Debts";
three needed hand intervention (reflection hotfix + pipeline buildkit fix, health-path
seeding, three lost post-receive/build-event replays). One wire divergence on record:
the registry serializes `target` where the contract says `deploymentTarget` — cd's
tolerant reader accepts it; align in a follow-up. Remaining work: the debts below, the
parked phases, and the new `qits-cli-bootstrap` workstream (TUI bootstrap CLI replacing
the bash script; repo seeded separately). Supersedes v1 (git
history). Precedes the userflow work (handover.md). The "Current state" investigation
record from v1 still holds; only the pointers section is kept here.

## Decisions (user-confirmed)

1. **qits-cd reads `deployments.yml` from the git host itself** at the announced sha
   (cd grows its first outbound HTTP client). No change to the build-succeeded payload.
2. **qits-projects' `CdEnvironmentNotifier` is removed.** qits-cd owns environment and
   network creation. Environments are created over REST, deliberately.
3. **Singletons first cut: qits-idp and qits-cd.**
4. **Application registration is DERIVED, not declared over REST**: a green build on an
   environment's branch auto-registers/updates the application in that environment, shaped
   by the repo's `deployments.yml`.
5. **Branch convention `environment/<name>` cut over NOW**: dev deploys from
   `environment/dev`, not from `main`. `main` stays the integration trunk; the release
   flow fast-forwards `environment/dev` after releasing to `main`.
6. **Network topology: hub-and-spoke, from the get-go, via dual-home transition.**
   - Per (environment, application) network: the app's containers only.
   - Per environment **bundle** network: public nodes only (`available_on_env: true` —
     today just qits-gateway; single member, deliberately redundant, kept for cleanliness).
   - `available_on_env: true` ⇒ join the bundle **and every per-app network of the
     environment** (the hub); that is how apps reach the gateway and how the gateway
     proxies every app. All cross-application traffic is meant to flow app → gateway →
     target app's public API.
   - **Singletons join every per-app network of every environment** — they are *locally*
     reachable everywhere by design. idp and cd therefore never need gateway routes for
     intra-platform callers (revisit only if a second project arrives; then configuration
     grows, not the topology).
   - **Transition**: new containers additionally stay joined to legacy `qits-net` until
     every remaining direct cross-app URL (artifacts, events, observability, workspaces↔
     projects) has migrated to gateway routes; dropping the legacy membership is the
     enforcement flip, a later phase. This also keeps the bootstrap compose-takeover and
     the live migration safe.
7. **Rollout is GATED** (user, 2026-08-06): the qits-local-up.sh we branched from has known
   issues being fixed in a separate effort. Implementation and green builds proceed now;
   deploying to the local environment and merging wait for that fix. When it lands on the
   wrapper's `main`, merge/rebase this branch's `qits-local-up.sh` changes onto the fixed
   version before any bootstrap use, then run the sequenced rollout below.

Resolved minor points (from v1): lowercase enum values in the yaml; singletons deploy from
`main` (they are platform-plane, not env-tiered — override key exists); `QITS_ENVIRONMENT`
is not injected into singletons; singleton OTel `deployment.environment.name=platform`;
target flips environment↔singleton are handled by converting the existing rows (the live
migration needs exactly that once, for idp and cd).

### Post-review decisions (user, 2026-08-06, supersede where they conflict)

8. **qits-cd is NOT a singleton after all** — it is an ordinary environment application
   (each environment runs its own cd; the deployer rides the tier ladder like everything
   else). **The singletons are qits-idp and qits-serviceregistry** — idp deployed today,
   serviceregistry when its leg lands. Applied on the branch: cd's `deployments.yml`
   deleted, wrapper `SINGLETONS="idp"` (mirrors deployed reality; serviceregistry joins
   the list when it ships), docs corrected. Rollout consequence: only idp converts; cd's
   rows stay environment-scoped throughout.
9. **The cross-cutting domain extracts into a new service: `qits-serviceregistry`**
   (repo created: https://github.com/QuicklyIterateTheSoftware/qits-serviceregistry.git,
   empty — submodule added when the leg starts; note `git submodule add` fails on a
   born-empty remote, seed an initial commit first). See "Successor leg" below.
   Execution model settled: **shape 2** — the registry is socketless pure domain; a
   designated home cd executes platform-plane deployments (idp, the registry itself,
   seeding a cd into a new environment) as the registry's agent. Driver code exists only
   in qits-cd; the docker socket count does not grow.

## Pinned contracts (all agents build against these exactly)

### `.config/qits/deployments.yml` (parsed by qits-cd, strict: unknown/duplicate keys are errors)

```yaml
deployment_target: environment   # default when key or file absent | singleton
available_on_env: false          # default; true = public node (bundle + hub joins)
branch: main                     # singleton only: the branch that deploys it (default main)
```

- File absent or blob 404 ⇒ all defaults (environment target) — every repo without the
  file behaves exactly as today.
- Read via `GET <qits.cd.git-host-url>/git/<repoId>/blob/<sha>/.config/qits/deployments.yml`
  (`qits.cd.git-host-url` default `http://qits-artifacts:8080/artifacts` — same contract
  qits-ci uses; 404 ⇒ defaults; other failures ⇒ the deployment row FAILS with the error
  in `detail`, never guesses).
- `available_on_env: true` with `deployment_target: singleton` is a parse error (a
  singleton is already everywhere locally; the bundle is environment-scoped).

### qits-cd model

- `CdEnvironment(id, name unique, branch, network, createdAt)` — `network` is the
  **bundle** network name; per-app networks are derived, never persisted.
  New-environment convention: branch defaults to `environment/<name>` (replaces the dead
  `epic/` default), network defaults to `qits-env-<name>` as today.
- `CdApplication` (V4 migration): `environment_id` becomes nullable (null ⇔ singleton);
  new columns `deployment_target` (`ENVIRONMENT`|`SINGLETON`), `branch` (nullable, only
  singletons), `available_on_env` (boolean default false). Uniqueness: keep
  `(environment_id, name)`; singleton name uniqueness enforced in the service transaction
  (H2 has no partial unique index).
- **Derived registration** on build-succeeded `(repoId, branch, sha)`:
  read the spec at `sha`, then
  - target `environment`: for every `CdEnvironment` whose `branch` matches — ensure a
    `CdApplication(env, repoId, name=repoId, availableOnEnv from spec)` exists and is
    up to date; deploy into each.
  - target `singleton`: if `branch` matches the spec's branch (default `main`) — ensure
    the singleton row (converting any existing env-scoped rows for that repoId:
    decommission their active deployments' rows, remove the rows); deploy once.
  - No matching environment and not a matching singleton ⇒ 202, nothing (as today).
  - healthPath keeps the current default-derivation (`qits.cd.default-health-path`);
    existing rows keep their explicit healthPath.
- REST changes: `PATCH /cd/api/environments/{id}` body `{name?, branch?}` (rename/retarget,
  no docker side effects; validation as create). Environment create: `applications` list
  becomes optional-and-deprecated (bootstrap stops sending it). New
  `GET /cd/api/applications` (singletons + env apps flattened, for the registry view).
  Everything else unchanged.

### Networks, naming, labels

- Bundle network: `<env.network>` (dev: `qits-net`). Per-app network:
  `qits-env-<envName>-<appName>`. Singleton primary network: `qits-platform` (created on
  demand). Legacy/transition network: config `qits.cd.legacy-network` (default `qits-net`;
  empty disables the dual-home join — that flip is the enforcement moment).
- `docker run` primary `--network`: per-app network (env apps), `qits-platform`
  (singletons). After start, `docker network connect --alias <appName>` joins:
  - env app: legacy network (if configured).
  - `available_on_env: true` app: + its env's bundle + every existing per-app network of
    its environment.
  - singleton: + every per-app network of every environment + legacy network.
- Reconciliation (label-driven, docker is the runtime bookkeeping — H2 never stores
  membership): when a deploy creates a per-app network, connect the environment's hub
  containers (`label qits.cd.available-on-env=true` + matching env) and all singleton
  containers (`label qits.cd.target=singleton`) to it. Environment create makes the
  bundle; environment delete disconnects singletons, then removes its networks.
  Pre-deploy self-heal: before starting, compute desired networks and connect what is
  missing on the predecessor's replacement.
- Labels — containers: existing three id labels plus `qits.cd.target=environment|singleton`
  and `qits.cd.available-on-env=true|false`. Networks: `qits.cd.environment=<envId>`,
  `qits.cd.network=bundle|application`, and on app networks `qits.cd.app-name=<name>`.
  Adopting pre-existing unlabeled networks (`qits-net`) stays supported.
- Predecessor discovery (`aliasHolders`) searches the union of the container's desired
  networks INCLUDING the legacy network — that is what finds today's containers during
  the migration.
- Container names: env apps unchanged (`qits-cd-<env>-<app>-<id8>`); singletons
  `qits-cd-singleton-<app>-<id8>`. `QITS_ENVIRONMENT` injected for env apps only; OTel
  `deployment.environment.name` = env name, or `platform` for singletons.

### Branch convention and promotion

- dev environment row after migration: `{name: dev, branch: environment/dev, network: qits-net}`.
- qits-workspaces release: after the versioned merge commit lands on `main`, push the same
  commit to `environment/dev` (fast-forward; non-fast-forward is an error surfaced by the
  release, not forced). Integrate is untouched.
- Bootstrap: pushes `main` AND `environment/dev` (same sha) per repo; seeds
  `{name: dev, branch: environment/dev, network: qits-net}` with NO applications array;
  the 409 branch reconciles by PATCH (never delete-and-recreate).
- The direct-push escape hatch deploys by pushing `environment/dev` (with the push token —
  it is not the default ref, but keep using the token for uniformity); pushing only `main`
  builds but deploys nothing. Document this in local-platform.md.

## Implementation waves (Opus subagents, parallel)

Wave 1 — parallel, one agent per repo, all in the worktree
`/home/wohlben/code/qits-qits-userflow-tests/`:

- **qits-cd**: everything under "qits-cd model", "Networks, naming, labels", the git-host
  spec reader, V4 migration, PATCH endpoint, README/AGENTS updates, its own
  `.config/qits/deployments.yml` (`deployment_target: singleton`), tests.
- **qits-workspaces**: release fast-forwards `environment/dev`; tests; AGENTS note.
- **qits-projects**: remove `CdEnvironmentNotifier` + port + config + tests + doc refs.
- **qits-idp + qits-gateway** (one agent, two tiny commits): idp
  `deployments.yml` (`deployment_target: singleton`); gateway `deployments.yml`
  (`available_on_env: true`).
- **wrapper**: `qits-local-up.sh` (seed dev, both-ref pushes, PATCH reconcile, naming
  greps), `local-platform.md`.

Wave 2 — orchestrator: cross-review, green `mvn verify` everywhere, then the live rollout:

**REWRITTEN 2026-08-06 (late): the live-migration runbook above/below is RETIRED.** The
user's cold-bootstrap fix landed and proved a full from-scratch bring-up, and the user
chose a clean start over live migration. The old steps (decoupling-probe delete, PATCH
rename, conversion choreography) are moot on a wiped platform — the fresh bootstrap
comes up directly in the target model. Preserved for the record in git history.

The clean-start rollout:

1. Preconditions (all met before executing): wrapper `main` merged into `userflow-tests`
   (`d05611b` — both `${user.home}` fixes converged, release-replay + lost-event-replay
   preserved, replay gated to environment apps); the fix effort's submodule commits
   (qits-cd `8ef8a8f`, qits-ci `4439c4b`+`b698b99`) merged into the worktree checkouts
   the bootstrap seeds from; all repos' gates green.
2. Teardown (user-authorized clean start): cd-labeled containers, compose stack, ALL
   `qits-*` volumes, platform/seed/build images. `.qits-bootstrap.env` (idp client
   secrets) is a wrapper-dir file and is kept, as the fix effort's reset did.
3. Fresh bootstrap FROM THE WORKTREE (`/home/wohlben/code/qits-qits-userflow-tests`) —
   it seeds from local checkouts, so every re-model commit and the serviceregistry
   submodule ship without any push. ~22 min proven on the old model; this run is the
   first on the re-model script — watch it, do not fire-and-forget.
4. Verify the target model live: eleven applications healthy (serviceregistry among
   them, container `qits-cd-singleton-qits-serviceregistry-…`); environment `dev`
   (branch `environment/dev`, bundle `qits-net`) served by the registry through cd's
   proxy; per-app networks `qits-env-dev-<app>` labeled and populated; `qits-platform`
   carrying both singletons, joined across all app networks; gateway (available_on_env)
   on the bundle + every app network; idp answering token mints as before; the links
   query composing linked services + singletons; pins API up; qits-spa-cd rendering
   environments/deployments (hard-reload — index.html cache).
5. Prove the flow: a real change through release → `main` + `environment/dev`
   fast-forward → build → deploy ACTIVE; and a singleton path: an idp or registry push
   to `main` deploying once, platform-wide.
6. Update handoff.md and the memory; the parked phases (enforcement flip, URL migration,
   preprod, idp phase 2, userflows) stand.

### Debts surfaced by the first live run (follow-ups, user-confirmed direction)

- **Pipelines must be buildkit-compatible** (the platform targets buildkit — a swarm
  cannot assume the legacy builder). qits-cd's and every SPA-serving service's
  `ci-post-receive.yml` does `docker build --network qits-net`, which only works because
  `node-docker-base`'s older CLI falls back to the legacy builder. serviceregistry's
  pipeline shows the corrected shape (`e4e42ab`): `--network host` +
  `QITS_MAVEN_REPOSITORY_URL` derived from `$QITS_REGISTRY`. Migrate the others the same
  way.
- **Health-path convention**: derived registration has no source for per-app health
  paths (the old bootstrap's applications array carried them). The live run needed
  hand-PUTs into the registry. Durable fix: cd derives `/<name-sans-qits->/q/health/ready`
  as the registration default, with an optional `health_path` spec key for exceptions
  (gateway: `/q/health/ready`).
- **Registration failure with no rows is silent** (deviation 5's ordering hole): the
  registry answering 500 on the first-ever registration produced no FAILED row and no
  monitor signal — an hour-long stall. cd should record the failure somewhere loud.
- **The script's docker-based singleton liveness** counts a `running/unhealthy`
  container as live (idp declared live, then rolled back). Needs a cd API that exposes
  singleton deployments, or a health-state check in the grep.
- **A failed singleton cutover of idp takes the token plane down with it** for the
  stop-to-rollback window; anything announcing in that window (post-receive → ci) is
  lost fire-and-forget. stt's run had to be replayed by hand. Worth a retry on the
  announce path or a health-gated stop order for idp specifically.

Parked (explicitly out of this effort): the enforcement flip (`qits.cd.legacy-network=`
empty) and the cross-app URL migration to gateway routes it requires; preprod/prod
creation; per-environment run-args/ports/volumes ("second environment readiness");
qits-idp phase-2 users + environment claims; qits-dns wiring; the userflow workstream;
the qits-serviceregistry extraction (successor leg below).

## Successor leg: qits-serviceregistry (planned, paired with second-environment readiness)

Repo: https://github.com/QuicklyIterateTheSoftware/qits-serviceregistry.git (created,
empty; will live at `services/qits-serviceregistry`). Not part of the gated rollout —
with one environment, "the registry lives in dev's cd" and "the registry lives in
qits-serviceregistry" are functionally identical; the extraction pays when environment #2
arrives, so it lands in the same leg.

The shape (decision 9, execution model settled on shape 2):

- **Domain**: the environment/application topology. Every service is an entity with N
  environment-links; "singleton" stops being a special deployment target and becomes a
  linkage pattern (idp = linked into every environment; qits-ci = one link per
  environment). Environment CRUD (create/PATCH/list, the registry `GET`s) moves here from
  qits-cd. Consumers: cds ("what must be linked into my environment"), qits-idp phase 2
  (per-environment grants), future qits-dns wiring, the userflow workstream's
  by-environment execution profiles, the explorer SPAs.
- **The registry is itself the second singleton**: one instance, linked into every
  environment (each cd must reach it to ask what links its environment). Its own
  `deployments.yml` will say `deployment_target: singleton`.
- **Execution stays in qits-cd, exclusively.** The registry is socketless pure domain. A
  designated **home cd** executes platform-plane deployments (idp, the registry itself,
  seeding a cd into a newly created environment) as the registry's agent. Driver code
  exists in one codebase; the root-equivalent docker socket count does not grow.
- **Reconciliation is pull-based and label-driven** (already true after this leg's
  implementation): a cd asks the registry what links its environment, compares against
  docker labels — the shared runtime truth — and connects what is missing. No push
  channel, no stored membership.
- **qits-cd's domain reduces** to deployments in its own environment: the environment
  and application registry entities move out; the deployment rows, the driver, the spec
  parser and derived-registration mechanics stay (registration then writes to the
  registry instead of local rows — the seam the current implementation already isolates).
- Cross-context rule holds: no FK between cd's deployment rows and registry entities —
  names/ids as plain strings, exactly as `ci_run.repo_id` does it.

### Registry leg — pinned implementation contracts (pulled forward 2026-08-06, user ask)

The extraction is implemented NOW (not deferred to second-env readiness). Rollout order
extends the runbook: (a) current cd re-model deploys as planned (it still owns rows);
(b) serviceregistry deploys via the new cd as a singleton from `main`; (c) cd v2 (the
extraction) deploys, exporting its rows into the registry on first boot.

**The service** (repo `qits-serviceregistry`, GitHub org QuicklyIterateTheSoftware; local
clone seeded and pushed to GitHub `main` — GitHub ships nothing, so the rollout gate is
untouched):

- Mirrors qits-cd's shape: modules `serviceregistry/` (domain, framework-free) +
  `service/` (JAX-RS), packages `eu.wohlben.qits.serviceregistry.*`, artifactIds
  `qits-serviceregistry-domain` / `qits-serviceregistry-service`, parentless poms,
  clone-alone. `quarkus.rest.path=/serviceregistry/api`, health
  `/serviceregistry/q/health/ready`, alias `qits-serviceregistry:8080`, own H2 file
  datasource `serviceregistry`, Flyway V1, the platform OTel/log block +
  `OtelLogConfigTest`, OpenAPI export test, Dockerfile + `.config/qits/ci-post-receive.yml`
  modeled on qits-cd's, `deployments.yml` = `deployment_target: singleton`. NO docker
  socket, NO SPA, no outbound HTTP clients.
- Entities: `RegEnvironment(id, name unique, branch, network, createdAt)`;
  `RegService(id, name unique, deploymentTarget, branch nullable, availableOnEnv,
  healthPath nullable, createdAt)`; `RegServiceLink(service FK, environment FK,
  createdAt, unique(service, environment))`. Singletons have NO links — implicitly
  linked everywhere, which is what makes new environments pick them up.
- API: environments CRUD (`POST/GET/GET{id}/PATCH/DELETE /serviceregistry/api/environments`,
  same validation vocabulary as cd — dns-label names, 409 on name, PATCH {name?, branch?};
  delete = rows only, no docker anywhere); `PUT /serviceregistry/api/services/{name}`
  (upsert from cd: {deploymentTarget, branch?, availableOnEnv, healthPath?,
  environmentIds[]} — replaces the link set for environment-target services);
  `GET /serviceregistry/api/services` (flattened, with links);
  `GET /serviceregistry/api/environments/{id}/links` (the cd pull query: linked services
  + every singleton, with availableOnEnv). Auth mirrors cd: forward-auth for humans,
  `MachineAuth` on the writes (audience `qits-serviceregistry`), gate ships false.

**cd v2 (extraction)** — on top of the existing branch commits:

- New port `RegistryClient` in `cd/control`, `java.net.http` impl in `service/`
  (`qits.cd.registry-url`, default `http://qits-serviceregistry:8080`). Tests stub the
  registry HTTP (StubGitHost pattern) — no compile dependency between the repos, the
  wire contract above is the interface.
- Registry is the system of record for environments/services. cd's environment
  endpoints STAY as the operational surface (shape 2's agent door): create proxies to
  the registry then ensures the network; PATCH proxies; delete tears down docker FIRST
  (existing label-driven teardown, legacy-network guard intact) then deletes in the
  registry. Reads proxy through. The bootstrap and qits-spa-cd keep working unchanged.
- Derived registration writes services/links to the registry; deploy resolution queries
  it (branch match, links, singleton set). Registry unreachable at deploy time ⇒ FAILED
  rows with the cause (same posture as spec reads). Boot does not require the registry.
- One-time export: at startup, if the registry answers and is EMPTY and local
  environment/application rows exist, cd upserts them (idempotent); local
  `cd_environment`/`cd_application` tables are no longer read or written after
  extraction but are NOT dropped this leg (a later cleanup migration, post-rollout).
  `cd_deployment` decouples from the FK: V5 adds plain `application_name` +
  `environment_id` (nullable) columns backfilled from the join; `sweepInFlight`'s
  QUEUED/STARTING adoption contract survives unchanged.

**Wrapper/bootstrap**: submodule add at `services/qits-serviceregistry` (CLAUDE.md
procedure, `--name`, after GitHub has the seed commit); `SINGLETONS="idp serviceregistry"`;
serviceregistry joins `DEPLOYABLES` (ordered after idp, before the rest) and the compose
`CORE` seed (cd needs it reachable for environment ops); run-args
(`qits-serviceregistry-data` volume, datasource env); idp grants gain the
`qits-serviceregistry` audience for the `qits-cd` client. qits-spa-cd and qits-gateway:
untouched this leg (cd proxies reads; a direct gateway route is a later nicety).

## v3 (2026-08-06 late, user decisions): qits-platform-deployments — the merge-back

The cd/serviceregistry split was the wrong boundary: the executor was always
cross-environment in behavior (one socket, fan-out over every matching environment) while
labeled as an environment citizen, and the extracted registry was the passive half. The
correction: **one platform component owning both** — environment management AND deploying
services into environments — named **qits-platform-deployments**
(repo https://github.com/QuicklyIterateTheSoftware/qits-platform-deployments.git, seeded
by hoisting qits-cd's code merged with qits-serviceregistry's domain, RE-PARTITIONED
properly). qits-cd and qits-serviceregistry are superseded; their repos remain until the
cutover completes.

**Platform services** (cross-environment, deploy from `main`, the singleton machinery —
vocabulary migrating `singleton` → `platform`): qits-platform-deployments, qits-idp,
qits-artifacts, qits-ci, qits-events, qits-projects (bundles deployments/builds),
qits-observability. **Environment services**: qits-workspaces ("ultimately the only
non-platform service" — user), qits-gateway as each environment's hub
(available_on_env). qits-stt: unclassified, stays environment-target pending a call.
Deployment triggering: the target model is bus-driven (qits-ci's SoftwareRelease /
BuildSuccessful events); the direct build-succeeded HTTP intake stays as the
transitional and manual door.

Hoist contracts (wave 1): package `eu.wohlben.qits.platformdeployments`; REST path
`/platform-deployments/api`; module partition `environments/` (topology domain:
environments, services, links, networks), `deployments/` (execution domain: deployment
rows, driver, run-args, pins), `service/` (API, bus, docker adapter, webui);
ONE fresh Flyway V1 on datasource `platformdeployments` (clean-start world — no lineage
inheritance); config namespace `qits.pd.*`; container prefix `qits-pd-`; docker labels
`qits.pd.*`; spec parser accepts `deployment_target: platform` as canonical with
`singleton` as an accepted alias; audience `qits-platform-deployments`. The webui stays
the qits-spa-cd submodule, served under `/platform-deployments` (its baseHref change is a
wave-2 commit in that repo).

**v3 addendum (user, same day): the `platform/*` branch pattern.** Platform services do
NOT deploy from `main` — `main` stays the trunk everywhere. Mirroring `environment/<name>`,
the platform scope's conventional deploy branch is **`platform/main`** (the `*` slot
deliberately open for a future staged platform plane;
`DeploymentSpec.DEFAULT_PLATFORM_BRANCH`, spec `branch:` overrides). Releases fast-forward
BOTH `environment/dev` and `platform/main` (spec-aware promotion selection is a recorded
debt, the double CI build the accepted cost); the CLI pushes platform services with deploy
ref `platform/main`, quiet ref `main`.

**v3 addendum 2 (user, same day): platform is a NAMESPACE QUALIFIER**, not a compound —
java package `eu.wohlben.qits.platform.deployments`, config namespace
`qits.platform.deployments.*` (env `QITS_PLATFORM_DEPLOYMENTS_*`, incl. the run-args
family and qits-ci's `qits.platform.deployments.intake-url`). The `qits.pd.*` spelling in
the wave-1 contracts above is superseded. Kept as abbreviations by explicit decision:
the `Pd` java class prefix, the `qits-pd-` container-name prefix (docker names carry no
dots), artifactIds, the `/platform-deployments` URL segment, and the `platformdeployments`
datasource name. The qits-spa-cd repo is REUSED as the webui (no new repo); its rename is
cosmetic debt.

Wave 2 (after the hoist lands): CLI/bootstrap cutover (PlatformModel lists, compose CORE,
run-args family, api paths), qits-ci's notify target, gateway route, idp audience wiring,
retiring cd/serviceregistry from the deploy sets. Rollout stays the clean-start path.

## Contract amendments (accepted from implementation, 2026-08-06)

1. `qits.cd.app-name` is a container label too — reconciliation needs the alias name when
   connecting a running container to a new network.
2. `qits.cd.network` has a third value `platform` (on `qits-platform`).
3. Singleton containers carry NO `qits.cd.environment` label — environment deletion reaps
   by that label and must never take a platform-plane container.
4. Singleton conversion MOVES deployment history onto the singleton row (actives
   decommissioned); deleting rows would destroy an in-flight self-update `STARTING` row.
5. Spec-read failure with no registered rows ⇒ 202 nothing (no row exists to fail);
   registered rows each get a FAILED row with the cause.
6. `qits.cd.legacy-network` injects as `Optional<String>` (empty env value = absent —
   the enforcement flip's own spelling).
7. Derived registration means a green build on an environment's branch auto-registers the
   repo there — imageless repos record `IMAGE_MISSING` rows if pushed to a deploy branch.
   ROLLOUT CONSEQUENCE: PATCH the environment to `environment/dev` immediately after the
   new cd is live, or main-branch release-train pushes register junk into the `main`-
   tracking row.
8. `branch:` beside `deployment_target: environment` is accepted and ignored (not a fifth
   parse error).
9. Workspaces: a failed promotion is partial success (200 + `promotionError`, ERROR log),
   never an unwound release. Off switch = empty `qits.workspaces.release.environment-branch`.
10. Bootstrap: the non-deploying ref is pushed with `-o qits.no-ci` (real, tested git-host
    option); singletons hand-post `branch: main`; singleton liveness is watched via docker
    because `GET /cd/api/deployments` requires an environmentId singleton rows lack.
11. `PATCH /cd/api/environments/{id}` does not rename the bundle network (dev keeps
    `qits-net` by design).
12. Target flips are asymmetric (review outcome): environment→singleton converts (the
    migration's one-time need); singleton→environment is REJECTED loudly (FAILED row on
    the singleton naming the flip) — explicit remediation, never a silent double-run.
13. Predecessor discovery is environment-aware (review finding 2): a holder labeled with
    a different environment id is never a predecessor; unlabeled holders (compose/old-cd)
    stay adoptable. Environment delete never disconnects from or removes the configured
    legacy network. A real join failure fails the deployment; only "already connected" is
    benign. Singleton registration is serialized (one row per repoId under concurrency).

## Hazards (unchanged from v1, still binding)

- Environment DELETE tears down containers by label — the migration path is PATCH, never
  delete (memories: local-up recreate landmine, qits project delete blast radius).
- run-args are cached at cd boot; config-volume changes need a cd restart before the
  affected app redeploys.
- cd's self-update handoff: schema/model changes must not disturb `sweepInFlight`'s
  QUEUED/STARTING adoption contract.
- Release a self-hosting repo only with the CI queue drained; a run row must appear after
  every push (replay the post-receive event if not).
- The bootstrap greps cd's container naming — wrapper and cd changes land together.

## Investigation pointers (from v1)

- `services/qits-cd/cd/…/entity/*.java`, `…/control/EnvironmentService.java:40-125`,
  `…/control/DeployService.java:74,162,212-391`,
  `service/…/dockerhost/DockerDeploymentDriver.java:107,148,241,366,404-466`,
  migrations `V1-V3`.
- `services/qits-projects/service/…/notify/CdEnvironmentNotifier.java` (to remove);
  seam `domain/…/control/ProjectEnvironmentNotifier.java`.
- `qits-local-up.sh:135,159,704-764,780,896-930`.
- Blockers catalogue for env #2 and the one-per-daemon reaps: v1 §"Why a second
  environment cannot run today" (git history of this file).
