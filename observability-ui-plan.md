# The observability UI

Status: **IMPLEMENTED AND BROWSER-PROVEN (2026-08-02).** All seven decisions were settled as
recorded in §10; the complete UI was embedded at superproject commit `95f3a9e`. This document is
retained as the design and decision record; where its pre-implementation measurements differ from
the shipped state, the completion record in `handoff.md` wins.

The one-line summary, and it is uncomfortable: **the observability service is receiving the whole
platform's telemetry into a bucket that no query can address.** Ten Quarkus processes export OTLP
here right now; every record lands in `TelemetryStore`'s `_unscoped` quarantine, which the REST
surface cannot name and the MCP tools cannot name. Meanwhile the five read endpoints that *do*
exist are all keyed on `repositoryId` + `workspaceId`, and **zero workspaces exist on this
platform** — and the only thing that would ever stamp those attributes is the parked dev-server
sender. A UI built on today's read surface would be correct, complete, and permanently empty.

So this plan is a backend workstream plus six screens, not six screens. The backend half is small
(one service, no database, no persistence, no migration) and it is the difference between a page
that shows the platform and a page that shows nothing.

Paths are relative to the superproject `/home/wohlben/code/qits-qits`.

---

## 1. What was measured

Live reads were taken from the running platform on 2026-08-01 through the gateway at
`localhost:8080`. Source citations are absolute paths at the commit in the working tree.

### 1.1 The read surface is five GETs, and they are all workspace-keyed

`WorkspaceTelemetryController` declares exactly five operations, and the committed document agrees
(`services/qits-observability/service/src/main/java/eu/wohlben/qits/telemetry/api/WorkspaceTelemetryController.java:43-114`;
`services/qits-observability/docs/openapi.yml:164-300`). Every one answered live:

| Route | Params | Live response |
|---|---|---|
| `GET /observability/api/telemetry/errors` | `repositoryId`, `workspaceId`, `sinceMinutes` | `{"groups":[]}` |
| `GET …/telemetry/traces/{traceId}` | `repositoryId`, `workspaceId` | `{"trace":{"traceId":"deadbeef","spans":[],"logs":[]}}` |
| `GET …/telemetry/slow-spans` | `repositoryId`, `workspaceId`, `thresholdMs=500`, `sinceMinutes`, `sort=duration` | `{"spans":[]}` |
| `GET …/telemetry/logs` | `repositoryId`, `workspaceId`, `query`, `service`, `sinceMinutes` | `{"logs":[]}` |
| `GET …/telemetry/metrics` | `repositoryId`, `workspaceId`, `name` | `{"metrics":[]}` |

Five facts about that table matter to a UI and none of them are obvious:

- **`sort=recent|duration` is real**, and it is on `slow-spans` only
  (`WorkspaceTelemetryController.java:77-84`, decoded to `TelemetryQueryService.SpanSort` at
  `TelemetryQueryService.java:99-119`). An unrecognised value silently means `duration` — measured:
  `?sort=nonsense` answered 200 with the duration ordering, no complaint.
- **`thresholdMs=0` turns `slow-spans` into "every buffered span"**. The filter is
  `span.durationMs() >= thresholdMs` (`TelemetryQueryService.java:115`), so zero admits everything.
  That is the only way today to enumerate spans, and it is how a trace list could be derived.
- **There is no `limit` anywhere.** Every endpoint returns the entire matching buffer. With the
  default caps that is up to 5,000 spans or 10,000 logs in one response body.
- **There is no listing of anything.** No route answers "what buckets exist", "what services have
  reported", or "what traces are in the buffer". The caller must already know a `repositoryId` and
  a `workspaceId`.
- **A missing scope is not an error.** `GET …/telemetry/errors` with no parameters at all answered
  `200 {"groups":[]}` — the key becomes `"null/null"` and selects an empty bucket
  (`TelemetryStore.java:240-242`). A UI bug that drops its scope looks exactly like "no telemetry".
  So does an unknown trace id: `traces/deadbeef` answered 200 with an empty trace, never 404.

### 1.2 Everything the platform exports is unreachable

Bare Java filenames below live under
`services/qits-observability/service/src/main/java/eu/wohlben/qits/telemetry/` in the package their
name implies (`control/TelemetryStore.java`, `dto/StoredSpan.java`, and so on).

`TelemetryStore` buckets by two resource attributes,
`qits.repository.id` and `qits.workspace.id` (`TelemetryStore.java:48-49`). Records carrying
neither land in `UNSCOPED_KEY = "_unscoped"` (`TelemetryStore.java:46`, `:230-238`), described in
the class javadoc as "a quarantine bucket … bounded like any other but not exposed by the query
surface" (`TelemetryStore.java:28-31`).

That is not a hypothetical corner. **Every qits service exports here, and none of them stamps those
attributes.** Ten `application.properties` files carry
`quarkus.otel.exporter.otlp.endpoint=${qits.observability.url}/observability/api/otel` — artifacts,
cd, ci, dns, events, observability (to itself), projects, stt, workspaces, and the gateway
(`services/qits-gateway/src/main/resources/application.properties:287-288`). A grep for
`OTEL_RESOURCE_ATTRIBUTES` across every repository finds it only in qits-gateway's `config.json`
relay and qits-workspaces' capture endpoint — **never in a service's own configuration**. Confirmed
on the live containers: `docker inspect` of the running `qits-observability` and `qits-ci`
containers shows `QITS_ENVIRONMENT` and `QITS_APPLICATION` and no OTel variable at all. The
`opentelemetry` feature is installed in both (`docker logs`, "Installed features"), and no export
error appears in either log.

So the exports are arriving, and they are all in `_unscoped`.

**And `_unscoped` cannot be addressed.** The lookup key is `repoId + "/" + workspaceId`
(`TelemetryStore.java:240-242`); no pair of query parameters can produce a string equal to
`_unscoped`, because that string contains no `/`. This is not an oversight to route around in the
client — it is closed by construction.

### 1.3 The workspace lens has no subjects, and its producer is parked

`GET /workspaces/api/workspaces?repositoryId=…` answered `{"entries":[]}` for every repository
tried, including `qits-observability` and the fixture repositories. There are **nineteen
repositories and zero workspaces** on this platform right now.

Even with a workspace, nothing would export: the README records the gap plainly at
`services/qits-observability/README.md:164-173` — the overlay that set
`OTEL_EXPORTER_OTLP_ENDPOINT` on launched services "was dropped during the daemon extraction as
dead code, and the live launch path — the daemon's `ServiceSupervisor` — never had it". **That
sender is out of scope here and this plan does not design it.** It is named because it is the sole
producer for the entire existing read surface, and a plan that quietly built five screens on top of
it would be building on nothing.

### 1.4 One bucket means the two-tier cap is defeated

Bounding is two-tier by design: per-workspace count caps plus a global byte ceiling that evicts from
the *fattest* bucket "so one chatty service pays for its own volume instead of evicting a quieter
workspace's telemetry" (`TelemetryStore.java:34-38`). Defaults, from
`TelemetryStore.java:53-63`: **5,000 spans**, **10,000 logs**, **500 metric series** per bucket, and
**64 MiB** (67,108,864 bytes) total.

