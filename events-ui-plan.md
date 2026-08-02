# The events UI

Status: **IMPLEMENTED AND BROWSER-PROVEN (2026-08-02).** Backend queries landed at `9099c91`; the
completed explorer was embedded at superproject commit `aef2df1`. This document is retained as the
design and decision record; where its pre-implementation measurements differ from the shipped
state, the completion record in `handoff.md` wins.

Everything in section 1 was read off the running platform or out of the repositories today. Where a
number appears, it was counted.

---

## 1. What was measured

### 1.1 The store, live

`GET http://localhost:8080/events/api/events`, once, unfiltered:

    137 events   62,478 bytes   7.7 ms   ≈ 456 bytes per event

The whole history in one response. `?limit=10` returned the **same 62,478 bytes** — the parameter is
not merely unhonoured, it is unknown: `EventController.list` declares one query parameter and it is
`parentId` (`services/qits-events/service/src/main/java/eu/wohlben/qits/events/api/EventController.java:70`),
so JAX-RS drops anything else in silence. A client that passes `limit` gets the whole log and is
told nothing. That is worse than an absent parameter and it is the first thing section 5 fixes.

The vocabulary, counted:

    BuildSuccessful        127
    SCMRelease               4
    SoftwareRelease          3
    ProbeEvent               2
    SomethingElseEntirely    1

**There are no workspace events on this bus.** Three classes implement `QitsEvent` in production —
`BuildSuccessful` and `SoftwareRelease` in qits-ci
(`services/qits-ci/ci-events/src/main/java/eu/wohlben/qits/ci/events/BuildSuccessful.java:40`,
`SoftwareRelease.java:48`) and `SCMRelease` in qits-workspaces
(`services/qits-workspaces/workspaces-events/src/main/java/eu/wohlben/qits/workspaces/events/SCMRelease.java:55`).
The other two names are hand-recorded probes from the `POST` path. A screen designed around a
richer vocabulary would be designed around events that do not exist; a screen that **cannot survive
a fourth name appearing** would be designed around an accident. Section 4.3 handles both.

Payload keys are fixed per name and disjoint between names:

    BuildSuccessful   branch, commitSha, finishedAt, repoId, runId
    SCMRelease        branch, projectId, repository, version
    SoftwareRelease   packageName, packageType, repository, version

**The repository is under two different keys** — `repoId` for builds, `repository` for both release
events. There is no single payload key that means "which repository", which is the whole reason
section 5.4 and ⚖2 exist.

`description` is null on all 137 rows. Nothing on the platform writes it; the field is for the
hand-recorded path.

### 1.2 The graph, live

    events with a parent          17 of 137
    parents that have children    14
    fan-out                       11 parents × 1 child, 3 parents × 2 children
    maximum depth                 2
    largest connected component   5 nodes

The largest component is the npm release train, and it is the N+1 fork
`docs/scm-release-split-notes.md:17-18` describes, with one extra hop on each arm:

    SCMRelease       c5edabb5  qits-spa-ui-components 2026.801.85149   08:51:49
      SoftwareRelease 0bdbe98d qits-spa-ui-components 2026.801.85149   08:52:23.928965
        BuildSuccessful a3528932 qits-spa-home                          08:52:29
      BuildSuccessful  99c733d8 qits-spa-ui-components                  08:52:23.928965
        BuildSuccessful 049165ec qits-spa-workspaces                    08:52:25

**One parent id in the log resolves to nothing.** Event `59934bf8-ebc6-4760-bec2-cbe7cafd0371`
names `064158b0-837f-40aa-aa3c-d287d34f929e` as its cause and
`GET /events/api/events/064158b0-…` answers **404**. This is not damage: `V4__delete_old_software_release.sql:17-21`
deleted that row on purpose and says the surviving child "becomes a chain start, which is the
honest reading — its cause is gone". A dangling parent is data
(`events/src/main/resources/db/events/migration/V3__parent_id.sql:19-20`), so the chain view must
render one, today, on live data. There is a fixture for it and it is that id.

### 1.3 Timestamps tie, and the ties are the interesting rows

    distinct occurredAt values   133 of 137

Four collisions, and three of them are release forks:

    2026-08-01T10:56:11.390939Z   SoftwareRelease 8dfa021f + BuildSuccessful 65e066cc
    2026-08-01T08:57:31.091267Z   SoftwareRelease f99998d3 + BuildSuccessful 8ab8faf4
    2026-08-01T08:52:23.928965Z   SoftwareRelease 0bdbe98d + BuildSuccessful 99c733d8
    2026-07-31T13:40:00Z          SomethingElseEntirely + ProbeEvent (two hand-recorded probes)

The fork's siblings share the run's finish instant **by construction** — the handoff says so
(`handoff.md:81-83`) and the store agrees. Two consequences, both load-bearing:

- The list's order is not total. `EventRepository.listNewestFirst` sorts by `occurredAt` alone
  (`events/src/main/java/eu/wohlben/qits/events/persistence/EventRepository.java:16-18`), so H2 is
  free to return a tied pair in either order on two calls. Today nothing notices, because the whole
  log arrives in one response.
