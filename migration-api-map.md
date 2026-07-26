# Monolith → submodules: the complete API map

**Every** REST operation in `../qits`, one row each, with where it ended up. Companion to
[`migration-plan.md`](migration-plan.md), which maps *files*; this maps *entrypoints*.
Generated 2026-07-26, after the extraction of `qits-stt`, `qits-ci`, `qits-artifacts`,
`qits-observability`, `qits-projects`, the completion of `qits-workspaces`, and the
in-container git handover to `qits-workspace-daemon`.

**The monolith still serves all of these.** Per migration-plan.md §1 nothing was deleted from
`../qits`; "new home" is the submodule that now carries a copy and is the intended future owner.

## How this was produced, and why not from OpenAPI

Two things had to be established before any of it could be trusted:

**`../qits/docs/openapi.yml` is stale.** The checked-in spec has 128 operations; the source has
**145**. The 17 it is missing are every `ci/`, `artifacts/`, `otel/v1`, `capture` and SSE
endpoint — the spec predates those modules. It was last regenerated at
`68e077d4 refactor: finish the workspace-daemons -> workspace-services rename`. Do not use it
as an inventory.

**The submodules cannot generate one at all.** None of their `service/` modules carries the
`quarkus-maven-plugin`, because every extraction deliberately made `service/` a **library jar**
rather than a deployable (migration-plan.md §9 item 7). No augmentation ⇒ no schema. So there
is nothing to diff spec-against-spec, and there won't be until something packages these as
processes.

So the list below is extracted from source — class `@Path` + method verb + method `@Path`,
across `service/`, `auth/`, `artifacts/`, `ci/` and `epics/` — and the extractor was
**validated against the monolith's own generated spec first**: it reproduces all 128 of the
spec's operations with zero misses, and finds the 17 more the stale spec never captured. The
same extractor was then run over each submodule.

## The result in one line

| | Operations |
|---|---|
| Monolith total | **145** |
| Carried by a submodule (path unchanged) | 80 |
| Re-homed to the daemon at a **new path** | 6 |
| **Live total** | **86** |
| Still owed to a submodule — assigned, not carried | **15** |
| Pending the daemon extraction | 10 |
| Monolith-only by decision (featureflow, mutiny demos) | 30 |
| Unassigned (auth, settings) | 4 |

**Zero drift.** Not one submodule serves an operation that does not exist in the monolith at
the identical path — every extraction was a move, never a redesign. The only six paths that
changed are the ones deliberately handed to the daemon.

## ⚠ Before treating "new path" as a URL

The gateway routes **verbatim by prefix**: `/<segment>/*` → `qits-<segment>`, no rewriting.
The services kept their monolith paths, so only two of six currently serve anything their own
segment can reach:

| Service | Segment | Serves | Routable |
|---|---|---|---|
| `qits-artifacts` | `/artifacts` | `/artifacts/repositories/**` | ✅ |
| `qits-ci` | `/ci` | `/ci/**` | ✅ |
| `qits-projects` | `/projects` | `/projects/**` ✅ · `/repositories/**`, `/epics`, `/features`, `/tasks` ❌ | partial |
| `qits-workspaces` | `/workspaces` | `/repositories/{repoId}/workspaces/**`, `/events`, `/service-events`, `/technical-processes/**` | ❌ |
| `qits-stt` | `/stt` | `/speech/transcriptions` | ❌ |
| `qits-observability` | `/observability` | `/config.json`, `otel/v1`, `/repositories/**/telemetry` | ❌ |

Either the services adopt their segment as a prefix, the gateway grows rewriting, or the enum
changes. Nothing is deployed behind any of them yet, so deciding is still free.

---

## The full list

Status: ✅ live · 🕓 pending (daemon modules, not extracted) · ⚠️ **stranded** (assigned, but no
submodule carries it — §9 items 11–13) · ⬜ monolith-only by decision · ❔ open (§4).
Paths carry the `/api` prefix from `quarkus.rest.path`.