With everything in one bucket, the fairness tier has nothing to be fair between. Ten services share
one 5,000-span and one 10,000-log allowance, and a chatty one evicts a quiet one — the exact outcome
the design was built to prevent.

The byte ceiling, meanwhile, never fires. Using `TelemetrySizeEstimator`'s own arithmetic (48 bytes
per object/entry, 2 bytes per char — `TelemetrySizeEstimator.java:19,66`), a Quarkus server span
with ~10 span attributes and ~8 resource attributes estimates at roughly 2 KB, and a log record at
roughly 1.5 KB. Full buffers are therefore about 10 MB of spans plus 15 MB of logs — **the count
caps bind first, every time, and the 64 MiB ceiling is unreachable in the current topology.** A UI
that reports buffer pressure must report *counts*, not bytes, or it will always read 40%.

### 1.5 There is no live channel, and the one hint that exists is scoped-only

`TelemetryChangePublisher` fires a CDI async `TelemetryChanged` event
(`TelemetryChangePublisher.java:21-25`), and the README documents a consuming application bridging
it to the workspaces SSE channel (`README.md:129-142`).

**Nothing observes it.** A grep for `TelemetryChanged` across every service, daemon and lib finds
only its own declaration, its own tests, and a `Topic.TELEMETRY` enum constant in
`services/qits-workspaces/domain/src/main/java/eu/wohlben/qits/workspaces/control/WorkspaceChangeHint.java:20`
plus one test reference. The bridge described in the README is a same-process pattern, and under
the gateway topology qits-workspaces and qits-observability are separate containers — a CDI event
cannot cross that.

Worse for our purposes: the hint **only fires for scoped workspaces**. `fireTelemetryHints` skips
any record without both attributes (`TelemetryStore.java:149-160`) and the javadoc says so outright:
"unscoped records … produce no hint (nothing subscribes to them)" (`TelemetryStore.java:141-142`).
So the one live signal in this service is silent for 100% of the telemetry that exists.

There is no SSE, no WebSocket and no long-poll route on qits-observability. **This is polling
territory**, and §6 budgets it.

### 1.6 Metrics have no history, so there is nothing to plot

`TelemetryStore` keeps a `LinkedHashMap<String, MetricPoint>` — **one point per series**, replaced
in place on every arrival (`TelemetryStore.java:76`, `:113-137`). `TelemetryDecoder` keeps Gauge and
Sum only and drops histograms, summaries and exponential histograms outright
(`TelemetryDecoder.java:122-130`), and a COUNTER carries "the latest cumulative total, no rate math"
(`MetricPoint.java:6-9`).

A time-series chart needs a series. There is none, and building one would mean retaining history,
which is persistence and is out of scope. **The metrics screen is a table.** This is a measurement,
not a taste call.

### 1.7 The SPA is a shell, and its deploy path runs through the service

`frontends/qits-spa-observability` is four source files:
`src/app/app.ts` (a bare `<router-outlet />`, OnPush, standalone), `src/app/app.routes.ts`,
`src/app/app.config.ts` (`provideBrowserGlobalErrorListeners` + `provideRouter`, nothing else) and
`src/main.ts`. The route table is one line:

    export const routes: Routes = [{ path: '', component: QitsMainLayout, children: [] }];

and its comment names the hook: "`children` is empty on purpose: the observability pages are not
written yet, and this is the hook they attach to when they are"
(`frontends/qits-spa-observability/src/app/app.routes.ts:9-11`). Angular **21.2**,
`@qits/ui-components` **^0.0.4**, vitest, no service layer, no `eslint.config.js`, and — measured
against the four working SPAs — **no `provideHttpClient(withFetch())`**: `app.config.ts` carries
`provideBrowserGlobalErrorListeners()` and `provideRouter(routes)` and stops there
(`frontends/qits-spa-observability/src/app/app.config.ts:6-8`), where every sibling carries three.
There is also no `**` route, so an unknown URL under `/observability/` renders blank chrome.

Live at `http://localhost:8080/observability/` — 200, `<base href="/observability/">`, the platform
stylesheet attached. Chrome renders; there is nothing under it.

Confirmed as the `webui` gitlink inside the service:
`services/qits-observability/.gitmodules` maps `qits-spa-observability` to `service/src/main/webui`,
and `git ls-tree HEAD service/src/main/webui` in that repo shows `160000 commit bea5f2f6…`. Quinoa
builds it during augmentation (`services/qits-observability/service/src/main/resources/application.properties:36-70`)
with `quarkus.quinoa.build-dir=dist/qits-spa-observability/browser`.

Two deploy facts a dispatcher needs:

- **`qits-spa-observability` is not a repository on the platform git host.**
  `GET /artifacts/git/qits-spa-observability/info/refs?service=git-upload-pack` answers **404**;
  `qits-observability` answers 200. The SPA repo pushes to GitHub `origin` only, and it has no
  `.config/qits/` directory, so it runs **no pipeline** — no lint, no tests, nothing.
- **The service's pipeline fetches the submodule from GitHub.**
  `services/qits-observability/.config/qits/ci-post-receive.yml` runs
  `git submodule update --init --depth 1 service/src/main/webui`, rewrites the lockfile's registry
  origin, `npm ci`, `npm run build`, then builds the image. So a SPA change reaches production only
  when the **gitlink in qits-observability is bumped and that repo is pushed**.

### 1.8 What the DTOs actually carry

Everything a screen can render, and nothing more:

- `TelemetrySpanDto` (`dto/TelemetrySpanDto.java:7-20`) — `traceId`, `spanId`, `parentSpanId`,
  `serviceName`, `scopeName`, `name`, `kind`, `startEpochNanos`, `durationMs`, `status`,
  `statusMessage`, `attributes`, `events`. `parentSpanId` plus `startEpochNanos` plus `durationMs` is
  exactly a waterfall. Note `durationMs` is integer milliseconds — sub-millisecond spans render as 0.
- `SpanEvent` (`dto/SpanEvent.java`) — `name`, `epochNanos`, `attributes`, with
  `exception.type` / `exception.message` / `exception.stacktrace` the interesting case.
- `TelemetryLogDto` (`dto/TelemetryLogDto.java:6-14`) — `epochNanos`, `severityNumber` (OTel scale,
  ERROR starts at 17 — `StoredLog.java:23-24`), `severityText`, `body`, `traceId`, `spanId`,
  `serviceName`, `attributes`.
- `TelemetryMetricDto` (`dto/TelemetryMetricDto.java:6-14`) — `name`, `description`, `unit`, `type`
  (`GAUGE`/`COUNTER`), `value`, `epochNanos`, `serviceName`, `attributes`.
- `TelemetryErrorGroupDto` (`dto/TelemetryErrorGroupDto.java:10-14`) — `traceId`, `serviceName`,
  `errorSpans`, `errorLogs`. Uncorrelated evidence groups under an **empty** trace id
  (`TelemetryQueryService.java:33-35`), which a UI must render as "no trace" rather than linking to
  `/traces/`.

Time windows filter on `receivedAtMillis`, the server-clock ingest stamp, never the exporter's own
timestamps (`TelemetryQueryService.java:22-24`). A null `sinceMinutes` means "everything still
buffered", which is the honest default for a bounded store and is what the UI should default to.

