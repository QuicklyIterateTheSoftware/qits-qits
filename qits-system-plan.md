# qits-platform-system — the base system information panels

Decided 2026-08-23. One PLATFORM service + SPA that shows the machine the platform runs on:
a live `glances` terminal for the host, the swarm (nodes, services, configs, secrets), and each
node's local docker resources with a shell into any container. Operators stop falling back to ssh.

Repos: `services/qits-platform-system` (Quarkus, platform tier, segment `/system`) and
`frontends/qits-platform-spa-system` (Angular 21, embedded by Quinoa at `service/src/main/webui`).
Both modelled on `qits-platform-maintenance` / `qits-platform-spa-maintenance` — same module split
(`system/` domain + `service/`), same clone-alone-builds-green law, same oidc shape (`qits:admin`
people, `qits:system` machines), same `deployments.yml` stanza (`deployment_target: platform`,
`routes: /system`, `navigation: System:14`, `health_path: /system/q/health/ready`, NO `resources:`).

**Stateless.** No postgres, no flyway: every answer is read live from the docker daemon; the only
state is the in-memory terminal registry.

## Decisions (2026-08-23, with the user)

1. **This service holds the docker socket** — the third holder after qits-containers and
   qits-deployments. It reads swarm/host state with the docker CLI and owns the PTYs that drive
   `docker exec -it` / `docker run -it`. No exec capability is added to qits-containers' machine
   API: the power stays behind `qits:admin` in one admin console. The grant is an extras block
   (`mounts[]=bind:/var/run/docker.sock…`, `groups[]=${DOCKER_GID}`), a recorded, deliberate act.
2. **glances runs as a container from `nicolargo/glances`, pulled through the platform mirror**
   (`mirror.dev.localhost:8080/hub/nicolargo/glances:4.5.6-full`), on a PTY the service owns. Not
   baked into the service image. Fallback only if the mirror path fails live: a dedicated
   `images/qits-oci-glances` image on the train.
3. v1 reaches ONE node: the one this service runs on (`docker info` → `Swarm.NodeID`). Node-scoped
   reads for another node answer 409 `NODE_REMOTE`. Swarm-level reads are cluster-wide from the
   manager.

## What it does NOT do (v1)

- No writes to swarm or docker: no scale, no restart, no rm, no config/secret create. Read + shell.
- No secret VALUES (swarm does not expose them; the UI shows metadata). Config data IS shown
  (base64-decoded) — it is configuration, behind `qits:admin`.
- No per-node agents: other nodes' containers are not reachable.
- No store: a restart drops every terminal session (the SPA reconnects, gets "no longer running").

## Sources of truth

| Fact | Read from | How |
|---|---|---|
| host | `docker info --format '{{json .}}'`, `docker system df --format '{{json .}}'` | one bounded CLI call each |
| swarm | `docker node ls/inspect`, `service ls/inspect/ps`, `config ls/inspect`, `secret ls/inspect` | `--format '{{json .}}'` for ls (one JSON per line), inspect = JSON array |
| node-local | `docker ps -a`, `container inspect`, `logs --tail`, `image ls`, `volume ls`, `network ls` | same |
| a terminal | `docker run -it … glances` / `docker exec -it <id> <shell>` on a PTY | the CLI is the child; see "Terminals" |

Every CLI call has a timeout (`qits.system.docker.call-timeout`, PT20S) and an output bound; a
failed read is 503 `{"message"}` naming docker's last words, never a 404.

## Config (`qits.system.*`, defaults in the domain jar at ordinal 100)

```
docker.binary=docker                   docker.call-timeout=PT20S
glances.image-repo=mirror.dev.localhost:8080/hub/nicolargo/glances   glances.image-version=4.5.6-full
glances.args=                          glances.pull-at-startup=true   (bounded, logged, never fatal)
terminals.linger=PT60S                 terminals.max-sessions=8
terminals.scrollback-bytes=262144      terminals.write-timeout=PT5S
terminals.owner=${quarkus.application.name}   (label value; two platforms on one daemon must not sweep each other)
```

## API — `/system/api`, roles `qits:admin` (people) or `qits:system` (machines); WS `qits:admin`