| # | Monolith operation | Status | New home | New path / note |
|---|---|---|---|---|
| 1 | `GET /api/action-configurations` | ⬜ monolith-only | — | featureflow, deferred (§9 item 6) |
| 2 | `POST /api/action-configurations` | ⬜ monolith-only | — | featureflow, deferred (§9 item 6) |
| 3 | `DELETE /api/action-configurations/{id}` | ⬜ monolith-only | — | featureflow, deferred (§9 item 6) |
| 4 | `GET /api/action-configurations/{id}` | ⬜ monolith-only | — | featureflow, deferred (§9 item 6) |
| 5 | `PUT /api/action-configurations/{id}` | ⬜ monolith-only | — | featureflow, deferred (§9 item 6) |
| 6 | `GET /api/agents/available` | 🕓 pending | qits-workspace-daemon | agents module, not extracted |
| 7 | `GET /api/artifacts/repositories` | ✅ live | qits-artifacts | unchanged |
| 8 | `PUT /api/artifacts/repositories/{repo}` | ✅ live | qits-artifacts | unchanged |
| 9 | `GET /api/artifacts/repositories/{repo}/blobs` | ✅ live | qits-artifacts | unchanged |
| 10 | `POST /api/artifacts/repositories/{repo}/blobs` | ✅ live | qits-artifacts | unchanged |
| 11 | `GET /api/artifacts/repositories/{repo}/blobs/{id}` | ✅ live | qits-artifacts | unchanged |
| 12 | `GET /api/auth/me` | ❔ open | — | auth strategy unresolved (§4) |
| 13 | `POST /api/capture` | ✅ live | qits-workspaces | unchanged |
| 14 | `POST /api/ci/events/post-receive` | ✅ live | qits-ci | unchanged |
| 15 | `GET /api/ci/repositories/{repoId}/runs` | ✅ live | qits-ci | unchanged |
| 16 | `GET /api/ci/runs/{runId}` | ✅ live | qits-ci | unchanged |
| 17 | `GET /api/commands` | 🕓 pending | qits-workspace-daemon | commands module, not extracted |
| 18 | `POST /api/commands` | 🕓 pending | qits-workspace-daemon | commands module, not extracted |
| 19 | `GET /api/commands/{commandId}` | 🕓 pending | qits-workspace-daemon | commands module, not extracted |
| 20 | `GET /api/commands/{commandId}/log` | 🕓 pending | qits-workspace-daemon | commands module, not extracted |
| 21 | `POST /api/commands/{commandId}/terminate` | 🕓 pending | qits-workspace-daemon | commands module, not extracted |
| 22 | `GET /api/config.json` | ✅ live | qits-observability | unchanged |
| 23 | `POST /api/context/chain` | ⬜ monolith-only | — | mutiny demo |
| 24 | `GET /api/context/trace` | ⬜ monolith-only | — | mutiny demo |
| 25 | `POST /api/echo/reactive` | ⬜ monolith-only | — | mutiny demo |
| 26 | `GET /api/echo/reactive/{message}` | ⬜ monolith-only | — | mutiny demo |
| 27 | `GET /api/epics/{epicId}/features` | ✅ live | qits-projects | unchanged |
| 28 | `POST /api/epics/{epicId}/features` | ✅ live | qits-projects | unchanged |
| 29 | `DELETE /api/epics/{id}` | ✅ live | qits-projects | unchanged |
| 30 | `GET /api/epics/{id}` | ✅ live | qits-projects | unchanged |
| 31 | `PUT /api/epics/{id}` | ✅ live | qits-projects | unchanged |
| 32 | `GET /api/epics/{id}/audit` | ✅ live | qits-projects | unchanged |
| 33 | `GET /api/events` | ✅ live | qits-workspaces | unchanged |
| 34 | `GET /api/feature-flow-configurations` | ⬜ monolith-only | — | featureflow, deferred (§9 item 6) |
| 35 | `DELETE /api/feature-flow-configurations/{id}` | ⬜ monolith-only | — | featureflow, deferred (§9 item 6) |
| 36 | `GET /api/feature-flow-configurations/{id}` | ⬜ monolith-only | — | featureflow, deferred (§9 item 6) |
| 37 | `PUT /api/feature-flow-configurations/{id}` | ⬜ monolith-only | — | featureflow, deferred (§9 item 6) |
| 38 | `GET /api/feature-flow-phase-actions` | ⬜ monolith-only | — | featureflow, deferred (§9 item 6) |
| 39 | `POST /api/feature-flow-phase-actions` | ⬜ monolith-only | — | featureflow, deferred (§9 item 6) |
| 40 | `DELETE /api/feature-flow-phase-actions/{id}` | ⬜ monolith-only | — | featureflow, deferred (§9 item 6) |
| 41 | `GET /api/feature-flow-phase-actions/{id}` | ⬜ monolith-only | — | featureflow, deferred (§9 item 6) |
| 42 | `PUT /api/feature-flow-phase-actions/{id}` | ⬜ monolith-only | — | featureflow, deferred (§9 item 6) |
| 43 | `GET /api/feature-flow-phase-steps` | ⬜ monolith-only | — | featureflow, deferred (§9 item 6) |
| 44 | `POST /api/feature-flow-phase-steps` | ⬜ monolith-only | — | featureflow, deferred (§9 item 6) |
| 45 | `DELETE /api/feature-flow-phase-steps/{id}` | ⬜ monolith-only | — | featureflow, deferred (§9 item 6) |
| 46 | `GET /api/feature-flow-phase-steps/{id}` | ⬜ monolith-only | — | featureflow, deferred (§9 item 6) |
| 47 | `PUT /api/feature-flow-phase-steps/{id}` | ⬜ monolith-only | — | featureflow, deferred (§9 item 6) |
| 48 | `GET /api/feature-flow-phases` | ⬜ monolith-only | — | featureflow, deferred (§9 item 6) |
| 49 | `POST /api/feature-flow-phases` | ⬜ monolith-only | — | featureflow, deferred (§9 item 6) |
| 50 | `DELETE /api/feature-flow-phases/{id}` | ⬜ monolith-only | — | featureflow, deferred (§9 item 6) |
| 51 | `GET /api/feature-flow-phases/{id}` | ⬜ monolith-only | — | featureflow, deferred (§9 item 6) |
| 52 | `PUT /api/feature-flow-phases/{id}` | ⬜ monolith-only | — | featureflow, deferred (§9 item 6) |
| 53 | `GET /api/features/{featureId}/tasks` | ✅ live | qits-projects | unchanged |
| 54 | `POST /api/features/{featureId}/tasks` | ✅ live | qits-projects | unchanged |
| 55 | `DELETE /api/features/{id}` | ✅ live | qits-projects | unchanged |
| 56 | `GET /api/features/{id}` | ✅ live | qits-projects | unchanged |
| 57 | `PUT /api/features/{id}` | ✅ live | qits-projects | unchanged |
| 58 | `POST /api/otel/v1/logs` | ✅ live | qits-observability | unchanged |
| 59 | `POST /api/otel/v1/metrics` | ✅ live | qits-observability | unchanged |
| 60 | `POST /api/otel/v1/traces` | ✅ live | qits-observability | unchanged |
| 61 | `GET /api/projects` | ✅ live | qits-projects | unchanged |
| 62 | `POST /api/projects` | ✅ live | qits-projects | unchanged |
| 63 | `DELETE /api/projects/{id}` | ✅ live | qits-projects | unchanged |
| 64 | `GET /api/projects/{id}` | ✅ live | qits-projects | unchanged |
| 65 | `PUT /api/projects/{id}` | ✅ live | qits-projects | unchanged |
| 66 | `GET /api/projects/{projectId}/epics` | ✅ live | qits-projects | unchanged |
| 67 | `POST /api/projects/{projectId}/epics` | ✅ live | qits-projects | unchanged |
| 68 | `GET /api/projects/{projectId}/feature-flow-configurations` | ⚠️ **stranded** | qits-workspaces | assigned, not carried (§9 item 13) |
| 69 | `POST /api/projects/{projectId}/feature-flow-configurations` | ⚠️ **stranded** | qits-workspaces | assigned, not carried (§9 item 13) |
| 70 | `GET /api/projects/{projectId}/repositories` | ✅ live | qits-projects | unchanged |
| 71 | `POST /api/projects/{projectId}/repositories` | ✅ live | qits-projects | unchanged |
| 72 | `DELETE /api/repositories/{repoId}` | ✅ live | qits-projects | unchanged |
| 73 | `GET /api/repositories/{repoId}` | ✅ live | qits-projects | unchanged |
| 74 | `GET /api/repositories/{repoId}/active-process` | ✅ live | qits-projects | unchanged |
| 75 | `DELETE /api/repositories/{repoId}/branches` | ✅ live | qits-projects | unchanged |
| 76 | `GET /api/repositories/{repoId}/branches` | ✅ live | qits-projects | unchanged |
| 77 | `POST /api/repositories/{repoId}/branches/cleanup` | ⚠️ **stranded** | qits-workspaces | assigned, not carried (§9 item 13) |
| 78 | `POST /api/repositories/{repoId}/branches/merge` | ⚠️ **stranded** | qits-workspaces | assigned, not carried (§9 item 13) |
| 79 | `GET /api/repositories/{repoId}/commits` | ✅ live | qits-projects | unchanged |
| 80 | `GET /api/repositories/{repoId}/commits/{commitHash}/changes` | ✅ live | qits-projects | unchanged |
| 81 | `GET /api/repositories/{repoId}/commits/{commitHash}/diff` | ✅ live | qits-projects | unchanged |
| 82 | `GET /api/repositories/{repoId}/events` | ⚠️ **stranded** | qits-workspaces | assigned, not carried (§9 item 13) |
| 83 | `GET /api/repositories/{repoId}/history` | ✅ live | qits-workspaces | unchanged |
| 84 | `GET /api/repositories/{repoId}/history/{id}` | ✅ live | qits-workspaces | unchanged |
| 85 | `PATCH /api/repositories/{repoId}/history/{id}` | ✅ live | qits-workspaces | unchanged |
| 86 | `PUT /api/repositories/{repoId}/main-branch` | ✅ live | qits-projects | unchanged |
| 87 | `POST /api/repositories/{repoId}/pull` | ✅ live | qits-projects | unchanged |
| 88 | `POST /api/repositories/{repoId}/push` | ✅ live | qits-projects | unchanged |
| 89 | `POST /api/repositories/{repoId}/sync` | ✅ live | qits-projects | unchanged |
| 90 | `GET /api/repositories/{repoId}/sync-status` | ✅ live | qits-projects | unchanged |
| 91 | `GET /api/repositories/{repoId}/workspaces` | ✅ live | qits-workspaces | unchanged |
| 92 | `POST /api/repositories/{repoId}/workspaces` | ✅ live | qits-workspaces | unchanged |
| 93 | `GET /api/repositories/{repoId}/workspaces/{workspaceId}/actions` | ⬜ monolith-only | — | featureflow, deferred (§9 item 6) |
| 94 | `POST /api/repositories/{repoId}/workspaces/{workspaceId}/actions/{actionId}/run` | ⬜ monolith-only | — | featureflow, deferred (§9 item 6) |
| 95 | `GET /api/repositories/{repoId}/workspaces/{workspaceId}/active-process` | ✅ live | qits-workspaces | unchanged |
| 96 | `GET /api/repositories/{repoId}/workspaces/{workspaceId}/agent-plugins` | 🕓 pending | qits-workspace-daemon | agents module, not extracted |
| 97 | `POST /api/repositories/{repoId}/workspaces/{workspaceId}/agent-plugins/{pluginId}/install` | 🕓 pending | qits-workspace-daemon | agents module, not extracted |
| 98 | `GET /api/repositories/{repoId}/workspaces/{workspaceId}/agent-sessions` | 🕓 pending | qits-workspace-daemon | agents module, not extracted |
| 99 | `POST /api/repositories/{repoId}/workspaces/{workspaceId}/agents` | 🕓 pending | qits-workspace-daemon | agents module, not extracted |
| 100 | `GET /api/repositories/{repoId}/workspaces/{workspaceId}/bootstrap-commands` | ✅ live | qits-workspaces | unchanged |
| 101 | `POST /api/repositories/{repoId}/workspaces/{workspaceId}/bootstrap-commands/run` | ✅ live | qits-workspaces | unchanged |
| 102 | `POST /api/repositories/{repoId}/workspaces/{workspaceId}/bootstrap-commands/{stepId}/run` | ✅ live | qits-workspaces | unchanged |
| 103 | `GET /api/repositories/{repoId}/workspaces/{workspaceId}/component-map` | ✅ live | qits-workspace-daemon | GET /component-map |
| 104 | `GET /api/repositories/{repoId}/workspaces/{workspaceId}/conflicts` | ⚠️ **stranded** | qits-workspaces | ResolveConflictService — side unratified (§9 item 11) |
| 105 | `POST /api/repositories/{repoId}/workspaces/{workspaceId}/delete-container` | ✅ live | qits-workspaces | unchanged |
| 106 | `GET /api/repositories/{repoId}/workspaces/{workspaceId}/detection` | ✅ live | qits-workspace-daemon | GET /detection |
| 107 | `POST /api/repositories/{repoId}/workspaces/{workspaceId}/discard` | ✅ live | qits-workspaces | unchanged |
| 108 | `POST /api/repositories/{repoId}/workspaces/{workspaceId}/ensure-container` | ✅ live | qits-workspaces | unchanged |
| 109 | `GET /api/repositories/{repoId}/workspaces/{workspaceId}/events` | ✅ live | qits-workspaces | unchanged |
| 110 | `POST /api/repositories/{repoId}/workspaces/{workspaceId}/fast-forward` | ✅ live | qits-workspace-daemon | POST /fast-forward?parent= |
| 111 | `GET /api/repositories/{repoId}/workspaces/{workspaceId}/files` | ✅ live | qits-workspace-daemon | GET /files?path= |
| 112 | `GET /api/repositories/{repoId}/workspaces/{workspaceId}/files/content` | ✅ live | qits-workspace-daemon | GET /files/content?path= |
| 113 | `GET /api/repositories/{repoId}/workspaces/{workspaceId}/incoming-commits` | ⚠️ **stranded** | qits-workspaces | ResolveConflictService — side unratified (§9 item 11) |
| 114 | `POST /api/repositories/{repoId}/workspaces/{workspaceId}/merge` | ✅ live | qits-workspaces | unchanged |
| 115 | `DELETE /api/repositories/{repoId}/workspaces/{workspaceId}/prompt-draft` | ⚠️ **stranded** | qits-workspaces | assigned, not carried (§9 item 13) |
| 116 | `GET /api/repositories/{repoId}/workspaces/{workspaceId}/prompt-draft` | ⚠️ **stranded** | qits-workspaces | assigned, not carried (§9 item 13) |
| 117 | `PUT /api/repositories/{repoId}/workspaces/{workspaceId}/prompt-draft` | ⚠️ **stranded** | qits-workspaces | assigned, not carried (§9 item 13) |
| 118 | `GET /api/repositories/{repoId}/workspaces/{workspaceId}/prompt-draft/attachments` | ⚠️ **stranded** | qits-workspaces | assigned, not carried (§9 item 13) |
| 119 | `POST /api/repositories/{repoId}/workspaces/{workspaceId}/prompt-draft/attachments` | ⚠️ **stranded** | qits-workspaces | assigned, not carried (§9 item 13) |
| 120 | `DELETE /api/repositories/{repoId}/workspaces/{workspaceId}/prompt-draft/attachments/{attachmentId}` | ⚠️ **stranded** | qits-workspaces | assigned, not carried (§9 item 13) |
| 121 | `POST /api/repositories/{repoId}/workspaces/{workspaceId}/prompt-refinements` | ⚠️ **stranded** | qits-workspaces | assigned, not carried (§9 item 13) |
| 122 | `POST /api/repositories/{repoId}/workspaces/{workspaceId}/recreate-container` | ✅ live | qits-workspaces | unchanged |
| 123 | `POST /api/repositories/{repoId}/workspaces/{workspaceId}/resolve-conflict` | ⚠️ **stranded** | qits-workspaces | ResolveConflictService — side unratified (§9 item 11) |
| 124 | `GET /api/repositories/{repoId}/workspaces/{workspaceId}/services` | ✅ live | qits-workspaces | unchanged |
| 125 | `POST /api/repositories/{repoId}/workspaces/{workspaceId}/services/{serviceId}/start` | ✅ live | qits-workspaces | unchanged |
| 126 | `POST /api/repositories/{repoId}/workspaces/{workspaceId}/services/{serviceId}/stop` | ✅ live | qits-workspaces | unchanged |
| 127 | `POST /api/repositories/{repoId}/workspaces/{workspaceId}/stop-container` | ✅ live | qits-workspaces | unchanged |
| 128 | `GET /api/repositories/{repoId}/workspaces/{workspaceId}/telemetry/errors` | ✅ live | qits-observability | unchanged |
| 129 | `GET /api/repositories/{repoId}/workspaces/{workspaceId}/telemetry/logs` | ✅ live | qits-observability | unchanged |
| 130 | `GET /api/repositories/{repoId}/workspaces/{workspaceId}/telemetry/metrics` | ✅ live | qits-observability | unchanged |
| 131 | `GET /api/repositories/{repoId}/workspaces/{workspaceId}/telemetry/slow-spans` | ✅ live | qits-observability | unchanged |
| 132 | `GET /api/repositories/{repoId}/workspaces/{workspaceId}/telemetry/traces/{traceId}` | ✅ live | qits-observability | unchanged |
| 133 | `POST /api/repositories/{repoId}/workspaces/{workspaceId}/update-from-parent` | ✅ live | qits-workspace-daemon | POST /update-from-parent?parent= |
| 134 | `GET /api/repositories/{repositoryId}/submodules` | ✅ live | qits-projects | unchanged |
| 135 | `POST /api/repositories/{repositoryId}/submodules/import` | ✅ live | qits-projects | unchanged |
| 136 | `POST /api/repositories/{repositoryId}/submodules/prepare` | ✅ live | qits-projects | unchanged |
| 137 | `GET /api/service-events` | ✅ live | qits-workspaces | unchanged |
| 138 | `GET /api/settings` | ❔ open | — | domain.setting unassigned (§4) |
| 139 | `GET /api/settings/{key}` | ❔ open | — | domain.setting unassigned (§4) |
| 140 | `PUT /api/settings/{key}` | ❔ open | — | domain.setting unassigned (§4) |
| 141 | `POST /api/speech/transcriptions` | ✅ live | qits-stt | unchanged |
| 142 | `DELETE /api/tasks/{id}` | ✅ live | qits-projects | unchanged |
| 143 | `GET /api/tasks/{id}` | ✅ live | qits-projects | unchanged |
| 144 | `PUT /api/tasks/{id}` | ✅ live | qits-projects | unchanged |
| 145 | `GET /api/technical-processes/{id}/events` | ✅ live | qits-workspaces | unchanged |