One wart worth fixing while we are in there: the generated schema names are `Response`, `Response1`,
`Response2`, `Response3`, `Response4` (`docs/openapi.yml:180-300`), because the request/response
records are nested inside the controller. Any generated client inherits those names.

### 1.9 The idiom is settled, written down, and app-local

Measured across `qits-spa-ci`, `qits-spa-cd`, `qits-spa-artifacts` and `qits-spa-workspaces`. None of
this is up for reinvention here; it is recorded so a dispatched agent copies rather than invents.

- **`@qits/ui-components` exports seven names and nothing else** — `QitsButton`, `QitsBadge`,
  `QitsCard`, `QitsMainLayout`, `QITS_NAV_LINKS`, and two type aliases
  (`libs/qits-spa-ui-components/projects/qits-spa-ui-components/src/public-api.ts:1-7`). There is **no
  table, list, empty-state, tab or status-pill component in the library.** Every SPA carries its own.
- **`Loadable<T>` is copied per SPA**, four near-identical files at `src/app/ui/loadable.ts`, with the
  duplication justified in the file: "there is no place to put it yet — @qits/ui-components carries
  presentational components, not application types"
  (`frontends/qits-spa-artifacts/src/app/ui/loadable.ts:14-15`). `idle` and `loading` are separate
  states on purpose: "`idle` is a state, not an absence … 'no workspaces' must not be drawn where
  'not asked yet' is the truth" (`frontends/qits-spa-workspaces/src/app/ui/loadable.ts:6-7`).
- **`app-async` renders nothing for `ready`/`idle`**; the caller writes its own
  `@if (x.kind === 'ready')` (`frontends/qits-spa-ci/src/app/ui/async.ts:8-12`).
- **`app-empty` takes `input.required<string>()`** — you cannot draw an empty state without naming its
  reason (`frontends/qits-spa-ci/src/app/ui/empty.ts:6-8, 10-24`). §5 of this plan is that rule
  applied to a buffer.
- **`QITS_API_BASE` self-provides and is the empty string.**
  `new InjectionToken<string>('qits.api-base', { providedIn: 'root', factory: () => '' })`
  (`frontends/qits-spa-ci/src/app/api/api-base.ts:16-19`). It is not provided in `app.config.ts` in
  any SPA; it exists so a spec has a seam to assert paths against.
- **`app.config.ts` is exactly three providers, in order**: `provideBrowserGlobalErrorListeners()`,
  `provideRouter(routes)`, `provideHttpClient(withFetch())`
  (`frontends/qits-spa-ci/src/app/app.config.ts:21-27`). `withFetch()` is mandatory and its reason is
  pointed straight at us: "the default XHR backend is invisible to OTLP fetch instrumentation"
  (`app.config.ts:15-19`). The observability SPA is the one page on this platform where shipping
  without it would be a joke at its own expense.
- **HttpClient + `firstValueFrom` → Promise, one injectable per upstream service.** `httpResource()`
  is deliberately not used while it is `@experimental` in the pinned Angular
  (`frontends/qits-spa-ci/src/app/api/ci-api.ts:22-26`).
- **Chevrons are drawn from two rotated borders, not typed.** Take
  `frontends/qits-spa-artifacts/src/app/ui/page.css:154-174` — "Both sibling explorers use the raw
  `▸`/`▾` glyphs and both render tofu boxes wherever the font lacks them" (`page.css:5-7`). That is
  the handoff's open tofu item, already solved in one repo.
- **Load budgets are stated in the README's route bullet and asserted in the page spec**, e.g. "the
  page itself makes two requests, both flat lists" (`frontends/qits-spa-ci/README.md:6-9`) and "On
  load this page reads `5 + P` … The assertion that matters most is still a negative one"
  (`frontends/qits-spa-ci/src/app/tree/tree-page.spec.ts:12-25`). There is **no `AGENTS.md` in any
  frontend repo**; the README is the document.
- **Routes:** one route at `''` whose component is `QitsMainLayout`, everything as `children`, and
  `**` → `NotFound` **inside** the children, because "`/ci/` is a segment this application owns
  outright, so an unknown URL under it is an ordinary 404 and is drawn with the chrome around it"
  (`frontends/qits-spa-ci/src/app/app.routes.ts:28-31`). Everything loads eagerly; no lazy chunks.
- **Standalone + OnPush on every component, signals throughout, `inject()` not constructor params,
  `DestroyRef.onDestroy` not `ngOnDestroy`, `DOCUMENT` injected not global, `@if`/`@for` control
  flow.** No `NgModule`, no `ngOnInit`, no `@Input`/`@Output` decorators anywhere in four repos.
- **Tests are vitest on jsdom through `@angular/build:unit-test`**, no vitest config file;
  `HttpTestingController` with `afterEach(() => http.verify())` for transports,
  `RouterTestingHarness` + `provideLocationMocks()` for routes, and an `app.config.spec.ts` asserting
  `TestBed.inject(HttpBackend).constructor.name` contains `Fetch` — "the backend choice is invisible
  when it is wrong" (`frontends/qits-spa-ci/src/app/app.config.spec.ts:5-19`).
- **There is no charting anywhere on this platform.** A sweep for `<svg`, `canvas`, `chart`,
  `sparkline`, d3/echarts/highcharts/apexcharts/ng2-charts across all four SPAs, the library and all
  five `package.json` files returns exactly one hit, and it is a refusal: "Nothing here is summed and
  nothing is charted. A bar chart of these would draw a comparison…"
  (`frontends/qits-spa-artifacts/src/app/repositories/store-summary.ts:39`). §7.3 does not break that
  streak.

---

## 2. What this UI is for

Three readers, and they want different things:

1. **The platform operator** — "is qits healthy right now, and what just failed?" Answered by the
   platform's own service telemetry, which is the data that exists.
2. **The workspace developer** — "my dev server threw; show me the trace." Answered by the workspace
   lens, which has no data until the parked sender ships.
3. **Everyone, once** — "what *is* this thing?" A buffer that empties on restart is a surprising
   product, and the UI's first job is to say so before anyone concludes it is broken.

Reader 1 is who the first release serves. Reader 2 gets a first-class, empty, and *honestly
labelled* place to stand, so that when the sender lands the screens light up with no UI change.
Reader 3 is served by the ephemerality band in §5, which is not a dismissible banner.

---

## 3. ⚖1 — the central decision: does the backend gain a read surface?

**The question.** The five existing endpoints can only address workspace buckets, and there are
none. All real telemetry is in a bucket that is unaddressable by construction (§1.2). Do we add
read endpoints to qits-observability, or ship a UI over what exists?

**Option A — ship over the existing surface.** Five screens, each with a repository and workspace
picker, each permanently empty, each with an empty state explaining that workspace dev servers do
not export yet. Zero backend risk. It is also a page that will not show a single row until an
unrelated, unscheduled workstream lands.

**Option B — add the read surface.** Six additions to one service that owns no tables, has no
migrations, and whose whole query layer is 156 lines over an in-memory map. The work is measured in
§4 and it is small. It makes the platform's own telemetry visible on day one, and the workspace lens
still works unchanged when its producer arrives.

