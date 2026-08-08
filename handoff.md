# Handoff

Updated 2026-08-08. Everything shipped-and-verified has been removed; history is
in git. What remains is open, pending, or standing. This is the ONE handoff document —
handover.md (the userflow plan) is folded in below and deleted.

## In flight right now

- **Deployable images (new concept)** (started 2026-08-08): docker images as
  deployable services — first case `images/qits-oci-postgresql`
  (GitHub repo created by the user, submodule added: wrapper `aa271d4`, unpushed).
  A repo holds a Dockerfile (FROM postgres:18.4) + `.config/qits`, and rides the
  NORMAL lifecycle: SCM release → CI image build → SoftwareRelease → the env's
  qits-deployments deploys it. PoC scope = behave like any Quarkus service
  deployment; proper configuration comes later.
  **Design settled after a four-explorer sweep** (findings in session history):
  - The build side needs NO platform change. CI steps are generic `{image,
    script}`; `images/qits-oci` is the in-tree precedent (Dockerfile-only repo,
    release pipeline, docker artifacts → SoftwareRelease). The repo carries
    `ci-post-receive.yml` (sha-tagged image, the tag the deployer resolves:
    `$QITS_REGISTRY/$QITS_IMAGE_REPOSITORY/<repo>:$QITS_CI_SHA`) and
    `ci-event-release.yml` (`artifacts: [{type: docker}]` → SoftwareRelease).
    Base images pull through the OCI mirror: `FROM localhost:8081/hub/library/postgres:18.4`.
  - The release side needs NO change: the flow is stack-agnostic ("a repository
    with no stack is still a release"); `deployments.yml` with
    `deploy_branches: environment/prod` makes the release promote the deploy ref,
    whose CI-hot push is what actually deploys.
  - The deploy side needs ONE change: the health gate is unconditional
    `curl -fsS http://localhost:8080<health_path>` (DockerDeploymentDriver:711),
    which no non-HTTP image can pass, and run-args cannot carry a quoted
    override. **New optional spec key `health_cmd`** (mutually exclusive with
    `health_path`; used verbatim as `--health-cmd`) in the strict
    DeploymentSpecParser + driver. Ordering: the deployer change must be LIVE
    before this repo's first deploy (unknown key = failed deployment; the
    workspaces reader is lenient, releases unaffected).
  - PoC accepts: no volume (data dies with the container), `POSTGRES_PASSWORD`
    baked as a placeholder in the Dockerfile; both go through the real
    config mechanism later (volumes/env stay deployer-side run-args by trust
    design). Consumers dial the wire alias `prod-qits-oci-postgresql:5432`;
    no gateway route (routes are a gateway enum; not needed for TCP peers).
  - Bootstrap: NOT added to PlatformModel DEPLOYABLES/SEEDED_REPOS — it enters
    the platform through the normal repo lifecycle after bootstrap settles.
  **Repo seeded and pushed** (`6dbfc60` on GitHub main): Dockerfile,
  .dockerignore, both CI pipelines (release extraction uses jq — allowed here,
  this repo is never in the bootstrap path), deployments.yml with `health_cmd:
  pg_isready -U postgres`, README.
  **Deployer `health_cmd` SHIPPED IN CODE** (qits-deployments `d552f1c`, main,
  LOCAL ONLY — not pushed): optional key, any non-blank one-line string ≤512
  chars (no charset allowlist — it IS the command, runs in the repo's own
  container, one argv element), mutually exclusive with `health_path`; carried
  spec→Target→Plan→StartSpec, deliberately NOT persisted (spec is re-read per
  deploy; the catalogue-resolving arm only records FAILED rows). `clean verify`
  green: 190 tests, 0 failures. Docs updated (README/AGENTS/spec header).
  Spot-checked by the orchestrator: seeded pipeline files match the CI schema;
  `QITS_CI_REPOSITORY_URL` confirmed injected (CiDaemonLauncher:508).
  **NEXT (blocked on the cold bootstrap settling):** release qits-deployments
  through the release endpoint (branch ahead of main + marker commit — NEVER a
  direct main push), push wrapper `aa271d4`, get qits-oci-postgresql onto the
  platform git host (reconcile adopts it from the wrapper), then prove the
  lifecycle: push → sha image → release → SoftwareRelease → deployment row
  ACTIVE with postgres passing `pg_isready`. Deploy ORDER: the health_cmd
  deployer must be live BEFORE this repo's first deploy (strict parser fails
  on the unknown key).

