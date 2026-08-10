# Moving local execution to docker swarm

Where every docker call in this platform is made, what swarm changes about each one, and the order
to change them in.

Goal, as stated: (1) run the local daemon as a swarm, (2) make qits-deployments create swarm
services instead of `docker run` containers. Agent-style container executions — CI steps, workspace
containers, project agents — stay plain `docker run` until a delegation layer exists.

Measured on this host on 2026-08-09: docker **29.7.2**, swarm **already active** (1 node, 1
manager), 13 deployed `qits-pd-*` containers plus 1 workspace container.

---

## 1. Where docker is called

Nothing uses a docker client library. Every call is `ProcessBuilder` over the `docker` CLI, and
every one of them is behind a named seam.

| # | Component | Class | Verbs | Fate |
|---|---|---|---|---|
| 1 | qits-deployments | `dockerhost/DockerDeploymentDriver` (826 lines) | `pull`, `run`, `stop`, `start`, `rm`, `ps`, `inspect`, `logs`, `network create/inspect/ls/connect/disconnect/rm` | **becomes swarm** |
| 2 | qits-cli-bootstrap | `platform/Docker` (146) + `phases/SeedPhases` (890), `phases/PipelinePhases`, `phases/UnwrapPhases` (305) | `version`, `compose version/up/down`, `build`, `create`/`cp`/`start -a`, `run -d`, `run --rm`, `rm -f`, `ps`, `restart`, `volume *`, `network *`, `images` | **partly swarm** |
| 3 | qits-ci | `daemonhost/CiDaemonLauncher` (587), `CiDaemonContainerProbe` | `run -d` (step containers), `inspect`, `rm` | stays `docker run` |
| 4 | qits-workspaces | `control/DockerExecutor` (464) | `run`, `exec`, `start/stop/rm/restart`, `inspect`, `ps -a`, `volume create/rm/ls/inspect`, `network inspect/create` | stays `docker run` |
| 5 | qits-projects | `agenthost/DockerAgentRuntime` (242) | `run`, `start/stop`, `container inspect`, `ps -a`, `volume create`, `network inspect/create` | stays `docker run` |

Two smaller call sites worth naming because they are easy to miss:

- `cli/.../api/InNetworkHttp` runs `docker run --rm --network qits-net <curl-image>` for every HTTP
  call to a service with no published port. It is how the bootstrap probes idp, ci and the deployer.
- `DockerDeploymentDriver.handoff` starts a **referee container** that mounts the docker socket and
  runs `docker stop / inspect / rm / start` from a shell script, to arbitrate the deployer's own
  self-update.

Config keys naming the runtime: `qits.platform.deployments.container-runtime`,
`qits.ci.container-runtime`, `qits.workspace.container-runtime`,
`qits.projects.agent-container-runtime` — all default `docker`, all already a seam.

---

## 2. What swarm changes — measured, not assumed

Each of these was run against this host today and the probe resources were removed afterwards.

