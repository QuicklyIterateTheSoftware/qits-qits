# Deployment model — DRAFT

**Status: draft, not gospel.** This is a brainstorm document. We iterate on it, and
parts of it WILL be wrong. Do not treat anything here as a decision until it moves
into a real plan.

The problem it exists for: we switched too many services to the platform plane, and
we modelled deployment wrong. The target has evolved while drafting — the current
sketch is section 2, whose short form is: **every environment runs the full stack;
the few true platform services run INSIDE prod as `platform-` named applications;
"the platform" is simply production.**

## 1. The lifecycle today

How a change becomes a running container, and which service owns each step.
Source of truth: `PlatformModel.java` (bootstrap CLI), the qits-ci and qits-events
READMEs, and the live platform (eleven containers).

### The lifecycle of a change

     human: commit on a branch ahead of main
       │
       ▼
    (1) RELEASE ································· qits-workspaces
     POST /workspaces/api/branches/release
       stamps a release(<calver>) commit
       publishes SCMRelease ─────────────────────────────────────┐
       pushes the promoted refs                                  │
       │                                                         │
       ▼                                                         │
    (2) REFS MOVE ······························· qits-artifacts │ (git host)
     main             trunk; builds, deploys nothing             │
     environment/dev  deploy ref → environment plane             │
     platform/main    deploy ref → platform plane                │
       │ post-receive fan-out, one POST per consumer             │
       ├────────► qits-projects: debounced backup                │
       │          push to GitHub                                 │
       ▼                                                         │
    (3) BUILD ··································· qits-ci        │
     one run per pushed ref; pipeline config read                │
     at the event sha over the git host's blob API               │
       image ───► qits-artifacts OCI registry                    │
       on green:                                                 │
         POST build-succeeded ──► deployer (direct,              │
              fire-and-forget, aud=qits-platform-deployments)    │
         publishes BuildSuccessful ──────────────────────────────┤
       │                                                         │
       ▼                                                         │
    (4) DEPLOY ·································· qits-platform- │ deployments
     only when (repo, branch) matches an application             │
       pulls localhost:8081/qits/<repo>:<sha>                    │
       run-args from its config volume (read at ITS boot)        │
       docker run qits-pd-<plane>-qits-<name>-<sha>              │
       stops and replaces the predecessor (docker ps -q)         │
       │                                                         │
       ▼                                                         │
     the running container                                       │
                                                                 │
    THE BUS ····································· qits-events ◄──┘
     every event is a row + /events/stream; qits-ci is both
     a producer and the bus's first consumer:
       SCMRelease ───► release pipelines in qits-ci: publish npm
                       and docs artifacts to qits-artifacts, then
                       one SoftwareRelease per declared artifact ──► BUS
       SoftwareRelease ─► ci-event-upstream-*.yml in consumer repos:
                       force-push maintenance/<dep>, cut that repo's
                       own release ──► back to (1)  [the release trains]

     tokens for (3)→(4): qits-idp

Two escape hatches bypass (1): a direct push to a deploy ref deploys code with
stale version identity and no release bookkeeping (forbidden by convention), and
`-o qits.no-ci` pushes a ref without triggering (3).

### Where each service lands

