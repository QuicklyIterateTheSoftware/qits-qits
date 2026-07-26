# qits monolith → submodules: migration plan

Status: **five targets extracted; daemon modules remain.**
Source of truth for the split. Written 2026-07-26, revised the same day from the
extractions of `qits-stt`, `qits-ci`, `qits-artifacts`, `qits-observability`,
`qits-projects` and the completion of `qits-workspaces`.

Done: `qits-stt`, `qits-ci`, `qits-artifacts`, `qits-observability`, `qits-projects`,
`qits-workspaces`. Remaining: the daemon `agents/` + `commands/` modules (§3.3), and the
open questions in §9. Every count and recipe step below that an extraction contradicted has
been corrected against what actually happened, not against what was planned.

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
| `services/qits-projects` | Project, repository, epics/planning | **done** | 200 |
| `services/qits-workspaces` | Host side of workspaces, containers, dev services | **done** | 207 |
| `daemons/qits-workspace-daemon` | In-container daemon **+ agents + commands** | **partial** (55 copied) | 104 new |
| `services/qits-artifacts` | Blob store + git smart-HTTP host | **done** | 45 |
| `services/qits-ci` | In-repo pipelines | **done** | 41 |
| `services/qits-observability` | Telemetry / OTLP | **done** | 32 |
| `services/qits-stt` | Speech-to-text | **done** | 6 |
| `services/qits-cd` | Live deployment | **reserved** — nothing maps yet | 0 |
| `libs/qits-userflows` | Playwright story framework | **done** | — |
| `integrations/qits-integrations-angular` | `@qits/angular` | **done** | — |
| `integrations/qits-integrations-quarkus` | *(unstarted, no monolith source)* | empty | 0 |
| ~~`services/qits-repositories`~~ | **dropped** — name collides with `domain.repository` | — | — |
| *(no target)* | webui, app shell, featureflow, product userflows | monolith-only | 0 |
| *unassigned* | `auth/*` (34), `domain.setting` (9), `cli/` (12) | open question | 55 |
| *duplicated* | error types, validation, test scaffolding | copy per target | 15 |

Totals: **926 / 926 monolith files classified, none unclassified.** The monolith
keeps every one of them; the counts above are copies made into submodules.

Two assignment corrections came out of the extractions and are already applied to
`migration-manifests/`:

- **27 rows left `workspaces`.** File browsing and framework detection moved into
  `daemons/qits-workspace-daemon` (its own commits `2dbe0ab`, `0b034cc`, as
  `workspace-daemon-files` and `workspace-daemon-detection`), reimplemented in `java.nio`
  instead of host-side `docker exec`. 25 are recorded in `already-extracted.txt`;
  `WorkspaceCheckpointService` + its test were deleted rather than relocated (the daemon's
  `OriginSync` already pushes per commit) and are recorded in `monolith-only.txt`.
- **25 rows left `projects`, 24 of them for `workspaces`.** `assign.py` split
  `domain/repository` per class but matched the *service* side by directory, so the whole
  `service/.../domain/repository/{api,mcp,control}` boundary went to projects — stranding
  the workspace controllers, sockets, prompt-draft surface and workspace fakes there with
  no other owner. Found when qits-projects was cut. `ContainerFileBrowserIT` went to the
  daemon with the rest of file browsing.

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

- `artifacts/` module in full (33) + `service/.../artifacts/api/**` (5+4 test)
- `service/.../githost/**` (2) + `service/src/test/.../githost/GitHostTest.java`

The git smart-HTTP host lands here rather than in a `qits-repositories` service —
that submodule is dropped because the name collides with `domain.repository`.
Own datasource + `db/artifacts/migration`; no Flyway from the shared lineage.

`CiPostReceiveNotifier` already POSTs to `qits.ci.intake-url`, so the
artifacts→ci seam is HTTP today and survives the split unchanged.

### 3.5 `services/qits-ci`

`ci/` module in full (33) + `service/.../ci/api/**` (4+2 test) + `ci/control` tests
in `service` (2). Own datasource + `db/ci/migration`.

