# The CI and CD explorers: reading the platform through its projects

Two read-only data-exploration UIs, one per service. Everything qits-ci and qits-cd hold is
system-created — a pipeline runs because someone pushed, a deployment happens because a pipeline
went green — so there is no CRUD here and no forms. There are two trees and one detail page.

Both trees are **project-centric**: the spine is qits-projects' projects and their repositories,
and each service is rendered through that lens. But `/ci/` and `/cd/` stay top-level segments,
because each service serves its own client under its own segment and that is the whole shape of
the platform. Project-centric is a *reading order*, not a mount point.

This document designs both. **Implementation in this feature is the ci half only** — the workstreams
below build qits-spa-ci and the qits-ci gaps it needs. The cd screens are designed here, complete,
and sequenced into a later phase; the serving surface underneath them (a qits-spa-cd skeleton at
`/cd/` via Quinoa) is in flight as separate groundwork and is *not* part of this feature's
workstreams either.

## What exists today (the seams this builds on)

- **Every SPA on the platform is an empty skeleton.** All seven are byte-identical: an
  `app.ts` that renders `<router-outlet />`, an `app.routes.ts` of exactly
  `[{ path: '', component: QitsMainLayout, children: [] }]`, and a two-provider `app.config.ts`.
  There is **no HTTP code anywhere in `frontends/`** — no service class, no `HttpClient`
  injection, no generated client, no polling, no websocket. qits-spa-ci will be the platform's
  first SPA with real pages, and the first with a network call.
- **`@qits/ui-components` 0.0.3** exports four components and one const: `QitsButton`,
  `QitsBadge` (tones `neutral|info|success|warning|danger`), `QitsCard` (with a
  `[qitsCardActions]` projection slot), `QitsMainLayout`, and `QITS_NAV_LINKS` (seven entries,
  `/ci/` among them). No table, no spinner, no empty-state, no design tokens. `QitsMainLayout`
  has **no `<ng-content>`** — it is a route component whose children render into its internal
  outlet, which is exactly how the skeletons already mount it.
- **The idioms are settled even though the pages are not**: Angular 21.2 (never 22 — host node is
  22.22.0), zoneless, standalone, `OnPush` everywhere, signals with `inject()` in field
  initialisers, `@if`/`@for`, `async`/`await` mapped into a state signal, vitest on jsdom, prettier
  at `printWidth: 100`, `app-` selector prefix for an application's own components against
  `qits-` for the library's.
- **qits-ci already serves qits-spa-ci**: submodule at `service/src/main/webui`, Quinoa 2.8.2,
  `ui-root-path=/ci`, `enable-spa-routing=true`, `ignored-path-prefixes=/api,/q,/daemon`,
  `baseHref: "/ci/"`. The Dockerfile consumes a pre-built `dist/` and fails loudly without it;
  the CI recipe inits the submodule and runs `npm ci && npm run build` before `docker build`.
  Nothing about the serving surface needs to change to give it pages.
- **The gateway needs nothing.** `/ci` and `/cd` are both in `QitsService`, both have
  `proxy-hosts` entries in `docker-compose.qits.yml`, both are forwarded verbatim with no path
  rewriting, and both sit behind the session policy (`PublicPaths` deliberately exempts neither).
  A browser that loaded `/ci/` through the gateway carries a session cookie to `/projects/api/…`
  in the same origin — which is what makes cross-service reads from the browser work with no
  machine token and no CORS.

## The finding that shapes everything: what `repoId` actually is

The brief's join surface — "everything references `Repository.id` as a plain String" — is true,
and it is also less useful on the live platform than it sounds. Traced end to end:

- `RepositoryService` assigns `repo.id = UUID.randomUUID().toString()` and clones the bare origin
  to `<data-dir>/<repo.id>/origin`.
- qits-artifacts' git host serves `<data-dir>/<repoId>/origin` from the **same shared volume**
  (`qits-repositories`, mounted at `/data/repositories` in qits-artifacts, qits-projects and
  qits-workspaces alike). Both of its addressing schemes resolve to that directory name, and
  `GitHostRoutes` hands exactly that name to `CiPostReceiveNotifier.onPostReceive`.
- So **`CiRun.repoId` is the shared repository directory name**, and for any repository qits-projects
  provisioned, that name *is* `Repository.id`. The join the brief describes is real.

But `qits-local-up.sh` seeds the platform's own repositories by hand:
`git init --bare /repos/qits-<name>/origin`, with **no qits-projects `Repository` row**. That is
why the shipped event trigger matched `repoId: { exact: qits-spa-ui-components }` — a human name,
not a UUID. `RepositoryDiscoveryService` sees those directories at startup and logs
"has no project association; skipping". Likewise, cd's applications are seeded with
`repoId: "qits-<name>"`.

**Consequence, and it is not a footnote: on the platform as it stands, every repository that has
real CI runs is unattributed.** A project-centric ci tree that only walks projects → repositories →
runs would render, today, as a list of projects with nothing under them, while the entire run
history sat in a bucket the UI never drew. The brief's requirement that orphans be visible in both
directions is therefore not defensive polish — it is the main content on day one, and it is the
reason `GET /ci/api/repositories` below is a required gap and not a nicety.

The cd tree is unaffected: its top-level join is `CdEnvironment.name == Project.slug`, and
`qits-local-up.sh` creates the environment named `qits` against a project self-seed that announces
the same slug. Its *application* rows carry the same hand-seeded `repoId`s, but the cd tree never
joins on them — it only displays them.

## Decision 1 — hand-written typed API services, not generated clients

The platform generates OpenAPI **documents**, not clients: `docs/openapi.yml` is committed in
qits-ci, qits-cd, qits-projects and others, each written by an `OpenApiSchemaExportTest` that GETs
`/<segment>/q/openapi` and writes the file, so a hidden-or-unhidden operation shows up as a diff.
Nothing consumes those documents. There is no `openapi-generator` in any frontend `package.json`,
no `.openapi-generator` file, no `api/` or `generated/` directory anywhere in `frontends/`.

Three reasons not to start now:

1. **The generated types would be unusable.** Every controller here nests its request/response
   records inside the request type, so the generator names them positionally. qits-projects'
   committed document already carries `Response19` and `Entry4` as the schema names for
   "the list-projects response" and "one project entry". A tree component written against
   `Entry4` is worse than one written against a six-line hand-typed interface.
2. **Two of the three endpoints the ci tree needs are absent from the document** (Decision 6),
   so a generated client would need hand-written supplements anyway — the worst of both.
3. **The total surface is six endpoints.** Two from qits-projects, three from qits-ci, and for the
   cd phase three from qits-cd. Generating that is not leverage; it is a build step, a toolchain,
   and a CI recipe change per SPA, in exchange for typing thirty lines by hand.

