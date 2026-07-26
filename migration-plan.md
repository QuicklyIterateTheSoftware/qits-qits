# qits monolith → submodules: migration plan

Status: **assignment agreed, extraction not started.**
Source of truth for the split. Written 2026-07-26.

## 1. Purpose and scope

> ### Invariant: the monolith is not modified.
>
> This is a **parallel build-up**, not a teardown. `../qits` is treated as read-only
> throughout: no file is deleted from it, no module is dropped from its reactor, and
> it keeps building and running unchanged for the entire migration. Every assignment
> below is a **copy** — the monolith retains its copy of everything.
>
> This is already the established precedent, not a new rule. `WorkspaceService.java`,
> `domain/workspace/**` and `workspace-daemon-protocol/**` exist today in *both*
> `../qits` and their submodules, and `../qits/pom.xml` still lists all 14 modules.
>
> "Extraction" here means *history replay into a new repo*, which operates on a clone
> (§8 step 1). Nothing writes to `../qits`. Decommissioning the monolith's copies is
> out of scope and happens later, per context, once a service is live behind the
> gateway.

`../qits` is the Quarkus/Maven monolith being rearchitected into one deployable per
submodule of this repo. Three extractions have already landed ad hoc. This document
fixes the assignment *before* the remaining ones start:

- every tracked file under `../qits` is mapped to the target that should carry a copy
  of it (or to several, or to none — see `monolith-only.txt`);
- the mechanics of the next step — replaying each file's git history into its target
  repo — are written down once.

**In scope:** the 926 tracked files under `domain/`, `service/` (minus `webui/`),
`artifacts/`, `epics/`, `ci/`, `auth/`, `cli/`, `workspace-daemon*/`, `userflows/`,
`qits-userflows/`.

**Out of scope:** `service/src/main/webui/**` (673 files) and the app shell. The
frontend will be redone as per-service Lit web components; until then it stays in
`../qits`. Also out of scope for now: `domain.featureflow`.

Machine-readable per-target file lists live in [`migration-manifests/`](migration-manifests/),
one `<target>.txt` per section below, `path<TAB>reason`. They are the input to
`git filter-repo --paths-from-file` in §8.

## 2. Target topology

"Files" = how many monolith files this target receives a **copy** of. The columns do
not sum to a partition of the monolith — the monolith keeps all 926.

| Submodule | Bounded context | Status | Files copied |
|---|---|---|---|
| `services/qits-gateway` | Edge reverse proxy, service registry | **done** | — |
| `services/qits-projects` | Project, repository, epics/planning | empty | 225 |
| `services/qits-workspaces` | Host side of workspaces, containers, dev services | **partial** (84 copied) | 210 |
| `daemons/qits-workspace-daemon` | In-container daemon **+ agents + commands** | **partial** (55 copied) | 104 new |
| `services/qits-artifacts` | Blob store + git smart-HTTP host | empty | 45 |
| `services/qits-ci` | In-repo pipelines | empty | 41 |
| `services/qits-observability` | Telemetry / OTLP | empty | 32 |
| `services/qits-stt` | Speech-to-text | empty | 6 |
| `services/qits-cd` | Live deployment | **reserved** — nothing maps yet | 0 |
| `libs/qits-userflows` | Playwright story framework | **done** | — |
| `integrations/qits-integrations-angular` | `@qits/angular` | **done** | — |
| `integrations/qits-integrations-quarkus` | *(unstarted, no monolith source)* | empty | 0 |
| ~~`services/qits-repositories`~~ | **dropped** — name collides with `domain.repository` | — | — |
| *(no target)* | webui, app shell, featureflow, product userflows | monolith-only | 0 |
| *unassigned* | `auth/*`, `domain.setting`, `cli/` | open question | 55 |
| *duplicated* | error types, validation, test scaffolding | copy per target | 15 |

Totals: **926 / 926 monolith files classified, none unclassified.** The monolith
keeps every one of them; the counts above are copies made into submodules.

