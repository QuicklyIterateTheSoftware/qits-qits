# Unify ingress: one authenticated door instead of four open ports

Status: **COMPLETE 2026-08-14** — proven by a green from-zero rebootstrap
(70/70) on the two-port topology. This document is the campaign record;
remove it at the next plan-doc audit. Standing facts live in the
unify-ingress memory and handoff.md. Progress and proofs live in
`unify-ingress-plan-prerequisites.md` (inline ✅): Gate 0 is GREEN including
the real-edge run — docker did the full idp Bearer flow (login, push, pull,
logout-deny) under `registry.dev.localhost` through the WP1/WP2 edge branch
on a spare port. WP1+WP2 built (qits-platform-edge branch `unify-ingress`),
WP3 built (qits-deployments branch `unify-ingress`), WP4 proven (no setup
needed on this host), WP7 built and proven. WP0's answer is inline below.
2026-08-14: full-codebase investigation done (four sweeps: bootstrap phases,
literal inventory, deployer pull path, gateway/git residue). The findings
reshaped two decisions — see "Final decisions (2026-08-14)" and "Execution
plan (2026-08-14)" below, which supersede conflicting earlier wording.

## Final decisions (2026-08-14)

1. **Auth at edge is method-scoped on the byte-plane vhosts.** Writes
   (POST/PUT/PATCH/DELETE) on the registry and mirror vhosts require an idp
   Bearer token; GET/HEAD stay anonymous there. The githost vhost requires a
   token for every method. Rationale, from the sweeps:
   - Every image pull runs on the HOST docker daemon, and the pull points
     have no credential home: the deployer's docker CLI runs as uid 1001
     with no HOME and no DOCKER_CONFIG and never passes
     `--with-registry-auth`; qits-containers pulls the same way; swarm task
     pulls need spec-embedded creds; ~10 release pipelines resolve
     `http://$QITS_REGISTRY/artifacts/maven/maven` INSIDE `docker build
     --network host`, where no credential can exist. Full-auth-on-read
     means distributing a credential to five independent pull points and
     breaks every release train's maven stage.
   - The measured defect was the anonymous WRITE (202 on a blob upload).
     Method-scoping closes it while pulls stay credential-free.
   - Edge keeps the full Bearer machinery (proven in Gate 0), so flipping
     to auth-on-read later is config + credential rollout, not new code:
     the anonymous-read exemption is a config key, default OFF (auth
     everything), set explicitly for this platform.
2. **No "bootstrapping edge".** The from-zero chicken-egg is not an auth
   problem: ~38 boot phases run before edge+idp exist, and the seed phases
   already hand-publish 127.0.0.1:8081/8082 via plain `docker run -p`
   (loopback-scoped, allowed for standalone containers). Those seed ports
   stay; they die when the platform services replace the seed containers.
   The PLATFORM services simply never publish 8081/8082/8083 — from the
   seed stack onward, host traffic rides the edge vhosts (edge and idp are
   live before the first replay). Nothing to close at the end.
3. **P-idp-4 collapses.** With anonymous reads, swarm/deployer/containers
   pulls need no credential. The one machine credential left is the CI
   step's docker PUSH: qits-ci materializes a docker config.json (auth for
   the registry vhost from a configured idp client id+secret) and injects
   DOCKER_CONFIG into step containers. Host operators `docker login
   registry.dev.localhost:8080` only to push (rare).
4. **Host git after the 8083 drop**: edge accepts Bearer only, git sends
   none by itself. Mint via edge's own broker
   (`curl -u id:secret http://githost.dev.localhost:8080/token`), push with
   `git -c http.extraHeader="Authorization: Bearer $T" push …` plus the
   unchanged `-o qits.token=` push option. Only humans are affected: the
   release door, CI, projects and the bootstrap all push in-network.