Note it already runs entirely host-side and outside any workspace container
(`CiDockerRunner.java:110` spawns ephemeral `docker run --network qits-ci` steps;
`GitConfigFetcher.java:67-139` keeps its own bare git cache). That is by design and
needs no change.

### 3.6 `services/qits-observability` — telemetry

`service/.../domain/telemetry/{api,control,dto,mcp}/**` — 20 main, 12 test.

This is the only domain whose business logic lives entirely in the `service` module;
there is no `domain/telemetry`. Owns no tables (in-memory `TelemetryStore`).

**Naming: settled (§9 item 1).** Both, not one — `qits-observability` is the submodule,
context and deployable; `qits-telemetry` is the maven module and java package inside it.
`qits-otel` is retired and appears nowhere in the extracted repo. The gateway enum was
`OTEL` → default host `qits-otel`, which was actively wrong because `defaultHost()` derives
`qits-<segment>` and no `qits-otel` container exists; it is now `OBSERVABILITY`, so the
public route moved `/otel/*` → `/observability/*`. Nothing was deployed behind it.

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
| 34 | `auth/{core,local,oidc,forwardauth}` | Every extracted service needs the same `QitsAuthPolicy` + `PublicPaths`. A `libs/qits-auth` is the obvious answer, but the modules are **profile-swapped at build time** (`-Dqits.variant`), which does not survive a per-service split unchanged. The `qits-gateway` epic Part 4 proposes moving auth to the edge instead, which would delete most of this. Decide with that epic, not here. |
| 9 | `domain/setting/**` + its api | A generic DB-backed key/value store read by `agent` only (`agent.default-type`, `agent.activity-tracking.enabled`). Either follows agents into the daemon repo, or becomes the seed of `libs/qits-commons`. Flyway V40. |
| 12 | `cli/` | Command-mode seeding/dev tooling (`SeedService`, `SeedWebappService`, `SeedLitService`, `GenerateMigrationService`). Depends on `domain` only, executes nothing. Likely ships with whatever holds the app shell. |

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
| `domain/error/*` (5: `DomainException`, `BadRequest`, `NotFound`, `InternalServerError`, `PayloadTooLarge`) | every target **that does not already own an `error/` package** (as `<ctx>/error/`) — take only the ones you actually throw |
| `GitExecutor`, `GitIdentity` | projects, workspaces |
| `ContainerRuntime`, `DockerExecutor`, `ProvisionResult`, `ProxyOrigin`, `QitsHostResolver` | **workspaces only** |
| `QitsConfig`, `QitsConfigParser` (+ `service.entity.{HealthCheckKind,RestartPolicy}`, inlined) | projects, workspaces |
| `WorkspaceChangeHint`, `WorkspaceChangePublisher` | workspaces, daemon-agents, daemon-commands — **see the CDI caveat below** |
| `AgentActivityState` | workspaces (already), daemon-agents |
| `ProcessExecutor` | daemon-agents, stt |
| `CommandOutputSink` | projects, workspaces, daemon-commands |
| `http/RootPath` | any target with a raw vertx route that parses `rc.request().path()` (workspaces) |
| `repository/mcp/ProjectScope` | projects, observability (as `RepositoryScope`) — any MCP-bearing target |
| `validation/NotBlankIfPresent{,Validator}` | projects, workspaces |
| `domain/testsupport/`, `src/test/resources/{application,junit-platform}.properties`, `META-INF/services/…Extension` | **only targets whose test classes share `qits.repositories.data-dir`** — projects took them; ci, artifacts, stt, observability and workspaces did not |
| `src/test/resources/fixtures/testing-repo*` (4 gitlinks) | projects, workspaces — **build in-test, do not re-attach as submodules** (see §8) |
| `workspace-daemon-protocol` | already vendored in `qits-workspaces` **and** `qits-workspace-daemon` |

