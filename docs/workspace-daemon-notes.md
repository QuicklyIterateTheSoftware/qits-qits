# Workspace daemon communication: what survives the retired migration plan

The final-workspaces-and-agent-communication migration shipped in two stages (2026-07-29); the
plan was verified fully implemented and retired 2026-08-01. The shipped shape is documented in
qits-workspaces' AGENTS.md, the daemon repo's README/AGENTS.md, and the code javadoc. These
items had no other home.

## ~~OPEN DEFECT: no backpressure on the browser↔qits-workspaces upgraded socket~~ — FIXED

Fixed 2026-08-01 (qits-workspaces `365ea90`): websocket upgrades no longer traverse
`vertx-http-proxy` at all — `proxyUpgrade` builds the outbound request itself and pipes the two
NetSockets raw with pause/resume + drainHandler both directions, close/end/exception propagated,
refused handshakes forwarded with the daemon's own status. A discriminating test proves the bound
(the reverted library path fails it in 0.2s). Kept here as the record of why the route does its
own upgrade instead of using the library's.

## Why the container surface is NOT multiplexed onto the control socket

"The design anyone will propose again" — the daemon already has a perfectly good HTTP server, so
why not tunnel everything through the one control websocket? Four reasons, rejected at design
time:

1. One workspace-global write queue: every stream shares the control socket's ordering.
2. Bulk bodies (file downloads, logs) share the wire with keystrokes and heartbeats.
3. Availability coupling: a control-socket blip takes down every in-flight stream.
4. It violates the invariant that the protocol grows with transports, not endpoint count —
   every new daemon endpoint would become a protocol message.

The shipped shape instead: the daemon's HTTP API stays an HTTP API (loopback-bound), reached via
the host-side reverse proxy and, when direct dialing is impossible, a per-workspace reverse
tunnel whose only protocol addition was one message (`OpenStream`).

## The daemon API token's upgrade path

Today `QITS_WORKSPACE_DAEMON_API_TOKEN` is one shared default — a scoping device, not a
boundary (qits-net is trusted; the bearer is not the boundary). If qits-net ever stops being
trusted: the value becomes a host-secret HMAC over the workspace id. The injection point, env
var, and bearer header all stay where they are — only the value's derivation changes.

## Dependency caching (parked in qits-ci) must be volume-shaped

From the retired finish-ci-feature plan: caching cannot be daemon-shaped, since nothing survives
a step's container — a cache must be a volume the launcher mounts. qits-ci's README names
caching as a follow-up; this constraint belongs with it.