| Fact | Consequence |
|---|---|
| A service cannot attach a local bridge network. `docker service create --network qits-net` answers **`network qits-net not found`** | `qits-net`, `qits-platform` and the nine `qits-env-prod-*` networks are all bridges. Every one a service touches must become an **overlay**. |
| An `--attachable` overlay hosts services **and** `docker run` containers. Both directions of DNS work: a plain container resolved a service VIP, a service task resolved a plain container by name | CI steps, workspace containers and agent containers keep working unchanged on a converted `qits-net`. This is what makes the split model possible. |
| A service's DNS name **does not resolve until its task passes its healthcheck**. While the task was `Starting`, `getent hosts probe-svc` returned nothing; the VIP existed in `service inspect` the whole time | Swarm health-gates discovery. This is the property `DeployService`'s manual cutover was written to obtain. |
| **`start-first` + a successor that never goes healthy leaves the predecessor serving, then rolls back on its own.** Probed with `--update-order start-first --update-monitor 8s --update-failure-action rollback` and a health command that always fails: the old task stayed `Running` for the whole 33 s, the new one sat in `Starting` and was then declared `Failed`, and `UpdateStatus` went `updating` → `rollback_completed` ("rollback completed") with the spec reverted | This is the whole of what the self-update referee does. See §3.1. |
| A standalone container can attach a bridge **and** an overlay in one `docker run` (`eth0` on the bridge, `eth1` on the overlay) | Only interesting for an in-place migration. Not needed — the platform is re-bootstrapped, see §5 phase 0. |
| **Nothing is published unless `--publish`.** Container ports stay private to the overlay and are reached by DNS at the real port | Every service keeps listening on 8080, exactly as today. There is no "one service per port". |
| `--publish mode=host` binds **0.0.0.0**; the long syntax has no `ip` field. Verified with `ss`: `LISTEN 0.0.0.0:18099`. Ingress mode additionally claims the port cluster-wide; `mode=host` is per-node, like plain docker. A standalone `docker run` is unaffected and still binds an IP | Applies to **published host ports only**, of which the platform has three — and one of those (postgres) should not be published in the first place. See §4.2. |
| `--no-resolve-image` exists on both `service create` and `service update` | Needed for the seed's local-only `qits/*:latest` tags, which no registry can resolve. |
| A stack service resolves under **both** `<stack>_<service>` and the bare `<service>` short name, even on an external network | The whole wire-alias addressing model survives `docker stack deploy` unchanged. Big de-risker. |
| `container_name:` is **ignored** in a stack. The container is `<stack>_<service>.<slot>.<taskid>` | Every name-based check breaks — see §3.2. The alias is DNS-only from then on. |
| `service update --network-add/--network-rm` exists, and recreates the task | Joining a network after the fact is a restart, not a no-op. Reshapes the hub-and-spoke model — see §4.1. |
| A network is removable ~1 s after `docker stack rm`, not immediately | Teardown needs a retry loop. |
| **A running container attaches itself to a network through the socket, with no restart.** Probed: a container on no qits network read its id from `/etc/hostname`, ran `docker network connect <attachable overlay> <self>`, and resolved a service on it immediately — new interface live, no re-exec | Removes the ordering constraint on a containerized bootstrap (§4.3): the CLI joins the network it creates, when it creates it. |

---

## 3. Blast radius

### 3.1 qits-deployments — the big one

**What dissolves.** Roughly half of `DockerDeploymentDriver` and a third of `DeployService` exist to
do by hand what the swarm orchestrator does:

- **The replace cutover.** `aliasHolders` + `parseHolders` + `predecessorsOf` + `stop` + `restart` +
  `remove` + the "a container's own name counts as an alias" rule (`DeployService:698-904`,
  `DockerDeploymentDriver:366-462`). A service name **is** the identity; `service update --image`
  replaces in place. `--update-order start-first`, `--update-failure-action rollback` and
  `--update-monitor` are the cutover and the rollback.
- **The health gate.** `awaitHealthy` polling `docker inspect` (`DockerDeploymentDriver:583-619`).
  The `--health-cmd` stays — it is the same flag on a service — but the verdict is read from
  `service ps` task state and `service inspect .UpdateStatus.State`, and an unhealthy successor
  never receives traffic because it never enters DNS.
- **The self-update referee.** `handoff`, `buildHandoffArgv`, `socketGid`, `HANDOFF_PREFIX`, the
  referee shell script and the `selfHolder` branch in `DeployService:793-826`, plus
  `selfContainerId()` reading `/etc/hostname`.

  The referee exists because **neither instance can arbitrate its own succession** — the old is
  about to be stopped and the new cannot boot until it is — so a third process is needed. Swarm
  supplies one: the manager lives in dockerd, not in a container the deployer owns. The deployer
  calls `service update` on its own service and dies; the orchestrator finishes the job.

  It is not a matter of swarm only noticing failures. With a healthcheck, a task is `Starting`
  until the check passes and only then `Running` — and §2 measures the full failure path: under
  `start-first` the predecessor kept serving for the whole 33 s while the unhealthy successor sat
  in `Starting`, then swarm failed the successor and reverted the spec by itself. Stop the old,
  await the gate, remove the loser, restore on failure: all four, none of them ours.

**What survives, changed.**

