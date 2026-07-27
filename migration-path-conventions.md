# API path conventions: current → proposed

Status: **adopted across all nine repos.** Written and executed 2026-07-27.
Companion to [`migration-api-map.md`](migration-api-map.md), which records where each entrypoint
*went*. This one asks where each entrypoint *should be addressed*.

**What landed is recorded in [§6 Resolution](#6-resolution) at the bottom.** Everything above it is
the original proposal, **unedited** — including the three things it got wrong, which §6.1 names
rather than silently correcting in place. Read §6 before acting on any row above it.

## The convention

    /<segment>/(api|mcp)/<entity>/...

`<segment>` is the gateway segment — the service name without the `qits-` prefix, matching
`QitsService` in the gateway: `artifacts`, `ci`, `observability`, `projects`, `stt`, `workspaces`.

The gateway routes **verbatim by prefix**, `/<segment>/*` → `qits-<segment>`, with no rewriting. So
this convention is not cosmetic: it is the difference between a service being reachable through its
own segment and not being reachable at all. Four of six are currently in the second category
(`migration-api-map.md`, ⚠ section).

Two things fall out immediately, and both are in the table below:

- **`/api/config.json` does not belong to qits-observability at all** — it is web-component
  configuration, and the gateway serves the web components. It moves there (§4 item 2).
- **`/api/repositories/{repoId}/workspaces/{workspaceId}/telemetry/*` is addressed by another
  context's aggregate.** Three services currently serve routes under `/api/repositories/...`:
  projects owns the repository, workspaces owns branches and workspaces beneath it, observability
  owns telemetry beneath that. A prefix-routing gateway cannot separate them. This is the single
  biggest reason the convention is worth adopting.

---

## 1. A defect this document depends on

**`workspaceId` is not globally unique, and one existing path already assumes it is.**

`WorkspaceService.toWorkspaceSlug` derives the workspace id from the *branch name* — sanitised to
`[A-Za-z0-9_-]`, truncated at 64 chars, falling back to the literal `"main"` when blank. There is no
repository component, and `V1__init.sql` explicitly carries **no unique constraint** on
`(repository_id, workspace_id)` (V10 dropped V1's, because resolved rows accumulate).

So two repositories each with a `main` branch produce two workspaces both called `main`.

Container naming already accounts for this — `WorkspaceContainerFactory.containerName(workspaceId,
repoId)` includes a repo prefix. **The daemon control socket does not:**

```java
@WebSocket(path = "/api/workspace-daemon/{workspaceId}")   // DaemonControlSocket:29
registry.register(workspaceId, connection);                // DaemonControlSocket:41
clients.put(workspaceId, new DaemonConnection(connection)); // WorkspaceDaemonRegistry:186
```

The registry is keyed on `workspaceId` alone. Two daemons whose workspaces share a slug appear to
collide on that key. **That specific consequence still needs confirming** — nobody has traced whether
registration is scoped upstream — but the non-uniqueness itself is not in doubt, and a second,
confirmed defect follows from the same root.

**Both are defects, not constraints to design around.** They are written up in
[`priority-bug.md`](priority-bug.md), and the specified behaviour is:

- at most one ACTIVE workspace per `(repositoryId, branch)` — the branch is the resource;
- a workspace is identified by a **surrogate key**, whose entire specification is "unique". Pairing
  it with `repositoryId` to identify a row is redundant, because a unique id is already unique.

**That key already exists.** `Workspace` has `@Id @GeneratedValue public Long id` and has since V1;
`workspace_event`, `workspace_bootstrap_run` and `workspace_prompt_draft` all FK to `workspace(id)`.
The string `workspaceId` is a branch-derived *label* that was pressed into service as an identifier —
and `WorkspaceCommandHistory:22` already documents why that was wrong: *"Keyed by the row id rather
than `workspaceId` because the latter is reusable once a workspace resolves."*

So nothing needs generating. The fix externalises the `Long` that is already the durable identity
internally.

> **This document assumes the fix.** Workspace routes below are therefore
> `/workspaces/api/workspaces/{id}/...`, with **no repository segment**. That is the shape
> a surrogate key implies, and adopting the paths before the fix would mean shipping URLs that
> cannot address a workspace unambiguously.

**Sequencing, because it matters:** `priority-bug.md` lands *before* the workspace half of this
document. The other five services have no such dependency and can move independently.

## 1a. `services` and `bootstrap-commands` move to the daemon — the host routes are removed

**Decision taken.** Six host-side routes are to be **deleted**, not renamed:

```
GET  /api/repositories/{repoId}/workspaces/{workspaceId}/services
POST /api/repositories/{repoId}/workspaces/{workspaceId}/services/{serviceId}/start
POST /api/repositories/{repoId}/workspaces/{workspaceId}/services/{serviceId}/stop
GET  /api/repositories/{repoId}/workspaces/{workspaceId}/bootstrap-commands
POST /api/repositories/{repoId}/workspaces/{workspaceId}/bootstrap-commands/run
POST /api/repositories/{repoId}/workspaces/{workspaceId}/bootstrap-commands/{stepId}/run
```

Both run **inside the container**, and in both cases the host only forwards. They are the same
defect twice, which is why they are one section:

```
WorkspaceServiceController   → ServiceSupervisor (host)      → WorkspaceServiceDriver
                                                             → StartService / SignalService
WorkspaceBootstrapController → WorkspaceBootstrapRunner      → WorkspaceBootstrapDriver
                                                             → RunBootstrap
                                                             → the control socket → the daemon
```

The daemon's own `ServiceSupervisor` and `BootstrapRunner` do the work. The host keeps a
*projection*: `service_event` and the run record in `workspace_bootstrap_run`.

These are the **last two capabilities still shaped this way**. Files, detection, component-map,
fast-forward, update-from-parent, commands, agents, agent-plugins, prompt-refinements and both
interactive websockets all took their addressing into the daemon's own HTTP API when their execution
moved, and the host routes were deleted (`migration-api-map.md`, "Daemon HTTP API"). Services and
bootstrap kept a host surface for no reason that generalises. Removing them finishes a migration that
was left one step short.

### What removal has to account for

These were the arguments for keeping the surface host-side. They were raised, and the decision is to
proceed anyway — so they are **work items, not objections**:

1. **Both host-side projections survive a container recreate; daemon state does not.** `service_event`
   is a host table given no FK deliberately, so events "outlive the row" — diagnostic history.
   `workspace_bootstrap_run` is a host table too (FK to `workspace(id)`, so it dies with the
   workspace but survives any number of container recreates). The daemon has **no datasource at
   all** — no `quarkus-jdbc-*`, no Hibernate in any of its poms — and its state is
   container-lifetime-scoped by design (`migration-plan.md` §9 item 17).
   **Recommended split for both:** the daemon owns the API and the execution; the host keeps the
   record and the feed. Nothing about deleting these six routes requires losing either — service
   transitions and bootstrap steps already arrive over the **control socket**
   (`daemonEvent`/`ServiceTransition`, `bootstrapStep`/`bootstrapOutcome`), not through these
   endpoints.
2. **Two host-side triggers are not REST-driven and must keep working.** Both surfaces auto-run, and
   neither path goes through a controller:
   - `WorkspaceBootstrapRunner.onContainerStarted(@ObservesAsync WorkspaceContainerStarted)` runs the
     chain on a **fresh provision**, then fires `ReadyForServices`;
   - `ServiceLifecycleCoupler:76` then calls `supervisor.start(...)` for each autostart service.

   So the container-provision → bootstrap → services sequence is host-orchestrated today and is
   untouched by removing the REST surface. Whether that orchestration should also move into the
   daemon is a **separate, larger question** — it would have to answer how a container knows to
   bootstrap and start itself before anything has asked it to.
3. **`ServiceProxyRoute` stays.** It fronts the dev server's published port from outside the
   container and cannot move into it. `/workspaces/service/{id}/{serviceId}/*` is unaffected by this
   removal and is **not** marked for deletion.
4. **Container lifecycle stays host-owned.** Both starting a service and running a bootstrap chain
   presuppose a running container, and `ensureContainer` is the host's. A daemon-owned API can assume
   a container, since it *is* one — but a caller that hits it before the container exists gets a
   connection failure rather than a lifecycle error, which is a UX change to design for.
5. **Addressability is the real blocker, and it is not specific to either surface.** The daemon's
   REST surface has **no gateway route and no injected `QITS_WORKSPACE_DAEMON_API_TOKEN`**, so its
   HTTP API does not bind at all in a host-created container (`migration-plan.md` §9 item 16).
   Twelve operations and two websockets already sit behind that. Moving services and bootstrap there
   adds six more to the same queue — it does not create the problem, but it does mean **these routes
   cannot be deleted until §9 item 16 is resolved**, or the capabilities go dark.

### Sequencing

1. Resolve `migration-plan.md` §9 item 16 — gateway constant plus API-token injection for the daemon.
2. Add the endpoints to the daemon's `WorkspaceApi`. It serves **neither** `/services` nor
   `/bootstrap-commands` today (verified against `WorkspaceApi.java`):
   - `GET /services`, `POST /services/{id}/start`, `POST /services/{id}/stop`;
   - `GET /bootstrap-commands`, `POST /bootstrap-commands/run`,
     `POST /bootstrap-commands/{stepId}/run`.
3. Keep the host projections: `service_event` + its SSE feed, `workspace_bootstrap_run`, and
   `ServiceProxyRoute`.
4. Delete `WorkspaceServiceController` and `WorkspaceBootstrapController` — **and nothing else with
   them.** Each has a host-side collaborator with non-REST callers that stay:

   | Deleted | Stays, and why |
   |---|---|
   | `WorkspaceServiceController` | `ServiceSupervisor` — `ServiceLifecycleCoupler:76` auto-starts services on `ReadyForServices`, and `ServiceProxyRoute` reads its state to resolve the proxy port |
   | `WorkspaceBootstrapController` | `WorkspaceBootstrapRunner` — `onContainerStarted(@ObservesAsync)` auto-runs the chain on fresh provision and then fires `ReadyForServices` |

   So `ServiceSupervisor`, `WorkspaceBootstrapRunner`, both driver ports and the
   `StartService`/`SignalService`/`RunBootstrap` EVENTs stay. What is removed is the *externally
   addressable* surface, not the host's ability to drive and observe either.
5. **`workspace_bootstrap_run` loses its only external reader — decide what that table is for.**
   Traced: the run record is touched by `BootstrapRun`, `BootstrapRunRepository`,
   `BootstrapRunService`, `BootstrapRunMapper`, `WorkspaceBootstrapRunner` and
   `WorkspaceBootstrapController` — and by nothing else. `WorkspaceHistoryService` does **not** read
   it. So once the controller is deleted, the table is written by the runner and read by no one.

   That does not make the table wrong, but it does make "keep the host projection for durability"
   (item 1) hollow for bootstrap specifically: durable history nobody can query is not history.
   Either give it a reader — the workspace history surface is the obvious home, and it is where
   somebody would look for "did this workspace bootstrap cleanly?" — or drop the table with the
   controller and accept that bootstrap state is container-lifetime-scoped like the daemon's other
   state. **Do not leave it write-only by omission.**

   `BootstrapRunService` itself stays either way: `WorkspaceBootstrapRunner` depends on it, and the
   runner is not going anywhere (item 2).

## 2. What the protocol fixes, and what it does not

Three families of path are not ours to choose freely. Verified empirically, not assumed:

- **Git smart-HTTP imposes no root.** Git treats the URL as an opaque base and appends
  `/info/refs?service=git-upload-pack|git-receive-pack`, then `POST <base>/git-upload-pack` or
  `<base>/git-receive-pack`. Confirmed against a raw listener: a base of
  `/deeply/nested/anything/at/all/myrepo` and a push to `/artifacts/git/someproj/somerepo` both
  produced exactly the expected handshake. **`/git` is this codebase's convention, nothing more** —
  but the *suffixes* are fixed, and the id-addressed vs. name-addressed forms are distinguished by
  path *length*, which any new prefix must preserve.
- **OTLP fixes the suffix, not the base.** SDKs append `/v1/{traces,logs,metrics}` to
  `OTEL_EXPORTER_OTLP_ENDPOINT`. The base is ours; `/v1/<signal>` is not.
- **Quarkus management endpoints** (`/q/openapi`, `/q/swagger-ui`) sit outside `quarkus.rest.path`
  and move only via `quarkus.http.non-application-root-path`.

## 3. The table

`{repoId}`, `{workspaceId}` etc. are path parameters. Rows marked **⚠** carry a decision, expanded
in §4. Nothing here is implemented.

### qits-observability → `/observability`

| Current path (full) | Proposed |
|---|---|
| `POST /api/otel/v1/traces` | `POST /observability/api/otel/v1/traces` |
| `POST /api/otel/v1/logs` | `POST /observability/api/otel/v1/logs` |
| `POST /api/otel/v1/metrics` | `POST /observability/api/otel/v1/metrics` |
| `GET /api/config.json` | 🗑 **REMOVE from this service** — moves to the gateway (§4 item 2) |
| `GET /api/repositories/{repoId}/workspaces/{workspaceId}/telemetry/errors` | `GET /observability/api/telemetry/errors?repositoryId=&workspaceId=` |
| `GET /api/repositories/{repoId}/workspaces/{workspaceId}/telemetry/logs` | `GET /observability/api/telemetry/logs?repositoryId=&workspaceId=` |
| `GET /api/repositories/{repoId}/workspaces/{workspaceId}/telemetry/metrics` | `GET /observability/api/telemetry/metrics?repositoryId=&workspaceId=` |
| `GET /api/repositories/{repoId}/workspaces/{workspaceId}/telemetry/slow-spans` | `GET /observability/api/telemetry/slow-spans?repositoryId=&workspaceId=` |
| `GET /api/repositories/{repoId}/workspaces/{workspaceId}/telemetry/traces/{traceId}` | `GET /observability/api/telemetry/traces/{traceId}?repositoryId=&workspaceId=` |
| `/mcp/repository` (server name `repository`) | `/observability/mcp` — server renamed too |
| `/q/openapi`, `/q/swagger-ui` | `/observability/q/openapi`, `/observability/q/swagger-ui` |

### qits-stt → `/stt`

| Current path (full) | Proposed |
|---|---|
| `POST /api/speech/transcriptions` | `POST /stt/api/transcriptions` |
| `/q/openapi`, `/q/swagger-ui` | `/stt/q/openapi`, `/stt/q/swagger-ui` |

The only service already consistent in shape; it just gains its segment. `speech` → `transcriptions`
because the segment already says `stt`.

### qits-ci → `/ci`

| Current path (full) | Proposed |
|---|---|
| `POST /api/ci/events/post-receive` | `POST /ci/api/events/post-receive` |
| `GET /api/ci/repositories/{repoId}/runs` | `GET /ci/api/runs?repositoryId={repoId}` |
| `GET /api/ci/runs/{runId}` | `GET /ci/api/runs/{runId}` |
| `/q/openapi`, `/q/swagger-ui` | `/ci/q/openapi`, `/ci/q/swagger-ui` |

Already routable today (`/ci/**` under segment `/ci`) — it just carries a redundant `ci` segment
that becomes `api` instead. Note the runs listing is currently addressed under another context's
aggregate (`/repositories/{repoId}/runs`); the proposal makes `runs` the entity and the repository a
filter.

### qits-artifacts → `/artifacts`

| Current path (full) | Proposed |
|---|---|
| `GET /api/artifacts/repositories` | `GET /artifacts/api/repositories` |
| `PUT /api/artifacts/repositories/{repo}` | `PUT /artifacts/api/repositories/{repo}` |
| `GET /api/artifacts/repositories/{repo}/blobs` | `GET /artifacts/api/repositories/{repo}/blobs` |
| `POST /api/artifacts/repositories/{repo}/blobs` | `POST /artifacts/api/repositories/{repo}/blobs` |
| `GET /api/artifacts/repositories/{repo}/blobs/{id}` | `GET /artifacts/api/repositories/{repo}/blobs/{id}` |
| `GET /git/{repoId}/info/refs` | `GET /artifacts/git/{repoId}/info/refs` |
| `POST /git/{repoId}/git-upload-pack` | `POST /artifacts/git/{repoId}/git-upload-pack` |
| `POST /git/{repoId}/git-receive-pack` | `POST /artifacts/git/{repoId}/git-receive-pack` |
| `GET /git/{projectId}/{repoName}/info/refs` | `GET /artifacts/git/{projectId}/{repoName}/info/refs` |
| `POST /git/{projectId}/{repoName}/git-upload-pack` | `POST /artifacts/git/{projectId}/{repoName}/git-upload-pack` |
| `POST /git/{projectId}/{repoName}/git-receive-pack` | `POST /artifacts/git/{projectId}/{repoName}/git-receive-pack` |
| `/q/openapi`, `/q/swagger-ui` | `/artifacts/q/openapi`, `/artifacts/q/swagger-ui` |

`artifacts.repositories` is a *blob-store* repository (a named bucket of CI artifacts), not a
`domain.repository` — the collision of the word is pre-existing and this move does not fix it.
`/artifacts/api/blobs?repository=` would be the stricter reading of the convention; flagged in §4.

`git` is deliberately proposed as a **third second-level segment** alongside `api` and `mcp`, not as
`/artifacts/api/git/...` — it is a wire protocol spoken by `git`, not a JSON API, and it appears in
no OpenAPI document.

### qits-projects → `/projects`

| Current path (full) | Proposed |
|---|---|
| `GET /api/projects` | `GET /projects/api/projects` |
| `POST /api/projects` | `POST /projects/api/projects` |
| `GET /api/projects/{id}` | `GET /projects/api/projects/{id}` |
| `PUT /api/projects/{id}` | `PUT /projects/api/projects/{id}` |
| `DELETE /api/projects/{id}` | `DELETE /projects/api/projects/{id}` |
| `GET /api/projects/{projectId}/epics` | `GET /projects/api/projects/{projectId}/epics` |
| `POST /api/projects/{projectId}/epics` | `POST /projects/api/projects/{projectId}/epics` |
| `GET /api/projects/{projectId}/repositories` | `GET /projects/api/projects/{projectId}/repositories` |
| `POST /api/projects/{projectId}/repositories` | `POST /projects/api/projects/{projectId}/repositories` |
| `GET /api/epics/{id}` | `GET /projects/api/epics/{id}` |
| `PUT /api/epics/{id}` | `PUT /projects/api/epics/{id}` |
| `DELETE /api/epics/{id}` | `DELETE /projects/api/epics/{id}` |
| `GET /api/epics/{id}/audit` | `GET /projects/api/epics/{id}/audit` |
| `GET /api/epics/{epicId}/features` | `GET /projects/api/epics/{epicId}/features` |
| `POST /api/epics/{epicId}/features` | `POST /projects/api/epics/{epicId}/features` |
| `GET /api/features/{id}` | `GET /projects/api/features/{id}` |
| `PUT /api/features/{id}` | `PUT /projects/api/features/{id}` |
| `DELETE /api/features/{id}` | `DELETE /projects/api/features/{id}` |
| `GET /api/features/{featureId}/tasks` | `GET /projects/api/features/{featureId}/tasks` |
| `POST /api/features/{featureId}/tasks` | `POST /projects/api/features/{featureId}/tasks` |
| `GET /api/tasks/{id}` | `GET /projects/api/tasks/{id}` |
| `PUT /api/tasks/{id}` | `PUT /projects/api/tasks/{id}` |
| `DELETE /api/tasks/{id}` | `DELETE /projects/api/tasks/{id}` |
| `GET /api/repositories/{repoId}` | `GET /projects/api/repositories/{repoId}` |
| `DELETE /api/repositories/{repoId}` | `DELETE /projects/api/repositories/{repoId}` |
| `GET /api/repositories/{repoId}/active-process` | `GET /projects/api/repositories/{repoId}/active-process` |
| `GET /api/repositories/{repoId}/branches` | `GET /projects/api/repositories/{repoId}/branches` |
| `DELETE /api/repositories/{repoId}/branches` | `DELETE /projects/api/repositories/{repoId}/branches` |
| `GET /api/repositories/{repoId}/commits` | `GET /projects/api/repositories/{repoId}/commits` |
| `GET /api/repositories/{repoId}/commits/{commitHash}/changes` | `GET /projects/api/repositories/{repoId}/commits/{commitHash}/changes` |
| `GET /api/repositories/{repoId}/commits/{commitHash}/diff` | `GET /projects/api/repositories/{repoId}/commits/{commitHash}/diff` |
| `PUT /api/repositories/{repoId}/main-branch` | `PUT /projects/api/repositories/{repoId}/main-branch` |
| `POST /api/repositories/{repoId}/pull` | `POST /projects/api/repositories/{repoId}/pull` |
| `POST /api/repositories/{repoId}/push` | `POST /projects/api/repositories/{repoId}/push` |
| `POST /api/repositories/{repoId}/sync` | `POST /projects/api/repositories/{repoId}/sync` |
| `GET /api/repositories/{repoId}/sync-status` | `GET /projects/api/repositories/{repoId}/sync-status` |
| `GET /api/repositories/{repositoryId}/submodules` | `GET /projects/api/repositories/{repositoryId}/submodules` |
| `POST /api/repositories/{repositoryId}/submodules/import` | `POST /projects/api/repositories/{repositoryId}/submodules/import` |
| `POST /api/repositories/{repositoryId}/submodules/prepare` | `POST /projects/api/repositories/{repositoryId}/submodules/prepare` |
| `WS /api/terminal/repositories/{repoId}/remote-login` | `WS /projects/api/repositories/{repoId}/remote-login` |
| `/mcp/repository` (server name `repository`) | `/projects/mcp` |
| `/q/openapi`, `/q/swagger-ui` | `/projects/q/openapi`, `/projects/q/swagger-ui` |

Note `{repoId}` and `{repositoryId}` are used inconsistently *today* across the submodule routes;
worth normalising in the same pass.

### qits-workspaces → `/workspaces`

**A workspace is not a sub-resource of a repository here.** This context does not own repositories —
it holds a repository *id as a string*, with no foreign key and no join, in a different database
(`AGENTS.md`: "Never add a JPA relation to another context's entity"). Addressing its routes as
`/repositories/{repoId}/workspaces/...` asserts a containment the model deliberately does not have,
and it is what puts three services under one prefix (see the header note).

So the entity leads, and the repository is *scope*, exactly as for telemetry:

- **collections** take `?repositoryId=` — a filter, which is what it is;
- **a single workspace** is identified by `{id}` alone — `Workspace.id`, the generated `Long`
  primary key that already exists and that every FK'd child table already uses. Not the string
  `workspaceId`, which `WorkspaceCommandHistory`'s javadoc already documents as *reusable*.
  Assumes `priority-bug.md` has landed and that key is externalised.

| Current path (full) | Proposed |
|---|---|
| `GET /api/repositories/{repoId}/workspaces` | `GET /workspaces/api/workspaces?repositoryId={repoId}` |
| `POST /api/repositories/{repoId}/workspaces` | `POST /workspaces/api/workspaces` — `repositoryId` in the body |
| `POST /api/repositories/{repoId}/branches/cleanup` | `POST /workspaces/api/branches/cleanup?repositoryId={repoId}` |
| `POST /api/repositories/{repoId}/branches/merge` | `POST /workspaces/api/branches/merge?repositoryId={repoId}` |
| `GET /api/repositories/{repoId}/history` | `GET /workspaces/api/history?repositoryId={repoId}` |
| `GET /api/repositories/{repoId}/history/{id}` | `GET /workspaces/api/history/{id}` |
| `PATCH /api/repositories/{repoId}/history/{id}` | `PATCH /workspaces/api/history/{id}` |
| `GET /api/repositories/{repoId}/workspaces/{workspaceId}/active-process` | `GET /workspaces/api/workspaces/{id}/active-process` |
| `GET /api/repositories/{repoId}/workspaces/{workspaceId}/bootstrap-commands` | 🗑 **REMOVE** — belongs to the daemon (§1a) |
| `POST /api/repositories/{repoId}/workspaces/{workspaceId}/bootstrap-commands/run` | 🗑 **REMOVE** — belongs to the daemon (§1a) |
| `POST /api/repositories/{repoId}/workspaces/{workspaceId}/bootstrap-commands/{stepId}/run` | 🗑 **REMOVE** — belongs to the daemon (§1a) |
| `POST /api/repositories/{repoId}/workspaces/{workspaceId}/delete-container` | `POST /workspaces/api/workspaces/{id}/delete-container` |
| `POST /api/repositories/{repoId}/workspaces/{workspaceId}/discard` | `POST /workspaces/api/workspaces/{id}/discard` |
| `POST /api/repositories/{repoId}/workspaces/{workspaceId}/ensure-container` | `POST /workspaces/api/workspaces/{id}/ensure-container` |
| `GET /api/repositories/{repoId}/workspaces/{workspaceId}/events` | `GET /workspaces/api/workspaces/{id}/events` |
| `POST /api/repositories/{repoId}/workspaces/{workspaceId}/merge` | `POST /workspaces/api/workspaces/{id}/merge` |
| `POST /api/repositories/{repoId}/workspaces/{workspaceId}/recreate-container` | `POST /workspaces/api/workspaces/{id}/recreate-container` |
| `GET /api/repositories/{repoId}/workspaces/{workspaceId}/services` | 🗑 **REMOVE** — belongs to the daemon (§1a) |
| `POST /api/repositories/{repoId}/workspaces/{workspaceId}/services/{serviceId}/start` | 🗑 **REMOVE** — belongs to the daemon (§1a) |
| `POST /api/repositories/{repoId}/workspaces/{workspaceId}/services/{serviceId}/stop` | 🗑 **REMOVE** — belongs to the daemon (§1a) |
| `POST /api/repositories/{repoId}/workspaces/{workspaceId}/stop-container` | `POST /workspaces/api/workspaces/{id}/stop-container` |
| `GET /api/events` | `GET /workspaces/api/events` |
| `GET /api/service-events` | `GET /workspaces/api/service-events` |
| `GET /api/technical-processes/{id}/events` | `GET /workspaces/api/technical-processes/{id}/events` |
| `POST /api/capture` | `POST /workspaces/api/capture` |
| `OPTIONS /api/capture` (Vert.x CORS preflight) | `OPTIONS /workspaces/api/capture` |
| `WS /api/workspace-daemon/{workspaceId}` | `WS /workspaces/daemon/{id}` |
| `/service/{workspaceId}/{serviceId}/*` (Vert.x dev-server proxy) | `/workspaces/service/{id}/{serviceId}/*` |
| `/q/openapi`, `/q/swagger-ui` | `/workspaces/q/openapi`, `/workspaces/q/swagger-ui` |

Three consequences worth noticing, because they are the argument for the shape:

- **The stutter is gone.** `/workspaces/api/workspaces/{id}/services` reads as
  "the workspaces service, the workspaces collection, this workspace" rather than repeating a
  repository that this context does not own.
- **All three workspace-addressed surfaces now agree**, on `{workspaceId}` alone. Today the REST
  routes take `{repoId}` *and* `{workspaceId}`, the daemon control socket takes only `workspaceId`
  (§1), and the dev-server proxy takes only `{workspaceId}/{serviceId}` — three different answers to
  "how do you name a workspace", which is itself the symptom of the id not being a real key. Note
  the socket and the proxy are already right; it is the id underneath them that has to become
  unique.
- **`history` loses its repository prefix on the item routes.** `history/{id}` is already a
  standalone row id; the repository was decoration on `GET`/`PATCH` of a specific record and a real
  filter only on the collection.

**Not adopted: `{repoId}:{workspaceId}` as one composite segment.** It shortens the path, but Vert.x
route syntax already uses `:name` for path parameters (`router.get("/git/:repoId/info/refs")`), so a
literal colon in the path makes route definitions read ambiguously. Two plain segments need no
parsing rule and no reserved character.

### qits-workspace-daemon — 🚧 OUT OF SCOPE

> **Deferred. Nothing in this section is decided, and the `Proposed` column is a placeholder.**
> The daemon is one process per workspace container rather than a single service, so its
> addressing is a separate question from the six services' and is not settled here. The list below
> is an inventory only, extracted from `WorkspaceApi.java`.

| Current path (full) | Proposed |
|---|---|
| `GET /files?path=` | `GET /workspaces/api/workspaces/{id}/daemon/files?path=` |
| `GET /files/content?path=` | `GET /workspaces/api/workspaces/{id}/daemon/files/content?path=` |
| `GET /detection` | `GET /workspaces/api/workspaces/{id}/daemon/detection` |
| `GET /component-map` | `GET /workspaces/api/workspaces/{id}/daemon/component-map` |
| `POST /fast-forward?parent=` | `POST /workspaces/api/workspaces/{id}/daemon/fast-forward?parent=` |
| `POST /update-from-parent?parent=` | `POST /workspaces/api/workspaces/{id}/daemon/update-from-parent?parent=` |
| `GET /commands?status=` | `GET /workspaces/api/workspaces/{id}/daemon/commands?status=` |
| `POST /commands` | `POST /workspaces/api/workspaces/{id}/daemon/commands` |
| `GET /commands/actions` | `GET /workspaces/api/workspaces/{id}/daemon/commands/actions` |
| `GET /commands/{commandId}` | `GET /workspaces/api/workspaces/{id}/daemon/commands/{commandId}` |
| `GET /commands/{commandId}/log?severity=&channel=` | `GET /workspaces/api/workspaces/{id}/daemon/commands/{commandId}/log?severity=&channel=` |
| `POST /commands/{commandId}/terminate` | `POST /workspaces/api/workspaces/{id}/daemon/commands/{commandId}/terminate` |
| `POST /agents` | `POST /workspaces/api/workspaces/{id}/daemon/agents` |
| `GET /agents/available` | `GET /workspaces/api/workspaces/{id}/daemon/agents/available` |
| `GET /agent-sessions` | `GET /workspaces/api/workspaces/{id}/daemon/agent-sessions` |
| `GET /agent-plugins` | `GET /workspaces/api/workspaces/{id}/daemon/agent-plugins` |
| `POST /agent-plugins/{pluginId}/install` | `POST /workspaces/api/workspaces/{id}/daemon/agent-plugins/{pluginId}/install` |
| `POST /prompt-refinements` | `POST /workspaces/api/workspaces/{id}/daemon/prompt-refinements` |
| `WS /terminal/commands/{commandId}` | `WS /workspaces/api/workspaces/{id}/daemon/terminal/commands/{commandId}` |
| `WS /chat/commands/{commandId}` | `WS /workspaces/api/workspaces/{id}/daemon/chat/commands/{commandId}` |
| *(loopback)* agent lifecycle hook sink | unchanged — loopback only, never externally addressed |

## 4. Decisions

**Settled**, recorded so they are not reopened:

1. **Scope goes in the query string.** `/observability/api/telemetry/logs?repositoryId=&workspaceId=`,
   not `/observability/api/telemetry/{repositoryId}/{workspaceId}/logs`. Applies uniformly to all
   nine affected routes: the 5 telemetry reads, `/ci/api/runs?repositoryId=`,
   `/workspaces/api/branches/{cleanup,merge}?repositoryId=` and
   `/workspaces/api/history?repositoryId=`. Workspace *item* routes are unaffected — `{id}` there is
   identity, not scope (§1).
2. **`/api/config.json` moves to the gateway.** It is web-component configuration, and the gateway
   is what serves the web components — so it belongs there, not in qits-observability. Removes the
   two-owner ambiguity in `migration-auth-plan.md` §11 item 4 by deleting one of the owners.
   `ConfigResource` leaves qits-observability entirely.
3. **`POST /workspaces/api/workspaces` carries `repositoryId` in the body.**
4. **`/observability/mcp`**, and the MCP **server name changes with the path**. It is currently named
   `repository` and contains no repository tools; observability's tools are observability's.
   `/projects/mcp` keeps the tools that are genuinely repository-scoped.
5. **`git`, `service` and `daemon` are legitimate second-level segments** alongside `api` and `mcp`.
   None is a JSON API: `/artifacts/git/…` is a wire protocol spoken by `git`,
   `/workspaces/service/{id}/{serviceId}/*` is an opaque reverse proxy, `/workspaces/daemon/{id}` is
   the control socket.
6. **`/q/*` moves under each service's segment** — `/observability/q/openapi` and so on, via
   `quarkus.http.non-application-root-path`. Mechanical: the gateway routes by prefix, so anything
   left at the root is unreachable through it. (`/q/*` is Quarkus' non-application root path: what
   the framework serves rather than application code — the OpenAPI document, swagger-ui, health.)

**Settled (continued):**

7. **`artifacts.repositories` keeps its name.** It looked like a collision with
   `domain.repository`, but "repository" is the standard term in this domain — Maven repositories,
   npm registries — and that is what this is becoming. `RepositoryType` holding only
   `CI_SCREENSHOTS` and `CI_VIDEOS` today is a TODO, not the definition. Two domains legitimately
   use the same word; the git origins served by `eu.wohlben.qits.githost` in the same service are a
   different thing and stay addressed by `repoId`.

8. **`terminal` is dropped from remote-login: it is a repository operation.** The path becomes
   `/projects/api/repositories/{repoId}/remote-login`, beside `/push`, `/pull` and `/sync` — which is
   what it is. `RemoteLoginSession` runs *"exactly the interactive form of
   `RepositoryService#pushRepository`'s push … in the bare origin"*, in a host-side pty4j PTY with
   git's prompting enabled, so git can ask for the **upstream remote's** credentials and persist them
   to the host credential store. The websocket is the transport, not the resource, and `terminal`
   was a grouping prefix for three sockets of which the other two have since moved into the daemon.

   **It is not a workspace feature and cannot move to the daemon**, despite the name suggesting a
   login *into* something. It operates on the **bare origin** under `qits.repositories.data-dir`
   (the daemon has a checkout, not the origin), writes the **host** credential store shared across
   repositories, and holds a repository-scoped `TechnicalProcessRegistry` reservation so it cannot
   race a concurrent pull/sync/push. The class contains no `ContainerRuntime`, no container and no
   workspace id. Recorded because the name invites the question.

**The one thing still open — and it is a gateway question, not a path one:**

9. **Websockets through a rewritten prefix.** All of them must keep working through the gateway with
   `SameOriginUpgradeCheck` still seeing a real `Origin`/`Host` (`migration-auth-plan.md` §11
   item 2). One answer for all sockets, not per route. This is a gateway capability question, not a
   naming one.

> **Note on scope.** An earlier draft of this section costed several of these as migrations of a
> live system — remotes baked into existing volumes, deployed daemons dialling old paths, rows
> already violating a new constraint. **Nothing is deployed behind the gateway.** Those costs do not
> exist yet, and treating them as real inflated the list. Path changes here are code changes, not
> data migrations.

## 5. How this would land

Not proposed as one change. The ordering that keeps things reachable throughout:

1. **Decide §4 items 1, 2 and 3** — they change API *shape*, not just prefix, and everything else is
   mechanical once they are settled.
2. **Adopt the segment prefix per service**, one repo at a time. In Quarkus this is mostly
   `quarkus.rest.path=/<segment>/api` plus `quarkus.http.non-application-root-path`, so the JAX-RS
   half is close to a one-line change per repo — but every raw Vert.x route (`/git/**`,
   `/service/**`, the capture preflight) is registered on the router directly and does **not** move
   with it. `RootPath` exists precisely because of that split.
3. **Regenerate `docs/openapi.yml`** in each repo. The committed documents make this reviewable —
   the whole diff is visible before anything ships.
4. **Update the callers that hardcode a path**, listed in §4 item 5.
5. **Only then** point the gateway at the services, and delete the monolith's copies.

---

## 6. Resolution

Adopted 2026-07-27, one commit per repo, on each repo's `main`. Nothing pushed at the time of
writing; no gitlinks moved.

| Repo | Commit | What it carries |
|---|---|---|
| `qits-observability` | `47df7ae` | segment, telemetry query-string reshape, MCP renamed, `ConfigResource` deleted |
| `qits-stt` | `00b90fe` | segment, `speech/transcriptions` → `transcriptions` |
| `qits-ci` | `b9ec632` | segment, redundant `ci` dropped, runs listing reshaped, token filter fixed |
| `qits-artifacts` | `f6ad67e` | segment, redundant `artifacts` dropped, `/git/**` moved, token filter fixed |
| `qits-projects` | `986b135` | segment, MCP moved, `terminal` dropped, `{repositoryId}` normalised |
| `qits-workspaces` | `9ceabb1` + `7943253` | branch merge, then the entity-led reshape and the §1a deletions |
| `qits-gateway` | `084f79e` | `PublicPaths` per-upstream, `/api/config.json` as a Vert.x route |
| `qits-workspace-daemon` | `ef68716` | per-service MCP and git addresses, explicit config with warning fallback |
| `@qits/angular` | `d9af6c0` + `954f2d5` | capture ingest moved; the dead proxy-base pattern fixed |

Every service serves `/<segment>/api` and `/<segment>/q`, verified against the **packaged process**
and not only the suite — including a real `git clone`/`push` over `/artifacts/git/<repoId>`, a `101`
websocket upgrade on both moved sockets, and a `204` CORS preflight on the moved capture route. Old
addresses `404` everywhere; no compatibility aliases were left behind.

### 6.1 What the proposal got wrong

- **§1's premise about `RepositoryScopeGuard` was wrong.** Scope was never enforced on the telemetry
  *REST* surface — `WorkspaceTelemetryController` injects only `TelemetryQueryService`, and an
  unknown scope selects an empty bucket. The guard covers the **MCP tools**, where scope arrives
  from the connection (`X-QITS-Repository`/`X-QITS-Workspace`), never from a caller-supplied
  parameter. Moving `repoId`/`workspaceId` into the query string therefore changed no
  authorization — the right outcome, for a different reason than §4 item 1 gave.
- **§5 step 4 pointed at "§4 item 5" for the callers that hardcode a path.** No such list exists
  there; item 5 is about second-level segments. The real callers were found by tracing: qits-ci's
  git-host bases, qits-artifacts' `qits.ci.intake-url`, the daemon's two derivations, and
  `@qits/angular`'s capture branch.
- **`migration-plan.md` §9 item 16 says thirteen `QITS_WORKSPACE_DAEMON_*` vars.** It is fourteen.
  `API_TOKEN` is genuinely absent, so the item's substance holds.

### 6.2 Two defects the change surfaced, both the same shape

**Path-prefix token filters that fail open.** `ArtifactsTokenFilter` and `CiTokenFilter` both
matched `UriInfo.getPath()` — which is relative to `quarkus.rest.path` — against a literal that the
redundant-noun removal deleted. Under `/ci/api`, a request to `/ci/api/events/post-receive` reaches
the filter as `events/post-receive`: it **loses** `ci` rather than gaining it, so a matcher written
against the absolute-path intuition looks correct and is wrong. Both fail open, so both write
surfaces would have been served unguarded with nothing going red.

Proven rather than inspected: reverting only qits-ci's matcher literal turns `CiTokenGuardTest` red
with `Expected 401 but was 202` — the intake accepting an untokened post-receive event. Both traps
are now written into their repos' `AGENTS.md`.

Audited for the same shape elsewhere: qits-workspaces has **no JAX-RS filters at all**, and its one
`UriInfo` use reads only scheme+authority. qits-projects, qits-stt and qits-observability have no
path-prefix guard. The gateway's `PublicPaths` is this shape by design and is the one place it is
tested as such.

### 6.3 Decisions taken during implementation

1. **§1a's six routes were deleted, not deferred** — the user's call, overriding the document's
   "cannot be deleted until §9 item 16 is resolved". The execution already lives in the daemon's own
   `ServiceSupervisor` and `BootstrapRunner`. **The daemon endpoints were *not* added**: that is
   §1a step 2 and still needs item 16. So the capabilities are currently reachable only through the
   daemon's HTTP API, which does not bind at all in a host-created container. Deliberate, and the
   thing to fix next.
2. **Coverage genuinely lost with `WorkspaceBootstrapController`:** the list projection — chain
   order merged with each step's last run, step ids defaulting to names, the `chainRunning` flag.
   It existed only in the deleted controller. Run/single-run/in-flight-conflict remain covered
   against the runner directly.
3. **`workspace_bootstrap_run` is now write-only.** Confirmed: `WorkspaceHistoryService` does not
   read it and nothing else does. Table kept — dropping it is a data migration — and the state is
   recorded in `BootstrapRun`'s javadoc, `BootstrapRunService.listForWorkspace`, `AGENTS.md` and
   `README.md`, per §1a step 5's "do not leave it write-only by omission".
4. **`LegacyDaemonControlSocket` keeps `/api/workspace-daemon/{workspaceId}`.** Prefixing it defeats
   its only purpose — the address is baked into already-running containers — and it is dialled
   container-to-container, never through the gateway.
5. **A service's own `/q/*` is not public through the gateway.** Healthchecks dial `qits-net`
   directly by DNS name; what is left at the front door is swagger-ui and the OpenAPI document, read
   by humans who have a session. The gateway's own `/q/*` stays public — it is the only published
   listener and its probe has no other address.
6. **`PublicPaths` keeps the monolith-relative forms**, because they are not a second spelling of
   one route but a second **upstream**: `app-host=qits` still routes there and every `proxy-hosts`
   entry is still commented out. `isPublic` is now three methods grouped by who serves the path —
   `gatewaysOwn` / `onAService` / `onTheMonolith` — with the third's deletion trigger named on both
   sides. A block deletes cleanly; a line inside a `||` chain goes missing silently.
7. **qits-ci puts `/artifacts` in the config value, not the code.** `qits.ci.git-host-url` now
   defaults to `…/artifacts` and the code still appends `/git/<repoId>`: `/git` is this codebase's
   own convention that ci legitimately knows, but *which service hosts it* is a deployment fact.
   Consequence, documented in both the properties comments and the README: a deployer who writes
   `…/artifacts/git` gets a doubled segment.
8. **The daemon warns rather than guessing silently.** `qits.workspace-daemon.git-base-url` and
   `qits.observability-mcp.url` are new explicit keys; derivation from the control-socket authority
   survives as a fallback that logs a `WARN` naming what it guessed. `actions` has no derivable form
   and throws. Choosing otherwise would have been deciding the topology, which §4 item 9 leaves open.
9. **The nameless default MCP server at `/mcp` was left in place** in both qits-projects and
   qits-observability. `quarkus-mcp-server-http` mounts it regardless; it carries no tools, since
   every tool is annotated onto a named server, and it is unreachable through the gateway. Both
   repos made the same call deliberately, so they do not diverge. One line
   (`quarkus.mcp.server.http.root-path`) moves it in each if that changes.

### 6.4 Still open

- **§4 item 9 is untouched.** Websockets through the gateway with `SameOriginUpgradeCheck` still
  seeing a real `Origin`/`Host` remains one answer for all sockets, and no per-route answer was
  invented. Both moved sockets were verified upgrading against their own service directly.
- **§5 step 5 has not run.** Every `qits.gateway.proxy-hosts.*` entry is still commented out and the
  monolith catch-all is still configured, so nothing is actually routed to a split service yet. That
  is the last step and it is a deployment change.
- **The `actions` MCP server has no provider in the split.** It appears in no §3 table and
  `migration-api-map.md` shows it as monolith-only, yet the daemon had been deriving an address for
  it. It now throws instead. Somebody has to decide where, or whether, it lives.
- **The daemon's own HTTP surface is still unaddressed** (§3's 🚧 section, `migration-plan.md` §9
  item 16). Twelve operations, two websockets, and now the six capabilities §1a removed from the
  host all sit behind it.
- **`@qits/angular`'s OTLP export is a two-hop path and only the far hop moved.** The browser posts
  base-relative to the consumer app's own `OtelProxyResource`, which forwards server-side to
  `OTEL_EXPORTER_OTLP_ENDPOINT`. That endpoint must now be
  `http://qits-observability:8080/observability/api/otel` — and per
  [`migration-deployables-plan.md`](migration-deployables-plan.md) §4a **nothing injects it today**,
  because the OTLP overlay was dropped during the daemon extraction. The receiver still has no
  senders.

### 6.5 Two operational notes

- **`./mvnw -pl service -am test -Dtest=OpenApiSchemaExportTest` needs
  `-Dsurefire.failIfNoSpecifiedTests=false`** where `-am` also visits a module without that test.
- **`migration-plan.md` §9 item 14's port flake is contention, not mystery.** Running these suites
  concurrently across repos makes `Port already bound: 8081` systematic — two different PIDs were
  observed holding the port in overlapping windows. Re-run, or pass `-Dquarkus.http.test-port`.
  Same for boot checks on 8080.
