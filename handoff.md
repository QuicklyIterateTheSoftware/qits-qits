# Handoff

Updated 2026-08-06 (late). Everything shipped-and-verified has been removed; history is
in git. What remains is open, pending, or standing. This is the ONE handoff document —
handover.md (the userflow plan) is folded in below and deleted.

## In flight right now

- **The platform plane is readable, and the gateway is on it** (2026-08-07, late). **Shipped and
  verified live** — eleven containers healthy, every gateway route 200, both planes screenshotted.
  Two changes that turned out to be one question: "why does the Deployments page show three
  applications when eleven are running?"
  - `GET /deployments` takes a required `environmentId`, so the plane that has **no** environment id
    could not be asked for at all — every platform row was recorded and then unreadable. It now
    accepts `?environmentId=platform`, the stand-in `ApplicationKeys` already puts at the front of a
    platform application's id. It cannot be mistaken for a tier (an environment id is a random
    UUID), and it is a named plane rather than a widening: no filter is still a 400.
  - qits-platform-spa-deployments grew a third root, **Platform services**, beside the projects and
    the unmatched-environments bucket. `loadEnvironment` became `loadPlane`: one branch (which
    listing holds the applications — the environment aggregate, or the flat `GET /applications`) and
    one pair of caches keyed by an environment id *or* the word `platform`. The bucket starts
    **closed** — the unmatched bucket is free because its contents arrive with the page, this one
    costs the same two requests as any other expansion.
  - **qits-gateway is a PLATFORM service now.** It publishes the host's only port and every
    environment is reached through that one origin, so a per-tier copy was always a second binder
    for port 8080. `available_on_env` went with the flip: it made the gateway an environment's
    public node, and a platform service joins every environment's per-application networks
    unconditionally — the only thing left behind is the bundle network, whose only member was the
    gateway itself. Verified: the new container holds `qits-platform`, `qits-net` and all three
    `qits-env-dev-*` networks.

  Things worth not rediscovering:
  - **environment → platform is a supported one-way conversion, and it is complete on the DB side.**
    `registerPlatform` drops the links *and* absorbs every environment-scoped deployment row —
    ACTIVE becomes DECOMMISSIONED and `environment_id` is nulled, so the tier's history moves into
    the plane rather than being orphaned. Nothing had to be fixed by hand. The reverse is a 409.
  - **What the conversion does NOT do is stop the old container**, and that is the whole operational
    catch. `predecessorsOf` keeps an alias holder only when its `qits.platform.deployments.environment`
    label is absent or equals this deployment's — and a platform deployment's is null. So the
    tier-labelled gateway was invisible to the cutover; left alone it would have held port 8080 and
    the successor's `docker run` would simply have failed. **Delete the old container before
    promoting.**
  - **`aliasHolders` uses `docker ps -q`, not `-a`** — stopping a predecessor is enough to hide it
    from the cutover, which is what makes "stop, deploy, remove" a safe order if you want a rollback
    in hand.
  - **The git host is reachable directly on `localhost:8081`** (`http://localhost:8081/artifacts/git/<repo>`),
    which is how you push while the gateway is down. CI and the deployer never need the gateway
    either: the CI step clones `qits-artifacts:8080` and the deployer pulls `localhost:8081`.
  - **`run-args` are keyed by application name, not by plane**, so `-p 8080:8080` survived the flip
    untouched. They live in `/work/config/application.properties` on the deployer's config volume —
    not in its env, which is where you will look first.
  - Push `main`, wait for green, *then* push `platform/main`: two runs of one sha collide on the
    shared image tag when they overlap, and sequential costs one cached rebuild.

  qits-gateway's `environment/dev` branch is **deleted** on the git host — the repo now carries
  `main` and `platform/main` only, both at the deployed sha. Its tip was already an ancestor of
  `main`, so no commit was orphaned, and the delete triggered no build.

  **Left open:** the page draws project `qits` as **"no environment"**
  and puts `dev` in the unmatched bucket: the join is `environment.name === project.slug`, and since
  the env re-model the environment is named `dev` while the only project's slug is `qits`. That
  convention is stale, and it predates all of this.

