# Byte-plane split plan

Decided 2026-08-10. Goal: `qits-platform-artifacts` is platform-scoped only
because it holds the pull-through caches. Split those out into their own
platform service; everything else returns to env scope.

## Settled decisions

- **`qits-platform-mirror`** — new platform service, the only platform-scoped
  byte service. Holds the pull-through caches: `NPM_PROXY` (npmjs),
  `MAVEN_PROXY` (Maven Central), `OCI_MIRROR` (Docker Hub etc.), their
  upstream config, and the access-tracked eviction GC.
- **Two-endpoint topology.** Clients address the mirror directly for
  third-party content; `qits-artifacts` keeps zero proxy code.
  - npm: scoped registries — `@qits` scope → env `qits-artifacts`,
    default registry → mirror.
  - docker: `registry-mirrors` in dockerd config → mirror; qits images pull
    from the env registry by name.
  - maven: repositories list carries both endpoints.
- **`qits-githost`** — new env service. The git smart-HTTP host moves out of
  artifacts entirely: it is not an artifact, it only shares the storage
  layout. Its consumers (`qits-ci`, `qits-deployments`, `qits-workspaces`,
  the daemons, workspace containers) are all env services already; an
  env-scoped git host is the consistent shape. The `git-storage` module moves
  into this repo — no lib needed, nothing else uses it. The name
  `qits-repositories` stays off the table (taken, and collides with
  `domain.repository`).
- **`qits-platform-artifacts` → `qits-artifacts`** — env service again.
  Keeps: hosted npm/maven/oci registries, docs bundles, pin-based GC.
- **`qits-platform-docs` → `qits-docs`** — env service. It was only
  platform-scoped because artifacts was; it reads bundles from its own env's
  `qits-artifacts`.
- **Two lib repos:**
  - `libs/qits-blobstore` — the content-addressed SHA-256 blob store:
    entities, persistence, blob control (disk index, census, reclaim).
  - `libs/qits-registries` — the protocol code, one maven module per format
    (`npm`, `maven`, `oci`), each holding both hosted and proxy sides;
    each service wires only the repository types it owns.
- `frontends/qits-platform-spa-artifacts` → `qits-spa-artifacts`; the mirror
  gets its own admin UI (the upstream/cache views move there).

## New and renamed repositories

| Action | Repository | Role |
|---|---|---|
| new | `libs/qits-blobstore` | shared lib |
| new | `libs/qits-registries` | shared lib |
| new | `services/qits-platform-mirror` | platform service |
| new | `services/qits-githost` | env service |
| rename | `qits-platform-artifacts` → `services/qits-artifacts` | env service |
| rename | `qits-platform-docs` → `services/qits-docs` | env service |
| rename | `qits-platform-spa-artifacts` → `frontends/qits-spa-artifacts` | frontend |
| rename | `qits-platform-spa-docs` → `frontends/qits-spa-docs` | frontend |

## Phases

1. **Extract the libs** (additive — no platform change), in two steps:
   1. Prove the carve: copy the blob store and the format code out of
      `qits-platform-artifacts` into two standalone projects
      (`extraction/`); both build and test green. This yields the
      class-by-module manifest.
   2. Extract **with history**: per lib repo, clone
      `qits-platform-artifacts` and run `git filter-repo` with a paths file
      built from the manifest — per-file renames into the target layout, so
      each `qits-registries` maven module (`npm`/`maven`/`oci`) carries the
      real history of its files. Graft onto the seeded GitHub repo, add one
      scaffolding commit (poms, mvnw), verify the tree matches the proven
      `extraction/` tree and builds green.

   Package names stay as-is to keep the later service diffs small. Libs
   carry **no Flyway migrations**: each service owns its schema.
   `qits-platform-mirror` starts a fresh V1; `qits-artifacts` keeps its
   existing migration chain untouched.
2. **Build `qits-platform-mirror`** on the libs: proxy/mirror repository
   types, upstreams, access tracker, eviction GC, admin UI.