## 3. Per-target assignment

### 3.1 `services/qits-projects` — project + repository + planning

Owns the Project aggregate, the git-remote-as-entity half of `domain.repository`, and
the epics planning module.

- `domain/project/**` — 5 main, 2 test
- `domain/seeding/**` + `service/.../seeding/**` — self-seed drives project+repository
- `epics/` module in full (33) + `service/.../epics/api/**` (6+1 test)
- `service/.../domain/repository/api/**` (8+10 test), `.../repository/mcp/**` (7+3 test),
  `.../domain/project/api/**` (1+1 test)
- `domain/src/main/resources/project-template/**` (5) — the archetype skeleton
- `domain/src/test/resources/fixtures/submodule-*.git/**` (49) — submodule-graph fixtures
- `domain/.../validation/ProjectSlug{,Validator}.java`
- Repository half of `domain/repository` (below)

**`domain/repository` → projects, explicit list**

```
control/  CommitService  GitRemoteAuth  GitSubmoduleParser  MetadataService
          ProjectTemplate  QitsConfigParser  RemoteLoginSession  RemoteLoginSessions
          RepositoryDiscoveryService  RepositoryMetadata  RepositoryNameResolver
          RepositoryService  ResolveConflictService
          + duplicated: GitExecutor  GitIdentity  ContainerRuntime  DockerExecutor
                        QitsConfig  QitsHostResolver
entity/   Repository  RepositoryArchetype  RepositoryName  RepositorySubmodule
dto/      BranchDto  CommitChangesDto  CommitDto  CommitFileChangeDto  CommitFileDiffDto
          CommitLogDto  RepositoryDto  RepositorySubmoduleDto  SyncStatusDto
mapper/   RepositoryMapper  RepositorySubmoduleMapper
persist./ RepositoryNameRepository  RepositoryRepository  RepositorySubmoduleRepository
docs/     package-info.java  AGENTS.md
tests/    Repository*Test (pull/push/sync/submodule), RepositoryArchetypeTemplateSyncTest
```

Flyway: V1, V3, V10, V20, V24, V33, V34, V41, V43, V44.

### 3.2 `services/qits-workspaces` — host side of workspaces

Already holds 31 control / 5 entity / 4 dto / 2 persistence / 1 mapper / 5 api /
3 daemonhost classes plus the vendored protocol. Its own pom states the scope:
*"the HOST side of workspaces … everything that runs INSIDE the container belongs to
qits-workspace-daemon and is deliberately absent."*

Still to copy:

- `domain/bootstrap/**` (8+2 test) + `service/.../domain/bootstrap/api` (1+1)
- `domain/service/**` (28+9 test — dev-server supervision) + `.../domain/service/api` (3+1)
- `domain/process/**` (6+2 test) + `.../domain/process/api` (1+1)
- `domain/capture/**` (3+1 test) + `.../domain/capture/api` (2+1)
- `domain/workspace/**` (2) + `.../domain/workspace/api` (3+3)
- `service/.../serviceproxy/**` (1+1), `service/.../workspacedaemonhost/**` (3+5)
- Workspace half of `domain/repository` (below)

**`domain/repository` → workspaces, explicit list**