**Recommendation: B.** The cost is genuinely low — this is the one service where adding a read
endpoint costs a method on `TelemetryQueryService` and a JAX-RS annotation, with no schema, no
migration and no persistence question. And the alternative is not "a smaller UI", it is "a UI with
no data", which is not a smaller version of the same thing.

**What B explicitly does not include:** no persistence, no retention, no second store, no history
for metrics, no dev-server sender. The store stays ephemeral and stays bounded exactly as it is.

---

## 4. The backend additions (workstream CG)

All in `services/qits-observability`. Every query goes through `TelemetryQueryService` so the MCP
tools and the REST twins keep answering identically — that is the repo's stated rule
(`TelemetryQueryService.java:20-22`) and it is worth keeping.

### 4.1 ⚖2 — how a caller names a bucket

`repositoryId` + `workspaceId` cannot name `_unscoped`. Three ways out:

- **(a) `?source=<opaque key>`** — the sources listing returns a key; the caller passes it back
  verbatim. Additive, explicit, and it survives any future bucketing change without another
  parameter.
- **(b) `?scope=unscoped`** — a boolean-ish flag beside the existing pair. Cheapest, but it hard-codes
  the one special bucket into the wire, and a second special bucket needs a third spelling.
- **(c) Re-key the bucket so the existing pair reaches it** — e.g. `_service/<name>`, which
  `key(repoId, workspaceId)` would happily produce from `repositoryId=_service&workspaceId=nginx`.
  It works, it needs no new parameter, and it is a lie: the caller is passing a service name in a
  field named `workspaceId`.

**Recommendation: (a).** One new optional parameter on all five existing endpoints, mutually
exclusive with the pair. When `source` is present the pair is ignored; when both are absent the
behaviour is unchanged (an empty bucket, as today), so nothing existing breaks and the MCP tools —
which build the pair from connection scope (`TelemetryMcpTools.java:140-151`) — need no change at
all. (c) is recorded here as the weighed-and-declined shortcut so nobody rediscovers it as a
feature.

### 4.2 ⚖3 — does the store re-bucket unscoped telemetry by service?

Today ten services share one bucket, and the two-tier fairness the store advertises is defeated
(§1.4). Bucketing unscoped records by `service.name` — key `_service/<name>`, falling back to
`_unscoped` when even that is absent — is about five lines in `bufferFor`
(`TelemetryStore.java:230-238`) and restores per-producer fairness: a chatty gateway can no longer
evict qits-cd's spans.

Against it: it changes ingest behaviour, and ingest is the one path here with a native-image failure
mode. It also multiplies the worst-case retained set — ten buckets at 5,000 spans is 50,000 spans,
roughly 100 MB by §1.4's arithmetic, which finally makes the 64 MiB global ceiling load-bearing.
That is arguably correct (the ceiling exists for exactly this) but it is a live behaviour change on
a running platform.

**Recommendation: yes, re-bucket — and lower `max-spans-per-workspace` to 2,000 in the same change**
so the worst case lands near 40 MB and stays under the ceiling by count as well as by bytes. The
fairness argument is the store's own, the change is small and testable in the existing plain-JUnit
`TelemetryStoreTest`, and it makes `?source=` a genuinely useful axis rather than a single value.

If this is declined, everything else in this plan still works — the UI shows one `_unscoped` source
with a per-service filter (§4.4) instead of one source per service. Nothing downstream is
conditional on it.

### 4.3 `GET /observability/api/telemetry/store` — the buffer's own state

The ephemerality screen cannot be honest without this, and none of it is exposed today.

```json
{
  "startedAt": "2026-08-01T09:24:20Z",
  "totalBytes": 18234112,
  "maxTotalBytes": 67108864,
  "caps": { "spansPerSource": 2000, "logsPerSource": 10000, "metricSeriesPerSource": 500 },
  "sourceCount": 10,
  "evictedSpans": 41233,
  "evictedLogs": 0,
  "droppedMetricSeries": 0
}
```

`totalBytes` exists already (`TelemetryStore.java:209-211`) and is exposed nowhere. `startedAt` and
the three counters do not exist and must be added: a field set in `@PostConstruct`, and increments in
the two eviction paths (`evictOldestSpan` at `:251-261`, the log removal at `:302`, the global
ceiling loop at `:269-307`) and the metric-cap drop at `:119-127`. Keep them plain `AtomicLong`s —
`TelemetryStoreTest` is plain JUnit with no CDI and must stay that way
(`services/qits-observability/CLAUDE.md`, "The buffer").

`evictedSpans > 0` is the single most important number on this UI: it is the difference between "the
buffer is showing you everything" and "the buffer is showing you what survived".

### 4.4 `GET /observability/api/telemetry/sources` — what is in there

```json
{ "sources": [
  { "key": "_service/qits-ci",
    "kind": "SERVICE",
    "label": "qits-ci",
    "repositoryId": null, "workspaceId": null,
    "services": [ { "name": "qits-ci", "spans": 1841, "logs": 92, "metricSeries": 61 } ],
    "spans": 1841, "logs": 92, "metricSeries": 61, "bytes": 3910224,
    "oldestReceivedAt": "2026-08-01T13:02:11Z", "newestReceivedAt": "2026-08-01T15:40:02Z" },
  { "key": "repo-1/wt-9", "kind": "WORKSPACE", "label": "wt-9",
    "repositoryId": "repo-1", "workspaceId": "wt-9", … }
] }
```

`kind` is `SERVICE` | `WORKSPACE` | `UNSCOPED`. The `services` breakdown is what lets the UI offer a
per-service filter whether or not ⚖3 is taken. `oldest`/`newestReceivedAt` are what make "your
window excludes what is buffered" a distinguishable empty state.

This is a snapshot walk over `buffers` under each bucket monitor — the same shape as the existing
snapshot accessors (`TelemetryStore.java:163-206`).

### 4.5 `GET /observability/api/telemetry/traces` — the trace list

```json
{ "traces": [
  { "traceId": "4bf92f…", "rootName": "POST /ci/api/events/post-receive",
    "rootService": "qits-ci", "services": ["qits-ci","qits-artifacts"],
    "startEpochNanos": 1..., "durationMs": 812,
    "spanCount": 14, "errorSpanCount": 1, "hasException": true }
], "total": 340, "truncated": true }
```

⚖4 lives here. The alternative is deriving the list in the browser from
`slow-spans?thresholdMs=0&sort=recent` and grouping by `traceId` — which needs **no backend at
all**. Measured against it: that pulls up to the full span cap over the wire to render fifty rows,
and the store already maintains `spansByTrace` per bucket (`TelemetryStore.java:77`), so the grouping
is free on the server and expensive in the client.

**Recommendation: add the endpoint.** It is roughly twenty lines over an index that already exists,
and it is the difference between a 1-request screen and a several-megabyte one. Record the
client-side derivation as the fallback if CG has to be cut.

`rootName` is the span whose `parentSpanId` is empty; if none is buffered (the root was evicted or
belongs to another bucket), it is the earliest span, flagged `"rootMissing": true` — that condition
is common in a bounded buffer and the UI must say so rather than showing a plausible-looking wrong
root.