5. **Gateway residue, scoped down**: retire only the `/v2` GET/HEAD public
   exemption (PublicPaths — no in-network consumer routes registry traffic
   through the gateway). `/git/*` STAYS public for now: the projects SPA's
   pasteable clone URL depends on it, and anonymous push there is already
   ref-gated by the push-option token. Its retirement is a follow-up with
   its own product decision (clone-URL story), logged in handoff.

## Execution plan (2026-08-14)

Order chosen so every build after the literal sweep proves the edge path,
and no release happens twice:

1. **Release qits-deployments** from branch `unify-ingress` (publish_mode
   parser). Live deployer first — an unknown spec key fails deployments.
2. **Finish + release qits-platform-edge** from branch `unify-ingress`:
   add the anonymous-read config key (method-scoped policy above), declare
   `publish_mode: ingress` + `update_order: start-first` in its
   deployments.yml, add the QITS_EDGE_APPS_* env to the live deployer
   config volume (and restart the deployer). Flip the live service:
   `service rm` + redeploy (update never restates ports). Prove WP3: a
   rolling edge update overlaps under ingress/start-first; vhost smoke
   (anonymous read 200, anonymous write 401, githost vhost 401, env vhost
   unchanged).
3. **Release qits-gateway**: retire the `/v2` GET/HEAD public entry.
4. **Fleet literal sweep** (commits on mains, pushed through the platform
   githost so the trains build through edge): 34 `FROM localhost:8082` →
   mirror vhost across 18 Dockerfiles; `ARG QITS_MAVEN_REPOSITORY_URL`
   defaults; the three machine-edited pins → registry vhost; the
   workspace-daemon sed pair (Dockerfile:40 + recipe lines 91/98, same
   commit); `.npmrc`/`pom.xml` dev-loop URLs; the lockfile-rewrite seds;
   stale comments where touched.
5. **Release wave** (queued in handoff + this campaign, one release each):
   blobstore → registries (pin bump) → mirror/githost/artifacts →
   workspace-daemon + projects-daemon → qits-containers → qits-ci (last,
   queue drained; carries the step DOCKER_CONFIG feature and cbfd7f7).
6. **Port drops on the live platform**: verify githost vhost clone+push,
   drop 8083 (`--publish-rm` by target port + extras edit + deployer
   restart). Flip QITS_ARTIFACTS_REGISTRY_HOST to the registry vhost in
   the ci + deployer extras (+ live env update), add the ci registry-push
   credential env, drop 8081/8082 the same way. Prove: full train (push
   through edge), a deploy (pull through edge), a workspace-image pull.
7. **cli-bootstrap**: registry-host values → vhost (4 places + test), no
   platform publishes for artifacts/mirror/githost, seed stack edge gets
   the apps env (+ ingress publish), SeedDockerfile.MIRROR_HOST follows
   the FROM sweep, unwrap sweep learns the vhost image prefix, preflight +
   summary line for the daemon.json insecure-registries host step.
8. **Tag sync, then full rebootstrap** (`QITS_SHIP_MAINS=1`) proving the
   from-zero boot on the two-port topology. Then handoff/memory closeout.

## Decision (2026-08-13): ingress mode, everything behind edge, one door

Committed. Switch edge (and the other host-port HTTP services) from swarm
**host mode** to **ingress mode**, and route the registry, mirror and githost
behind edge under `<app>.<env>.localhost` names. The registry's separate host
port (8081) is REMOVED — it goes behind edge like the rest. Ingress makes this
safe: edge in ingress mode is `start-first`, so an edge redeploy pulls the new
edge image through the still-running old edge (no stop-first, no circularity).

End state — host-published ports drop from five to two:

- **edge (8080, ingress)** — the one HTTP door; terminates idp auth.
- **dns (5353, host)** — stays: it serves the DNS wire protocol (UDP/TCP), not
  HTTP, so an HTTP edge can't front it.

