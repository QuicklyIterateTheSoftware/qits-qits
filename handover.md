# Userflow tests — first usage: implementation plan

Status: **plan for iteration, nothing implemented — and PARKED behind priority-feature.md**
(the environment re-model must land first; it also answers open question 1 below). Branch
`userflow-tests` of the wrapper, worktree `../qits-qits-userflow-tests`, all submodules on
`main`. This document is the working handover for the workstream; update it as decisions land.

## The goal, restated

Establish the first real usage of `libs/qits-userflows` and, in the same stroke, document the
concept in the framework's own doctext (package + class javadoc), so the library explains itself.

The concept: a **userflow** is an integration test written from the user's point of view
(Playwright steps through the UI), and the *same* test executes against a spectrum of targets:

1. **Mocked** — in the owning repo's own CI pipeline ("built" tests). The environment around the
   app is stubbed; the app under test is real.
2. **Live environment, in-network** — a CI run inside the cluster, targeting the deployed
   environment the way services target each other (`http://qits-gateway:8080`).
3. **Live environment, external** — the same suite run from a developer host, targeting the same
   environment through its published ports (`http://localhost:8080`).
4. **Future environments** — `preprod`, `prod`, … must be targetable by adding configuration, not
   code. qits-cd already supports this shape: an environment is a row `(name, branch, network)`
   and several environments may track the same branch (`CdApplicationRepository.listByRepoAndBranch`).