### 4.6 Widenings on the existing five

- **`?service=`** on `errors`, `slow-spans` and `metrics`. `logs` already has it
  (`WorkspaceTelemetryController.java:96`, `TelemetryQueryService.java:131`); the other three are one
  `.filter()` each. Without this, a single-bucket world has no way to look at one service.
- **`?limit=`** on `errors`, `slow-spans`, `logs` and `traces`, with `{ items…, total, truncated }`
  in the envelope. Default 200. Today every response is the whole buffer (§1.1), which no screen can
  budget against.
  **Coordination point:** qits-events has a shipped bug where `?limit=` is accepted and ignored and
  the whole history comes back (handoff.md, "Operational truths"). Do not reproduce it here — and if
  the events-UI plan proposes fixing it there, the two should agree on one envelope spelling before
  either ships. This plan proposes `total` + `truncated`; it does not claim the right to settle it
  for qits-events.
- **`?sort=recent|duration`** on `logs` is *not* proposed. Logs are oldest-first by construction
  (`TelemetryQueryService.java:137`) and a tail wants that order; the UI reverses for display if it
  wants newest-first, at zero cost.

### 4.7 ⚖5 — do the new queries become MCP tools?

The README's rule is that humans and agents see identical answers. The new queries break that rule
in one direction: `sources`, `store` and a platform-wide `traces` list are **not workspace-scoped**,
and the MCP surface's entire safety property is that it is. `requireScope()` fails closed without
both a repository and a workspace (`TelemetryMcpTools.java:140-151`), and
`TelemetryToolFilter` hides the tools from any session not narrowed that far
(`TelemetryMcpTools.java:33-36`). A tool that lists every source on the platform has no scope to
check and would be a cross-project leak by design.

**Recommendation: no new MCP tools.** Add the new methods to `TelemetryQueryService` (so the code
is shared), add `service` and `limit` arguments to the existing five tools where they are
scope-safe, and record in `TelemetryMcpTools`' javadoc *why* the listing queries are REST-only. The
"identical answers" rule holds for everything an agent is allowed to ask.

### 4.8 What CG must not do

No entity, no datasource, no Flyway, no retention, no second store — the repo's own rule
(`services/qits-observability/CLAUDE.md`, "Adding a dependency on another context"; `README.md:93-101`).
No change to `OtelReceiverResource` or `TelemetryDecoder` beyond what ⚖3 requires. No dev-server
sender. No `PublicPaths` change — the new routes are authenticated like the existing five.

---

## 5. Surfacing the ephemerality honestly

The platform's UI culture is that an empty state names its reason, and it is enforced in code:
`app-empty` takes `input.required<string>()`, so a component physically cannot render "nothing here"
without saying why (`frontends/qits-spa-ci/src/app/ui/empty.ts:10-24`). The register to match is
already on the platform — "No tags point at anything in this image. That is not the same as the image
being unknown — an image that does not exist answers the same way"
(`frontends/qits-spa-artifacts/src/app/image/image-page.html:68-69`).

A store that empties on restart has more reasons than most, and collapsing them into one "No data" is
the failure mode this section exists to prevent.

**The source strip.** A persistent band under the chrome on every screen, not dismissible:

> **Live buffer.** Held in qits-observability's memory since **09:24 today** (6 h 18 m). A restart
> empties it. Nothing here is written to disk.
> `qits-ci` · 1,841 spans · 92 logs · 61 series · **41,233 spans evicted**

The eviction count is shown whenever it is non-zero, in the same weight as the rest — not as a
warning, because eviction is the design working, and not hidden, because it changes what the numbers
below mean.

**The five empty states, which must stay distinguishable:**

| Condition | What the screen says |
|---|---|
| Source has never received this signal | "No spans have arrived from `qits-ci`. It exports traces, so either it has been idle, or its spans have all been evicted." |
| Process restarted recently (`startedAt` within the last few minutes) | "The buffer was emptied 3 minutes ago when qits-observability restarted. Anything from before that is gone." |
| The window excludes what is buffered (`sinceMinutes` set, `newestReceivedAt` older) | "Nothing in the last 15 minutes. The buffer holds records up to 2 h old — clear the window to see them." |
| Eviction is active and the answer is truncated | "Showing 200 of 1,841. The buffer has dropped 41,233 older spans at its cap." |
| Workspace lens, no workspace has ever exported | "No workspace has exported telemetry. Workspace dev servers do not send OTLP yet — the sender is a known gap (qits-observability README §164-173). Workspace telemetry will appear here without any change to this page." |

That last row is the honest form of the parked item: it names the gap, points at where it is
recorded, and promises nothing about when.

**The trace-not-found case.** `traces/{id}` answers 200 with an empty trace for an id that never
existed *and* for one that was evicted (§1.1). The UI cannot tell them apart from that response
alone, and must not pretend to: "No spans buffered for this trace. It may have been evicted, or the
id may be wrong." If the source's `evictedSpans` is zero, the second half is dropped.

**No fake freshness.** Timestamps render as absolute time with a relative suffix
("15:40:02 · 2 m ago"), never a bare "2 m ago" — in a buffer whose contents may predate your last
page load by hours, relative-only time invites the wrong conclusion.

---

## 6. Live behaviour: polling, and why

Measured in §1.5: no stream exists, the CDI hint has no observers and cannot cross a process
boundary, and it is silent for unscoped telemetry anyway.

The platform's own rule decides the rest. `qits-spa-workspaces` is the one SPA with a live channel
and it states the division plainly: "**Nothing here polls.** That is a rule and not a tendency: the
explorer screens poll because they have no channel, and this page has one"
(`frontends/qits-spa-workspaces/src/app/api/workspace-events.ts:52-53`). Observability has no
channel. It polls.

**⚖6 — should CG add SSE to qits-observability instead?** The machinery is half-present: the store
already fires a per-scope hint. Against it: the hint fires only for scoped workspaces
(`TelemetryStore.java:149-160`), which is 0% of today's data, so an SSE channel wired to it would be
a permanently silent stream — the worst possible outcome, because it *looks* live. Making it fire
for every bucket is a change to the hot ingest path for a benefit polling already delivers.

**Recommendation: poll. Do not add SSE.** Record the hint's scoped-only limitation in
`TelemetryChanged`'s javadoc so a future reader does not wire a stream to it and spend a day
wondering why nothing arrives.

**The mechanism is the platform's, unchanged.** The
`shouldPoll()` / `syncPolling()` / `stopPolling()` / `onVisibilityChange()` quartet over a plain
`setInterval`, `DOCUMENT` injected, the listener removed and the interval cleared in
`DestroyRef.onDestroy` — `frontends/qits-spa-ci/src/app/run/run-page.ts:170-175, 271-299` is the
copy source, and `frontends/qits-spa-cd/src/app/deployments/deployments-page.ts:352-381` is the
second witness. An exported `POLL_INTERVAL_MS` constant carries its own justification comment, as
`run-page.ts:32-41` does. An in-flight guard prevents overlap; `syncPolling()` is re-called in the
poll's `finally`. No rxjs `interval`/`timer` — there is none anywhere on this platform.

