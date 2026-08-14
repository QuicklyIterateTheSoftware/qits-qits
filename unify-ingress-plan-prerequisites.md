# Unify-ingress prerequisites: gates before dropping any port

Status 2026-08-14: P-edge PROVEN LIVE — deployer 2026.814.64650 and edge
2026.814.65508 released; edge runs in ingress mode (service rm + recreate)
with app vhosts + method-scoped auth; WP3 rolling update proven lossless
(120 probes, zero failures). Docker pull (anonymous) and login/push/pull
through edge proven on the real 8080. GITHOST PORT 8083 DROPPED after a
proven vhost push. One new host prerequisite discovered: the v6 loopback
blackhole (ingress mesh is v4-only; standing ip6tables RST rule on
lo:8080 — see [[ingress-v6-blackhole-and-swarm-ops]] and the bootstrap's
preflight warning). Registry/mirror drops pend the release wave.

Status: EXECUTING, opened 2026-08-13. Companion to `unify-ingress-plan.md`.
2026-08-13 evening: Gate 0 GREEN — stand-in AND the real-edge/real-vhost run
(the true gate), with docker doing the full idp Bearer flow through the edge
branch. P-name, P-trust, P-glass proven; WP1/WP2 built and live-smoked on a
spare port; WP3 built (code-proven). Still open: P-idp-4, the daemon.json
automation, WP3's live rolling-update proof, releasing the branches in order
(deployer before edge), then the port drops per the gate order. Results are
inline below, marked ✅.

This document exists for one reason: **dropping the registry's direct port
before edge-fronted authenticated pulls are PROVEN is a lock-out.** If the
registry is only reachable through edge and that path doesn't actually work,
the platform can't pull images — and it can't even pull a *fixed* edge, because
pulling needs the registry. So every irreversible step (dropping a port) has a
gate here that must pass first, on a spare port that never touches the live
8081/8082/8083.

## The rule

No service loses its host port until its gate below is green. Order:
githost first (lowest risk), registry last (highest — it is the pull
primitive), and the registry's break-glass must exist before its port drops.

## Gate 0 — the plausibility test (MANDATORY, before any port drop)

Prove, end to end, that `docker` can pull and push through an
auth-terminating proxy in front of the real registry — WITHOUT touching the
live 8081 port. Two ways to run it; either satisfies the gate:

- **Stand-in proxy (cheap, do this first):** a reverse proxy (e.g. nginx,
  already present as `nginx:alpine`) on `qits-net` reaching
  `dev-qits-artifacts:8080`, published on a SPARE loopback port (a standalone
  `docker run -p 127.0.0.1:<spare>:80` CAN bind loopback — unlike a swarm
  service), doing HTTP Basic auth. Mimics hardened-edge's simplest form.
- **Real edge (once WP1/WP2 exist):** the actual edge with app-label routing
  + auth termination, on a spare port / second instance.

Pass criteria — ALL must hold:
1. Anonymous `GET /v2/` → `401` with a challenge docker honours.
2. `docker login <proxy>` then `docker push <proxy>/qits/plausibility:1`
   succeeds (a new tag, pushed through the proxy).
3. `docker rmi` it locally, then `docker pull` the same ref back through the
   proxy succeeds (manifest + blobs survive the hop).
4. After `docker logout`, `docker pull` is DENIED (auth is really enforced,
   not decorative).
5. The same works under the real vhost name, not just `localhost` (see the
   name-resolution + insecure-registries prerequisites — this is where the
   loopback-trust shortcut stops helping).

Until Gate 0 is green under the real vhost name, no registry port drops.

✅ **Stand-in run GREEN, all five criteria (2026-08-13).** nginx:alpine on
qits-net → `dev-qits-artifacts:8080`, Basic auth, published
`127.0.0.1:18081`. Anonymous `/v2/` → 401 with a Basic challenge; `docker
login` + push of `qits/plausibility:1` through the proxy; `rmi` + pull-back;
denied after logout; and the whole cycle again as `registry.dev.localhost:
18081` (which also proved dockerd resolves and trusts the vhost).

