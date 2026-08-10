# Gateway routes from deployment events

Status: **DRAFT — epic, not scheduled.** Concept settled in conversation 2026-08-08.
Blocked on one prerequisite (§1) before any wave starts.

## Goal

Replace the gateway's hardcoded service map — the `QitsService` enum plus per-deployment
`qits.gateway.proxy-hosts.*` entries — with a map of proxyable targets that maintains
itself: a deployment opens a route, a decommission closes one, and no gateway code or
config changes when a service is added.

The design is event-fed, not registry-backed. The gateway does **not** call
qits-platform-deployments at runtime; the ingress must never depend on another service
being up to answer a request. Deployments remains the *authority* on topology, but its
knowledge reaches the gateway asynchronously, as events, and the gateway serves from its
own materialized copy.

Explicitly rejected alternatives, so they do not come back:

- **Services self-register with the gateway** (PUT /gateway/register + deregister).
  Forces the gateway to infer liveness (health polling — monitoring territory, which is
  qits-observability's), and an endpoint where a request names a proxy target is the
  SSRF the gateway's security invariant exists to forbid. Deployments already *knows*
  every lifecycle moment self-registration would report.
- **Gateway reads topology from deployments at runtime** (pull/snapshot). Makes the
  ingress 100% dependent on deployments' availability.

## 1. Prerequisite: event bus delivery is a guarantee, not a hope

The whole design stands on ServiceDeployment events arriving. The bus is *meant* to be
reliable — publishing retries exist, so an event may be **delayed but never lost**; a
lost event is a bug, not a tolerated mode.

Before wave 1 starts:

- Verify the publish path end to end and close any remaining loss window. The known
  lost-announce incidents (post-receive announces that needed manual replay) must be
  explained and fixed, not worked around.
- Fix the stale prose: `ci-event-release.yml` still documents the bus as "at-most-once
  with no catch-up and no replay". Wherever that is still true, it contradicts the
  intent above; align the implementation and then the comments.
- ⚖1 Decide what a subscriber that was down during publish gets. Retried delivery
  covers a slow consumer; it does not cover one that did not exist yet (see §5,
  cold start).

This epic does not add a reconciliation/anti-entropy loop against deployments. That is
deliberate: with a reliable bus it is dead weight, and building it anyway would license
the bus to stay lossy.

## 2. The event: ServiceDeployment

Today a green release run makes qits-ci announce `SoftwareRelease` per `artifacts:`
entry, and deployments deploys from it. This epic adds **ServiceDeployment**, published
by qits-platform-deployments after a deploy succeeds — same content family as
SoftwareRelease, enriched with what routing needs:

    environment      which environment this deploy landed in (or `platform`)
    serviceName      the deployable's artifact id
    version, sha     the deployed coordinates
    upstream         resolved swarm service name + port — deployments owns the naming
                     scheme; the gateway derives nothing
    routing          frontendPath, extra root prefixes (the /v2 case), navigation
                     label + position — from the repo's own config, §3
    stamp            monotonic, assigned by deployments — orders events per service

Consumer semantics:

- **Idempotent upsert** keyed `(environment, serviceName)`, last-write-wins by `stamp`.
  A duplicate or out-of-order delivery cannot regress the map.
- **Decommission is a tombstone**, not absence: a future `ServiceDecommissioned` event
  (same key, same stamp rule) closes the route. Manual for now — an operator action in
  deployments that publishes the event.
- A deploy in progress changes nothing: the swarm service name stays valid while the
  container behind it is replaced. (Optional later polish: a "deploying" state so the
  gateway answers 503 instead of 502 during the swap. Not this epic.)

## 3. Routing config lives in the repo, read at the released sha

Each repository declares its deployables' routing in `.config/qits/`, following the
existing convention (`ci-event-release.yml` and kin). The declaration is **per
deployable entry**, keyed by artifact name, because one repository may release several
artifacts (service + lib) and only some of them are routable:

    deployables:
      qits-example-service:
        frontendPath: /example
        extraPrefixes: []            # the /v2 exception, when a protocol forces one
        navigation: { label: Example, position: 9 }   # omit = routed, not in the menu
      # a lib released from the same repo simply has no entry here

Deployments receives tag and sha with the release, reads this file **at that tag**, and
stamps the event with it. The repo owns its identity, deployments owns the topology
moment, the gateway owns the materialization.

Rules:

- **Validation happens in deployments, at deploy time, loudly.** A bad frontendPath
  fails the deploy; it must not surface as a gateway that quietly dropped an event.
- Same landing-order rule as the existing trigger files: the config must be committed
  before the release that needs it.
- ⚖2 Config schema details: whether `deployables:` extends `ci-event-release.yml`'s
  `artifacts:` list or is its own file; exact field names.

## 4. The gateway side: materialize, persist, serve

- A consumer applies ServiceDeployment/ServiceDecommissioned to an in-memory route
  table — the same longest-prefix `RouteTable` model as today.
- The table persists as a **file on a config volume**, not a database. It is a
  single-writer materialized view; Postgres + Flyway + an ORM would break the gateway's
  doctrine (stateless, native, minimal extensions) to hold a cache. Precedent: the
  deployer's run-args already live on a config volume.
- On startup the gateway loads the persisted file and serves immediately; events only
  ever move it forward. Deployments being down affects route *changes*, never requests.
- Gateway-side hard checks stay: no empty prefix, no prefix collisions (a colliding
  event is rejected and logged, never silently shadowed).

Security — the invariant moves, it does not weaken. "Upstream targets come from
configuration only" becomes: **targets come only from ServiceDeployment events whose
publisher is qits-platform-deployments' idp-verified identity, and their persisted
materialization.** Any event source short of that is an SSRF vector; the gateway must
reject it.

Display identity moves with routing identity: navigation label and position come from
the event (i.e. from the repo's config), which retires `QitsService`'s second job. The
enum shrinks to nothing over the rollout.

## 5. Cold start

A gateway deployed into a fresh environment has consumed no events and would route
nothing. Publishing reliability does not fix this — the events predate the subscriber.

⚖3 Two candidate answers; pick one in wave 1:

1. **Seed the file** (recommended): deployments deploys the gateway, so it can write
   the initial materialized map onto the gateway's config volume as part of that
   deploy. Deterministic, no ordering dance.
2. **Re-announce**: deployments re-publishes ServiceDeployment for every current
   service after an environment's gateway comes up. Simpler event story, fragile
   ordering ("after it comes up").

## 6. Waves

1. **Prerequisite closed** (§1): publish path verified, loss window closed, stale
   comments fixed, ⚖1 and ⚖3 decided.
2. **Producer**: config schema (§3), deployments reads it at the tag, validates, and
   publishes ServiceDeployment after each successful deploy.
3. **Consumer, shadow mode**: gateway consumes and materializes but `proxy-hosts` stays
   authoritative; the gateway logs every divergence between the two maps. Runs until
   divergence is zero across normal deploys.
4. **Flip**: the event map becomes authoritative; `proxy-hosts` and the `QitsService`
   enum are retired. Cold-start seeding (§5) lands here at the latest.
5. **Decommission** (future, cheap once 1–4 stand): the ServiceDecommissioned event and
   its operator action in deployments.

## Out of scope

- Health checking / liveness inference — qits-observability's territory. A dead
  container behind a live route answers 502, which is honest.
- Any runtime gateway→deployments call, including "just for repair".
- Multi-instance or cross-environment route sharing; each environment's gateway holds
  its own map (its environment's services plus the platform services it fronts).