Everything else (registry, mirror, githost, and the maven/npm half of
artifacts) is reached through edge. Accepted with the decision: edge is now on
the path of every image pull (coupling), a break-glass is kept for
forward-fixing a wedged edge, and the image-reference migration
(`insecure-registries` + ~210 literals) is in scope. The rest of this document
is the route there; earlier "open decision / stays direct" wording is
superseded by this section.

**No port is dropped until its gate passes** — see
`unify-ingress-plan-prerequisites.md`. It requires an end-to-end
`docker pull`/`push`-through-edge plausibility test on a spare port BEFORE any
irreversible drop (dropping the registry port before auth'd edge pulls are
proven would lock the platform out), and splits off the idp prerequisites that
likely need doing first (idp's 300s no-refresh tokens can't be a durable
`docker login` credential as-is).

## Why

Four platform services publish their own host port on `0.0.0.0`, bypassing
edge and its intended auth hop:

| Service | Port | What it exposes |
|---|---|---|
| qits-platform-edge | 8080 | the front door (keep) |
| qits-artifacts | 8081 | OCI + maven registry |
| qits-platform-mirror | 8082 | pull-through cache |
| qits-githost | 8083 | git push/clone |
| qits-platform-dns | 5353 | nameserver (keep) |

Measured 2026-08-13 on the live dev host:

- All bind `0.0.0.0` (every interface, incl. `eth0` 192.168.152.4), no host
  firewall (`iptables INPUT policy ACCEPT`). Swarm host-mode publish cannot
  express a bind IP, so the pre-swarm `127.0.0.1` scoping was silently
  widened to every interface — documented on purpose in the deployer's
  run-args, not an accident.
- **artifacts accepts an anonymous write**: `POST /v2/.../blobs/uploads/`
  returned `202` with a real upload-session `Location`, no token.
- mirror is read-only (upload `405`) but proxies/caches for any caller.
- githost gates push behind `qits.token=local-dev` — a weak shared static
  token, not idp.

On a NAT'd single-user dev box this has not bitten, but the exposure is real
and the registry write path has no auth at all. Per
[[no-speculative-security-schemes]] the intended intra-network auth is
qits-idp; interim static tokens are not the answer.

## The hard constraint (does not move)