3. **Build `qits-githost`**: `git-storage` module + the DFS storage adapters
   and githost packages from `service/`. It also replaces the post-receive
   HTTP fan-out with durable domain events (decided 2026-08-10): a
   `githost-events` module publishes `SCMPublishCommit` (per updated branch
   ref, head-commit metadata: parents, author, timestamps, message, plus
   `suppressCi` absorbing `-o qits.no-ci`), `SCMPublishTag` (new — tags
   never left the git host before), and `SCMDeleteBranch`/`SCMDeleteTag`.
   Consumers migrate: qits-ci drops `/ci/api/events/post-receive` for a
   durable listener (retires the replay trick and the in-memory-retry loss
   window), qits-projects gains the `qits-eventstream` dependency + DB
   resource for its backup-push trigger, the gateway retires the
   `/ci/api/events/` public-path exemption. Verified 2026-08-10: qits-ci
   keeps no local checkouts anymore (pipeline config is an HTTP read; the
   only clone is inside the step container), so the events replace the
   notifier, not a mirror.
   Added 2026-08-10 (new eventstream features, user ask): the githost reads
   `X-Qits-Causation-Id` off incoming pushes (Vert.x path — the JAX-RS
   filter cannot) and publishes the SCM events under that cause, so
   release → push → commit event → CI run → deploy is one causation chain.
   Producers must stamp the header on their receive-pack requests:
   qits-workspaces and qits-projects pushes (JGit allows extra HTTP
   headers) — part of the consumer/producer migration workstream, along
   with extending qits-ci's `EventWireReflection` with the SCM records
   when its listener lands. Every service publishing or consuming the new
   records needs them in a `bus/EventWireReflection` for native.
4. **Slim `qits-artifacts`**: consume the libs, delete proxy and githost
   code, keep hosted types + docs + pin GC. Rename lands here. The
   open-registration refactor (landed in the libs 2026-08-10) requires this
   service to contribute `DAEMON_BINARIES` and `DOCS` profile beans and to
   resolve request-body type strings via `RepositoryTypeProfiles`
   (`@JsonCreator` on the enum is gone).
5. **Cutover.** Client config (npm scoped registries, dockerd
   `registry-mirrors`, maven settings, `QITS_MAVEN_REGISTRY_URL` wiring),
   bootstrap seed (the mirror is a core service — it must listen before the
   first CI build pulls a third-party dependency), wire names, post-receive
   endpoints, then the renames and `qits-docs`.

## Repo state

The four new GitHub repos exist (created 2026-08-10, seeded). The parallel
rebootstrap finished successfully the same day. Endgame (user directive):
when all phases are ready, merge `main` on every touched repository —
qits-platform-artifacts (slimmed), qits-ci, qits-projects, qits-gateway
(event migrations), the wrapper (submodules, seed, config) — then
rebootstrap to ship the split. The GitHub renames are DONE (user,
2026-08-10, after the bootstrap finished) — four of them, since qits-docs
has a backend and a SPA: qits-artifacts, qits-docs, qits-spa-artifacts,
qits-spa-docs — redirects cover old URLs. The platform-side rename
(repo rows, wrapper gitmodules/paths, wire names) still happens at
cutover. The final
rebootstrap must NOT delete the config volumes — they hold git and
agent-harness credentials the user does not want to re-enter.

## Cutover mechanics (recon 2026-08-10, file:line refs verified then)

- Scope is ONE key: `deployment_target` in `.config/qits/deployments.yml`
  (parser `DeploymentSpecParser.java:78`, default environment). Wire name is
  derived: platform = bare repo name, environment = `<env>-<repo>`
  (`PdNetworks.alias`, `DeployService.java:615/535`). The name IS the
  repository — no separate naming field.
- **Platform→environment is a hard 409** (`ServiceCatalog.java:148-160`):
  delete the pd service rows for qits-platform-artifacts and
  qits-platform-docs ("retire deliberately"), then push the env spec.
- Repo rows reconcile from the wrapper's `.gitmodules` on every
  qits-projects boot (`SelfSeedService`, `WrapperReconcileService`) — a repo
  joins qits by joining the wrapper. Git-host bare repos are created by the
  bootstrap (`PipelinePhases.gitRepositories`, PUT per
  `PlatformModel.platformRepos()`).
- Bootstrap CLI is hardcoded Java lists (`PlatformModel`: CORE,
  DEPLOYABLES, PLATFORM_SERVICES, SEEDED_REPOS, RELEASE_PUBLISHERS;
  `BootstrapPlan` orders phases; pivot = `seedArtifactsStart`). The dns
  addition (`090199d`) is the template for adding a service.
- Landmines: `QitsClaims.ARTIFACTS` is a compiled constant in the published
  qits-auth-core lib; `WrapperDir.MARKER_DIR =
  "services/qits-platform-artifacts"` is wrapper detection;
  qits-workspaces ships dead default `qits.artifacts.url=http://qits-artifacts:8080`
  that goes live-and-wrong when the name returns; `/v2` is claimed by the
  gateway's ARTIFACTS entry — the mirror gets a host-published port
  instead of a gateway identity (dockerd cannot use qits-net DNS anyway).

## Cutover sequence

5a — remaining dev, on branches (in flight):
1. Specs + CI pipelines for qits-platform-mirror (platform, core,
   `resources: postgresql:db`, host publish for third-party clients) and
   qits-githost (environment, core).