---

## Non-REST entrypoints

OpenAPI never described any of these, which is the other reason the spec could not have been
the inventory: raw vertx routes, websockets and the control-socket protocol are invisible to it.

### Raw vertx routes

| Monolith | Status | New home | New path / note |
|---|---|---|---|
| `/git/{repoId}/info/refs` | ✅ live | qits-artifacts | unchanged |
| `/git/{repoId}/git-upload-pack` | ✅ live | qits-artifacts | unchanged |
| `/git/{repoId}/git-receive-pack` | ✅ live | qits-artifacts | unchanged |
| `/git/{projectId}/{repoName}/info/refs` | ✅ live | qits-artifacts | via the optional `RepositoryNameResolver` port; absent ⇒ 404 |
| `/git/{projectId}/{repoName}/git-upload-pack` | ✅ live | qits-artifacts | same |
| `/git/{projectId}/{repoName}/git-receive-pack` | ✅ live | qits-artifacts | same |
| `/api/capture` CORS preflight | ✅ live | qits-workspaces | `CaptureCorsRoute`, unchanged |
| `/` service proxy (dev-server web views) | ✅ live | qits-workspaces | `ServiceProxyRoute`, unchanged |
| `/` SPA dev-mode fallback | ⬜ monolith-only | — | app shell |

