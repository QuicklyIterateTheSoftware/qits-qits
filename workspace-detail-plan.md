# The workspace detail view: implementation plan

Status: **IMPLEMENTED AND BROWSER-PROVEN (2026-08-02)** from the clean-room
`workspace-detail-spec.md`. The full screen landed through BM–BV; final SPA fixes are `a984672` and
the service embed is `d02f7040`. The decisions and implementation deviations remain here as the
design record; `handoff.md` carries the final proof and parked follow-ups.

This plans one screen: the page you sit on while a coding agent changes a workspace. The behaviour
is `workspace-detail-spec.md`; this document is what we build, in what order, on top of what
actually exists. Everything in the next section was read out of the new platform or measured
against the running one on 2026-08-01 — the spec's author worked from the old monolith and could
not check any of it, and eight of their findings turned out to be wrong in ways that change the
plan.

---

## What exists, measured (not assumed)

### The container proxy is real, reachable from a browser, and needs nothing added

`ContainerProxyRoute` (`services/qits-workspaces/service/src/main/java/eu/wohlben/qits/workspaces/api/ContainerProxyRoute.java`)
serves `/workspaces/container/{workspaceRowId}/*` as a raw Vert.x route and forwards **verbatim** to
that workspace's in-container daemon. Measured through the real gateway:

```
$ curl -i http://localhost:8080/workspaces/container/1/files
HTTP/1.1 404 Not Found
Content-Type: application/json
{"message":"No workspace here."}
```

That 404 is `ContainerProxyRoute`'s own body, not the gateway's and not Quinoa's. So the gateway
forwards the whole `/workspaces` subtree (`QitsService.WORKSPACES`, verbatim, no rewriting), and
`quarkus.quinoa.ignored-path-prefixes=/api,/q,/daemon,/service,/container` keeps the SPA fallback
off it. **A browser can call the daemon today, with no gateway change and no new route.**

The auth posture is better than the spec feared:

- The path is *not* in `PublicPaths`, so the gateway's session policy guards it like every other UI
  surface. The SPA is served by qits-workspaces itself at `/workspaces/` (Quinoa,
  `ui-root-path=/workspaces`, `<base href="/workspaces/">`), so the proxy is **same-origin with the
  page** and the session cookie rides automatically. `QITS_API_BASE = ''` works unchanged.
- The proxy **sets** `Authorization: Bearer <daemon token>`, replacing whatever arrived. The browser
  never holds a daemon credential and cannot smuggle one in.
- WebSocket upgrades ride through. `vertx-http-proxy` skips its interceptor chain on an upgrade, so
  the bearer is set on the inbound request instead (`presentBearerOnUpgrade`) — that fix has landed;
  without it every terminal and chat socket was a 401.
- The daemon emits no redirects, no `Set-Cookie`, no CORS headers, no `Content-Encoding`. Nothing a
  browser or an intermediate proxy trips on.

**But the control socket is now load-bearing, and the service's own javadoc is stale about it.**
`DaemonProxyTargets` says control-socket liveness is deliberately not a reachability state. That was
true before the reverse tunnel. `ContainerProxyRoute.resolve` now asks `WorkspaceTunnels.originFor`
first, which calls `WorkspaceDaemonRegistry.lookup` — and that returns empty the moment the socket
closes. A tunnel-capable daemon has *stopped listening on qits-net*, so the direct fallback finds
nothing and the request 502s. **A daemon reconnect blip takes the entire file browser, every
terminal and the whole agent surface down for its duration.** Plan the client for it; do not repeat
the docstring's claim.

### The daemon's API is untyped and undocumented, and there is nothing to introspect

Verified across the whole submodule: **zero** occurrences of `openapi`, `swagger`, `smallrye-openapi`,
JAX-RS or Jackson. `workspace-daemon/pom.xml` carries `quarkus-arc`, `quarkus-vertx`, `snakeyaml` and
the four sibling modules. The server is a raw `io.vertx.core.http.HttpServer` with a hand-written
`switch` dispatcher (`WorkspaceApi.java`) and hand-built `JsonObject` bodies in `WorkspaceJson`,
`CommandJson` and `AgentJson`. There is no `docs/` directory.

The closest thing to a schema is the API test suite, which asserts every wire key as a **literal
string** (`CommandsApiTest`, `AgentsApiTest`, `ServicesApiTest`, `BootstrapApiTest`,
`WorkspaceApiTest`). That is what a written contract has to be pinned against.

### What the daemon actually answers — corrections that matter

| Surface | Reality |
|---|---|
| `GET /files` | `{paths[], lazyDirs[{path, childCount}], generation}`. **The generation token exists** — `generation` is a sha256 over the deduped sorted `git ls-files` output, and `/detection` computes it with a byte-identical duplicate algorithm. `childCount` is immediate children only. Lazy dirs *are* the gitignored dirs; there is no separate ignored flag, exactly as the spec predicted. |
| `GET /files/content` | `{path, content?, binary}`. **Reads any regular file inside the root, tracked or not** — no git consultation at all, so the log-anchoring case works. 2 MB cap, and over-cap **soft-degrades to `binary:true` with no content**, not a 413. |
| `GET /detection` | `{projects[], frameworks[{frameworkId, root, label, memberPaths[]}], links[{path, projectRoot?, tests[{path,kinds[]}]}], generation}`. Everything section 6 of the spec asks for, plus the same token. |
| `POST /agents` | `{scope, mode, initialContext, resumeSessionId, fork, deliverTaskPrompt, agentType}`. **All four parameters the resolution order needs exist**, plus a fork flag. |
| `GET /agent-sessions` | **A nested tree.** `children[]` recurses to arbitrary depth; `subagents[]` is a flat list one level deeper. Fields: `sessionId`, `firstRecordedAt`, `forkedFromSessionId`, `messageCount`, `newestCommandId`. |
| `WS /chat/commands/{id}` | **Replays the whole conversation on attach** — transcript head stitched to a 256 KB ring tail, deduped on `uuid`, under the session lock. Sub-agent side-chains are anchored by a synthetic `{"type":"qits_agent_meta", …, "toolUseId"}` line before each one, and `toolUseId` is the `Task` call that spawned it. Side-chains join **only after the exit sweep** — the live tail covers the main session only. |
| `WS /terminal/commands/{id}` | Replays 256 KB of scrollback. Bearer required on the handshake. Close is a bare `socket.close()` (code 1000) after writing a `[no longer running]` banner. Closing detaches; the process survives. |
| `GET /commands/actions` | `{actions:[{id, name, interactive}]}`. **There is no origin field, because there is only one origin** — `ConfigActionResolver` reads the checkout's `.qits-config.yml`. The globally-defined "code actions" did not come across; the action tools never left the monolith. |
| Config actions "run inline" | **Absent from HTTP.** The fire-and-await triple (`RunCommand` → `CommandChunk` → `CommandExit`) exists only on the control socket and `CommandExecutor`'s own javadoc says it wires no production caller. `POST /commands` is always spawn-and-return. |
| `GET /services` | `{services:[{name, state, id?, description?}]}` — **that is the entire DTO.** No restart count, no health-check results, no proxy path, no web-view entry path, no log command id, no web-viewable marker. All of it exists inside the daemon (`Supervised.restartCount`, `HealthCheckDecl`, `WebViewDecl`) and is published only on the control socket's `ConfigView`. `DEGRADED` is explicitly not a wire state. |
| `GET /bootstrap-commands` | The declared chain only — `{steps:[{name, id?, description?}]}`. **No per-step last run.** Progress rides the control socket as `BootstrapStep`/`BootstrapOutcome`/`Bootstrapped`. |
| `POST /prompt-refinements` | `{transcript, preamble}` → `{prompt}`. The refine half of the old speech flow survives intact. |
| Agent-activity tracking | A daemon config key plus a `.qits-config.yml` override. **No endpoint reads or writes it.** It gates the turn-boundary hooks only; the `SessionStart` lineage hook is injected unconditionally. |