**Decision: one `@Injectable({providedIn: 'root'})` service per upstream service, with hand-written
`interface` DTOs mirroring the wire shape exactly**, in `src/app/api/`. Field names are copied from
the Java records verbatim; the response envelopes differ per service and the interfaces say so
(`{runs: […]}` for ci's list, a bare `CiRunDto` for its single-run read, `{entries: [{project: …}]}`
for projects — these are genuinely inconsistent upstream and the client must not pretend otherwise).

**Transport: Angular's `HttpClient` with `provideHttpClient(withFetch())`**, awaited through
`firstValueFrom`. Two things decide this over bare `fetch()`. First, `HttpTestingController` is the
only request-mocking story Angular ships, and the vitest suites for these pages are mostly
"given this response, render that tree". Second, `withFetch()` routes through `window.fetch`, which
is what the platform's OTel browser instrumentation hooks — spa-home's `app.config.ts` documents
this at length, and choosing the XHR backend now would quietly forfeit client spans later.
`firstValueFrom` is the one rxjs import in the codebase, and rxjs is already a declared dependency
of every SPA.

Provider order in `app.config.ts` follows spa-home's documented order:
`provideBrowserGlobalErrorListeners()`, `provideRouter(routes)`, `provideHttpClient(withFetch())`.

*Discovery task for the implementing agent:* Angular 21 ships `httpResource()`, which is
signal-native and would give `.value()`/`.status()`/`.error()`/`.reload()` for free — a very good
fit for lazy tree expansion. **Check whether it is out of developer preview in the pinned 21.2.** If
it is, prefer it and say so in the commit; the API-service seam means that swap is a change inside
the page components, not a rewrite.

**Base URLs are same-origin absolute paths** (`/ci/api/runs`, `/projects/api/projects`) behind an
`InjectionToken<string> QITS_API_BASE` defaulting to `''` — the `LEAVE_APP` pattern from
spa-home's `mfe-exit.ts`, which is the platform's one DI-token precedent, and the seam the specs
need. For `ng serve` (no gateway in front) the SPA gains a `proxy.conf.json` forwarding `/ci/api`
and `/projects/api` to the local gateway.

## Decision 2 — the join lives in each SPA, duplicated

The ci tree needs projects and repositories from qits-projects; the cd tree will need the same. The
tempting move is a shared `@qits/ui-components` addition. **Reject it**, on two grounds:

- It is a *components* library. Its public API is four components and a nav constant, it declares
  `@angular/common`, `core` and `router` as peers, and it deliberately holds no state and no
  transport. Adding HTTP services would put a transport dependency into six SPAs that do not make
  requests.
- The version cost is the real one. Any change to the shared join becomes a library publish, a
  version bump in every consuming SPA, and — because each SPA's `app.spec.ts` asserts
  `toHaveLength(7)` on the rendered nav links — a coordinated release train. We have run that train
  once. It is the right price for a nav entry and the wrong price for a fetch of
  `/projects/api/projects`.

The platform's own precedent settles it: qits-ci does not depend on qits-events' domain module; the
wire contract is duplicated as DTOs on each side, and the eventsourcing plan calls that duplication
the thing that keeps extraction clean. **Decision: each SPA owns its own `ProjectsApi` service and
its own `ProjectDto`/`RepositoryDto` interfaces.** That is roughly forty duplicated lines between
qits-spa-ci and qits-spa-cd. If a third consumer appears and the shapes have stayed identical, that
is the moment to reconsider — and the answer then is a `@qits/platform-api` package, not the
components library.