Relative timestamps come from `tickingNow()` (`frontends/qits-spa-ci/src/app/ui/ticker.ts:13-18`), a
1 s clock signal that costs no requests — "re-reading a run to learn what a subtraction already knows
would turn every open row into traffic" (`ticker.ts:6-8`). Copy it; the ages on this UI change every
second and none of them is worth a request.

**The polling contract:**

- The **source strip** refreshes `store` + `sources` every **10 s**. That is the app-level poll and
  it is the only one that always runs.
- The **active screen** refreshes its own single request every **10 s**, except:
  - **Trace detail does not poll.** A trace is a finished thing; a manual refresh control covers the
    case where late spans arrive.
  - **Logs poll every 5 s while "Follow" is on**, and not at all when it is off. Follow defaults on
    and switches itself off the moment the user scrolls up.
- **All polling stops when `document.hidden`** and does one immediate catch-up refresh on
  `visibilitychange` back to visible. A backgrounded tab costs zero requests.
- A poll that errors backs off to 30 s and shows a stale-data marker on the strip rather than
  clearing the screen. Data you know is 40 s old beats an empty page.

Steady-state cost on a visible tab: **2 requests / 10 s** for the strip plus **1 / 10 s** for the
screen, or **1 / 5 s** on Logs with Follow on. Peak is 4 requests in 10 s. All of it against an
in-memory map in a process with no database.

---

## 7. The screens

Route base `/observability/`, children of `QitsMainLayout` exactly as the shell's comment
anticipates (`frontends/qits-spa-observability/src/app/app.routes.ts:9-11`).

**URL state.** The selected source lives in `?source=` on every route — it is a request-costing
level, so it is URL state by the house rule, and every screen is a shareable link. `?service=`,
`?since=`, `?q=`, `?sort=` and `?threshold=` follow the same rule. Nothing costing a request hides
in component state.

**Shell cost: 2.** `GET /telemetry/store` and `GET /telemetry/sources`, held app-wide by one
injectable and shared by every screen. Every screen below adds exactly one request on top of it, so
**no page in this SPA costs more than 3 requests cold**. Assert it in the specs, not just here.

### 7.1 Overview — `/` — **2 requests (shell only)**

The buffer's own state, and the source list. Per source: kind, label, per-signal counts, per-service
breakdown, and the age span of what it holds. Selecting a source sets `?source=` and the header
strip follows you everywhere after.

This is the landing page on purpose. It is the screen that answers "is anything arriving at all",
which on a platform whose telemetry was invisible until now is the first question, and it is where
the ephemerality statement is made in full rather than in a one-line band.

### 7.2 Traces — `/traces` — **+1** (`GET /telemetry/traces?source=&service=&sort=&limit=`)

A list, newest-first by default, with the `sort=recent|duration` lens the backend already
distinguishes (§1.1) exposed as a two-position toggle: **Recent** ("what just happened") and
**Slowest** ("what is slow"). Rows: root span name, root service, duration, span count, service
count, error marker. `rootMissing` renders as a muted "(root not buffered)" beside the name.

A duration threshold control maps to `slow-spans`' `thresholdMs` semantics; default 0 (everything),
because in a buffer this short "everything" is a reasonable list.

### 7.3 Trace detail — `/traces/:traceId` — **+1** (`GET /telemetry/traces/{traceId}?source=`)

The waterfall, and the screen this whole feature is for.

**The waterfall is hand-rolled CSS, and this is not a ⚖.** The data is
`parentSpanId` + `startEpochNanos` + `durationMs` (§1.8); the render is a nested list where each row
carries `left: X%` and `width: Y%` computed from the trace's own start and span. That is a `div`
with two inline percentages. Every chart library on offer would be a new dependency in a repo that
has none — and §1.9 measured that *no* SPA on this platform has one, and that the only place a chart
was ever considered, it was refused in writing. SVG is not needed either, since nothing here is a
curve. Zero new dependencies, and the streak holds.

Expansion chevrons come from `frontends/qits-spa-artifacts/src/app/ui/page.css:154-174` — the drawn
border-rotate form, not the `▸`/`▾` glyphs, which is the shape the handoff's open tofu item is
waiting for.

Two rendering rules the data forces:

- `durationMs` is integer milliseconds, so sub-millisecond spans are 0 and would render as invisible
  slivers. Floor every bar at 2px and show the true value in the label.
- Spans of one trace can be evicted independently (the eviction path removes from `spansByTrace`
  individually — `TelemetryStore.java:251-261`), so a trace can arrive with holes. A span whose
  `parentSpanId` names no buffered span is drawn at the top level with an explicit
  "parent not buffered" marker, never silently re-parented.

Selecting a span opens a detail pane: kind, status, `statusMessage`, attributes, and the `events`
list with `exception.stacktrace` rendered in a monospace block. Below the waterfall, the correlated
logs the same endpoint already returns, in time order, each anchored to its span.

### 7.4 Errors — `/errors` — **+1** (`GET /telemetry/errors?source=&service=&sinceMinutes=&limit=`)

The `TelemetryErrorGroupDto` shape rendered as-is: one card per trace, its error spans and its ERROR
logs together. Each card links to the waterfall. This is the REST twin of the `telemetryErrors` MCP
tool and it should look like what that tool returns, because an agent and a human debugging the same
failure should be looking at the same thing.

Groups with an **empty** `traceId` (uncorrelated evidence, §1.8) render as one "Not correlated to a
trace" card at the bottom with no link.

### 7.5 Logs — `/logs` — **+1** (`GET /telemetry/logs?source=&service=&query=&sinceMinutes=&limit=`)

A tail. Severity chip from `severityNumber` (≥17 is ERROR — `StoredLog.java:23-24`), service,
timestamp, body. Substring search maps to `?query=`, which the backend already matches
case-insensitively over body **and** severity text (`TelemetryQueryService.java:132-136`) — say so in
the field's placeholder, because searching "error" matching a severity is surprising otherwise.

Trace-correlated rows carry a link to the waterfall. Follow mode per §6.

### 7.6 Metrics — `/metrics` — **+1** (`GET /telemetry/metrics?source=&service=&name=`)

A table, grouped by metric name, one row per series with its attribute set as chips and the latest
value. `unit` in the column header, `description` as the group subtitle, `GAUGE`/`COUNTER` as a
badge.

**No chart, and §1.6 is why:** the store keeps one point per series and replaces it in place, so
there is no series to draw. The screen says so once, in the group header area: "Latest value per
series. The buffer keeps no history, so there is nothing to plot." That is the honest version of a
missing feature.

⚖7 sits here: a client-side sparkline could be accumulated from successive polls — ten minutes of
polling gives sixty points. **Recommendation: no.** It would be a chart of "what this browser tab
happened to observe", it would vanish on navigation, and it would be the first thing on this page
that is not a fact the server can confirm. Named so it is a decision rather than an omission.

---

## 8. Workstreams (one Opus 5 agent each)

Letters start at **CG** — CB–CF are reserved by the events-UI design running in parallel.