- **A `?before=<occurredAt>` cursor is wrong here.** `docs/ci-cd-explorer-notes.md:20-21` rejects
  `?offset=` for the right reason — an offset over a head-growing list re-shows rows — and names
  `before=<createdAt>` as the answer. On *this* table a scalar cursor splits a fork across a page
  boundary and either drops a sibling or repeats it, and the split lands precisely on the rows a
  release train is read for. The cursor has to be composite: `(occurredAt, id)`.

### 1.4 Growth

The window is 2026-07-31T13:21 to 2026-08-01T12:58 — 137 events in a shade under 24 hours, peaking
at 27 in one hour. At that rate:

    ≈ 50,000 events/year   ≈ 22 MB/year of response body   on one un-paged route

62 KB today is nothing. 22 MB in a year, fetched on every page load, is not — and the store is
append-only by design, so it never shrinks. Paging is not premature; it is a year late by the time
anyone notices.

### 1.5 The API surface, as it is

| | |
|---|---|
| `GET /events/api/events` | whole log, newest first by `occurredAt`. One parameter: `parentId` |
| `GET /events/api/events?parentId=<id>` | that event's children, newest first. Unknown parent → `{"events":[]}` and **200**, never 404 (`EventController.java:63`) — measured, including for a non-UUID |
| `GET /events/api/events/{id}` | one event; 404 if absent — measured |
| `POST /events/api/events` | hand-recorded write |
| `PUT /events/api/events/{id}` | the bus's idempotent publish |
| `DELETE /events/api/events/{id}` | removal |
| `GET /events/stream` | the websocket |

`EventDto` carries `id, name, occurredAt, payload, description, parentId, createdAt, updatedAt`
(`events/src/main/java/eu/wohlben/qits/events/dto/EventDto.java:17-25`).

**There is deliberately no chain route.** The README is explicit: no `/chain`, no depth parameter,
no root filter, no graph endpoint, "a chain-walking client bounds its own depth and remembers the
ids it has visited" (`services/qits-events/README.md:44-51`); the same instruction is on
`EventDto.java:14-15` and `EventController.java:63-67`. That is a standing constraint on this
design, not an omission to fix.

### 1.6 The stream

`@WebSocket(path = "/events/stream")`
(`service/src/main/java/eu/wohlben/qits/events/stream/EventStreamSocket.java:48`). It upgrades
through the gateway — probed today, `HTTP/1.1 101 Switching Protocols` on
`ws://localhost:8080/events/stream` with no credential.

The protocol, from `EventStreamSocket.java:35-46` and `EventStreamSubscriptions.java`:

- The client sends `{"subscribe": ["BuildSuccessful", …]}`. `["*"]` means everything.
- The set is **replaced** wholesale by each frame (`EventStreamSubscriptions.java:69-82`).
- **Until it sends one, a connection receives nothing** (`:46-49`). Opening the socket is not
  subscribing.
- The server then pushes `EventCreated` as text: **live only, no replay, no offset, no catch-up**.
- Only a *create* broadcasts. A 200 idempotent replay pushes nothing
  (`EventCreated.java:30-34`).
- A malformed frame costs the frame, not the connection.

The frame is `EventCreated` — `id, name, occurredAt, payload, description, parentId`
(`EventCreated.java:41-47`) — which is `EventDto` **minus `createdAt`/`updatedAt`**, absent on
purpose: "they are this database's bookkeeping, not facts about the thing that happened"
(`EventCreated.java:22-24`).

### 1.7 The client, as it is

`frontends/qits-spa-events` is the Angular 21 scaffold plus the platform chrome and nothing else:

    src/app/app.ts             the shell: `<router-outlet />`, OnPush
    src/app/app.routes.ts      `[{ path: '', component: QitsMainLayout, children: [] }]`  ← empty
    src/app/app.config.ts      provideBrowserGlobalErrorListeners + provideRouter — and no more
    src/index.html, styles.css, main.ts

138 lines of TypeScript across four files. Three facts an implementer needs:

- **`provideHttpClient` is not wired.** `app.config.ts:6-8` has two providers where every sibling
  has three; `qits-spa-artifacts/src/app/app.config.ts:19-24` is the reference, and `withFetch()`
  there is argued, not preferred.
- **The tooling is behind the siblings.** `package.json` has no eslint, no `angular-eslint`, no
  `lint` script and no `eslint.config.js`; `qits-spa-artifacts` has all four. `angular.json` has
  `build`, `serve`, `test` and no `lint` target. The README is still the unedited `ng new` text.
- Deployment is confirmed: `services/qits-events/.gitmodules` puts `qits-spa-events` at
  `service/src/main/webui`, `angular.json` sets `baseHref: "/events/"`, and
  `GET http://localhost:8080/events/` today serves `<base href="/events/">` with the platform
  stylesheet. Production budgets are `initial` 500 kB warn / 1 MB error.

