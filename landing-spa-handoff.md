# Handoff: the landing SPA (qits-landing-app), epic qits-112

Written 2026-10-03 ~01:00 at shutdown. Actionable state only. Read this, then
`git log` on the branch below.

## In flight right now (2026-10-03 morning)

- USER 2026-10-03: the deployed app is defunct until another agent finishes qits-528 (edge deny /
  delete travel; the apex `/projects` goes to qits-projects today). Until then: LOCAL work only, NO new
  release requests for qits-landing-app; stack branches. The wrong `qits-landing` origin in
  `/main-navigation` (edge NavigationRoute, gap in qits-328) is parked with that topic.

- Shipped overnight: landing 2026.1003.61026 + .61311, qits-projects-service 2026.1002.225915
  (finish states), wrapper 14d57b64. Flaky screenshot fixed by `ca63bfe` (--disable-partial-raster).
- Finish pact DONE: `22b000a` on `external/finish-pact`, request **272f3a68** PENDING (provider
  check passed locally, 28/28).
- Undo DONE: `f08b160` on `external/finish-undo` (on top of the pact). No release request yet:
  waits for the user's look. 152 tests green; checked in a browser on mocked API only.
- Branch stack (all pushed, no RR): `external/finish-pact` 22b000a (RR 272f3a68) → `external/finish-undo`
  f08b160 → `external/owner-origins` d963e68 (origins from /main-navigation, dev keeps proxy via
  environment.development.ts) → `external/otel` d964344 (SSR + browser OTel, export proven locally) → `external/route-pages`
  7fe1b47 (origin check, editor iframe from navigation) + 21b141c (routes/ tree, loadComponent,
  work-archive, guard in core/auth). Bundle 506.56 kB (warns; budget 500 unchanged): browser OTel
  SDK ~138 kB in main; API client runtime bundled 4× (~12 kB each). Old screenshot baselines are
  orphaned at their old paths (moved specs need regenerating). Stack needs origin/main merged.
  → `external/import-aliases` d8632cc ($core/$ui/$patterns in tsconfig paths; routes/ and api/ stay
  relative; no-restricted-imports bans relative climbs into the three trees).
  → baef68e (orphaned baselines dropped) → `external/page-screenshots` f3c706f + merge 45a4b49 =
  STACK TOP, the user's checkout sits here. Every page has a browser spec (events, observability,
  work-item are still blank pages).
- Lazy OTel SDK: jslib `external/lazy-otel` 0822e36, RR **a5f1ad91** (after 68e15b85).
- Rule `qits/page-has-screenshots`: jslib `external/page-screenshots-rule` 83c2feb, RR **e020b3a9** (after a5f1ad91); root.page.ts needs an eslint-disable with reason.
- Landing initial bundle 403.5 kB with lazy OTel. After the three jslib RRs release: exact-pin @qits/angular in landing.
- USER DECISION golden-master enforcement for page/layout screenshot specs: jslib
  `external/golden-master-guard` (on page-screenshots-rule): deep-frozen, registered recordings +
  `guardGoldenMasters()` wrapping TestRequest.flush (2xx body must be a recording) + lint
  `qits/browser-spec-data-from-golden-masters`. qits-projects `external/two-projects-state` (state
  "two projects exist", RR to come) replaces the picker's spread copy. Then landing switch-over: install
  the guard in setup.ts, picker uses the new state, shell layout spec gets a selected-project case.
- Guard detail: jslib 4403cb2 + d55538e (rule refuses provider overrides of ANY `core/` token) +
  `allowTokens` option (landing allows only EVENT_SOURCE; payloads via assertRecorded). Landing
  violations to fix in the switch-over: picker 72/83/103 (needs qits-projects states), editor
  SelectedProject + AppOrigins useValue (feed AppOrigins from the edge golden master), repositories
  SelectedProject useValue, work-archive EVENT_SOURCE (allowed).