### The live channel is exactly what the spec says it is, and I watched it

`WorkspaceEventBroadcaster` — debounce leading-edge-plus-trailing at
`qits.events.debounce-ms=1000`, heartbeat merged in at 25 s, `onOverflow().drop()`, no replay
protocol, no `Last-Event-ID`. Topic names are `Topic.name().toLowerCase().replace('_','-')`.
Measured live through the gateway:

```
$ curl -N http://localhost:8080/workspaces/api/events
Content-Type: text/event-stream
data:ping
data:ping
```

Three things the spec does not have:

- **`telemetry` is a dead topic.** Nothing in `domain/` or `service/` fires it, and the daemon nudges
  exactly one topic (`WorkspaceChangeTopic.COMMANDS`). The Telemetry surface has no live signal.
- **`git-status` fires on the *repository* channel `(repoId, null)`**, and **there is no
  `RepositoryEventsController`** — only `/workspaces/{id}/events` and `/events` exist. So the
  repository-scope hints are unreachable by any client today. The detail view gets clean/dirty
  refreshes for free anyway, because every `GitStatus` report also fires `FILES` on the workspace
  channel.
- `prompt-draft` and `prompt-attachments` fire from `WorkspacePromptDraftService` /
  `WorkspacePromptAttachmentService` — which **nothing calls**, because the controllers do not
  exist. The topics are wired and silent.

`/technical-processes/{id}/events` is the payload-bearing stream and behaves as described: full
replay on every connect, then live, then `done`, then completes; an unknown or evicted id is a 404,
which `EventSource` treats as fatal.

### Eight of the spec's gap claims are wrong

1. **"15 documented operations."** It is **18**, across 16 paths — `branches/release` landed with
   the release train, and `POST /workspaces` and `PATCH /history/{id}` were missed.
2. **"The SPA's activity enum is missing `ENDED`; fix that or the Ended state renders as nothing."**
   The enum *is* missing it (`dto.ts:31`), and adding it changes nothing, because **the host never
   emits `ENDED`**. `WorkspaceDaemonRegistry.onAgentActivity` *evicts* the entry on `ENDED`, and
   `rollup()` returns `BUSY > WAITING > IDLE` or `null`. The four-state activity bar — and the whole
   "a session that has just stopped bubbles to the far left, because that is the workspace that
   needs your next prompt" ordering rule — **cannot be built on today's data.** This is ⚖9.
3. **"No branch listing."** `GET /projects/api/repositories/{repoId}/branches` exists, is in
   qits-projects' OpenAPI, and answers live:
   `{"branches":[{"name":"main","canCleanup":false,"parent":null,"ahead":null,"behind":null}]}`.
4. **"No diff or changed-files surface."** For **committed** work there is a full one in
   qits-projects: `/commits`, `/commits/{hash}/changes`, `/commits/{hash}/diff`, all documented, all
   answering 200 live. What is genuinely absent everywhere is a **working-tree** diff — the
   uncommitted agent edits, which is the one the detail view wants.
5. **"Telemetry lives in another service" (framed as a gap).** It lives in another service and is
   **fully documented and reachable**: `/observability/api/telemetry/{errors,logs,metrics,slow-spans,traces/{traceId}}`,
   in qits-observability's `docs/openapi.yml`, filtered by `repositoryId` + `workspaceId`,
   `slow-spans` taking `sort=recent|duration` (the Recent/Slowest lens) and `thresholdMs=0` for
   everything. `GET /observability/api/telemetry/errors` answers 200 through the gateway right now.
   The Telemetry tab is *cheap*, not blocked. What it lacks is the live hint (finding above).
6. **"No live command list host-side; history is readable through `history/{id}` for a resolved
   workspace."** Worse than that: **`WorkspaceCommandHistory` has no implementation anywhere.** The
   port is injected as `Instance<T>` and always resolves absent, so `history/{id}.commands` is
   always `[]` — for active *and* resolved workspaces. The host has no command history at all.
7. **"No single-workspace read."** Nearly right, and the correction matters for effort:
   `GET /workspaces/api/history/{id}` is id-keyed and works for ACTIVE rows (`findById`, no status
   filter) — but `WorkspaceHistoryDetailDto` carries no branch, no runtime status, no clean flag, no
   daemon fields. It is the narrative record, not the live view. The real gap is a `GET
   /workspaces/{id}` returning `WorkspaceDto`, and `WorkspaceService.getWorkspace(id)` already
   exists and is already the return value of four mutation endpoints. Five lines.
8. **"The services panel is tier 2 — `GET /services` on the daemon covers it."** The route exists and
   returns four fields. Restart count, health results, proxy path, web-view entry path and the log
   command id are **not on any HTTP surface, host or daemon**. This is the largest under-estimate in
   the gap list and it moves work into the daemon repo.

One more, which is not in the spec at all because nothing points at it: **`deliverTaskPrompt: true`
launches an agent that is told to call a tool that does not exist.**
`AgentLaunchService.TASK_PROMPT_BOOTSTRAP` seeds the session with *"Fetch the current task prompt for
this workspace with the taskPrompt tool"*, aimed at the `repository` MCP server — which is
qits-projects, whose MCP tools are `listRepositories`, `listBranches`, `listCommits`,
`listCommitChanges`, `getCommitFileDiff`. There is no `taskPrompt` anywhere on the platform.

### The frontend, as it stands

`@qits/ui-components` 0.0.4 exports exactly four components — `QitsButton`, `QitsBadge`, `QitsCard`,
`QitsMainLayout` — plus three type aliases and `QITS_NAV_LINKS` (eight entries). The spec's count is
right. `Async`, `Empty`, `Loadable` and `format` are triplicated per SPA on purpose.

`Loadable<T>` is verbatim in all three SPAs and `idle` really is a state, not an absence:

```ts
export type Loadable<T> =
  | { readonly kind: 'idle' }
  | { readonly kind: 'loading' }
  | { readonly kind: 'ready'; readonly value: T }
  | { readonly kind: 'error'; readonly status: number; readonly message: string };
```

with `IDLE`, `LOADING`, `ready()`, `failed()`, `statusOf()`, `describeError()`. No type guards —
call sites discriminate on `state.kind` inline. `describeError` prefers the platform's
`{"message": …}` envelope and renders status 0 as *"the service is unreachable"*, which is exactly
what a 502 from a disconnected daemon needs.

Everything else in the brief's idiom list is CONFIRMED against the code: standalone (by Angular 19+
default — the word `standalone` appears zero times), `OnPush` on every component in all four repos,
no `@Input`/`@Output` anywhere, no `*ngIf`/`*ngFor`, no `| async`, `.subscribe(` only in specs,
`QITS_API_BASE` self-providing with `factory: () => ''`, eager routes only, Angular `^21.2.0`, and
Vitest on jsdom through `@angular/build:unit-test` with **no vitest config file anywhere** — jsdom is
the builder default and `tsconfig.spec.json` sets `"types": ["vitest/globals"]`.