✅ **REAL-EDGE run GREEN — the true gate (2026-08-13, same evening).** The
`unify-ingress` edge branch (WP1+WP2) ran as a real instance on qits-net at
`127.0.0.1:18081` (fast-jar, temurin 25), app patterns
`{env}-qits-artifacts` / `{env}-qits-githost` / `qits-platform-mirror`,
audience `dev-qits-artifacts`. Docker did the full Bearer flow itself:
`docker login registry.dev.localhost:18081` with the idp client
`dev-qits-artifacts` + secret (edge's `/token` brokered client_credentials
to the LIVE idp), push of `qits/plausibility:2`, `rmi` + pull-back, and
"client credentials required" after logout. The same single port proxied the
env vhost (`dev.localhost` → gateway, 200) at the same time; mirror and
githost vhosts route and gate (401 anonymous, 200 with a token); unknown
app labels 404. Audience naming is env-prefixed on this platform
(`dev-qits-artifacts`, not `qits-platform-artifacts` — that is the prod-era
CLIENT name); edge derives it now: `qits.edge.auth.audience-pattern`,
default `{env}-qits-artifacts` (3ad1ae7, live-smoked with zero audience
config; a dev token no longer unlocks another env's vhost).

## idp prerequisites (split off, as anticipated)

These are the ones most likely to need work FIRST, because idp today cannot
issue a credential a `docker login` can keep using. From the live idp
investigation (2026-08-13):

- **P-idp-1 — a docker-usable credential lifetime.** idp issues only
  `client_credentials` tokens with a **~300s TTL and no refresh**. `docker
  login` stores a static password and resends it, so a raw idp token dies in
  5 minutes and every pull after that fails. Decide and build ONE of:
  (a) a long-lived idp credential (a client secret / long-TTL token) that edge
  validates, or (b) the docker v2 **Bearer token-endpoint** flow, where docker
  transparently re-fetches short-lived tokens using a stored long-lived
  credential. Without this, edge-terminated auth cannot be durable.
- **P-idp-2 — where the credential is validated / exchanged.** idp is
  **overlay-only and not edge/gateway-routed**, so a `docker login` client on
  the host cannot reach idp directly. Options: edge validates the presented
  credential OFFLINE against idp's JWKS (`/idp/jwks`, confirmed live, RS256,
  `kid`), needing no host→idp reach; or edge serves a token endpoint that
  brokers to idp on qits-net. Pick offline-validation if possible — it keeps
  idp off the per-pull path.
- **P-idp-3 — a registry-access permission.** idp's claims are a CLOSED set
  (`project`/`workspace`/`branch`) with no registry scope or docker `access`
  concept. Decide how "may pull" / "may push" is expressed: cheapest is to
  reuse the existing `qits-platform-artifacts` audience as the gate and shape
  any docker-side scope in edge; finer per-repo grants would extend idp's
  claim model. No idp claim change may be needed if edge does the shaping.
- **P-idp-4 — deployer / host-daemon credentials.** Swarm pulls run on the
  host docker daemon, which must carry a stored registry credential so
  rolling-update pulls authenticate. Decide where it lives (deployer config
  volume) and how it refreshes. Ties to [[machine-token-minting]].

✅ **P-idp-4 RESOLVED by design (2026-08-14): no pull credential exists,
because reads stay anonymous.** Auth at edge is method-scoped on the
registry/mirror vhosts (writes need a Bearer, GET/HEAD do not) — see the
"Final decisions" section in `unify-ingress-plan.md` for the full
rationale (five credential-less pull points, and maven resolution inside
`docker build` where no credential can live). The one machine credential
built is the CI step's docker PUSH config (qits-ci injects DOCKER_CONFIG);
the deployer needs nothing.