What varies between 1 and 2–4 is **only the setup**: mocked runs stub the preconditions ("a
repository exists in qits-artifacts" → seed a stub git host), live runs *execute the userflow that
creates the precondition for real* (drive the UI/API to create the repository). The test body
never changes. That is the progressive-integration idea: one orchestration, verified from mocked
IT all the way to a real environment.

## What exists today (investigated 2026-08-06)

### The framework (`libs/qits-userflows`, artifact `eu.wohlben.qits:qits-userflows@2026.802.153255`)

Extracted standalone repo, released through the platform Maven registry. Already provides:

- `@UserStory` — meta-`@Test` + `UserStoryExtension`; one story per class; name → report slug.
- `@UserflowPrecondition(Class...)` — gating dependency: producers must run first *and pass*,
  else the dependent skips (transitively). Keyed by the producer story's slug in a JVM-wide
  `PASSED_SLUGS` set.
- `@UserflowRunsAfter(Class...)` — ordering-only edge (cleanup flows).
- `UserflowClassOrderer` — topological sort over both edge kinds; registered as the default class
  orderer via `junit-platform.properties`. Orders one surefire/failsafe run; producer and
  dependent must be the same kind (`*Test` vs `*IT`).
- `UserflowContext` — shared key→value store for producer→dependent handoff (`project.id` etc.).
- `Flow` — step-recording Playwright facade; relative navigation resolves against **one** base URL.
- `UserflowTarget` — `qits.userflows.base-url` system property (default `http://localhost:8080`)
  + `isReachable()` self-skip idiom.
- `report/` — `userflow.json` + markdown + screenshots + webm per story under
  `target/userstories/<slug>/`.
- Self-test harness stories (`…userflows.harness.*Test`) against a bundled static page — they
  prove the ordering/skip/handoff machinery with no app. New framework features get harness
  stories the same way.

### The gaps against the goal

- **No environment concept.** One flat system property for one base URL; no named execution
  profiles, no per-environment property files, no way to gate a story to certain environments.
- **No setup seam.** Preconditions are concrete classes only. There is no way to say "given
  *RepositoryExists*" and have a mocked implementation satisfy it in one profile and a real
  seeding userflow satisfy it in another.
- **No consumer.** Zero poms depend on the artifact; the "stories" module the AGENTS.md mentions
  never existed post-extraction. First usage is genuinely first.
- **Stale doc:** `UserflowTarget` javadoc still references `-Pextended`, which does not exist in
  the extracted repo (the `extended` *JUnit tag* + `-DskipITs=false` is today's convention).

### Platform facts the plan builds on

- **One gateway, path-routed.** Every UI and API is under one origin (`/ci/…`, `/artifacts/…`,
  `/cd/…`). In-network that origin is `http://qits-gateway:8080`; from the host it is
  `http://localhost:8080`. One base URL per profile covers both UI driving and API seeding.
- **qits-cd environments** are rows `(name, branch, network)` created over the API; deploys
  resolve by `(repoId, branch)`. Today's single environment is named `qits` (branch `main`,
  network `qits-net`) — the thing that "should have been called dev". Deployed containers carry
  `QITS_ENVIRONMENT=<name>`.
- **CI steps** are YAML in the repo (`.config/qits/ci-post-receive.yml`, `ci-event-*.yml`);
  scripts get addresses as env vars injected by `CiDaemonLauncher` (`QITS_MAVEN_REGISTRY_URL`,
  `QITS_WORKSPACES_URL`, …). **There is no `QITS_GATEWAY_URL` yet** — the in-cluster run needs
  one added.
- `qits/build-images/userflows-base` (Playwright Java + maven + git + jq) already exists and runs
  the framework's own pipeline.
- qits-artifacts pre-seeds `ci-screenshots` / `ci-videos` repository types that nothing fills yet
  ("the golden-diff loop has never produced a screenshot") — the natural later sink for userflow
  reports.
- qits-ci's suite conventions show what "mocked environment" means here: **no WireMock anywhere**;
  hand-rolled stubs that speak the real wire shape (`StubGitHost`, `StubEventsServer`), test
  config pointing unused collaborators at dead ports (`http://localhost:1/…`).
- The clone-alone rule: every repo builds against the platform Maven registry with no prior
  install. A consumer module therefore depends on a *released* `qits-userflows` version — the
  framework must release before consumers can build in CI (locally, `mvn install` bridges).

## Design

Two orthogonal axes, and it pays to keep them separate:

- **Environment kind** — is the world around the app real or mocked? Values: `mocked` or the name
  of a live environment (`qits`, later `preprod`, `prod`). Decides *which setup implementation
  runs*.
- **Vantage** — where does the test process sit? In-network or external. Decides *which base URL
  (and later, credentials) apply*. Never changes which code runs.

A named **execution profile** combines both: one properties file per profile.

### 1. Execution profiles (framework)

- New system property `qits.userflows.profile` (default `mocked`). The framework loads
  `userflows/<profile>.properties` from the test classpath, then lets system properties override
  key-by-key — so `-Dqits.userflows.base-url=…` keeps working and CI can inject addresses as
  `-D` flags from env vars.
- Profile keys (initial set, deliberately small):
  - `qits.userflows.base-url` — the single origin everything resolves against.
  - `qits.userflows.env` — the environment kind (`mocked` | live env name). Defaults to the
    profile name so simple profiles need one line or none.
- New `UserflowProfile` (or fold into `UserflowTarget`) exposing `name()`, `env()`,
  `baseUrl()`, `property(key)`. `UserStoryExtension` and `UserflowTarget` read through it.
- Expected profile files for first usage (each a few lines):
  - `mocked.properties` — env `mocked`, base-url set by the consumer's own harness (the port the
    app under test booted on, passed as a `-D`).
  - `qits-external.properties` — env `qits`, base-url `http://localhost:8080`.
  - `qits-internal.properties` — env `qits`, base-url `http://qits-gateway:8080`.
  - `preprod-*.properties` etc. later: new file, no code.

### 2. Environment gating (framework)

- New annotation `@UserflowEnvironments({"mocked"})` / `{"qits", "preprod"}` (exact strings;
  maybe `"live:*"` sugar later — start without it) on the story method. The extension's
  `ExecutionCondition` skips a story whose list does not cover the current profile's env.
  Absent annotation = runs everywhere.
- The skip must interact correctly with the precondition machinery: a story skipped for
  environment reasons does not satisfy anything (already the semantics — only PASSED satisfies).

### 3. Named setup references — capabilities (framework; the core new idea)

- A **capability** is a plain marker interface in the consumer's story code, e.g.
  `interface RepositoryExists {}` — the "given" a dependent story names. Javadoc on it states the
  contract: what exists afterwards and which `UserflowContext` keys it publishes
  (`repository.id`, …).
- `@UserflowPrecondition` learns to accept an **interface** among its classes. A concrete class
  keeps today's exact semantics; an interface is resolved to its **provider** in the current run.