```
control/  AngularComponentParser  ComponentMapService  ContainerFileAccess
          DetectionService  FrameworkDetectionService  GitignoreLazyDirectoryStrategy
          LazyDirectoryStrategy  ProvisionResult  ProxyOrigin  WorkingTreeMarker
          WorkspaceAgentActivity  WorkspaceBootstrapDriver  WorkspaceCheckpointService
          WorkspaceConfigReader  WorkspaceConfigView  WorkspaceContainer
          WorkspaceContainerEventPublisher  WorkspaceContainerFactory
          WorkspaceContainerStarted  WorkspaceContainerStopping  WorkspaceDaemonInfo
          WorkspaceDaemonLiveness  WorkspaceDaemonProvisioner  WorkspaceFileAccess
          WorkspaceFilesService  WorkspaceGitStatus  WorkspaceGitSync
          WorkspaceHistoryService  WorkspaceMetadata  WorkspacePromptAttachmentService
          WorkspacePromptDraftService  WorkspaceReadyForServices  WorkspaceResolver
          WorkspaceService  WorkspaceServiceDriver  WorkspaceTreeFingerprint
          + duplicated: GitExecutor  GitIdentity  ContainerRuntime  DockerExecutor
                        QitsConfig  QitsHostResolver
entity/   PromptAttachmentSource  Workspace  WorkspaceEvent  WorkspaceEventType
          WorkspacePromptAttachment  WorkspacePromptDraft  WorkspaceRuntimeStatus
          WorkspaceStatus
dto/      ComponentMapDto  ComponentMapEntryDto  ComponentSelectorDto  DetectedProjectDto
          DetectionDto  FileLinkDto  FrameworkMembershipDto  LazyDirDto  TestLinkDto
          WorkspaceDto  WorkspaceEventDto  WorkspaceFileContentDto
          WorkspaceHistoryDetailDto  WorkspaceHistoryDto
          WorkspacePromptAttachmentDataDto  WorkspacePromptDraftDto
mapper/   WorkspaceMapper  WorkspacePromptDraftMapper
persist./ WorkspaceEventRepository  WorkspacePromptAttachmentRepository
          WorkspacePromptDraftRepository  WorkspaceRepository
tests/    Fake* (ContainerRuntime, WorkspaceAgentActivity, WorkspaceBootstrapDriver,
          WorkspaceConfigReader, WorkspaceDaemon{Info,Liveness,Provisioner},
          WorkspaceGit{Status,Sync}, WorkspaceServiceDriver)
          Workspace*Test, GitIdentityAttributionTest,
          IncomingMergePullNotificationTest, IntegrateSyncsSourceContainerTest
```

Flyway: V14–V17, V19, V21–V26, V31, V35–V38, V42, V43, V45, V10, V24.

### 3.3 `daemons/qits-workspace-daemon` — both ends of the container socket

Gains **two new maven modules**, kept separate so each can be re-extracted later:

- **`agents/`** — `domain/agent/**` (28 main incl. `agent/acp`, 16 test)
  + `service/.../domain/agent/api/**` (5+5 test). Flyway V30, V39, V28.
- **`commands/`** — `domain/command/**` (33 main, 3 test)
  + `service/.../domain/command/api` (1+2 test) + `service/.../domain/chat/api` (1).
  Flyway V8, V9, V12, V13, V18, V28, V29, V32.

Existing `workspace-daemon/` and `workspace-daemon-protocol/` are untouched.

**Rationale and the caveat this rests on.** Before the gateway existed the frontend
could not address the daemon over REST, so agent/command APIs had to live in the
monolith. With `services/qits-gateway` in place they can be daemon-side.

The premise was checked against the code. It holds **partially**, and the difference
is load-bearing for the extraction:

- ✅ Every `CommandService` launch requires a workspace and a container. There are no
  null-workspace commands (`CommandService.java:503-528`). All three `CommandKind`
  values (`TERMINAL`, `CHAT`, `SERVICE`) execute their payload in-container.
- ❌ The **transport is host-side**. `CommandRegistry.java:150` spawns a pty4j
  `docker exec -it` client; `CommandRegistry.java:100` a `ProcessBuilder`
  `docker exec -i`. `WorkspaceDaemonRegistry` is not referenced anywhere under
  `domain/command/control/`. `WorkspaceDaemonRegistry.runCommand` is self-documented
  as a *"Part-1 demonstration seam"* with a single caller
  (`WorkspaceActionsController.java:134`).

So these two modules land in the daemon repo as **host-side control plane**, and
flipping the execution seam to the daemon socket is tracked as follow-up (§9).

Known host-coupled classes inside `agents/`, to be resolved per-class during
extraction rather than now:

| Class | Coupling |
|---|---|
| `AgentTranscriptService`, `AgentTranscriptTailService` | read `/claude-home/.claude` off the **host** filesystem |
| `AgentSessionQueryService`, `AgentActivityState`, `agent_session_stat` | pure DB / in-memory, no execution |
| `PromptRefinementService` (`:138`) | host `ProcessExecutor` wrapping docker argv |
| `AgentAuthStatus`, `AgentPluginService` | `ContainerRuntime.exec` → host docker CLI |

Dead code to drop rather than migrate: `CommandService.launchService`,
`beginServiceRun`, `followService`, `launchAndAwait`, `launchScriptAndAwait` (no
production callers) and the tmux verbs in `DockerExecutor.java:500-530` — residue of
the pre-daemon host-exec supervisor. Also stale: the `runAction` entry in
`ReadOnlyRepositoryToolFilter.java:46` names a tool that no longer exists.

### 3.4 `services/qits-artifacts` — blob store + git host

- `artifacts/` module in full (32) + `service/.../artifacts/api/**` (5+4 test)
- `service/.../githost/**` (2) + `service/src/test/.../githost/GitHostTest.java`

The git smart-HTTP host lands here rather than in a `qits-repositories` service —
that submodule is dropped because the name collides with `domain.repository`.
Own datasource + `db/artifacts/migration`; no Flyway from the shared lineage.

`CiPostReceiveNotifier` already POSTs to `qits.ci.intake-url`, so the
artifacts→ci seam is HTTP today and survives the split unchanged.

### 3.5 `services/qits-ci`

`ci/` module in full (32) + `service/.../ci/api/**` (4+2 test) + `ci/control` tests
in `service` (2). Own datasource + `db/ci/migration`.

Note it already runs entirely host-side and outside any workspace container
(`CiDockerRunner.java:110` spawns ephemeral `docker run --network qits-ci` steps;
`GitConfigFetcher.java:67-139` keeps its own bare git cache). That is by design and
needs no change.

### 3.6 `services/qits-observability` — telemetry

`service/.../domain/telemetry/{api,control,dto,mcp}/**` — 20 main, 12 test.

This is the only domain whose business logic lives entirely in the `service` module;
there is no `domain/telemetry`. Owns no tables (in-memory `TelemetryStore`).

**Naming conflict to settle before extraction.** Four names are in play for one
service: submodule `qits-observability`, its README `# qits-otel`, gateway enum
`OTEL` → default host `qits-otel`
(`services/qits-gateway/src/main/java/eu/wohlben/qits/gateway/QitsService.java`),
and the monolith feature-idea `standalone-telemetry-service.md` which says
`qits-telemetry`. Pick one and align the other three.

### 3.7 `services/qits-stt` — speech

`domain/speech/**` (2 main, 1 test) + `service/.../domain/speech/api` (1+1)
+ `domain/src/main/resources/speech/transcribe_worker.py`. Owns no tables.

Genuinely host-side and *not* workspace-scoped: `SpeechWorker.java:80` runs a
resident host python process and `TranscriptionService.java:124-133` bootstraps a
venv with `pip install` on the host. Its own service is the right home for that.

### 3.8 `services/qits-cd` — reserved

Nothing in the monolith maps to it. The `qits-live-deployment` epic is unimplemented.
Keep the submodule as a reservation; do not copy anything into it yet.

### 3.9 Monolith-only — no target receives a copy

These 106 files are classified but never copied anywhere. They are not "left behind" —
under the §1 invariant *nothing* leaves the monolith; these simply have no submodule
that wants a copy.

106 files: `service/src/main/webui/**` (not counted above), `spa/`, `mcp/`,
`mutiny/`, `api/` exception mappers, `http/RootPath`, `websocket/`,
`application.properties`, `service/src/main/docker/**`, the root/`domain`/`service`
poms, `domain/featureflow/**` (28) + `service/.../domain/featureflow/{api,mcp}` (7),
and `userflows/` (the product stories — the framework is already extracted).
Flyway V2, V4–V7, V11, V27, V43 (featureflow parts).

