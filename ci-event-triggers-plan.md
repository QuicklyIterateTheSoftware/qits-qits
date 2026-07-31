# CI event triggers: pipelines that fire on domain events

The follow-up to eventsourcing-plan.md. qits-ci today has exactly one trigger: the git host's
post-receive notification, which runs `.config/qits/ci-post-receive.yml` for the pushed commit.
This feature adds a second trigger type: a repo can commit pipelines that fire when a **domain
event** (the bus built in the previous feature) matches a selection the repo declares. The
motivating shape is the release train: qits-spa-ui-components releases (a future ReleaseEvent —
out of scope here) → every consuming SPA's event pipeline fires and commits the version bump →
each SPA's own release fires the event pipelines of the Quarkus services embedding it → those
release themselves. Each hop is one repo declaring, in its own tree, which upstream events it
cares about.

Status: SETTLED 2026-07-31 — the selection DSL (YAML matcher document, list-of-maps groups,
`exact`/`prefix`/`exists`), and the loop question (deliberately **no guard** in this feature;
cycle/self-reference detection is a separate future feature operating on a meta-level DAG of
triggers, with its own UX). Decisions recorded inline below.

## What exists (the seams)

- **Post-receive intake**: `CiRunService.onPostReceive(repoId, branch, oldSha, newSha)` →
  single-threaded worker → `GitConfigFetcher.read(repoId, branch, sha)` fetches the branch ref
  into a per-repo bare cache under `<data-dir>/repos/` and reads the blob
  `.config/qits/ci-post-receive.yml` at the sha (`CiConfigParser.CONFIG_PATH`, today a single
  hardwired path). Runs are recorded only when they say something true about a commit.
- **The bus client** (qits-eventsourcing module, same repo): `EventStreamSubscriber` dials
  `/events/stream`, subscribes the signature set derived from registered
  `QitsEventListener<E>` beans — **typed listeners only, set fixed at startup**. Delivery is
  live-stream, at-most-once; catch-up/replay is a future feature.
- Events: envelope `{id, name, occurredAt, payload, description}`, payload = canonical JSON.

## The trigger file

- **Path**: `.config/qits/ci-event-*.yml` — the `*` is freely chosen and completely ignored
  (it names the trigger for humans; `ci-event-ui-components-released.yml`). A repo may have
  any number; each is an independent trigger + pipeline. `ci-post-receive.yml` is untouched.
- **Read from the head of `main`** (the platform's one tracked branch — every submodule
  follows it; the post-receive path gets its branch from the push, an event has no push, so
  the convention supplies it). The run records the head sha it built.
- **Schema**: the existing pipeline schema (steps, images, timeouts — everything
  `CiConfigParser` already accepts) plus two new top-level keys:

```yaml
# .config/qits/ci-event-ui-components-released.yml
event: BuildSuccessful          # the event NAME (signature) this trigger listens for
when:                           # the selection — see the DSL section
  - repoId: { exact: qits-spa-ui-components }
    branch: { exact: main }
steps:
  - image: qits/build-images/node-base:latest
    script: |
      ...the version bump, commit, push...
```

A `ci-post-receive.yml` containing `event:`/`when:` is a parse error, and vice versa a
`ci-event-*.yml` missing `event:` is one too — the two trigger types never blur.

## The selection DSL — decided: YAML matcher document

**Bash eval is rejected, with reasons rather than taste.** The evaluation input is an event
payload authored by *another service* (and, transitively, by whatever fed that service), and
it reaches qits-ci through an unauthenticated intake on qits-net. Interpolating that into a
shell — even "just for a true/false" — is remote-influence over `sh -c` on the CI host, a
class of surface the platform has carefully avoided (see GitConfigFetcher's javadoc on why
identifiers are validated before they reach an argv). It is also unreadable at review time and
untestable without a shell. A data-only matcher document has none of these problems. Bash
stays what it already is here: the *step* language, running in a step container after the
trigger has decided.

**The recommended DSL** (what the example above uses):

