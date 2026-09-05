# Split the causation trio out of the eventstream jar

Status: PLANNED (written 2026-08-10, night of the causation-rows rollout). Do after the
rebootstrap settles.

## The problem, measured

The causation persistence trio — `CausedRow`, `CausationStamp`, `@Uncaused` — lives in the
qits-eventstream jar. Three jakarta-persistence-shaped types with no bus in them, but adopting
them means adopting the whole jar, and the jar carries the platform's bus client: hibernate-panache,
jdbc-postgresql, flyway, scheduler, and `quarkus-websockets-next` — which ships an HTTP **server**
even though the jar only uses its client.

The jar's own pom argued this was fine: "this jar is only ever consumed by a service that is
already serving HTTP." The causation rows broke that assumption the same night they landed.
Entity modules are deliberately web-free (`qits-ci-domain`, `qits-workspaces-domain`,
`qits-deployments-deployments`/`-environments`, `qits-projects-domain`/`-epics`), and each one
that adopted the trio paid the same three taxes in its test suite:

1. **An HTTP server it never asked for.** Every `@QuarkusTest` in the module now binds a port.
   Measured immediately: the qits-workspaces domain suite hit the known 8081 collision (the npm
   registry's port) and needed the `quarkus.http.test-port=0` magic that the module's own notes
   said "costs nothing today — the day a dependency drags a server in" would be the failure.
   That day was 2026-08-10.
2. **The eventstream persistence unit boots in the module's tests** whether the bus is dark or
   not, so every entity module's `EmbeddedPgConfigSource` grew an eventstream database triple.
3. **The darkness keys** (`qits.eventstream.enabled=false`, `catchup-at-startup=false`,
   `quarkus.flyway.eventstream.clean-at-start=true`) got copied into every entity module's test
   properties.

That is per-module boilerplate with a landmine each (the consumer-contract rules the eventstream
README states), multiplied by every entity module the platform ever grows.

## Target shape

Restructure the qits-eventstream **repo** into a two-module reactor:

| Module | Artifact | Contents | Dependencies |
| --- | --- | --- | --- |
| `causation/` | `eu.wohlben.qits:qits-causation` | `CausationScope`, `CausedRow`, `CausationStamp`, `Uncaused`, `CausationHeader`, `CausationClientFilter`, `CausationServerFilter` | `jakarta.persistence-api` + `jakarta.ws.rs-api` (+ `jakarta.annotation-api`), API jars only — **no Quarkus extension, no server, no persistence unit, no scheduler** |
| `eventstream/` | `eu.wohlben.qits:qits-eventstream` | everything else (bus, outbox, dispatcher, durable seam) | as today, **plus `qits-causation`** — a bus consumer still sees one dependency and the whole surface |

- Entity modules then depend on `qits-causation` alone: no server, no PU, no darkness keys, no
  embedded-postgres second database. All three taxes disappear.
- The REST filters move too (they need only `CausationScope` + the ws.rs API), so a REST service
  that is not on the bus can still propagate the header.
- `QitsEventBus` keeps reading `CausationScope` — it arrives transitively.

## Decisions (recommended, argue here before starting)

1. **Same repo, not a new one.** A `causation/` module beside `eventstream/` in the existing
   repo keeps one clone-alone gate, one release, one CI recipe, and versions in lockstep by
   construction. The repo's "ONE MODULE AT THE ROOT" comment falls — its rationale was "no
   deployable here", which a second library module does not disturb. The integrations repo is
   the precedent for a category reactor.
2. **Package names DO NOT change.** Everything stays `eu.wohlben.qits.eventstream`. Two reasons:
   qits-arch-rules matches the trio **by fully-qualified name** (its constants, its fixture
   mirror, and every consumer's green build hang on those strings), and consumers then need no
   import churn — the split is a pom-level move. A same-package split across two jars is legal
   on the classpath; nothing here uses JPMS. The eventstream repo's extraction-rule test
   (single-package rule) already permits it.
3. **One version property in consumers.** Both artifacts release from one reactor with one
   CalVer stamp, so consumers reference `${qits.eventstream.version}` for both deps. The
   existing `ci-event-upstream-eventstream.yml` bump recipes then need **no change**.
4. **Release recipe follows the integrations pattern from 2026-08-10**: `artifacts:` lists both
   coordinates, and the publish-if-absent probe checks **both** poms (skip only when every
   module of the reactor is published) — see qits-integrations-quarkus `a0829fa` for the shape
   and the reasoning comment.

## Phase 2 (recommended, separable): de-server the bus client itself

After the split, the remaining `test-port=0` magic belongs only to modules that genuinely
consume the bus — because `quarkus-websockets-next` still brings its server along for its
client. The jar's pom already documents the alternative it rejected: vert.x-core's own
`WebSocketClient`, which qits-ci-daemon uses precisely to avoid linking an HTTP server. Port
`EventStreamSubscriber` to it, drop `quarkus-websockets-next`, and the eventstream jar stops
carrying a server at all.

- Cost: the connector's reconnect ergonomics are hand-rolled again; the redial/backoff suite
  (`EventStreamSubscriberTest`) is the safety net — the SHAPE of reconnect is what it pins.
- Payoff: every bus consumer's suite loses the incidental server; the port-0 keys become
  removable platform-wide except where a repo really serves HTTP in tests.
- Do it second: the trio split pays most of the debt and is pure pom motion; this one touches
  live reconnect code.

## Work packages

1. **qits-eventstream repo**: restructure into parent + `causation/` + `eventstream/`
   (`git mv`, keep package paths), move the trio + header + filters, wire the causation module's
   own small suite (scope/header/filter/stamp tests move with their classes; the stamping test
   keeps its embedded-postgres default-PU arrangement inside the `eventstream` module where the
   consumer stand-in lives — or moves to `causation` with its own zonky wiring, whichever keeps
   the clone-alone gate simplest). Update the release recipe per decision 4. Update README +
   AGENTS.md (the "one module" paragraph, the public-surface table, the consumer contract:
   "entity modules take qits-causation; deployables on the bus take qits-eventstream").
2. **Consumers, one commit each** (qits-ci, qits-workspaces, qits-deployments, qits-projects —
   whatever tonight's sweep landed): entity-module dep `qits-eventstream` → `qits-causation`;
   DELETE the eventstream triple from the module's `EmbeddedPgConfigSource`, the darkness keys
   from its test properties, and any `test-port=0` added only for this (check each module's
   comment — some predate this and guard real 8081 collisions of their own; qits-workspaces
   domain never committed the key, it was a `-D` flag, so nothing to remove there). Revert the
   AGENTS.md "the jar rides into this module's tests" paragraphs to name qits-causation and the
   taxes' removal.
3. **qits-arch-rules**: no rule change (names unchanged). One README sentence: the judged types
   ship in `qits-causation`; entity modules need only that.
4. **docs/project-setup-quinoa-angular.md**: the arch-rules step gains the one-liner "entity
   modules take `qits-causation` (compile) beside `qits-arch-rules` (test)".
5. **Cleanup inventory — the port-0/darkness magic added or leaned on for this feature**, to
   revisit after phases 1(+2):
   - `services/qits-ci/ci/src/test/resources/application.properties`: eventstream darkness keys
     + the `EmbeddedPgConfigSource` eventstream triple (added 2026-08-10, removable in phase 1);
     its `quarkus.http.test-port=0` predates the feature (real 8081 hazard note) — keep until
     phase 2, then re-evaluate.
   - `services/qits-workspaces/domain`: same triple + darkness keys (removable phase 1); the
     8081 collision was worked around with `-Dquarkus.http.test-port=0` at invocation, nothing
     committed.
   - `services/qits-projects` `domain/` and `epics/`: committed `quarkus.http.test-port=0` in
     both modules' test properties (feature-caused — removable phase 1, or phase 2 if kept as a
     general guard), plus `epics/src/test/resources/archunit.properties`
     (`archRule.failOnEmptyShould=false`) — removable as soon as the consumer pins a
     qits-arch-rules release carrying `f4bb41a` (`allowEmptyShould` on all three rules).
   - `services/qits-deployments`: NOTHING to remove — its entity modules run no `@QuarkusTest`,
     so the eventstream PU never boots there and no wiring was added; the service module's
     eventstream triple predates the feature and stays.
   - `libs/qits-eventstream/src/test/resources/application.properties` `test-port=0`: stays in
     phase 1 (its own suite still hosts the websocket client's server), removable in phase 2.

## Rollout order

1. Release the restructured qits-eventstream repo (both artifacts, one version). The registry
   then has `qits-causation`; nothing consumes it yet — additive, safe.
2. The train auto-bumps bus consumers to the new eventstream version; their builds stay green
   because the eventstream artifact still (transitively) carries the trio.
3. Land the consumer commits (work package 2) repo by repo, a release request each — each is
   the dep swap plus the test-wiring deletion, provable by the module suite going green
   *without* the eventstream database.
4. Phase 2 whenever wanted; it is invisible to consumers except as deleted test keys.

## Out of scope

- Services not on the bus (idp, dns, artifacts): unchanged decision — they adopt causation the
  day they adopt the bus, and after this split the entity-module half of that costs two API
  jars instead of a server and a database.
- qits-events: still the server side; still no client dependency.