The same rule governs components: build `app-tree-node`, `app-status-badge` (a thin map from a
status enum onto `QitsBadge`'s tone), `app-async` and `app-empty` **locally in qits-spa-ci first**.
Promote to the library only when the cd screens prove they want the identical thing — at which
point promotion is a real decision with two data points instead of a guess with one.

## Decision 3 — lazy expansion, not a fan-out budget

Eagerly composing the ci tree costs `1 + P + R` requests: the project list, one repository list per
project, one run list per repository. With ten projects and thirty repositories that is
forty-one requests on page load, and each run list is unbounded. Capping the concurrency of that
storm just makes it slower, not smaller.

**Decision: every level of the tree loads on expansion, and caches once loaded.**

- `/ci/` on load: **one** request, `GET /projects/api/projects`, plus **one**
  `GET /ci/api/repositories` for the unattributed bucket. Nothing else.
- Expanding a project: `GET /projects/api/projects/{id}/repositories`.
- Expanding a repository: `GET /ci/api/runs?repositoryId={id}&limit=100`.
- Expanding a trigger-type group: **no request at all** — trigger grouping is a client-side
  `groupBy` over the run list already fetched, since every run carries `triggerType`. Groups render
  in enum order, `POST_RECEIVE` then `EVENT`, and a group with no runs is not drawn.

The user's clicks are the bound; there is no cap to tune and no concurrency to manage. It also makes
the missing paging (Decision 6) survivable, because a repository's runs are only ever fetched when
someone asks for that repository.

Each node holds its own state signal — `'collapsed' | 'loading' | 'ready' | 'error'` — so a failure
in one repository's run fetch collapses to an inline retry on that row and leaves the rest of the
tree standing. That is the point of the fan-out being per-node.

**Deep links** are the one case that loads without a click. `/ci/runs/:runId` needs no ancestors
at all (Decision 4) — the run read stands alone. *(Amended after the E2E, settled with the user:
the page additionally fetches the project list + per-project repositories, application-cached and
in parallel, to render the `· project <name>` attribution — the original "single request" wording
lost to correctness when O measured its consequence: a repo link that landed on the tree
unexpanded under a wrong banner. A `/ci/?repo=` URL naming a repository no opened project claims
buys the same cached lookup.)* The tree itself is only ever reached at `/ci/`.

The cd tree follows the same rule: `/cd/` loads `GET /projects/api/projects` and
`GET /cd/api/environments` (two requests — both are flat lists, and the second is what makes
unmatched environments computable). Expanding a project costs two:
`GET /cd/api/environments/{id}` for its applications (the list endpoint returns `applications: null`
by design) and `GET /cd/api/deployments?environmentId={id}` for the deployment history. The
"current deployment per application" is then the first row per `applicationId` in a list already
sorted newest-first — one client-side pass, and `CdDeploymentDto` carries both `applicationId` and
`applicationName`, so no third request is needed.

## Decision 4 — URLs

Angular path routing under each `baseHref`; `enable-spa-routing=true` already makes deep links fall
back to `index.html` on reload. No hash routing anywhere.

```
/ci/                       the tree (the root view IS the tree)
/ci/?project=<id>&repo=<id>  the tree, with that path expanded — bookmarkable, back collapses
/ci/runs/<runId>           run detail
```

```ts
export const routes: Routes = [
  { path: '', component: QitsMainLayout, children: [
      { path: '', component: CiTreePage },
      { path: 'runs/:runId', component: RunDetailPage },
  ]},
];
```

Two choices worth defending.

**A run is addressed by its runId alone — not `/ci/projects/<pid>/repos/<rid>/runs/<runId>`.** The
nested form asserts a hierarchy the data does not have. A `CiRun` is keyed by `repoId` and knows
nothing about projects; the project association is a join performed in the browser against another
service. A URL carrying a project id would become internally inconsistent the moment a repository
moved project, and would be unresolvable for exactly the runs that matter most here — the
unattributed ones, which belong to no project at all. `runId` is the run's real identity, so it is
the whole path.

**Tree expansion lives in query parameters, not path segments.** It is view state, and the path is
for resources. Query parameters keep it bookmarkable and make the back button mean "collapse", which
is what a user pressing back on a tree expects. Navigation on expand uses `router.navigate` with a
history entry (not `replaceUrl`) for exactly that reason.

The cd tree mirrors this: `/cd/` and `/cd/?project=<id>`. It gets **no detail route**, because a
deployment row already carries everything cd knows — `commitSha`, `status`, `containerName`,
`detail`, `createdAt`, `finishedAt` — and the row expands in place to show the `detail` clob. That
is deliberate: cd has no deployment-by-id endpoint, and rendering around that gap costs nothing,
whereas adding the endpoint to serve a route we do not need would be building for a screen we
decided not to draw.

Both SPAs get a `**` route rendering a small "no such page here" view. They must **not** copy
spa-home's `window.location.assign` exit behaviour — that is the landing page's job, and it is
correct only because the gateway has already decided nothing owns the URL.

## Decision 5 — live behaviour: poll only while something is in flight

qits-ci offers no push transport to a browser. Its own sources say so three times over —
`CiStepRelay`'s javadoc ("Following along is a **poll** … there is no SSE and no WebSocket on the
read side"), `getRun`'s javadoc, and the README. The only websocket is `/ci/daemon`, which closes
unknown callers with 1008. There is no ETag, no `If-None-Match`, no `Last-Modified` anywhere in
qits-ci.

**One policy, both screens: poll only while a visible entity is non-terminal.**

- **Run detail**: while `status === 'RUNNING'`, re-`GET /ci/api/runs/{runId}` every **3 seconds**.
  Stop on the first response with a terminal status — that response is already complete (`live` is
  null, unreached steps are written `SKIPPED`), so no extra fetch is needed. Pause on
  `document.hidden` and resume on `visibilitychange`. The tree never polls.
- **cd deployments** (the deferred phase): while any visible deployment is `QUEUED` or `STARTING`,
  re-`GET /cd/api/deployments?environmentId={id}` every **5 seconds**; otherwise nothing, with a
  manual refresh button (`QitsButton`). Deployments settle in tens of seconds and then sit for days;
  polling a settled table is pure waste.

Three seconds rather than one is bought with a measured cost. The run read has **no delta and no
offset**: every poll re-sends the full `output` of every completed step, bounded at
`qits.ci.output-max-chars=65536` each. A run with five completed steps is up to 320 KiB per poll.
Client-side mitigation is free and should be done — a step row whose `stepIndex` and `finishedAt`
are unchanged is not re-rendered — but the bytes still cross the wire, and the honest answer is a
slower cadence plus a named fast-follow (output offsets, or a conditional GET on the run resource).
It is not worth building now: during the RUNNING window the resource genuinely changes every second,
which is precisely when a conditional GET saves nothing.

**The events stream stays out of v1**, and not merely for scope. qits-events *does* ship a
browser-usable websocket (`/events/stream`, subscribe-frame, `["*"]` for everything) — it is the one
live channel on the platform a browser could dial. Subscribing to it would still be wrong here:

1. It would be **silently incomplete**. qits-ci publishes `BuildSuccessful` and nothing else — a run
   entering RUNNING, failing, or being cancelled emits no event. A tree that refreshed on the stream
   would update on a strict subset of the changes it displays, which is worse than not updating,
   because the staleness would be invisible.
2. **cd publishes nothing at all**, so the cd screen would gain zero.
3. It costs a second live transport with its own reconnect and backoff state, in a SPA that has no
   HTTP code today.

Poll-while-in-flight covers both screens with one mechanism and one rule. When qits-ci publishes a
richer set of lifecycle events, revisit.

## Decision 6 — which service gaps ship

The rule is: close a gap only where rendering around it would make the UI **lie**, or where the fix
is a line and the alternative is a workaround with its own semantics.

### Shipping in this feature (all in qits-ci; no migration, no new literal route)

**1. Unhide the two run reads.** `GET /ci/api/runs` and `GET /ci/api/runs/{runId}` carry
`@Operation(hidden = true)`. The stated reason is explicit and worth quoting, because engaging with
it is the point — qits-ci's `AGENTS.md`:

> The intake and the two run reads carry `@Operation(hidden = true)` because they are machine
> surfaces rather than part of the JSON API the Angular client consumes … `POST
> /ci/api/runs/{runId}/cancel` is deliberately **not** hidden: it is the one operation here a person
> invokes on purpose.

That reasoning was correct and is now falsified by its own premise. The criterion was "does a client
consume it, does a person invoke it", and the answer changes the moment a first-party SPA reads
these endpoints on every page. The service has already conceded the direction: `CiRunDto`'s javadoc
says the provenance fields are exposed "because the run API is where an operator reads a run's
provenance from outside — no client renders them yet, and that is a later, small follow-up rather
than a gap". This is that follow-up.

The concrete cost of leaving them hidden is not client generation (Decision 1 generates nothing). It
is that `docs/openapi.yml` — a file the platform commits specifically so that *"hiding or unhiding an
operation shows up as a diff"* — would omit the entire contract the SPA depends on. A breaking change
to `CiRunDto` would land with an empty diff. Unhiding restores the document to its stated purpose.

**The intake stays hidden.** `POST /ci/api/events/post-receive` is genuinely machine-only,
token-guarded, and has a cross-repo wire contract with qits-artifacts. The criterion still applies to
it; only its application to the reads was wrong.

Cost: two annotation lines, then
`./mvnw -pl service -am test -Dtest=OpenApiSchemaExportTest -Dsurefire.failIfNoSpecifiedTests=false`
and commit the regenerated document. Any `./mvnw verify` regenerates it anyway.

**2. `GET /ci/api/repositories` → `{"repositoryIds": ["…"]}`.** The distinct `repoId`s qits-ci has
runs for. `CiRunRepository.distinctRepoIds()` already exists and is already used by `KnownCiRepos`;
it is simply not reachable over HTTP. Without it the tree cannot see CI activity that no project
claims — which, per the finding above, is *all* of it on the platform today. The name is deliberate:
these are ids qits-ci observed, not repository objects it owns, and the response says so.

**3. `?limit=` on the run list.** Optional; absent means unbounded, so nothing existing changes. The
ordering is already well-defined (`createdAt desc, id desc`), so "the newest N" is a total answer.
The SPA requests `limit=100` and renders "showing the newest 100" with a *load all* affordance.

**Explicitly no `?offset=` and no cursor.** An offset over a list that grows at the head is a lie
under concurrent inserts — page 2 re-shows rows page 1 already showed. And nobody wants page 2 of a
repository's runs; they want the newest N and then one specific run, both of which are covered. When
someone genuinely needs to walk history, the right shape is a `before=<createdAt>` cursor, and that
is a fast-follow with a real requirement behind it.

**4. `CiPackagedSurfaceIT` grows the SPA probes.** qits-ci's packaged IT asserts the OpenAPI
document, the intake, the daemon socket and a full push-to-run round trip — but **not** that the SPA
is served, that deep links fall back, or that a mistyped machine path 404s instead of returning
`index.html`. qits-events' `PackagedSurfaceIT` probes all of those. Shipping the first real pages
into `/ci/` without that asymmetry closed is how the SPA-fallback trap gets discovered in
production. Add: `/ci/` → 200 HTML with `<base href="/ci/">`; `/ci/runs/anything` → 200 index.html;
`/ci` → 301; `/ci/api/nope` → 404 never HTML; plain `GET /ci/daemon` → 404 never HTML.

No Flyway migration is needed for any of this — nothing gains a column, so the ci lineage stays at
V3. `ignored-path-prefixes` is unchanged: `/api` already covers `/api/repositories`, and no new
literal route is added.

### Fast-follows, named so nobody builds them here

- **cd's `run_id` column** (V2 migration + read `event.runId()` in `CdEventController` +
  `CdDeploymentDto` field). The intake already receives it — `CiPostReceiveNotifier`'s sibling
  `CdBuildNotifier` posts `{runId, repoId, branch, commitSha}` and the controller's own javadoc says
  *"`runId` is recorded nowhere yet but travels for traceability"*. It is the only thing that could
  ever make the deployment-row → its-build click-through possible, and it is genuinely cheap. It is
  a fast-follow only because the ci run-detail screen does not need it: that screen shows steps and
  output, and the edge it would enable points the other way. **Ship it with the cd screens phase**,
  where the click-through has a screen to land in.