- **Wrapper repository as a first-class concept + projects UI** (2026-08-07). **Implemented
  and green in worktrees; NOT merged, NOT pushed, NOT deployed.** Plan:
  `~/.claude/plans/lets-start-by-planning-valiant-dragon.md`. Branch `feat/wrapper-first-class`
  in worktrees under `/home/wohlben/code/qits-wrapper-work/` (qits-projects, qits-spa-projects,
  qits-spa-ci, qits-spa-workspaces, qits-qits, qits-cli-bootstrap); main checkouts untouched.
  What landed: (A) qits-projects release A — archetypes SERVICE/DAEMON/LIBRARY/FRONTEND/CLI/
  IMAGE (+ deprecated INTEGRATION/APPLICATION aliases, widening-only V3), server-side wrapper
  commits (`amendTree` + `WrapperGitmodules` + `WrapperSubmoduleWriter`), create = url XOR
  name (blank repos seeded from new `repository-template/`), wrapper-driven reconcile +
  `POST .../repositories/reconcile` + wrapper block on the repositories list, membership
  guard on write paths, submodule import surface deleted, self-seed reads the wrapper (
  `platformManifest()` deleted), `RepositoryDto.name`; full verify + PackagedSurfaceIT green,
  native binary built and boot-checked. (B) archetype unions widened in ci/workspaces SPAs.
  (C) qits-spa-projects fully built (sub-nav picker, six type groups, wrapper status +
  reconcile report, create page; 69 tests green) and verified against the committed
  openapi.yml. (D) qits-qits: all 31 `.gitmodules` urls now relative `../<name>.git`,
  `integrations/*` moved to `libs/*`, docs updated; CLI `repoPath` follows; resolution
  smoke-tested against both a local and the GitHub origin.
  Empty-manifest semantics: a wrapper with no `.gitmodules` entries disables the membership
  guard and deregistration until the first entry exists (deploy-day safety).
  **Next steps, in order**: review diffs → merge each worktree branch to its repo's main →
  push through the platform git host → deploy release A → deploy the wrapper bump (after A)
  → run the repositories reconcile once → then release B (V4: row updates, qits-backend→FORK,
  tighten constraint, drop `repository_submodule`; delete deprecated enum constants; drop
  legacy union arms in the three SPAs). First reconcile will deregister the legacy
  fixture-sibling rows (testing-repo etc.) — expected; host repos survive.