`QITS_NAV_LINKS` already carries `{ label: 'Events', href: '/events/' }`
(`libs/qits-spa-ui-components/projects/qits-spa-ui-components/src/lib/main-layout.ts:26-34`).
Untouched by this plan.

### 1.8 The idiom this plan inherits and does not re-argue

Settled by qits-spa-ci, qits-spa-cd and qits-spa-artifacts:

- Standalone components, `ChangeDetectionStrategy.OnPush`, signals, no NgModules.
- `QITS_API_BASE` as an `InjectionToken` defaulting to `''`, so every call is a same-origin path
  (`qits-spa-ci/src/app/api/api-base.ts:16-19`).
- `Loadable<T>` = `idle | loading | ready | error`, with `idle` a state and not an absence
  (`qits-spa-ci/src/app/ui/loadable.ts:11-34`), rendered through `Async` and `Empty`.
- **Load budgets written in the component's own javadoc as `N + M`** and asserted in the spec —
  `qits-spa-artifacts/src/app/repositories/repositories-page.ts:17` is the model.
- **Every level that costs a request is URL state.** A path segment where the level is a page
  (`qits-spa-artifacts/src/app/app.routes.ts:23-27`), a query parameter where it is an expansion
  inside one screen (`qits-spa-ci/src/app/tree/tree-page.ts`).
- **Chevrons are drawn, not typed** — two borders rotated, no glyph, no font dependency
  (`qits-spa-artifacts/src/app/ui/page.css:5-7, 154-166`). This is the newest form and it closes
  the tofu-chevron item in `handoff.md:170`.
- **Do not poll where a stream exists.** `qits-spa-workspaces/src/app/api/workspace-events.ts:52-53`
  states it as a rule: "the explorer screens poll because they have no channel, and this page has
  one." This page has one.
- The stream is reached through an injected factory token so a spec can drive it by hand —
  `EVENT_SOURCE_FACTORY` at `qits-spa-workspaces/src/app/api/event-source.ts:34-37`.
- **Invalidate everything on every connect and reconnect** (`workspace-events.ts:41-46`): there is
  no replay protocol and the client must not invent one.
- Angular 21 only. Node 22.22.0 on this host is below Angular CLI 22's minimum.

---

## 2. What a person actually wants here

Three questions, and they are not three views of one thing.

**"What has been happening?"** The log. Reverse-chronological, filterable, and legible at a glance
without opening anything — which on this data means a row must render `repoId`/`repository` and a
version or a sha, not just a name and a time. 127 of 137 rows are `BuildSuccessful`; a log that
does not say *which repository* is a wall of one word.

**"What exactly is this event?"** One event, its payload, its timestamps. Small, and the easy part.

**"What did this cause, and what caused it?"** This is the reason the feature is worth building.
`?parentId=` is "the whole answer to 'what did this release produce'" (`handoff.md:81-83`), and
today the only way to ask it is curl. The `parentId` graph is also the platform's **only** runtime
cycle detector for trigger loops that a conditional `when` produces sometimes — the argument is in
`docs/event-causation-notes.md:45-52`, and it has had no reader since it shipped.

There is a fourth thing a person will want that this plan refuses: **the trigger DAG**. That is the
graph of *declarations*, dual to and not the same as the graph of *occurrences*
(`event-causation-notes.md:45-52`). Out of scope, section 9.

---

## 3. The screens

Three routes, all inside `QitsMainLayout`, all loaded eagerly — there are three of them and they
share every component below them.

### 3.1 The log — `/events/`

**Load budget: `2 + 1 socket`, and the variable term is zero per row.**

- `GET /events/api/events?limit=200` — one page of the log.
- `GET /events/api/events/names` — the filter's vocabulary (section 5.3).
- one `/events/stream` connection, opened once for the page's life.

Nothing fans out per row: everything a row draws is in the row. "Load more" is `+1` and appends;
it is a button, not an infinite scroll, because a scroll that fires requests hides its own cost.

A row is: time · name badge · repository · summary · a cause marker. The summary is per-name
(section 4.3). The **cause marker is a link and not a count** — `parentId` arrives with the row so
"this had a cause" is free, while "this caused N" would be one `?parentId=` per row and turn a flat
budget into 200 requests. Deriving child counts from the loaded window instead is worse than
nothing: it would be right in the middle of a page and wrong at both edges, silently.

Filters, all in query parameters so the view is bookmarkable and the back button means "undo the
filter":

    ?name=SCMRelease,SoftwareRelease   server-side, and also the socket's subscribe set
    ?since=2026-08-01T00:00:00Z        server-side
    ?q=qits-stt                        payload substring — see ⚖2
    ?cursor=<occurredAt>,<id>          the composite cursor, written by "load more"

A live-tail toggle sits in the header with a quiet connected/stale marker, the same shape
`workspace-events.ts:69` describes: disconnected means the page is briefly behind, not wrong.

### 3.2 The event, with its chain — `/events/events/:id`

**Load budget: `1 + U + D`**, where `U` is upward hops to the root and `D` is the number of nodes
in the connected component.

