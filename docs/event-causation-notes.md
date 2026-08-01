# Event causation: three arguments rescued from the retired plan

The event-causation feature shipped 2026-07-31 and its plan document was verified fully
implemented and retired on 2026-08-01. The contract lives in shipped code and repo docs
(`EventEnvelope`/`CausationScope` javadocs, qits-events README, the eventstream repos' AGENTS.md).
These three passages are the arguments that lived nowhere else — kept because each answers a
question a future design pass will ask again.

## Is a bare ThreadLocal enough for CausationScope? (the audit that says yes)

Every consume → publish → deliver path is one thread end to end, so a plain `ThreadLocal` with no
context propagation is a complete answer. The audit:

| path | thread | publishes? |
| --- | --- | --- |
| `EventStreamSubscriber.onTextMessage` → `EventDispatcher.dispatch` → `onEvent` | websockets-next worker, `ExecutionModel.BLOCKING`, one frame at a time | yes — this is the case the ThreadLocal serves |
| `QitsEventBus.publish` → `EventsPublisher.put` (`HttpClient.send`, synchronous) → `Outbox.enqueue` (`QuarkusTransaction.requiringNew`, same thread) | the caller's | — |
| `OutboxSweeper.tick` | `@Scheduled`, scheduler thread | re-sends a **stored** envelope; stamps nothing |
| `EventStreamSubscriber.redial` (`vertx.setTimer`) | event loop | dials only |
| qits-events `EventStreamSubscriptions.onEventCreated` (`AFTER_SUCCESS`) | the transaction-completing thread | fans out; publishes nothing |
| qits-ci `CiRunService`'s `ci-run-worker` | its own single thread | **yes** — the one real hop |

If an async hop ever appears on a publish path, the extension shape is `wrap(Runnable)` /
`wrap(Executor)` on `CausationScope` — not inheritance, not context propagation frameworks.

## Do not conflate causation with OpenTelemetry trace context

A trace is about one request's latency; a causation chain is about days of history. Multiple
parents, causation *types* ("caused by" vs "correlated with"), and a separate correlation or trace
id are a different feature with its own read model — one nullable `parentId` edge is what the
release train needs. Unifying causation with OTel trace context is the obvious-looking move this
note exists to stop.

## Two graphs, and they are duals

The trigger DAG feature (future) is a graph of *declarations*: which repo's trigger file listens
for which event — static, knowable without running anything, so a cycle can be found before it
runs. `parentId` is the graph of *occurrences*: what actually caused what, knowable only after the
fact — and therefore the only way to see a cycle that a conditional `when` produces only
sometimes. A depth query over `parent_id` is the runtime detector the static analysis structurally
cannot have, and it has existed since the feature shipped.