- **The self-update bookkeeping — the one part of the handoff that does not go.** The deployer
  issues the update on its own service and dies before it can record the outcome, so a `STARTING`
  row still has to be settled by whichever instance boots next. That is the adoption arm of
  `sweepInFlight` (`DeployService:157-204`), reshaped from a race into a read: ask
  `docker service inspect <self> --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}'` and compare
  it with the row's sha. Carries the row's sha → I am the successor, `ACTIVE`. Carries the
  predecessor's → swarm rolled back, `FAILED`. `UpdateStatus.State`/`.Message` supplies the detail
  string, and the **image** is the primary check rather than `UpdateStatus` because that field holds
  only the most recent update and a later one overwrites the verdict.
- `pull` — keep it, but only for the `IMAGE_MISSING` classification a deployment records. Swarm
  pulls on its own.
- Labels stay the bookkeeping. `--label` on the service, `--container-label` for the task container.
  Reads move from `docker ps --filter label=` to `docker service ls --filter label=`.
- `removeEnvironmentContainers` → `docker service rm` by label.
- `ensureNetwork` → `docker network create -d overlay --attachable`, and `networks()` reads swarm
  networks.
- `logs` → `docker service logs`.

**What breaks outright.** `qits.platform.deployments.run-args.<application>` — 13 lines generated by
`ComposeTemplate:435-573`, whitespace-split and appended verbatim to a `docker run` argv. Almost
none of it is valid on `service create`:

| run-args today | swarm |
|---|---|
| `-v qits-ci-data:/data` | `--mount type=volume,source=qits-ci-data,target=/data` |
| `-v /var/run/docker.sock:/var/run/docker.sock` | `--mount type=bind,source=…,target=…` |
| `--group-add ${DOCKER_GID}` | `--group ${DOCKER_GID}` |
| `-p 127.0.0.1:8081:8080` | **no equivalent** — see §4.2 |
| `-e KEY=value` | unchanged |

This is the single largest config-shaped change and it is entirely inside the bootstrap's generator,
which is good news: one file, 13 lines, one template.

### 3.2 qits-cli-bootstrap — the seed

The user's note is right: the bootstrap needs the same switch, and in some places a bigger one.

- **Preflight** (`SeedPhases:49-62`) checks `docker version` and `docker compose version`. It gains
  the swarm check and, if inactive, `docker swarm init`. This is goal (1), and it belongs here
  rather than in a README step.
- **The seed stack** (`PipelinePhases.seedStackUp:50-104`) runs `docker compose -p qits -f … up -d`
  with an explicit service list. `docker stack deploy` is the equivalent, but four things in the
  generated compose file do not survive: `container_name` (ignored), `group_add` (unsupported in
  swarm mode — must move to `deploy`-compatible spelling or a service-create call),
  `restart: unless-stopped` (→ `deploy.restart_policy`), and the external **bridge** `qits-net`
  (→ external overlay).
- **The name-based skip rule is the subtle one.** `seedStackUp` decides what to start by asking
  `docker ps --format {{.Names}}` and matching `qits-pd-<env>-<app>-` prefixes and wire aliases
  (`PipelinePhases:81-96`); `seedArtifactsStart` and `seedPostgres` do the same
  (`SeedPhases:315`, `SeedPhases:570`). Under swarm the deployed thing is a **service**, whose task
  container is named `<service>.<slot>.<taskid>`. Every one of those checks must become a
  `docker service ls` query. Miss one and the bootstrap resurrects a compose sibling beside a
  deployed service — exactly the failure the current comments say the rule exists to prevent.
- **What stays plain docker.** The builder containers (`docker create` + `cp` + `start -a`, the musl
  builder, the maven and npm publishes, the config-volume writer at `SeedPhases:704-745`) are batch
  jobs with an exit code, not services. `docker build` is unchanged. `InNetworkHttp`'s throwaway
  curl container is unchanged as long as the network it joins is attachable.
- **Unwrap** (`UnwrapPhases:90-126`): `compose down` → `docker stack rm qits`; the label-driven
  container reap needs a `docker service rm` pass beside it; network removal needs the retry loop.
  The existing rule — patterns are added, never removed — means the compose-era filters stay.

### 3.3 The three that stay `docker run`

They need one change each, and it is the same change: their `ensureNetwork` would create a
**bridge** named `qits-net` if it ever went missing (`DockerExecutor:81-95`,
`DockerAgentRuntime:88-102`). Under swarm that silently rebuilds the wrong kind of network and
partitions the platform. Make it create an attachable overlay, or make it a no-op that logs.

