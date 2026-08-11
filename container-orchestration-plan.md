# Centralized container orchestration — qits-containers

Status: plan APPROVED and executing 2026-08-11. Round 1 = build the repo + migrate
qits-ci. The 2026-08-10 idea draft and code survey are folded in below; the
refinement decisions are recorded here so the doc stays the one source.

## Decisions (user, 2026-08-11)

- Scope round 1: new repo (core lib + service + client lib) AND one consumer
  migrated end-to-end. workspaces/projects follow in later rounds.
- First adopter: **qits-ci**. Its containers die with the service today (the
  registry is an in-memory map), so it gains the most.
- The service owns lifecycle AND the data plane. The two ~300-line reverse
  tunnels (AgentTunnels, WorkspaceTunnels) centralize here eventually; round 1
  ships the proxy behind `qits.containers.proxy.enabled=false`, minimally
  proven, because ci proxies nothing inbound.
- **Headline requirement: restart resilience.** A qits-containers restart must
  not invalidate running containers. They keep running, reconnect on their own,
  everything continues. No reap-on-boot of live workloads, ever.

## Design in one page

The restart model is qits-deployments', generalized:

- A durable row (`ct_container`) is written BEFORE `docker run` — owner,
  workload, owner_ref, container_name (unique), spec_json/spec_hash (env is
  never persisted: it carries secrets), policy, desired vs observed state,
  append-only detail. A crash can never leave a container without a row.
- One label namespace, `qits.containers.*` (managed/owner/workload/ref/row/
  instance). Legacy vocabularies are never read; absence of the label is the
  statement (the deployments rule).
- Boot sweep ADOPTS: inspect each in-flight row's own container; running →
  adopted; settled otherwise per policy; desired=ABSENT rows replay their
  delete. No code path removes a container not named by a row.
- A rows-only observer (30s, single ct-worker, 2-strike demote, recover on
  return) reconciles reality; policy sweeps (idle stop with stamp-on-sight,
  volume reconcile from the never-called listWorkspaceVolumes shape, row GC)
  are also row-driven.
- Lifecycle policies, not hardcoded behavior: EPHEMERAL (ci steps; rm on
  delete, no --restart, maxAge GC), IDLE_STOP (project agents; stop-never-
  remove, unless-stopped, PT4H), EXPLICIT (workspaces; delete may take
  volumes, unless-stopped).
- Every docker call carries a timeout and an output bound (ContainerProcess,
  the third deliberate CiProcess/PdProcess twin) — a security property.
- Data plane: containers dial OUT to stable DNS aliases and re-dial on their
  own; all tunnel state is in-memory, rebuilt lazily. Durable = which
  containers exist. In-memory = live sockets. An orchestrator restart is
  therefore invisible to running traffic.
- API (`/containers/api`, machine-token only, owner = token subject):
  PUT ensure per (owner, workload, ref); stop/touch/logs; DELETE one
  (`?logs=true` returns the bounded tail atomically before rm — logs-AS-reap;
  `?volumes=true` for EXPLICIT); DELETE all per owner+workload with
  `createdBefore` (what qits-ci's boot reap becomes — row-scoped, never a
  host-wide label sweep). Failed reads are 5xx, never 404.
- ensureNetwork never creates a bridge (swarm plan §3.3): inspect, WARN+no-op
  by default (`qits.containers.network-create=off|overlay`).
- Client lib: plain HttpClient (instance field, HTTP_1_1 pinned), four-outcome
  results (REFUSED ≠ UNREACHABLE, never merged), TokenSource seam, ordinal-100
  default `qits.containers.url=http://qits-containers:8080`.
- Eventstream jar + eventstream datasource from day one (causation trio now,
  durable listeners later without a flag day). Datasource baseline everywhere.

qits-ci migration (Part B): `CiStepRunner` seam and the whole daemon control
plane are untouched — step containers keep dialing `ws://<env>-qits-ci:8080/
ci/daemon`, which is why an orchestrator restart mid-step is survivable.
`CiDaemonLauncher` becomes spec-builder + client adapter (buildArgv →
buildWorkloadSpec; logs+reap → destroyWithLogs; reapOrphans → owner-scoped
destroyAllOwned(createdBefore=bootInstant) with PT60S boot patience;
ensureNetwork deleted). `CiProcess` dies with no callers. qits-ci loses its
docker socket mount. Hard cutover, no dual path; rollback is one revert.
Bootstrap: qits-containers becomes a core seed service (the dns precedent) —
present and healthy before ci's first pipeline.