- Guard final: jslib d849b00 (allowTokens, fix advice "new provider state + pact interaction" in
  every message, `pactedGoldenMasters(masters, pactFile)` refuses a state/op no pact interaction
  uses), RR **2b994127** (carries the 3 lower jslib branches too). Landing switch-over steps: wrap
  readers with pactedGoldenMasters in vitest-browser.config.ts; src/testing/browser/golden-master.ts
  = fromGoldenMasters(read, source); guardGoldenMasters() in setup.ts; specs use that helper; lint
  `allowTokens: ['EVENT_SOURCE']`; fix editor/repositories/picker violations.
- RELEASED 10:19: @qits/angular **2026.1003.81521** holds ALL jslib work (route rules, lazy OTel,
  page-has-screenshots, golden-master guard, pactedGoldenMasters); edge **2026.1003.81928**
  (@qits/edge-golden-masters). CI runner is back. NEXT: landing pin bump + switch-over.
- USER DECISION: golden masters required in EVERY browser spec except src/app/ui/** (only dumb UI
  components may use synthetic data). jslib `external/golden-masters-beyond-pages` 499f7bc, RR **b90409e0** (option
  `syntheticAllowed`, rule + guard). Landing switch-over agent makes patterns specs comply now;
  a second pin bump picks up the widened defaults.
- In flight: landing `external/guard-switch-over` (pin 81521, rules, nav pact, guard, shell spec,
  patterns compliance) and `external/card-screenshots` e256eac (user checkout is HERE) + qits-projects
  `external/card-states` 8c13d17e, RR **4d3ad6a3** (carries e9451cf1's branch too). After it releases:
  pin @qits/projects-golden-masters, drop the 10 `it.skip` card cases + run the pact spec once with
  QITS_GOLDEN_UPDATE=true. Card shows no ticket type (BUG/IMPROVEMENT/MAINTENANCE look alike).
- 2026-10-03 ~10:00: CI's only runner "workstation" (80253c4a) is QUARANTINED since 09:27, so all
  runs are queued (edge d745e377, jslib 68e15b85/a5f1ad91/e020b3a9/2b994127, projects e9451cf1).
  The user has dispatched another agent to fix it: do not greenlight / health-check it yourself.
- qits-projects `external/two-projects-state` 3347cbd9, RR **e9451cf1**: states "two projects exist"
  (qits-00000001 + telemetry-00000002; repos/entities for qits only), "no projects exist", "a
  project with one repository" (= wrapper + one: the card should not count the wrapper; fix there).
- Asked the user (no answer yet): withdraw jslib 68e15b85/a5f1ad91/e020b3a9, since 2b994127 carries all.
- /main-navigation pact: edge `cefd530` on `external/navigation-pact`, RELEASED **2026.1003.81928** (RR d745e377; tests only; the qits-528 workspace agent JOINED its epic branch to it at 09:40, so each push there refolds and cancels the gate;
  qits-528 thread told). After it releases: landing adds `@qits/edge-golden-masters` (exact pin),
  `edgeGoldenMasters` in src/testing/golden-masters.ts, a pact spec next to AppOrigins (provider
  `qits-edge-service`, state "a published navigation", op `getMainNavigation`, consumes only
  `applications.<app>.origin`), commits `pacts/qits-landing-app_qits-edge-service.json`, publishes
  the pact jar; then the edge pins the jar, `REQUIRED = true` in ClasspathPactLoader and drops
  `@IgnoreNoPactsToVerify`.
- USER DECISION routes on the filesystem: `src/app/routes/` mirrors the URL, `[param]` dirs,
  `<name>.page.ts` / class `<Name>Page`, layout `<name>.layout.ts` / `<Name>Layout`. Lint rules
  `qits/page-location`, `qits/page-suffix`, `qits/route-matches-directory` go in @qits/angular
  (jslib `external/route-pages` 9698b35 + 9efed97 traceparent option `propagateTraceHeaderCorsUrls`,
  RR **68e15b85**). After release: exact-pin bump in landing (rules then bite; tree must be moved).
- USER: budget STAYS 500 kB; instead every route uses loadComponent (route-pages). If still over, the OTel SDK may need lazy loading in @qits/angular. OTel open: `/api/*` on the apex must
  reach the landing app (follows the edge work).
- TODO after otel lands, on top of the stack: security review of d963e68 — AppOrigins must accept
  only `https:` origins whose host is the page host or a subdomain of it; anything else counts as
  missing. The fail-open session guard on a failed navigation stays (the edge's login wall covers it).
- USER 2026-10-03 on the open points: (1) YES pact for /main-navigation: agent building the edge
  provider side on qits-edge-service `external/navigation-pact` (worktree, no RR; another agent owns
  qits-528 edge work on its epic branch); landing consumer interaction follows after otel.
  (2) @qits/angular helper: later, not now. (3) keepalive loss: fine, a PWA service worker will do
  the calls later. (4) Editor iframe: replace `core/platform-host.ts` with the navigation's
  `qits-workspaces` origin; under ng serve still read /main-navigation (proxy it to the live edge):
  API calls stay on the proxy, iframe/links use navigation origins. Goes in the follow-up commit.
- USER: the app's address is the APEX https://qits.wohlben.eu (not landing.qits…). Edge logs
  "a name outside the grammar" for landing.qits…; the apex is still the projects door. Diagnosis
  agent finds the change (edge and/or deployments.yml `host:`).
- USER: add OTel, mainly for SSR: Node SDK in server.ts → `http://${QITS_ENVIRONMENT}-qits-observability:8080/observability/api/otel`
  (http/protobuf), and serve @qits/angular's browser passthrough from the SSR server. Start after
  owner-origins (same package.json/server.ts).
- Request 895ef71b (qits-731 ticket branch) re-opened after I withdrew 4928a282 by mistake.

- USER: the Work board gets 4 columns (REFINED, IMPLEMENTING, IMPLEMENTED, VERIFIED), per ticket
  qits-749 (IMPLEMENTING status, refine phase by another agent). Landing needs posted on qits-749
  (enum, a feature/task "implementing" signal, golden masters "a project with work in every status"
  re-recorded). USER: the landing column is OUT of qits-749's scope (posted); I build it on the
  stack after that qits-projects release.

- USER DESIGN: patterns/work/kanban-board (pattern) uses patterns/work/epic-card (features nested
  inside) and patterns/work/ticket-card; replaces work-board-node. Epic screenshot cases: several
  campaign memberships, several features, all tasks done. Agent on landing `external/work-patterns`
  (on card-screenshots) + qits-projects `external/epic-campaigns-state` (on card-states, RR to open).

- `external/card-screenshots` now = stack top incl. guard switch-over (aa7f97e merge, ddd5c7b,
  5edb913 no scroll container around the board). USER DESIGN: finish bubble in the BOTTOM-RIGHT
  corner on ticket, epic and feature (work-patterns agent). Open from switch-over: picker waits on
  qits-projects e9451cf1; 5 project-card LOC cases need qits-githost listLoc states keyed by the
  repository ids of "a project with 3 repositories" (+ pact interactions).

- work-patterns agent also owns: 3-shot finish interaction test (initial / clicked + toast / toast
  gone + one POST {target:DONE}); find-in-page: `hidden="until-found"` + `beforematch` expands and
  highlights collapsed cards; `selectionchange` highlights the card holding the match (UNVERIFIED that
  Chrome moves the selection while stepping matches: check with the user on the dev server).
- USER: ONE stable board order: roots (epics + tickets) by qualified-id number, children by id
  within each parent, recursively; in core/work; finishing must not reorder the rest (work-patterns).

- STACK TOP now `external/work-patterns` 0630c5a (user checkout + ng serve here): kanban-board /
  epic-card / ticket-card + work-list / epic-list-item / ticket-list-item patterns, finish-control in
  core/work, bubble bottom-right, stable id order, find-in-page (until-found + SelectionHighlight).
  qits-projects `external/epic-campaigns-state` eb00bb7c, RR **c222b68a**. After 4d3ad6a3 + c222b68a
  release: pin projects golden masters, drop `.skip`s, QITS_GOLDEN_UPDATE=true pact run.
  Campaign qits-750 filed (751 mouse DnD, 752 touch inverted DnD, 753 prioritization) — not to work on.

- qits-528 DONE; apex works. Landing RR 2c79ca8d REJECTED (51 missing references + the moved
  finish button; no code failure). New landing RR **33623a39** on `external/dev-bearer` 7c6a451
  (whole stack + dev-only bearer login); baselines job 44ccbe12 started for it (POST
  maintenance/api/repositories/qits-landing-app/release-requests/<id>/screenshot-baselines
  {"workItem":"qits-112"}).
  After it ships: check the deployed app (calls to <app>.qits.wohlben.eu, Editor iframe, menus,
  OTel relay /api/*), and that the baseline job regenerated screenshots for the moved specs.
- Edge `external/landing-origin` (agent): qits-landing origin = apex in /main-navigation. Release
  the edge ALONE when CI is idle (an edge deploy drops the CI runner socket → quarantine).
- USER asked to allow localhost:4200 at the edge CORS; I flagged that the qits-session cookie
  (SameSite=Lax, Domain=wohlben.eu) is not sent from localhost anyway; awaiting the user's pick:
  SameSite=None (advised against), local.qits.wohlben.eu → 127.0.0.1 dev host, or keep the proxy.

- USER DECISION: the landing app does NOT read /main-navigation (that was the old multi-frontend
  design). Backend origins come from an injectable `PlatformOrigins` in core/platform (one label
  table in code, domain = page host; ng serve: APIs '' via proxy, iframe via env domain). The edge
  pact consumer side + @qits/edge-golden-masters go. Agent commits ON external/work-patterns (RR
  2c79ca8d refolds).

- USER DECISION: ng serve calls services DIRECTLY with a bearer (no proxy). Plan, in order:
  (1) qits-idp `external/spa-dev-client` 9aa515c, RR **a7d556c8**: client `qits-landing-dev`, PKCE S256,
      redirect http://{localhost|127.0.0.1|[::1]}:<port>/auth/callback; access 900 s; refresh rotates
      (reuse revokes the family). Discovery advertises public endpoints to public callers.
  (2) qits-edge `external/localhost-cors` on `external/landing-origin`: CORS admits localhost/127.0.0.1
      any port, `authorization` header; bearer honoured from browser origins; SSE auth answer
      DONE ac9d8b9 (on f63308d), NO RR yet — release edge alone when CI idle. localhost gets NO
      allow-credentials (bearer only). SSE: EventSource can't send a bearer and the edge reads no
      query token; the SPA must read the stream with fetch() + a stream reader in dev.
  (3) landing `external/dev-bearer` 7c6a451 DONE (idp released 2026.1003.95120; needs the edge release
      before the user's checkout moves there — the proxy is gone): dev-only PKCE login,
      /auth/callback, bearer interceptor + refresh, PlatformOrigins dev → real hosts, proxy removed.
  Production keeps the cookie.

- RELEASED 2026.1003.95806 (RR 33623a39, whole stack + dev-bearer; baselines job joined). Deployed
  at the apex: /, /projects, /projects/qits/work answer from Express; /api/config.json relays a
  telemetry target; server OTel arrives as service qits-landing. TODO: every SSR request logs WARN
  "x-forwarded-* received but trustProxyHeaders not set" → configure Angular SSR trustProxyHeaders
  for the edge. Browser check of the live app still owed (needs the user's login).

## Next steps, in order

0. In flight:
   - Open for the user: overflow-hidden on ticket/task cards (skipped: would clip the finish button
     and the preview); one ACTIVE workspace
     per work item across all repositories (index on work_id alone).
   - Released today: landing 2026.1003.160331 (Work subnav, workspace links slots, verified tiles)
     and 2026.1003.161347 (lane grows with its id; screenshot test on "an epic with a feature whose
     tasks are all verified", golden masters 2026.1003.155934); edge 2026.1003.155243 (HTTP/2
     bodies); qits-workspaces 2026.1003.161529 (workId, listOpenWorkspaces, listWorkItemWorkspaces,
     one ACTIVE per work item); qits-projects 2026.1003.154243 (sends workId).
   - Released today (landing): 164019 workspaces store; 173957 epic boards (`app-epic-board`, 5
     columns, campaigns + epic detail for REFINED..VERIFYING epics; Archive unchanged); 175052 ┌ strip;
     175905 solid feature bars (`ui-board-row solid`) + white/20; 180303 headings unpinned
     (`ui-board [pinned]="false"`); 183455 campaign state tests + `ui-list-lane` ids never cut +
     `shootMembers`; 184026 recorded "no open workspace". qits-workspaces 183318 verifies the
     landing pact. User's checkout `external/workspace-links` at 8c15472 (= 184026's content).
   - Open for the user: one workspace page per item or per workspace; split the epic board's ui
     blocks from In Progress's (recommended: keep shared until a third switch).
   - qits-877 filed: `qits ci cancel` in the CLI.
   - Open: a qits-projects state with a DONE/DROPPED campaign (Archive campaign screenshot); campaign
     start availability from the backend (registry has no campaign phases); qits-650 (campaign
     status derived from members); import
     cycle platform-origins › environment.development › dev-bearer › dev-tokens › session.
   project-card LOC flush carries an eslint-disable until qits-githost has a matching listLoc state.
   Breadcrumbs: at 400px the header overflows; hidden "…" loses its focus ring.

1. USER DECISION: finish = **delayed commit with Undo**. The item animates out at once, and the
   DONE call goes out after ~5 s unless Undo in a toast is clicked. In progress (see above).
2. Maintenance: SETTLED. "Maintenance" is `ticketType: MAINTENANCE` on a TICKET (the platform
   files it for a stuck release request). A VERIFIED one already gets the bubble. Nothing to do.
3. Not yet measured in the dev server: the leave animation and the wider Backlog/Archive gaps.
4. After release, check the deployed app: the Editor iframe and the live menus. From localhost these
   get 401, because the `qits-session` cookie is `Domain=wohlben.eu; SameSite=Lax`.

## Open design work, as the user last asked

- **Backlog and Archive:** have their own list components that look like the board (done in
  `b3bd40a`). Let the user review them.
- **Finish bubble** (check icon, halfway out of the right edge):
  - On VERIFIED epics and VERIFIED tickets, bugs and maintenance items. Not on tasks or features.
  - It transitions the item to DONE, then animates the item to 0 size and removes it.
  - Open question: are "maintenance" items qits-projects work items? If not, they get no
    transition.
- **Parked by the user:** direct backend calls without the dev proxy (epic qits-528, edge CORS),
  and a `local.qits.wohlben.eu` dev host.
- **Not done yet:** move layout, root-redirect and the auth guard into `patterns/shell/` and
  `core/auth/`.
- **Offered, not answered:** a ticket to check every pact provider whose consumers bind a bare JSON
  array. pact-jvm then checks only the raw bytes, and that always passes. qits-maintenance was
  fixed with `listPendingBumps`.

## Rules the user set (also in memory)

- Commit subject: `term(qits-112): …`. Stage explicit paths. Never commit `__screenshots__/**`.
  Baselines come only from the platform job.
- Code layout:
  - dumb components in `src/app/ui/components/`
  - smart components in `src/app/patterns/<domain>/<component>/`
  - state in `src/app/core/<domain>/`
- Styling: Tailwind only. Hydration: toggle server-rendered parts by class (exactly one display
  class), never `@if`.
- Pacts: pact-js, next to the store. Bind consumed fields only. Every new call gets a pact
  interaction and a provider state in its provider. File `pacts/qits-landing-app_<provider-repo>.json`.
- Platform configuration lives in its own service (qits-ci), never in the wrapper.
- Push only to the platform git host, never to GitHub `origin` of a platform repo. Lockfile URLs
  must be public hosts.
- Dev server goes stale: `pkill -f "ng serve --port 4200"; rm -rf .angular/cache; npx ng serve --port 4200`
  (node 24 via `source ~/.nvm/nvm.sh`). Only one agent may own it.