- `GET /events/api/events/{id}` — the event itself.
- `U ×` `GET /events/api/events/{parentId}` — the walk up, one hop at a time, **bounded at 32** and
  stopping on null, on 404 and on an id already seen.
- `D ×` `GET /events/api/events?parentId={id}` — the walk down from the root, breadth-first, one
  call per visited node, bounded by **depth 8 and 200 nodes**.

Measured cost on live data: a root with no children is `1 + 0 + 1 = 2`. The largest component in
the store — the five-node npm train of section 1.2, entered from its deepest leaf — is
`1 + 2 + 5 = 8`. The bounds are twenty times the observed graph and they exist because the API
refuses to bound anything for us (`README.md:44-51`); when one is hit the tree draws a "bounded
here" node rather than truncating in silence.

The page is: a header (name, both timestamps, id), the payload block (section 4.4), and the chain
tree with the current event marked. A dangling parent draws as "cause not in the log
(`064158b0…`)" — the honest reading, and there is a live row that needs it.

### 3.3 Not found — `/events/**`

`/events/` is a segment this application owns outright, so an unknown URL under it is an ordinary
404 drawn with the chrome around it — `qits-spa-artifacts/src/app/app.routes.ts:36-38`.

---

## 4. The four design arguments

### 4.1 The causation view is a page, not an expansion

Three shapes were considered against the measured graph.

**Inline tree in the log.** Rows expand into their children, ci-explorer style. It fails on the
data: 120 of 137 events are roots with no children, so the affordance is empty on 88% of rows, and
learning *which* rows are worth expanding is exactly the per-row `?parentId=` request the log's flat
budget forbids. It also cannot show the walk *upwards*, which is half the question.

**Click-through rows.** Each event page shows a parent link and a children list; the user
reconstructs the shape by navigating. Cheapest to build and it makes the user hold the graph in
their head — but **the shape is the information**. "One SCMRelease became a BuildSuccessful and one
SoftwareRelease per declared artifact, at the same instant" is a picture; as five navigations it is
a memory test.

**The whole component, on the event's own page.** The event page walks up to the root and draws the
component down from there, with the event you arrived at marked. It answers both directions at
once, it renders the fork as a fork, and it costs `1 + U + D` — measured at 8 requests for the
largest graph the platform has produced in its lifetime.

*Recommendation: the third.* See ⚖1 — it is the decision this feature turns on.

One tempting shortcut is worth naming so nobody rediscovers it: the log page has already fetched
every event, so the whole graph could be built client-side for **zero** extra requests. That is
true today and true only because history is 62 KB. Section 5 deliberately makes it stop being true.
Building the chain against a full-history fetch would design the feature around an accident and
break it on the day paging lands.

### 4.2 The live tail pushes rows, and refetches on every connect

The stream is at-most-once and live-only (`EventStreamSocket.java:40-42`). So:

- On `onopen`, **refetch the first page** and subscribe. Not "on first open" — on *every* open,
  including reconnects, because the gap a disconnect left is unknowable and the server offers no
  resume token. This is `workspace-events.ts:41-46` applied to a different transport, and it is the
  same trade: a handful of requests on reconnect against a class of correctness bugs.
- Subscribe to **the name filter's set**, or `["*"]` when there is no name filter. The set is
  replaced wholesale by each frame (`EventStreamSubscriptions.java:69-82`), so a filter change is
  one frame — and changing the filter refetches anyway, which closes the same gap by the same
  mechanism. This makes the filter mean one thing live and historically.
- **Insert by `occurredAt`, do not prepend.** `occurredAt` is the caller's time and may be in the
  past (`V1__init.sql:9-11`) — measured on the live store: `ProbeEvent 3fb1b96a` has
  `occurredAt 13:30:00` against `createdAt 13:21:13`, an 8-minute disagreement in a log of 137
  rows. A prepend would put it in the wrong place on screen and disagree with the next refetch.
- **Deduplicate by id.** A refetch and a frame overlap by construction, since frames keep arriving
  while the invalidating fetch is in flight.
- Where the filter is client-side (⚖2), the frame is filtered client-side too, by the same
  predicate the loaded rows go through.

The alternative is the sibling's own shape — hint-and-refetch, treat a frame as "the log is stale"
and re-issue the list request. It is simpler and has no shape-drift risk. It is also a full page
refetch per event, and this stream carries the whole event rather than a payload-free topic name.
See ⚖3.

The frame's missing `createdAt`/`updatedAt` (`EventCreated.java:22-24`) are not a problem, because
the log does not draw them: the row shows `occurredAt`, which every frame carries. The event page
fetches by id and gets the full `EventDto`. That is worth stating out loud, because if the log ever
grows a `createdAt` column the push path silently becomes lossy.

### 4.3 The row summary is a small table plus an honest fallback

Three production names, disjoint payload keys, no shared "repository" key. A per-name formatter:

    BuildSuccessful   repoId  ·  branch  ·  shortSha(commitSha)
    SCMRelease        repository  ·  version  ·  branch
    SoftwareRelease   repository  ·  version  ·  packageType packageName