Otherwise: CI step containers (`CiDaemonLauncher.buildArgv`) keep `--network qits-net`,
`--add-host host-gateway`, the sandbox flags and the optional socket mount, all unchanged on an
overlay. Workspace and agent containers likewise.

### 3.4 qits-gateway / qits-platform-edge

No docker calls, but both resolve upstreams by wire alias
(`QITS_GATEWAY_PROXY_HOSTS_*`, `QITS_EDGE_UPSTREAM_HOST_PATTERN`). Service names must equal today's
aliases exactly — §2 confirms a stack preserves the bare short name, so no config moves. One
behaviour changes: a route to a service whose task is still starting now gets **NXDOMAIN** rather
than a connection refusal. Check the gateway maps both to 502.

---

## 4. Decisions to make before coding

### 4.1 Network topology — recommend collapsing

Today: one bundle network per environment, one per application (nine `qits-env-prod-qits-*` bridges
exist right now), one `qits-platform`, plus the flat `qits-net`. `DeployService.desiredJoins` and
`reconcile` recompute the whole membership on every deployment and repair drift by joining
(`DeployService:949-1052`) — cheap, because `docker network connect` on a bridge is instant and
non-disruptive.

Under swarm every join is `service update --network-add`, which **restarts the task**. The
self-healing reconcile would become a restart storm: deploying one application would bounce every
platform service that needs to join its new network.

**Recommendation:** collapse to two overlays — `qits-net` (attachable, everything) and
`qits-platform` — and declare the full network set at service-create time. Per-application
isolation was nearly free with bridges and is not free with swarm; buy it back later with swarm's
own primitives if it is still wanted. If the topology is kept as-is, `reconcile` must be gutted to
"declare at create, never add afterwards", which is most of the same work.

### 4.2 The two loopback publishes — narrow, but real

**First, what is not a problem.** A service publishes nothing unless told to. Internal ports stay
private to the overlay and are reached by DNS at the real port, so all thirteen applications keep
listening on 8080 exactly as they do now. Port sharing is unaffected; swarm is not a per-port
registry for anything you did not publish.

The platform publishes exactly three host ports:

| Publish | Who dials it | Under swarm |
|---|---|---|
| edge `${PORT}:8080` | the outside world | unchanged, meant to be reachable |
| artifacts `127.0.0.1:8081:8080` | the **host docker daemon**, for `push`/`pull` — image refs are literally `localhost:8081/…` | loses the `127.0.0.1` |
| postgres `127.0.0.1:5433:5432` | **only the bootstrap CLI** | should not exist at all — see below |

Swarm's publish syntax has no `ip` field in either mode, so a published port goes from loopback-only
to all interfaces. On this WSL2 host that also reaches the Windows side.

**Postgres does not need publishing, and the publish is not about the platform.** Every service
dials the wire alias on the network — `BootstrapConfig.pgPort`'s own comment says it: *"Consumers
inside qits-net dial the wire alias on 5432 and never see this number."* The deployer provisions
roles and databases from inside a container, over the alias, with the admin password. The published
port has exactly one consumer: `PgAdmin`, opening plain JDBC to
`jdbc:postgresql://127.0.0.1:5433/postgres` (`SeedPhases:594`) to create the deployer's role and
database on a cold boot — and the run-args keep it afterwards *"so this CLI can reconnect to the
same server after the deployer replaces the seed container"*.

It is a bill for one of the deliberate simplifications of the shell→CLI port: *"the bootstrap runs
on the host, so it talks to the daemon the way a person does — no socket mount, no throwaway wrapper
container."* Swarm does not create this exposure; it removes the `127.0.0.1` that was hiding it.

**So remove the publish rather than firewalling it.** The key asymmetry: only a *swarm service*
cannot bind an IP — a standalone `docker run` still can. Three ways, cleanest first:

1. **Run the bootstrap itself in a container on qits-net** — §4.3. `PgAdmin` then dials the alias
   like every other component, and the publish has no consumer left at all.
