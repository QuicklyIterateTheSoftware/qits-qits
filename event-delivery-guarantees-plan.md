# Event delivery guarantees — durable consumption in the lib

Settled direction (user, 2026-08-10): the bus is the delivery mechanism and the
eventstream LIB owns durability on BOTH sides. Publishers already have the
outbox; consumers get the mirror image — tracking of handled events — inside
qits-eventstream, never reimplemented per service. Every consumer of events
uses the lib. Consumers must not be forced to store all events: only the ones
their filtering selects.

## Why (measured, 2026-08-10 rebootstrap campaign)

- The stream half of the lib has no replay: "the events missed while
  disconnected are not replayed" (RetrySchedule javadoc). A consumer that is
  down or mid-cutover when a frame arrives has lost it forever.
- qits-events already serves the cure's other half: a queryable, pageable log
  (`GET /events/api/events?name=&since=&cursor=&limit=`) with a composite
  `(occurredAt,id)` cursor that is tie-safe for release-fork siblings.
- The direct point-to-point announcements that stand in for the bus today
  (artifacts→ci post-receive, ci→deployer build-succeeded) each lost real
  events to cutover windows — both hops now carry bounded in-memory retries,
  which hardens the transitional door but is not the target model.
  qits-deployments' own `BuildAnnouncements` javadoc records the bus as wave 3.

## The mechanism (in qits-eventstream)

A durable listener variant beside today's `QitsEventListener` /
`QitsRawEventListener`. A durable listener declares:

- `consumerId()` — a stable string, part of the storage contract (survives
  class renames; documented as such).
- `signatures()` — the event names it subscribes to (unchanged).
- `selects(event)` — the sub-name predicate (default: everything it is
  subscribed to).

The lib provides, on the consumer's eventstream datasource (the one the outbox
already claims; consume-only services adopt that datasource the same way
publishers do):

- `consumed_event (listener_id, event_id, handled_at)`, PK on
  `(listener_id, event_id)`.
- `consumer_watermark (listener_id, occurred_at, event_id)` — the composite
  cursor, mirroring qits-events' own.

**One funnel, both channels.** A live frame and a catch-up row take the same
path: if `selects(event)` → one transaction { insert the consumed row
(duplicate key → another channel already handled it → skip) ; invoke the
handler }. Exactly-once EFFECT per event id per listener, whatever mix of
stream delivery, catch-up, and publisher retry produced the arrivals.

**Selective storage.** Only handled events get a consumed row — an event the
predicate skips stores nothing. What makes that safe is the watermark: catch-up
re-evaluates only events ABOVE it, so a later change to the predicate (an
environment starts listening to a branch, a repo adds a trigger file) cannot
resurrect ancient history. Once the watermark passes an event, it is settled
forever. Consumed rows below the watermark are pruned — the table covers only
the stream/catch-up overlap window and never becomes a second copy of the log.

**Catch-up sweep.** Scheduled, plus once at startup (that is the cutover cure):
per listener, page the log ascending from the watermark, run each event through
the funnel, advance the watermark only when a page is fully processed. Live
frames never advance the watermark; they are ahead of it, and the consumed
rows dedupe when the sweep catches up.

**Ordering is per-handler, documented, non-optional.** Catch-up delivers late;
across a restart a handler can see an event older than one it already handled.
A handler whose effect is last-writer-wins must collapse (the deployer: deploy
only if the event is still the newest green for that (repo, branch)).

## qits-events API addition

The log pages newest-first. Catch-up needs ascending traversal from a cursor:
an `order=asc` (or `after=<cursor>`) mode on the existing list endpoint, same
composite-cursor predicate flipped. Small, and the one server-side change.

## Publisher-side hole (same workstream)

The outbox gives up after `max-attempts` (5 ≈ 5½ min) — measured live when the
seed ci dialled a dead alias: terminal rows, events that never reached the bus,
holes no consumer bookkeeping can recover. Split the failure classes:
bus-unreachable (connect failure/timeout) must NOT consume the attempt budget —
retry indefinitely at the capped backoff; the bounded budget is for refusals
(a response arrived and said no). "The bus is the record" is only true if
reaching it is never abandoned.

## Consumers and their scopes (inventory, 2026-08-10)

| Consumer | signatures | selects |
|---|---|---|
| qits-deployments (wave 3, NEW) | BuildSuccessful | an environment/the platform listens to the branch |
| qits-ci BuildSuccessfulListener | BuildSuccessful | release-train membership |
| qits-ci DaemonReleaseListener | SoftwareRelease | the daemon's own release |
| qits-ci CiEventTriggerListener | `*` (config-driven) | repos' ci-event-*.yml selections |

## Work packages, in order

1. **qits-events**: ascending list mode. Tie-safe both directions; tests mirror
   the cursor suite.
2. **qits-eventstream**: (a) outbox give-up split (unreachable ≠ refused);
   (b) the durable-consumer mechanism — migration in its own lineage, funnel,
   watermark, catch-up sweeper against the query API, pruning, config keys
   (sweep cadence, prune horizon). The lib rides to consumers as a normal
   release + dependency bump.
3. **qits-ci**: move its three listeners onto the durable variant (each gains
   consumerId + selects; the eventstream datasource already exists there).
4. **qits-deployments**: wave 3 exactly as its `BuildAnnouncements` seam
   records — the lib, an eventstream datasource (deployments.yml resource),
   one durable BuildSuccessful subscriber calling `announce()` with a
   newest-green tip check. The HTTP intake stays as the manual/bootstrap door.
5. **qits-cli-bootstrap**: run-args for the new datasource + QITS_EVENTS_URL
   where missing.
6. **Retire** ci's direct PdBuildNotifier POST once the subscriber is proven
   live. The in-memory retries shipped 2026-08-10 stay until then.

## Open fork: the bus and the bootstrap

qits-events deploys at phase 46; six deployables announce before it exists.
Either the direct doors remain the bootstrap-window transport (status quo,
hardened), or qits-events joins the CORE seed stack — then even bootstrap rides
the bus, and post-receive can become a bus event too (artifacts adopts the lib
as a publisher; ci consumes it durably). Deliberately NOT decided here: seeding
one more service is cheap, but post-receive-on-the-bus changes the build
trigger path's latency and failure shape and deserves its own look.