- A **provider** is an ordinary story class that declares what it satisfies and where it applies:

      @UserflowProvides(RepositoryExists.class)
      @UserflowEnvironments({"mocked"})
      class MockedRepositoryExistsTest { @UserStory("Given a repository (mocked)") … }

      @UserflowProvides(RepositoryExists.class)
      @UserflowEnvironments({"qits"})        // and later preprod, prod
      class CreateRepositoryIT { @UserStory("Create a repository") … }

  The mocked provider configures stubs (or seeds the stub the harness booted); the live provider
  *is* the real "create a repository" userflow — which is itself a first-class story with its own
  report. Exactly the piggyback on the ordering concept the goal asks for.
- Resolution rules (fail loudly, no magic):
  - The orderer and the extension resolve an interface reference against the story classes **in
    the current run** whose `@UserflowProvides` names it and whose environments cover the current
    env. Exactly one must match: zero → the dependent fails with a naming error (not a silent
    skip); two+ → hard error at ordering time.
  - Ordering edge: dependent after the resolved provider. Gating: dependent skips unless the
    resolved provider PASSED. Satisfaction is recorded per *capability*, beside the existing
    per-slug set.
  - No classpath scanning: resolution only sees classes JUnit already selected for the run, the
    same universe the orderer already receives. (Providers in other modules/jars are a later
    problem — see Open questions.)
- Harness self-tests: a capability with two fake providers gated to two fake envs, run twice with
  different `-Dqits.userflows.profile`, asserting the right provider ran, the wrong one skipped,
  the dependent gated correctly, and the zero/two-provider error paths.

### 4. Doctext (deliverable, not an afterthought)

The user-facing documentation **lives in the module's doctext**:

- New `package-info.java` for `eu.wohlben.qits.userflows` carrying the doctrine: what a userflow
  is, the environment-spectrum model (mocked → live envs), the two axes, profiles, capabilities,
  how a suite is structured, how the same test progresses from mocked IT to real environment run.
- Class-level javadoc on the new types (`UserflowProfile`, `@UserflowEnvironments`,
  `@UserflowProvides`) and updates to `@UserStory` / `@UserflowPrecondition` /
  `UserflowTarget` (also fixing the stale `-Pextended` reference).
- `AGENTS.md` of the framework repo updated to point at the package-info as canonical.

### 5. First consumer: qits-ci stories

The worked example from the goal: *"trigger the SoftwareRelease pipeline"*, precondition
*repository exists in qits-artifacts*.

- New maven module `userflows/` in the qits-ci reactor (test-only module: stories in `src/test`,
  depends on `eu.wohlben.qits:qits-userflows` from the platform registry — clone-alone holds).
- Stories (package `eu.wohlben.qits.ci.userflows`), sketch:
  - `RepositoryExists` capability (+ context keys).
  - `MockedRepositoryExistsTest` — seeds the harness stubs.
  - `CreateRepositoryIT` — live provider driving the real platform (create repo via
    qits-artifacts UI/API through the gateway).
  - `TriggerReleasePipelineIT`-style story: `@UserflowPrecondition(RepositoryExists.class)`,
    pushes/POSTs a trigger, watches the run appear and go green in the qits-ci SPA.
- **Mocked mode mechanics** (the open design question with a recommendation): Quinoa is off under
  `@QuarkusTest`, so a browser test cannot drive a `@QuarkusTest`-hosted app. Recommendation:
  follow the `CiPackagedSurfaceIT` pattern — a failsafe-launched **packaged** qits-ci (fast-jar,
  SPA built) with `qits.ci.git-host-url` pointed at a standalone stub git host the suite boots;
  the userflows run against that port with profile `mocked`. Alternative (cheaper, less honest):
  `quarkus dev`-style boot with Quinoa forced on. Decide during phase 3.
- Pipeline wiring: a step in qits-ci's `ci-post-receive.yml` running the userflows module with
  the `userflows-base` image (needs node for the SPA build — Quinoa's
  `package-manager-install=true` covers it, or the image grows node; measure first).

### 6. Live-environment execution

- **External (first):** from the host, `mvn verify -Dqits.userflows.profile=qits-external` in the
  consumer module. Reachability self-skip keeps it green with no platform up.
- **In-network (second):** a CI pipeline whose step runs the same command with
  `-Dqits.userflows.profile=qits-internal`. Needs:
  - `QITS_GATEWAY_URL` injected by `CiDaemonLauncher` (small qits-ci change, mirrors
    `QITS_WORKSPACES_URL`).
  - A trigger. Options: manual `POST /ci/api/events/trigger` at first (matches how the platform
    bootstraps); later a domain event when "environment deployed" becomes observable. Start
    manual.
  - A decision on *which repo's pipeline* owns the cross-service environment suite — see Open
    questions.