```
GET  /overview                          → {host: HostInfo, usage: DiskUsage, swarm: {state, nodeId, managers, nodes}}
GET  /swarm/nodes                       → [NodeSummary]         GET /swarm/nodes/{id} → NodeDetail
GET  /swarm/services                    → [ServiceSummary]      GET /swarm/services/{id} → ServiceDetail{…, tasks:[Task]}
GET  /swarm/configs                     → [ConfigSummary]       GET /swarm/configs/{id} → ConfigDetail{…, data}
GET  /swarm/secrets                     → [SecretSummary]       (metadata only)
GET  /nodes/{id}/containers?all=true    → [ContainerSummary]    GET /nodes/{id}/containers/{cid} → ContainerDetail
GET  /nodes/{id}/containers/{cid}/logs?tail=200 → {text, truncated}
GET  /nodes/{id}/images | /volumes | /networks
POST /terminals {kind: "GLANCES"} | {kind: "EXEC", container: "<id|name>", shell: "bash"|"sh"}
       → 201 Terminal (GLANCES: 200 + the existing one when one is live — find-or-create)
       400 bad kind/shell/ref · 404 container unknown · 409 not running | max sessions · 503 docker unreachable
GET  /terminals → [Terminal]   GET /terminals/{id} → Terminal | 404   DELETE /terminals/{id} → 204
WS   /system/api/terminals/{id}          attach: replays scrollback, then live
Terminal = {id, kind, container:{id,name}|null, shell|null, createdAt, createdBy, attachedClients, socketPath}
```
Errors are `{"message": "…"}`; node-scoped reads for a foreign node: 409
`{"code":"NODE_REMOTE","message":"only the local node is reachable in v1"}`. Wire names camelCase.

WS protocol (identical to the workspaces/projects terminals): client→server text frames
`{"type":"data","data":"…"}` and `{"type":"resize","cols":N,"rows":M}`; server→client raw PTY
text; on exit `\r\n\e[33m[terminal exited (code N)]\e[0m\r\n` then close **1000** (final, no
reconnect); unknown id → note + 1000; anything else (restart) → non-1000, the client reconnects
and gets the replay.

## Terminals

- PTY from `ForeignPty` (libc via `java.lang.foreign`, copied from qits-projects) + the
  child-opens-the-pts launch `sh -c 'exec 0<>"$0" 1>&0 2>&0; exec "$@"' <slave> setsid --ctty …`
  (the PID-1 SIGHUP incident fix; `HangupImmunity` as backstop). Reader = platform daemon thread.
- glances: `docker run --rm -it --name qits-system-glances-<id> --label qits.system.session=<id>
  --label qits.system.kind=glances --label qits.system.owner=<owner> --pid host --network host
  -v /var/run/docker.sock:/var/run/docker.sock:ro --cap-drop ALL --security-opt no-new-privileges
  --memory 512m --memory-swap 512m --pids-limit 256 --oom-score-adj 500 -e TERM=xterm-256color <repo>:<version> <args>`.
- exec: `docker exec -it -e TERM=xterm-256color -e QITS_SYSTEM_SESSION=<id> <canonical 64-hex id> <shell>`;
  the ref the caller sent is validated (`[A-Za-z0-9][A-Za-z0-9_.-]{0,127}`) and resolved through
  `docker container inspect` first; the argv never carries the caller's string.
- Lifecycle: created by POST, linger armed at creation and re-armed on last detach (PT60S →
  terminate); DELETE terminates now. Terminate = polite `^C^D` (exec) → pty close → destroy →
  2 s → destroyForcibly; glances additionally `docker rm -f` by name (the container outlives a
  dead CLI). Boot sweep: `docker rm -f $(docker ps -aq --filter label=qits.system.owner=<owner>)`.
- A stalled client (`write-timeout`) is dropped and closed 1011; it reconnects.

## Registration