## 4. Unassigned — open questions

| Files | What | Why it's open |
|---|---|---|
| 29 | `auth/{core,local,oidc,forwardauth}` | Every extracted service needs the same `QitsAuthPolicy` + `PublicPaths`. A `libs/qits-auth` is the obvious answer, but the modules are **profile-swapped at build time** (`-Dqits.variant`), which does not survive a per-service split unchanged. The `qits-gateway` epic Part 4 proposes moving auth to the edge instead, which would delete most of this. Decide with that epic, not here. |
| 10 | `domain/setting/**` + its api | A generic DB-backed key/value store read by `agent` only (`agent.default-type`, `agent.activity-tracking.enabled`). Either follows agents into the daemon repo, or becomes the seed of `libs/qits-commons`. Flyway V40. |
| 11 | `cli/` | Command-mode seeding/dev tooling (`SeedService`, `SeedWebappService`, `SeedLitService`, `GenerateMigrationService`). Depends on `domain` only, executes nothing. Likely ships with whatever holds the app shell. |

## 5. Duplicate-now, library-later

Note this is duplication *among submodules*. Since the monolith keeps its copy of
everything (§1), every row below already exists in `../qits` too — the "Copies to"
column lists the additional new homes.

`qits-workspaces` already set the precedent: it carries its own copies of
`GitExecutor`, `ContainerRuntime`, `DockerExecutor`, `QitsConfig`, `QitsHostResolver`,
`GitIdentity`, `ProvisionResult`, `ProxyOrigin`, `WorkspaceChangeHint/Publisher` and a
local `workspaces/error/` package, and vendors `workspace-daemon-protocol` outright.

Copy to every target that needs them; consolidate into `libs/qits-commons` later:

| Class / path | Copies to |
|---|---|
| `domain/error/*` (5: `DomainException`, `BadRequest`, `NotFound`, `InternalServerError`, `PayloadTooLarge`) | every target (as `<ctx>/error/`) |
| `GitExecutor`, `GitIdentity` | projects, workspaces |
| `ContainerRuntime`, `DockerExecutor` | projects, workspaces |
| `QitsConfig`, `QitsHostResolver`, `ProvisionResult`, `ProxyOrigin` | projects, workspaces |
| `WorkspaceChangeHint`, `WorkspaceChangePublisher` | workspaces, daemon-agents, daemon-commands |
| `AgentActivityState` | workspaces (already), daemon-agents |
| `ProcessExecutor` | daemon-agents, stt |
| `validation/NotBlankIfPresent{,Validator}` | projects, workspaces |
| `domain/testsupport/`, `src/test/resources/{application,junit-platform}.properties`, `META-INF/services/…Extension` | every target |
| `src/test/resources/fixtures/testing-repo*` (4 gitlinks) | projects, workspaces — already separate repos, re-attach as submodules |
| `workspace-daemon-protocol` | already vendored in `qits-workspaces` **and** `qits-workspace-daemon` |

## 6. Coupling cycles to break

`domain` is not a DAG. From the import graph:

```
repository ↔ command    repository ↔ agent    repository ↔ service
repository ↔ project    command   ↔ agent     project    ↔ featureflow
agent      ↔ setting    process → command, repository → process
```

`repository`, `command`, `agent`, `service` form a mutually recursive core — the main
obstacle. `error` and `workspace` are the only zero-outbound-edge packages.

Named cut sites, each of which must become an HTTP call, an event, or a duplicated
type at extraction time:

| Site | Edge |
|---|---|
| `QitsConfig` / `QitsConfigParser` | → `service.entity.{HealthCheckKind,RestartPolicy}` |
| `RemoteLoginSessions` | → `command.control.CommandOutputSink`, `process.control.{RepoReservation,TechnicalProcessRegistry}` |
| `RepositoryService`, `WorkspaceService` | → `process.control.*` |
| `ResolveConflictService` | → `agent.control.AgentLaunchService` |
| `WorkspaceDto`, `WorkspaceAgentActivity`, `WorkspaceService` | → `agent.control.AgentActivityState` |
| `WorkspaceHistoryService` | → `command.{mapper,persistence}` |
| `Repository`, `RepositoryName` entities | → `project.entity.Project` (FK) |
| `Setting` validation | → `agent.entity.AgentType` |

`domain.workspace.control.WorkspaceChangePublisher` is already the intended
decoupling mechanism (payload-free CDI async hints, 11 `Topic` values). Prefer
widening it over new synchronous calls.

## 7. Flyway migration map

The monolith's V1–V45 lineage cannot be split in place. Each target starts a fresh
`V1__init.sql` squashed from the migrations below (schema as of V45, not a replay).

| Target | Migrations |
|---|---|
| projects | V1, V3, V10\*, V20, V24\*, V33, V34, V41, V43\*, V44 |
| workspaces | V10\*, V14–V17, V19, V21–V26, V31, V35–V38, V42, V43\*, V45 |
| daemon-commands | V8, V9, V12, V13, V18, V28\*, V29, V32 |
| daemon-agents | V28\*, V30, V39 |
| unassigned (setting) | V40 |
| monolith-only (featureflow) | V2, V4–V7, V11, V27, V43\* |
| own lineage, unaffected | artifacts (`db/artifacts`), ci (`db/ci`), epics (`db/epics`) |

`*` = migration touches more than one target; split its statements.
Live tables by owner: `Project` → projects; `Repository`, `repository_name`,
`repository_submodule` → projects; `workspace`, `workspace_event`,
`workspace_prompt_draft`, `workspace_prompt_attachment`, `workspace_bootstrap_run`,
`service_event` → workspaces; `command`, `command_log_line`, `command_agent_session`
→ daemon-commands; `agent_session_stat` → daemon-agents; `setting` → unassigned;
`FeatureFlowConfiguration` + `feature_flow_*` + `ActionConfiguration*` → monolith-only.

Note the V42–V45 trend: repo-scoped DB configuration was already deleted in favour of
in-repo `.qits-config.yml` read by the in-container daemon. The host DB now keeps only
*observed* state, which makes these lineages far easier to separate than the raw
migration count suggests.

## 8. Extraction recipe

History replay is proven: `services/qits-workspaces` carries 94 real commits back to
`3ab9791 Split into domain / service / cli modules`.

For each target `<t>`:

1. **Clone.** `git clone --no-local ../qits /tmp/extract-<t>`
   (`--no-local` so filter-repo gets a real object copy, not hardlinks.)
   Every later step runs inside this throwaway clone. **`../qits` is never written
   to** — do not run `filter-repo`, `rm`, or any commit against it. `filter-repo`
   refuses to run on a repo with a remote or unclean state anyway, which is a useful
   backstop; do not defeat it with `--force` pointed at the real monolith.
2. **Filter.**
   `git filter-repo --paths-from-file migration-manifests/<t>.paths`
   Generate `.paths` from `migration-manifests/<t>.txt` (first tab-separated field).
   `--path` matches historical paths, so add `--path-rename` / extra `--path` entries
   for anything that moved. Known renames to cover: `worktree` → `workspace`
   (V24 era), `domain.daemon.*` → `domain.service.*`, and the `daemon` → `service`
   rename at V45. Cross-check with `git log --follow <file>` before filtering.
3. **Rename packages.** `eu.wohlben.qits.domain.<area>` → `eu.wohlben.qits.<ctx>`,
   plus an added `<ctx>/error/` package. Apply as one post-filter commit, matching
   `qits-workspaces` (`7d32a29 Rename packages to eu.wohlben.qits.workspaces.*`).