- **ci's `?triggerEventId=` filter.** The ci tree groups by trigger *type*, which is a field on each
  run row, so nothing here needs it. Walking `Event → runs it triggered` is the causation explorer,
  a different feature.
- **cd's `?repoId=` filter, deployment-by-id, and application routes outside the environment
  nesting.** All three are rendered around in the cd design (Decision 4), at no cost to the screen.
- **Output offsets or a conditional GET on the run read** (Decision 5).
- **Cursor paging** on either hot list.
- **Filter-name symmetry** (`?repositoryId=` vs `?environmentId=`). Deliberately not touched.
  Renaming a query parameter is a breaking change to buy symmetry between two services that never
  appear in one request, and both spellings are `<thing>Id` and unambiguous in their own service.
  If the platform ever does an API-conventions pass, it belongs there.

## The screens

`QitsMainLayout` supplies the top bar and the left nav; everything below is what renders into its
content outlet. Status badges map onto `QitsBadge` tones: run `RUNNING`→info, `SUCCESS`→success,
`FAILED`→danger, `CONFIG_ERROR`→warning; step `SUCCESS`→success, `FAILED`→danger, `SKIPPED`→neutral;
deployment `ACTIVE`→success, `STARTING`→info, `QUEUED`→neutral, `IMAGE_MISSING`→warning,
`FAILED`→danger, `DECOMMISSIONED`→neutral.

### `/ci/` — the run tree

```
┌────────────────────────────────────────────────────────────────────────────────────────────────┐
│ qits                                                                                        ☰  │
├───────────────┬────────────────────────────────────────────────────────────────────────────────┤
│ Home          │  CI runs                                                          [ Refresh ]  │
│ CI         ◀  │  Projects → repository → trigger. 4 projects · 3 repositories with no project. │
│ Artifacts     │                                                                                │
│ Projects      │  ▾ qits                                                          6 repositories│
│ Workspaces    │    ▾ qits-ci                          SERVICE  main  …/QuicklyIterate/qits-ci  │
│ Events        │      ▾ POST_RECEIVE                                 12 runs · newest 100 shown │
│ Observability │          SUCCESS   da4a3f0e  main  9f2c1ab   31 Jul 14:02 → 14:06     4m 12s   │
│               │          FAILED    7b19c204  main  1de0447   31 Jul 11:47 → 11:49     1m 58s   │
│               │          RUNNING   3c8ef011  main  aa71903   31 Jul 15:20 → …         2m 07s   │
│               │          …                                              [ show all 12 runs ]   │
│               │      ▾ EVENT                                                            1 run  │
│               │          SUCCESS   b41d7e90  main  c9d1514   30 Jul 09:15 → 09:19     3m 44s   │
│               │                    ↳ BuildSuccessful · ci-event-upstream-ui-components.yml     │
│               │    ▸ qits-cd                          SERVICE  main                            │
│               │    ▾ qits-docs                        LIBRARY  main                            │
│               │        No runs recorded for this repository.                                   │
│               │    ▾ qits-spike                       FORK     main                            │
│               │        ⚠ Could not load runs — 503.                        [ Retry ]           │
│               │  ▸ website                                                     2 repositories  │
│               │  ▾ scratch                                                                     │
│               │      This project has no repositories.                                         │
│               │                                                                                │
│               │  ▾ Not claimed by any project                    3 repositories with CI runs   │
│               │    ▸ qits-spa-ui-components                                                    │
│               │    ▸ qits-gateway                                                              │
│               │    ▸ legacy-build-box                                                          │
└───────────────┴────────────────────────────────────────────────────────────────────────────────┘
```

Notes that are design, not decoration:

- The repository label is the **url basename** derived in the browser
  (`url.replace(/\.git$/, '').split(/[/:]/).pop()`), because `RepositoryDto` carries
  `id, url, mainBranch, archetype, projectId` and no name, and a tree row reading
  `a1b2c3d4-5e6f-…` helps nobody. The **identity stays `repository.id`** — the basename is a label
  and is never used as a key. (Exposing the alias table's registered name on `RepositoryDto` is a
  reasonable projects-side nicety; it is not needed to make this work, so it is not in scope.)
- Under "Not claimed by any project", the label *is* the `repoId`, because that is all qits-ci knows.
  These nodes expand straight to trigger groups — there is no repository metadata to show.
- The unattributed set is `repositoryIds` from qits-ci minus the union of every loaded project's
  repository ids. Because projects load lazily, this set is computed against the projects **already
  expanded** and is recomputed on each expansion; the header says "3 repositories with CI runs"
  from qits-ci's own list, so the count is honest even before any project is opened. A repository id
  that later turns out to belong to a project disappears from the bucket when that project expands —
  which is correct, and visible.