### WebSockets

| Monolith | Status | New home | New path / note |
|---|---|---|---|
| `/api/workspace-daemon/{workspaceId}` (host end) | ✅ live | qits-workspaces | `DaemonControlSocket` + `WorkspaceDaemonRegistry` |
| `/api/terminal/repositories/{repoId}/remote-login` | ✅ live | qits-projects | `RemoteLoginTerminalSocket`, unchanged |
| `/api/terminal/commands/{commandId}` | 🕓 pending | qits-workspace-daemon | commands module |
| `/api/chat/commands/{commandId}` | 🕓 pending | qits-workspace-daemon | commands module |
| `/api/terminal/services/{repoId}/{workspaceId}/{serviceId}` | ❌ **removed** | — | see below |

The service terminal is the **only entrypoint deleted rather than moved**. It attached a browser
xterm to a dev server's tmux session over `docker exec` — the pre-daemon host-exec supervisor
that migration-plan.md §3.3 already listed as dead code to drop. Re-serving it means a
`RunCommand`-style PTY over the control socket (§9 item 3), not a new `docker exec`.
`qits-workspaces` declares `WorkspaceTerminalSessions` for exactly that; nothing implements it,
and absent ⇒ the socket refuses the upgrade.

### Daemon HTTP API — where six operations actually went