The load-budget convention is real and is **asserted in tests**, not just written down:
`tree-page.ts:68` says *"On load this page reads `5 + P`"* and `tree-page.spec.ts:18` repeats the
sentence and counts the requests.

The URL rule is the sharpest thing in the codebase. Expensive levels go in comma-joined query params
read through `toSignal(route.queryParamMap)` and written with `queryParamsHandling: 'merge'` and a
history entry (so back means collapse); free levels are local signals that die with the node
(`repo-runs.ts:46`). Loading is driven off an `effect()` watching the URL, never off the click —
which is what makes deep links and the back button behave identically to a click. And
`NONE_EXPANDED` (writing `?project=` empty rather than dropping the key) exists because *"it is the
difference between 'I have not said' and 'I said none'"* — the same distinction a bare tab URL needs.

**Neither explorer consumes SSE.** Zero `EventSource` in any of the four repos. They poll, with a
codified discipline: an exported `POLL_INTERVAL_MS`, a `shouldPoll()` gate that is
`nonTerminal() && !this.document.hidden`, `this.handle ??= setInterval(…)` for idempotent start, an
`inFlight` re-entrancy flag that *skips* rather than queues, a `visibilitychange` listener removed
through `inject(DestroyRef).onDestroy`, **one immediate read on becoming visible then back to the
interval**, and a failed poll that sets a `pollProblem` beside the content rather than blanking it.
`DOCUMENT` is injected, never global, which is what lets specs fake `hidden`.

Also measured, and it shapes the frontend estimate: `qits-spa-workspaces` has no `eslint.config.js`
and no `lint` script (its CI recipe says so and says the line goes back in when both land); there is
no shared stylesheet and **zero CSS custom properties** — every colour is a repeated Tailwind-palette
hex; there is no dark mode (`:root { color-scheme: light }` is an explicit opt-out); and the chevron
tofu bug is five literal `▸`/`▾` sites across spa-ci and spa-cd. `qits-spa-workspaces` has no tree
and therefore no chevrons yet — we do not inherit the bug, we avoid it.

---

## Decision 1 ⚖ — how the browser reaches the daemon

This determines the shape of everything below, so it goes first.

### The options, honestly

**A — the browser calls `/workspaces/container/{id}/*` directly, with a hand-written typed client.**
Cost: five `@Injectable` services and their DTO interfaces, mirroring `WorkspaceJson`/`CommandJson`/
`AgentJson` by hand — about twenty endpoints and two sockets. No backend change to reach any of it.
Risk: no contract test. A daemon rename breaks the SPA and nothing says so; the daemon's own tests
assert wire keys as literals, so they catch the rename *in the daemon repo* and stay silent about
the consumer. Forecloses nothing. Session cookie: works, same-origin, no CORS, no machine token.
Gateway: no change.

**B — qits-workspaces grows thin typed host routes that forward.**
This is what the standing rule forbids, and the rule is right about the reason: the two controllers
that were deleted (`WorkspaceServiceController`, `WorkspaceBootstrapController`) were pure
forwarders, and a forwarder is a second copy of a contract that must be kept in sync forever. Doing
it for the whole surface means roughly forty JAX-RS resources, forty DTOs, forty mappers and a
forwarding client, all appearing in `docs/openapi.yml` as if they were this service's API. It also
does not remove the proxy, because the two websockets must still ride it — so you end up with two
mechanisms and two auth stories for one daemon.

There is a real argument on B's side and it should not be waved away: **for three surfaces the host
holds state the daemon does not publish.** Service restart counts and health results, the
web-viewable service list with its proxy path, and per-step bootstrap history are all readerless
host-side data (`ServiceSupervisor`, `ServiceInstanceDto`, `WebViewDto`, `workspace_bootstrap_run`,
`BootstrapRunService`). A route there is not a forwarder.

**C — hybrid: streams direct, JSON through host routes.** The worst split available. The JSON half is
the expensive half, and the streams are the part that already works.

### Recommendation

**Take A, with a written contract, under one line that resolves the tension with the standing rule:**

> **The proxy carries everything the daemon owns. The host serves only what the host owns. Nothing
> forwards.**

Concretely:

- Files, content, detection, component-map, commands, actions, agents, agent-sessions, plugins,
  prompt-refinements, service start/stop, bootstrap run, and both websockets: **direct through
  `/workspaces/container/{id}/*`**, from the browser, with hand-written `@Injectable` clients. This
  is the house idiom already — `ci-cd-explorer-plan.md` Decision 1 rejected generated clients, so
  "hand-written" is not a compromise, it is the convention.
- The daemon repo gains **`docs/openapi.yml`, hand-written**, covering those endpoints and the two
  socket protocols. It is not generated (there is nothing annotation-shaped to generate from) and it
  is not decoration: the existing `*ApiTest` classes already assert wire keys as literal strings, so
  the acceptance criterion is that every field in the document is asserted by a test in the same
  commit. The document is what the SPA's DTOs are written from and what a future change has to
  update.
- **The three host-owned gaps get host routes, and they are not forwarders**: per-step bootstrap
  history (`workspace_bootstrap_run`, which has had no reader since the controller was deleted),
  `GET /workspaces/{id}`, and the prompt draft and attachment controllers.
- **Service enrichment goes in the daemon, not the host.** Restart count, health results and the
  web-view declaration are the *daemon's* supervisor state today; the host's `ServiceSupervisor` is a
  projection of what the daemon reports. Adding a host route there would resurrect the deleted
  controller by another name. `GET /services` grows the fields it already has in memory.

Rejected alternative, stated: B for everything. It re-adds forty routes to fight a settled decision,
buys one contract test we can get more cheaply by writing the daemon's contract down, and leaves the
websockets on the proxy anyway.

---

## Decision 2 — the tab shell, and how hidden tabs stay mounted

The contract is non-negotiable: chat sockets, framed iframes, open files and scroll positions
survive a tab switch, and the cross-tab "open in source" jump exists only because of it.

Angular has no `keep-alive`. Three mechanisms, and the right one is the third:

1. `@if (active())` — destroys. Fails the contract outright.
2. All ten panels rendered eagerly with `[style.display]` — keeps everything alive and fires ten
   loads on page open. Fails the load budget.
3. **`@if (latched(slug))` around each panel, inside a `[style.display]` wrapper.** `latched` is a
   signal that flips true on first selection and never flips back. The panel is created once, on
   first selection, and then merely hidden. That is precisely the spec's "expensive panels
   initialise on first selection, then persist" rule, expressed in the framework.

Reordering moves only the buttons because there are **two loops with two orders**: the tab strip
renders `@for (tab of order())`, the panel container renders `@for (tab of TABS)` in a fixed order
that never changes. One sentence of Angular, and it is what stops a reorder from reloading an
iframe.

**What it costs, stated rather than hidden.** With `OnPush` and signals, a hidden panel re-renders
only when its own signals change — but they will, because an SSE hint invalidates by topic
regardless of which tab is open. A workspace with seven latched panels would refetch seven surfaces
on every hint. The discipline that fixes it is the explorers' visibility rule, applied per panel
instead of per page:

- A panel's fetch effect is gated on `latched() && (visible() || keepsLiveWhileHidden)`.
- Only three panels keep working while hidden, and each for a named reason: **Chat** (the socket must
  stay attached or the conversation stops replaying correctly), **Web view** (the iframe must not
  reload), **Agents** (the terminal socket must stay attached).
- Every other panel records that it missed a hint and does **one catch-up read on becoming
  visible** — the same invalidate-on-reconnect trick, one level down.

That preserves the contract (component alive, scroll intact, open file intact) without paying for
seven live panels.

### The URL

Route: `repositories/:repositoryId/workspaces/:workspaceId`. The repository segment is not
decoration — `GET /workspaces/api/workspaces` requires `?repositoryId=`, and without it the page
cannot read its own header (measured: `GET /workspaces/api/workspaces` with no filter answers
`404 {"message":"Repository not found: null"}`).

**The tab goes in the query string, not in a trailing path segment.** Rejected alternative: a
trailing `:tab` segment, which is what the original did. In Angular, a param change under one route
config reuses the component — so a trailing segment gets tab-switch-without-remount for free, and
gets *workspace*-switch-without-remount too, which is the bug the spec warns about. Putting the tab
in `?tab=` removes the question entirely, matches the house rule (a tab switch to an unlatched tab
costs requests, so it is a URL-level state), keeps every tab a shareable link, and makes a bare URL
mean "no tab pinned" by simple absence — the `NONE_EXPANDED` distinction the explorers already
reason about. `router.navigate([], { queryParams: { tab }, queryParamsHandling: 'merge' })` pushes,
so back walks tabs.

A workspace change *is* a path change under the same route config, so Angular still reuses. The
detail component therefore carries an explicit remount guard: an `effect` that, on a `workspaceId`
change, flips a signal false and true so the `@if` destroys and recreates the whole subtree. Three
lines, explicit, and it is the one place the reuse behaviour is worth fighting.

`?path=` and `?lines=` carry the file deep link. Tree expansion and the filter set follow the
explorers' comma-joined-id-set convention.

### The load budget

**Page shell: `2 + T`, plus one stream.**
`GET /workspaces?repositoryId=` (header, status strip, activity bar, and the shared entry every panel
reads), `GET /workspaces/{id}/active-process`, and the SSE channel. `T` is the selected tab's own
budget. Re-derive this on every change to the shell, and assert it in the shell's spec the way
`tree-page.spec.ts` does.

---

## Decision 3 — everything is app-local; the shared library is not touched

`@qits/ui-components` gets **nothing**. Tabs, tree, split pane, code viewer, terminal, dialog, form
controls, spinner, tooltip and icons are all built in `frontends/qits-spa-workspaces` under the `app-`
selector prefix.

The reason is measured, not aesthetic. A library release costs one publish plus a lockfile-rewriting
bump run per consumer plus a redeploy per serving service — the 0.0.4 train cost one release, eight
consumer commits and seven redeploys, and `release-train-hops-plan.md` Decision 2 spells out why a
bump cannot be spliced (the lockfile's `integrity` is a fact about tarball bytes; npm has to run
where the registry is reachable). A component with exactly one consumer does not earn that.

The precedent is already set inside these repos: `ProjectsApi` is copy-pasted three times on purpose,
because *"putting it in `@qits/ui-components` would push a transport dependency into seven SPAs that
make no requests, and turn every change to it into a library publish plus a version bump in eight
applications."* Same argument, larger components.

Revisit when a **second** SPA needs the same tree. Not before.

Three consequences to plan for:

- **Draw the chevron in CSS.** The explorers' `▸`/`▾` literals are the parked tofu bug; this repo has
  no tree yet, so it inherits nothing. A bordered pseudo-element triangle, rotated on expand.
- **The terminal collides with "no lazy loading".** xterm.js is roughly 250 kB against a 500 kB
  initial-bundle warning and a 1 MB error. Use `@defer (on interaction)` on the terminal panel — a
  template-level deferral, not route lazy-loading, and it *is* the latch-on-first-selection rule
  expressed in Angular. Same for the code viewer's syntax highlighter and the markdown renderer.
  Report the measured bundle size in the ship workstream; raise the budget deliberately if it moves,
  rather than letting a threshold decide the architecture.
- **First cut ships the viewer with line numbers and no highlighting.** Highlighting is a named
  fast-follow behind the same `@defer`. A monospace pane with line numbers, ranges and a highlight
  overlay is the load-bearing 90%.

---

## Scope

### In, and in this order

**Six tabs plus one transient**, answering the spec's "ten is a lot" directly (⚖4 below):

1. **Starting** — transient, pinned first, auto-selected, lingers ~5 s after `done`.
2. **Chat** — conversation, prompt panel, terminate.
3. **Files** — tree, filters, viewer, line picking, both entry points.
4. **Services** — services panel and the durable events feed.
5. **Actions** — actions, the run history, and **Bootstrap as a section** (see below).
6. **Web view** — the framed app. Element picker is ⚖5.
7. **Agents** — embedded session, activity, session tree, plugins.

Plus a proper **status strip** in the header — runtime state, runtime error, daemon connected-since,
daemon version, outdated-daemon warning with its recreate, clean/dirty, ahead/behind, resolution
status. Every field is already on `WorkspaceDto`; the old screen simply ignored them. This is the
single biggest improvement available and it costs one component.

### Out, deliberately

- **Speech capture.** A server-side speech runtime, a WAV recorder, an audio-level meter and a second
  model call, to produce text in a textarea. Ship the textarea. **Keep "Refine into prompt"** — the
  daemon's `POST /prompt-refinements` survived the split, so the refine half is free.
- **The Sketch tab.** It does not survive a reload, its persistence never landed, and pasting a
  screenshot covers the same delivery path. Keep image attachment by paste.
- **Bootstrap as a tab.** It is a repository-level declaration whose only per-workspace content is
  "when did each step last run here". It becomes a section in Actions.
- **Telemetry, in the first cut.** Cheaper than the spec thought (the endpoints are documented and
  live) but still secondary, and it has no live hint. Phase two.
- **Anything the platform deliberately deleted upstream, which must not be resurrected:** per-line
  log observers, pattern and severity based error detection, file log sources, the `DEGRADED` service
  status, and host-side service supervision (launcher, liveness poll, restart policy, straggler
  reaper, boot re-adoption, scheduler, health probing). The host issues start/stop and projects what
  the daemon reports. Double supervision meant a socket blip could put host and daemon into a port
  fight.
- **Host routes that forward.** Decision 1.
- **The code/config action origin split.** There is one origin now. Do not build a badge for a
  distinction the platform no longer has.
- **The inline fire-and-await action result panel.** No HTTP path exists for it. A config action is
  spawned like any other command and reports through the run history.

---

## The backend work

Everything here is small and well-specified. The order is: host gaps, then the daemon contract, then
the MCP tool.

### In `services/qits-workspaces`

**1. `GET /workspaces/{id}` → `WorkspaceDto`.** `WorkspaceService.getWorkspace(id)` already exists and
is already the return value of `stop-container` and `delete-container`. Five lines plus a test plus a
regenerated `docs/openapi.yml`. It removes the "a detail view cannot be opened without knowing the
repository" constraint from *reads*, though the activity bar still needs the repository-scoped list.