A table of three is honest when the vocabulary is three. What keeps it from being brittle is the
**fallback**: an unknown name renders the first three `key=value` pairs of its parsed payload, in
canonical order. New names are born in
`services/qits-ci/service/src/main/java/eu/wohlben/qits/ci/bus/EventWireReflection.java` and in no
SPA's release cycle, so a fourth event type must render *something* useful the day it first fires,
with no frontend deploy. The fallback is the feature; the table is the polish.

### 4.4 The payload renders as pretty-printed JSON, and never assumes it is JSON

Bus payloads are **already canonical**: keys sorted alphabetically, no insignificant whitespace,
nulls omitted, and the publisher — not the server — produces them
(`libs/qits-eventstream/src/main/java/eu/wohlben/qits/eventstream/control/CanonicalJson.java:19-45`).
The server stores the string verbatim and compares it byte-for-byte
(`EventService.java:130-131`); `V2__payload.sql:13` says the column "is never queried by content".

So the renderer:

- parses, pretty-prints at two-space indent, and **re-sorts keys** — free insurance, since the
  `POST` path accepts any string a person types and nothing canonicalizes that;
- on a parse failure, shows the raw string in a `<pre>` and says it is not JSON, rather than
  failing;
- on `null`, draws the empty state. `payload` is nullable and permanently so
  (`V2__payload.sql:9-10`);
- does not truncate. Measured payload sizes: min 38, median 192, **max 220 bytes**. A "show more"
  affordance on a 220-byte value is ceremony.

---

## 5. The backend workstream (qits-events)

Five additions to one route plus one new route. None is a new literal outside `/events/api`, so
**`quarkus.quinoa.ignored-path-prefixes` is not touched** — the standing trap this repo documents at
length (`services/qits-events/CLAUDE.md`, "Paths") does not fire here, and that is worth confirming
in the commit message rather than leaving to luck.

### 5.1 A total order, first

    listNewestFirst()  →  Sort.by("occurredAt").descending().and("id", Descending)

`EventRepository.java:16-18` sorts by `occurredAt` alone and 4 of 137 rows tie (section 1.3). This
is a correctness fix independent of paging: without a tiebreaker the log's order is not reproducible
across two calls, and with paging it silently loses rows. Ship it first and alone if convenient.

### 5.2 Cursor paging

    GET /events/api/events?limit=200&cursor=<occurredAt>,<id>

- `limit` — honoured. Default 200, clamp to 1000. **The clamp must be silent-safe**: the response
  says how many it returned and whether more exist, so a client never has to infer it.
- `cursor` — the composite `(occurredAt, id)` of the last row of the previous page, opaque to the
  client in spirit and legible in practice. The predicate is
  `occurred_at < :t or (occurred_at = :t and id < :id)`.
- Response grows one field:

      { "events": [...], "nextCursor": "2026-08-01T08:52:23.928965Z,0bdbe98d-…" }

  `null` when the page is the last one. Appending a field is safe: the SPA is the only consumer of
  this route today and the bus client never reads it.

Scalar `before=<occurredAt>` is rejected for the reason in section 1.3 — it splits release forks —
and `?offset=` stays rejected for the reason in `docs/ci-cd-explorer-notes.md:20-21`.

`?parentId=` is **not** paged. A parent's children are N+1 for N declared artifacts; the observed
maximum is 2 and the shape is bounded by a pipeline file, not by history.

### 5.3 Name filter and vocabulary

    GET /events/api/events?name=SCMRelease,SoftwareRelease
    GET /events/api/events/names   →  { "names": ["BuildSuccessful", "SCMRelease", …] }

The vocabulary route is `select distinct name order by name`. Without it the SPA can only learn the
names by fetching all of history, which is the thing paging exists to stop.

**Route ordering is a real hazard here.** `/names` and `/{id}` are siblings under `@Path("/events")`.
JAX-RS sorts literal characters ahead of templates, so `/names` wins — but that is a spec guarantee
being leaned on, so `EventApiTest` asserts `GET …/events/names` returns the vocabulary and not a
404 from `EventService.get`. If that reads as too clever, `@Path("/event-names")` on a second
controller gives `/events/api/event-names` with no ordering question at all; both are fine and the
first is one method.

### 5.4 Time floor and payload search

    GET /events/api/events?since=2026-08-01T00:00:00Z
    GET /events/api/events?q=qits-stt

`since` is a lower bound only. There is deliberately no `until`: the cursor **is** the upper bound,
and two parameters that mean the same thing is two things to keep in step.

`q` is a case-insensitive substring match on `payload` — `lower(payload) like '%'||?||'%'`. It is
named `q` and documented as a substring search, not as a repository filter, because it is one: on
this data `q=qits-stt` matches `"repoId":"qits-stt"`, `"repository":"qits-stt"` and
`"packageName":"qits/qits-stt"`, which is what a person asking about qits-stt wants and is not what
the word "repository" promises. It does not parse the payload and it adds no column, so the
server's "the string is opaque" stance survives intact. See ⚖2.

