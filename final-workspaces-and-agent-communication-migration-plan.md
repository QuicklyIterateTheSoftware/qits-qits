# How qits reaches a workspace daemon

Status: **done, both stages.** Written 2026-07-28, implemented the same day.
Amended in place where implementation contradicted the design — every such amendment says so and
says why, because a plan document that quietly agrees with the code it produced is worth nothing.
Resolves [`migration-plan.md`](migration-plan.md) §9 items 9 (the daemon half) and 16, and shrinks
item 21. This is the fifth migration document. `migration-plan.md` maps files,
`migration-deployables-plan.md` maps what runs — this one maps **how the pieces reach each other**
across the one boundary the split left unaddressed.

---

## 1. The defect, stated precisely

Twelve REST operations and two websockets that the SPA calls live only in
`daemons/qits-workspace-daemon`, and nothing can reach them. The plan's item 16 names two causes —
no gateway route, and `QITS_WORKSPACE_DAEMON_API_TOKEN` never injected, so `WorkspaceApi` fail-closes
and does not bind at all. Both are real. Neither is the actual problem.

**The actual problem is direction.** `WorkspaceApi` is an *inbound* listener on `0.0.0.0:13338`,
reachable by DNS name from every other container on `qits-net` — including other workspaces, each
running a coding agent over someone else's untrusted checkout with unrestricted outbound network.
Its own javadoc sets that threat model out in full (`WorkspaceApi.java:88-105`) and defends it with
one shared secret. That secret is the only thing standing between one workspace's agent and every
other workspace's working tree, and today it is not even wired.

Stage 1 wires it without strengthening it (§5 step 1) — under the trusted-`qits-net` posture that is a
deliberate deferral, not a fix. Stage 2 is where the surface stops existing.

> ### The REST surface is not the mistake, and rewriting it is not the fix.
>
> A resource-shaped API over one workspace's checkout is a reasonable shape, the daemon serves
> exactly one workspace so it carries no `{repoId}/{workspaceId}` prefix to get wrong, and the SPA
> already speaks it — `CommandJson` and `AgentJson` deserialize into the host's existing DTO records
> unchanged. What has to change is how a call arrives, not what it looks like when it does.
>
> This matters for scoping: everything below is transport and addressing. No handler in
> `WorkspaceApi` changes, and no message shape the browser sends changes.

## 2. What is actually true today

Audited, not assumed:

| | Finding |
|---|---|
| `WorkspaceApi` bind | `0.0.0.0`, port from `qits.workspace-daemon.api-port` (default 13338). Distinct from `HookWebhook`, which binds `127.0.0.1:13337` because its only client shares the network namespace. |
| The API token | `qits.workspace-daemon.api-token`, `Authorization: Bearer`, compared with `MessageDigest.isEqual`. **Absent ⇒ the server does not bind**, with a warning. |
| `WorkspaceContainerFactory` | injects fourteen `QITS_WORKSPACE_DAEMON_*` vars. **`_API_TOKEN` is not one of them.** |
| A host-side client for the daemon's API | **does not exist.** No reference to `13338`, to `api-token`, or to any daemon HTTP client anywhere in qits-workspaces. The entire host side is greenfield. |
| Gateway route table | static config (`QITS_GATEWAY_PROXY_HOSTS_*`), segment-aware prefix match, forwarded **verbatim** — no rewriting, and `/` is rejected rather than normalised into a catch-all. |
| Container reachability | by DNS name on `qits-net`. The name is *derived* host-side: `WorkspaceContainerFactory.containerName(workspaceId, repoId)`. |
| Precedent for a host-side proxy | `ServiceProxyRoute` — `HttpProxy.reverseProxy`, origin resolved exclusively from supervisor state, vertx-http-proxy forwards WebSocket upgrades by default. |
| The control socket | outbound-dialled by the daemon, one per workspace, already carrying correlated request/reply (`WorkspaceDaemonRegistry.runCommand/describe/describeConfig` over `CompletableFuture`) and correlated output streams (`provision`, `bootstrap:<name>`, `service:<name>`). |
| `CAPABILITY_VERSION` | 3 in the daemon and in qits-workspaces' vendored copy, 2 in `../qits`. Already diverged once (§9 item 19). |
| Authorization on daemon calls | **none anywhere.** The daemon has no idea who the user is; the token is peer authentication, not user authentication. |

The fourth row is the licence for this document. There is no client to preserve and no caller to
keep compatible, so the choice here is not between the cheap fix and the right one — the host side
gets written from nothing either way.

