# Epic lifecycle + refinement agent harness

Branch `epic-refinement`, worktree `~/code/qits-qits-epics`. Runs beside the
deployment-unification refactor; the two do not intersect. Repos touched:
`services/qits-projects`, `frontends/qits-spa-projects`, and the new
`daemons/qits-projects-daemon` (submodule added on this branch).

## 1. The lifecycle model (backend, qits-projects `epics/`)

Statuses on `Epic`: `REFINING`, `IMPLEMENTATION`, `DONE`, `SUPERSEDED`, `ABANDONED`.

- **REFINING** — the draft phase. Title, description, features, tasks are all
  mutable. New epics start here.
- **IMPLEMENTATION** — scope is frozen: no adding/removing/renaming features or
  tasks, no description edits. Only the implemented markers
  (`implementedOn`/`implementedAt`) may change. Enforced in the services
  (`EpicService`/`FeatureService`/`TaskService` check the epic's status before
  every mutation), not just the UI.
- **DONE** — explicit transition for now; later derived from git (all features
  merged to main).
- **SUPERSEDED** — the epic went back to the drawing board. Superseding creates a
  NEW epic in `REFINING` (copying title/description as the starting draft) and
  links it via `supersededByEpicId` on the old row; the old row keeps its frozen
  scope as the record of what was discarded. This is why superseded epics remain
  list entries.
- **ABANDONED** — terminal. Code reverted, will not be implemented.

Transitions (validated in `EpicService`, audited like every mutation):
`REFINING→IMPLEMENTATION` (freeze), `IMPLEMENTATION→DONE`,
`IMPLEMENTATION→SUPERSEDED` (spawns the successor), `IMPLEMENTATION→ABANDONED`,
`REFINING→ABANDONED` (a draft can be dropped too).

Changes:
- Migration `V3__epic_status.sql`: `status varchar` not null + index, nullable
  `superseded_by_epic_id`. Backfill existing rows to `IMPLEMENTATION` (they were
  created under the implementation-centric UI). New rows default `REFINING`.
- `EpicDto` gains `status` + `supersededByEpicId`.
- New endpoint `POST /projects/api/epics/{id}/transition` `{target}` → 409 with a
  reason on an illegal transition. List endpoint gains `?status=` filter.
- openapi regeneration; service + API tests for freeze enforcement and each
  transition.

## 2. UI reorganization (qits-spa-projects)

The project page's epics overview becomes grouped-by-status:
- **Refining** and **Implementation** sections front and center, always expanded.
- **Done**, **Superseded**, **Abandoned** in collapsed `<details>`-style sections
  (count in the summary line), loaded lazily on expand is unnecessary — the data
  is already in the fan-out; just render collapsed.
- The card varies by phase:
  - Implementation card = the existing card (tree + badges + branch names).
  - Refining card = draft styling, editable feel: description prominent, features
    and tasks as a draft outline, no branch names (no branches exist yet), a
    "Start implementation" action (the freeze transition), and the refinement
    agent panel (phase C below).
  - Done/Superseded/Abandoned cards = compact single-row summaries; superseded
    links to its successor epic.

## 3. Refinement agent harness

Mirrors the workspaces harness. All the load-bearing patterns exist and the
exploration mapped them; copy, don't reinvent. Key precedent files are in
`services/qits-workspaces` (registry, tunnels, proxy, SSE) and
`daemons/qits-workspace-daemon` (daemon, agent launch, MCP wiring).

### 3a. qits-projects-daemon (new repo, seeded)

Structure copied from qits-workspace-daemon, trimmed to the refinement use case:
- `projects-daemon-protocol/` — vendored codec module, byte-identical copy into
  qits-projects (the drift-detector `DaemonCodecTest` on both sides, same
  discipline as the workspaces pair).
- The daemon module: `ControlSocket` (outbound WS to
  `ws://…/projects/daemon/{projectId}` — new path literal, append-only
  contract), `Provisioner` (autonomous self-clone of the project's WRAPPER repo
  `<gitBase>/<projectId>/<slug>-<slug>` into `/workspace`), `DaemonStreamTunnel`,
  the loopback HTTP API with `WS /terminal/commands/{id}`, the hook webhook.
- `qits-commands/` + `qits-coding-agents/` copied — the agent IS a command;
  Claude CLI shelled with `--mcp-config` pointing at qits-projects' MCP. The MCP
  base derives from the control-socket authority — here the derivation is
  provably correct (both are qits-projects), so no override WARN needed.
- `docker/Dockerfile` (native binary) + `Dockerfile.projects` (layer the binary
  onto a toolchain base with git + the agent CLI), same as the workspace pair.

### 3b. Registry in qits-projects (`service/`)