✅ **Decisions taken (2026-08-13), build rides WP2 in qits-platform-edge:**
P-idp-1 = option (b), the docker Bearer token-endpoint flow — the durable
`docker login` credential is an idp CLIENT ID + SECRET, docker re-fetches
short-lived tokens through an edge token endpoint that brokers
client_credentials to idp; no idp code change. P-idp-2 = offline JWKS
validation at edge; idp stays off the per-pull path. P-idp-3 = reuse the
`qits-platform-artifacts` audience; edge shapes/ignores docker `scope`.
P-idp-4 stays OPEN (deployer-held credential for swarm pulls, ties to the
deployer config volume).

## Other prerequisites (before the matching port drops)

- ✅ **P-name — host name resolution. PROVEN, no setup needed on this host.**
  systemd-resolved synthesizes multi-label `*.localhost` → loopback and
  nsswitch routes through it (`resolve [!UNAVAIL=return]`). Proven for getent
  (all three vhosts → `::1`/`127.0.0.1`), for dockerd (login + pull under
  `registry.dev.localhost:18081`), and for git (`ls-remote` on
  `githost.dev.localhost:8083` got an HTTP answer). A host without
  systemd-resolved still needs hosts-file entries — recheck on any new box.
- ✅ **P-trust — insecure-registries. CONFIGURED AND PROVEN.**
  `/etc/docker/daemon.json` now carries `insecure-registries:
  [registry.dev.localhost:18081, registry.dev.localhost:8080,
  mirror.dev.localhost:8080]` (18081 was the gate rig; the 8080 pair is for
  the real edge). Backup at `daemon.json.bak-unify-ingress`. The dockerd
  restart bounced the platform; all 17 services returned 1/1, edge 200.
  Still open: automate it — today it is a hand-applied host step, so it
  belongs with the printed host-side steps the bootstrap emits.
- ✅ **P-glass — built and PROVEN: `qits-registry-break-glass.sh`** (wrapper
  root): `open|close|status`, forces `--update-order stop-first` (start-first
  deadlocks on host-mode ports), iptables `! -i lo` DROP goes in before the
  port opens and leaves after it closes. Proven from the real post-drop state
  (zero publishes): open → anonymous 200 → real `docker pull` WITH the scope
  rule active → close → standing state restored exactly. Two docker facts the
  script documents: `--publish-rm` matches by TARGET port (close removes every
  direct publish — the intended end state), and two host-mode publishes of one
  target port collapse to a single container binding (a spare-port test beside
  the standing 8081 converges in the spec but never binds).
- **P-edge — edge capabilities proven.** WP1 (app-label routing), WP2 (auth
  termination incl. the docker challenge), WP3 (ingress mode / start-first)
  must be built and proven on a spare port before they carry real traffic.
  2026-08-13: WP3 BUILT — qits-deployments branch `unify-ingress`
  (worktree `.claude/worktrees/unify-ingress`, f5194ac + 8d6bc8d, 240 tests
  green): spec key `publish_mode: host|ingress`, host default byte-identical,
  no update_order coupling. Sequencing rule: an unknown spec key fails a
  deployment, so edge must not declare `publish_mode` until a deployer with
  this parser is LIVE. Also: `buildUpdateArgv` never restates ports — flipping
  an existing service's mode takes `service rm` + redeploy. WP1/WP2 in flight
  on qits-platform-edge branch `unify-ingress`. The spare-port live proof is
  still open.

## What blocks what

    Gate 0 (stand-in, localhost)      ─ cheap first proof, unblocks confidence
        │
    P-name + P-trust ─────────────────┐
    P-idp-1..4 ───────────────────────┤
    P-edge (WP1/WP2/WP3) ─────────────┤
        │                             │
    Gate 0 (real edge, real vhost) ◀──┘  ─ the true gate
        │
    githost port drop (pilot)
        │
    P-glass ready ───────────────────────
        │
    registry + mirror port drop  ◀── last, irreversible-feeling, gated on all above
