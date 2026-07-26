# Monolith → submodules: the entrypoint map

Every externally-reachable entrypoint in `../qits` and where it lives now. Companion to
[`migration-plan.md`](migration-plan.md), which maps *files*; this maps **APIs**.

Written 2026-07-26, after the extraction of `qits-stt`, `qits-ci`, `qits-artifacts`,
`qits-observability`, `qits-projects` and the completion of `qits-workspaces`.

**The monolith still serves all of these.** Per migration-plan.md §1 nothing was deleted
from `../qits`; "moved to" means a submodule now carries a copy that is the intended future
home. Status column:

| | |
|---|---|
| **live** | extracted, builds and tests green in its submodule |
| **pending** | assigned to a submodule that is not extracted yet (the daemon modules) |
| **stranded** | assigned, but no submodule actually carries it — migration-plan.md §9 items 12–13 |
| **monolith-only** | no target wants it |
| **open** | unassigned, migration-plan.md §4 |

---

## ⚠ Read this before using the "now" column as a URL

The gateway routes **verbatim by path prefix**: `/<segment>/*` → `qits-<segment>`, no
rewriting (`QitsService`, and its README's registry table). Extracted services mostly kept
their monolith paths, so **only two of the six currently serve paths their own gateway
segment can reach**:

| Service | Segment | Serves | Routable today |
|---|---|---|---|
| `qits-artifacts` | `/artifacts` | `/artifacts/repositories/**` | ✅ |
| `qits-ci` | `/ci` | `/ci`, `/ci/events` | ✅ |
| `qits-projects` | `/projects` | `/projects/**` ✅, but also `/repositories/**`, `/epics`, `/features`, `/tasks` | ❌ partial |
| `qits-workspaces` | `/workspaces` | `/repositories/{repoId}/workspaces/**`, `/events`, `/service-events`, `/technical-processes/**` | ❌ none |
| `qits-stt` | `/stt` | `/speech/transcriptions` | ❌ |
| `qits-observability` | `/observability` | `/config.json`, `otel/v1`, `/repositories/**/telemetry` | ❌ |

This is a genuine open question, not an oversight in the table below: either the services
adopt their segment as a path prefix, or the gateway grows rewriting, or the enum's segments
change. It has to be settled before any of these routes can go live behind the gateway.
Nothing is deployed behind them yet, so the cost of deciding is still zero.

---

## `artifacts/` — blob store

| Monolith | Now | Status |
|---|---|---|
| `GET/POST/DELETE /artifacts/repositories` | `qits-artifacts` · `RepositoryController` · unchanged | live |
| `GET/PUT/DELETE /artifacts/repositories/{repo}/blobs` | `qits-artifacts` · `BlobController` · unchanged | live |

## `githost/` — git smart-HTTP

Assigned to `qits-artifacts` rather than a `qits-repositories` service, whose name collided
with `domain.repository` (migration-plan.md §3.4, §9 item 2).

| Monolith | Now | Status |
|---|---|---|
| `/git/{repoId}/info/refs` | `qits-artifacts` · `GitHostRoutes` · unchanged | live |
| `/git/{repoId}/git-upload-pack` | `qits-artifacts` · unchanged | live |
| `/git/{repoId}/git-receive-pack` | `qits-artifacts` · unchanged | live |
| `/git/{projectId}/{repoName}/info/refs` | `qits-artifacts`, via the `RepositoryNameResolver` port | live |
| `/git/{projectId}/{repoName}/git-upload-pack` | same | live |
| `/git/{projectId}/{repoName}/git-receive-pack` | same | live |

The name-addressed three used to resolve through `domain.repository.persistence.RepositoryNameRepository`
directly. That table is `qits-projects`-owned and in another database, so the reach became an
**optional port**: absent implementation ⇒ the name-addressed scheme 404s and the id-addressed
scheme is unaffected. The assembling application supplies the ~5-line adapter.

## `ci/` — in-repo pipelines

| Monolith | Now | Status |
|---|---|---|
| `GET /ci/**` (runs, steps) | `qits-ci` · `CiRunController` · unchanged | live |
| `POST /ci/events` (post-receive intake) | `qits-ci` · `CiEventController` · unchanged | live |

`CiPostReceiveNotifier` (in `qits-artifacts`) POSTs to `qits.ci.intake-url`. That seam was
already HTTP inside the monolith and survived the split untouched.

## `epics/` — planning

| Monolith | Now | Status |
|---|---|---|
| `/epics` | `qits-projects` · `EpicController` · unchanged | live |
| `/features` | `qits-projects` · `FeatureController` · unchanged | live |
| `/tasks` | `qits-projects` · `TaskController` · unchanged | live |
| `/projects/{projectId}/epics` | `qits-projects` · `ProjectEpicsController` · unchanged | live |

Kept its own datasource and `db/epics/migration` lineage verbatim (migration-plan.md §7,
"own lineage, unaffected"). It is the module most likely to be lifted out again next.

## `domain.project` — projects

| Monolith | Now | Status |
|---|---|---|
| `/projects` | `qits-projects` · `ProjectController` · unchanged | live |
| `/projects/{id}/feature-flow-configurations` (2 routes) | **cut outright** — `featureflow` is monolith-only *and* deferred, so there was no other side to declare a port against | monolith-only |

## `domain.repository` — the package that genuinely splits

Split per class between `qits-projects` and `qits-workspaces` (`PROJ_REPO` / `WS_REPO` in
`assign.py`). The `service/` side splits with it — matching by directory instead is the bug
that stranded 24 files (migration-plan.md §2).

| Monolith | Now | Status |
|---|---|---|
| `/repositories` | `qits-projects` · `RepositoryController` · unchanged | live |
| `/repositories/{repositoryId}/submodules` | `qits-projects` · `RepositorySubmoduleController` · unchanged | live |
| `/repositories/{repoId}/workspaces` | `qits-workspaces` · `WorkspaceController` · unchanged | live |
| `/repositories/{repoId}/workspaces/{workspaceId}/fast-forward` | **`qits-workspace-daemon`** · `POST /fast-forward?parent=` | live |
| `/repositories/{repoId}/workspaces/{workspaceId}/update-from-parent` | **`qits-workspace-daemon`** · `POST /update-from-parent?parent=` | live |
| `/repositories/{repoId}/history` | `qits-workspaces` · `WorkspaceHistoryController` · unchanged | live |
| `/repositories/{repoId}/events` | `qits-workspaces` · `RepositoryEventsController` | **stranded** |
| `/repositories/{repoId}/workspaces/{workspaceId}/prompt-draft` | `qits-workspaces` · `WorkspacePromptDraftController` | **stranded** |
| `POST /repositories/{id}/branches/merge` | `qits-projects` (no REST caller carried) | **stranded** |
| `POST /repositories/{id}/branches/cleanup` | `qits-projects` (no REST caller carried) | **stranded** |

The two daemon rows are the only entrypoints that changed **host**, not just repo: both were
`docker exec git fetch/merge --ff-only/merge --no-edit/push` against the container's checkout.
They now run where the checkout is a local path, serialized behind the daemon's auto-push.
Response body keeps the host DTO's `output` field, so the frontend contract did not move.

## `domain.workspace` / `domain.bootstrap` / `domain.capture` / `domain.process` / `domain.service`

| Monolith | Now | Status |
|---|---|---|
| `/events` (global SSE) | `qits-workspaces` · `GlobalEventsController` · unchanged | live |
| `/repositories/{repoId}/workspaces/{workspaceId}/events` | `qits-workspaces` · `WorkspaceEventsController` · unchanged | live |
| `/repositories/{repoId}/workspaces/{workspaceId}/bootstrap-commands` | `qits-workspaces` · `WorkspaceBootstrapController` · unchanged | live |
| `/repositories/{repoId}/workspaces/{workspaceId}/services` | `qits-workspaces` · `WorkspaceServiceController` · unchanged | live |
| `/service-events` | `qits-workspaces` · `ServiceEventController` · unchanged | live |
| `/technical-processes/{id}/events` | `qits-workspaces` · `TechnicalProcessEventsController` · unchanged | live |
| `/api/capture` (raw vertx + CORS preflight) | `qits-workspaces` · `CaptureResource` + `CaptureCorsRoute` · unchanged | live |
| *(startup)* workspace↔container reconcile | `qits-workspaces` — **no startup reconciler shipped** | **stranded** |

## `domain.agent` / `domain.command` / `domain.chat` — the daemon modules

Not extracted. They carry the most §6 cut sites and come last, and §9 item 3 (the execution-seam
flip) is still open, which is *why* they remain host-side modules inside the daemon repo.

| Monolith | Now | Status |
|---|---|---|
| `/agents` | `qits-workspace-daemon` (agents module) | pending |
| `/repositories/{repoId}/workspaces/{workspaceId}/agents` | same | pending |
| `/repositories/{repoId}/workspaces/{workspaceId}/agent-plugins` | same | pending |
| `/repositories/{repoId}/workspaces/{workspaceId}/agent-sessions` | same | pending |
| `/repositories/{repoId}/workspaces/{workspaceId}/prompt-refinements` | same | pending |
| `/commands` | `qits-workspace-daemon` (commands module) | pending |

There is no `DAEMON` constant in `QitsService`, and routing these under `/workspaces` would
conflate two repos — open, §9 item 9.

## `domain.speech` — speech-to-text

| Monolith | Now | Status |
|---|---|---|
| `/speech/transcriptions` | `qits-stt` · `SpeechController` · unchanged | live |

Genuinely host-side and *not* workspace-scoped: a resident host python process plus a venv
bootstrapped with `pip install`. That is deliberate and is the reason it is its own service.

## `domain.telemetry` — observability

| Monolith | Now | Status |
|---|---|---|
| `otel/v1/**` (OTLP receiver) | `qits-observability` · `OtelReceiverResource` · unchanged | live |
| `/config.json` | `qits-observability` · `ConfigResource` · unchanged | live |
| `/repositories/{repoId}/workspaces/{workspaceId}/telemetry` | `qits-observability` · `WorkspaceTelemetryController` · unchanged | live |

Naming settled: `qits-observability` the submodule, `qits-telemetry` the maven module inside
it. The gateway constant moved `OTEL` → `OBSERVABILITY`, so the public segment is now
`/observability` (nothing was deployed behind `/otel`).

## `domain.setting`, `domain.featureflow`, and the app shell

| Monolith | Now | Status |
|---|---|---|
| `/settings` | undecided — follows `agent` into the daemon repo, or seeds `libs/qits-commons` | open |
| `/feature-flow-configurations`, `/feature-flow-phases`, `/feature-flow-phase-actions`, `/feature-flow-phase-steps`, `/action-configurations` | — | monolith-only |
| `/repositories/{repoId}/workspaces/{workspaceId}/actions` | — | monolith-only |
| `/context`, `/echo` (mutiny demos) | — | monolith-only |
| SPA dev-mode fallback route | — | monolith-only |
| `/` catch-all (app + SPA) | gateway `app-host` | live |

---

## WebSocket endpoints

| Monolith | Now | Status |
|---|---|---|
| `/api/workspace-daemon/{workspaceId}` — the daemon control socket, **host side** | `qits-workspaces` · `DaemonControlSocket` + `WorkspaceDaemonRegistry` | live |
| `/api/terminal/repositories/{repoId}/remote-login` | `qits-projects` · `RemoteLoginTerminalSocket` | live |
| `/api/terminal/commands/{commandId}` | `qits-workspace-daemon` (commands module) | pending |
| `/api/chat/commands/{commandId}` | `qits-workspace-daemon` (commands module) | pending |
| `/api/terminal/services/{repoId}/{workspaceId}/{serviceId}` | **removed** — it attached a browser xterm to a service's tmux session over `docker exec`; the daemon owns service processes | see below |

The service terminal is the one entrypoint that was **deleted rather than moved**. Its host-exec
path (`ContainerRuntime.attachServiceCommand` → `exec tmux -L … attach`) was the pre-daemon
supervisor that migration-plan.md §3.3 already listed as dead code to drop. Re-serving it means
a `RunCommand`-style PTY over the daemon control socket (§9 item 3), not a new `docker exec`.
`qits-workspaces` declares the `WorkspaceTerminalSessions` port for exactly that; nothing
implements it yet, and absent ⇒ the socket refuses the upgrade.

---

## Daemon control socket — EVENTs

One websocket per workspace, `/api/workspace-daemon/{workspaceId}`. The protocol module is
**vendored into both repos** with the same java package and different artifactIds; a change to
either must be mirrored and bump `DaemonProtocol.CAPABILITY_VERSION`. `DaemonCodecTest` runs on
both sides and is what catches drift.

Neither side "moved" — the socket is the boundary itself. What changed is which repo owns each
end: the **host** end is `qits-workspaces`, the **daemon** end is `qits-workspace-daemon`.

### daemon → qits

| EVENT (wire tag) | Message | Host end, now |
|---|---|---|
| `hello` | `Hello` | `qits-workspaces` · registry: capability version, daemon build identity |
| `heartbeat` | `Heartbeat` | `qits-workspaces` · liveness |
| `clientLog` | `DaemonLog` | `qits-workspaces` · log observers |
| `workspaceInfo` | `WorkspaceInfo` | `qits-workspaces` |
| `provisioned` | `Provisioned` | `qits-workspaces` · `WorkspaceDaemonProvisioner` — the **sole** provisioning path, no host-clone fallback |
| `provisionFailed` | `ProvisionFailed` | same |
| `configView` | `ConfigView` | `qits-workspaces` · `WorkspaceConfigReader` |
| `bootstrapStep` | `BootstrapStep` | `qits-workspaces` · `WorkspaceBootstrapDriver` |
| `bootstrapOutcome` | `BootstrapOutcome` | same |
| `bootstrapped` | `Bootstrapped` | same |
| `gitStatus` | `GitStatus(workspaceId, clean, head)` | `qits-workspaces` · `WorkspaceGitStatus.isClean` **and** `.head` |
| `agentActivity` | `AgentActivity` | `qits-workspaces` · `WorkspaceAgentActivity`; the session-lineage write is daemon-agents' |
| `daemonEvent` ¹ | `ServiceTransition` | `qits-workspaces` · `ServiceSupervisor` (projection only — the daemon owns the process) |
| `commandChunk` | `CommandChunk` | `qits-workspace-daemon` (commands module) — pending |
| `commandExit` | `CommandExit` | same — pending |

`gitStatus` is worth singling out: it always carried `head`, and the host was discarding it.
Both halves of that frame are now cached, and the two host gates that used to shell into the
container — "is the tree clean", "is the branch fully pushed" — read them and **fail closed**:
unknown is refusal, never permission.

### qits → daemon

| EVENT (wire tag) | Message | Host end, now |
|---|---|---|
| `ack` | `Ack` | `qits-workspaces` |
| `describe` | `Describe` | `qits-workspaces` |
| `describeConfig` | `DescribeConfig` | `qits-workspaces` |
| `runBootstrap` | `RunBootstrap` | `qits-workspaces` · `WorkspaceBootstrapDriver` |
| `pullBranch` | `PullBranch` | `qits-workspaces` · `WorkspaceGitSync.pullFromOrigin` |
| `startDaemon` ¹ | `StartService` | `qits-workspaces` · `WorkspaceServiceDriver` |
| `signalDaemon` ¹ | `SignalService` | same |
| `runCommand` | `RunCommand` | `qits-workspace-daemon` (commands module) — pending |

¹ Wire tags kept their pre-rename `daemon*` spelling so stale daemon images keep speaking to a
newer qits. Retag with the next `CAPABILITY_VERSION` bump.

---

## Daemon-owned HTTP

Not in the monolith at all — these replaced host-side `docker exec` work with local
`java.nio` / in-process git. Listed for completeness, because they are where several monolith
behaviours ended up.

| Endpoint | Replaced |
|---|---|
| `GET /files?path=` | N `docker exec find/cat/realpath` per request, host-parsed |
| `GET /files/content?path=` | same |
| `GET /detection` | host-side `FrameworkDetectionService` |
| `GET /component-map` | host-side `ComponentMapService` |
| `POST /fast-forward?parent=` | host `POST …/workspaces/{id}/fast-forward` |
| `POST /update-from-parent?parent=` | host `POST …/workspaces/{id}/update-from-parent` |
| *(loopback)* hook webhook | the coding agent's lifecycle hook sink |

Bearer-token auth, constant-time compare, bound `0.0.0.0` (reachable from `qits-net`) — unlike
the loopback hook webhook. The read endpoints are GET-only and the two integration endpoints
POST-only; the pairing is checked before dispatch so a GET can never reach git.

## MCP servers

| Monolith | Now | Status |
|---|---|---|
| `repository` MCP server | `qits-projects` (`RepositoryMcpTools` etc.) | live |
| `repository` MCP server — telemetry tools | `qits-observability`, behind two **fail-closed** ports (`RepositoryScopeGuard`, `WorkspaceLookup`) | live |
| `repository` MCP server — workspace tools (`listWorkspaces`, `createWorkspace`, `cleanupBranch`, `integrateBranch`, `mergeParentIntoWorkspace`) | `qits-workspaces` — no MCP surface shipped | **stranded** |
| `repository` MCP server — `TaskPromptMcpTools` / `TaskPromptToolFilter` | `qits-workspaces`; also needs `telemetry.mcp.WorkspaceScope` | **stranded** |
| `actions` MCP server | — | monolith-only |
| `/mcp` discovery server | — | monolith-only |

`qits-observability`'s MCP server is still *named* `"repository"` in a repo containing no
repository tools — renaming it would change the mount path and every configured agent URL, so
it was reported rather than changed. Note also that "optional port" there means **deny**, not
"skip the check": both guards fail closed, because they are cross-project isolation checks.

---

## Summary of what is not reachable anywhere

1. Every **stranded** row above — assigned but uncarried (§9 items 12–13).
2. The service terminal websocket — needs the execution-seam flip (§9 item 3).
3. All six extracted services except `qits-artifacts` and `qits-ci` — path/segment mismatch,
   see the warning at the top.