- `when:` is a **list of match groups** — groups are OR'd.
- A group is a **map of path → matcher** — entries are AND'd.
- So `when` reads "fire if any group fully matches", which covers "x AND y" (one group, two
  entries) and "x OR y" (two groups) without a second nesting form. This is the flattened,
  YAML-idiomatic spelling of the proposed `values: {...}[][]` — a map's keys already AND, so
  the inner list collapses into the map. The one thing the map form cannot express is two
  matchers on the *same* path in one group (`prefix: a` AND `suffix: b` on one field);
  allowing a matcher-*list* as the map value (`repoId: [{prefix: qits-}, {suffix: -spa}]`,
  AND'd) restores that with no structural change. **Decided: map-based groups**, with the
  matcher-list-per-path form included.
- **Paths are dot-paths into the payload JSON** (`repoId`, `repository.url`) — navigation
  only: no wildcards, no filters, no indexing. Full JSONPath is a dependency and a footgun;
  every payload this platform emits is a flat-to-shallow canonical JSON object, and a dot-path
  over it is one small loop. `event:` matches the envelope's `name` exactly and is not part
  of `when`.
- **Matcher vocabulary — decided**: `exact`, `prefix`, `exists` (true/false), nothing else in
  v1. Values compare as strings (the canonical payload is JSON — numbers/booleans compare by
  their JSON literal). `regex` is deliberately absent until a real trigger needs it;
  `exact`+`prefix` cover the release train, and regex invites the complexity the DSL exists
  to avoid.
- Unknown matcher keys, unknown top-level keys, non-string path values: parse errors, loudly
  — a trigger that cannot be parsed must not silently never fire (log at WARN naming repo and
  file; a parse failure of one file does not disable the repo's other trigger files).

## The trigger engine (in the `ci` module)

Flow, on every inbound event frame:

1. **Subscription**: qits-ci subscribes to `["*"]` for trigger evaluation. The `event:` names
   across all repos' files are unknowable at startup and change with pushes, so filtering
   moves from the socket subscription to the engine. This needs the eventsourcing module to
   grow a **raw listener** seam — `QitsRawEventListener { Set<String> signatures(); /* or "*" */
   void onFrame(EventFrame frame); }` — a small, extraction-clean addition; the existing typed
   `QitsEventListener` path is untouched (the `BuildSuccessfulListener` from the previous
   feature keeps working, and the subscribe frame is the union of both sets, `["*"]` absorbing
   everything).
2. **Candidate repos**: the git host owns the repo list. First choice: enumerate via
   qits-artifacts' API if it exposes one (**discovery task for the implementing agent**: check
   qits-artifacts' resources; qits-projects' RepositoryDiscoveryService may already consume
   such a listing). Fallback if none exists: the repos qits-ci already knows — the union of
   its recorded runs' repoIds and its bare caches — accepting that a repo never pushed since
   this feature ships cannot event-trigger until its first push (each candidate source is one
   method; swapping later is cheap).
3. **Evaluation**, per candidate repo: resolve `main`'s head → list `.config/qits/ci-event-*.yml`
   blobs at that sha (a `git ls-tree` of `.config/qits/` in the existing bare cache — one new
   verb on `GitConfigFetcher`/`CiConfigSource`) → parse → `event` name equals the frame's
   `name` → evaluate `when` against the parsed payload → on match, enqueue.
4. **Run creation**: the standard run machinery (same worker, same recording semantics,
   daemon, step containers) with **trigger provenance** on `CiRun`: `triggerType`
   (`POST_RECEIVE` | `EVENT`, existing rows backfilled `POST_RECEIVE`), `triggerEventId`,
   `triggerEventName`, `configPath` (which trigger file — post-receive rows get the constant).
   Flyway migration in ci's lineage.
5. **The payload reaches the steps as environment**: `QITS_EVENT_ID`, `QITS_EVENT_NAME`,
   `QITS_EVENT_OCCURRED_AT`, `QITS_EVENT_PAYLOAD` (the canonical JSON, verbatim — steps that
   want a field use `jq`, which the step images carry). No per-field flattening: env names
   from payload paths invite collision and quoting bugs, and `jq` is already the platform's
   answer inside steps.

### Exactly one run per (event, trigger) — the 1-relationship

However many groups of a `when` match, evaluation short-circuits at the first — matching is
boolean, not multiplicative. The guarantee that survives redelivery and races is a **database
unique constraint on `(triggerEventId, repoId, configPath)`**: a second arrival of the same
event (bus replays are legal — the PUT is idempotent and a future catch-up feature will
redeliver) hits the constraint and is dropped as already-triggered, not re-run. One event, one
trigger file, at most one run — ever. (Two *different* trigger files in one repo matching the
same event are two runs by design: they are two declared pipelines.)

### Loops — decided: no guard in this feature

The release train is a chain of events causing builds causing events; a **cycle** is the same
thing pointed backwards, and nothing structural prevents one: a repo whose event trigger
matches an event its own green build publishes re-triggers itself forever (each hop is a *new*
eventId, so the dedupe constraint never engages — it kills replays, not descendants).

**Decision (2026-07-31): this feature ships with no inline guard.** Cycle and
self-reference detection is a *separate future feature* — the trigger declarations across
repos form a dependency graph, and the right treatment is at that meta level (build the DAG,
detect cycles there, with its own UX for surfacing and resolving them), not an ad-hoc
per-event check buried in the engine. Until that lands, the footgun is documented where a
trigger author will read it (the config-format docs Agent G writes): a `when` that matches an
event the same repo's build publishes is an unbounded build loop, and review is the only
guard. Engine-side, nothing is built that the DAG feature would have to undo; the provenance
columns (`triggerEventId`, `triggerEventName`) are exactly the trail it will need.

## Out of scope, named

- ReleaseEvent itself, the version-bump tooling inside the train's steps, and any
  publishing of libraries — this feature is the trigger, not the train.
- Catch-up/replay (an event fired while qits-ci is down is missed — the at-most-once
  limitation inherited from the bus, fixed bus-side by the future replay feature; the dedupe
  constraint here is already replay-proof for that day).
- Trigger conditions over anything but the event (no cron, no "and file X changed").
- Cycle/self-reference detection — the future meta-level feature: build the DAG of trigger
  declarations across repos, detect cycles there, with its own UX. This feature only records
  the provenance trail that DAG will consume.
- UI for event-triggered runs beyond what the existing run list shows (provenance columns are
  recorded; surfacing them in qits-spa-ci is a later, small follow-up).

## Workstreams (Opus 5 agents, after the ⚖ decisions land in this doc)

- **Agent F — the raw listener** (repo services/qits-ci, eventsourcing module): the
  `QitsRawEventListener` seam, subscribe-frame union (`["*"]` absorbing), dispatch order
  (raw listeners see every frame; typed dispatch unchanged), tests incl. coexistence with
  typed listeners. Extraction rule holds (no ci imports).
- **Agent G — the trigger engine** (same repo, `ci` + `service` modules, after F): the
  `ci-event-*.yml` parser (shared schema base with `CiConfigParser`, the two-way
  parse-error rule), the matcher DSL evaluator (pure, exhaustively unit-tested: groups,
  AND/OR, dot-paths, each matcher, malformed docs), `GitConfigFetcher` tree-listing verb,
  candidate-repo source (with the discovery task), provenance migration + entity/DTO,
  unique-constraint dedupe, env injection, engine wiring behind the raw listener,
  config-format docs including the loop footgun, @QuarkusTest suite (event in → run recorded
  with provenance; dedupe on redelivery; parse-failure isolation). Push both remotes,
  pipeline redeploys qits-ci
  (the run-args need nothing new — no new datasource, no new URL).
- **Agent H — end-to-end on the live platform** (after G): commit a real
  `ci-event-*.yml` into a suitable small repo (qits-spa-workspaces is the established guinea
  pig) triggering on `BuildSuccessful` of another repo; cause that upstream green build
  (post-receive replay, the proven trigger); assert: exactly one event-triggered run, correct
  provenance, `QITS_EVENT_*` visible in the step log, and dedupe on a hand-replayed frame
  (a second delivery of the same eventId records no second run). Leave the trigger
  file in place or revert it — decide by whether it is a plausible permanent train hop, and
  say which.

Sequencing: F → G → H, strictly (one repo, and each builds on the previous). The bus feature
(eventsourcing-plan.md) must be fully closed first — G's engine rides the same subscriber
whose native-image serialization fix is currently in flight.