2. **A throwaway forwarder for the life of the phase** — `docker run --rm -d -p 127.0.0.1:5433:5432
   --network qits-net <socat-image> tcp-listen:5432,fork tcp:<alias>:5432`, then JDBC to
   `127.0.0.1:5433` exactly as today. `PgAdmin` unchanged. The minimal fix if the CLI stays on the
   host.
3. Run the DDL inside a throwaway `psql` container. No forwarder, but `PgAdmin` loses the SQLState
   codes it leans on for idempotency and has to parse psql output instead.

**The registry is the one residue.** It is dialled by the host's docker daemon on every push and
pull, not just during a bootstrap, so a per-phase forwarder does not help. Either accept
`0.0.0.0:8081` with a host firewall rule set from the bootstrap's preflight, or keep a permanent
loopback-bound forwarder container in front of the service. The first is simpler and the exposure is
reviewable; the second preserves today's property exactly for the cost of one always-on container.

### 4.3 Run the bootstrap in a container — recommended, and best done first

The loopback publishes exist because the CLI runs **on the host** and therefore needs host-reachable
addresses. Put the CLI on qits-net and the whole class of problem goes.

**The objection to check first is the CLI's own**: *"no paths that mean one thing inside and another
outside"* is one of the three stated reasons for running on the host, and image builds are most of
what the bootstrap does. It does not apply. `docker build` and `docker cp` are **client-side**: the
client tars the context and streams it over the socket, so a containerized CLI builds from its own
filesystem. Probed — a marker file written inside the CLI container appeared in the built image,
through the `-f -` stdin form `SeedPhases` uses, and `docker cp` behaved the same.

Path agreement is only needed for **bind mounts**, and the bootstrap barely uses any: `SeedPhases`
already prefers `docker create` + `docker cp` + `start -a` and named volumes, and the one bind mount
is `/var/run/docker.sock`, which is the same path on both sides.

**What it buys**

- Postgres publishes nothing, ever. `PgAdmin` dials `<env>-qits-oci-postgresql:5432` with no code
  change — plain JDBC, SQLState idempotency, autocommit, masking, all intact.
- **`InNetworkHttp` disappears.** Every HTTP call to idp, ci and the deployer is a throwaway `docker
  run` today, with the status code scraped out of curl's output. Those become ordinary
  `java.net.http` calls like the rest of `api/`.
- The edge health poll stops needing `127.0.0.1:${PORT}`.
- **GraalVM and sdkman leave the host requirements** if the CLI ships as an image. `qits-local-up.sh`
  compiles a native binary with the host's JDK today; a `docker build` needs only docker. Probably
  the largest ergonomic win here.
- The bootstrap stops being the one platform component that is not a container. The deployer, ci,
  projects and workspaces all hold the socket from inside one already.

**What it costs**

- **It reverses a documented decision.** The README calls host-run *"the architecture's one real
  simplification over the script"*. This has to be a deliberate entry on its deviation list, not a
  side effect of the swarm work.