2. Bootstrap CLI rewiring: both new services in the lists/phases/templates,
   seed registries split (hosted → env artifacts, third-party → mirror,
   git → githost), `SeedDockerfile` rewrite target → mirror,
   WrapperDir marker accepting both spellings, renames throughout.
3. qits-docs env-scoping (spec, `/docs` segment move, gateway enum,
   artifacts-url → env artifacts) + workspaces dead-default fix +
   QitsClaims decision.

5a addenda (from the CLI rewiring, 2026-08-10):
- Gateway needs a GITHOST entry (segment `git`, session-free passage
  replicating what /artifacts/git had, excluded from nav) + run-args key —
  in flight; the CLI's run-args gain the key once the gateway names it.
- After the libs release calver (5b step 2), bump the consumer pom
  properties (mirror: qits.blobstore.version/qits.registries.version;
  qits-ci: qits.githost-events.version; artifacts likewise) and land those
  bumps before their pipelines run. The seed's maven-seed phase deploys
  the SNAPSHOT jars into the temporary nginx registry, so the BOOTSTRAP
  works either way; the CI pipelines are what need the calvers.
- Seed image tags are `qits/<short-name>:latest` (qits/platform-mirror,
  qits/githost); CI-published names are `qits/qits-platform-mirror` etc. —
  different namespaces, both correct.
- The old stale-RED-run replay door (CiApi.postReceive) is gone with the
  intake; durable listeners + catch-up make the loss scenario it healed
  structurally impossible, so the trick retires with it.

5b — live execution, in order:
1. Merge every branch to main: the four new repos are already on main;
   byte-plane-split branches in ci / projects / workspaces / gateway /
   spa-artifacts / docs / cli-bootstrap; worktree-byte-plane-split in
   artifacts; then the wrapper commit (four new submodules, four renamed
   entries, stale empty `services/qits-artifacts/` dir removed, plan doc).
2. Release the libs + githost-events to the platform maven registry
   (calver) before anything builds against them on-platform.
3. Retire the pd service rows: qits-platform-artifacts, qits-platform-docs.
4. Rebootstrap preserving config volumes. The githost "data move" IS the
   bootstrap: it re-pushes every repo from local mains and replays
   releases; mirror caches start cold and warm up. Host-side printed
   steps: dockerd `registry-mirrors` → the mirror's published port.
5. Post-cutover cleanup: V7's three oci-mirror rows (data step), SPA
   package.json/README renames if not merged, mirror admin UI phase.

## Hazards

- Route prefixes are literals in `qits-registries` (`/artifacts/npm`,
  `/artifacts/maven`, `/v2`), so the mirror answers the same paths as
  `qits-artifacts`. The two-endpoint topology must split at the gateway:
  the mirror gets its own entry/host, clients pick by config, no shared
  prefix routing.
- The mirror has no deployment spec yet; it needs `resources:
  postgresql:db` declared (its `QITS_RESOURCE_DB_*` triple refuses to boot
  without values).
- Migrating the live git host is a DATA move: repositories are rows in
  `git_pack`/`git_pack_file` plus blobs in the artifacts store. The
  githost's V1 creates empty tables; nothing copies them yet. The cutover
  must move (or re-push) every repository before the old host goes away.
- The new libs are only in `~/.m2`; before CI can build the slimmed
  qits-artifacts on the platform, qits-blobstore and qits-registries must
  be registered repos with released jars in the platform maven registry —
  bootstrap/cutover ordering.
- Repo renames on the live platform: a repo DELETE pushes a wrapper commit
  removing the submodule — sequence create-before-delete, and expect the
  wrapper rewrite.
- Bootstrap ordering: mirror before CI; githost before anything that clones.
- The mirror builds itself through whatever registry CI is configured with —
  its own first deploy cannot depend on itself.
- GC carve: eviction strategies (proxy types) → mirror; pin-based
  (hosted types) → `qits-artifacts`; pack handling → `qits-githost`.
- The `gc` module's split is not designed yet — do it in phase 2/4, not 1.
- `RepositoryType` sits in `qits-blobstore` after extraction (it is the blob
  core's validation profile, and `CI_*` types are not registry formats), but
  as a closed enum it forces a core release per new format. Phase 2: replace
  it with open registration — opaque type key + profile interface in
  blobstore, `CI_*` as built-ins, each registries module contributing its
  own types.
- Stale empty dir tree `services/qits-artifacts/` sits in the wrapper
  checkout — remove it when the rename lands so it cannot shadow the real
  submodule path.

## Where the work lives

Phase 1 runs on branch `worktree-byte-plane-split` of
`qits-platform-artifacts` (worktree under
`services/qits-platform-artifacts/.claude/worktrees/byte-plane-split`), with
the lib projects as `extraction/qits-blobstore/` and
`extraction/qits-registries/` on that branch until the real repos exist.
