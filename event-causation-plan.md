# Event causation: a parent id, and the context that stamps it

The follow-up to eventsourcing-plan.md and the companion to ci-event-triggers-plan.md. The bus
records *that* things happened; nothing records **what caused what**. The release train is a chain
— an event fires a build, the build publishes an event, that event fires another build — and today
each hop is an unrelated row in the event log, distinguishable from coincidence only by reading
timestamps and guessing. This feature adds one nullable field, `parentId`, to the event envelope,
and one mechanism that fills it in without every publisher having to remember to.

The purpose is a picture: a chain-walk in qits-spa-events that draws the train. This document
builds the field, the stamping and the query that make such a picture possible, and builds no
picture.

Status: SHIPPED 2026-07-31. Agent I (qits-events, `16656f0`) and Agent J (the eventsourcing module
in qits-ci, `88d1bca`) are deployed and ACTIVE. Agent K drew the first real edge by hand through the
gateway: a three-event chain, the pushed `/events/stream` frame carrying `parentId`, the walk down
(`?parentId=`) and the walk up (`parentId`) agreeing at every hop, 200 on the byte-identical replay,
400 on a re-PUT naming a different cause and 400 on one with the field removed — absent means null
in the comparison, and null is not the value already stored. Probe rows deleted afterwards. Nothing
stamps a non-null parent in production yet; the first *automatic* edge is the trigger engine's
(Decision 7). The wire contract delta below is frozen, on the same terms the parent plan set: an
agent that believes it is wrong reports back rather than adjusting its own side.

## What exists today (the seams this builds on)

- **`QitsEvent`** (`services/qits-ci/eventsourcing/`) declares four methods — `signature`,
  `eventId`, `occurredAt`, `name` — and `CanonicalJson`'s mix-in `@JsonIgnore`s all four so that
  none of them can reach a payload. `BuildSuccessful` holds `eventId` as an ordinary record
  component and is kept honest by that mix-in and by nothing else; the two binaries it took to
  discover that are written up in `EventWireReflection`'s javadoc.
- **`EventEnvelope(name, occurredAt, payload, description)`** is the PUT body, built in exactly one
  place — `EventEnvelope.of(event)`, called from `QitsEventBus.publish`. `EventFrame` is the same
  four fields plus the row's `id`, read off `/events/stream`.
- **`EventDispatcher.dispatch(text)`** reads a frame, looks the signature up in a map built at
  `@PostConstruct`, and calls `onEvent` directly. It is reached from `EventStreamSubscriber`'s
  `onTextMessage`, and that connector is created with
  `.executionModel(BasicWebSocketConnector.ExecutionModel.BLOCKING)` — a worker thread, one frame
  at a time.
- **The outbox** stores the envelope *whole* (`OutboxEvent.name/occurredAt/payload/description`),
  and `OutboxSweeper` rebuilds an `EventEnvelope` from those columns to re-send. `V1__init.sql`'s
  own comment says why: the server compares the payload verbatim, so a row that re-derived the
  envelope could serialize differently later and turn its own retry into a 400.
- **qits-events** compares `name` + `occurredAt` + `payload` on the idempotent PUT and leaves
  `description` outside it; `Validations.requireUuid` guards the path id; `EventCreated` is the
  stream frame *and* the in-process CDI signal, observed `AFTER_SUCCESS` by
  `EventStreamSubscriptions`; `Event.id` is `varchar(255)` with no FK to anything, by platform rule.
- **qits-ci's publish hook** is `CiRunService.announceRun(run, finishedAt)` → the `RunAnnouncer`
  port → `BuildSuccessfulAnnouncer` → `bus.publish(...)`, all on the single-threaded `ci-run-worker`.

## Decision 1 — the bus stamps; `QitsEvent` and every event class are untouched

The obvious shape is a fifth interface method, `UUID eventParentId()`, defaulting to null or to a
read of the ambient context. **Rejected, on four counts, none of them taste.**