- **The navigation is the gateway's answer now, and the sidebar has a sub-menu**
  (2026-08-07, late). **Shipped and verified on the live platform** — all eleven containers
  healthy, every gateway route 200, and the reading room screenshotted with ONE left column.
  Two things at once, because they are the same shape.
  `QITS_NAV_LINKS` — eight `{label, href}` entries compiled into a published npm package —
  is **deleted**. qits-gateway answers `GET /main-navigation` from its own `RouteTable`, so a
  component appears in the menu exactly when this gateway routes it, and `QitsMainLayout`
  fetches it through `provideQitsNavigation()`. `QitsService` now carries display identity
  (label + position) beside routing identity; **no label means no menu entry**, which is how
  `stt` (no SPA) and `cd` (superseded) stay out. `/v2` is excluded by construction — it is a
  protocol root docker hardcodes, not a page. `Home` is prepended: the landing SPA is the
  gateway's own static output and is in no route table.
  Underneath the *active* entry the layout renders a **sub-menu slot** — a `TemplateRef`
  handed sideways through the injector, because `QitsMainLayout` is a route component and
  nothing can be projected up into it. `qits-platform-spa-docs` is the only consumer: its
  second left column is **gone**, and the catalog tree plus the version picker live in the
  sub-menu instead. `scope.ts` is deleted (the tree *is* the scope→site list), `scopes.ts` is
  a landing page, and the reader is the iframe alone.
  Things worth not rediscovering:
  - **A caret range cannot pin a prerelease.** All nine SPAs pin
    `2026.806.184725-main.gc03ad30` **exactly**. `^2026.806.184725-main.gc03ad30` also admits
    the plain `2026.806.184725`, which npm prefers because it sorts higher — and that release
    predates `QitsPicker`, `QitsNavSubmenu` and `provideQitsNavigation()`. It installs
    silently and the build dies on "has no exported member 'QitsPicker'". The old
    `^…-main.g404b2c4` pin only worked because the stable release did not exist yet.
  - **`ci-event-upstream-ui-components.yml` in eight SPAs follows a `SoftwareRelease` of
    @qits/ui-components** and force-pushes a bump onto `maintenance/qits-spa-ui-components`.
    Releasing the library mid-change would have stampeded a nine-repo train over half-finished
    code, so **no formal release was cut** — the prerelease pin is deliberate, and a release
    plus its cascade is a separate later step.
  - **`git diff --cached --quiet` reports clean for a moved gitlink** under `ignore = all`,
    so a "did anything stage?" guard silently skips every submodule bump. `git status --short
    --ignore-submodules=none` shows the truth; so does `--ignore-submodules=none` on the diff.
  - **`QitsNavSubmenu` must be declared in the app SHELL**, beside the `<router-outlet />`,
    never inside a page: `RouterOutlet` rebuilds a page on every hop, so a declaration there
    loses the tree's scroll position and open groups each time a document is opened.
  - The slot is a **stack, not a slot** — two pages are alive at once during a hop, and a
    single nullable field lets whichever is destroyed last clear a template still on screen.
  - `.qits-layout-nav` needed `min-height: 0`: a grid item defaults to `min-height: auto`, so
    a tall sub-menu grows the row instead of scrolling and the sidebar runs off the viewport.
  - The **gateway ships twice** — once for `/main-navigation`, once for the home SPA gitlink.
    Its `src/main/webui` is a second checkout of qits-spa-home and was three months stale
    (`@qits/ui-components@^0.0.4`); missing it is how this cascade half-lands invisibly.
  - Multi-module services carry the client at `service/src/main/webui`; only qits-gateway and
    qits-platform-docs use `src/main/webui`.

  Proved in a browser, not inferred: clicking a site in the tree and picking a version are both
  **router hops** — a marker set on `window` before the click survives both, which is what says
  the shell (and with it the tree's scroll position) was never rebuilt. `window.location.assign`
  is gone from `onVersion`. Back leaves the versioned URL for the unversioned one rather than
  walking the frame's own history. The iframe is version-addressed, never the bare
  `/platform-docs/<site>` — that path is the service's redirect *to the reader*, and pointing the
  frame at it renders the page inside itself. Below 768px the burger reveals the nav with the
  sub-menu inside it. No console error, no page error, no failed request on any SPA.

  **The release train then ran, end to end** (`@qits/ui-components@2026.807.122825`). npm
  `latest` moved off the pre-picker build, a real Storybook bundle joined `0.0.0-smoke` in the
  docs store, and every SPA came off its exact prerelease pin onto an ordinary `^` range. All
  nine services are current against their deploy branches and all eleven containers healthy.
  Switching versions is proved across two real versions now: the URL and the iframe both
  change, a `window` marker survives, and the tree keeps its state.
  - **`POST /workspaces/api/branches/release` is the door, and it refuses a branch already
    merged.** Work pushed straight to `main` via the escape hatch therefore cannot be released
    from where it landed — the release only moves forward from a branch carrying a commit
    `main` does not have. The CalVer stamp rides along, so that commit can be small.
  - **The double-build races are systemic, not luck.** A release promotes to `main`,
    `environment/dev` *and* `platform/main`, so three or four builds of one commit hit one
    docker daemon and collide on the shared image tag. Three forms appeared in one train:
    `No such image` at a COPY, `AlreadyExists` on tag create, and `tag does not exist` on push.
    Two hit a deploying branch (qits-ci, qits-observability); in both the image was already
    present and complete, so the fix was a **build-succeeded replay, not a rebuild**. This is
    the open follow-up "spec-aware release promotion" with evidence attached.
  - **The replay needs a token minted as the `qits-ci` client, not `qits-artifacts`.** The
    deployer wants audience `qits-platform-deployments`; the `qits-artifacts` client is granted
    `qits-ci, qits-cd, qits-artifacts, qits-workspaces, qits-gateway` and gets a flat 401. Its
    idp registration was never updated after the cd merge-back. `qits-ci` carries the audience.
  - **The train pushes to the platform git host only** — GitHub was behind on sixteen repos
    afterwards and had to be synced by hand. Beware `git ls-remote <url> main`: it can match
    more than one ref, and the resulting two-line "sha" makes every later git command fail in a
    way that reads as "not a fast-forward". Ask for `refs/heads/main`.
  - The deploy order that matters if this is ever repeated: **gateway first** (a library that
    ships before `/main-navigation` exists collapses every SPA's chrome to a single `/` link at
    once — there is no version negotiation), then the library, then the SPAs, then the webui
    gitlinks. qits-artifacts, qits-ci and qits-platform-deployments each went **alone against an
    empty queue**: they host the registry and git host, build everything, and deploy everything
    respectively.

- **Documentation is a published artifact** (2026-08-07). A `docs` repository type in
  qits-artifacts holds one immutable bundle per version at
  `/artifacts/docs/docs/<site>/-/<version>`; a release pipeline declares `{type: docs}` beside
  its package; `qits-platform-docs` is the reading surface at `/platform-docs`. The store
  answers what exists, the reader answers what to read.
  **Shipped and verified on the live platform**: qits-artifacts is deployed on `18c1128` and a
  real 9.7 MB Storybook bundle publishes (201, 53 files) and serves back through it;
  qits-gateway is deployed on `cf2129b` with the `/platform-docs` route; qits-ci is deployed on
  `9bd8726`, so the `docs` artifact type and `$QITS_DOCS_URL` are live and a release pipeline can
  now declare documentation. All ten platform containers healthy after the three rollovers.
  **qits-platform-docs is deployed and serving**: `/platform-docs/@qits/ui-components/` answers
  302 to the newest version and renders the workbench through the gateway, with no failed request
  and no page error. Its own reading is proved separately on qits-net, so the redirect is this
  service resolving `latest` from the store's rows rather than the gateway's landing page
  answering 200 — a distinction that cost a false "ready" reading earlier and is worth checking
  the BODY for, never the status code alone.
  **The reading room** (2026-08-07, later; **restructured the same night** — see the navigation
  entry above, which supersedes the layout described here). It had three layers: `/platform-docs/`
  listed what publishes documentation by scope, `/platform-docs/@qits` listed what that scope
  publishes, and `/platform-docs/read/<site>/-/<version>` showed one bundle with a **QitsPicker**
  beside it. The middle layer is **gone** — `scope.ts` is deleted and the `:scope` route with it,
  because the sub-menu's catalog tree *is* the scope→site list and two implementations of it fed
  by the same `catalog()` could disagree. `/platform-docs/` is now a landing page, the reader is
  the iframe alone, and the picker lives in the platform sidebar. The service still falls through
  for a single `@`-prefixed segment so a scope page could be served; nothing claims it now, and
  `DocsPaths.NOT_RESERVED` still reserves `read/`. `qits-platform-spa-docs` is the client,
  Quinoa-served from qits-platform-docs; the store gained `GET /artifacts/docs/<repo>` (the catalog
  it could not previously be asked) and the reader gained `/api/sites` and `/api/versions`.
  Three things in there are worth not rediscovering:
  - **`DocsRoutes.ROUTE_ORDER` is 20 000 and the client does not render without it.** Quinoa
    registers static resources at 1060 and its SPA fallback near 40 000. Below 1060, `SITE` claims
    the client's own `main-<hash>.js` — one alphanumeric segment, a perfectly good site name — asks
    the store for its versions and answers 404: the index renders and every asset is gone. Both
    Quinoa numbers are read off the jar and are not API.
  - **`route.url` under a `read/**` route includes the literal `read` segment.** Leaving it in made
    the site `read/@qits/ui-components`, which pointed the iframe back at the reader — five nested
    rails in a screenshot before it was caught.
  - **Every SPA now pins a prerelease of @qits/ui-components**, not `latest` — all nine at
    `2026.806.184725-main.gc03ad30`, exactly, no caret. A ui-components release turns those back
    into ordinary ranges. Was one client on the `main` dist-tag; it is all of them now.

  Two pieces of platform state are hand-made and want a bootstrap run to become generated:
  - **The gateway's `QITS_GATEWAY_PROXY_HOSTS_PLATFORM_DOCS` entry was appended by hand** to
    `/work/config/application.properties` on the qits-platform-deployments-config volume, and the
    deployer was restarted to read it. `cli/qits-cli-bootstrap` now generates that line, so the
    next bootstrap regenerates the file identically rather than diverging — but until one runs,
    that volume is edited state.
  - **qits-platform-docs is not registered in qits-projects.** `POST
    /projects/api/projects/{id}/repositories` assigns a **UUID** id, and
    qits-platform-deployments derives the image name from the repoId — so it looked for
    `qits/1adb8e08-…:<sha>` and reported `IMAGE_MISSING` while CI had pushed
    `qits/qits-platform-docs:<sha>`. Fixed by creating the repo on the git host under its bare
    name (`PUT /artifacts/git/qits-platform-docs`, body `{"defaultBranch":"main"}`) and pushing
    there; the two UUID rows were then deleted rather than left pointing at an id nothing uses.
    **The underlying mismatch is unfixed** — either the projects API should let a caller choose
    the id, or the deployer should resolve the image from the application name.
  - `@qits/ui-components@0.0.0-smoke` is a **hand-published docs version in the live store** from
    verification. Harmless — it dedupes against the real one and the own engine ages it out — but
    it came from no release, and it is currently what `latest` resolves to.
  - The docs half of a ui-components release only fires on `SCMRelease`; a push to `main`
    publishes the npm prerelease and no docs version, by design.
  Three build failures on the way, each a real gap now closed: a non-exhaustive `switch` over
  `RepositoryType` that local incremental compilation hid, a `./mvnw` line in a step container
  that has no JDK, and `quarkus.package.output-name` without its
  `jar.add-runner-suffix=false` twin. The last is now on the checklist in
  `docs/project-setup-quinoa-angular.md`, which mentioned neither key.

- **The shell bootstrap is retired** (2026-08-07): `qits-local-up.sh` is now a shim that
  compiles `cli/qits-cli-bootstrap` and runs it, passing modes, flags and every `QITS_*`
  variable through. It pins the wrapper directory, the clones and the log, so the run no
  longer depends on where you stand, and recompiles only when the sources are newer than
  the binary (`QITS_CLI_BUILD=always|never` overrides). The 1298-line POSIX port is in git
  history; its operational comments live in the CLI's sources, which is now the only place
  they exist. The CLI's AGENTS.md and README no longer claim the CLI is unproven — that
  claim was already false when the v3 cutover shipped. `local-platform.md` gained the new
  invocation and a header warning that the rest of it predates the v3 merge-back.
  **Proved by two full `unwrap` + `bootstrap` cycles**, and each found a real bug:
  - A **stale CI row failed a phase in zero seconds**. On a rerun nothing is pushed, so no
    new run exists, and the CLI read the newest run at that sha as this phase's outcome.
    qits-workspaces carries four runs at one commit from the release train, two red and two
    green, newest red — so the phase died while the deployment it had just asked for went on
    to land. The deployment-row side of that wait already had a baseline id; the CI-run side
    now has the same one. A stale GREEN row still counts on purpose: it means no new run is
    coming, which is what the lost-event replay acts on.
  - The CLI **falls back to `bootstrap` only when given no arguments at all**, so a leading
    flag was an unknown top-level option and `./qits-local-up.sh --skip-build` would have
    failed. The shim names the mode when the first argument is a flag; `--help` and
    `--version` still reach the top level.

  The second cycle finished clean in 3m44s: 43 phases of 45 (2 skipped as already
  published), no phase warnings, all ten applications healthy, every gateway route 200,
  and `/workspaces/` verified in a browser (real data, no console errors). A warm cycle is
  that cheap because `unwrap` removes the seed images but not docker's build cache, and the
  volumes keep the registry blobs — so the deployables are pulled, not rebuilt.
- **v3 IS LIVE AND FULLY WIRED**: qits-platform-deployments (the cd+serviceregistry
  merge-back) runs the platform — 7 platform services from `platform/main`, 3 dev
  services from `environment/dev`, deployed by the native CLI (15 proving-run fixes,
  green cold bootstrap 22m29s, warm cycle: unwrap 11s + bootstrap 3m29s). The browser
  view (`:8480`, `0.0.0.0` default for WSL2) is proven live. The gateway serves the
  real home SPA; `/platform-deployments/` serves the relocated deployments UI.
- **The release train ran END TO END and COMPLETED** (2026-08-06 evening): the
  ui-components release (`2026.806.184725`, the Deployments nav entry) cascaded through
  all seven SPA releases and the full service tier; every sidebar now links
  `Deployments -> /platform-deployments/`. All ten containers healthy on the released
  builds; ALL release commits are synced into the checkouts and GitHub; zero unpushed
  commits anywhere. Cascade frictions handled: three twin-build image races replayed
  (the -o qits.no-ci discipline matters), one orphaned step-container name collision
  cleared, two SPA specs pinning the old nav fixed and released, the retired qits-cd's
  event triggers stripped (its resurrection was blocked by a failed env-branch build;
  triggers are gone now). Cosmetic leftovers: a handful of red quiet-ref runs, and the
  imageless release-train repos auto-registered in the services listing (amendment-7
  consequence, harmless).
- **GC pins retargeted** (2026-08-07, qits-artifacts `9779c38`): the pin source was still
  `http://qits-cd:8080/cd/api/pins`, which resolves nowhere since the merge-back — so every
  plan and every sweep aborted fail-closed and the cleanup page showed the outage. It reads
  `http://qits-platform-deployments:8080/platform-deployments/api/pins` now, the same
  `{"pins":[{"applicationName","shas"}]}` shape from `RollbackPins`. The report's source
  name, its outcome sentences and the keep reason name the deployer too. **The `cd-` config
  keys deliberately keep their names** — renaming one loses a deployment's override in
  silence, and nothing sets them. Found along the way and fixed: the native
  `PackagedProcessIT` was already red before this change, expecting an aborted sweep to
  report an untouchable pool it never measured.
  Still stale, cosmetic, not shipped: `qits-spa-artifacts`' cleanup-page banner prose says
  "live pins from qits-cd and qits-ci". It only renders when the pins fail, which this fix
  stops, and moving it costs a SPA release plus a webui bump — worth folding into the next
  qits-spa-artifacts release rather than a cascade of its own.
- **Open follow-ups**: qits-ci's image-pull/health-gate prose still names qits-cd (facts
  hold); `target` vs `deploymentTarget` wire spelling; buildkit migration for the
  remaining SPA-service pipelines (`--network qits-net` relies on the legacy builder);
  spec-aware release promotion (today both deploy branches push, double/triple builds);
  the enforcement flip (`qits.platform.deployments.legacy-network=` empty) + the
  cross-app URL migration it needs; two cosmetic red runs on qits-spa-cd/home mains
  (interim spec commits, superseded by their releases).