### 5.5 The index

    V5__event_query_indexes.sql
      create index idx_event_name_occurred_at on Event (name, occurred_at);

`idx_event_occurred_at` (V1) already covers the unfiltered page and `since`. `idx_event_parent_id`
(V3) covers the chain walk. The composite is for `where name in (…) order by occurred_at desc`.
`q` gets no index — a `like '%…%'` cannot use one, and at 50,000 rows/year (section 1.4) a scan of
a 22 MB column is honest. Write that number into the migration comment so the next reader does not
have to re-derive it.

### 5.6 What is NOT added

- **No `/chain` route, no depth parameter, no graph endpoint.** The refusal is argued at
  `README.md:44-51` and this design does not reopen it: the client bounds its own walk (section 3.2).
- **No child-count aggregate.** It would let the log draw fork markers; the log deliberately does
  not draw them (section 3.1). Fast-follow if a user asks for it, roughly
  `select parent_id, count(*) … group by parent_id` over the loaded page's ids.
- **No `?rootsOnly=`.** Measured: 120 of 137 events are roots, so it removes 12% of the rows. Not
  worth a parameter.
- **No projected `repository` column.** It would require the server to parse a payload it defines as
  opaque, and there is no single key to project (section 1.1). ⚖2.

---

## 6. The decisions ⚖

**⚖1 — is the causation view a chain page, an inline tree, or click-through rows?**
Section 4.1 prices all three against the measured graph: 120 of 137 events are roots, max depth 2,
largest component 5 nodes, and forks are the rows anyone cares about.
*Recommendation: the chain page* — the event page walks up to the root and draws the whole
component down from it, with the arrived-at event marked, at a measured cost of 2 requests for the
common case and 8 for the biggest graph the platform has ever produced. It is the only one of the
three that renders the fork *as* a fork, and the inline tree's expand affordance would be empty on
88% of rows. Cost against click-through: roughly one extra workstream-day for the walker and its
bounds. **This is the decision the feature turns on; answer it before anything is built.**

**⚖2 — how does a person filter by repository?**
Three options. (a) Client-side over the loaded page — free, no backend change, and quietly useless:
filtering 200 loaded rows to 3 looks like "there are only 3". (b) `?q=` substring on `payload` —
about ten lines, no schema change, keeps the payload opaque, over-matches slightly and says so. (c)
A projected `repository` column populated at write time — the only exact answer, and it makes the
server parse a payload that `V2__payload.sql:13` and `EventService.java:130-131` both define as an
opaque string it must never interpret, for two keys that are not even the same key.
*Recommendation: (b).* It is the honest shape of the question, it costs nothing structural, and it
leaves (c) available if someone later wants exactness enough to pay for a write-path parser. Label
the input "search payload", not "repository".

**⚖3 — does the live tail push rows, or hint-and-refetch?**
The sibling precedent is hint-and-refetch (`workspace-events.ts:31-46`), but that channel carries
payload-free topic names; this one carries the whole event. Push-the-row costs zero requests per
event and needs insert-by-`occurredAt`, dedup-by-id, and client-side filtering of frames.
Hint-and-refetch costs one full page fetch per event — at the measured peak of 27 events/hour that
is trivial, and at a release train's burst it is five fetches in six seconds — and it cannot drift
from the fetched shape.
*Recommendation: push the row.* The frame **is** the event, the two fields it lacks are two fields
the log does not draw, and a tail that refetches the page on every arrival is a poll with extra
steps. Write the drift risk down in the component: if the log ever renders `createdAt`, this
decision must be revisited in the same commit.

**⚖4 — does the SPA ship before the backend paging lands?**
The client can be written so `limit` is advisory: send it, cap the rendered list client-side, and
treat a missing `nextCursor` as "no more". Against **today's** server — which ignores `limit`
entirely (section 1.1) — that renders correctly and merely over-fetches 62 KB.
*Recommendation: yes, decouple them.* CB and CC/CD then run in parallel instead of in series, and
the SPA's first deploy does not wait on a qits-events release cycle. The cost is one temporary
over-fetch and one line of prose explaining it.

**⚖5 — what is the event page's URL?**
`/events/events/:id` repeats the noun, which is ugly. `/events/:id` (a bare `:id` under the base
href) is clean but swallows every future top-level route and makes `**` unreachable.
*Recommendation: `/events/events/:id`.* Every sibling repeats its noun — `/ci/runs/…`,
`/artifacts/repositories/…` — the segment matches the API path it mirrors, and the alternative
trades a cosmetic win for a routing constraint that cannot be undone once links are shared.

**⚖6 — the time-range control: local, or in `@qits/ui-components` from the start?**
A sibling agent is designing the observability UI in parallel and will want the same "last hour /
last 24h / custom" control. Promoting it to the shared library sounds obviously right and is
currently blocked by a measured fact: every SPA pins `@qits/ui-components@^0.0.4` while the library
publishes calver, "the caret will never cross"
(`docs/ci-cd-explorer-notes.md:40-41`), so a component added to the library today reaches no
application until the release-train fan-out (`handoff.md:103-107`) unfreezes the pin.
*Recommendation: build it locally in qits-spa-events, and record it as a promotion candidate.*
Section 8 lists it as a coordination point rather than a shared deliverable.