- A run row is a link to `/ci/runs/<runId>`. Nothing else on this screen navigates.
- Duration for a RUNNING run counts from `createdAt` and ticks locally; it is not polled.

### `/ci/runs/<runId>` — run detail

```
┌────────────────────────────────────────────────────────────────────────────────────────────────┐
│  ← All runs                                                                                    │
│                                                                                                │
│  qits-ci · main · 9f2c1ab                                                          SUCCESS     │
│  ────────────────────────────────────────────────────────────────────────────────────────────  │
│  Run          da4a3f0e-11c2-4f7a-9b03-2ee45c1f8d61                                             │
│  Trigger      EVENT · BuildSuccessful · 6f31a0c4-…-c2a1                                        │
│  Config       .config/qits/ci-event-upstream-ui-components.yml                                  │
│  Started      31 Jul 2026 14:02:11Z      Finished  14:06:23Z      Duration  4m 12s             │
│  Daemon       0.4.1                      Repository  qits-ci  ·  project qits                  │
│                                                                                                │
│  Steps                                                                                         │
│  ┌──────────────────────────────────────────────────────────────────────────────────────────┐  │
│  │ ▾ 0   SUCCESS   qits/build-images/node-docker-base:latest    exit 0   14:02:12   2m 41s   │  │
│  │   ┌────────────────────────────────────────────────────────────────────────────────────┐ │  │
│  │   │ [... output truncated ...]                                                         │ │  │
│  │   │ added 812 packages in 41s                                                           │ │  │
│  │   │ > qits-spa-ci@0.0.0 build                                                           │ │  │
│  │   │ Application bundle generation complete. [8.204 seconds]                             │ │  │
│  │   └────────────────────────────────────────────────────────────────────────────────────┘ │  │
│  │ ▸ 1   SUCCESS   qits/build-images/ci-base:latest             exit 0   14:04:53   1m 30s   │  │
│  │ ▸ 2   SKIPPED   qits/build-images/ci-base:latest             —        —          —        │  │
│  └──────────────────────────────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────────────────────────────┘
```

While RUNNING, the head reads `RUNNING`, `Finished` is `—`, and the steps panel gains the live step —
the one `live` names, which by contract has no row of its own yet:

```
│  Steps                                                    ⟳ following · updated 2s ago         │
│  ┌──────────────────────────────────────────────────────────────────────────────────────────┐  │
│  │ ▸ 0   SUCCESS   qits/build-images/node-docker-base:latest    exit 0   15:20:04   1m 12s   │  │
│  │ ▾ 1   RUNNING   (step 1 · live)                                       15:21:16   0m 51s   │  │
│  │   ┌────────────────────────────────────────────────────────────────────────────────────┐ │  │
│  │   │ #14 exporting layers 2.1s done                                                      │ │  │
│  │   │ #14 DONE 2.4s                                                                       │ │  │
│  │   │ ▍                                                                                   │ │  │
│  │   └────────────────────────────────────────────────────────────────────────────────────┘ │  │
│  └──────────────────────────────────────────────────────────────────────────────────────────┘  │
```

- The live step is rendered from `live: {stepIndex, output}` — **two fields, that is all it has**. No
  image, no timestamps, no status. The row must not invent them; it shows the index, the word
  `live`, and the tail. Its elapsed time is computed locally from when the client first saw it.
- The live pane auto-scrolls to the bottom unless the user has scrolled up, and the last completed
  step's pane is the one expanded by default on load.
- `[... output truncated ...]` is `CiRunService.TRUNCATION_MARKER` arriving verbatim in the output —
  the **head** is dropped and the tail kept. Render it as received; do not restyle it into a UI
  affordance that implies the missing text can be fetched. It cannot.
- ANSI escape sequences in step output are stripped, not interpreted. Interpreting them is a
  terminal emulator, and this is a log pane.
- `Repository · project qits` is a link back to `/ci/?project=<id>&repo=<id>`. When the run's repoId
  matches no project, it reads `Repository qits-ci · not claimed by any project` and links to the
  unattributed bucket.
- **Cancel button on RUNNING runs** — settled decision 2: confirmation-guarded, 409-tolerant
  (a run that finished between render and click reconciles on the next poll), hidden on
  terminal runs. The page's one write.

### `/cd/` — deployments by project (designed here, built in the deferred phase)

```
┌────────────────────────────────────────────────────────────────────────────────────────────────┐
│  Deployments                                                                     [ Refresh ]   │
│  Current deployments by project. 4 projects · 3 environments · 1 unmatched.                    │
│                                                                                                │
│  ▾ qits                                     environment "qits" · main · network qits-net       │
│    ┌──────────────────────────────────────────────────────────────────────────────────────┐    │
│    │ Application    Repository       Status         Commit    Last deployment    Container │    │
│    ├──────────────────────────────────────────────────────────────────────────────────────┤    │
│    │ qits-ci        qits-ci          ACTIVE         9f2c1ab   31 Jul 14:09  3h    qits-ci-9f│   │
│    │ qits-cd        qits-cd          ACTIVE         1de0447   30 Jul 22:41  19h   qits-cd-1d│   │
│    │ qits-events    qits-events      STARTING       aa71903   31 Jul 15:21  2m    qits-eve-a│   │
│    │ ▾ qits-stt     qits-stt         IMAGE_MISSING  77c0e13   29 Jul 09:12  2d    —         │   │
│    │     manifest unknown for qits/qits-stt:77c0e13 — the build published no image          │   │
│    │ qits-dns       qits-dns         never deployed                                         │   │
│    └──────────────────────────────────────────────────────────────────────────────────────┘    │
│  ▸ website                                  environment "website" · 2 applications              │
│  ▾ scratch                                                                                      │
│      No environment named "scratch" exists in qits-cd.                                          │
│                                                                                                 │
│  ▾ Environments matching no project                                          1 environment      │
│    ▸ epic-spike-42                          epic/spike-42 · 2 applications                      │
└────────────────────────────────────────────────────────────────────────────────────────────────┘
```

- The project → environment edge is `CdEnvironment.name === Project.slug`, and it is **convention
  only** — no column links them. `CdEnvironmentNotifier` in qits-projects POSTs
  `{name: slug, branch: "main", applications: []}` on project creation, and its javadoc explains
  why the slug rather than the display name (cd validates the name as a DNS label, which a slug
  already is, and a slug cannot be renamed out from under the environment it named). The UI must
  never present this as a foreign key. It is drawn as a match, and both kinds of non-match are shown:
  a project with no environment (the notifier may simply have failed — that is exactly what an
  operator wants to see) and an environment matching no project.