The deploy ref decides the plane; the container name carries it.

    platform/main ──────► one container for the whole host          (9)
        gateway  artifacts  ci  platform-deployments  idp
        projects  events  observability  platform-docs
        joins qits-platform, qits-net and every environment's networks

    environment/dev ────► one container per environment             (2)
        workspaces  stt

    no deploy ref at all:
        dns            repo exists, absent from the bootstrap model
        repositories   retired 2026-08-06 (git storage is DFS blobs
                       inside qits-artifacts)

    lifecycle without a container of their own:
        ci-daemon         release-train binary, runs inside CI steps
        workspace-daemon  runs inside workspace containers
        all frontends/*   ship inside their service's image via the
                          webui gitlink; a SPA release only reaches
                          users when its host service redeploys
                          (the maintenance/<spa> train does the bump)

### The knot

Six services ARE the lifecycle they are deployed by: workspaces (1), artifacts
(2, plus images and packages), ci (3), platform-deployments (4), events (bus),
idp (tokens). Each one rolls over through the very pipeline it implements —
which is why self-hosting landmines (drain the queue before releasing artifacts,
ci or platform-deployments) exist, and why any re-model has to answer what
deploys the deployer.

### What is wrong with this picture (why the draft exists)

- 9 of 11 services are "platform", so the environment plane is nearly empty — the
  plane distinction stopped carrying meaning. "It felt cross-cutting" was enough to
  flip a service; there was no test.
- With one instance of ci, idp, projects, events and observability for all stages,
  a stage is not actually isolated: its builds, tokens, inventory and telemetry all
  live in shared state. Promoting a broken platform service breaks every stage at
  once.
- The release flow assumes both planes per repo (stale-plane bugs in handoff.md:
  it recreated qits-gateway's deleted `environment/dev` branch).
- Services bundle functions that belong to different planes. qits-artifacts is the
  clearest case: the proxy-cache (want: shared, x-stage) lives beside the git host
  and the release stores (unclear — probably per stage?).

## 2. Target model

Working sketch, iterating. Earlier drafts of this section kept a "platform
plane" (first gateway+idp, then +observability) and invented an admission test
for it. Superseded by the reframe below; the routing and naming mechanics
survived and follow after it.

### The reframe: platform services live inside prod

qits is self-hosting — the platform machinery IS the product, running in
production. So the model is not "planes": **every environment runs the same
full stack** (gateway, observability, artifacts, ci, deployments, workspaces,
events, projects, docs, …), and "qits-platform" was production all along.

**The convention: a platform service is an application deployed ONLY into
prod, and its REPO is named `qits-platform-<x>`.** On the wire it is dialed
by its repo name, unprefixed — a singleton needs no instance qualifier —
while env services are dialed `<env>-qits-<app>`. The repo name itself says
"this instance serves every env"; there is no separate plane, no separate
deployer — prod's deployer deploys them like any other prod application.
Five repos carry the name (renamed on GitHub 2026-08-08). The bar: per-env copies
cannot do the job (one port, one trust root, one zone authority) — or would
multiply heavy shared-by-nature state for no isolation gain (the artifact
store and its views):

- **qits-platform-edge** — the edge. Binds the host's only port, reads
  `$env` off the host name and forwards the whole request to that env's
  gateway — UNIFORMLY, prod included: the apex (`qits.eu`) forwards to
  prod-qits-gateway exactly as `*.dev.$domain` forwards to dev-qits-gateway.
  (Matches qits-dns's existing model: `qits.eu` is prod, envs are subdomains.)
  Route table = the env list; it knows no application names.
- **qits-platform-idp** — the ONE issuer, for everything. It joins every
  env's networks (safe: inbound-only — the multi-network ambiguity bites
  callers, and idp dials nobody). Per-env idps were considered (they would
  make idp changes stageable) and dropped: hierarchy-of-issuers mechanics
  open too many cans of worms. Env isolation lives in the token model
  instead — see below.
- **qits-platform-artifacts** — the ONE store: git host, OCI registry, npm
  registry, proxy caches, blob store, docs store — for every env. A per-env
  artifacts (with a cache hierarchy chaining to prod's) was drafted and
  dropped: three copies of the platform's heaviest state bloat too much for
  the isolation they buy. One store also collapses promotion: an image built
  once is visible to every env, so "promote" means "deploy that sha" — no
  artifact ever moves. The costs, accepted:
  - It breaks the inbound-only purity of the other two: **its GC calls INTO
    every env** — pins from each env's deployments and each env's ci (the
    daemon pin). Keep = the UNION of all envs' pins. Unambiguous under the
    naming convention (it dials `dev-qits-deployments`, qualified), but it
    is a platform service depending on env services.
  - GC stays fail-closed across ALL sources: any env's pin source failing
    aborts the sweep — a sweep with partial pin knowledge deletes what a
    silent env still runs. So one dead env blocks GC platform-wide.
    Accepted: GC is not urgent, and a dead env is the louder problem.
  - The env list (= pin endpoints) is injected config; env creation and
    deletion touch it.
- **qits-platform-docs** — the reader over the one docs store. Stateless, and
  the store it reads is qits-platform-artifacts: a per-env reader would be
  three front doors onto one store (the argument the old PlatformModel
  comment already made). The repo already carried the right name — it was
  the template for the scheme.
- **qits-platform-dns** — the one zone authority. Purely outward facing: the
  registrar delegates `qits.eu` / `qits-dev.eu` to ONE server, and it is the
  thing that NAMES the envs — per-env copies are conceptually impossible.
  Binds host port 53 (the third host-port holder, beside the edge's 8080 and
  the git host's 8081). Records are written over its HTTP API (env creation
  will be a writer). Deployment stays out of the MVP — `*.localhost` needs
  no DNS; it joins the bootstrap when real domains do.

Running inside prod also answers their operational needs for free: their
telemetry goes to prod-qits-observability, their deploys are ordinary prod
deploys, their health is prod's concern.

The remaining special thing about prod is a ROLE, not a service:

- **The bootstrap origin.** The CLI cold-boots prod (platform services
  included); prod's deployer creates and first-deploys every other env.
  "What deploys the deployer": the CLI for prod, prod for everything else.

### The environment as the unit

    host :8080
        │
    qits-platform-edge  (in prod; joined to every env's edge network)
        │
        │ qits.eu (apex)   ──► prod-qits-gateway     ─┐ uniformly:
        │ *.dev.$domain    ──► dev-qits-gateway       │ every env by
        │ *.preprod.$domain──► preprod-qits-gateway  ─┘ host name
        ▼
    ┌─ every env, the same shape ────────────────────────────────┐
    │  <env>-qits-gateway         path routing, auth, headers    │
    │  <env>-qits-observability   observes THIS env              │
    │  <env>-qits-ci              builds for this env            │
    │  <env>-qits-deployments     deploys THIS env               │
    │  <env>-qits-workspaces, -events, -projects, …              │
    └────────────────────────────────────────────────────────────┘
      created and first-deployed by prod; runs autonomously after

    qits-platform-idp        (in prod; joined to every env's networks)
      the one issuer — every service in every env authenticates
      against it
    qits-platform-artifacts  (in prod; joined to every env's networks)
      the one store — git host, registries, proxy caches, blobs,
      docs; its GC asks EVERY env's deployments + ci for pins
    qits-platform-docs       (in prod)
      the reader over the one docs store
    qits-platform-dns        (in prod; host :53; not in the MVP)
      the one zone authority — it names the envs

- **Observability is per-env** ("receives data" is an implementation detail,
  not a reason to be x-env). An env's window dies with its env — you look
  from prod. Prod observes itself, which is today's accepted state; the
  upstream OTLP tee offers an optional env→prod feed if that ever hurts.
  The platform services export to prod-qits-observability — they run in
  prod, so that is simply their env's sink.

### Machine auth: one issuer, env-scoped claims

Every service in every env authenticates against qits-platform-idp — it
joins all env networks, so it is reachable everywhere under one unambiguous
name. dev-qits-ci gets its token there and presents it to
dev-qits-deployments, which validates against the same issuer. One JWKS, one
token endpoint, no federation, no hierarchy.

What keeps envs isolated is the TOKEN MODEL, not the topology: client ids
and audiences are env-qualified, matching the naming convention.

    client `dev-qits-ci` + its secret
        │ client_credentials ──► qits-platform-idp
        ▼
    token, aud=dev-qits-deployments
        │ Bearer ──► dev-qits-deployments  ✓ accepted
        ╳ Bearer ──► prod-qits-deployments — rejected: wrong audience

A compromised dev secret can only mint tokens whose audiences are dev
services. `aud=platform-…` audiences are the ordinary way every env reaches
the platform services: `dev-qits-ci` is granted `aud=qits-platform-artifacts`
(push images, publish) but never `aud=prod-…`. Anything that DOES cross an
env line (promotion, if it ever needs to) is a client whose granted audiences
cross it — an explicit, auditable grant, in one place.

The cost accepted with one shared issuer: an idp change cannot be staged in
dev first — it rolls straight into the thing every env depends on. That is
the price of "no federation", and it is why qits-platform-idp must stay the
most boring service on the platform: envs differ only in registered client
rows, never in idp code or deployment shape.

### Routing and naming (survives from earlier iterations)

Why a name must carry the env: Docker's embedded DNS scopes a lookup to the
networks the REQUESTING container joins, and a client cannot say "resolve on
network X". A multi-network client dialing a bare name that exists in three of
its networks gets the union — round-robin across envs. qits-platform-edge
sees three `qits-gateway`s; a bare name from its position is a coin flip.

**Convention (settled): the qualified name is used EVERYWHERE on the wire** —
`<env>-qits-<app>` for env services, `qits-platform-<app>` for the five
platform services. Every caller dials it, env-internal peers included.
Technically only multi-network clients need it, but one rule with no
exception beats "qualified here, bare there". The edge's route table:

    qits.eu (apex)    ──► http://prod-qits-gateway:8080
    *.dev.$domain     ──► http://dev-qits-gateway:8080
    *.preprod.$domain ──► http://preprod-qits-gateway:8080

Images stay env-agnostic regardless: no peer name is hardcoded — they arrive
as deployer-injected config (`qits.events.url`, the intake url) — so the env
lands in injected config, never in the image. That is the invariant to
protect, and it is independent of the naming convention.

The flatter variant — the edge dialing `$env-$app` directly, skipping the env
gateway — was considered and dropped: it centralizes a cross-env route table
(and auth/header enforcement) at the edge.

### Docker swarm has most of this built in

The host daemon is already a single-node swarm manager (kept so on purpose,
2026-08-08). Swarm gives:

- **Forced unique naming**: service names are unique per swarm, not per
  network. `docker stack deploy` with stack = env names services
  `dev_qits-ci`, `preprod_qits-ci`, … — the env prefix, automatically.
- **The two-name scheme, automatically**: inside the stack's overlay network,
  swarm registers the bare compose name (`qits-ci`) as an alias beside the
  full name. Only the full name is used, per the convention.
- **VIP-based discovery**: a service name resolves to a stable virtual IP and
  swarm moves tasks behind it. Cutover stops being an alias handoff; rolling
  update + health gate replace the deployer's predecessor dance.

What swarm does NOT give: L7 host-header routing. The routing mesh publishes
ports; nothing in swarm parses `$app.$env.$domain`. The edge gateway stays.

The platform services fit as plain swarm services under their repo names
(`qits-platform-idp`, `qits-platform-artifacts`, …) — no stack prefix needed,
because the repo name already carries the qualifier a singleton needs.

The cost: qits-deployments' `docker run` + aliasHolders cutover machinery is
replaced by `docker service update`. A real reshape — but of code whose job it
replaces, not extra machinery beside it.

### The envs

Three, fixed: **dev, preprod, prod**. Envs are NOT epic-scoped in this model —
that may come later and is out of scope here. So the cost of "full stack per
env" is bounded and known: three stacks of ~11 services, ~33 containers on one
host. No trimmed profiles needed for now; if epic envs ever arrive, they are a
different, lighter thing to model then.

### Open questions, next iterations

- **The lifecycle re-wiring around the ONE store.** The git host is
  qits-platform-artifacts, so a push lands in one place — which env's ci does
  its post-receive fan out to? Presumably the ref decides:
  `environment/dev` → dev-qits-ci, `environment/prod` → prod-qits-ci; but
  `main` (trunk, builds only) needs an owner, and so does the projects
  backup fan-out. Same question for the bus: events are per-env, the store
  is not — who hears a release?
- **Promotion.** Largely collapsed by the one store: an image built once is
  visible to every env, so "promote" = deploy that sha in the next env. What
  remains: where "release to prod" runs (prod's workspaces?), and whether
  each env's ci rebuilds or reuses the earlier env's image (reuse is the
  point of the one store — but then one build must serve every deploy ref,
  which today's per-ref builds do not).
- **Env creation choreography.** What exactly prod seeds into a new env: idp
  client registrations (ids + granted audiences), config volumes, the stack,
  DNS records (written to qits-platform-dns over its HTTP API). Plus
  touching every platform service: connecting them to the new env's
  networks, and adding the env's pin endpoints to platform-artifacts' GC
  config.
- **Prod's self-hosting knot remains** — section 1's landmines become
  prod-internal, unchanged. The reframe does not dissolve them; it contains
  them to one env.
- The edge needs the env list. Static config, asked from prod's deployer, or
  convention (forward any `$env`, let DNS refuse the rest)?
- Swarm network granularity: today's per-application networks are finer than
  one overlay per stack. Keep the fine grain (a stack can declare several
  networks) or accept one net per env?

## 3. Cut lines

For each service that hosts more than one function, where to cut. One verdict
so far.

### qits-artifacts: platform service, whole — no split

**Decision: qits-artifacts becomes `qits-platform-artifacts`, unsplit, and
its GC becomes multi-deployments aware.**

The dilemma: the proxy-cache should be x-env, but qits-artifacts' GC consumes
qits-deployments (pins, fail-closed) and qits-ci (the daemon pin) — so a
shared artifacts needs a deployments to ask. Two clean-looking outs: split
the proxy-cache off (the split-off part needs no pins), or keep artifacts
per-env with a cache HIERARCHY (each env's artifacts chains to prod's as its
upstream — one config value, pins stay env-local at every layer; drafted in
an earlier iteration of this section, see git history). The hierarchy was
dropped by decision: three copies of the platform's heaviest state — git
host, blob store, OCI + npm registries — bloat too much for the isolation
they buy. The split was dropped with it: once the store is platform anyway,
carving the proxy-cache out buys nothing.

What the one store gives:

- **Promotion collapses.** An image (or any artifact) built once is visible
  to every env; "promote" = deploy that sha in the next env. Nothing ever
  copies between stores.
- One git host, one npm registry, one docs store — no source-of-truth
  question, no seam network, no upstream auth.

What it costs — the GC reshape:

    qits-platform-artifacts GC ──► dev-qits-deployments     + dev-qits-ci
                                   preprod-qits-deployments + preprod-qits-ci
                                   prod-qits-deployments    + prod-qits-ci

- **Keep = the UNION of every env's pins.** Pin sources are injected config
  (the env list); env creation and deletion edit it. MVP note (2026-08-08):
  ships UNCHANGED single-source first — the reshape is gated to land before
  any second env exists (see deployment-unification-plan.md, D5).
- **Fail-closed extends across all sources**: any env's pin source failing
  aborts the sweep, because a sweep with partial pin knowledge deletes what
  a silent env still runs. One dead env therefore blocks GC platform-wide —
  accepted: GC is not urgent, and a dead env is the louder problem.
- It breaks the inbound-only purity of the platform set: this platform
  service CALLS INTO every env. Unambiguous under the naming convention
  (qualified names), but it is a dependency pointing down the layering —
  the one such dependency, and it is periodic and read-only.