Bearer auth, constant-time compare, bound `0.0.0.0` (reachable from `qits-net`), unlike the
loopback hook webhook. Read endpoints are GET-only, the two integration endpoints POST-only, and
the pairing is checked before dispatch so a GET can never reach git.

| Monolith operation | Daemon endpoint |
|---|---|
| `GET /api/repositories/{repoId}/workspaces/{workspaceId}/files` | `GET /files?path=` |
| `GET /api/repositories/{repoId}/workspaces/{workspaceId}/files/content` | `GET /files/content?path=` |
| `GET /api/repositories/{repoId}/workspaces/{workspaceId}/detection` | `GET /detection` |
| `GET /api/repositories/{repoId}/workspaces/{workspaceId}/component-map` | `GET /component-map` |
| `POST /api/repositories/{repoId}/workspaces/{workspaceId}/fast-forward` | `POST /fast-forward?parent=` |
| `POST /api/repositories/{repoId}/workspaces/{workspaceId}/update-from-parent` | `POST /update-from-parent?parent=` |
| *(none — new)* | *(loopback)* agent lifecycle hook sink |

The first four replaced N `docker exec find/cat/realpath` per request with local `java.nio`; the
last two replaced `docker exec git`. Response bodies keep the host DTOs' field names, so the
frontend contract did not move with the endpoints.