**2. The prompt-draft controller.** `WorkspacePromptDraftService` (get/save/delete/recordRun/
hasDeliverablePrompt), `WorkspacePromptDraftDto`, the `WorkspacePromptDraft` entity, the
`workspace_prompt_draft` table and the `PROMPT_DRAFT` SSE topic all exist. **Only the REST layer is
missing**, and nothing calls the service today — verified: `saveDraft`, `getDraft`, `deleteDraft`,
`recordRun` and `hasDeliverablePrompt` have zero callers outside their own file.

`GET`/`PUT`/`DELETE /workspaces/{id}/prompt-draft`. The service already validates JSON
well-formedness (400) and a 2 MB combined cap (413), and already does an H2 `MERGE` upsert
specifically because two concurrent first-saves would otherwise collide on the shared PK. The
controller adds nothing but the HTTP shape. Return the persisted entity so the client gets the
DB-assigned `updatedAt` byte-for-byte — the client stores it to dedup its own SSE echo.

**3. The prompt-attachment controller.** `GET`/`POST`/`DELETE
/workspaces/{id}/prompt-attachments[/{attachmentId}]` over `WorkspacePromptAttachmentService`, the
`workspace_prompt_attachment` table and the existing 64 MB body limit configured for exactly this.
`PROMPT_ATTACHMENTS` is a separate topic on purpose — sharing one with the draft would re-download
every image on every debounced keystroke save.

**4. A reader for `workspace_bootstrap_run`.** `BootstrapRunService` writes it and, in the service's
own words, "now has no reader". `GET /workspaces/{id}/bootstrap-runs` → per step name, outcome,
timestamp, exit code and log reference. Host-owned state; not a forwarder. The *run* verbs stay on
the daemon.

**5. Regenerate `docs/openapi.yml`** via `OpenApiSchemaExportTest` and commit the diff. The diff is
the assertion. Note the SSE controllers stay `@Operation(hidden = true)` — they are consumed with a
raw `EventSource`, not a client.

Two traps this repo will bite you with: an SSE method returning a `Multi` runs on the IO thread, so
any database lookup inside one must be `@Blocking` or it answers 500 (`WorkspaceEventsController`
carries the annotation and the reasoning); and every new literal route has to be repeated in
`quarkus.quinoa.ignored-path-prefixes` or Quinoa's SPA fallback serves `index.html` to a machine
client with a 200. Neither applies to a plain JAX-RS resource under `qits.rest.path`.

### In `daemons/qits-workspace-daemon`

**6. `docs/openapi.yml`, hand-written.** Every route in `WorkspaceApi`'s dispatch ladder, every field
in `WorkspaceJson`/`CommandJson`/`AgentJson`, and both socket protocols including the
`qits_agent_meta` anchoring line. Acceptance: every documented field is asserted by a literal-string
test in the same commit. This is the artifact Decision 1 rests on.

**7. Enrich `GET /services`.** Add `restartCount`, `health` (the declared checks and their last
results), and `webView` (`{port, entryPath, basePath}` from `WebViewDecl`) — all of which the daemon
already holds and publishes only on the control socket's `ConfigView`. This is what makes the
Services panel and the Web view tab possible at all. Do **not** add `DEGRADED`; it is host-derived
from log observers that were deleted.

**8. Consider `webViewable` as a derived boolean** so the Web view's service selector is a filter
rather than an inference.

### Phase two: the `taskPrompt` MCP tool

The launch path's `deliverTaskPrompt: true` sends the agent to fetch a tool nobody wrote. Two ways to
close it:

- **A new `/workspaces/mcp` server in qits-workspaces**, one tool, `taskPrompt`, returning the
  serialized prompt plus the attachments as `ImageContent`. It follows the platform's existing
  `/<segment>/mcp` convention exactly (`/projects/mcp`, `/observability/mcp`), needs a
  `PublicPaths` entry at the gateway (both siblings have one — the callers are agents in containers
  holding no user token), an `ignored-path-prefixes` addition, and a `DaemonMcpEndpoints` change so
  the daemon can address a fourth server.
- Rejected: **putting `taskPrompt` on qits-projects' existing `repository` server**, which is already
  public and already addressed, with a `WorkspacePromptLookup` port reading from qits-workspaces.
  Cheaper — no daemon change, no gateway change — but it puts a workspace's prompt and up to 64 MB of
  its images behind the repository server, and makes qits-projects carry a passthrough it has no
  reason to know about. The coupling is exactly what the split exists to remove.

**The first cut does not wait for it.** `POST /agents` with `deliverTaskPrompt: false` and
`initialContext` set delivers the composed prompt **inline**, and that works today with zero backend
change. Text, code references and picked elements are all text. **Only image attachments need the
fetch path**, because an image cannot ride an argv or a PTY keystroke — which is the reason the
inversion exists in the first place. So: ship the prompt panel with text and references in phase one;
image paste lands with the MCP tool in phase two.

---

## The live-data plan

The server side needs nothing. The client side is new — no SPA on this platform has ever opened an
`EventSource`.

**One channel per workspace.** `GET /workspaces/api/workspaces/{id}/events`, one `EventSource`,
opened by the shell and owned by it. Not one per panel: the whole point is that eight polls became
one connection.

**Payload-free topics map to cache invalidations.** A small `WorkspaceEvents` service holds the
`EventSource` and exposes one `invalidations` signal per topic (a counter, bumped on each frame).
Panels react with `effect()`s that read the counter and their own visibility gate. `ping` and any
unrecognised topic are ignored — the client must tolerate a topic a newer service invented, exactly
as `WorkspaceDaemonRegistry` tolerates one a newer daemon nudges about.

**Invalidate everything once on every connect and reconnect.** The `onopen` handler bumps every
counter. There is no replay protocol, no `Last-Event-ID`, no resume token and no snapshot-then-delta,
and there must not be: the browser's own reconnect handles the retry and one burst of requests
removes an entire class of correctness bugs. This is the single most copyable decision on the screen.

**No polling anywhere on this page.** That is a rule, not a tendency. The explorers poll because they
have no channel; this page has one.

**The visibility discipline still applies, one level down.** The explorers pause polling on
`document.hidden`; this page pauses *refetching* on a hidden panel and does one catch-up read on
becoming visible (Decision 2). `DOCUMENT` is injected, never global, so specs can fake `hidden`.
Every listener is removed through `inject(DestroyRef).onDestroy`.

**The other three transports each need their own treatment.**

*The technical-process stream.* Payload-bearing, separate from the hint channel, `EventSource` on
`/workspaces/api/technical-processes/{id}/events`. Every connect replays all buffered segments and
lines with fresh ordinals — so **reset local state and rebuild from the replay**, which is the
intended contract, not a fallback. A 404 is fatal (unknown or evicted id) and maps onto the explicit
state *"The log stream ended before the process finished (it may have expired)"*. Close the source
yourself on the terminal frame; the server completes the stream anyway, but closing is what stops the
reconnect. The one documented failure hint is `remote-auth`, whose `hintTarget` names the repository
to sign into — **and for a submodule child that is not the root repository**, so act on the target you
are given.

*The chat socket.* Replays the whole conversation on attach, so re-attaching costs nothing.
Auto-reconnect on close after ~1.5 s. Messages sent while down are queued and flushed on open, and a
send while closed triggers an immediate reconnect attempt.