- cli-bootstrap `PlatformModel`: `DEPLOYABLES` + `PLATFORM_SERVICES` + `IDP_CLIENT_APPS` gain
  `platform-system`; `SEEDED_REPOS` gains `platform-spa-system`. `ComposeTemplate`: idp client
  `qits-platform-system` (roles `qits:system,qits-platform:system`, audiences `${IDP_AUDIENCES}`);
  extras block `qits-platform-system`: socket bind + `groups[0]=${DOCKER_GID}`,
  `mounts[1]=volume:qits-platform-system-config:/work/config`, `env.DOCKER_CONFIG=/work/config`,
  `QITS_AUTH_MACHINE_REQUIRED/AUDIENCE`, `QUARKUS_OIDC_AUTH_SERVER_URL`,
  `QITS_SYSTEM_GLANCES_IMAGE_REPO/_VERSION`, `QITS_OBSERVABILITY_URL`. `SeedPhases.dockerConfig`
  writes this service's `config.json` with BOTH the registry and the mirror vhost (the edge grants
  no anonymous reads; the mirror pull needs the credential).
- wrapper `.gitmodules`: both repos (`--name`, `ignore = all`, `update = merge`, `branch = main`).

## Rollout (the maintenance recipe)

1. Seed both repos on GitHub; add as submodules here.
2. Release cli-bootstrap; release the wrapper (catalog).
3. `PUT /git/<name>` ×2 on the githost, seed mains, projects reconcile (UUID rows + GitHub twins).
4. idp client + extras + `config.json` (registry + mirror auth) on `qits-platform-system-config`;
   secret in `.qits-bootstrap.env`.
5. SPA release → service webui gitlink bump → service release → deployer creates the service.
6. Browser proof: Overview glances; swarm lists; node → containers → [sh]; terminate; no leftovers.

## Status

- 2026-08-23 — decided; worktree `feature/system` (`/home/wohlben/code/qits-qits-system`);
  three Opus subagents building service, SPA and the bootstrap wiring in parallel.
- 2026-08-23 evening — all three work packages green: service (94 unit tests, PackagedSurfaceIT
  11/11 against the NATIVE binary; live smoke on the WSL host: exec into the edge container,
  resize honoured, glances dashboard through the ro socket, no leftovers), SPA (86 tests, 11
  browser screenshots against a stub), cli-bootstrap (477 tests; `platform-system` in the four
  lists, extras block, `config.json` for registry + mirror). Rollout: cli-bootstrap
  2026.823.171206, wrapper 2026.823.171252 (merged over the gateway-retirement main), projects
  reconcile adopted both repos (rows dc85aa7d / 945daacb, githost mains at the GitHub heads),
  idp client `qits-platform-system` live (extras imported + `service update --env-add`; token
  minting 200), 14 extras entries imported (system 10, idp 4), `config.json` with registry AND
  mirror auth on `qits-platform-system-config` (manifest inspect 200 against both), glances
  image pre-pulled through the mirror with a service credential (PROVEN: `hub/` prefix + Basic
  client credential). SPA 2026.823.171747 (a branch already in main is refused by the door —
  ALREADY_INTEGRATED — so a release needs one commit of its own), service 2026.823.171819
  promoted to environment/dev. Lesson re-learned live: `timeout 25 docker run --rm …` leaves the
  container running when the CLI dies — the `docker rm -f` belt is not optional.
- 2026-08-23 19:25 — **LIVE on wohlben.eu.** CI runs SUCCESS (post-receive b890d06b, release
  a32aba79), deployer created `qits-platform-system` 1/1 at 5028372, health 200, nav shows
  System. Browser proof through the public edge as `claude-verify`: Overview draws glances
  (host CPU/MEM/LOAD, 24 containers via the ro socket), Nodes → node → containers → `sh` into
  `qits-platform-edge.1` answers `uid=1001`, resize + Terminate + Stop glances all clean, zero
  leftover containers, service log shows every open/end. Screenshots in the main worktree's
  `.playwright-mcp/system-live-0*.png`. Released mains synced to GitHub with their tags.
- 2026-08-23 19:40 — user asked that glances close automatically when leaving the Overview:
  `qits.system.terminals.glances-linger=PT3S` (last-detach grace for GLANCES only; EXEC keeps
  the general linger; still find-or-create shared). Released SPA 2026.823.173245 (wording) and
  service 2026.823.173309 (deployed 451cb1c); proven live — navigate away, container gone,
  log `Ending GLANCES terminal … (unattended for PT3S)`.