### Daemon control socket — EVENTs

One websocket per workspace. The protocol module is **vendored into both repos**, same java
package, different artifactIds; any change must be mirrored and bump
`DaemonProtocol.CAPABILITY_VERSION`, and `DaemonCodecTest` runs on both sides to catch drift.
Nothing "moved" here — the socket *is* the boundary. What is recorded is which repo owns each end.

#### daemon → qits

| EVENT (wire tag) | Message | Host end |
|---|---|---|
| `hello` | `Hello` | qits-workspaces — capability version, daemon build identity |
| `heartbeat` | `Heartbeat` | qits-workspaces — liveness |
| `clientLog` | `DaemonLog` | qits-workspaces — log observers |
| `workspaceInfo` | `WorkspaceInfo` | qits-workspaces |
| `provisioned` | `Provisioned` | qits-workspaces — the **sole** provisioning path, no host-clone fallback |
| `provisionFailed` | `ProvisionFailed` | qits-workspaces |
| `configView` | `ConfigView` | qits-workspaces — `WorkspaceConfigReader` |
| `bootstrapStep` | `BootstrapStep` | qits-workspaces — `WorkspaceBootstrapDriver` |
| `bootstrapOutcome` | `BootstrapOutcome` | qits-workspaces |
| `bootstrapped` | `Bootstrapped` | qits-workspaces |
| `gitStatus` | `GitStatus(workspaceId, clean, head)` | qits-workspaces — `WorkspaceGitStatus.isClean` **and** `.head` |
| `agentActivity` | `AgentActivity` | qits-workspaces; the session-lineage write is daemon-agents' |
| `daemonEvent` ¹ | `ServiceTransition` | qits-workspaces — `ServiceSupervisor` (projection only; the daemon owns the process) |
| `commandChunk` | `CommandChunk` | 🕓 qits-workspace-daemon, commands module |
| `commandExit` | `CommandExit` | 🕓 qits-workspace-daemon, commands module |