> **CDI event types cannot be duplicated.** `WorkspaceChangeHint`/`WorkspaceChangePublisher`
> are the one row above where copying is not merely wasteful but *silently wrong*: the
> duplicated type is not the type the original boundary observes, so a verbatim copy
> compiles, runs, and delivers nothing — no error anywhere. `qits-observability` hit this
> and cut a context-local `TelemetryChangePublisher` + `TelemetryChanged` instead, bridged
> at the consumer with a three-line `@ObservesAsync`. Do the same for any event type; §6's
> "prefer widening `WorkspaceChangePublisher`" only holds *within* a context.

Two rows were wrong as written and are corrected above. `ContainerRuntime`, `DockerExecutor`,
`ProvisionResult`, `ProxyOrigin` and `QitsHostResolver` were listed for projects as well as
workspaces; every production use is workspace-side, and `DockerExecutor` cannot compile in
projects at all because it injects `WorkspaceContainerFactory` (a `WS_REPO` class). The
testsupport row said "every target" and was needed by exactly one.

`duplicated.txt` is **not** this register — it is only what `assign.py` assigned to more than
one *target*. Rows here that live in a single target's manifest (`ProcessExecutor`,
`GitExecutor`, `ContainerRuntime`, `QitsConfig`, `QitsHostResolver`, `ProvisionResult`,
`ProxyOrigin`, `GitIdentity`, `WorkspaceChangeHint/Publisher`, `AgentActivityState`) do not
appear in it. Work from this table and from what fails to compile.

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

| Site | Edge | Resolved as |
|---|---|---|
| `QitsConfig` / `QitsConfigParser` | → `service.entity.{HealthCheckKind,RestartPolicy}` | enums inlined into the context (both projects and workspaces) |
| `RemoteLoginSessions` | → `command.control.CommandOutputSink`, `process.control.{RepoReservation,TechnicalProcessRegistry}` | projects: `TechnicalProcessRegistry` port + duplicated `CommandOutputSink` |
| `RepositoryService`, `WorkspaceService` | → `process.control.*` | projects: `TechnicalProcessRegistry` port, optional; absent → unnarrated, no single-flight |
| `ResolveConflictService` | → `agent.control.AgentLaunchService` | **unresolved** — reassigned to workspaces, not yet carried (§9 item 11) |
| `WorkspaceDto`, `WorkspaceAgentActivity`, `WorkspaceService` | → `agent.control.AgentActivityState` | workspaces: duplicated per §5 |
| `WorkspaceHistoryService` | → `command.{mapper,persistence}` | workspaces: `WorkspaceCommandHistory` port |
| `Repository`, `RepositoryName` entities | → `project.entity.Project` (FK) | **no cut needed** — both endpoints are projects', one database, kept as real `@ManyToOne` |
| `Setting` validation | → `agent.entity.AgentType` | still unassigned (§4) |
| `GitHostRoutes` | → `repository.persistence.RepositoryNameRepository` | artifacts: `githost.RepositoryNameResolver` port, optional; absent → name-addressed 404s, id-addressed unchanged |
| `TelemetryStore` | → `workspace.control.WorkspaceChangePublisher/Hint` | observability: context-local publisher + `@ObservesAsync` bridge (a copy would silently not deliver — see §5) |
| `TelemetryMcpTools` | → `repository.mcp.ProjectScopeGuard` | observability: `RepositoryScopeGuard` port, **fail closed** |
| `TelemetryMcpTools` | → `repository.persistence.WorkspaceRepository` | observability: `WorkspaceLookup` port, **fail closed** |
| `CommitService`, `RepositoryService` | → `WorkspaceRepository`, `WorkspaceService` | projects: `WorkspaceLookup` port; absent → main-branch fallback |
| `RepositoryService.delete`, clone | → `WorkspaceService.createMainWorkspace`, `ContainerRuntime` teardown | projects: `WorkspaceLifecycle` port, kept synchronous (ordering precondition, not a hint) |
| `CaptureService` | → `Repository` entity + `RepositoryRepository` | workspaces: existing mandatory `RepositoryLookup` |
| `ServiceTerminalSocket` | → `CommandRegistry` | workspaces: `WorkspaceTerminalSessions` port; absent → upgrade refused |
| `ServiceAgentNotifier` | → `CommandRegistry`, `CommandRepository`, `CommandKind` | workspaces: `WorkspaceChatInbox` port; absent ≡ "no chat running", already handled |
| `LogLevelLineClassifier` | → `command.control.LogLineClassifier`, `command.entity.LogSeverity` | workspaces: the one *outbound* port — this context supplies the impl |
| `ProjectService.delete`, `Project` | → `featureflow.*` (`@OneToMany` + 2 REST routes) | projects: **cut outright** — featureflow is monolith-only *and* deferred, so there is no other side to declare against |