1. **Records are immutable and the parent is known later than the event.** `BuildSuccessful` is a
   record; an instance built at the SUCCESS transition cannot acquire a parent afterwards. Making
   it a component means every event class this platform ever writes carries an eighth field, a
   second compact-constructor default beside `eventId`'s, and a second constructor overload to hide
   it — ceremony paid forever by every author, for a value the author does not have.
2. **A default method that reads a `ThreadLocal` is a method that answers differently on different
   threads for the same object.** The event would report the dispatch thread's parent inside
   `onEvent` and null on the sweeper's thread an hour later — and the sweeper re-sends a stored
   envelope precisely so that a retry is the same request. `eventId`'s javadoc rests the whole
   idempotency argument on "fixed at construction, stable for the object's life"; a sibling field
   that is neither would quietly undo it.
3. **It puts a fifth entry in the mix-in, which is the one place this repo has already been bitten
   silently.** A record implementing `eventParentId()` as a component leaks it into the canonical
   payload unless `CanonicalJson$QitsEventMixin` grows a `@JsonIgnore` *and* native-image keeps
   reflecting on that mix-in. The measured failure — `eventId` present in a shipped payload, no
   crash, no log — is exactly this shape. Not adding the method removes the hazard rather than
   guarding it.
4. **One read of the context is one place to test.** Stamping in the bus means the context is read
   at `publish`, in one method, on the way into one envelope constructor — and because the outbox
   row is built from the envelope, persistence of the parent comes free.

**Decision: `parentId` is envelope data, stamped by `QitsEventBus.publish` at envelope-build time.**
The public surface grows one overload and nothing else:

```java
public void publish(QitsEvent event) { publish(event, null); }

/** Announce that something happened, caused by the event with this id. */
public void publish(QitsEvent event, UUID parentEventId) { … }
```

and inside, the whole of the rule:

```java
UUID parent = parentEventId != null ? parentEventId : CausationScope.current();
EventEnvelope envelope = EventEnvelope.of(event, parent);
```

**Precedence: an explicit argument always wins over the ambient context.** An author who names a
cause knows something the runtime does not — typically that the causation crossed a thread and a
database row to get there, which is precisely the CI trigger case (Decision 7).

**No self-parent repair in the bus, and no cycle guard.** A guard that catches only the length-one
cycle is worse than none: it cannot see `A → B → A`, and its presence tells a reader that cycles
have been handled. This feature takes the same position ci-event-triggers-plan.md took on build
loops — detection belongs at a level that can see the graph — and adds the trail such a feature
would need. The server does reject a self-edge (Decision 4), because that one is decidable from a
single row and is therefore validation rather than analysis.

## Decision 2 — `CausationScope`: a thread-local, and a scope API around it