`gitStatus` is the load-bearing one: it always carried `head`, and the host was discarding it.
Both halves are now cached, and the two gates that used to shell into the container — "is the
tree clean", "is the branch fully pushed" — read them and **fail closed**: unknown is refusal,
never permission.

#### qits → daemon

| EVENT (wire tag) | Message | Host end |
|---|---|---|
| `ack` | `Ack` | qits-workspaces |
| `describe` | `Describe` | qits-workspaces |
| `describeConfig` | `DescribeConfig` | qits-workspaces |
| `runBootstrap` | `RunBootstrap` | qits-workspaces — `WorkspaceBootstrapDriver` |
| `pullBranch` | `PullBranch` | qits-workspaces — `WorkspaceGitSync.pullFromOrigin` |
| `startDaemon` ¹ | `StartService` | qits-workspaces — `WorkspaceServiceDriver` |
| `signalDaemon` ¹ | `SignalService` | qits-workspaces — `WorkspaceServiceDriver` |
| `runCommand` | `RunCommand` | 🕓 qits-workspace-daemon, commands module |

¹ Wire tags keep their pre-rename `daemon*` spelling so stale daemon images keep speaking to a
newer qits. Retag with the next `CAPABILITY_VERSION` bump.

### MCP servers

| Monolith | Status | New home | Note |
|---|---|---|---|
| `repository` server — repository tools | ✅ live | qits-projects | unchanged |
| `repository` server — telemetry tools | ✅ live | qits-observability | behind two **fail-closed** ports (`RepositoryScopeGuard`, `WorkspaceLookup`) |
| `repository` server — workspace tools (`listWorkspaces`, `createWorkspace`, `cleanupBranch`, `integrateBranch`, `mergeParentIntoWorkspace`) | ⚠️ **stranded** | qits-workspaces | no MCP surface shipped |
| `repository` server — `TaskPromptMcpTools` / `TaskPromptToolFilter` | ⚠️ **stranded** | qits-workspaces | also needs `telemetry.mcp.WorkspaceScope` |
| `actions` server | ⬜ monolith-only | — | featureflow |
| `/mcp` discovery server | ⬜ monolith-only | — | app shell |

`qits-observability`'s MCP server is still *named* `"repository"` in a repo with no repository
tools; renaming changes the mount path and every configured agent URL, so it was reported rather
than changed. "Optional port" there means **deny**, not "skip the check" — both guards are
cross-project isolation checks.

---

## What is not reachable anywhere today

1. **15 stranded REST operations** — assigned to `qits-workspaces` but not carried: the whole
   prompt-draft surface (5), `/repositories/{repoId}/events`, both `/branches/{merge,cleanup}`,
   and the `ResolveConflictService` group (`conflicts`, `incoming-commits`, `resolve-conflict`)
   whose side is still unratified (§9 item 11).
2. **The entire workspace MCP surface** — 5 tools plus the task-prompt pair.
3. **The service terminal websocket** — needs the execution-seam flip (§9 item 3).
4. **Four of six extracted services** — path/segment mismatch, see the warning at the top.
