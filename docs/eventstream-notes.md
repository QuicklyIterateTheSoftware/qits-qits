# Eventstream: what survives the retired eventsourcing plan

The event-bus feature shipped 2026-07-31 and its plan (`eventsourcing-plan.md`) was verified
fully implemented and retired 2026-08-01. The contract lives in shipped code and repo docs
(qits-events-platform-service's controllers and AGENTS.md; qits-eventstream-javalib's README/AGENTS.md, which the
consumer repos vendor as submodule copies). These items had no other home.

## Parked follow-ups (deliberate, not forgotten)

- **Event schema versioning** — considered and deferred at design time. No mechanism exists;
  the event name is the whole signature. Reopen as its own design if a payload ever needs to
  change shape incompatibly.
- **Dead-letter UI for FAILED outbox rows** — a FAILED row today is visible only in the H2 file.
  A view could list them; it could never resend (the bus is at-most-once by design).

## The deferred architecture judgement whose trigger has now arrived

The design weighed SmallRye Reactive Messaging (`@Incoming`/`@Outgoing` channels with a
connector SPI — how the Kafka and AMQP extensions plug in) and judged it "the right shape for
the extracted library one day, but a connector implementation is real machinery (channel
lifecycle, config binding, ack strategies) — too much for an in-service first cut." The chosen
banal explicit API was deliberately extraction-friendly: "migrating to a reactive-messaging
connector later changes the internals of one module and no consumer's mental model."

The library HAS since been extracted (`components/qits-eventstream/qits-eventstream-javalib`). The trigger condition for
revisiting the connector shape has arrived; nothing forces it, but the option was priced and
recorded here so it is a decision, not a rediscovery.