The full plan (schema, restart/crash matrix, per-call failure semantics, test
reshaping, work packages with verification) is in the session plan file; this
doc tracks the campaign.

## Work packages and status

| WP | what | status |
|---|---|---|
| 1 | scaffold services/qits-containers, clone-alone green | DONE (a9818fe, 7 tests, pushed) |
| 2 | core primitives (ContainerProcess, DockerArgv, spec/policy/labels, driver+fake) | DONE (397dc59, 46 tests, pushed) |
| 3 | registry + restart story vs the fake (BootSweep, Observer, sweeps) | DONE (cf3a692, 88 tests, pushed; causation stamp MEASURED firing despite the augmentation warning; volume GC narrowed to row-driven decisions — grace key declared but deliberately unread) |
| 4 | real driver + REST + auth + ContainersRestartAdoptionIT (real docker) | DONE (add8513, 111 JVM tests + 5 ITs, pushed; ADOPTION PROVEN on real docker 29.7.2 — Id/StartedAt unchanged, bystander survived; measured: docker's combined-inspect needs `index .State "Health"` on the raw-JSON path; wrong audience is 401 not 403) |
| 5 | client lib | DONE (755d8dd, 152 JVM tests, pushed; sealed four-outcome answers + client-owned UNREADABLE; native reflection debt documented not shipped — ContainersWireReflection paste in README) |
| 6 | proxy skeleton, flag off | DONE (3520fff, 160 tests, pushed; per-tunnel secret required from day one — the sources' path-parameter impersonation weakness NOT reproduced; round-trip proven in-JVM) |
| 7 | ship: Dockerfile, pipelines (first dual maven+docker release), deployments.yml, submodule wiring | DONE (2df567c + wrapper 8b308f0; two-step release — no build image carries JDK+docker; docker artifact spelled qits/qits-containers; submodule wired per ritual, gitdir absorbed) |
| 8 | bootstrap seeding as core service | DONE (cli-bootstrap b3262e3, 232 tests; seed maven publish extended to `-pl core,client`; receive-only idp audience like the deployer; cold plan 70 phases) |
| 9 | qits-ci hard cutover + its ComposeTemplate side | DONE (qits-ci ae9d779, 425 tests — CiProcess deleted, owner=`${quarkus.oidc-client.client-id:qits-ci}`, ref = the container name; cli-bootstrap 407e2e5, 233 tests — QITS_CONTAINERS_URL in, socket mount + --group-add OUT of qits-ci, audience repointed, read-shaped warm probe) |
| 10 | USER DIRECTIVE: full clean rebootstrap keeping config volumes, green start-to-finish with no manual nudges (failures fixed at source, whole re-run), then live restart proof on the fresh platform, then SHUT DOWN the Windows host | RUNNING (2026-08-11 night) |

GitHub remote (created empty 2026-08-11):
`https://github.com/QuicklyIterateTheSoftware/qits-containers.git` — scaffold
main is pushed there before the WP7 submodule add.

## Verified inventory (2026-08-10 survey, still the factual base)

Everything shells the docker CLI through ProcessBuilder. Five spawners:

| module | containers | notes |
|---|---|---|
| qits-projects (`agenthost/DockerAgentRuntime` + `AgentContainers`) | one refinement agent per project | labels `qits.managed=project-agent`; ensure ladder; stop-never-remove; PT4H idle sweep; no timeouts on docker calls |
| qits-workspaces (`control/DockerExecutor` + `WorkspaceService`) | one per workspace | richest vocabulary; DB + labels as registry; dangling-volume reconcile implemented but uncalled |
| qits-ci (`daemonhost/CiDaemonLauncher` + `CiDaemonStepRunner`) | one per pipeline step | label `qits.ci.run`; timeout + bounded output everywhere; boot reaps ALL labelled orphans host-wide; logs before rm -f |
| qits-deployments (`DockerDeploymentDriver`) | long-lived apps — OUT OF SCOPE — plus the socket-privileged handoff referee | `qits.platform.deployments.*` labels are the registry; the adopt-on-boot model |
| qits-cli-bootstrap | self-containerization + seed helpers | pre-platform; out of scope permanently |

Later rounds (after ci): workspaces and projects migrate onto the same
contract; the deployer's handoff referee stays self-sufficient (the deployer
must survive the platform being down) unless the swarm migration retires it
first (docker-swarm-migration-plan.md §3.1 — under swarm the referee's job is
the orchestrator's).