- **Maven Central proxy in qits-platform-artifacts: CODE COMPLETE, UNMERGED**
  (2026-08-08): a brainstorm about extracting the blob store exposed a gap —
  there was NO Maven proxying anywhere; CI's `.qits-maven-settings.xml` mirrors
  only `qits-maven`, so every step container pulls the whole Central tree from
  repo1.maven.org directly. Implemented on the npm-proxy blueprint, commit
  `7d1d488` on branch `feat/maven-central-proxy` in worktree
  `/home/wohlben/code/qits-maven-proxy-work/qits-platform-artifacts` (main
  checkout verified pristine — the bootstrap runs from it). Full `verify` green:
  611 tests, 0 failures. Landed: `RepositoryType.MAVEN_PROXY`, seeded repo
  `central` (repo's own recorded name, not `maven-central`); V13 migration
  (widened type check + `maven_proxy_metadata` table; cached files are ordinary
  `maven_artifact` rows, so census/explorer/GC needed no new liveness code);
  `MavenUpstream` miss path; metadata TTL PT1H with ETag AND Last-Modified
  revalidation (plain file-server mirrors have no ETag) + serve-stale; deploy to
  proxy = 405; GC cache strategy, window P90D (maven-packages' own resolve-
  cadence argument), identity = path not coordinate (a cache self-repairs, a
  publish doesn't — documented contrast in both adapters); config
  `qits.artifacts.maven.proxy.upstream` + `.metadata-ttl`. Worktree-only
  caveat: `service/src/main/webui` submodule was tar-copied from the main
  checkout (worktree add leaves it empty; not in the commit). Fixed in passing:
  `PackagedProcessIT` asserted 8 repo types against a 9-constant enum (native-
  only, never ran in verify) — now 10. Integration checklist (from the
  implementer): base is `9a0e5c0`; if another workstream lands first, check
  (a) V13 not taken — else renumber AND re-enumerate
  `ck_artifact_repository_type` from the merged `RepositoryType.values()`,
  (b) the type-count tests (`GcPlanControllerTest` 9→10, `PackagedProcessIT`
  8→10) as conflict sites, (c) merge the `GcTypeConfigTest` maven-proxy hunk,
  don't resolve it away. Deploy via the release endpoint, never a direct main
  push. Post-deploy smoke (suite has no network): `curl -sI
  <host>/artifacts/maven/central/org/slf4j/slf4j-api/2.0.13/slf4j-api-2.0.13.jar`
  → 200 with `Cache-Control: … immutable`, second call from the blob store.
  **NEXT (user-gated)**: merge to main +
  release (after the bootstrap settles), and the separate verdict on wiring CI
  through it (a `central` mirror in `.qits-maven-settings.xml` — behavior
  change across all builds, makes artifacts a hard dep of dependency
  resolution). The blob-extraction brainstorm itself is SHELVED (shared
  content-addressed store across envs; works, notes in session history).

- **Deployment unification: CODE COMPLETE, PRE-BOOTSTRAP** (2026-08-08): all of
  `deployment-unification-plan.md` phases 1-5 implemented by parallel subagents,
  every touched repo green on its own suite. Landed: qits-platform-edge (new
  service, host-header env demux, ws+SSE passthrough, native, platform target);
  deployer rework (aliases `<env>-qits-<app>` / bare platform names, container
  `qits-pd-<app>-<id8>` platform shape, platform branch matching via env rows,
  parser `deploy_branches` in / `branch:` out); workspaces spec-driven promotions
  (+quiet trunk pushes; no-spec repos promote nothing); specs in all deployables
  (`deploy_branches: environment/prod`; 4 platform targets: edge/idp/artifacts/
  docs); six submodule renames locally (wrapper plumbing verified); rename
  internals in artifacts/idp/deployments + both SPA chains; idp identity model
  (clients prod-qits-ci, qits-platform-artifacts, prod-qits-workspaces,
  prod-qits-gateway; +aud prod-qits-deployments; qits-cd dropped); gateway XFF
  multi-hop semantics (ws allow-list carry-across included) + CD retirement +
  defaultHost deletion; pipeline-file wire-name sweep (only live dials were
  ci/workspaces maven build-args; rest comments); platform-name defaults baked
  (incl. deployer's load-bearing git-host-url); bootstrap CLI prod rework
  (93 tests, native built: env default prod, one deploy ref, edge second-to-last
  before the deployer handoff, seed containers named by wire alias, volumes
  renamed, fail-loud sources, unwrap patterns widened). qits-platform-edge added
  as wrapper submodule. All repos pushed to GitHub (gateway rebased onto its two
  backup-synced release commits first). `unwrap --with-volumes` DONE (11
  containers, all volumes, 28 images — old world gone). COLD BOOTSTRAP IN
  PROGRESS, runs so far: 1+2 failed on qits-ci seed testCompile —
  MachineGuardTest used QitsClaims.CI/CD, constants deleted from
  qits-integrations-quarkus; local verify was green only because ~/.m2 served
  the OLD auth-core jar; the seed registry serves the new one (drift the
  clone-alone rule hides; fixed: test owns its audience literals, qits-ci
  4410b73, pushed). Run 3+4 + manual probe: quay.io unreachable from this host
  (TLS connection reset, multiple CDN IPs, plain curl too) — likely edge
  throttling after today's repeated image pulls; backoff probe retrying every
  5 min, bootstrap resumes when quay answers (seed stack through qits/ci is
  built and cached; unwrap deleted the mirrored builder images, so the daemon
  musl build MUST re-pull quay). History resets with the volumes — accepted.
  Cosmetic debt deferred: Maven artifactIds/application.name/output-name keep
  old names; spec headers still say "qits-platform-deployments" in prose.

- **Deployment re-model brainstorm** (started 2026-08-08): `deployment-model-draft.md`
  in this repo. Section 1 (the lifecycle today: release → refs → build → deploy, the
  bus, the self-hosting knot) is written. Section 2's current sketch (after three
  superseded iterations, all recorded in the doc: platform plane gateway+idp, then
  +observability + admission test, then per-env idps with an issuer hierarchy —
  dropped as too many cans of worms; then per-env artifacts with a cache
  hierarchy — dropped as bloat): **every env runs the same full stack;
  "qits-platform" IS production; a platform service = an application deployed ONLY
  into prod, its REPO named `qits-platform-<x>` and dialed by that name unprefixed
  (singletons need no instance qualifier; env services are `<env>-qits-<app>`),
  joined to every env's networks. Exactly
  FIVE: qits-platform-edge + qits-platform-idp + qits-platform-artifacts +
  qits-platform-docs (the docs reader follows its store: a per-env reader = three
  front doors onto one store) + qits-platform-dns (one zone authority, names the
  envs, host :53 — deployment stays out of the MVP).** The bar: per-env copies
  cannot do the job (one port, one trust root, one zone authority) OR would
  multiply heavy shared-by-nature state for no isolation gain (the store and its
  views). The
  edge routes UNIFORMLY by host name — apex qits.eu → prod-qits-gateway exactly
  like `*.dev.$domain` → dev-qits-gateway (matches qits-dns's model); route table
  = env list, knows no app names. Idp: ONE issuer for all envs; env isolation
  lives in the TOKEN MODEL — env-qualified client ids + audiences (`dev-qits-ci`,
  `aud=dev-qits-deployments`); `aud=platform-…` is the normal way envs reach
  platform services (`aud=qits-platform-artifacts`); a dev secret cannot mint
  prod-valid tokens. Accepted cost:
  idp changes cannot be staged in an env — idp must stay maximally boring.
  Artifacts (user decision, supersedes the earlier no-cut/hierarchy verdict):
  ONE store, unsplit — git host, registries, proxy caches, blobs, docs for every
  env; promotion collapses (built once, visible everywhere, "promote" = deploy
  that sha); the GC becomes MULTI-DEPLOYMENTS AWARE — keep = UNION of every
  env's pins (each env's deployments + ci, endpoints via injected config),
  fail-closed across ALL sources (one dead env blocks GC platform-wide,
  accepted); it is the one platform service that calls INTO envs (periodic,
  read-only). Remaining prod role: BOOTSTRAP ORIGIN (CLI boots prod; prod
  creates + first-deploys the other envs). Observability per-env; platform
  services export to prod's sink. Naming (settled): qualified names EVERYWHERE
  on the wire (`<env>-qits-<app>` / `qits-platform-<app>`); images stay
  env-agnostic (peer names only via deployer-injected config — the invariant to
  protect). Swarm fits (stack-per-env naming for env services, platform services
  as plain swarm services under their repo names, VIP cutover; no L7 host
  routing — edge stays; reshape cost: deployer's docker-run/aliasHolders →
  `service update`). Envs (settled): three, fixed —
  dev/preprod/prod; NOT epic-scoped (maybe later). Open: lifecycle re-wiring
  around the one store (post-receive fan-out per ref → which env's ci; who owns
  `main` builds; per-env bus vs one store), promotion remainder (where "release
  to prod" runs; rebuild vs reuse across deploy refs), env-creation choreography
  (idp grants, stack, DNS, connecting the platform services + GC pin
  endpoints), prod's self-hosting knot (contained, not dissolved). Draft by
  declaration — iterate, don't obey it.
  **Implementation plan APPROVED in its decisions** (user, 2026-08-08):
  `deployment-unification-plan.md` — 7 phases to a clean cold bootstrap in the
  target shape, MVP = ONE env named **prod** (no second env). Decisions D1–D5:
  D1 retire `platform/main` (deploy refs = `environment/<env>` only; platform =
  qits-platform-* repo name + prod-only + all-nets flag; fixes the stale-plane
  release bugs by reading refs from the repo's deployments spec). D2 the edge =
  new repo `services/qits-platform-edge` — CREATED on GitHub 2026-08-08, verified:
  has `main` + initial commit (submodule add works directly). D3 repo naming:
  platform repos = `qits-platform-<x>`, env repos plain. **GitHub renames DONE
  (user, 2026-08-08), VERIFIED via ls-remote**: platform-deployments→deployments,
  platform-spa-deployments→spa-deployments (the `qits--spa-deployments` double
  dash was a message typo, real name correct), artifacts→platform-artifacts,
  idp→platform-idp, dns→platform-dns, spa-artifacts→platform-spa-artifacts;
  docs + spa-docs were already right. Local wrapper-submodule renames = phase 4
  (GitHub redirects cover old-name remotes meanwhile). Leftover: `platform/main`
  branches still on GitHub for platform-artifacts/platform-idp/deployments —
  delete in phase 3 (D1). D4 no swarm in this
  plan. D5 GC ships UNCHANGED in the MVP (single pin-source pair, new URLs only);
  the multi-deployments reshape is deferred with a HARD GATE: must land BEFORE
  any second env exists (else that env's pins are invisible → over-deletion).
  Phases: 1 config plumbing (hardcoded-peer audit, deployer naming scheme +
  injected qualified names) → 2 the edge (gateway sheds :8080; browser pass incl.
  websockets/SSE is the gate) → 3 refs/release flow → 4 renames → 5 bootstrap CLI
  (default env `prod`, qualified idp clients/audiences) → 6 THE CLEAN BOOTSTRAP
  (unwrap --with-volumes; 12 containers; verification checklist in the plan;
  history resets) → 7 deferred (GC multi-pin GATE, second env, multi-env wiring,
  swarm, dns).

- **Epics overview on the project detail page** (2026-08-08). **Released and live**:
  qits-spa-projects 2026.808.105044, qits-projects 2026.808.110015; container on the
  release sha, deployment row ACTIVE, live page verified in the browser (empty state —
  live has no epics yet). The releasing itself: the SPA release auto-triggered the
  `maintenance/qits-spa-projects` follow-bump in qits-projects, so a manual webui
  gitlink bump is redundant — reconcile onto the moved main and release only the code.
  - Backend: immutable git-safe `slug` on Epic/Feature/Task — V2 migration (backfill +
    per-scope dedupe), `Slugs.java`, DTOs, openapi. H2 note: `regexp_replace` takes no
    `g` flag.
  - SPA: read-only epic→feature→task tree on the project page — client-side fan-out,
    status badges from `implementedOn`/`implementedAt`, compare links are muted
    placeholders (no compare UI exists yet).
  - **Branch naming convention adopted** (per-level prefixes, no path-prefix conflicts):
    `epic/<epic>`, `feature/<epic>/<feature>`, `task/<epic>/<feature>/<task>`.
    Documented in qits-projects AGENTS.md ("Branch naming").
  **Open:**
  - qits-workspaces CaptureService mints `feature/<timestamp>` capture branches that
    collide directory-wise with the new feature branches — needs a new prefix,
    separate workstream.
  - Compare/commits view to replace the placeholders; epic-level implemented state for
    zero-feature epics (Epic has no implemented field, so those can only show "open").
  - quarkus:dev in qits-projects transparently reads PRODUCTION: Quinoa's dev proxy
    matches ignored-path-prefixes (`/api,/q,/mcp`) against the RAW path, so with
    `ui-root-path=/projects` every GET under `/projects/api` misses the ignore list,
    goes to the Quinoa-spawned `ng serve`, whose `proxy.conf.json` (wired via
    angular.json) targets `localhost:8080` — the live gateway. Live 404s fall through
    to local REST; non-GETs skip Quinoa — hence "reads live, writes 404" (writes only
    saw the local DB, which lacks the live ids). Fix candidates: point webui
    `proxy.conf.json` at the dev backend, or add the full-path forms to the ignore
    list for the dev proxy (prod matches them ui-root-relative — both spellings would
    be needed). Until fixed: verify with the packaged jar
    (`-Dqits.startup-seed.enabled=false`).

- **The platform runs on native docker-ce in the Fedora distro** (since 2026-08-08).
  Docker Desktop is uninstalled; the daemon is systemd-managed and a single-node swarm
  manager (the deployer can target swarm services later without re-plumbing); containers
  bind the real `/var/run/docker.sock`; an HKCU Run key (`qits-wsl-fedora-autostart`)
  starts the distro at Windows logon. Rebuilt by cold `./qits-local-up.sh` bootstrap —
  the how and the six bugs it surfaced are in this repo's and qits-cli-bootstrap's
  2026-08-08 commit messages.
  **Open:**
  - Prove a full host reboot end to end (dockerd + restart policies + Run key say yes;
    nobody has watched it happen).
  - qits-cli-bootstrap: a failed clone refresh must fail LOUD — stale clones with dead
    origins (pre-`libs/`-move paths) built Aug 2 sources silently until the version pins
    caught it.
  - Push the local commits: wrapper (handoff, shim fix) and qits-cli-bootstrap
    (`415ca8a`, `1ed351e`).
  - **The release flow still thinks the gateway is an environment service**: releasing
    qits-gateway (2026.808.94038) promoted `environment/dev` beside `platform/main`,
    re-creating the deleted branch (deleted again by hand). Same stale-plane bug family
    the bootstrap CLI had — qits-workspaces should read the plane from the repo's
    deployments spec, not assume both branches.
  - **The release flow pushes every promoted ref CI-hot**: one release queued four
    overlapping runs of one sha (`main` ×2, `platform/main`, `environment/dev`) — the
    image-tag collision the bootstrap avoids with `-o qits.no-ci` on the quiet refs. All
    four happened to pass; the flow should push non-deploy refs quietly.

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

- **Sync targets + automatic GitHub backup** (2026-08-07, follow-on to the wrapper work).
  **SHIPPED AND VERIFIED LIVE.** `Repository.url` is formally the backup sync target now:
  `RepositoryDto.backupUrl` ships beside a wire-deprecated `url` twin (drop it next release —
  tracked), the reconcile derives every member's target relationally (wrapper's backup
  sibling via the relative `.gitmodules` url) and healed all 32 rows to the org namespace,
  and the UI cards say **Clone** (always the platform host's name-addressed url) and
  **Backup** — the "Origin" label is dead. Backups are automatic: the git host fans its
  post-receive out to `POST /projects/api/events/post-receive` (`-o qits.no-ci` does NOT
  suppress it), qits-projects debounces per repo and pushes `refs/heads/* refs/tags/*` to
  the target; an hourly sweep (`qits.projects.backup.enabled`) covers what events miss.
  UI restructure per user: `:projectId` is a lean overview (heading + "Project setup"
  action); everything else moved to `:projectId/project-setup`; every visible "wrapper"
  became **Project repository** ("wrapper" stays informal).
  **Late-day corrections (2026-08-07 evening), all shipped:**
  - **Release-flow correction (user-called):** direct main/platform-main pushes deploy code
    but skip the real release flow. Everything from earlier today was squared with catch-up
    releases through `POST /workspaces/api/branches/release?repositoryId=…` `{branch,summary}`
    (needs the branch AHEAD of main — an empty marker commit works; the flow stamps
    `release(<version>)`, publishes SCMRelease, promotes environment/dev + platform/main
    itself). All six touched repos got stamped versions. NEVER push main directly again.
  - **SIGHUP crash (the 502s):** using the sign-in terminal killed the service — ProcessBuilder
    file redirects open in the PARENT with no O_NOCTTY, and a PID-1 session leader adopting
    the pty slave gets the kernel's SIGHUP on teardown; Quarkus treats HUP as stop. Fixed by
    opening the slave in the child (`sh -c 'exec 0<>"$0" …' <slave> setsid --ctty git …`) plus
    a log-and-ignore HUP handler. Regression test reproduces the exact signature.
    Adds /bin/sh to runtime requirements (UBI9-minimal has it).
  - **Gitlink landmine, again:** the SIGHUP-fix commit silently dragged the webui gitlink
    backwards (ignore=all hides it; the UI "reverted"). Restored. Check `git ls-tree` before
    releasing qits-projects from a worktree.
  - **Terminal paste:** the pane had no paste listener. Now a hidden-textarea capture
    (xterm.js pattern) — Ctrl+V/Cmd+V/Shift+Insert send one data message. Chromium-measured.
  - **Release D shipped:** `RepositoryDto.url` is gone; `backupUrl` is the only spelling;
    ci/workspaces SPAs dropped their declarations too.
  - **The spa-projects release train is real:** releasing qits-spa-projects fires
    `ci-event-upstream-spa-projects.yml` in qits-projects, which force-pushes
    `maintenance/qits-spa-projects` and cuts the webui-bump release itself — do NOT bump the
    gitlink by hand for SPA-only changes; the train races you (it won today, harmlessly).
  **The sign-in now lives in the UI**: the project-setup page has a Backups panel —
  per-card badges from `RepositoryDto.lastBackup` (V5 records every attempt's outcome),
  "Sync backups" (project-wide `POST …/repositories/backup-sync`, 202), and "Sign in to
  backup remote", an inline terminal driving the remote-login PTY websocket (client sends
  JSON `{type:data|resize}`, server sends raw PTY text; close 1000 = refetch; the session
  lingers 60s server-side so closing the pane mid-prompt is safe). One sign-in against
  github.com fixes every repository — the credential store is host-keyed.
  **Still pending a human: nobody has signed in yet — all 32 rows sit at AUTH_REQUIRED.** Things worth not rediscovering:
  - The deployer reads `/work/config/application.properties` at ITS boot, not per deploy —
    a run-args edit needs `docker restart` of the deployer before the next roll picks it up.
    (`QITS_PROJECTS_INTAKE_URL` was added to the qits-artifacts run-args there.)
  - Do not promote qits-artifacts and anything else to `platform/main` concurrently: the
    artifacts cutover kills the other build's registry pulls at `localhost:8081` mid-run.
  - spa-ci/spa-workspaces read `name`/`backupUrl` now; the ci tree label no longer
    basename-hacks the url.

- **Wrapper repository as a first-class concept + projects UI** (2026-08-07). **SHIPPED AND
  VERIFIED LIVE — both releases.** Release A (+A.1 drift-healing) and release B are deployed
  (`qits-pd-platform-qits-projects-34098d66`); the real qits-qits history was force-pushed
  onto the platform wrapper origin (replacing the greenfield skeleton); the reconcile
  converged: 32 rows = wrapper + 31 components, archetypes directory-derived
  (13 SERVICE, 2 DAEMON, 5 LIBRARY, 9 FRONTEND, 1 CLI, 1 IMAGE), legacy fixture rows
  deregistered, all 31 wrapper entries matched, re-running reconcile is a KEPT×31 no-op.
  The projects UI is live at `/projects/` (auto-select, picker sub-nav, type groups,
  wrapper "in sync" + reconcile button) — screenshotted. **qits-backend (the pre-split
  monolith) is fully removed**: row deleted over REST, seed entry deleted in release B;
  a straggler deployment's row simply gets deregistered by its first reconcile.
  Four origins were preseeded onto the git host so reconcile could adopt them:
  qits-workspace-daemon, qits-repositories, qits-dns, qits-cli-bootstrap.
  Things worth not rediscovering:
  - The wrapper row's backup url was the stale `wohlben/qits-qits` fork; A.1's self-seed now
    asserts manifest archetype+url onto existing rows (two-pass, shared transaction — both
    load-bearing, see SelfSeedService comments) and the manifest constant is the org url.
    Other adopted rows still carry historic urls (e.g. `wohlben/qits-gateway`) — cosmetic,
    they are backup remotes only.
  - An empty wrapper `.gitmodules` disables the membership guard and deregistration until
    the first entry exists.
  - Worktrees under `/home/wohlben/code/qits-wrapper-work/` still exist; every branch is
    merged — prune with `git worktree remove` + `git branch -d` at leisure.
  Old text follows for reference. Plan:
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