*The terminal socket.* The most carefully tuned piece, and every rule was learned from a real
failure. Opening re-attaches and replays scrollback; closing only detaches. A clean server close
(1000) is final — print `[disconnected]` and stop. Everything else reconnects with exponential
backoff capped at 4 s, five attempts, each attempt resetting the terminal and letting the replay
repaint it. **A spent budget re-arms on `visibilitychange` and on `online`**, because a laptop sleep
outlives an 8-second window and "I'm back" is an event, not something to poll for. Key the terminal
by command id so a relaunch recreates it rather than reusing a socket bound to a dead process.

**Generation tokens.** `/files` and `/detection` both carry `generation`, computed by two byte-identical
implementations of the same sha256. Apply detection only while its token matches the tree currently
rendered; on a mismatch **hold the last consistent detection rather than blanking it**, and let the
next tick resolve it. The tokens agree on first load, so there is no initial flash. Any pair of
independently-fetched views over one mutable tree needs this, and without it the page flickers in a
way that is very hard to diagnose later.

**Shared cache entries.** One workspace-list entry feeds the header, the status strip, the activity
bar and the Agents dot. One command-list entry feeds the Chat tab, the Actions history, the session
tree and the embedded session. One services entry feeds the panel, the tab dot and the Web view. One
detection entry feeds the file browser and the plugin recommender. The discipline that makes this
work is identical key *and* identical result shape — in a signals codebase that means one
`@Injectable` owning one signal, injected everywhere, never a second fetch with the same URL.

**Two things do not participate.** The component attribution map is fetched once per pick-mode
activation (a map that misses a just-created component simply skips attribution). The available
agent harnesses are fetched once.

**And one thing has no live signal at all:** `telemetry` fires from nothing. If the Telemetry tab
ships, it refreshes on visibility and on demand, and that limitation is stated in the UI rather than
faked with a poll.

---

## Three decisions preserved, so no future reviewer simplifies them

**The agent session never auto-resumes.** The Agents tab resolves in exactly this order: an
attachable running interactive run → attach; a running chat → **defer** with a jump link, because a
concurrent resume of the same session is the exact collision session-pinning exists to prevent; no
history at all → launch fresh; **history exists but nothing is running → idle on an explicit
choice.** That last branch looks wrong and is right. The recorded last session can be gone from the
agent's own state — a re-materialised container, pruned volume state — and auto-resuming a vanished
id exits instantly with "no conversation found", in a loop the user never asked for. A finished run
does not auto-relaunch either, because a crashing agent would loop. On Resume the harness picker is
shown but **disabled**: a resumed session keeps its original harness; only a fresh launch may pick.

**The prompt draft flushes synchronously before launch, and a failed flush aborts the launch.** Keep
this even in the first cut, where the prompt is delivered inline and the race it defends against is
temporarily absent. Two reasons: the moment attachments land, delivery inverts back to fetch and the
discipline has to already be there; and a draft that failed to save is work the user is about to
lose, which is worth aborting for on its own. Fail loudly; launching with the wrong prompt is worse
than not launching.

**The file tree and the framework detection are gated on a shared generation token.** See the live-data
section. Hold the last consistent detection on a mismatch; never blank it.

Two more worth adding to the list, because they are equally easy to "simplify" away: **the user's own
chat turn is rendered from the server's echo, never optimistically** (it is what guarantees the live
view and a later replay show the same thing in the same order); and **mutations invalidate on
settled, not on success**, with per-row spinners keyed to the row actually being acted on, so a
failed start still refreshes the truth and one Run click does not spin every row.

---

## Workstreams (one Opus 5 agent each)

Letters continue the platform sequence. X–AC are burned by the release flow and AD–AG by the hops
plan, so this feature starts at **AH**.

Ship step, unless a workstream says otherwise: `npm run test` / `./mvnw verify` green, then **push
both remotes** — GitHub `origin` and the platform git host
(`git push http://localhost:8080/artifacts/git/<repo> main`). A push to `main` on the platform host
needs `-o qits.token=local-dev`. The traps in the Verification section apply to every push.

### AH — the host's own gaps (repo: `services/qits-workspaces`)

Lands: `GET /workspaces/{id}`; the prompt-draft controller; the prompt-attachment controller; the
`workspace_bootstrap_run` reader; regenerated `docs/openapi.yml`.

Must not touch: `ContainerProxyRoute`, `ServiceProxyRoute`, the daemon control socket, or anything
that would re-add a forwarding route for services, bootstrap-run, files, commands or agents.

Verifies: `@QuarkusTest` per endpoint including the concurrent-first-save upsert path (the H2 `MERGE`
exists for exactly that reason), the 413 cap and the 400 on malformed JSON; the committed
`docs/openapi.yml` diff; `./mvnw verify` green. New literal routes: none — everything is JAX-RS under
`qits.rest.path`, so `ignored-path-prefixes` needs no change. Confirm that in the report.

### AI — the daemon contract and the services enrichment (repo: `daemons/qits-workspace-daemon`) — parallel with AH

Lands: `docs/openapi.yml`, hand-written, covering every route in `WorkspaceApi`'s dispatch ladder and
both socket protocols; `GET /services` enriched with `restartCount`, `health` and `webView`.

Must not touch: the control-socket protocol or `DaemonProtocol.CAPABILITY_VERSION` — the enrichment
is HTTP-only and adds no wire message. `workspace-daemon-protocol/` is vendored byte-identically in
qits-workspaces and any change there must be mirrored and bumped; this workstream should need none.

Verifies: every field in the document is asserted by a literal-string test in `ServicesApiTest` /
`CommandsApiTest` / `AgentsApiTest` / `WorkspaceApiTest` in the same commit; `./mvnw verify` green.

Blocking pre-flight: confirm that `DEGRADED` stays out and that the health results being added are
the daemon's own observations, not a re-homed host log observer. If the health machinery turns out
not to exist inside the daemon, **stop and report** — that changes ⚖1's boundary.

### AJ — the SPA shell (repo: `frontends/qits-spa-workspaces`) — parallel with AH and AI

The foundation everything else mounts into. Contracts above are frozen, so it waits for nothing.

Lands: the detail route and its remount guard; the header and the **status strip** (runtime state,
runtime error, daemon connected-since/version/outdated with its recreate, clean/dirty, ahead/behind,
resolution); the activity bar; the tab host with the latch-and-hide contract, the two-loop reorder,
label status dots and the front-pinned transient slot; the Starting tab over
`/technical-processes/{id}/events`; the `WorkspaceEvents` SSE client with invalidate-everything-on-
connect; the `WorkspaceDaemonApi` transport skeleton; `eslint.config.js` and a `lint` script (copy
spa-ci's with the `app` prefix, and put the line back in `.config/qits/ci-post-receive.yml` where its
comment says it goes).

Must not touch: `QITS_NAV_LINKS` or anything in `libs/qits-spa-ui-components`. Reuse the existing
`ui/loadable.ts`, `ui/async.ts`, `ui/empty.ts`, `ui/format.ts` — do not promote them.

Verifies: the shell's load budget stated in prose on the page component **and asserted in its spec**;
a spec proving a tab switch does not destroy a panel and that reordering does not move one; a spec
with fake timers proving the SSE client bumps every counter on `onopen`; `recreate-container` is
disabled with an explanation whenever `clean` is not exactly `true` (the endpoint refuses with 400
otherwise, and "unknown" counts as not-clean — which matters because recreate is the remedy for
`daemonOutdated` and an outdated daemon may well be a disconnected one). Draw the chevron in CSS.