- Unlike the ci tree, cd needs **no service gap** for orphan honesty: `GET /cd/api/environments`
  returns everything, so the unmatched set is a client-side difference. That asymmetry is worth
  naming — cd's unfiltered list endpoint makes the orphan set computable; ci's mandatory filter
  makes it invisible, which is why gap 2 exists.
- "Last deployment" is the newest `CdDeploymentDto` for that `applicationId` from a list already
  sorted `createdAt desc, id desc` across all the environment's applications. One pass. An
  application with no deployment row shows `never deployed` and is drawn from the environment's
  `applications` array, not from the deployment list — otherwise it would vanish.
- A row expands to show `detail` (a clob) and the deployment's own `createdAt`/`finishedAt`. Row
  expansion replaces a detail route, per Decision 4.
- Once cd carries `run_id` (fast-follow), the commit cell gains a link to `/ci/runs/<runId>` — the
  full ci↔cd click-through, in one cell, and the reason that column is worth adding.

### States, per node

| Situation | What is drawn |
|---|---|
| Node not yet expanded | Collapsed chevron, no request made |
| Expanding | Inline skeleton row on that node only; the rest of the tree stays interactive |
| Project with no repositories | `This project has no repositories.` |
| Repository qits-ci has never seen | `No runs recorded for this repository.` — the API answers an empty list, not a 404 |
| Repository fetch fails | Inline `⚠ Could not load runs — <status>.` with a `[ Retry ]` on that node |
| Run list truncated at the limit | `12 runs · newest 100 shown` with `[ show all ]` re-fetching without `limit` |
| Run id in URL does not exist | Run detail renders `No run <id>.` with a link back to `/ci/` — a 404 from the API, not a crash |
| CI activity claimed by no project | The `Not claimed by any project` bucket, always drawn, never hidden even when empty (`0 repositories` is information) |
| Project with no cd environment | `No environment named "<slug>" exists in qits-cd.` |
| cd environment matching no project | The `Environments matching no project` bucket |
| Root list itself fails | Full-page error with a retry; a failure of `GET /projects/api/projects` is the one unrecoverable one |
| qits-ci unreachable but projects fine | The tree renders with projects and repositories; every repository shows the retry state. The reverse (`/ci/api/repositories` fine, projects down) shows the unattributed bucket alone with a banner |

## Frozen contracts

Agents build against these; an agent that believes one is wrong reports back rather than adjusting
its own side.

**New in qits-ci:**

```
GET /ci/api/repositories
    → 200 {"repositoryIds": ["qits-ci", "a1b2c3d4-…", …]}   # distinct repoIds with at least one run

GET /ci/api/runs?repositoryId=<id>[&limit=<n>]
    → 200 {"runs": [CiRunDto, …]}                            # createdAt desc, id desc; newest n
    → 400 {"message": "Invalid repository id"}               # repositoryId absent or not
                                                             # [A-Za-z0-9][A-Za-z0-9-]{0,63}
```

Both, plus `GET /ci/api/runs/{runId}`, appear in `docs/openapi.yml` after this feature.

**Read as they are (do not change):**

```
GET /ci/api/runs/{runId}   → CiRunDto (bare, not enveloped), steps[] populated,
                             live = {stepIndex, output} only while status == RUNNING
GET /projects/api/projects                       → {"entries": [{"project": ProjectDto}]}
GET /projects/api/projects/{id}/repositories     → {"entries": [{"repository": RepositoryDto}]}
GET /cd/api/environments                         → {"environments": [CdEnvironmentDto]}  (applications null)
GET /cd/api/environments/{id}                    → {"environment": CdEnvironmentDto}     (applications set)
GET /cd/api/deployments?environmentId=<id>       → {"deployments": [CdDeploymentDto]}    (400 without, 404 unknown)
```

Field names, verbatim from the Java records:

```
CiRunDto      id repoId branch commitSha status createdAt finishedAt daemonVersion
              triggerType triggerEventId triggerEventName configPath steps live
CiStepDto     stepIndex image status exitCode startedAt finishedAt output
CiLiveStepDto stepIndex output
ProjectDto    id name slug description dns
RepositoryDto id url mainBranch archetype projectId
CdEnvironmentDto id name branch network createdAt applications
CdApplicationDto id repoId name healthPath createdAt
CdDeploymentDto id applicationId applicationName commitSha status containerName detail
                createdAt finishedAt
```

Enums: `CiRunStatus` RUNNING|SUCCESS|FAILED|CONFIG_ERROR · `CiStepStatus`
PENDING|RUNNING|SUCCESS|FAILED|SKIPPED (the first two are legacy and never written) ·
`CiTriggerType` POST_RECEIVE|EVENT · `CdDeploymentStatus`
QUEUED|STARTING|ACTIVE|IMAGE_MISSING|FAILED|DECOMMISSIONED · `RepositoryArchetype`
PROJECT|SERVICE|LIBRARY|INTEGRATION|APPLICATION|SERVICE_TEMPLATE|FORK.

## Decisions settled with the user (2026-07-31)

**1 — The platform's own repositories get onboarded into qits-projects, now.** A `qits` project
whose repositories are the platform's real ones, so the project-centric tree has its spine from
day one. This adds a workstream (Agent P below, parallel with L and M, in qits-projects): the
mechanism is P's to investigate — qits-projects already has self-seed and repository-discovery
machinery — but the acceptance is fixed: `Repository` rows whose **ids equal the git-host
directory names** (`qits-ci`, `qits-gateway`, …), because `Repository.id` is the join key
`CiRun.repoId` carries. The unattributed bucket stays in the UI regardless (new un-onboarded
repos will always exist transiently).

**2 — The run-detail page ships WITH the cancel button.** One deliberate exception to the
read-only mandate: cancel on RUNNING runs, confirmation-guarded, with 409-tolerant handling for
a run that finished between render and click. It is the one operation qits-ci publishes as
human-facing and this page is the only home it could have.

**3 — Implementation launched immediately** (L ∥ M ∥ P → N → O).

The original decision text, for the reasoning record:

**⚖ 1 (as posed) — Do the platform's own repositories get onboarded into qits-projects, or does
the tree show them as unattributed indefinitely?**

Per the finding above, `qits-local-up.sh` seeds `qits-ci`, `qits-cd`, `qits-gateway` and the rest
directly onto the git host with no `Repository` row, so on the platform as it stands *every*
repository with CI runs lands in "Not claimed by any project". The explorer will therefore work
correctly and look almost empty at the project level — which is a true picture of the data, and
possibly a surprising one.

Two paths, and only the user can choose:

- **Show it honestly and leave the data alone.** The explorer's job is to report. The bucket is
  prominent, labelled, and fully expandable, so nothing is hidden. Zero extra work; the platform's
  repositories stay outside the project registry, as they are today.