## 3. The decision

**Every call to a daemon goes through qits-workspaces.** The gateway routes `/workspaces/*` to
qits-workspaces as it already does; qits-workspaces resolves the workspace, authorizes the caller,
and forwards to that workspace's daemon. Nothing else may reach a daemon.

Three invariants, each of which forecloses a plausible-looking alternative:

> ### The daemon is never a gateway route.
>
> This settles the open half of §9 item 9: **there is no `DAEMON` constant in `QitsService` and there
> must not be one.** The gateway's route table is static configuration mapping one path prefix to one
> `host:port`. A daemon is one process per workspace container, addressed per workspace and living
> for one container lifetime — it has no stable address to configure, no health check to register,
> and no segment it could claim without conflating itself with qits-workspaces' own routes. Routing
> it under `/workspaces` at the *gateway* would conflate two repos; routing it under `/workspaces` at
> *qits-workspaces*, which owns the workspace row and the container lifecycle, is simply that service
> serving its own resource.

> ### The host never learns an address from a container.
>
> The daemon could announce its address in its `Hello`, and it must not. The container runs an
> untrusted checkout: an address it reports is attacker-controlled input, and a host that dials it is
> an SSRF primitive aimed at everything on `qits-net`. `ServiceProxyRoute` already fixed this rule for
> dev servers — *"the origin is resolved exclusively from supervisor state — the container name and
> port come from the service definition recorded at launch, never from any request component"* — and
> the host already derives the container name deterministically. Nothing needs announcing.

> ### The protocol grows with the transport, not with the endpoint count.
>
> Whatever carries these calls, adding a daemon capability must not mean adding a control-plane
> message type, a `Type`/`Field` constant pair, two codec arms, a codec test case, a
> `CAPABILITY_VERSION` bump and a byte-identical mirror into qits-workspaces. That recipe is correct
> for control-plane events and unaffordable per endpoint — and §9 item 19 records that the mirrored
> copies have already drifted once. This is the invariant §4 rejects an alternative for violating.

## 4. The alternative rejected, and why

The obvious way to get "one channel" is to fold everything onto the control socket the daemon already
holds open: terminal input and output, chat, file listings, file content, the commands and agents
surfaces, all as correlated messages beside the heartbeats. It was considered seriously and is
recorded here because it is the design anyone will propose again.

**The terminal is not what makes it hard.** That is the counter-intuitive part and it is worth
stating plainly: the control socket already streams process output correlated by id —
`CommandChunk{correlationId, stream, text}` carries provisioning output, bootstrap step output and
live service stdout today. A terminal is that plus an inbound `CommandInput` and a `CommandResize`,
and both sides already hold the internals (`CommandRegistry.input/resize/attach/detach`, adapted by
`CommandSockets`). Three message types and a capability bump. `CommandSockets`' javadoc argues
against it — *"would mean new message types and a capability bump for something the daemon already
has a perfectly good HTTP server for"* — and that argument was a cost comparison resting on the HTTP
server being reachable. It is not, so the comparison is legitimately reopenable. It just does not
come out the other way, for four reasons that have nothing to do with terminals:

- **One write queue for the whole workspace.** `CommandSockets.WebSocketSink.isOpen()` returns
  `!socket.isClosed() && !socket.writeQueueFull()`, *per socket*, which is what lets the registry drop
  one stalled browser tab without buffering a terminal's output without bound. Multiplexed, that
  signal becomes workspace-global: one slow reader stalls or drops heartbeats, git status, chat and
  every other terminal along with itself. Fixing that means per-stream credit and windowing — writing
  HTTP/2's flow control by hand, inside a module whose governing rule is to check whether something
  already in the image does the job before adding a dependency.
- **Bulk bodies share the wire with keystrokes.** `CommandLogBuffer` holds 50,000 lines per command
  and `/files/content` already has a 413 for "a response the transport cannot carry". Those become
  JSON-escaped frames queued ahead of the next keypress on a single ordered stream. On a local docker
  network that is jitter rather than failure — but it is jitter chosen deliberately.
- **Availability couples.** A control-socket drop today leaves file browsing and the terminals alive.
  Folded in, a reconnect backoff takes the whole workspace dark.
- **It violates §3's third invariant** outright, and permanently.

Recorded so the trade is legible: what one-socket buys is a single outbound connection and no inbound
listener. §6 buys both of those without buying a multiplexer.

## 5. Stage 1 — reachable, authorized, no protocol change