One reading hazard, stated once: **the workstream letter `CI` is not qits-ci.** The sequence lands
on it and renaming it would break the platform's letter ordering. In any report, write it as
"workstream CI" or the reader will parse it as the CI service.

Ship step, unless a workstream says otherwise: `./mvnw verify` or `npm run test` green, then push
both remotes where both exist. **`qits-spa-observability` has only GitHub `origin`** (§1.7); do not
try to push it to the platform host, and do not create the repository there as a side effect of this
work.

### CG — the read surface (repo: `services/qits-observability`)

Lands: `startedAt` and the three eviction counters on `TelemetryStore`; the `sources()` snapshot;
`GET /telemetry/store`; `GET /telemetry/sources`; `GET /telemetry/traces`; `?source=` on all five
existing endpoints; `?service=` on errors / slow-spans / metrics; `?limit=` with
`{total, truncated}` on the four list endpoints; ⚖3's re-bucketing if taken; regenerated
`docs/openapi.yml`.

Must not touch: any persistence question, `OtelReceiverResource`'s decode path beyond ⚖3, the MCP
tool set (§4.7), `PublicPaths`, or the tuning defaults except as ⚖3 specifies.

Verifies: `TelemetryStoreTest` stays plain JUnit and gains the eviction-counter and re-bucketing
cases; `WorkspaceTelemetryControllerTest` gains one case per new endpoint and per new parameter,
including `?source=` reaching the unscoped bucket and `?limit=` setting `truncated`;
`OpenApiSchemaExportTest` regenerated and the diff committed; **`./mvnw verify -Dnative` green** —
the native build is this repo's shipping form and `-Dnative` also runs `OtelReceiverIT`, so extend
that IT to read the new endpoints back after an ingest.

Blocking pre-flight: confirm on the live platform that the `_unscoped` bucket is non-empty before
building against it — post a synthetic OTLP body with no `qits.*` attributes and read it back
through the new `?source=` addressing in the same session. If it comes back empty, **stop and
report**: that would mean the exports are not arriving and §1.2 is wrong.

### CH — SPA foundation and Overview (repo: `frontends/qits-spa-observability`)

The route table's `children: []` finally gets children. Everything else mounts into this.

Lands, in this order:

1. **`app.config.ts` gains its missing third provider** — `provideHttpClient(withFetch())`, per
   §1.9. Add `app.config.spec.ts` asserting the Fetch backend, copied from
   `frontends/qits-spa-ci/src/app/app.config.spec.ts`.
2. **`src/app/ui/{loadable,async,empty,format,ticker}.ts` copied verbatim** from the nearest sibling
   — `qits-spa-artifacts` for `page.css`'s drawn chevron, `qits-spa-ci` for the rest. Do not
   promote any of them to the library; do not invent variants.
3. **`src/app/api/{api-base,dto,telemetry-api}.ts`** — the token exactly as §1.9 records it,
   hand-written DTO interfaces matching CG's shapes, one injectable, `HttpClient` +
   `firstValueFrom`, every id `encodeURIComponent`'d into the path.
4. **The app-level source service** holding `store` + `sources`, with the §6 polling quartet and the
   `document.hidden` pause.
5. **The source strip** with the ephemerality band, and the **Overview** screen.
6. **`app.routes.ts`** rebuilt to the §1.9 shape, including the missing `**` → `NotFound` inside the
   layout's children.
7. **`eslint.config.js` + a `lint` script**, and a `.config/qits/ci-post-receive.yml` copied from
   spa-ci with the prefix adjusted. Note the repo has **no platform-host origin** (§1.7), so this
   pipeline does not run until one exists; land it anyway so it is ready and so the omission is
   visible rather than silent.
8. **README route bullets stating each screen's request cost**, in the register of §1.9.

Must not touch: `QITS_NAV_LINKS` or anything in `libs/qits-spa-ui-components`. Observability already
has its nav entry (`libs/qits-spa-ui-components/projects/qits-spa-ui-components/src/lib/main-layout.ts:34`)
and it is not this feature's to edit. Keep every new component app-local — the workspace-detail
plan's Decision 3 is the precedent, and the events UI is being designed in parallel against the same
library. No `httpResource()`, no rxjs `interval`/`timer`, no lazy route chunks — §1.9.

Verifies: the shell's 2-request budget asserted in a spec with `HttpTestingController` and
`afterEach(() => http.verify())`, not merely written down, and with the **negative** assertion the
platform values — that an unselected source costs no screen request; a fake-timer spec proving the
poll pauses on `document.hidden` and catches up on `visibilitychange`; a spec per empty-state row in
§5's table proving they are distinguishable.

### CI — Traces and the waterfall (repo: `frontends/qits-spa-observability`, after CH)

Lands: the trace list with the Recent/Slowest lens and the threshold control, all in `?query`
params; the waterfall; the span detail pane with `exception.stacktrace`; the correlated log rail;
the `rootMissing` and "parent not buffered" markers.

Must not: add any charting dependency. The bars are CSS percentages (§7.3). Draw the chevron in CSS,
as the platform's other explorers do.

Verifies: a spec with a fixture trace containing an orphaned span, proving it renders at top level
with the marker and is not silently re-parented; a spec proving a sub-millisecond span still has a
visible bar; the per-screen budget.

### CJ — Errors and Logs (repo: `frontends/qits-spa-observability`, after CH, parallel with CI)

Lands: the errors screen including the empty-`traceId` group; the logs tail with search, service
filter, severity chips, follow mode and its scroll-up auto-off, and the trace links.

Verifies: a fake-timer spec for follow mode's 5 s cadence and its auto-off; a spec proving the
`?query=` placeholder claim (that it matches severity text as well as body) is true against the real
response shape.

### CK — Metrics, and the honesty pass (repo: `frontends/qits-spa-observability`, after CH)

Lands: the metrics table; the "no history, nothing to plot" statement; and the sweep that makes §5's
empty-state table true on every screen the other workstreams built, including the absolute+relative
timestamp rule and the stale-data marker.

Verifies: every row of §5's table has a spec somewhere in the repo after this lands. This workstream
owns that being true.

### CL — embed and ship (repo: `services/qits-observability`, after CI/CJ/CK)

Lands: the `service/src/main/webui` gitlink bumped to the finished SPA; a `PackagedSurfaceIT`
matching the qits-ci / qits-cd / qits-projects / qits-events precedent — that `/observability/`
serves the SPA, that a deep link like `/observability/traces/abc` survives a reload through
`enable-spa-routing`, and that `/observability/api/nope` answers a machine answer rather than
`200 text/html`.

Verifies: the deploy chain end to end — push qits-observability to both remotes, watch the CI run
build the submodule and publish the image, watch qits-cd deploy it, then **hard-reload** before
judging anything (`index.html` is served `immutable, max-age=86400`; the gateway-level fix is
recommended and unowned, per the handoff).

### Ordering and cost

CG is the gate: CH–CK all read endpoints it defines. CH is the second gate; CI, CJ and CK are
parallel after it. CL is last.

Honestly: CG is a focused session on a small service with no database. CH is the largest frontend
piece because it builds the transport, the polling discipline and the honesty machinery that the
other three merely use. CI is the largest *screen*. CJ and CK are moderate. CL is short but must not
be skipped — a SPA that is not embedded is not deployed.