4. **Add the standalone parent pom.** Two established styles — pick per repo:
   - *namespaced GAV* (`eu.wohlben.qits:qits-<t>`) when child artifactIds are generic
     like `domain`/`service`. Required to avoid clobbering the monorepo jars in the
     shared `~/.m2` that every workspace container mounts. Used by `qits-workspaces`.
   - *monorepo-preserving GAV* (`eu.wohlben:qits`) when child artifactIds are already
     globally unique, so children's `<parent>` resolves unchanged. Used by
     `qits-workspace-daemon` and `qits-userflows`.

   Duplicate Quarkus `3.34.6` and JDK 25 on purpose. Drop the monorepo machinery:
   spotless, enforcer, the :8080 dev-guard, the 15-way isolated-test surefire
   chunking, `derive-fixture-bares`, the build-cache extension, and the
   `-Dqits.variant` auth profiles.
5. **Squash Flyway** per §7 into a fresh `V1__init.sql`.
6. **Push** to `github.com/QuicklyIterateTheSoftware/qits-<t>.git`, then register per
   the recipe in [`CLAUDE.md`](CLAUDE.md) — `ignore = all`, `update = merge`,
   `branch = main`. Seed the remote with an initial commit first; `git submodule add`
   fails against an empty remote and leaves a stale `.git/modules/<name>`.
7. **Register the route** in
   `services/qits-gateway/src/main/java/eu/wohlben/qits/gateway/QitsService.java`
   (enum constant → `/segment` prefix → `qits-<segment>` host on `qits-net`), and add
   the container to the compose topology.

Order matters: extract leaves first. `qits-stt`, `qits-observability`, `qits-ci`,
`qits-artifacts` have no inbound edges from the rest. `qits-projects` and
`qits-workspaces` must be cut together because of the `repository ↔ project` and
`repository` split. The daemon `agents/` + `commands/` modules come last — they carry
the most cut sites (§6).

## 9. Open questions and follow-ups

1. **Observability naming** — `qits-observability` / `qits-otel` / `qits-telemetry`.
   Pick one (§3.6).
2. **`services/qits-repositories` removal** — drop the entry from `.gitmodules`, `git rm`
   the gitlink, **and remove the `REPOSITORIES` constant from `QitsService`**
   (`services/qits-gateway/.../QitsService.java:38`). The name collides with
   `domain.repository`; the git host it was meant to hold goes to `qits-artifacts` (§3.4).
3. **Daemon execution-seam flip** — move terminals/chats/agents off the host
   `docker exec` client onto the daemon control socket, replacing
   `CommandRegistry.java:100,150` with `RunCommand` protocol messages. Until then
   `agents/` and `commands/` are host-side modules inside the daemon repo (§3.3).
4. **Auth strategy** — resolve against `qits-gateway` epic Part 4 (edge auth) before
   creating `libs/qits-auth` (§4).
5. **`libs/qits-commons`** — when the duplicate register (§5) stops being cheaper than
   a shared jar.
6. **`domain.featureflow`** — deferred; currently coupled to `project` in both
   directions.
7. **`qits-workspaces` is not yet a deployable.** Its `service/` module is a library
   JAR by design. Something must package it as a process (auth variant + main class)
   before its gateway route can go live.
8. **`daemons/` is not an archetype directory.** `RepositoryArchetype` defines
   `services`/`libs`/`integrations`/`apps` only. Either add `daemons` or move the
   submodule.
9. **Gateway enum vs target set.** `QitsService` today is
   `ARTIFACTS, OTEL, WORKSPACES, STT, CI, CD, REPOSITORIES`. After this plan it needs
   `PROJECTS` added, `REPOSITORIES` removed, `OTEL` reconciled with item 1, and a
   decision on how the daemon's `agents`/`commands` REST surface is addressed —
   there is no `DAEMON` constant, and routing them under `/workspaces` would conflate
   two repos. Also note `qits-gateway` is deliberately absent from its own enum.
10. **Missing AGENTS.md** in `services/qits-workspaces` and
    `daemons/qits-workspace-daemon`. Every other populated submodule has one
    (`CLAUDE.md` a symlink to it).