The deliverable: every daemon operation the SPA calls is reachable through the gateway, and a caller
who does not own the workspace cannot reach it. Nothing in `workspace-daemon-protocol` changes and
`CAPABILITY_VERSION` stays at 3.

**1. Inject the token.** `WorkspaceContainerFactory` gains a fifteenth env var,
`QITS_WORKSPACE_DAEMON_API_TOKEN`, and qits-workspaces sends it as the bearer on every proxied call.

**One value, shared by every container, from one config key on qits-workspaces.** No derivation, no
per-workspace secret, no column, no migration. That is deliberate and it is the whole of the
credential design here:

> **This token is a handshake constant, not a credential, and nothing should be built as though it
> were one.** `qits-net` is trusted for the POC (§9 item 21), and under that posture a per-workspace
> secret would be machinery defending a boundary the topology does not have — every workspace already
> reaches every service on the network directly. Its only job is to satisfy `WorkspaceApi`'s bind
> precondition. Ship it with a default so a deployment needs no configuration, and say in the config
> comment what it is not.
>
> What changes if `qits-net` stops being trusted: the *value* becomes per-workspace (a host-secret
> HMAC over the workspace id is the obvious form, since it needs no storage), and the service starts
> refusing to boot without a real secret. **The injection point, the env var and the proxy's bearer
> header do not move**, so that upgrade is a change of one expression. Which is why it costs nothing
> to defer, and why the token is injected now rather than removed.