**Ports are not automatically "absent = degrade".** For a cross-context *isolation* check the
documented absent-behaviour must be **deny**. Both observability MCP ports fail closed —
the tool filter hides them and a direct call 404s. Reading "optional port" as "skip the check
when unwired" would have been a security regression.

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

History replay is proven six times over: `qits-workspaces` carries 166 commits back to
`3ab9791 Split into domain / service / cli modules`, and `qits-projects` 132 back to the
monolith's own initial commit. Every step below is written against what those extractions
actually needed, not against what the first draft assumed.

**`git filter-repo` is not installed** on the dev machine and there is no `pip3`/`pipx`.
Fetch the single-file script and run it as `python3 git-filter-repo …`.

For each target `<t>`:

1. **Clone.** `git clone --no-local ../qits /tmp/extract-<t>`
   (`--no-local` so filter-repo gets a real object copy, not hardlinks.)
   Every later step runs inside this throwaway clone. **`../qits` is never written
   to** — do not run `filter-repo`, `rm`, or any commit against it. `filter-repo`
   refuses to run on a repo with a remote or unclean state anyway, which is a useful
   backstop; do not defeat it with `--force` pointed at the real monolith.

   **Leave the clone exactly as `git clone` left it.** Removing the `origin` remote as an
   extra safety measure makes filter-repo abort (`expected one remote, origin`), and
   re-adding it leaves `refs/remotes/origin/main` missing — only a re-clone recovers.
   filter-repo removes `origin` itself as its last act.

2. **Filter.**
   `python3 git-filter-repo --paths-from-file migration-manifests/<t>.paths`
   Generate `.paths` from `migration-manifests/<t>.txt` (first tab-separated field).

   `--path` matches historical paths, so add extra `--path` entries **on the command line**
   (never edited into the shared `.paths` file) for anything that moved. Known renames:

   - `worktree` → `workspace` (V24 era, `dd2f2385`)
   - `domain.daemon.*` → `domain.service.*`, and `daemon` → `service` at V45
   - **`artifactory` → `artifacts`** (`a8f2fccc`) — directories, packages,
     `db/artifactory/migration`, and eight class names
   - **`service/` → `domain/` module move** — the whole `domain.{project,repository}` tree
     plus `service/src/main/resources/db/migration/`; without it, 25 files lose all history
   - **`daemonproxy/DaemonProxyRoute` → `serviceproxy/ServiceProxyRoute`**
   - **`GitHostResolverTest` → `QitsHostResolverTest`**
   - two-hop chains exist and need *both* old names, e.g.
     `WorktreeDaemonController → WorkspaceDaemonController → WorkspaceServiceController`

   Cross-check with `git log --follow --name-status <file>` — and read the status letter:

   > **Only `R` is a rename. `C` is a copy**, and these modules were routinely written by
   > copying a sibling wholesale — `ci/pom.xml` ← `artifacts/pom.xml`, `epics/pom.xml` ←
   > `artifacts/pom.xml`, `CiTokenFilter` ← `ArtifactsTokenFilter`, stt's
   > `SpeechControllerTest` ← `AgentControllerTest`. Following one drags an unrelated
   > context's history in. `--follow` also chains *through* a copy, so an `R` further up the
   > chain can still be a false hit — check the R's destination is a path you own.

   Prefer an extra `--path` for the old name (preserves history and replays the monolith's
   own rename commit) over `--path-rename` (erases the rename). `--path-rename` does not
   imply keep, and filters apply **in argument order** against the evolving path, so pair it
   with a `--path` and place it after `--paths-from-file`.

   Sanity-check by count, not magnitude: take the expected number from the monolith first
   with `git log --oneline -- $(cat <t>.paths) | wc -l`. "More than one commit" is not a
   check — `qits-stt` legitimately filters to 2.