### AK — Files, part one: the tree (repo: `frontends/qits-spa-workspaces`, after AJ)

Lands: the tree over `GET /files`; lazy directories with their `childCount` labels and per-directory
caching; path compaction with lazy directories as boundaries; the fuzzy name filter with glob forms;
the framework quick-access footer; the generation-token gate against `/detection`; the "N collapsed
directories not searched" footer.

Reproduce the expansion distinction: **a name search or a manual rule expands the tree fully** (deep
matches must be visible), **a framework toggle expands to a framework-sensible depth** (browsing, not
searching). It is a real decision and it is easy to flatten by accident.

### AL — Chat and the prompt panel (repo: `frontends/qits-spa-workspaces`, after AJ; needs AH deployed for the draft)

Lands: the chat conversation over `WS /chat/commands/{id}` — user turns from the server's echo,
assistant text, thinking blocks, tool calls, tool results truncated at a few thousand characters,
error-styled system lines for failures only, and sub-agent side-chains folded into collapsible groups
anchored on the `qits_agent_meta` line's `toolUseId` (a side-chain whose anchor is missing appends at
the end). The socket's queue-and-flush reconnect. The prompt panel: textarea, "Refine into prompt"
over `POST /prompt-refinements`, "Use transcript as-is", picked-context rows, the restored-draft hint
with its Discard, the debounced autosave, and **flush-then-launch with abort-on-failure**.

Two things to get right: side-chains join only after the exit sweep, so a live session shows the main
thread and gains its side-chains when the run ends — say so in the UI rather than looking broken. And
image paste is **not** in this workstream; it lands with the MCP tool.

### AM — Services and Actions (repo: `frontends/qits-spa-workspaces`, after AJ; needs AI deployed)

Lands: the services panel (name, description, status chip with restart count, health results, logs
link, Start/Stop) with its aggregate label dot; the durable events feed over
`GET /service-events`; the Actions list and the run history; the **Bootstrap section** inside Actions
over the daemon's `GET /bootstrap-commands` joined with AH's `GET /workspaces/{id}/bootstrap-runs`.

Two traps, both measured. **`/service-events` filters by `workspaceId`, the branch-derived label,
not by the row id** — and that label is reusable once a workspace resolves, so a recycled label
surfaces a previous workspace's events. Filter client-side on `workspaceRowId`, which the DTO
carries. And **the run history comes from the daemon, so it disappears when the container stops**;
`WorkspaceCommandHistory` has no implementation anywhere, so there is no host fallback. Render that
as an explicit state ("the container is stopped — run history lives in the container"), not as an
empty list.

### AN — Files, part two: the viewer (repo: `frontends/qits-spa-workspaces`, after AK)

Lands: the read-only viewer with line numbers over `GET /files/content` (binary and over-2 MB both
arrive as `binary:true` with no content — distinguish them in the copy if the size is knowable, and
say "too large or binary" if not); the advanced filter dialog with its ordered last-match-wins rules
and live preview truncated at 500; dynamic filters (ignore-lists and frameworks) layered under the
manual rules with the fixed precedence framework → ignore-list → manual; test/code tabs normalised
through the owning source, with reachable tests hidden from the tree except while name-searching;
line picking with its sticky mode, chips, painted highlight and prompt-draft entry; and **both entry
points** — open-at-exact-range (which must work for files not in the tree at all) and
open-closest-match (which seeds the name filter exactly as if the user had typed it, so the user sees
*why* the tree is narrowed).

Syntax highlighting and the rendered-markdown view are `@defer`red fast-follows, named here and not
built.

### AO — Agents and Web view (repo: `frontends/qits-spa-workspaces`, after AL and AN)

Lands: the embedded session with its four-branch resolution and the never-auto-resume rule; the
sign-in-terminal special case that re-runs resolution and **replays the launch the sign-in
interrupted**; the activity badge; the session tree over the daemon's nested `agent-sessions`, with
per-lineage accent colours and Resume hidden while anything owns the conversation; the plugins
section; the Web view with its service selector, URL bar reading the framed window's live location,
and the same-origin frame over `/workspaces/service/{id}/{serviceId}/`.

The activity-tracking checkbox is **not** built — no endpoint reads or writes it. Render the current
value read-only if it is worth showing at all, and say where it is configured.

The element picker is ⚖5. If it is in, it lands here, one-shot with shift-to-multi, with the
component attribution map fetched once per activation and the "picker unavailable on external pages"
state.

### AP — embed and ship (repo: `services/qits-workspaces`, after AK/AL/AM/AN/AO)

Lands: the `service/src/main/webui` gitlink advanced to qits-spa-workspaces' new `main`, committed as
an explicit path (`ignore = all` hides submodule drift from `git status` but not from `git add -A`).
Verify locally that `./mvnw -pl service -am package` builds the client through Quinoa, then push both
remotes and let the pipeline redeploy.

Then the browser pass through the real gateway (see Verification). Report the measured initial bundle
size against the 500 kB warning.

### AQ — phase two (after AP)

The `taskPrompt` MCP server and image attachments; the Telemetry tab over qits-observability's
documented endpoints; syntax highlighting and rendered markdown. Each is independently shippable.

### Ordering

```
AH ∥ AI ∥ AJ
        ↓
AK ∥ AL ∥ AM        (AL needs AH deployed; AM needs AI deployed; all three need AJ)
        ↓
AN ∥ AO             (AN after AK; AO after AL and AN)
        ↓
AP
        ↓
AQ
```

### Cost, honestly

Ten workstreams, four of them large (AJ, AL, AK+AN together, AO). This is the biggest screen in the
product and the plan does not make it small — it makes it sequenced. Expect it to cost more than the
CI and CD explorers combined, expect Files to eat roughly a third of it across AK and AN, and expect
three or four qits-workspaces deploy cycles rather than one. The backend really is the cheap half:
AH and AI together are perhaps a tenth of the total, which is the one genuinely good piece of news in
the measurement.

---

## Verification

There is **no E2E framework** on this platform — verified, no Playwright or Cypress in any frontend's
`package.json`. "Browser-E2E'd" means a scripted manual pass, run with the DevTools or Playwright MCP
tools.

**Unit tests.** Vitest on jsdom through `@angular/build:unit-test`; there is no vitest config file
anywhere and there should not be one. `HttpTestingController` for every transport. `RouterTestingHarness`
for the route. Fake timers for the SSE client, the terminal backoff and the Starting tab's linger.
Per-panel specs must assert every state in the spec's state table, and the load budget must be
asserted, not just written down.

**Packaged surface.** qits-ci and qits-cd both carry a `*PackagedSurfaceIT`; qits-workspaces should
gain the equivalent probes in AP — that `/workspaces/` serves the SPA, that a deep detail link
survives a reload through `enable-spa-routing`, and that `/workspaces/api/nope`,
`/workspaces/container/`, `/workspaces/daemon` and `/workspaces/service` answer machine answers
rather than `200 text/html`. That last class of bug has already been measured on this repo once.

**The browser pass, through the real gateway.**

1. Create a workspace and watch the Starting tab: segments open, auto-expand, settle, the tab lingers
   ~5 s and unmounts. Confirm a manual toggle overrides the auto-collapse permanently for that
   segment.