---

## 9. Coordination with the events UI (CB–CF)

Named, not resolved. Both plans were written in the same session against the same platform.

1. **`@qits/ui-components` stays untouched by both.** Each SPA keeps its list, table, empty-state and
   status-chip components app-local. If either plan later wants to promote something, the other must
   be told first — a shared-library change lands in seven consumers and neither plan budgets for
   that. The `QITS_NAV_LINKS` entry for each already exists.
2. **The `?limit=` envelope.** qits-events currently accepts `limit` and ignores it. This plan
   proposes `{ items…, total, truncated }` for qits-observability's new list endpoints (§4.6). If the
   events plan touches its own limit handling, one spelling should win. This plan does not claim to
   settle qits-events' surface.
3. **Both SPAs poll and neither has a stream.** The `document.hidden` pause, the error backoff and
   the stale-data marker are the same discipline in both. Keeping them identical in *behaviour* is
   worth more than sharing the code.
4. **Trace ids and event ids are different identifiers.** A qits-events row and an OTLP trace are not
   correlated today and nothing in either plan makes them so. If cross-linking is ever wanted it is
   its own decision, and it needs a producer to stamp one id into the other's payload.
5. **Both ship through a gitlink bump in their owning service**, and both are affected by the
   unowned gateway `index.html` cache header. Whoever fixes it fixes both.

---

## 10. The decisions ⚖

| | Decision | Recommendation |
|---|---|---|
| **⚖1** | Add a read surface to qits-observability, or ship over the existing five endpoints? | **Add it.** The alternative is a UI with no data, not a smaller UI. §3. |
| **⚖2** | How does a caller name a bucket the `repositoryId`/`workspaceId` pair cannot reach? | **`?source=<opaque key>`.** Additive, honest, survives ⚖3 either way. §4.1. |
| **⚖3** | Re-bucket unscoped telemetry by `service.name`? | **Yes, and lower the span cap to 2,000.** Restores the fairness the store advertises and currently cannot deliver. Everything downstream works without it. §4.2. |
| **⚖4** | Trace list on the server, or grouped in the browser from `slow-spans?thresholdMs=0`? | **Server.** ~20 lines over an index that already exists, versus megabytes over the wire per page view. §4.5. |
| **⚖5** | Do the new queries become MCP tools? | **No.** The listing queries have no scope to check, and scope is the MCP surface's entire safety property. §4.7. |
| **⚖6** | Add SSE to qits-observability instead of polling? | **No.** The existing hint is silent for 100% of today's data; an SSE channel over it would look live and never fire. §6. |
| **⚖7** | Accumulate a client-side metric sparkline from successive polls? | **No.** It would chart what one browser tab happened to see and vanish on navigation. §7.6. |

---

## 11. Verification

**Live reads used to write this document**, all through the gateway at `localhost:8080` and all
GETs: the five telemetry endpoints with and without scope parameters; `/observability/` and
`/observability/q/health` and `/observability/q/openapi`; `/projects/api/projects` and its
`/repositories`; `/workspaces/api/workspaces?repositoryId=…` for several repositories;
`/artifacts/git/{qits-observability,qits-spa-observability,qits-spa-ci}/info/refs`. Plus
`docker ps`, `docker inspect` of the observability and ci containers' environments, and `docker logs`
for the installed-features line and the absence of export errors.

**What could not be measured, and must be before CG is trusted.** Nothing today can report how much
telemetry is actually in the buffer, because that is precisely what §4.3 adds. The estimates in §1.4
are arithmetic over `TelemetrySizeEstimator`, not observation. CG's blocking pre-flight exists to
close this: the first thing the new `/telemetry/store` and `/telemetry/sources` endpoints do is turn
§1.2 and §1.4 from arguments into readings. **If the readings disagree with §1.4 — if the byte
ceiling is reached before the count caps — ⚖3's cap recommendation changes and CG should stop and
report.**

**Unit tests.** Vitest on jsdom through `@angular/build:unit-test`; no vitest config file, matching
every other SPA here. `HttpTestingController` with `afterEach(() => http.verify())` for every
transport, `RouterTestingHarness` + `provideLocationMocks()` for the routes, fake timers for every
poller, `app.config.spec.ts` asserting the Fetch backend. Per-screen budgets asserted, not written
down.

**There is no E2E framework on this platform** — no Playwright, no Cypress in any frontend's
`package.json`. "Browser pass" below means a scripted manual pass driven with the DevTools or
Playwright MCP tools, which is what the other frontend plans mean by it.

**Backend tests.** `TelemetryStoreTest` and `TelemetryDecoderTest` stay plain JUnit with no Quarkus
boot — the repo's rule. `@QuarkusTest` for the controller. `OpenApiSchemaExportTest` regenerated and
its diff committed. `./mvnw verify -Dnative` green, with `OtelReceiverIT` extended to read the new
endpoints back after an ingest — protobuf decoding is the class of defect that is green on the JVM
and broken in the image, and this repo exists partly to catch it.

**Packaged surface.** CL's `PackagedSurfaceIT`, per §8.

**The browser pass**, through the real gateway, hard-reloading first:

1. Open `/observability/` with no source selected. The ephemerality band states a real start time
   and a real uptime. At least one source is listed with non-zero counts. *If it is empty, the
   feature has no data and something in CG regressed.*
2. Select a service source, open Traces on **Recent**, then flip to **Slowest** and confirm the order
   genuinely changes — that proves `sort=` is reaching the backend and not being silently coerced.
3. Open a trace with more than one service in it and confirm the waterfall nests, that a bar's width
   is proportional, and that a sub-millisecond span is still visible.
4. Produce a real error span and confirm it reaches Errors within one poll interval, with its trace
   reachable. A 404 from JAX-RS is **not** reliably an ERROR-status span, so do not depend on one:
   the dependable path is `TelemetryFixtures.errorTraceRequest(…)` posted to
   `/observability/api/otel/v1/traces` with no `qits.*` resource attributes — the same body
   `OtelReceiverIT` uses. Note the fixture also proves the trace-detail waterfall's exception pane,
   since it carries a real `exception` event with a stack trace.
5. Search Logs for a substring that exists only in a severity text, and confirm it matches — the
   placeholder claims it does.
6. Background the tab for a minute and confirm in DevTools that request count stops, then that one
   catch-up request fires on return.
7. Watch the buffer empty. **CL's own deploy is the restart** — qits-cd replaces the container, so
   reload after the deployment goes ACTIVE rather than restarting anything by hand. The buffer is
   empty, the band says so with the new start time, and **no screen looks broken**, which is the
   whole point of §5. (If a deliberate restart is wanted outside a deploy, `docker restart` of the
   single observability container is enough. Do not reach for `qits-local-up.sh`.)

**Traps that apply to every push here.** A push to `main` on the platform host needs
`-o qits.token=local-dev`. `qits-spa-observability` has no platform-host remote — GitHub only. The
service's gitlink is hidden from `git status` and `git diff` by `ignore = all`, so confirm a bump
with `git ls-tree HEAD service/src/main/webui`. And a green CI run with no deployment row is the
qits-cd write-wedge, not your change.