`EventDispatcher` wraps the per-frame listener loop; anything published inside `onEvent` is stamped
with the arriving frame's id. That is the mechanism's entire reason to exist, and making the same
class public is what lets a listener bridge a thread hop it creates itself — which the library
already tells listeners to do (`QitsEventListener`: "Anything slow belongs on the listener's own
executor").

```java
package eu.wohlben.qits.eventsourcing;   // API, beside QitsEvent — not in control/

public final class CausationScope {
  /** Run body with parentEventId as the ambient cause. Null means "nothing is the cause in here". */
  public static void with(UUID parentEventId, Runnable body);

  /** The ambient cause on this thread, or null. */
  public static UUID current();
}
```

- **Clearing is restore-the-previous, never remove-unconditionally.** `with` saves the current
  value, sets the new one, and in a `finally` restores: `set(previous)` when there was one,
  `remove()` when there was not. Both halves matter. Restoring rather than clearing is what makes
  nesting work; calling `remove()` for the null case rather than `set(null)` is what keeps a pooled
  worker thread from carrying an empty map entry, and — the correctness half — makes it impossible
  for the *next, unrelated* task on that thread to observe a stale cause. `EventDispatcher` runs on
  a websockets-next worker; `ci-run-worker` is a single thread reused for every run in the process's
  life. A leaked context there would attach a stale parent to every event for as long as the
  process ran.
- **Nested scopes: the innermost wins for its region, and the outer is intact after it.** No
  merging, no stack of causes: an event has one parent.
- **A body that throws still restores.** `finally`, not a trailing statement.
- **A plain `ThreadLocal`, not an `InheritableThreadLocal`.** Inheritance copies the value at thread
  *creation*, and pooled executors — the only kind used here — create their threads long before any
  consumption, so it buys nothing for the case that matters while silently tainting any thread a
  listener happens to spawn for an unrelated reason. Explicit propagation is the honest shape.
- **`with(null, body)` is the deliberate detach**, and it is a statement about a region ("in here,
  nothing is the cause"), which is a different sentence from `publish(event, null)` ("I have no
  argument to pass"). This asymmetry is real and was decided deliberately — see the settled
  decisions section.
- **No `call(…, Supplier<T>)` yet.** Nothing needs a value out. It is an additive overload the day
  something does.

**Deliberately not `ManagedExecutor`, `ThreadContextProvider` or a Vert.x duplicated context.** Each
would make the propagation automatic for one framework's threads and invisible for the rest, and
this module has one thread hop today, in another repo, in code that has not been written. The
extension point is named in Decision 6 and is not built.

## Decision 3 — the wire contract delta (frozen)

Both surfaces gain one nullable string field, spelled `parentId`.

### PUT `/events/api/events/{id}` — the envelope

```json
{
  "name": "BuildSuccessful",
  "occurredAt": "2026-07-31T12:46:03Z",
  "payload": "{\"branch\":\"main\",\"commitSha\":\"…\",\"repoId\":\"qits-ci\",\"runId\":\"…\"}",
  "description": null,
  "parentId": "6c3f2b1a-…"
}
```

- **`String`, not a JSON `UUID` type**, because every id in this contract is a string — the path
  id, the frame's `id`, `Event.id`'s `varchar(255)` column. The API takes a `UUID`; the envelope
  converts at the boundary.
- **Present as an explicit `null` when there is no parent**, like `description`. `EventEnvelope`
  already carries `@JsonInclude(ALWAYS)` as the one documented exception to `CanonicalJson`'s
  omit-nulls rule, and that annotation is on the type, so the new component inherits it with no
  further thought. Key order needs none either: the shared mapper has
  `SORT_PROPERTIES_ALPHABETICALLY`, so the envelope's keys are already alphabetical and a new one
  simply lands between `occurredAt` and `payload`.
- **Absent is legal and means null.** An older publisher that never learned about the field keeps
  working; Quarkus binds a missing property on a record to null and does not fail on unknown ones.
  This is the only backward-compatibility clause the feature needs, and it is one-directional —
  see the rollout order in Agent K.
- **`parentId` participates in the idempotency comparison.** It joins `name`, `occurredAt` and
  `payload`; `description` stays outside. Argued in Decision 4.
- **`parentId` never appears in `payload`.** It is envelope, exactly as `eventId` is, and the reason
  it stays out is stronger than symmetry: the payload string is compared byte-for-byte, so a field
  that entered it would make the same event published under two different parents two events the
  server cannot reconcile. Because no event class ever declares the field (Decision 1),
  `CanonicalJson` and its mix-in are **unchanged** — there is nothing new to hide.

### `/events/stream` — the frame

```json
{"id":"…","name":"…","occurredAt":"…","payload":"…","description":null,"parentId":"6c3f2b1a-…"}
```

`EventCreated` gains a sixth component, appended last. Its javadoc currently calls the five
components *and their order* the contract; the order clause is retired — both sides bind by name,
and `CanonicalJson` disables `FAIL_ON_UNKNOWN_PROPERTIES` precisely so a subscriber built against
five fields survives a sixth.

## Decision 4 — qits-events: the column, the comparison, the validation

**`V3__parent_id.sql`:**

```sql
alter table Event add column parent_id varchar(255);
create index idx_event_parent_id on Event (parent_id);
```

- **`varchar(255)`, matching `id`.** A parent id is an id of this table; a narrower column would be
  a second opinion about what an id is.
- **Indexed, from the first row.** The read model is `where parent_id = ?` — children-of-X — and a
  chain-walk is that query once per hop. The log is append-only and unbounded, so an unindexed scan
  per hop is the wrong shape before it is a slow one. A plain single-column index is enough:
  ordering the children of one parent is an in-memory sort of a handful of rows, so
  `(parent_id, occurred_at)` would buy nothing for twice the write cost.
- **No foreign key, not even a self-referential one.** The platform rule forbids FKs across
  contexts, and within this one a self-FK would impose an insertion order the bus does not
  guarantee — see the existence discussion below.

**The comparison gains `parentId`** (`name` + `occurredAt` + `payload` + `parentId`; `description`
still outside). The line the existing rule draws is *identity of the occurrence* versus *prose about
it*, and a parent is on the identity side: it is machine-consumed structure, it is the edge a
visualization draws, and two PUTs of one id claiming different parents are two different claims
about history. Keeping it outside would mean the server silently keeps the first and answers 200,
while the publisher believes it published the second — a divergence between two services about the
shape of history, with no error anywhere.

The strictness costs nothing that is not already a bug: the outbox stores the envelope whole, so a
publisher's own two attempts cannot disagree. **Which is exactly why the outbox must gain the
column** — if `OutboxSweeper` rebuilt the envelope without it, every retry of a caused event would
either 400 against a first attempt that had landed, or quietly re-publish it as a root. That is the
single most load-bearing line in the implementation.

**Validation:**

- `parentId`, when present, must be a canonical UUID — the existing `Validations.requireUuid`, run
  only when non-null. Not a UUID → 400.
- `parentId` equal to the event's own `id` → 400. An event cannot cause itself; this is malformed
  input in the same sense a non-UUID is, decidable from one row, with no graph to consult. Note the
  pairing with Decision 1: the client does not repair a self-edge, the server refuses it, and
  because 400 is unretryable the publisher gets a `FAILED` outbox row and a WARN naming the id —
  which is the visibility a bug of that kind deserves.

**No existence check on the parent, deliberately.** A `parentId` naming an event this log has never
seen is stored as it stands. Three reasons, and the first alone settles it:

1. **Nothing orders a parent's arrival before its child's.** Publishes are independent HTTP calls;
   a parent that failed its inline attempt sits in an outbox for up to four minutes while its child
   lands on the first try. An existence check would 400 that child — and 400 is unretryable, so the
   outbox marks it `FAILED` and the event is lost *permanently* on a fact that became true sixty
   seconds later. A timing accident would become data loss.
2. **The log has no retention policy yet, and the first one will begin invalidating parents of
   events still in the window.** A dangling parent must degrade to "the chain starts here", never to
   a write that cannot happen.
3. **A parent may belong to a publisher this instance never heard from** — a replay gap, a
   different service, a future catch-up feature. The id is still a true statement about causation.

A dangling parent is data, not an error. The reader's job is to treat an unresolvable `parentId` as
a chain root and, if it wants, to say so.

## Decision 5 — the read model: the smallest honest affordance

No UI, no tree endpoint, and exactly two additions:

1. **`parentId` on `EventDto`.** MapStruct maps it by name, and it costs one record component. This
   alone lets a client walk *upwards* — child → parent → parent — with the `GET /events/api/events/{id}`
   that already exists.
2. **`GET /events/api/events?parentId=<uuid>`** — an optional query parameter on the existing list
   route, returning that parent's children newest-first (`EventRepository.listChildrenOf`). Absent
   parameter is today's behaviour, unchanged. This is the downward walk, which is the release
   train's actual shape (one release fans out to N builds) and which a client cannot do without
   listing the whole log.

**Not built: `/events/{id}/chain`, a depth parameter, a root filter, a graph endpoint.** A tree
endpoint has to decide depth limits, cycle handling and ordering before anyone has drawn the
picture; the SPA can build any of those from these two, and the one that survives contact with a
real train is the one worth serving. A query parameter is also the only addition here that needs no
new route literal and therefore no `quarkus.quinoa.ignored-path-prefixes` entry — worth noting
because that key is the platform's standing trap and this feature does not touch it.

**A chain-walking client must bound its own depth and track visited ids.** Cycles are possible by
construction (ci-event-triggers-plan.md ships no loop guard, on purpose), and nothing on the server
side prevents one. Say it in the SPA's own notes when it is written.

## Decision 6 — async: the audit, and what is out of scope

**No async consume path exists today.** Traced rather than assumed:

| path | thread | publishes? |
| --- | --- | --- |
| `EventStreamSubscriber.onTextMessage` → `EventDispatcher.dispatch` → `onEvent` | websockets-next worker, `ExecutionModel.BLOCKING`, one frame at a time | yes — this is the case the ThreadLocal serves |
| `QitsEventBus.publish` → `EventsPublisher.put` (`HttpClient.send`, synchronous) → `Outbox.enqueue` (`QuarkusTransaction.requiringNew`, same thread) | the caller's | — |
| `OutboxSweeper.tick` | `@Scheduled`, scheduler thread | re-sends a **stored** envelope; stamps nothing |
| `EventStreamSubscriber.redial` (`vertx.setTimer`) | event loop | dials only |
| qits-events `EventStreamSubscriptions.onEventCreated` (`AFTER_SUCCESS`) | the transaction-completing thread | fans out; publishes nothing |
| qits-ci `CiRunService`'s `ci-run-worker` | its own single thread | **yes** — and it is the one real hop (Decision 7) |

So: consume → publish → deliver is one thread end to end today, and a bare `ThreadLocal` is not a
simplification but a complete answer for it. The sweeper is the case that could have broken and does
not, because `parentId` is fixed when the envelope is built and stored with it — the property
Decision 4's column exists to protect.

**Out of scope, named so nobody drifts into it:** automatic context propagation across executors,
Mutiny/reactive pipelines, Vert.x duplicated contexts, `@Scheduled` invocations, and any
`ThreadContextProvider`/`ManagedExecutor` integration. **The extension point is `CausationScope`**,
which is the manual bridge until one of those is real; the shape a later feature would take is an
additive `CausationScope.wrap(Runnable)` / `wrap(Executor)` that captures `current()` at submit time
and re-establishes it at run time. It needs no wire change and no server change, which is why
building it now would be building it blind.

## Decision 7 — the CI trigger hop, and the relationship to ci-event-triggers-plan.md

The trigger engine's flow breaks the single-thread assumption on purpose: the raw listener consumes
a frame on the dispatch thread, the matched run is *enqueued*, and the run — including its
`BuildSuccessful` publish — executes later on `ci-run-worker`. A `ThreadLocal` set around `onEvent`
is long gone by then. **The provenance column the trigger plan is already adding is exactly the
carrier**: `CiRun.triggerEventId` is the id of the event that caused the run, stored durably,
survives a restart, and is available at `announceRun` because that method has the `CiRun` in hand.

**The path, explicitly:**

- `RunAnnouncer.onRunSucceeded(runId, repoId, branch, commitSha, finishedAt)` gains a
  `String triggerEventId` — a plain String id, which is exactly how the `ci` module names foreign
  things, and which keeps that module free of any eventsourcing type.
- `BuildSuccessfulAnnouncer` (in `service/`, which already depends on the bus) parses it and calls
  `bus.publish(event, parent)`. A `POST_RECEIVE` run passes null and publishes a root event, which
  is correct: a push is not caused by an event.
- **Not** `CausationScope.with(...)` inside `CiRunService`. That would make `ci/` import
  `eu.wohlben.qits.eventsourcing`, which is the dependency the `RunAnnouncer` seam exists to
  prevent, and it would be the wrong tool anyway — the announcer is both the site that knows the
  cause and the site that publishes, so an argument is more honest than an ambient value.

**Recommendation for the trigger plan's Agent G: stamp from day one, and say so in that plan's
workstream.** It is two lines inside work G is doing regardless — the port parameter and the
overload call — and the column it reads is one G is already adding. **The cost of deferring is
permanent**: causation is known only at the moment of the run, nothing else records it, and chains
recorded without it cannot be backfilled. That is also the sequencing argument — **this feature
lands before or with the trigger engine**, never after, or the platform's first release trains are
half-born chains.

**Two graphs, and they are duals.** The trigger plan's future DAG feature is a graph of
*declarations*: which repo's trigger file listens for which event, static and knowable without
running anything, so a cycle can be found before it runs. `parentId` is the graph of *occurrences*:
what actually caused what, knowable only after the fact, and therefore the only way to see a cycle
that a conditional `when` produces sometimes. **This feature builds no guard either**, for the
reason that plan gives — but a depth query over `parent_id` is the runtime detector that feature's
static analysis structurally cannot have, and it exists the day this ships.

## Impact inventory

**services/qits-ci — `eventsourcing/` (the library):**

- `QitsEvent.java` — **unchanged**. Stated because not changing it is the decision.
- `CausationScope.java` — NEW, in the module's API package beside `QitsEvent`.
- `QitsEventBus.java` — the `publish(event, parentEventId)` overload and the precedence rule.
- `control/EventEnvelope.java` — a fifth component; `of(QitsEvent, UUID)`.
- `control/EventFrame.java` — a sixth component.
- `control/EventDispatcher.java` — the listener loop wrapped in `CausationScope.with(...)`. The
  frame's `id` is a String; parse defensively and scope null on anything unparseable rather than
  throwing (dropping a frame is a designed failure here, and killing dispatch over an id format is
  not).
- `control/Outbox.java`, `control/OutboxSweeper.java`, `entity/OutboxEvent.java` — the parent is
  written on enqueue and re-sent verbatim on sweep.
- `resources/db/eventsourcing/migration/V2__parent_id.sql` — NEW (`alter table outbox_event add
  column parent_id varchar(36)`; no index — the sweeper never queries by it).
- `control/CanonicalJson.java` — **unchanged**, mix-in included. See Decision 1 point 3.

**services/qits-ci — `ci-events/`, `ci/`, `service/`:**

- `ci-events/…/BuildSuccessful.java` — **unchanged**, seven components as it stands.
- `service/…/bus/EventWireReflection.java` — **unchanged**. `EventEnvelope` and `EventFrame` are
  already registered targets and `@RegisterForReflection` covers a class's members, so a new record
  component needs no new entry. Worth stating because it is the natural worry in this repo, and
  `EventWireReflectionTest` should be re-read rather than assumed.
- `ci/control/RunAnnouncer.java`, `service/…/bus/BuildSuccessfulAnnouncer.java` — **not touched by
  this feature.** They are Agent G's two lines (Decision 7). A parameter that is structurally always
  null is noise, and G is the one adding the data.
- `CLAUDE.md` — "The eventsourcing module": the stamping rule, the precedence, and the outbox column
  as the thing a retry rests on.

**services/qits-events:**

- `events/entity/Event.java`, `events/src/main/resources/db/events/migration/V3__parent_id.sql`.
- `events/dto/EventDto.java`, `events/dto/EventCreated.java` (the frame; its javadoc's order clause
  retired), `events/mapper/EventMapper.java` (unchanged — MapStruct maps by name).
- `events/control/EventService.java` — `create` and `publish` take `parentId`; the comparison gains
  it; the validation; `announce` carries it.
- `events/control/Validations.java` — a `requireUuidIfPresent`, or a conditional call; whichever
  reads better beside the existing three.
- `events/persistence/EventRepository.java` — `listChildrenOf(String parentId)`, newest-first.
- `service/api/EventController.java` — `PublishEventRequest` and `CreateEventRequest` gain the
  field; `list()` gains `@QueryParam("parentId")`.
- `README.md` (the envelope block, the frame's field list, the comparison sentence, the routes),
  `CLAUDE.md` ("The bus" — the comparison is now four fields).
- No `ignored-path-prefixes` change, no new route literal, no new config key, no new datasource, no
  new deployment variable. The rollout is an ordinary redeploy of two services.

**Superproject:**

- `eventsourcing-plan.md` — a pointer at its frozen-contract section saying the envelope gained
  `parentId` here. A shipped plan that silently disagrees with the wire is worse than a plan with a
  forward reference.
- `ci-event-triggers-plan.md` — Agent G's bullet gains the stamping (Decision 7).

## Tests

**eventsourcing module:**

1. `CausationScopeTest` — set and read; nested scopes (inner wins, outer intact afterwards);
   `with(null, …)` clears inside and restores outside; a body that throws still restores; **the
   thread-local is `remove()`d rather than set to null when there was no previous value**, asserted
   by a second task on the same thread observing `current() == null`; a freshly started thread does
   not inherit.
2. Bus precedence — `publish(e)` inside a scope stamps the scope's id; `publish(e, X)` inside a
   scope stamps `X`; `publish(e)` outside any scope stamps null; `publish(e, null)` inside a scope
   stamps the scope's id (settled decision 1). Asserted on `StubEventsServer`'s recorded
   PUT bodies.
3. Dispatcher — a `TestEvents` listener that publishes during `onEvent` produces a second PUT whose
   `parentId` is the arriving frame's `id`; two listeners on one frame see the same context; the
   context is clear after `dispatch` returns; a listener that throws does not leak it to the next
   frame; a frame whose `id` is not a UUID still dispatches, with a null context.
4. Outbox — a publish that fails inline writes `parent_id`; **the sweeper's retry PUT carries the
   same `parentId`** (the regression Decision 4 exists to prevent); a `FAILED` row keeps it.
5. Wire shape — `parentId` is an explicit `null` in the envelope when absent and the string when
   set; **the canonical payload of an event published under a parent is byte-identical to the same
   event published without one** (the guard equivalent to the mix-in lesson: causation must not
   leak into the compared bytes).
6. `EventsourcingDisabledTest` — unchanged; a disabled bus still dials nothing and stamps nothing.

**qits-events:**

7. `EventPublishApiTest` — 201 with a `parentId`; 200 on the identical replay; **400 when the same
   id is re-PUT with a different parent, in both directions (null → set and set → null)**; 400 on a
   non-UUID parent; 400 on `parentId == id`; 201 with the field absent entirely (the old-publisher
   compatibility clause).
8. `EventStreamSocketTest` — the pushed frame carries `parentId`, set and null.
9. `EventApiTest` — `?parentId=` returns that parent's children newest-first; an unknown parent
   returns an empty list rather than a 404; no parameter is unchanged.
10. `EventServiceTest` / `EventPublishTest` — a dangling parent is stored as it stands.
11. `PackagedSurfaceIT` — the existing PUT probe grows the field, and the read-back asserts it. Not
    a new test: one field on an assertion that already runs against the artifact, in the one place
    that can see what a `@QuarkusTest` structurally cannot.

**Later, in the trigger engine's suite (Agent G):** an event-triggered run's `BuildSuccessful`
carries the triggering event's id as its `parentId`, and a post-receive run's carries null.

## Workstreams (one Opus 5 agent each)

Letters continue the platform's running sequence: A–D were the bus, E is the native-image reflection
fix in flight, F–H are ci-event-triggers-plan.md's and are **not** started.

**Contract note for all agents: the delta in Decision 3 is frozen.** An agent that believes it is
wrong reports back; it does not adjust its side unilaterally.

### Agent I — qits-events learns about parents (repo: services/qits-events)

`V3__parent_id.sql` with the index; the field on entity, `EventDto` and `EventCreated`; the PUT
comparison and the two validations; `listChildrenOf` and the `?parentId=` query parameter; the POST
path accepts an optional parent too, validated identically, so the two write paths cannot diverge
about what an event is. Tests 7–11. README and CLAUDE.md. `./mvnw verify` green — note that needs
the webui submodule initialised — push both remotes, pipeline redeploys, verify live.

### Agent J — the eventsourcing module learns to stamp (repo: services/qits-ci)

`CausationScope`; the `publish` overload and the precedence rule; the envelope and frame components;
the dispatcher's scope; the outbox column, `V2__parent_id.sql` and the sweeper's re-send. Tests 1–6.
**The extraction rule holds** — no `eu.wohlben.qits.ci.*` import, `ExtractionRuleTest` proves it.
`ci-events/` and `service/…/bus/` are untouched; if a diff there becomes necessary, that is a signal
to report back rather than a small extra commit. `./mvnw verify` green, push both remotes, pipeline
redeploys qits-ci.

I and J share nothing but the frozen contract and may run in parallel.

### Agent K — the live proof and the plan updates (superproject + platform, after I & J)

- **Rollout order is qits-events first, and it is not arbitrary**: Quarkus does not fail on unknown
  JSON properties, so a qits-ci that stamps against a qits-events that has not shipped I would have
  its parents silently dropped — every chain of that window recorded as roots, unbackfillable. The
  other order is safe: an events service that knows the field and a publisher that never sends it is
  exactly the compatibility clause in Decision 3.
- **The proof, by hand and cheap**: `PUT` two events through the real API, the second naming the
  first; `GET /events/api/events?parentId=<first>` returns exactly the second; a websocket subscribed
  to both names sees the child frame carrying `parentId`; re-`PUT` the child with a different parent
  and assert 400. No CI run needed — the first *automatic* edge on this platform is drawn by the
  trigger engine, and that proof belongs to its Agent H.
- **The plan edits**: the pointer in `eventsourcing-plan.md`, and the stamping in Agent G's bullet
  in `ci-event-triggers-plan.md`.

**Sequencing across features: I ∥ J → K → F → G → H.** The trigger engine rides a bus that already
stamps, and G's two lines cost it nothing.

## Out of scope, named so nobody drifts into it

- The visualization itself — the chain view in qits-spa-events, and any run-provenance surfacing in
  qits-spa-ci.
- Automatic context propagation for async/reactive pipelines (Decision 6), and any executor wrapper.
- Cycle and depth guards, in the bus or in the server. `parentId` makes them *possible*; the DAG
  feature ci-event-triggers-plan.md names is where they belong.
- Multiple parents, causation *types* ("caused by" vs "correlated with"), and a separate correlation
  or trace id. One nullable edge is what the release train needs; a second relationship kind is a
  different feature with its own read model. (OpenTelemetry trace context is the obvious neighbour
  and is deliberately not conflated with this: a trace is about one request's latency, a causation
  chain is about days of history.)
- Backfilling causation onto events already in the log. There is nothing to derive it from.
- Existence enforcement, retention, and any FK on `parent_id` (Decision 4).

## Decisions settled with the user (2026-07-31)

**1 — `publish(event, null)` means "unspecified", falling back to the ambient context.**
`publish(e)` is exactly `publish(e, null)` and there is one implementation. The deliberate
detach is spelled `CausationScope.with(null, …)` — null means "unspecified" at the publish
site and "cleared" at the scope site, and that asymmetry is accepted as the price of a single
call shape.

**2 — `CausationScope` is public API from day one.** The library already instructs listeners
to hand slow work to their own executor, and that instruction would otherwise drop causation
with nothing to say so; a public scope plus the documented `current()`/`with()` pattern is
the answer to advice the library gives today, even though the first in-tree user (the CI
announcer) takes the explicit overload instead.