---

## 7. Workstreams

Letters start at **CB**. Sizes are honest, not encouraging.

- **CB — qits-events: paging, filters, vocabulary, order.** Section 5 in full: the tiebreaker, the
  composite cursor, `limit`, `name`, `since`, `q`, `GET …/events/names`, `V5__event_query_indexes.sql`,
  the OpenAPI regeneration, `EventApiTest` cases for the tie boundary and the `/names` vs `/{id}`
  ordering, and a `PackagedSurfaceIT` probe that `/events/api/events/names` answers JSON and not
  `index.html`. **Independent of every other workstream** (⚖4). One qits-events deploy cycle.
  *Small-to-medium — it is one controller method, one repository method, one migration and the
  tests that make the cursor believable.*

- **CC — qits-spa-events foundation.** `provideHttpClient(withFetch())`; `QITS_API_BASE`;
  `EventsApi` with `list/get/children/names` and its `dto.ts`; `Loadable`/`Async`/`Empty`/`format`
  and `ui/page.css` taken from `qits-spa-artifacts` (the newest form, with the **drawn** chevron);
  the routes; the `NotFound` page; eslint + prettier + a `lint` target to match the siblings; a real
  README. Blocks CD, CE, CF. *Medium, and almost all of it is transcription.*

- **CD — the log page.** Table, per-name summaries and the generic fallback (section 4.3), the four
  filters as URL state, "load more", the empty and error states, the budget written in the javadoc
  and **asserted** in the spec. *Medium.*

- **CE — the live tail.** A `WEB_SOCKET_FACTORY` injection token mirroring
  `qits-spa-workspaces/src/app/api/event-source.ts:34-37`; the subscribe frame; refetch-on-every-open;
  insert-by-`occurredAt`; dedup-by-id; the connected/stale marker; reconnect backoff. Specs drive
  the fake socket by hand — open, frame, close, reopen — because none of this is reachable
  otherwise. *Medium, and the highest defect density on the page.*

- **CF — the event page and the chain.** The header, the payload renderer (section 4.4), and the
  bounded walker: up by `parentId` with a seen-set and a 32-hop cap, down by `?parentId=` BFS with a
  depth-8 / 200-node cap, the "bounded here" node, and the dangling-parent rendering. The walker is
  its own service with its own spec — the caps are asserted, not described. *Medium-to-large; the
  walker is the substance.*

- **CG — deploy and verify.** Bump the `webui` gitlink in `services/qits-events`, push, watch the
  run, confirm the deployment, run the browser pass of section 8. *Small, and it is where the
  operational traps live.*

Sequencing:

    CB  ∥  CC
            ↓
           CD
            ↓
       CE  ∥  CF
            ↓
           CG

CB is independent throughout (⚖4) and can land in either order; if it lands late, CD's over-fetch
disappears with no client change. CE and CF are independent of each other.

**Cost, honestly.** Six workstreams, four of them medium, none of them large by this platform's
standards — this is a smaller feature than the CI explorer and much smaller than workspace detail.
Expect one qits-events deploy cycle for CB and one to three qits-spa-events gitlink bumps. The
walker's bounds and the tail's dedup are where the time actually goes; the log page is the part
that looks big and is not.

---

## 8. Verification

**There is no E2E framework on this platform** — no Playwright or Cypress in any frontend's
`package.json`, confirmed again today. "Browser-E2E'd" means a scripted manual pass driven with the
DevTools or Playwright MCP tools, and the script is below.

**Unit tests.** Vitest on jsdom through `@angular/build:unit-test`; no vitest config file anywhere
and there should not be one. `HttpTestingController` for every transport, `RouterTestingHarness` for
routes, the fake socket factory for the tail. Every page's load budget is **asserted**, not just
written down — `qits-spa-artifacts/src/app/repositories/repositories-page.spec.ts:92` is the model
("five repositories on screen and no further traffic: the variable term of the budget is zero").

Specific cases that would otherwise be found in production:

- The walker stops on a **404 parent** and draws "cause not in the log".
- The walker stops on a **cycle** (`A → B → A`), because nothing server-side prevents one
  (`EventService.java:210-213`).
- The walker stops at its depth and node caps and *says so*.
- A pushed frame with an `occurredAt` **older** than a rendered row lands in the right place.
- A pushed frame whose id is already rendered does not duplicate it.
- A reconnect refetches; a filter change refetches and sends one new subscribe frame.
- The payload renderer survives a non-JSON payload and a null payload.

**Backend tests (CB).** `EventApiTest`: a page boundary that falls **exactly on a tie** returns both
siblings across two pages and neither twice — build the fixture from the real shape, two events with
one `occurredAt` and different ids. `GET …/events/names` returns the vocabulary rather than a 404.
`?limit=` above the clamp returns the clamp. `PackagedSurfaceIT` gets the `/names` probe, because
Quinoa is off in tests and a route that falls through to the SPA is invisible to a `@QuarkusTest`.