## Phasing

Each phase lands and releases independently; consumers pin released versions (clone-alone).

1. **Framework: profiles + environment gating + doctext.** `UserflowProfile`,
   `@UserflowEnvironments`, package-info doctrine, stale-doc fixes, harness self-tests. Release.
2. **Framework: capabilities.** Interface preconditions, `@UserflowProvides`, resolution rules,
   harness self-tests, doctext. Release. (1+2 can be one release if iteration is quick.)
3. **qits-ci userflows module, mocked profile.** The capability, both providers (live one
   compiles but only self-skips outside its env), the trigger-pipeline story, packaged-app
   harness, pipeline step. This is the first CI-run userflow.
4. **Live env, external.** Run the same suite with `qits-external` against the local platform;
   the live provider earns its keep; fix what reality breaks.
5. **Live env, in-network.** `QITS_GATEWAY_URL` in qits-ci, the suite pipeline + manual trigger.
6. **Follow-ups (parked):** publish reports/screenshots/videos to the seeded `ci-screenshots` /
   `ci-videos` repos; deployment-event trigger; `preprod`/`prod` profiles when those environments
   exist; cross-repo provider resolution if suites split across modules.

## Open questions (for iteration on this document)

1. **Naming.** Profile names `mocked` / `qits-external` / `qits-internal` — keep `qits` (the cd
   environment's actual name) or introduce the logical name `dev` now and map it? Plan assumes
   the cd row name to avoid a mapping layer.
2. **Where does the cross-service environment suite live?** Options: (a) each service repo owns
   its stories and also runs them against environments (plan's default for first usage);
   (b) a dedicated suite repo (`qits-userflows-suite`) aggregating stories for whole-platform
   runs — better fit for the by-environment progressive runs long-term, but needs cross-repo
   provider resolution (published story test-jars). Start with (a), revisit at phase 5.
3. **Mocked-mode app boot**: packaged artifact (recommended, honest, slower) vs dev-mode boot.
   Decide in phase 3 with measurements.
4. **Capability satisfaction across surefire/failsafe.** Providers as `*IT`, dependents as
   `*Test` (or mixed) won't order — same limitation as today, but capabilities make it easier to
   hit. Convention to document: within one profile, a chain lives in one runner. Enforce or just
   document?
5. **Auth.** Live profiles will eventually need credentials (qits-idp user track pending;
   machine tokens exist). Profiles are the natural carrier (`qits.userflows.token` or a mint-on-
   start hook). Out of scope until an env demands it — but the property namespace should not
   paint us into a corner.
6. **Report identity per profile.** The same story run under two profiles overwrites
   `target/userstories/<slug>/` — fine per-module/per-run today; matters when reports get
   published. Parked with phase 6.

## Investigation record (pointers)

- Framework classes: `libs/qits-userflows/qits-userflows/src/main/java/eu/wohlben/qits/userflows/`
  (`UserStoryExtension.java:57` base-url property; `UserflowClassOrderer.java`;
  `UserflowTarget.java:10` stale `-Pextended` javadoc).
- cd environment model: `services/qits-cd/cd/…/entity/CdEnvironment.java:21`,
  `…/control/EnvironmentService.java:40` (`epic/` + `qits-env-` conventions),
  `…/persistence/CdApplicationRepository.java:22` (several envs per branch).
- CI step env injection: `services/qits-ci/service/…/daemonhost/CiDaemonLauncher.java:445` — no
  gateway URL today.
- Event triggering: `services/qits-ci/ci/…/control/CiEventTriggerService.java:58`
  (`TRIGGER_BRANCH = "main"`); manual trigger `POST /ci/api/events/trigger`
  (`services/qits-ci/README.md`, "Triggering one by hand").
- Stub conventions: `services/qits-ci/service/src/test/java/…/githost/StubGitHost.java`;
  packaged-app pattern `CiPackagedSurfaceIT`.
- Report sink candidates: `services/qits-artifacts/README.md:93,1690` (`ci-screenshots`,
  `ci-videos` seeded, excluded from GC, never yet written).
- The framework's own pipelines: `libs/qits-userflows/.config/qits/ci-post-receive.yml`
  (`mvn verify` on `userflows-base`), `ci-event-release.yml` (registry publish on `SCMRelease`).