3. **Rename packages.** `eu.wohlben.qits.domain.<area>` → `eu.wohlben.qits.<ctx>`,
   plus an added `<ctx>/error/` package. Apply as one post-filter commit, matching
   `qits-workspaces` (`7d32a29 Rename packages to eu.wohlben.qits.workspaces.*`).
   A no-op for targets already outside `domain.*` (ci, artifacts) — say so rather than
   inventing a rename.

   Take the §5 rows you need — **from the §5 table, not from `duplicated.txt`**, which is a
   different set — and only the ones you actually use. Targets that already own an `error/`
   package need none.

4. **Cut the seams.** *(This step was missing from the first draft and is where the work
   actually is.)* Precedent: `cc0609f Cut the seams so the workspaces context stands alone`.

   Every reach into another context becomes a **port**: declare the interface in your own
   `control/`, inject it, and let the assembling application implement it. Never add a JPA
   relation or foreign key across contexts — different databases, reference by string id.
   Mandatory (`@Inject`) when the context is meaningless without it and misconfiguration
   should fail at startup, à la `RepositoryLookup`; optional (`Instance<T>`) when absent is
   a real configuration. **Document the absent-behaviour either way, and make it *deny* for
   anything that is an isolation or authorization check** (§6).

   Record every seam you cut — §6's table is maintained from these reports.

5. **Fix the test surface.** *(Also missing from the first draft.)* §6 covers production
   coupling only, and the test surface broke in four of six extractions:

   - Dropping `derive-fixture-bares` (step 6) also invalidates `/fixtures/testing-repo*.git`
     and `RepositoryService.cloneRepository(fixtureUrl, …)` as setup idioms. **Build git
     fixtures in-test** — three of three agents that hit this did, and re-attaching the
     gitlinks as submodules is incompatible with the clone-alone gate.
   - A test asserting behaviour that belongs to *another* target must be reported, not
     silently deleted. Eight such assertions are currently unowned (§9 item 12).
   - `mvn clean` is mandatory after `git rm`-ing any test bean: filter-repo does not remove
     stale `target/` classes, and Quarkus still sees the `.class`. The failure mode is
     `Instance.isResolvable() == false`, which looks nothing like a duplicate-bean error.