- **Known first-run debts fixed tonight in the CLI**: stale ACTIVE rows without
  containers, tab-eating output sanitizer vs the container check, write-shaped
  auth-plane probes, pinned-only seed publishes (version immutability!), bearer on the
  deployer's guarded environment writes.

## Parked workstream: userflows (folded from handover.md)

First real usage of `libs/qits-userflows` (the Playwright user-story framework:
@UserStory/@UserflowPrecondition/@UserflowRunsAfter, topological orderer,
UserflowContext, report emission) + writing the doctrine into the module's doctext
(package-info). The design, adjusted to v3:

- **Execution profiles**, two axes: environment kind (mocked | a live scope — `dev`,
  later `preprod`/`prod`, plus the PLATFORM scope) and vantage (in-network | external).
  A profile = a small properties file (`qits.userflows.profile`); one gateway base URL
  covers UI + API. Profiles should eventually DERIVE from qits-platform-deployments'
  registry instead of being hand-written.
- **Capabilities**: a plain marker interface (e.g. RepositoryExists) accepted by
  @UserflowPrecondition; providers are stories annotated @UserflowProvides + an
  environments gate — mocked provider stubs, live provider IS the real create-flow.
  Resolution over the classes in the run; zero/two active providers = hard error.
- Phasing: framework profiles+gating+doctext -> capabilities -> first consumer in
  qits-ci (mocked profile against the packaged app + StubGitHost) -> live-external ->
  live in-network (CI pipeline; step env needs a gateway URL) -> publish reports to the
  pre-seeded ci-screenshots/ci-videos artifact types.