2. Open Files, expand a lazy directory, filter by name, toggle a framework, open a file, pick a line
   range, and confirm the chip appears on Chat.
3. Launch an agent from the prompt panel and confirm the panel swaps for the conversation **in
   place**, with no navigation.
4. Switch tabs while the agent is cooking; come back and confirm the conversation continued, the
   framed app did not reload, and the open file and scroll position survived.
5. From a service event, hit "open in source" and confirm the cross-tab jump lands on the right file
   at the right lines — including for a file that is not in the tree.
6. Kill the workspace container's daemon socket and confirm the failure is legible: Files, the
   terminal and the agent surface all 502, the status strip says the daemon is gone, and everything
   recovers when it reconnects. **This is the single most important negative test**, because the
   tunnel made the control socket load-bearing and nothing on the old screen behaved this way.
7. Watch the network panel: confirm an idle workspace produces **zero** requests, that no panel
   polls, and that a hidden tab does not refetch.

**Operational traps, every one of which has bitten this platform.**

- **No CI run row after a push** → replay `POST /ci/api/events/post-receive` with the pushed sha.
  Replays are not idempotent, and a missing row while the worker is busy means QUEUED, not lost.
- **A green run with no deployment row, plus "database has been closed" in cd's logs** → restart the
  qits-cd container and replay `POST /cd/api/events/build-succeeded`.
- **Every SPA serves `index.html` with `immutable, max-age=86400`** — measured again today on
  `GET http://localhost:8080/workspaces/`. A returning browser gets a blank or stale page after every
  deploy. **Hard-reload before judging anything.** The fix is a seven-service rollout parked in the
  handoff; do not attempt it inside this feature.
- qits-workspaces redeploying itself is part of this rollout, so the self-redeploy cutover blip
  applies on every AH and AP push.
- There are **no ACTIVE workspaces on the local platform right now** — `GET /workspaces?repositoryId=`
  returns `{"entries":[]}` for every repository. Creating one is the prerequisite for any of the
  browser pass, and none of tier 2 can be exercised before that.

---

## The open questions ⚖

Each carries a recommendation so they can be answered in one pass.

**⚖1 — how does the browser reach the daemon?**
*Recommendation: option A with a written contract, under the line "the proxy carries everything the
daemon owns; the host serves only what the host owns; nothing forwards."* Argued in full above. This
is the one that must be answered before any tab is built.

**⚖2 — does the detail view get the lifecycle verbs?**
Discard, integrate, merge, release and the container controls live only on the list today. The API is
ready for all of them and `recreate-container` even has its guard (400 unless the tree is provably
clean).
*Recommendation: yes, and put them in the status strip rather than a toolbar.* The detail view is the
page that **is** the workspace and it is currently the one place you cannot see its state or finish
its work. Start/stop/recreate belong next to the runtime state they act on; integrate/discard belong
next to the resolution status. Keep them on the list too — the list is where you act on a workspace
you are not inside.

**⚖3 — what does a resolved workspace's detail view look like?**
Today it is undefined: a resolved workspace is not in `GET /workspaces?repositoryId=` at all, so the
page cannot open it. `GET /history/{id}` does serve it, with the narrative and the event timeline but
no branch, no runtime and no commands (the command history port has no implementation).
*Recommendation: the detail view does not open a resolved workspace.* Route to the history record
instead, with a one-line explanation. Half a detail view — six tabs that all 502 because there is no
container — is worse than an honest redirect. Revisit if `WorkspaceCommandHistory` ever gets an
implementation, which would make a read-only Actions history meaningful.

**⚖4 — how many tabs?**
*Recommendation: six plus the transient.* Chat, Files, Services, Actions, Web view, Agents. Bootstrap
folds into Actions (its entire per-workspace content is three lines of status, and it is the only tab
whose whole content disables while its one action runs). Telemetry goes to phase two — it is real and
now known to be cheap, but it is three sub-tabs of a buffer whose most-used feature is a toggle
hiding the noise it generates, and it has no live hint.

**⚖5 — is the element picker in the first cut?**
It is the most distinctive thing on the screen and the most expensive: a proxy (exists), a same-origin
frame (exists), a DOM picker (new), and a component attribution map (exists on the daemon).
*Recommendation: yes, but last, in AO, and behind a clean cut line.* The frame without the picker is
already useful, so ship the tab when the frame works and add the picker within the same workstream if
the budget holds. Do not let it block the tab.

**⚖6 — does tab order still persist per browser?**
*Recommendation: no, drop it.* It buys per-device ergonomics on a row of six and costs a stored-order
migration every time a tab is added or renamed — and this reimplementation is renaming and removing
tabs on day one. Keep drag-reordering **within the session** (free, local signal, dies with the page),
and revisit persistence only if someone asks. Note the asymmetry that is worth preserving either way:
tab order is device ergonomics; the prompt draft is work product and lives on the server.

**⚖7 — is speech dead or paused?**
*Recommendation: dead as a flow, alive as a possible input method.* The recorder, the level meter and
the second model call all go. **Keep "Refine into prompt"** — the daemon's `POST /prompt-refinements`
survived the split and is one button on a textarea. Note that qits-stt is a live service on the
platform; nothing in this plan uses it, and confirming that is the point of the question.

**⚖8 — should a dropped live channel show a reconnecting marker?**
The spec calls today's silence a gap rather than a design choice, and the measurement above makes it
worse than it looked: a dropped **daemon control socket** now takes the entire file browser, every
terminal and the whole agent surface down, and the only symptom is a wall of 502s.
*Recommendation: yes, and split it in two.* A quiet inline marker for the SSE hint channel (data is
stale, it will catch up). A **first-class state in the status strip** for the daemon, because that
one is not cosmetic — it is the difference between "this page is briefly behind" and "half of this
page cannot work right now."

**⚖9 — the activity bar's "Ended" state, which the host cannot report.**
New, and it invalidates a design the spec treats as settled. `WorkspaceDaemonRegistry` *evicts* on
`ENDED`, so `WorkspaceDto.agentActivity` is `BUSY | WAITING | IDLE | null` and never `ENDED`. The
consequence is not cosmetic: the bar's whole point is that **a session that has just stopped bubbles
to the far left, because that is the workspace that needs your next prompt** — and today it silently
disappears at exactly that moment. Three ways out:

- Stop evicting: keep `ENDED` in the rollup and let it expire on a timer. Small host change, restores
  the design as specified, and makes the client enum fix meaningful.
- Keep the eviction and derive "recently ended" client-side from the transition to `null`. No backend
  change; loses the state across a page reload, which is when you most want it.
- Drop the fourth state and accept a three-state bar.

*Recommendation: the first.* It is a handful of lines in `onAgentActivity`, it is the only option that
survives a reload, and without it the bar's ordering rule — the subtlest and best decision on the
whole screen — is decoration.

**⚖10 — does the run history need a host reader?**
`WorkspaceCommandHistory` is an unbound port, so there is no host-side command history for any
workspace, live or resolved. The Actions history therefore lives entirely in the container and
vanishes with it.
*Recommendation: accept it for this feature and name it in the UI.* Binding the port means the host
persisting command rows again, which is a real feature with its own plan (and the natural home is the
workspace history surface, which also wants the bootstrap-run reader AH is adding). Do not smuggle it
in here.