One container per project, spawned on demand (first open of a refining card's
agent panel), not eagerly:
- Copy `ContainerRuntime`/`DockerExecutor`/argv-builder/factory with new
  namespace: name `qits-proj-<slug>`, labels `qits.managed=project-agent` +
  `qits.project`, volume `qits_project_<projectId>` → `/workspace`, network
  `qits-net`, shared `/claude-home` OAuth volume, no published ports.
- Image via config `qits.projects.agent-image`; freshness via the daemon's
  `Hello` build stamp (no registry table), recreate verb gated on a clean tree.
- Proxy: `ContainerProxyRoute` copy at `/projects/container/{projectId}/*` with
  bearer injection; reverse tunnels (`WorkspaceTunnels` triple) verbatim;
  `/projects/daemon/{id}` + `/projects/daemon/stream/{nonce}` routes.
- Every new raw route/websocket path MUST be added to
  `quarkus.quinoa.ignored-path-prefixes` in the same commit (`/daemon`,
  `/container` — values are ui-root-relative).

### 3c. MCP tools for refinement (qits-projects)

Extend the existing declared `@McpServer("repository")` (a second server name
would need its own declaration and daemon-side name contract; not worth it):
- `list_epics(status?)` — read, any state, filterable; this is how the agent
  distinguishes "extend epic X" (already refining) from "new epic".
- `get_epic(id)` — full tree including draft features/tasks.
- `propose_epic(title, description)` — creates status `REFINING`.
- `update_epic(id, …)`, `add_feature`, `update_feature`, `remove_feature`,
  `add_task`, `update_task`, `remove_task` — all guarded: only while the epic is
  `REFINING`; scope from `ProjectScope`'s `X-QITS-Project`, never from tool args.
- No transition tool in v1 — freezing scope is a human act in the UI.

### 3d. Live updates (SSE, qits-projects → SPA)

qits-projects has no SSE today; add the hint-only machinery copied from
workspaces: `ProjectChangeHint` (topics: `epics`, `agent-activity`),
`ProjectEventBroadcaster` (debounced BroadcastProcessor per project),
`GET /projects/api/projects/{id}/events` (`@Blocking`, `Multi<String>`). Every
epic mutation (REST or MCP) fires the hint; the SPA's epics overview re-fetches
on the counter, exactly the workspaces `event-source.ts`/`workspace-events.ts`
pattern (bump all counters on every connect; no replay protocol).

### 3e. SPA refinement panel

On a refining epic's card: an agent terminal (copy `terminal-socket.ts`,
`ansi-screen.ts`, `terminal-view.ts`, the `AgentSession` resolution state
machine — resume never automatic) attached through
`/projects/container/{projectId}` + the daemon's terminal websocket. The flow:
user types "new epic: …" → agent calls `propose_epic` → DB row in `REFINING` →
SSE hint → overview re-fetches → the new draft card appears. Session start is
lazy (a container is expensive); a per-project status strip states daemon
reachability once instead of N failures.

## 4. Phasing

- **A — lifecycle** (backend V3 + transitions + freeze enforcement + DTO/openapi)
  and **B — UI grouping** (status sections + per-phase cards, transition buttons).
  Shippable on their own; no daemon involved.
- **C — harness**: daemon repo skeleton + registry/proxy/tunnels + terminal panel
  (agent with repo access, no epic tools yet).
- **D — MCP refinement tools + SSE** wiring; the full propose/refine loop.
- Each phase releases through the workspaces release endpoint; SPA ships via the
  automated maintenance follow-bump (do NOT hand-bump the webui gitlink).

## 5. Decisions (user, 2026-08-08)

1. **DONE is derived, not stored.** Stored statuses are `REFINING`,
   `IMPLEMENTATION`, `SUPERSEDED`, `ABANDONED`. "Done" is an `IMPLEMENTATION`
   epic with ≥1 feature and every feature's `implementedOn` set — the same
   derivation the SPA's `epicStatus` already does. No transition, no button.
2. **Superseding copies the full old scope** into the successor draft: new epic
   in `REFINING` with copied title/description/features/tasks (fresh ids, same
   slugs — legal, new scope; `dependsOn*` remapped to the new ids; implemented
   markers reset to null).
3. **Agent image = full workspace toolchain**, layered exactly like the
   workspace image (`ARG BASE`/`ARG DAEMON_IMAGE` pattern), so the agent can
   build/test components during refinement.
4. **Stop policy: idle timeout + explicit stop verb.** Registry stops containers
   after a configurable idle window (no agent activity); the UI gets Stop like
   workspaces; restart is lossless (`docker start` in place).
5. The daemon-socket auth gap (`/…/daemon/{id}` token-free on qits-net) is
   inherited from workspaces — accepted for now, fixed together with workspaces
   when qits-idp machine auth lands (no interim tokens).