- **Buildx.** The builder is chosen by the *client*, so a CLI image without the buildx plugin
  silently falls back to the legacy builder — and this platform already has a scar from exactly
  that (qits-deployments' notes: `--network qits-net` on a build *"only worked because an older CLI
  in the step image fell back to the legacy builder"*). The probe image used here has no buildx and
  said so. Ship buildx in the bootstrap image, or builds change behaviour invisibly.
- ~~Chicken and egg.~~ **Not a problem: the CLI attaches itself.** A running container joins a
  network with no restart, and it can do it to itself through the socket it already holds — read the
  id from `/etc/hostname`, exactly as `DockerDeploymentDriver.selfContainerId()` already does.
  Probed: a container started with **no** qits network answered NXDOMAIN for a service, ran
  `docker network connect <overlay> $(cat /etc/hostname)` on itself, and resolved it immediately —
  new interface live, no re-exec. So the shim passes only the socket, and the CLI joins qits-net in
  the phase where it already creates it. No ordering constraint at all.

  One consequence for `unwrap`: an attached CLI is an endpoint, and docker refuses to remove a
  network that has one. It must disconnect itself before the network phase — the same shape as
  `EnvironmentOperations.delete` disconnecting platform services before removing an environment's
  networks.
- **The wrapper checkout.** It is resolved by walking up from cwd today, and *"a source this program
  cannot trust stops the boot"*. Containerized it needs `-v <wrapper>:/wrapper` — a bind mount the
  daemon never reads, so no path agreement is required — and `QITS_SRC` wants a named volume so a
  rerun does not re-clone the whole platform.
- **The displays.** JLine's exec provider under `docker run -it` with `TERM` passed through; the
  browser view's 8480 needs publishing or moves onto the network.
- **The socket mount is root-equivalent.** Not a new boundary for the platform — the deployer and ci
  already hold it — but it is one for the operator's CLI, which runs as the user today.
- **It does not remove the registry publish.** That one is dialled by the host's docker daemon, not
  by the CLI.

**Sequencing: do this before the swarm work, not with it.** Then the swarm migration inherits a CLI
that already dials aliases, and the only publish left to decide about is the registry. The
bootstrap's own rule — *"a behaviour change is a change to the only bring-up path there is. Prove it
with a real bootstrap"* — is the other half of the argument: one change per bootstrap, or a failure
has two candidate causes.

#### How the CLI gets into the container: a host half and a payload

Something has to put the CLI in a container on a cold machine. Split the program in two: a **host
half** that does the minimum the host must do, and a **payload** that is the whole bootstrap and
runs inside.

Probed end to end in miniature — a host side that builds a throwaway image with the payload copied
in (context streamed, so it needs no daemon-visible path), a payload that runs with only the socket,
creates the overlay, attaches itself, and exits 2. `docker run` returned 2 to the host. **The exit
codes are a contract** (2 = failure, 1 = a deployment that never landed, per the CLI's conventions)
and they survive the hop.

**The fork that matters is what the host half is.**

- **(A) It stays `qits-local-up.sh`.** 92 lines of shell that already resolve the wrapper, pass every
  `QITS_*` through and relay the exit code. It loses the sdkman/GraalVM compile and gains a
  `docker build`. The payload is built multi-stage — and **the toolchain is already in this repo**:
  `docker/Dockerfile.musl-builder` and `qits/graalvmce-musl-builder:jdk-25` build the ci-daemon as a
  fully static musl binary today (`SeedPhases:481-514`). So GraalVM leaves the host requirements
  using machinery that exists. Recommended: it is a change to a shim, not a new component.
- **(B) The host half is itself a released binary.** `curl -O qits-boot && ./qits-boot` — no
  toolchain, no checkout, one command from nothing. The real destination, and its own chicken-and-egg
  is answered by it being a *published artifact* rather than something built locally. Later.

**A temp image may not even be needed.** `SeedPhases` already does `docker create --entrypoint …` +
`docker cp` + `docker start -a` for every builder container — the same trick with no image and no tag
to clean up. The image wins anyway on two counts: tag it by the payload's sha and it is cached across
runs, and `docker run -it` has cleaner TTY semantics than `docker start -ai`. It also turns into a
publishable artifact (`qits/bootstrap:<version>`), which makes a second machine a pull-and-run.

**The rule that keeps this from becoming two things to maintain: the host half stays dumb.** No
config schema of its own — pass the whole environment through, mount what is needed, relay the exit
code. The shim already works this way (*"Modes, flags and every QITS_\* variable pass straight
through"*). The moment it interprets a `QITS_*` value, two places know the contract and they drift.

**What to prove first, in order:**

1. **The TUI under `docker run -it`.** JLine is pinned to its `exec` provider because the jni and ffm
   ones cannot be native-imaged — so it shells out, and the payload image needs a shell and `stty`
   (alpine, not scratch) with `TERM` forwarded. Not tested here; it is the one thing that could force
   a fallback to `PlainUi`.
2. **The run log.** `QITS_LOG_FILE` lands beside the CLI today and the docs treat it as the record.
   It needs a mount, or it dies with the container.
3. **SIGINT.** `docker run -it` forwards it; the host half must not trap it. Exit propagation is
   proven, signals are not.
4. The web view's 8480 needs publishing or moves onto the network, and `QITS_SRC` wants a named
   volume so a rerun does not re-clone the whole platform.

### 4.4 Cutover semantics — recommend adopting swarm's

Keep `--update-monitor`, `--update-failure-action rollback`, and read the verdict from the service's
image (§3.1). The alternative — keeping the hand-rolled stop/start/health/rollback against
services — preserves the current invariants but throws away the reason to move.

**The update order is per application, not global.** `start-first` is what makes the measured
rollback in §2 lossless, and it works by overlapping the two containers — which is exactly what the
current design refuses for stateful applications: *"one process per H2 file, one binder per
published host port"*. So the order is a key in each repository's `.config/qits/deployments.yml`,
defaulting to `start-first`, with `stop-first` for the deployer itself, the databases and anything
publishing a host port. `stop-first` still rolls back — swarm reverts the spec and starts a task
from it — it just has a gap in service, which is what those applications have today anyway.

**The gate window is not a straight port of `health-timeout-seconds`.** In the probe an unhealthy
task took ~22 s to be declared failed at `--health-interval 2s --health-retries 2`, longer than the
arithmetic suggests. The timeout becomes `--health-interval`/`--health-retries`/
`--health-start-period` plus `--update-monitor`, and the values want measuring per application
rather than deriving.

### 4.5 Stack vs. per-service calls in the bootstrap — recommend stack

The seed is a declarative set of eight services. `docker stack deploy` keeps that, keeps the
generated file readable (the stated reason it is a file at all), and §2 confirms the addressing
survives. The "leave deployer-managed services alone" rule ports as a filtered service list.

---

## 5. Implementation plan

Each phase is independently shippable, and phases 1–2 buy the ability to test the rest.

### Phase −1 — run the bootstrap in a container (§4.3)

Independent of swarm, and best done first: the CLI ships as an image and runs on qits-net, so it
dials wire aliases instead of published ports. Removes postgres' publish and the whole of
`InNetworkHttp`, and takes GraalVM off the host requirements. Prove it with a real bootstrap before
anything swarm-shaped moves.

### Phase 0 — the overlays, through a re-bootstrap

`qits-net` is a bridge with 14 endpoints on it and cannot be converted in place. That is not a cost
here: **the platform is re-bootstrapped rather than migrated**, so this is one edit — the bootstrap
creates `-d overlay --attachable` where it creates bridges today (`Docker.ensureNetwork`), and the
deployer's `ensureNetwork` does the same for the networks it derives. `unwrap` → `bootstrap` with
volumes kept is the normal path and the CLAUDE.md already calls it the cheap form of a real test.

Worth doing as its own step before phase 3, on today's `docker run` code: it proves the CI, workspace
and agent containers are indifferent to the network driver, with nothing else in flight to confuse
the result.

### Phase 1 — swarm preflight in the bootstrap

- `SeedPhases.preflight`: read `docker info` → `Swarm.LocalNodeState`; `docker swarm init` when
  inactive; fail loudly on a state that is neither (`pending`, `locked`, worker-only).
- `Docker.java`: add `swarmActive()`, `initSwarm()`, `serviceNames()`, `serviceRm()`,
  `stackDeploy()`, `stackRm()`.
- Record the swarm state in `RunState` so the summary prints it.

Small, self-contained, and it is goal (1).

### Phase 2 — the network ensure fix in the three `docker run` services

`DockerExecutor.ensureNetwork`, `DockerAgentRuntime.ensureNetwork`: create an attachable overlay
instead of a bridge, or no-op with a warning when the network is absent. Three files, one behaviour.
Ship it before phase 3 so a mid-migration restart cannot rebuild `qits-net` as a bridge.

### Phase 3 — `SwarmDeploymentDriver` beside the docker one

The seam already exists: `DeploymentDriver` is an interface in `deployments/`, with the
implementation in `service/dockerhost/` and a scripted fake in the suite. Add
`service/swarmhost/SwarmDeploymentDriver` selected by a config key
(`qits.platform.deployments.orchestrator=docker|swarm`, default `docker`).

The interface needs reshaping, and this is where the design work is. Proposed:

- `start(StartSpec)` → `apply(ServiceSpec)`: create-or-update, idempotent, carrying the full network
  list, mounts, labels, health command and update policy.
- `awaitHealthy(name, timeout)` → `awaitConverged(name, timeout)`: poll
  `service inspect .UpdateStatus.State` for `completed` / `rollback_completed` / `paused`.
- `aliasHolders`, `stop`, `restart`, `handoff`, `selfContainerId`, `containerId` → **removed** from
  the interface, not merely unimplemented. Leaving them makes the docker driver's model look like
  the contract.
- `connect` / `disconnect` → gone if §4.1 collapses the topology; otherwise `networkAdd`/`networkRm`
  with the task-restart cost documented at the declaration.

`DeployService.execute` (`:698-904`) then shrinks to: resolve target → pull for classification →
`apply` → `awaitConverged` → record. The predecessor search, the self-holder branch, the rollback
loop and the removal set all go.

Keep `FakeDeploymentDriver` on the new interface so the clone-alone rule holds — that rule is why
none of this needs docker to test.

### Phase 4 — run-args translation

In `ComposeTemplate`: emit swarm-shaped run-args for the 13 applications
(`-v` → `--mount`, `--group-add` → `--group`, publishes per §4.2). Two options, and the second is
better: keep the free-form string and translate it in the driver, **or** change the key family to a
structured form the driver renders per orchestrator. The free-form string was justified by "the
argv is docker's vocabulary"; with two orchestrators that stops being true.

`DockerDeploymentDriverTest.runArgsOfAnotherApplicationDoNotLeakIn` is the security property here —
whatever shape the key takes, that assertion must survive.

### Phase 5 — the seed as a stack

- `ComposeTemplate.COMPOSE` gains `deploy:` blocks, drops `container_name`, moves `group_add`, and
  declares `qits-net` as an external overlay.
- `PipelinePhases.seedStackUp` → `docker stack deploy --resolve-image never -c … qits`, with the
  deployer-managed filter reading `docker service ls` instead of `docker ps`.
- `seedArtifactsStart` / `seedPostgres` hand-over checks move to service queries.
- `UnwrapPhases.composeDown` → `docker stack rm qits`, plus a service reap by label and the network
  retry loop.

### Phase 6 — retire the referee, keep the bookkeeping

Delete `handoff`, `buildHandoffArgv`, `socketGid`, `HANDOFF_PREFIX`, the referee script, the
`selfHolder` branch and `selfContainerId()`. **Keep `sweepInFlight`'s adoption arm** and rewrite it
to settle a `STARTING` row by comparing the service's running image with the row's sha (§3.1) —
that is the half of the handoff swarm does not do for us, because the process that issued the
update is not around to record what happened.

Set the deployer's own service to `--update-order stop-first` in the same commit (§4.3): it holds a
config volume and was written on the stop-before-start assumption.

Do this **after** phase 3 is proven, not with it: the handoff is what makes the deployer able to
update itself at all today, and losing both paths at once leaves no way back.

### Phase 7 — flip the default, then delete

`qits.platform.deployments.orchestrator=swarm` becomes the default; run a full bootstrap; then
delete `DockerDeploymentDriver` rather than keeping two. Two orchestrators kept "just in case" is
two topologies to reason about, and the reason to move was that there is only one.

---

## 6. What this costs and what it buys

**Buys:** the cutover, the health gate, the rollback and the self-update referee all become the
orchestrator's job. That is ~400 lines of the most carefully-reasoned and most load-bearing code in
qits-deployments, plus every invariant its CLAUDE.md warns about (the alias union, the environment
label filter, the legacy-network breadth, the null-distinct queries around adoption).

**Costs, honestly:**

- One loopback publish (the registry) becomes a deliberate exposure decision. Postgres' publish
  turns out to be removable regardless of swarm — §4.2.
- Per-application network isolation gets expensive; §4.1 recommends giving it up.
- `start-first` overlaps containers, so single-writer applications must opt into `stop-first`.
- The self-update **bookkeeping** stays, reshaped. Only the referee goes.
- Swarm's own operational surface joins the platform: task history, `docker service ps` states,
  the ingress mesh, and node drain semantics the moment there is a second node.

**Not a cost, on this platform:** converting the networks. It would be a flag day for a running
environment; it is one edit in the bootstrap for one that is re-bootstrapped.

**Not affected at all:** qits-ci step containers, workspace containers, project agent containers,
every `docker build`, the git host, the registry protocol, and every service that does not shell
docker — which is most of them.