**The browser pass, through the real gateway at :8080.**

0. **Hard-reload first.** Every SPA serves `index.html` with `immutable, max-age=86400` — measured
   again today on `GET /events/`. A returning browser gets the stale page after every deploy. The
   gateway fix is parked (`handoff.md:93-97`); do not attempt it inside this feature.
1. Open `/events/`. Confirm 137-plus rows, newest first, each naming its repository.
2. Filter by name to `SCMRelease`. Confirm 4 rows and confirm in the network panel that the request
   carried `?name=` — not that the client filtered a full fetch.
3. Search `qits-stt`. Confirm the `SCMRelease`/`SoftwareRelease`/`BuildSuccessful` rows for it.
4. Open `SCMRelease c5edabb5-0621-4ff8-bf1b-29a3df2bb03c`. Confirm the five-node tree of section 1.2
   renders as a **fork** — two children at the same instant, one grandchild under each — and that
   the request count matches the budget in the javadoc.
5. Open `BuildSuccessful 59934bf8-ebc6-4760-bec2-cbe7cafd0371`. Confirm the dangling parent
   `064158b0…` renders as "cause not in the log" and not as a spinner, an error, or a blank.
6. Turn the live tail on. Trigger a real build (push to any repository, or replay
   `POST /ci/api/events/post-receive`) and watch the row arrive **without a page fetch**. Confirm
   the network panel shows no polling at all while the tail is on.
7. Kill the socket (DevTools offline, then online). Confirm the stale marker appears, that the
   reconnect refetches the first page, and that no row is duplicated.
8. Page: "load more" until the log ends. Confirm no row appears twice and no row is skipped across
   the tie at `2026-08-01T08:52:23.928965Z`.
9. Deep-link a chain page in a fresh tab, then press back twice. Confirm the filter state comes back.

**Operational traps, every one of which has bitten this platform.**

- No CI run row after a push → replay `POST /ci/api/events/post-receive`. Replays are not
  idempotent; a missing row while the worker is busy means QUEUED, not lost.
- Green run, no deployment row, "database has been closed" in cd's logs → restart qits-cd, replay
  `POST /cd/api/events/build-succeeded`.
- **qits-events redeploying itself is part of this rollout**, so the self-redeploy blip applies on
  every CB and CG push.
- Never run `qits-local-up.sh` casually; never delete the `qits` project.

---

## 9. Out of scope, named so it stays out

- **Retention, GC or any deletion of events.** The store is append-only by design and this plan adds
  nothing that changes that. `DELETE /events/api/events/{id}` exists and **the UI does not expose
  it**. Section 1.4's 22 MB/year is an argument for paging, not for a retention policy; if one is
  ever wanted it is its own feature with its own document, and it interacts with dangling parents
  (`EventService.java:204-207` already anticipates it).
- **Writing events from the UI.** No `POST` form, no publish button. The log is read-only.
- **The trigger DAG.** The graph of declarations is dual to and not the same as the graph of
  occurrences (`docs/event-causation-notes.md:45-52`). A different feature, a different read model,
  and it must not be smuggled into this one because the two look alike on screen.
- **Cross-push causation.** A force-push is not an event, so a train hop is two short chains rather
  than one long one — ruled correct at design time
  (`docs/event-causation-notes.md:36-43`). The chain view draws what the edges say and invents
  nothing across a push boundary.
- **Stream catch-up / replay.** Named by the service as "a deliberate omission rather than a gap"
  and "the next feature" (`EventStreamSocket.java:40-42`). Section 4.2's refetch-on-connect is the
  client-side answer that works without it, and must not be mistaken for a resume protocol.
- **Authentication and roles.** The gateway owns them; this service authenticates nothing by design.
- **The `index.html` cache header.** One gateway change, seven SPAs' worth of benefit, parked in
  `handoff.md:93-97`. Not this feature's to make.
- **`QITS_NAV_LINKS`.** Already correct.

---

## 10. Coordination points with the observability UI

Named, not designed — the observability SPA is being designed in parallel and this document has not
read that work.

1. **A time-range control.** Both screens want "last hour / last 24h / custom", and both will write
   it into a query parameter. ⚖6 recommends building it locally here and recording it as a
   promotion candidate for `@qits/ui-components`, because the `^0.0.4` caret means a library
   addition reaches no application until the release-train fan-out lands.
2. **Whether `?since=` is the platform's spelling for a time floor.** Cheap to agree now, expensive
   to reconcile after two SPAs ship two spellings.
3. **The cursor-paging shape.** Section 5.2's `(occurredAt, id)` composite and `nextCursor`
   response field are the first concrete paging on this platform;
   `docs/ci-cd-explorer-notes.md:20-21` already parks the same fast-follow for the CI and CD lists.
   If observability needs paging, it should use this shape or say why not.
4. **Nothing else.** The two services share no table, no route and no DTO, and neither should grow
   a dependency on the other to make a screen work.