6. **Add the standalone parent pom.** Two established styles — pick per repo:
   - *namespaced GAV* (`eu.wohlben.qits:qits-<t>`) when child artifactIds are generic
     like `domain`/`service`. Required to avoid clobbering the monorepo jars in the
     shared `~/.m2` that every workspace container mounts. Used by `qits-workspaces`.
   - *monorepo-preserving GAV* (`eu.wohlben:qits`) when child artifactIds are already
     globally unique, so children's `<parent>` resolves unchanged. Used by
     `qits-workspace-daemon` and `qits-userflows`.

   **Directory names are load-bearing** (they anchor the replayed history); artifactIds are
   not. Never let the directory name double up — `qits-ci-ci`, `qits-artifacts-artifacts`.
   Name children by layer (`qits-<t>-domain`, `qits-<t>-service`) unless a settled name wins,
   as `qits-telemetry` does over `service/`. A single-module target still gets a parent pom;
   flattening it would move the sources and break the history anchor.

   **`service/pom.xml` is monolith-only**, so it is in no manifest and must be written from
   scratch — which forces the library-jar-vs-deployable decision (§9 item 7). Every target so
   far chose library jar.

   Duplicate Quarkus `3.34.6` and JDK 25 on purpose. Drop the monorepo machinery:
   spotless, enforcer, the :8080 dev-guard, the 15-way isolated-test surefire
   chunking, `derive-fixture-bares`, the build-cache extension, and the
   `-Dqits.variant` auth profiles. `.mvn/` must be pruned by hand — drop `extensions.xml`
   and `maven-build-cache-config.xml`, keep `wrapper/`. Bring `mvnw`, `mvnw.cmd`,
   `.gitignore`, `.sdkmanrc`; `mvnw` must land mode `100755`. Check the Quarkus BOM before
   pinning any `<version>`.

   **Re-provide every app-shell property your routes depend on.** The monolith's
   `service/src/main/resources/application.properties` is monolith-only, and its settings are
   invisible until they fail:

   - `quarkus.rest.path=/api` — without it **every REST test 404s**. All six hit this.
   - `quarkus.mcp.server.<name>.http.root-path` — without it the MCP server refuses to
     **start** (`IllegalStateException: Invalid server name`).

   **Re-provide the exception mapper.** §3.9 sends `service/.../api/` mappers to
   monolith-only, so no target inherits `DomainExceptionMapper`; without a
   `<Ctx>ExceptionMapper` typed to your own `DomainException`, anything throwing
   `BadRequestException` returns **500 where the suite asserts 400**.

   Other per-target gotchas: a named persistence unit means `@Inject EntityManager` needs
   `@PersistenceUnit("<ctx>")`; a boundary reading `SecurityIdentity` needs `quarkus-security`
   explicitly (the monolith supplied it via the unassigned auth variants); and a test-jar
   filtered narrower than its directory throws `ClassNotFoundException`, because Quarkus
   indexes `target/test-classes` while the classpath resolves the jar — filter resources,
   never classes.

7. **Squash Flyway** per §7 into a fresh `V1__init.sql` — **unless §7 lists the target under
   "own lineage, unaffected"** (artifacts, ci, epics), in which case carry the existing
   lineage over verbatim and do not renumber it. A target that owns no tables (stt,
   observability) skips Flyway *and* the datasource entirely. `qits-projects` is the one repo
   with both: `domain/` squashed, `epics/` carried over untouched.

8. **Verify.** `./mvnw verify` must be green from a **fresh clone of the pushed repo alone**
   — no monorepo, no prior `mvn install`, no docker, no credentials. Verify from that clone,
   not from the working one. ITs needing docker default to `skipITs=true`.

9. **Push** to `github.com/QuicklyIterateTheSoftware/qits-<t>.git`.

   For an **empty** target the remote holds one seed commit whose only content is a one-line
   README; force-push the filtered history over it. For an **already-populated** target
   (`qits-workspaces`, and the daemon next) the remote holds real history and the push must
   be a **fast-forward** — never force. Add to a populated target by filtering a fresh clone
   down to just the new files, fetching that into a clone of the *target remote* (a third
   clone — the submodule directory is not the place), and merging with
   `--allow-unrelated-histories`: the filtered branch's root is the earliest commit touching
   *its* file set, so there is no merge base even though both descend from the monolith.
   **Merge before the package rename** — merging at monolith paths is conflict-free, and the
   rename lands as a separate `git mv` commit that keeps `--follow` intact.

   Register per [`CLAUDE.md`](CLAUDE.md) — `ignore = all`, `update = merge`, `branch = main`
   — only for a *new* submodule. The ones in `.gitmodules` already need nothing but
   `git -C services/qits-<t> fetch origin && git switch -C main origin/main`. Write a
   `README.md` and an `AGENTS.md`, with `CLAUDE.md` a **symlink** to the latter.

10. **Register the route** in
    `services/qits-gateway/src/main/java/eu/wohlben/qits/gateway/QitsService.java`
    (enum constant → `/segment` prefix → `qits-<segment>` host on `qits-net`), and add
    the container to the compose topology. Note this is a commit *inside the gateway
    submodule*, and its README is a contract document that lists the registry.

Order matters: extract leaves first. `qits-stt`, `qits-observability`, `qits-ci`,
`qits-artifacts` have no inbound edges from the rest — all four are done. `qits-projects`
and `qits-workspaces` were cut together because of the `repository ↔ project` and
`repository` split, and that pairing proved necessary: each declared ports the other
implements, and the one manifest bug that stranded 24 files was only visible from the
projects side. The daemon `agents/` + `commands/` modules come last — they carry the most
cut sites (§6), and items 11–13 of §9 are theirs to absorb or hand on.