**2. Do not make the daemon bind without a token.** Nothing in `WorkspaceApi` changes in stage 1, and
this step exists only to say so. Its fail-closed no-bind behaviour is isolation that already exists;
"`qits-net` is trusted for now" licenses not *adding* isolation, and explicitly not removing it
(§9 item 21's corollary). Relaxing the bind precondition would also be a daemon-side change made to
serve a host-side convenience, which is the wrong repo for it. Note only that `0.0.0.0` becomes
unnecessary the moment §6 lands.

**3. Add the proxy route to qits-workspaces.** `/workspaces/container/{workspaceId}/**`, a raw Vert.x
route, modelled on `ServiceProxyRoute` almost line for line: resolve the workspace, resolve the
container name from `containerName(workspaceId, repoId)` and *only* from there, then
`HttpProxy.reverseProxy(client).origin(13338, containerName)` with the bearer token added by an
interceptor. WebSocket upgrades ride along, which is what carries `WS /terminal/commands/{id}` and
`WS /chat/commands/{id}` without either side knowing it is proxied.

`container` rather than `daemon` as the second-level segment: `/workspaces/daemon/{id}` is taken by
the control socket, and that literal is a baked cross-repo contract — `WorkspaceContainerFactory`
injects it as `QITS_WORKSPACE_DAEMON_URL` and only a container recreate re-injects it, which is why
`LegacyDaemonControlSocket` exists at all. Overloading the segment that is hardest to change is the
wrong economy. The shape then matches the sibling proxy: `/workspaces/service/{w}/{s}/*` for a dev
server, `/workspaces/container/{w}/*` for the daemon.

**4. Scope.** ~~Authorize.~~ **Amended: there is nobody to authorize against.** qits is a
single-user application and a workspace has no owner — no column, no principal recorded at
creation, nothing to compare a caller to. Inventing one would be machinery defending a boundary the
product does not have, and this service authenticates nothing anyway (`ForwardAuthMechanism` resolves
a name for audit rows, and its own notes are explicit that `identity.isAnonymous()` is not a security
state).

What remains is real and is the part that was always load-bearing: **an unknown workspace id, a
non-numeric one and a soft-deleted row all answer one identical 404, before anything connects to a
container.** That goes through `WorkspaceRepository.findActiveById`, the ACTIVE finder whose own
header comment already says everything operating on a live workspace must use it. Call it scoping;
calling it authorization would be the kind of overstatement §9's third risk warns about.

**Not gated on: control-socket liveness.** It was the obvious fifth state and it is a bug. The
daemon's HTTP server and its control socket are independent listeners, so a socket merely in
reconnect backoff leaves the API bound and answering — refusing there would take file browsing and
every open terminal down for the length of a blip, which is precisely the availability coupling §4
rejects one-socket for. A daemon that genuinely is not there fails the connection instead, and that
is one generic 502 worth accepting.

**5. Re-expose what the path conventions deleted.** `/workspaces/{id}/services…` and
`/workspaces/{id}/bootstrap-commands…` were removed as host routes because the work moved into the
container; the daemon's `ServiceSupervisor` and `BootstrapRunner` do it, but `WorkspaceApi` never
grew routes for them. Add them there. They are purely additive and blocked on nothing but step 3.

**6. The gate.** A `@QuarkusIntegrationTest` is not enough here — the interesting failures are in
another process. The gate is: a real container, a browser-equivalent client through the gateway, one
file listing, one file read, one command launched and terminated, and a terminal socket that echoes a
keystroke and survives a client reconnect. `CommandSockets` detaches rather than terminates on close
precisely so a refresh re-attaches; a proxy that breaks that breaks it silently.

## 6. Stage 2 — flip the direction, delete the inbound port

Stage 1 leaves `:13338` reachable by every peer container, defended by one shared secret. That is
§9 item 21's accepted-for-POC posture becoming *more* load-bearing rather than less. Stage 2 removes
the listener instead of defending it.

**The shape.** The daemon dials; the host never does. `WorkspaceApi` rebinds to `127.0.0.1` and keeps
every handler it has. When qits-workspaces needs to make a call, it asks over the control socket for a
stream; the daemon dials a second outbound WebSocket back to qits-workspaces and pipes it to its own
loopback HTTP server. The host proxies the browser's request into that stream and the response back
out.

What this buys, and it is the whole point: **one direction, one address, one credential model, and no
port on `qits-net` that a peer workspace can reach at all.** The shared secret stops being the only
boundary because there is no longer a boundary to defend. And because each stream is its own
connection, flow control and head-of-line blocking are the TCP stack's problem rather than ours — the
cost §4 refused to pay.

> **Amended: that last sentence is true of the tunnel and false of the hop in front of it.**
> `vertx-http-proxy`'s WebSocket path pipes the two sockets with no `pause`, no `drainHandler` and a
> failure arm that prints a stack trace. So browser↔qits-workspaces has no backpressure at all on an
> upgraded socket. Stage 2 neither causes nor fixes it; it is a stage-1 defect recorded here rather
> than assumed away. Both ends of the tunnel itself do pause/drain properly.

The control-plane addition is fixed and small, and does not grow with the endpoint count:

- `OpenStream{streamId, nonce, method, path, query}` — qits → daemon
- the dial-back itself, `wss://<host>/workspaces/daemon/stream/{nonce}`
- a response envelope (status, headers) as the stream's first frame, body frames after it

One `CAPABILITY_VERSION` bump, once, for the transport. Adding a daemon endpoint after that costs
nothing on the wire.

**The nonce is not decoration**, and it is not stage 1's token by another name. §9 item 22 records
that the control socket identifies its caller by a path parameter, so anything on `qits-net` can claim
to be any workspace's daemon. A dial-back stream that named its own workspace would reproduce that bug
in a second place. The nonce must be host-minted, single-use, short-lived, and bound to the workspace
the host sent it to — properties stage 1's shared constant deliberately does not have and does not
need. Introducing a genuine per-container secret is stage 2 work, not an evolution of stage 1's value;
doing it here also produces the mechanism item 22 needs for the control socket itself, and settling
both together is the cheaper order.

**The spike was run, and neither framing above is what shipped.**

The Vert.x API for "an HTTP client over a socket I supply" **does not exist** — `HttpProxy` offers
`origin(…)`, `originSelector(…)` and `originRequestProvider(…)`, and all three want a real address.
So the raw-TCP alternative is not implementable as written. But the envelope framing is not the
consolation prize either: it needs a response envelope and body frames, and it would still have to
special-case the two WebSocket upgrades that must themselves traverse the tunnel.

**A loopback listener on the host is a real address.** So: qits-workspaces binds a `NetServer` on
`127.0.0.1:0` per workspace, and the stage-1 route changes exactly one expression — the origin. Each
accepted TCP connection mints a nonce, asks over the control socket, and is piped to the WebSocket
the daemon dials back with. The tunnel carries **bytes**, so an HTTP request and a WebSocket upgrade
traverse it identically and the protocol addition is `OpenStream{nonce, path}` — one message, two
fields — instead of an envelope, a response frame and a stream id. `vertx-http-proxy` already turns
an upgraded exchange into a raw byte pipe, so the two compose rather than fight.

Three things the implementation found that the design did not, each of which fails in a way that
looks like something else:

- **`writeBinaryMessage`, never `write(Buffer)` and never `pipeTo`.** A WebSocket's `write` emits one
  frame of whatever length it is handed, and a `NetSocket` read chunk sits at exactly Netty's 65536
  default maximum frame size. A large file read or a `git diff` into a terminal trips the peer's
  limit and drops the socket — "the terminal randomly dies", not a framing bug. Read with `handler`,
  never `binaryMessageHandler`, which aggregates and enforces a maximum *message* size a byte stream
  has no business having.
- **Both ends must hold their sockets until the handlers exist.** The host writes the moment its
  upgrade completes, which races the daemon wiring its pipe; a lost request line is a request that is
  simply never answered, with nothing anywhere to say why. The daemon connects to loopback *first*
  and pauses both ends; the host buffers what the proxy wrote before the daemon arrived and replays
  it. This was found by the test rather than by reading, which is the argument for the test.
- **One `HttpClient` per workspace.** Ephemeral ports are reused, and a pool keyed on `(host, port)`
  can hand workspace B a live connection wired through to A's daemon. That is a cross-workspace read
  of someone else's working tree with nothing misconfigured.

## 7. Order

1. Stage 1 steps 1–4, one commit per repo, qits-workspaces last (it is the only one with a dependency).
2. Stage 1 step 5 — the two re-exposed surfaces, additive, in the daemon repo alone.
3. Stage 1 step 6 — the gate. Nothing above is proven until this runs.
4. Stage 2, whole, once the spike in §6 has picked a framing.

**What actually landed, in order.** Step 5 went first (it is additive and blocked on nothing), then
steps 1–4 in qits-workspaces, then the gateway fix §9's first risk turned out to require, then the
gate, then stage 2 as protocol → daemon → qits-workspaces.

One repo more than planned: **qits-gateway**. It was not in scope and had to be, because the defect
§9 asked us to "confirm" was a live authentication bypass on every WebSocket in the system, and the
terminal and chat sockets do not carry an identity end to end without fixing it.

Stage 1 is worth landing on its own even if stage 2 never happens: it is what makes the SPA work, and
every line of it — the route, the authorization, the re-exposed surfaces, the gate — survives stage 2
unchanged. Only the origin the proxy forwards to moves.

## 8. Deliberately out of scope

- **No change to any `WorkspaceApi` handler, and no change to any message shape the browser sends.**
  Terminals keep sending `{"type":"data"}` and `{"type":"resize","cols":N,"rows":M}`, chats keep
  sending `{"type":"user","text":…}`. If a diff touches those, the change has grown.
- **No network split on `qits-net`** (§9 item 21's other half). Stage 2 removes one workspace-reachable
  surface; it does not make `qits-net` a boundary, and nothing here should be described as if it did.
- **No credential design.** Stage 1's token is one shared constant (§5 step 1) and stage 1 *depends on*
  the trusted-`qits-net` posture rather than narrowing it. Per-workspace secrets, rotation, and the
  control socket's own authentication are all deferred — to stage 2 where they are structural, or to
  whoever addresses §9 item 21. The one thing not deferred is leaving existing isolation alone.
- **`WorkspaceCommandHistory` is not re-specified here** (§9 item 17). Its contract is keyed on a
  `Long workspaceRowId` the daemon does not have, and that is a modelling question, not a transport
  one. Reachability does not fix it and this document does not pretend to.
- **No durability change.** Command history and agent-session lineage still die with the container
  (§9 item 17). Making a daemon reachable does not make it stateful.
- **The daemon's four outbound addresses stay as they are.** qits-artifacts, qits-projects and
  qits-observability are still derived from the control-socket authority with a `WARN`, and the daemon
  repo's `CLAUDE.md` says whoever settles the gateway question settles them. This document settles the
  *inbound* question only; it does not hand the daemon a gateway url, and adding one to close the
  other item would be a separate decision taken for separate reasons.

## 9. Risks

- **`Host` and `Origin` across two proxies — confirmed, and it was worse than the risk said.**
  Two findings, both amendments to this document rather than confirmations of it.

  **There is no `SameOriginUpgradeCheck` in Quarkus 3.34's websockets-next.** The class does not
  exist. Three javadocs across three repos cited it as the reason sockets through the gateway were an
  open question; all three are corrected. Nothing in this chain uses websockets-next anyway — both
  proxies are raw routes and the daemon runs a raw `vertx-core` server.

  **The real defect was in the gateway, and it was a live authentication bypass.**
  `vertx-http-proxy`'s `ReverseProxy.handle` short-circuits to its upgrade path and returns *before*
  installing the interceptor chain, so `EdgeHeaders` never ran on a handshake; the upgrade path then
  copies every inbound header except `Connection` and `Host`. Both halves of the header contract were
  lost at once — a client-supplied `X-Qits-User` reached the upstream unchanged, and a genuinely
  authenticated socket arrived anonymous. Every WebSocket in qits goes through it. Fixed:
  `EdgeHeaders.applyToUpgrade` forwards an explicit handshake allow-list (`Upgrade`, `Connection`,
  `Sec-WebSocket-*`, `Host`, `Origin`) and nothing else — `Cookie` and `Authorization` included,
  since authentication terminates at the gateway — then asserts the identity on top. A handshake is a
  protocol negotiation, not a request an upstream answers, which is why it is an allow-list here and
  a prefix strip everywhere else.

  The `hostRewrite` interceptor was worth keeping for its own reason: it pins the authority the
  daemon sees to the daemon's own port, so that value does not change when the origin does — which is
  exactly what stage 2 does to it.
- **Failure modes multiply along the chain.** A workspace with no container, a container with no live
  daemon, and a daemon that refused to bind are three different states that a naive proxy reports
  identically as a connection error. `ServiceProxyRoute` already distinguishes STARTING from STOPPED
  from unreachable and says so in the response; match that, or every daemon problem becomes one
  indistinguishable 502.
- **Stage 1's token is readable by every agent, and opens every daemon.** An agent can read its own
  environment, and one shared value means it can then reach any peer workspace's `:13338`. This is
  accepted, not overlooked: it is the trusted-`qits-net` posture, the same one that already lets that
  agent `curl http://qits-projects:8080/…` directly. What makes it acceptable to defer rather than
  ship-and-forget is that stage 2 deletes the listener rather than hardening the token. **The risk is
  writing about it as though it were a boundary** — in a javadoc, a config comment, or a review — which
  is how an accepted exposure becomes an assumed protection.
- **Stage 2 is where a hand-rolled framing could quietly become a protocol.** The envelope in §6 is
  fixed and proportional to HTTP. If it starts growing per-endpoint fields, §3's third invariant has
  been broken and the design has drifted back into §4.

## 10. Done when

A user in the browser lists files, opens a file, launches a command, watches its log, attaches a
terminal, resizes it, refreshes the page and re-attaches to the same running command — every call
travelling gateway → qits-workspaces → daemon, with an unknown, non-numeric or soft-deleted workspace
id refused identically before anything connects to a container.

~~with a caller who does not own the workspace refused~~ — amended, see §5 step 4: single-user
application, no owners.

**And "in the browser" is aspirational for now**: `frontends/qits-spa-home` is an empty placeholder
(one README), so acceptance is a browser-equivalent client. `DaemonApiGateIT` is that client against
a real container; `ContainerProxyRouteTest` and `DaemonStreamRouteTest` are it against real sockets
in-JVM. The gate could not be executed at implementation time because the local
`qits/workspace:latest` predates the daemon split — its entrypoint is `bash` and it carries no
daemon binary. The skip guard now checks for that rather than merely for an image of that name, so
the four pre-existing daemon ITs stop failing on a 30-second timeout when the image is stale.

Stage 2 adds one more: `qits.workspace-daemon.api-port` binds `127.0.0.1`, and a request from a peer
container to `<workspace-container>:13338` is refused by the network stack rather than by a token
check.

## 11. What this settles in `migration-plan.md` §9

| Item | Effect |
|---|---|
| 9 — gateway enum vs target set | **closed.** No `DAEMON` constant, by §3's first invariant. The daemon is qits-workspaces' resource. |
| 16 — the daemon's REST surface has no address | **closed by stage 1**, both halves: the route and the injected token. |
| 21 — `qits-net` is trusted | **relied on by stage 1, narrowed by stage 2 — both landed.** The daemon binds `127.0.0.1` and a peer container reaching `:13338` is refused by the network stack rather than by a token check. The posture itself stands: every service is still directly reachable on the network. |
| 22 — the control socket is impersonable | **still open, and the claim above was wrong.** The nonce works *because* the control socket already exists to deliver it; it proves nothing about who opened that socket. Authenticating the control socket itself needs a per-container secret injected at creation — adjacent, not free. |
| 17 — the durability trade | untouched, and explicitly out of scope (§8). |
| 19 — the three protocol copies | one `CAPABILITY_VERSION` bump in stage 2, none in stage 1. The mirror-and-`diff -r` recipe applies unchanged. |