- Open questions that remain: where the cross-service suite lives long-term; packaged
  vs dev-mode boot for mocked runs; surefire/failsafe chain constraint; auth for live
  profiles (idp machine tokens); report identity per profile.
- Stale note fixed on pickup: UserflowTarget's javadoc references -Pextended, which no
  longer exists (the `extended` JUnit tag + -DskipITs=false is the convention).

## Awaiting user verdicts

1. **WO-b judgment call**: the merge panel left the workspaces overview (merging lives
   on the detail route). Keep it that way, or bring a merge entry point back.

2. **The `qits-spa-cd` → `qits-platform-spa-deployments` rename is COMMITTED and pushed**
   (2026-08-07). The client repo is `7543720`, qits-platform-deployments `4271a2a`, the
   bootstrap `85ad5f5`, and this repository carries the submodule at
   `frontends/qits-platform-spa-deployments`. The Angular project key and
   `quarkus.quinoa.build-dir` moved together, as they had to; `docker/Dockerfile`'s
   `RUN d=…/dist/<name>/browser` guard is the third spelling of that path and moved with them.
   The rename was cut from `61986bf`, a release behind, and is **rebased onto `48cf39d`**
   (`2026.807.122943`) — so GitHub is no longer a release behind, and the released
   `^2026.807.122825` ui-components pin is kept.
   **Still carrying the old name, all of it platform-side state**: the git-host repository, the
   CI repository id, the deployments application row, and the image repository
   `qits/qits-spa-cd`. A `--with-volumes` unwrap plus a rebootstrap is what recreates them under
   the new name; until that runs, they are the whole of what is left.