dockerd and git clients run in the **host** network namespace. They cannot
resolve qits-net overlay DNS (`dev-qits-*`) and have no route to the overlay
data plane. So *something* must be reachable on a host port. The goal is not
"zero host ports" — it is **one** host port (edge's 8080), name-routed to the
services behind it, with auth at the gateway.

## What already exists (smaller than it looks)

Investigated 2026-08-13:

- **Edge already routes by Host header, not path.** `HostEnvironments`
  parses `$app.$env.$domain` / `$env.$domain` and resolves to an upstream
  (`services/qits-platform-edge/src/main/java/eu/wohlben/qits/edge/`). Today
  it uses only the `$env` label to pick a per-environment gateway; the `$app`
  label is parsed but unused. Proxy lib is `vertx-http-proxy` (streaming, no
  JAX-RS re-encode). Edge is deliberately dumb: "no paths, no auth, no state."
- **Service selection already lives at qits-gateway**, one hop in, via its
  `proxy-hosts` map: `/githost → githost`, `/mirror → mirror`, `/v2 →
  artifacts`, `/ci → ci` (`services/qits-gateway/src/main/resources/
  application.properties`). So `host → edge:8080 → gateway → service` by path
  **already works today** from the host. The direct 8081/8082/8083 ports are
  a *bypass* of this fabric.
- **Auth today terminates at the gateway** ("authentication terminates at
  the environment gateway on its own evidence"); edge is deliberately dumb.
  **This is drift to correct, not the target** (see Design direction 4): auth
  belongs at edge, the first node. That edge still carries "no auth" is a
  leftover from before it was the true front — it should hold the idp
  termination now.

So the proposal is an in-fabric change, not a rebuild: drop the direct ports,
force traffic through edge→gateway, and (optionally) add the nicer
`githost.qits.localhost` spelling by teaching edge/gateway to route on the
`$app` label.

## Design direction

1. Domain scheme: `<app>.<env>.localhost` — e.g. `githost.dev.localhost`,
   `registry.dev.localhost` (a real domain can come later). This maps onto
   edge's existing `$app.$env.$domain` parse with domain = `localhost`; no
   extra `qits` label. `.localhost` resolves to loopback by convention, which
   is what the host clients need (see resolution caveat below).
2. Host name resolution: `<app>.<env>.localhost` must resolve to loopback
   **for dockerd and git on the host** — glibc does NOT do this for free.
   Only bare `localhost` is wired; a multi-label `*.localhost` is not
   resolved to 127.0.0.1 by plain getaddrinfo (systemd-resolved does it,
   browsers do it, raw glibc does not). Options: `/etc/hosts`,
   systemd-resolved, or point the host resolver at qits-platform-dns. Same
   class of host step as the pending dockerd `registry-mirrors` decision.
3. Routing: extend edge (or lean on gateway's path map) so a host label
   selects a service, not only an environment.
4. **Auth terminates at EDGE, the first node.** Edge validates the idp token
   and only then proxies inward; it stops being the dumb "no auth" hop. If
   auth is still living in the gateway at this point, that is drift we forgot
   to move — it should have followed edge becoming the true front door. Edge
   already sees every request first and already reads the Host header, so it
   is the right and cheapest place to gate. The gateway keeps whatever
   in-network checks it needs on its own evidence, but the outermost idp
   termination is edge's job. (Verify where auth actually lives today — it
   may be as open as the direct ports; wherever it is, it moves to edge.)
5. Services that stop publishing a host port become overlay-only again →
   back to `start-first` (lossless rollback), dropping the `stop-first`
   requirement added 2026-08-13. Nice tie-off.

## Why ingress mode is the enabler

The `stop-first` landmine exists because a **host-mode** published port is
bound on the node by the task itself, so two tasks can't hold it during a
rolling update. A service in **ingress mode** has its port held by the swarm
routing mesh, not the container — so `start-first` (lossless rollback) works.
For edge that is what breaks the pull-edge-through-edge circularity and lets
the registry sit behind it. Verified why host mode was chosen originally
(`ComposeTemplate` edge comment): a deliberate single-node choice — ingress is
"a second hop for a door that only answers on this machine" — NOT a necessity,
so the switch is available.

**One fact ingress does NOT change, and it shapes the break-glass:** exposure.
Measured in `ServiceExtras`: "swarm's publish syntax has no ip field, IN EITHER
MODE … a host-mode publish listens on `0.0.0.0`." Ingress also binds `0.0.0.0`
and can't scope to `127.0.0.1`. That is why the answer is to remove the
registry's port (behind edge) rather than firewall it — and why the recovery
break-glass port, when opened, needs an `iptables` rule (it can't be
loopback-bound at the publish layer).

## Per-service verdict

- **githost — clean win, do first.** Git-over-HTTP is plain HTTP/1.1 with a
  Host header; not dialled by the docker daemon, so none of the
  registry/insecure-registries mess applies, and githost is NOT in any
  image-pull path so there is no circularity. Move behind `githost.dev.
  localhost`, edge validates the idp token before proxying, retire the 8083
  door. This is the pilot that proves edge-side auth + host-label routing.

- **mirror — behind edge too.** Read-only pull-through cache. Its only host
  consumer is dockerd's `registry-mirrors` setting, which names the edge vhost;
  because the caller is the docker daemon, that vhost needs an
  `insecure-registries` entry (or TLS), same as the registry. No circularity.
  Sequence it with the still-pending dockerd-mirror decision.

- **artifacts OCI registry — DECIDED: behind edge, no direct port.** Ingress
  mode makes it safe: edge is `start-first`, so an edge redeploy pulls the new
  edge image through the still-running old edge (the old "pull edge through a
  stopped edge" deadlock was purely a host-mode/`stop-first` artifact). Image
  refs move from `localhost:8081/qits/<app>:<sha>` to a vhost
  (`registry.dev.localhost:8080` via edge). Two things ride along with the
  decision, accepted:
  1. **Coupling.** edge is now on the path of every image pull, including its
     own forward fix. Rollback pulls nothing (prior edge image is cached on
     the node), so the common recovery is unaffected; only forward-fixing a
     fully-wedged edge needs a pull it can't get. Mitigation: a normally-closed
     **break-glass** — a way to open the registry's port directly during edge
     recovery, not a permanent second port. Keeps
     [[platform-reachable-without-gateway]]'s intent.
  2. **Migration.** `insecure-registries` entry per docker daemon for the vhost
     (or TLS), plus ~210 `localhost:8081` literals across ~120 files. The OCI
     ref itself is ONE receiver-named key pair
     (`qits.artifacts.registry-host`/`QITS_ARTIFACTS_REGISTRY_HOST` +
     `QITS_REGISTRY`), but three machine-edited pins bypass it and the
     `qits-workspace-daemon` recipe sed **hardcodes `localhost:8081`** — it
     must change in the same commit or it silently no-ops.

  Auth: edge terminates it, like every other vhost (WP2). The registry itself
  needs NO auth code — external reach is edge-gated, and intra-`qits-net`
  access stays on the platform's existing network-trust model (the registry is
  deliberately open to producers on qits-net today). The one docker-specific
  detail edge must honour is in WP2.

- **artifacts maven/npm half — behind edge too.** Loses its direct port with
  the OCI half; dev hosts reach it via an edge vhost. Step containers already
  use the in-network alias over qits-net (unchanged).

- **artifacts maven/npm half — low value to move.** Same service, same port,
  but this half is plain HTTP from dev hosts. Step containers already use the
  in-network alias over qits-net (NOT the host port), so the host port's
  maven/npm role is only developer convenience. Could ride an edge vhost for
  dev-facing access, but there's little security gain and the port stays up
  for the OCI half regardless.

## Open questions / to verify

- RESOLVED 2026-08-13 (WP0): auth today terminates **at the gateway**, as a
  browser-session oauth policy (`QitsAuthPolicy`) — but `PublicPaths` makes
  `/v2` GET/HEAD **public** (anonymous pulls) and `/git/*` public
  unconditionally; `/mirror` is not routed at all. So edge's idp termination
  was built fresh, nothing moved. Residue: with `/v2` GET still public at
  the gateway, an env vhost (`dev.localhost/v2/…`) reaches the registry
  anonymously AROUND edge's app-vhost gate — retiring `PublicPaths:65` is a
  qits-gateway change that must land before the registry's auth is real.
- h2c: `vertx-http-proxy breaks on h2c inbound` is live and unfixed for edge.
  Plain HTTP/1.1 (git/docker default) is fine; docker negotiated plain
  HTTP/1.1 throughout the Gate 0 runs.
- RESOLVED — `<app>.<env>.localhost` resolves to loopback on this host with
  zero setup: systemd-resolved synthesizes multi-label `*.localhost`, and
  getent, dockerd and git were each proven against it. A host without
  systemd-resolved still needs hosts-file entries.
- RESOLVED — registry circularity is NOT a blocker: it was contingent on edge
  being `stop-first` (host mode). Edge in ingress mode is `start-first`, the
  old edge serves the pull of the new edge, and the loop is gone. Decided:
  registry behind edge (see the Decision section).
- RESOLVED — docker honours edge's `401` challenge, proven live: the
  Bearer/token-endpoint flow (chosen so the stored credential is a durable
  idp client id+secret while tokens stay 300s) carried a real
  login/push/pull cycle through the edge branch. Audience gate is
  env-derived (`qits.edge.auth.audience-pattern`, default
  `{env}-qits-artifacts` — idp's names are env-prefixed).

## The break-glass (why the firewall fact still matters)

With the registry behind edge there is no standing registry port to firewall.
The one residual is **forward-fixing a wedged edge**: if a running edge can't
proxy and the fix is a new image, the pull needs an edge that isn't there.
Rollback avoids it (the prior edge image is cached on the node, no pull), so
the break-glass is only for a forward fix — a scripted, normally-closed way to
publish the registry's port directly for the duration of a recovery.

**When that break-glass port is opened it binds `0.0.0.0` and cannot be scoped
to loopback** — verified 2026-08-13 (Docker 29.7.2): swarm's publish has no
host-IP field in either mode (`host-ip=127.0.0.1` → `invalid field key`), and a
standalone `docker run -p 127.0.0.1:…` would break the swarm-only rule
([[swarm-migration-planned]]). So the break-glass pairs with a host `iptables`
rule (loopback + docker bridge only) applied while it is open. Not a standing
control — a recovery tool.

## Scope, decided

- **Behind edge:** githost (pilot), the artifacts registry (OCI + maven/npm),
  and mirror. All lose their host ports.
- **Stays a host port:** edge (8080, now ingress) and dns (5353 — DNS wire
  protocol, not HTTP, can't be edge-fronted).
- **Result: five host ports → two.** The registry's separate port is removed.
- **Prerequisite:** edge switches host mode → ingress mode (which also retires
  `stop-first` for it).

## Work packages

- **WP0 — verify where auth lives today** (gateway vs. nowhere on
  githost/registry/mirror paths). Cheap; sets how much WP2 moves vs. builds.
- **WP1 — edge routes a host label to a service.** Extend
  `HostEnvironments`/`EdgeConfig` so `<app>.<env>.localhost` resolves to a
  service upstream, not only an environment gateway. Keep the env-only path
  working.
- **WP2 — idp auth termination at edge, for every vhost incl. the registry.**
  A `vertx-http-proxy` request hook that validates the idp credential before
  dispatch and rejects anonymous; move whatever auth lives in the gateway out
  to edge. Docker specifics for the registry vhost: edge must answer an
  unauthenticated `/v2` with a `401` challenge the docker CLI honours —
  simplest is HTTP `Basic` (docker resends the `docker login` credential,
  which edge validates, ideally offline against idp's JWKS); a Bearer/token
  endpoint is only needed if short-lived tokens are wanted. The registry
  itself stays code-free of auth — intra-`qits-net` keeps network trust.
- **WP3 — edge switches to ingress mode.** host mode → ingress on edge (and
  any service kept host-published), so it is `start-first`. Retires the
  `stop-first` requirement. Deployer change: `DeploymentDriver`/`ServiceExtras`
  emit `mode=ingress`. Prove a rolling edge update overlaps cleanly.
- **WP4 — host name resolution.** Make `<app>.<env>.localhost` resolve to
  loopback for host dockerd/git (hosts file / systemd-resolved / point at
  qits-platform-dns). Needed before any vhost is usable from the host.
- **WP5 — githost behind `githost.dev.localhost`** (pilot). Prove clone +
  push with an idp credential through edge; drop githost's 8083 publish.
- **WP6 — registry + mirror behind edge.** Move image refs from
  `localhost:8081` to the edge vhost (the one receiver-named key pair, plus the
  three machine-edited pins and the `qits-workspace-daemon` sed that hardcodes
  `localhost:8081` — same commit); add the `insecure-registries` entry (or
  TLS) per docker daemon; drop the 8081/8082 publishes; prove a deploy pulls
  through edge.
- **WP7 — the break-glass.** A scripted, normally-closed direct-registry-port
  path (+ its `iptables` rule) for forward-fixing a wedged edge.