- **Onboard the platform's repositories into qits-projects** — a `qits` project whose repositories
  are the real ones — so the project-centric tree has something to show at its spine. This is a data
  and bootstrap change (`qits-local-up.sh`, or a one-off), not a code change, and it is a decision
  about how the platform models itself, not about this UI.

**The explorer is built the same way either way**, and gap 2 (`GET /ci/api/repositories`) is required
under both. The recommendation is to ship the explorer first and let it make the case: an operator
looking at a screen that says "3 repositories with CI runs, claimed by no project" is a better
argument for onboarding than this paragraph.

**⚖ 2 (as posed) — Does the run-detail page get the cancel button?**

The mandate is read-only, and the recommendation is **no in v1**. But it is worth putting back to
the user explicitly, because qits-ci ships exactly one operation intended for a human —
`POST /ci/api/runs/{runId}/cancel` — it is the *only* path in `docs/openapi.yml`, its javadoc calls
it "a button a person presses", and the run-detail page is the only place that button could ever
live. The service has been waiting for this screen.

Against, and why the recommendation stands: it is the one write in a feature reviewed as an
explorer, and it needs machinery nothing else here has — a confirmation step, 409 handling for a run
that finished between render and click, and an optimistic-then-reconciled state. It is roughly
twenty lines once a run-detail page exists, and it is the obvious first follow-up. Shipping the
explorer read-only keeps the review honest.

## Workstreams (one Opus 5 agent each)

Continuing the platform's letter sequence; A–K are burned across the three shipped features.

### Agent L — qits-ci's API grows up (repo: `services/qits-ci`)

**Task 0, a blocking gate, before anything else.** Verify the join against the *live* platform and
report before proceeding:

```
curl -s .../ci/api/repositories        # after building it, or read distinctRepoIds from the db
curl -s .../projects/api/projects      # and each project's /repositories
```

Confirm that the `repoId` values qits-ci holds are the shared `/data/repositories/<name>/origin`
directory names, and record how many of them match a `Repository.id`. The design above predicts
*few or none* and is built for that; if the reality differs — for instance if repository ids turn out
not to be the git-host directory names at all — **stop and report**, because the tree's join key is
the one assumption everything rests on.

Then:

- Remove `@Operation(hidden = true)` from `CiRunController.listRuns` and `getRun`. Leave
  `CiEventController`'s intake hidden. Regenerate `docs/openapi.yml` via `OpenApiSchemaExportTest`
  and commit the diff — the diff **is** the assertion.
- `GET /ci/api/repositories` → `{"repositoryIds": [...]}`, over the existing
  `CiRunRepository.distinctRepoIds()`. Sorted ascending, so the response is stable.
- `?limit=` on `listRuns`: optional, positive, absent means unbounded; a non-positive or
  non-numeric value is a 400 through `CiExceptionMapper`'s `{"message": …}` envelope.
- `CiPackagedSurfaceIT` gains the five SPA/machine-surface probes listed in gap 4.
- `@QuarkusTest` coverage for the new endpoint and the limit, including the boundary (limit larger
  than the row count; limit exactly the row count).
- No Flyway migration, no `ignored-path-prefixes` change, no new literal route. Confirm all three.
- `./mvnw verify` green, push both remotes, pipeline redeploys qits-ci, verify live.

### Agent M — qits-spa-ci grows pages (repo: `frontends/qits-spa-ci`) — parallel with L

The contracts above are frozen, so this does not wait for L to land.

- `app.config.ts` gains `provideHttpClient(withFetch())` in the documented order. Mirror
  spa-home's `app.config.spec.ts` assertion that the backend is the fetch one.
- `src/app/api/`: `projects-api.ts`, `ci-api.ts`, and the DTO interfaces, typed exactly as frozen
  above. `QITS_API_BASE` injection token. Note `noPropertyAccessFromIndexSignature` is on — write
  real interfaces, not index signatures.
- `src/app/tree/` and `src/app/run/`: the two pages plus the local `app-*` components
  (`app-status-badge` mapping onto `QitsBadge`, `app-tree-node`, `app-async`, `app-empty`). Signals
  throughout, `OnPush`, `@if`/`@for`, `inject()` in field initialisers, no `async` pipe. Eager
  routes — two pages in one bundle; lazy chunks here would be ceremony.
- Every state in the table above has a spec, driven by `HttpTestingController`. The polling spec
  uses fake timers and must assert that polling **stops** on a terminal status and **pauses** on
  `document.hidden` — a poll that never stops is the failure mode that will not show up in review.
- `src/styles.css` is currently an empty comment; copy spa-home's (system-ui stack, 15px, 1.55,
  `#111827` on `#f9fafb`) so the pages sit in the same typography as the landing page.
- Add `eslint.config.js` and a `lint` script, copied from spa-home with the `app` selector prefix.
  The service SPAs deliberately carry no lint today and qits-spa-workspaces' CI file documents that
  adding both puts the line back in the recipe — this is the SPA that earns it.
- Add `.config/qits/ci-post-receive.yml` (spa-home's recipe: lockfile `resolved`-origin rewrite from
  `$QITS_NPM_PROXY_URL`, `npm ci`, lint, test, build; `qits/build-images/node-base:latest`; no image
  published). This repo has no pipeline today, so its first push is also its first run.
- **The cancel button (settled decision 2)**: on the run-detail page, RUNNING runs only —
  confirmation step, `POST /ci/api/runs/{runId}/cancel`, 409/terminal-race tolerated by letting
  the next poll reconcile. Spec-covered like every other state.
- **Do not touch `QITS_NAV_LINKS`.** `/ci/` is already the second entry, and the seven-link
  `toHaveLength(7)` assertion in every SPA's `app.spec.ts` must keep passing.

### Agent P — the platform onboards itself (repo: `services/qits-projects`) — parallel with L and M

Settled decision 1. The platform's own repositories get `Repository` rows under a `qits`
project so the tree attributes their history. The mechanism is P's to investigate —
qits-projects already carries self-seed machinery (`StartupSelfSeed`/`SelfSeedService`) and
repository discovery (`RepositoryDiscoveryService` reads the shared repositories volume) — but
the acceptance criteria are fixed:

- A `qits` project exists (slug `qits`, matching the cd environment name by the standing
  convention), created idempotently — rerunning whatever mechanism P picks must not duplicate.
- `Repository` rows for the platform's repos whose **`Repository.id` equals the git-host
  directory name** (`qits-ci`, `qits-gateway`, `qits-spa-ui-components`, …) — that id is the
  join key `CiRun.repoId` carries, and any other id attributes nothing.
- Durable over the bootstrap: prefer extending qits-projects' own seed/discovery path over a
  one-off script, so a fresh environment onboards itself; if the honest mechanism is instead a
  bootstrap (`qits-local-up.sh`) addition, report that for the orchestrator rather than editing
  the superproject.
- Verified live: `/projects/api/projects` shows `qits` with its repositories, and a
  `CiRun.repoId` spot-check joins.