Resolved 2026-08-06: the **git-storage flip executed, and the file backend retired
the same day** (user: "the disk storage should be gone"). All 41 repositories imported
and three-check-verified; every path proven live: protection + both bypasses,
post-receive → CI, repository create/import over HTTP, history reads, the full release
train (SCMRelease → event run → SoftwareRelease), workspace container provisioning, a
service deploy, and qits-artifacts redeploying itself from its own DFS store — twice,
the second time as the dfs-only binary (`508e598`). The `qits-repositories` volume is
deleted (tarball: `~/qits-git-bares-final-2026-08-06.tar.gz`), the file-backend code
is gone, and `qits-local-up.sh` seeds over the wire (home `6843faf`). Full record in
git history: `git show 3d4382b:git-host-storage-unification-plan.md`.

Resolved 2026-08-06: the rewritten **`qits-local-up.sh` is proven end to end** — a full
cold bootstrap ran green in an isolated docker-in-docker daemon: seed stack, wire
repository creation, release replays, then all ten applications built and deployed
through the platform's own pipeline, qits-cd's self-update handoff included, gateway
healthy and the DFS git host serving clones. Five attempts; each earlier failure was a
real cold-start bug, all fixed: the `${user.home}` heredoc bashism (`b03bce2`); no
released artifacts on a fresh platform — bootstrap now replays the four publishers'
release pipelines (`3a19ed0`, `97bda56`); H2's compiled-check defect killing every run
after pool idle — V5 had dropped constraint names V1 never created; fixed for real
with a Java migration (qits-ci `4439c4b`, deployed live); stale webui gitlinks in
qits-ci/qits-cd pinning pre-CalVer `@qits/ui-components@0.0.4` (`b698b99`, `8ef8a8f`,
deployed live; qits-spa-ci's main had also never been pushed to the platform host);
and a lost fire-and-forget build-succeeded event — the deploy wait now replays it once
when a run is green with no deployment row (`97bda56`). Then the REAL platform was
torn down (containers, all volumes including the DFS store, network, every seed and
build image, the musl toolchain) and cold-bootstrapped from source on the host daemon:
green in ~22 minutes (docker layer cache carried unchanged sources), all ten
applications healthy, 32 repos on the fresh DFS host, blob API and clones serving, no
bares volume. The skip-build caveat is gone — both paths are proven. NOTE the reset:
run/deployment/event history restarted, throwaway probe repos (drift-forge, sv-train,
the UUID imports) are gone, idp client secrets were kept (.qits-bootstrap.env). This
unblocks the env re-model rollout (user's runbook).

Resolved 2026-08-06: the git host gained **content-read endpoints** (user's ask) —
`GET /artifacts/git/{repoId}/blob/{rev}/{path}` (raw bytes) and `…/tree/{rev}[/{path}]`
(JSON listing), `{rev}` a branch/tag or full sha, resolved sha in the `Git-Commit-Sha`
header, unauthenticated like the rest of the host (qits-artifacts `3f8ca71`). qits-ci
consumed them (`1d01e2b`): the bare-mirror cache, fetch/retry machinery, the CONTENDED
requeue path, and the git binary itself left the image — config is read at the exact
event sha over HTTP. Both deployed and proven live (a drift-forge push ran green with
no other config path in existence). Natural follow-up, not done: qits-projects'
`GitSubmoduleParser` (`git show <rev>:.gitmodules` in its mirror) is the second
consumer of the same verb. qits-workspaces' mirror cache **stays** — merges and
preflights are computations the wire cannot express, not file reads.

Resolved 2026-08-06: the explorer copy (old item 1) shipped — lede approved as-is, the
count punctuated, excluded rows say "not collected" (qits-spa-artifacts `85ea629`,
live via the qits-artifacts webui bump `a72cfd7`, verified in the browser). Note the
shape of that release: a green qits-spa-* run ships nothing by itself — the SPA goes
live only when qits-artifacts bumps its `service/src/main/webui` submodule and
redeploys, queue empty first (self-hosting landmine).

## Open work, not user-gated

- **First real GC sweep**: currently a proven no-op (2-day-old platform, everything
  inside the windows). When the store ages past P30D, run the README's first-sweep
  choreography (review the per-repo or global dry-run → H2 backup + blob listing →
  sweep → verify store-summary balance, cd restart pulls, evicted proxy package
  re-caches). Nothing sweeps without the review.
- **SHUTDOWN COMPACT** maintenance restart: the only way packument CLOB space comes
  back after proxy evictions; documented in qits-artifacts README, never run by code.
- **ci-screenshots / ci-videos GC**: excluded by configuration today; the user wants an
  own-like "$last versions" strategy for them eventually (out of scope for now).
- **Log-streaming leftovers**: none since 2026-08-05 — qits-events gained its OpenAPI
  export test (every repo has one now). Standing note: qits-artifacts publishes
  `paths: {}` (raw-route service — fine, known).

## Longer-term backlog (from settled plans)

- **Workspace views**: the pre-PoC overview tree shipped; the real model is
  project → epic → workspace views (user's mental model, recorded 2026-08-04) — future
  design work.
- **qits-idp**: machine auth is live platform-wide; the user-auth track of
  qits-idp-plan.md (gateway pointing at idp for humans) remains.
- **Workspace-launched dev services telemetry (LD-b): NOT PLANNED** (user decision
  2026-08-05). Console capture is the answer for both daemons; qits-observability's
  README "missing sender" note is a description, not a TODO.
- **Durable log retention (LG): SETTLED** (user decision 2026-08-05). qits adds no
  external component that cannot be embedded into the Quarkus app — no third-party log
  backend, no sidecar collector. The bounded live window stands; if it ever proves
  insufficient, the only path is a qits-owned persistent store inside
  qits-observability.
- **Git pack GC** (old BD): separate, DFS-gated, untouched by the GC reshape.

## Standing facts and landmines (not in memory files)

- **Release a self-hosting repo only after its epic build drained the queue** — a
  release run's npm install can race the redeploy of the service building it.
- Security model: publish surfaces are tokenless on qits-net by decision; qits-idp
  gates them together when its user track lands. `DaemonOpenPublishTest` and siblings
  pin this — re-gating one surface alone fails the build.
- idp token endpoint is not reachable via gateway; call it on `qits-net`. Machine auth
  is ON live (`QITS_AUTH_MACHINE_REQUIRED=true`); only the `qits-artifacts` idp client
  carries `project=*` (see memory: machine-token-minting).
- Git storage: DFS-only since 2026-08-06 — packs, indexes and reftables are blobs in
  qits-artifacts' own store, cataloged in H2 (`git_pack`/`git_pack_file`); there is no
  file backend, no storage config property, and no `qits-repositories` volume anymore.
  Rollback is roll-forward: every prior image sha serves the same DFS store.
  **Never run `DfsGarbageCollector`**: in a store without deletes it doubles the
  footprint (plan §1.7; posture ⚖2(b) — no git GC, in writing). The git CLI cannot
  open a DFS repo — every operation is the wire protocol; receive-pack is the sole
  writer of everything. `DfsBlockCache` rides its 32 MiB default, which today's whole
  git host fits inside. The rewritten `qits-local-up.sh` wire-seeding flow has not yet
  run a fresh bootstrap end to end — watch the first one.
- musl builder supply-chain flag stands: `FROM localhost:8081/...` + toolchain fetched
  from `more.musl.cc` per build.
- qits-ci: a record targeted by a MapStruct mapper needs `clean` after changing (stale
  generated impl → `NoSuchMethodError`); same family as stale `target/` after source
  deletions. qits-cd joined the family 2026-08-06: after a method-signature change,
  plain `verify` ran callers against the stale class (32 false 500s) — use
  `clean verify` after signature changes.
- GC operational shape: per-repository plan/sweep are subresources under
  `/artifacts/api/gc/repositories/`; pins are fetched per run from qits-cd
  `/cd/api/pins` and qits-ci `/ci/api/daemon`, any failure aborts the whole run; blob
  bytes lag identity deletion by up to two runs (row-less + 7-day grace); Σ(per-repo
  reclaim) ≤ global by design.
- Log export: all eleven services (idp included) carry the explicit
  `quarkus.otel.logs.*` block + an `OtelLogConfigTest` drift guard; the behavioral
  proof lives once, in qits-events (`OtelLogBridgeTest`/`PackagedLogBridgeIT`).
  Resource identity (`service.version` = deploy sha) is injected by qits-cd at
  `docker run`; a service shows it after its first post-2026-08-05 deploy.

## Preserve

- Root untracked user files: `daemon-artifact-identity-plan.md`,
  `workspace-overview-ux.md`.
- `services/qits-workspaces/.claude/` is user-owned and untracked.
- Do not reintroduce EventStream as a CI/Workspaces submodule or reactor module.
- QuarkusTest on this host: pass `-Dquarkus.http.test-port=0` (8081 is the npm
  registry).
- Moving the daemon pin stays a human act: edit cd run-args volume + compose, restart
  qits-cd, then redeploy qits-ci — in that order (qits-cd caches run-args at boot).