## 9. Open questions and follow-ups

1. ~~**Observability naming**~~ — **settled.** Both, not one: `qits-observability` the
   submodule, `qits-telemetry` the maven module and package inside it (§3.6). The gateway
   constant is now `OBSERVABILITY`; `qits-otel` is retired.
2. **`services/qits-repositories` removal** — **half done.** The `REPOSITORIES` constant is
   gone from `QitsService`. Still to do: drop the entry from `.gitmodules` and `git rm` the
   gitlink. The name collides with `domain.repository`; the git host it was meant to hold
   went to `qits-artifacts` (§3.4).
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
9. **Gateway enum vs target set** — **mostly done.** `QitsService` is now
   `ARTIFACTS, OBSERVABILITY, WORKSPACES, PROJECTS, STT, CI, CD`. Still open: how the
   daemon's `agents`/`commands` REST surface is addressed — there is no `DAEMON` constant,
   and routing it under `/workspaces` would conflate two repos. `qits-gateway` is
   deliberately absent from its own enum.
10. **Missing AGENTS.md** in `daemons/qits-workspace-daemon` and `libs/qits-userflows`.
    Every other populated submodule has one, with `CLAUDE.md` a **symlink** to it.
    (`qits-workspaces` was listed here and does have one.)
11. **`ResolveConflictService` changed sides without being ratified.** It was in
    `PROJ_REPO`, but it is ~90% workspace-scoped — creates workspaces via
    `WorkspaceService`, writes workspace metadata, persists prompt drafts, and reaches
    `agent.control.AgentLaunchService`; only its `CommitService.listIncomingCommits` call is
    repository-side. The qits-projects extraction removed it rather than import the
    workspace half, and the manifests now assign it to workspaces — but **no target carries
    it yet**. Confirm the side, then extract it.
12. **Eight assertions are unowned.** Each tested behaviour that belongs to a *different*
    target than the file it lived in, so the extraction dropped it rather than import
    another context. None are lost — §1 means the monolith still has every line — but no
    submodule carries them:
    - `branchDeletionRecordsNoRun` (was ci) → artifacts: `CiPostReceiveNotifier`'s DELETE filter
    - `listBranches` is-listed sanity check (was observability) → projects
    - `deleteRepositoryCascadesCommandAgentSessionRows` (was projects) → daemon-commands;
      this is the V32 `command_agent_session` FK bug class
    - `repositoryWithRecordedBootstrapRunDeletesCleanly` (was workspaces) → projects
    - `ServiceAttachTerminalTest`, `deliversToTheNewestRunningChat` (were workspaces) →
      beside `WorkspaceTerminalSessions` / `WorkspaceChatInbox` implementations
    - `WorkspaceSubmoduleProvisionTest` (was workspaces) → projects; it pinned an *accepted
      limitation* so that removing it would be a conscious change
    - `discoveryServerListsProjectsAndContextServers` (was projects) → monolith-only `/mcp`
13. **Work stranded by the `assign.py` service-side bug.** Now assigned to workspaces (§2)
    but not yet carried: the workspace↔container startup reconcile
    (`RepositoryDiscoveryService.discover()` + `reconcileWorkspaceVolumes()` + 3 tests) —
    `qits-workspaces` ships no startup reconciler today — plus five MCP tools and
    `TaskPromptMcpTools`/`ToolFilter`, which additionally need `telemetry.mcp.WorkspaceScope`
    from observability. `qits-workspaces` has no MCP surface.
14. **`qits-workspaces` suite flake.** One pristine-clone run in three had four
    `@TestProfile` service classes fail with `Failed to start quarkus`; it did not reproduce.
    Looks like resource contention across Quarkus restarts. Watch it in CI before trusting
    the gate.
15. **Compiled `.class` files are committed** under the daemon's
    `workspace-daemon-{files,detection}/target/`.