Interplay with L's task-0 pre-flight: P landing mid-flight changes L's match *count* — L's gate
is about the join *mechanism* (ids are the git-host names), not the count on the day.

### Agent N — qits-ci embeds the client and ships it (repo: `services/qits-ci`, after L and M)

- Advance the `service/src/main/webui` gitlink to qits-spa-ci's new `main`, commit the explicit path
  (`ignore = all` hides submodule drift from `git status` but not from `git add -A`).
- Verify locally that `./mvnw -pl service -am package` builds the client through Quinoa and that the
  packaged fast-jar passes the extended `CiPackagedSurfaceIT`.
- Push both remotes. The pipeline inits the submodule, rewrites the lockfile origins, `npm ci`,
  `npm run build`, then `docker build`; qits-cd redeploys qits-ci.
- **Known trap, in memory:** qits-ci redeploying *itself* is part of this rollout, and a push that
  rebuilds qits-ci can lose its own run during the cutover. If no run row appears, replay
  `POST /ci/api/events/post-receive` with the pushed sha.
- The superproject's `frontends/qits-spa-ci` gitlink is expected to lag and needs no commit.

### Agent O — live end-to-end through the gateway (after N)

- Browse `https://<gateway>/ci/` in a real session. Confirm the nav renders, `/ci` redirects to
  `/ci/`, and `/ci/runs/<a real runId>` survives a hard reload (the SPA fallback).
- Expand a project to a repository to a trigger group to a run; open that run; confirm the steps,
  the statuses, the truncation marker, and the provenance block against what
  `GET /ci/api/runs/{runId}` returns for the same id.
- Cause a real run (push to a tracked repo, or replay the post-receive intake) and **watch it live**:
  the live step appears with no row, the tail grows, the poll stops the moment the status turns
  terminal. Confirm in the network panel that polling ceases and that a hidden tab does not poll.
- Confirm the unattributed bucket lists what `GET /ci/api/repositories` returns, and that a run
  reached through it renders with `not claimed by any project`.
- Confirm `GET /ci/api/nope` answers 404 and not HTML through the gateway, not only in the IT.
- Report the measured payload size of one poll of a multi-step run — the number that decides whether
  the output-delta fast-follow is urgent or theoretical.

Sequencing: **L ∥ M ∥ P**, then N, then O (O also spot-checks P's attribution in the tree).

## The cd explorer: a later phase

Designed above, not built here. The serving surface is separate groundwork already in flight — a
qits-spa-cd Angular 21 skeleton at `baseHref: "/cd/"` mirroring qits-spa-events, and the documented
Quinoa wiring in qits-cd that embeds it. That work is not part of this feature's workstreams and is
tracked with its own agents.

State of the prerequisites, so a future session can lift this straight into workstreams:

| Prerequisite | State |
|---|---|
| `qits-spa-cd` repository exists and is seeded | **Done** — created with an initial commit on `main` (`fcde7fa`), so `git submodule add` works against it directly |
| Angular 21 skeleton at `baseHref: "/cd/"` | **In flight** (groundwork) |
| Quinoa wiring in qits-cd (see below) | **In flight** (groundwork) |
| Submodule wired twice — superproject `frontends/qits-spa-cd`, and qits-cd at `service/src/main/webui` (qits-cd has no `.gitmodules` at all today) | **In flight** (groundwork) |
| Superproject `run-args` | **Nothing to do** — cd is already deployed, and the SPA adds no datasource and no new URL |
| Gateway | **Nothing to do** — `/cd` is already in `QitsService`, already has a `proxy-hosts` entry, already forwards verbatim, already behind the session policy |

The Quinoa wiring row is the whole platform checklist, and qits-cd starts from nothing: no
`quinoa.version` in the root pom, no dependency in `service/pom.xml`, no `quarkus.quinoa.*` key in
`application.properties`, no `webui` directory. It needs `quinoa.version` 2.8.2 and the
`io.quarkiverse.quinoa:quarkus-quinoa` dependency; `ui-root-path=/cd`, `enable-spa-routing=true`
and `build-dir=dist/qits-spa-cd/browser`; the Dockerfile's five install flags and the `cp -a`
EXDEV dance around Quinoa's move of `build-dir` across an overlayfs layer; `**/node_modules`,
`service/src/main/webui/.angular` and `**/.quinoa` in `.dockerignore` with `dist/` deliberately
kept; the CI recipe moving from `ci-base` to `node-docker-base` with the submodule init and
lockfile-origin rewrite; a `WebUiRedirect` for `/cd` → `/cd/`; and the 404-not-HTML probe
`CdPackagedSurfaceIT` currently lacks. `ignored-path-prefixes` can be **left unset** here — unlike
qits-ci, cd has no literal route outside `quarkus.rest.path` and `non-application-root-path`, so
Quinoa's derivation is complete and cannot drift.

What remains for the cd phase itself, once the groundwork lands:

1. **The screens**, exactly as designed above.
2. **cd's `run_id`** — `V2__deployment_run_id.sql`, `CdEventController` reading the `runId` it
   already receives, `DeployService.onBuildSucceeded` carrying it, the `CdDeploymentDto` field, and
   the commit-cell link to `/ci/runs/<runId>` that completes the ci↔cd click-through.
3. **`@qits/ui-components` 0.0.4** — a `{ label: 'CD', href: '/cd/' }` entry in `QITS_NAV_LINKS`.
   This is the release train, run once before: publish the library, bump the dependency in **all
   seven** SPAs, and update the `toHaveLength(7)` assertion in each `app.spec.ts` to eight. It
   belongs in this phase and not earlier — a nav link to a segment serving nothing is worse than no
   link, and a UI nobody can navigate to is not shipped.

## Out of scope, named so nobody drifts into it

- **Any write.** No cancel, no re-run, no redeploy, no environment or application management. Both
  screens read.
- **A causation explorer.** Walking `Event → the runs it triggered → the events those published` is
  the natural next feature, it is why `?triggerEventId=` is named as a fast-follow, and it is not
  this one. qits-spa-events stays a skeleton.
- **Live push to the browser.** No SSE, no websocket subscription from either SPA (Decision 5).
- **Search, free-text filtering, date ranges, saved views.** The tree is the navigation.
- **Cross-project or cross-repository aggregate views** — "all failing runs", "everything deployed
  today". Those are dashboards, they need aggregate endpoints no service has, and they are not what
  a project-centric explorer is.
- **Log download, artifact links, image digests on the run page.** qits-ci records none of them on a
  run.
- **Extracting a shared frontend API package**, or moving any join into `@qits/ui-components`
  (Decision 2).
- **Renaming `?repositoryId=`** for symmetry with cd (Decision 6).
- **Angular 22.** The host node is 22.22.0 and Angular CLI 22 needs ≥22.22.3. Every SPA moves
  together when the platform node does, and not before.
