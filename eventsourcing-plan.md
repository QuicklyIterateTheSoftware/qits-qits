# The event bus: qits-eventsourcing, first consumer qits-ci

The plan for turning qits-events into what its domain wants to be — event sourcing: other
services publish events to it and listen for them. The delivery vehicle is a new library,
**qits-eventsourcing**, which for now lives as a Maven module *inside qits-ci* (its first
consumer), separated cleanly enough that extraction later is a `git mv` plus a pom, not a
refactor. This document is the work order: the wire contract is fixed here first, so the
server side and the client side can be built by different agents in parallel and meet in the
middle.

Execution is by Opus 5 subagents, one per workstream, same pattern as the qits-events
bring-up (2026-07-31): parallel where repos don't overlap, sequential inside a repo.

## What exists today (the seams this builds on)

- **qits-events** (`services/qits-events`): `events` domain module + `service` module. The
  `Event` entity already takes a *client-supplied String id* (no generator), with `name`,
  `occurredAt` (caller's time), optional `description`, and Hibernate's `createdAt`/
  `updatedAt`. What it lacks for a bus: a structured `payload`, PUT semantics, and a way out
  (nothing pushes; the API is read/write only).
- **qits-ci** (`services/qits-ci`): modules `ci-daemon-protocol`, `ci`, `service`. Already
  ships `quarkus-websockets-next` (`@WebSocket(path = "/ci/daemon")` — the path literal
  carries the segment itself, our precedent for socket paths). `CiRunService` owns the run
  status transitions — the place a build becomes SUCCESS is the publish hook.
- Platform conventions that bind every piece: each domain module owns a **named datasource**
  and its **own Flyway lineage** shipped as defaults in `META-INF/microprofile-config.properties`
  (ordinal 100); no FK and no entity reference across contexts — foreign things are named by
  String id; websocket literal paths must be added to `quarkus.quinoa.ignored-path-prefixes`
  **in the same commit** (docs/project-setup-quinoa-angular.md); telemetry-style externals
  are dark in `%dev`/`%test`.

## Answering the design question: CDI events, or our own interface?

Quarkus has two native shapes that look like a bus:

1. **CDI events** — `jakarta.enterprise.event.Event<T>.fire(…)` / `@Observes T`. In-process,
   type-routed. qits-ci *already observes* framework events this way (`StartupEvent`,
   `Router`). Piggybacking the remote bus on **bare** `@Observes` is the conflict you
   suspected: the two delivery worlds become indistinguishable at the observer site, and a
   service that both fires a type locally and round-trips it through the bus delivers it
   twice. Bare CDI is out.
2. **SmallRye Reactive Messaging** — `@Incoming`/`@Outgoing` channels with a connector SPI;
   this is *exactly* how the Kafka and AMQP extensions plug in. It is the right shape for
   the extracted library one day, but a connector implementation is real machinery
   (channel lifecycle, config binding, ack strategies) — too much for an in-service first cut.

**Decision: a banal explicit API of our own, CDI-discovered.** Publishing is a method call;
listening is implementing an interface:

```java
// eventsourcing module — the whole public surface
public interface QitsEvent {
  String signature();     // default: getClass().getSimpleName()
  UUID eventId();         // v4, generated at construction, stable across retries
  Instant occurredAt();
  String name();          // short label for the event log; default = signature()
}

@ApplicationScoped public class QitsEventBus {
  public void publish(QitsEvent event) { … }   // fire-and-forget; durability via outbox
}

public interface QitsEventListener<E extends QitsEvent> {
  Class<E> eventType();                        // signature derived from it
  void onEvent(E event);
}
```

Listeners are plain `@ApplicationScoped` beans; the subscriber collects all
`QitsEventListener` beans at startup (`Instance<QitsEventListener<?>>`), derives the
signature set, and subscribes. Internally the dispatcher MAY deliver via CDI with a
qualifier (`@FromEventBus`) if that simplifies testing — the qualifier keeps remote events
invisible to ordinary in-thread observers — but the public contract is the interface, which
is framework-neutral and extraction-friendly. Migrating to a reactive-messaging connector
later changes the internals of one module and no consumer's mental model.

## The wire contract (fixed now; both sides build against this)

The eventsourcing module lives in the qits-ci repo and **must not** depend on qits-events'
domain module (cross-repo dependency); the contract below is the only coupling, duplicated
as DTOs on each side.

**One superseding delta since, and it is written elsewhere:** the envelope and the frame each
gained a nullable `parentId` — the id of the event that caused this one — frozen in
event-causation-plan.md's Decision 3, which is where that field's semantics live. Everything
below stands as written, because absent means null: a publisher built against this document is
still a correct publisher.

### 1. Idempotent publish — `PUT /events/api/events/{id}`

- `{id}` is a UUID v4, chosen by the publisher.
- Body (the envelope, also what the websocket later pushes):

```json
{
  "name": "BuildSuccessful",
  "occurredAt": "2026-07-31T12:46:03Z",
  "payload": "{\"branch\":\"main\",\"commitSha\":\"…\",\"repoId\":\"qits-ci\",\"runId\":\"…\"}",
  "description": null
}
```

- `payload` is the event class's fields as **canonical JSON**: object keys sorted, no
  insignificant whitespace, no nulls for absent fields. Canonicalization happens in the
  *publisher* (the eventsourcing module); the server stores and compares the string verbatim.
- Semantics:
  - id unknown → create the row, **201**.
  - id exists and `name`, `occurredAt`, `payload` are all exactly equal → idempotent replay,
    **200**, no write, no re-broadcast.
  - id exists and anything differs → **400** (the caller reused a UUID; unretryable).
- The existing `POST /events/api/events` stays for manual/simple creation; both paths
  broadcast on *create* (only on create — a 200 replay pushes nothing).
- Server change needed: `V2__payload.sql` adds `payload clob` (nullable) to `Event`;
  `description` stays what it is — the human account. `name` doubles as the **signature**.

### 2. Listen — `@WebSocket(path = "/events/stream")` on qits-events

- Client connects, then sends one text frame:
  `{"subscribe": ["BuildSuccessful", "SomethingElse"]}` — replaces the connection's
  subscription set; `["*"]` means everything.
- Server pushes each *newly created* matching event as a text frame:
  `{"id": "<uuid>", "name": "…", "occurredAt": "…", "payload": "…", "description": null}`.
- Live-stream only, at-most-once, no replay/offset/catch-up — **deliberately**. Catch-up
  from the event log (the actual event-sourcing read model) is the next feature and is
  prepared separately; nothing in this protocol may preclude it (the envelope carries the id;
  a future `{"replayAfter": …}` field extends the subscribe frame compatibly).
- Quinoa: `quarkus.quinoa.ignored-path-prefixes` gains `/stream` (relative — after
  `ui-root-path` stripping) in the same commit as the `@WebSocket`; `PackagedSurfaceIT`
  gains the probe "plain GET `/events/stream` → 404, never HTML" (websockets-next claims
  only the upgrade handshake — the doc's measured trap).

### 3. Durability — the outbox in the publisher

`publish()` flow, as specified:

1. Attempt the PUT inline.
2. On success (200/201): done. Nothing written locally.
3. On failure: persist an `OutboxEvent` row (id = the event's UUID, envelope fields,
   `attempts`, `nextAttemptAt`, `status`), then a `@Scheduled` sweeper retries up to **5**
   attempts with exponential backoff (1s · 4^n cap 5m — attempt spacing ~1s/4s/16s/64s/4m),
   marking `FAILED` after the fifth.
4. A **400** (payload-mismatch or validation) is unretryable → `FAILED` immediately, at
   step 1 or from the sweeper.

Idempotency is what makes the retry safe: the UUID is fixed at construction, so a PUT that
half-succeeded (server wrote, response lost) replays as a 200. Note for the record: this is
failure-path-only persistence per the spec — a crash *between* step 1 failing and step 3
committing loses the event; the write-ahead variant (persist first, delete on ack) closes
that window and is a one-method change inside the module if we ever want it. Not now.

The outbox is the module's own context: datasource **`eventsourcing`**, H2-file default in
the module's `META-INF/microprofile-config.properties`, Flyway lineage
`db/eventsourcing/migration/V1__init.sql` — the same shape `epics` has inside qits-projects,
which is precisely what makes later extraction clean.

### 4. Configuration surface (of the eventsourcing module)

```properties
qits.events.url=http://qits-events:8080        # scheme+host+port, NO path (platform shape)
qits.eventsourcing.enabled=true                # %dev and %test default: false — dark outside
                                               # a deployment, same policy as OTel
```

The PUT URL and the `ws://…/events/stream` dial address both derive from `qits.events.url`.
Disabled mode: `publish()` is a no-op (debug log), the subscriber never dials. Tests that
exercise the module itself enable it against an in-test stub server (plain Vert.x HTTP+WS on
an ephemeral port), never against a real qits-events.

## Module layout in qits-ci after this feature

```
qits-ci/
  ci-daemon-protocol/    (unchanged)
  eventsourcing/         NEW — artifactId qits-eventsourcing. The future library:
                         QitsEvent, QitsEventBus, QitsEventListener, OutboxEvent + sweeper,
                         websocket subscriber, canonical-JSON serializer. Depends on nothing
                         qits-ci-specific. THE EXTRACTION RULE, enforced by review: no import
                         from eu.wohlben.qits.ci.* anywhere in this module.
  ci-events/             NEW — artifactId qits-ci-events. The event classes qits-ci emits;
                         today exactly one: BuildSuccessful(runId, repoId, branch, commitSha,
                         imageDigest, finishedAt) implements QitsEvent (occurredAt =
                         finishedAt). Depends only on eventsourcing. Separately *publishable*
                         one day; separately *published* is explicitly out of scope now.
  ci/                    (unchanged except the publish hook)
  service/               depends on eventsourcing + ci-events; wires them
```

Root pom gains the two modules (before `ci`); `service`'s application.properties carries the
`qits.events.url` default and the `%dev`/`%test` darkness.

## The round trip that proves it

`CiRunService` marks a run SUCCESS → constructs `BuildSuccessful` → `QitsEventBus.publish()`
→ PUT lands the row in qits-events → qits-events broadcasts on `/events/stream` →
qits-ci's own subscriber (registered `QitsEventListener<BuildSuccessful>`) receives it →
consumes it visibly (an INFO log naming runId and commitSha is enough; no further behavior
hangs off it yet). One service is both producer and consumer by design — that *is* the
acceptance test.

## Workstreams (one Opus 5 agent each)

**Contract note for all agents: the wire contract above is frozen.** An agent that believes
the contract is wrong reports back; it does not adjust its side unilaterally.

### Agent A — qits-events grows the bus surface (repo: services/qits-events)
- `V2__payload.sql`; `payload` on entity/DTO/mapper.
- `PUT /events/api/events/{id}` with the three-way semantics; equality = exact string/field
  match on (name, occurredAt, payload).
- `EventStreamSocket` (`@WebSocket(path = "/events/stream")`, websockets-next — new
  dependency in service pom), subscription-set-per-connection, broadcast on create from
  both POST and PUT paths. In-process fan-out (CDI event or direct call from EventService)
  — single-instance service, no cluster concern.
- Same commit: `/stream` into `ignored-path-prefixes`; PackagedSurfaceIT probes (GET
  /events/stream → 404 not HTML; WS handshake works against the packaged jar; PUT semantics
  201/200/400).
- `./mvnw verify` green, push (GitHub + platform git host), pipeline redeploys, verify live.

### Agent B — the eventsourcing + ci-events modules (repo: services/qits-ci, first of two)
- Both modules as laid out above, with unit tests: canonical JSON (key order, absent-field,
  round-trip), outbox flow against a stub server (success / retryable failure + backoff
  progression / 400-instant-FAILED / replay-200), subscriber (subscribe frame, dispatch by
  signature, reconnect with backoff after server drop).
- The extraction rule: no `eu.wohlben.qits.ci.*` imports in `eventsourcing`.
- `./mvnw verify` green at repo level. Commit on main; **do not push yet** (Agent C pushes
  the repo once integration lands — one pipeline run, not two).

### Agent C — qits-ci integrates (repo: services/qits-ci, after B)
- Wire modules into `service`; publish hook in the SUCCESS transition; a
  `BuildSuccessfulListener` consuming with the INFO log; config defaults + darkness.
- `@QuarkusTest`: a SUCCESS transition with eventsourcing enabled against a stub → exactly
  one PUT with a stable UUID; disabled (test default) → zero dials from every other test.
- `./mvnw verify` green, push both remotes, pipeline redeploys qits-ci.

### Agent D — deployment wiring + end-to-end proof (superproject + live platform, after A & C)
- `qits-local-up.sh`: `qits.cd.run-args.qits-ci` gains
  `-e QUARKUS_DATASOURCE_EVENTSOURCING_JDBC_URL=jdbc:h2:file:/data/eventsourcing/h2/eventsourcing`
  and `-e QITS_EVENTS_URL=http://qits-events:8080` (data volume `qits-ci-data` already
  mounted at /data). Same values into the **live** `qits-cd-config` volume (the bootstrap's
  volume-write mechanism — cd caches at boot, so restart/redeploy cd's config consumer or
  rewrite before the next deploy), superproject edit left uncommitted for review.
- E2E on the local platform: land any commit on a tracked repo → CI run SUCCESS → assert the
  BuildSuccessful row via `GET /events/api/events` (name, payload fields) → assert qits-ci's
  consumer log line. Re-run the same wire event → assert idempotency (no second row).
- Known traps from 2026-07-31, both in memory: pushes that rebuild qits-ci can lose their
  CI run silently during cutover (recovery: replay `POST /ci/api/events/post-receive`); and
  qits-ci's *own* redeploy is part of this rollout, so expect one cutover blip.

Sequencing: **A ∥ B**, then C, then D. A and B share nothing but the frozen contract.

## Out of scope, named so nobody drifts into it

- Extracting qits-eventsourcing or qits-ci-events into their own repos, and publishing
  either to the platform Maven/npm-style registry.
- Replay/catch-up, durable subscriptions, consumer offsets — the next feature, prepared
  separately; this design leaves the door open (ids in the envelope, extensible subscribe
  frame) and builds none of it.
- A second consumer service, dead-letter UI for FAILED outbox rows, event schema versioning.
