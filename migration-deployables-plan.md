# Making the services services

Status: **done for all six.** Written and executed 2026-07-27.
**Extended 2026-07-28 — all seven services now compile to a native binary; see §9,** which reverses
§6's "no native build" and supersedes §4 step 1.

| Repo | Commit | Document |
|---|---|---|
| `qits-observability` | `1c9b548` | 5 telemetry query operations |
| `qits-stt` | `ecf3c77` | `/api/speech/transcriptions` |
| `qits-ci` | `767714b` | `paths: {}` — all operations hidden by design |
| `qits-artifacts` | `1b19bdb` | `paths: {}` — hidden by design; `/git/**` is Vert.x |
| `qits-projects` | `d536596` | 24 paths |
| `qits-workspaces` | `9765b0f` (branch) | 19 paths |

Each builds from a clone of itself alone, produces `quarkus-run.jar`, and serves `/q/openapi` +
`/q/swagger-ui`. Five boot and answer routes. **`qits-workspaces` deliberately does not** — see §3;
it refuses to start without a `RepositoryLookup`, which is the behaviour its port contract specifies.

Three things this turned up that the plan did not predict, all recorded in the relevant repos'
`AGENTS.md`:

- **A test fixture was being published as a real API operation.** `OpenApiSchemaExportTest` runs as a
  `@QuarkusTest`, which indexes the *test* classpath — so `IdentityEchoResource`'s
  `/api/test-identity`, added to all six repos by the auth work, landed in the committed document. A
  client generated from it would have grown a method for an endpoint no deployment serves. Hidden
  with `@Operation(hidden = true)` in every repo.
- **`mvn verify` cannot see a missing plugin execution.** `qits-projects`' `<build>` has a
  `<testResources>` block ahead of `<plugins>`, so the plugin silently failed to apply and the suite
  stayed green — augmentation runs per `@QuarkusTest` regardless of packaging. Only booting the jar
  caught it. This is the strongest argument for §4 step 5 being part of the gate rather than a
  nicety.
- **The §9 item 14 flake has a concrete cause.** `Failed to start quarkus` is
  `Port already bound: 8081` — `@QuarkusTest` restarts racing for the test port. Not a mystery, and
  not worth investigating when it appears; re-run.

Original plan follows.
Resolves [`migration-plan.md`](migration-plan.md) §9 item 7 ("`qits-workspaces` is not yet a
deployable"), which is true of all six extracted services, and unblocked the edge-auth staging that
has since landed.

**The goal in one line:** every `services/*/service/` module stops being a library JAR and becomes
a runnable Quarkus process that serves its own OpenAPI document and swagger-ui, the way the
monolith does.

This is the fourth migration document. `migration-plan.md` maps files — this one maps **what
runs**.

---

## 1. What is actually true today

Audited across all six repos, not assumed:

| | Finding |
|---|---|
| `quarkus-maven-plugin` | declared in every **root** pom's `pluginManagement`, executed by **no** service module. No augmentation, no runnable artifact. |
| `src/main/resources/application.properties` | **does not exist in any of the six.** |
| `quarkus.rest.path=/api` | present **only** in `src/test/resources` — in all six. |
| `quarkus-smallrye-openapi` | present in five; **absent in `qits-stt`**. |
| MCP root-path | `qits-projects` and `qits-observability` set it in test resources only. |
| Cross-repo maven consumption | **nobody pulls these jars in.** No target depends on another's GAV. |

The last row is the licence for this whole change. Each `service/pom.xml` carries a comment
justifying the library-JAR shape as *"a consuming Quarkus application pulls it in and gets the
routes"* — that application was never written and, under the gateway topology, never will be. The
shape is paying a cost for a consumer that does not exist.

The `quarkus.rest.path` row is the sharpest one. Every route was written with the `/api` prefix.
A service packaged today would serve all of them one level up, and the
suites would not notice, because they set the property themselves.

## 2. The decision

**`service/` becomes the application.** Not a new `app/` module wrapping it.

- Directory names are load-bearing — they anchor the replayed git history (`migration-plan.md` §8
  step 6). `service/` must keep its name and its sources.
- A wrapper module would exist solely to hold a `application.properties` and a plugin execution.
  That is not a module.
- `domain/` stays a library JAR, and keeps shipping its defaults as
  `META-INF/microprofile-config.properties` at ordinal 100. The layering is unchanged: the app's
  own `application.properties` (ordinal 250) overrides it. **Nothing moves out of domain's
  mp-config.**

Cost, to be paid in the same commit: the "library JAR, not a deployable" paragraph in each
`service/pom.xml` and the equivalent sentence in each `README.md` become false and must be
rewritten, not left to rot.

## 3. The blocker, and it is only one repo

`qits-workspaces` injects `RepositoryLookup` **mandatorily** — `@Inject RepositoryLookup`, three
sites (`WorkspaceService`, `WorkspaceResolver`, `CaptureService`). Deliberate: a workspace cannot
exist without a repository, and misconfiguration should fail at startup.

Quarkus resolves injection at **augmentation**, so adding the build goal to
`qits-workspaces/service` fails the *build* with `UnsatisfiedResolutionException` before anything
boots. The package step and the port problem are the same problem there.

Every other port in every other repo is `@Inject Instance<T>` — optional, with documented
absent-behaviour. Verified: `qits-projects` (`WorkspaceLookup`, `WorkspaceLifecycle`),
`qits-artifacts` (`RepositoryNameResolver`), `qits-observability` (`RepositoryScopeGuard`,
`WorkspaceLookup`). **Five of six repos need no port work to package.**

**Resolution: ship an `@DefaultBean` `UnconfiguredRepositoryLookup` in
`qits-workspaces/service/src/main`**, returning `Optional.empty()`.

- `io.quarkus.arc.DefaultBean` is exactly this case: it is used only when no other bean of the type
  exists, so `FakeRepositoryLookup` still wins in the suites and no test changes.
- The behaviour is already specified — `require()` throws `NotFoundException`, so an unwired
  workspaces service answers `404 Repository not found` on every repository-scoped route. It fails
  **closed**, which is the documented posture.
- Its javadoc names its own replacement: the HTTP-backed `RepositoryLookup` against
  `qits-projects`. This is a scaffold with an expiry date, not a design.

Do **not** relax the port to `Instance<T>`. The mandatory-ness is a documented invariant; weakening
it to unblock packaging trades a startup failure for a silent one.

> **Resolved 2026-07-28 — the scaffold is gone.** `UnconfiguredRepositoryLookup` has been replaced by
> `wiring/HttpRepositoryLookup`, the qits-projects-backed implementation its javadoc always named,
> reaching `GET /projects/api/repositories/{id}` through a `@RegisterRestClient` interface. So
> `qits-workspaces` now starts and answers.
>
> The fail-closed posture is unchanged, only relocated: it was "no implementation", it is now "no
> address". One explicit key, `qits.projects.url` (scheme, host and port, no path — qits-projects
> serves its own `/projects/api` segment, so one base url is correct both on `qits-net` and through
> the gateway), and the service refuses to start in a production launch without it. Dev and test
> downgrade to a warning, and the suite's `FakeRepositoryLookup` still wins, so the replacement kept
> `@DefaultBean` — dropping it makes the two an ambiguous dependency that fails the *build*.
>
> The judgement worth knowing, because it is the whole reason the class is more than three lines:
> **only a 404 becomes `Optional.empty()`.** Any other status and any transport failure throws.
> `require()` turns empty into a 404, so folding an outage into it would report an unreachable
> qits-projects as a user mistyping an id. Verified against both native binaries: unknown id → 404,
> qits-projects killed → 500 naming the address.
>
> Deliberately not cached. `find` sits on nearly every repository-scoped route, so a cache is a real
> optimisation — and also a staleness policy for a value that changes. That is a decision to take,
> not to inherit.

## 4. The per-repo recipe

Applied six times. Steps 1–4 are the deliverable; 5–6 are the gate.

**1. Execute the plugin.** Add to `service/pom.xml`:

```xml
<plugin>
    <groupId>${quarkus.platform.group-id}</groupId>
    <artifactId>quarkus-maven-plugin</artifactId>
    <extensions>true</extensions>
    <executions>
        <execution>
            <goals>
                <goal>build</goal>
                <goal>generate-code</goal>
                <goal>generate-code-tests</goal>
            </goals>
        </execution>
    </executions>
</plugin>
```

Version comes from the root pom's `pluginManagement`, which already has it. Packaging stays `jar`;
the output is `target/quarkus-app/quarkus-run.jar` (fast-jar).

> **Superseded by §9.** This is no longer the shape to copy: the module is `<packaging>quarkus</packaging>`
> and carries no `<executions>` at all. The packaging type binds the same three goals and, unlike an
> execution block, cannot silently fail to apply — which is exactly what the `<testResources>`
> finding above describes happening.

**2. Write `service/src/main/resources/application.properties`.** App-level only — anything the
context owns stays in `domain`'s mp-config. Minimum:

```properties
quarkus.application.name=qits-<ctx>
quarkus.rest.path=/api
quarkus.http.port=8080
quarkus.smallrye-openapi.info-title=qits-<ctx> API
quarkus.swagger-ui.always-include=true
```

`quarkus.rest.path` is the one that must not be forgotten: without it every route moves, and no
suite will tell you. (It has since become `/<segment>/api` — see each repo's `AGENTS.md`.)

Per-repo additions:
- `qits-projects`, `qits-observability` — `quarkus.mcp.server.repository.http.root-path=/mcp/repository`.
  Without it the MCP server refuses to **start** (`IllegalStateException: Invalid server name`).
- `qits-projects`, `qits-observability` — promote the `actions` server path too if that server is
  carried.
- Repos with a datasource (`workspaces`, `projects`, `artifacts`, `ci`) — nothing. The named
  datasource, persistence unit and Flyway lineage already come from `domain`'s mp-config, and prod
  values are already file-H2. Overriding belongs to the deployment, not the jar.

**3. OpenAPI + apidocs.**
- Add `quarkus-smallrye-openapi` to `qits-stt` (the only one missing it).
- `quarkus.swagger-ui.always-include=true` — swagger-ui is dev-only by default; the monolith's
  apidocs habit needs it on in a packaged build.
- Endpoints land at `/q/openapi` and `/q/swagger-ui`, outside `quarkus.rest.path`.

**4. Copy `OpenApiSchemaExportTest` into each repo**, writing `docs/openapi.yml` at the repo root.
Verbatim from the monolith (`eu.wohlben.qits.openapi.OpenApiSchemaExportTest`) — a `@QuarkusTest`
that GETs `/q/openapi` and writes the file with a DO-NOT-EDIT header. Add the regeneration command
to each `AGENTS.md`, matching the monolith's:

```
./mvnw -pl service -am test -Dtest=OpenApiSchemaExportTest
```

Checking the document in makes API drift show up in a diff instead of in a deploy. It also gives
the REST-client work a real source — `docs/openapi.yml` is stale in the monolith and unusable
today.

**5. Verify from a pristine clone.** The clone-alone gate is unchanged and non-negotiable:

```
./mvnw verify                      # green, no monorepo, no docker, no credentials
java -jar service/target/quarkus-app/quarkus-run.jar
curl -sf localhost:8080/q/openapi  # 200
curl -sf localhost:8080/q/swagger-ui/   # 200
```

Boot is the new half. `mvn verify` passing has never proven these start, because augmentation never
ran outside `@QuarkusTest`.

**6. Diff the document against the monolith.** For each repo, the operations in its
`docs/openapi.yml` must be exactly the routes that repo is meant to serve and no others. This
replaces a hand-maintained map, and mechanically proves the
zero-drift claim.

## 4a. `qits-observability` goes first, and needs more than the recipe

**It is not a library that stores otel data — it is already the receiver.**
`OtelReceiverResource` serves the three standard OTLP/HTTP export endpoints under `/api/otel/v1/*`,
protobuf-only, gzip by magic bytes, teed byte-verbatim upstream before decoding. `TelemetryDecoder`,
`TelemetryStore`, `TelemetryQueryService` and the five MCP tools sit behind it. Functionally this is
the receiving service the context was meant to be.

Two things stop it from *being* a service, and only the first is this document's recipe:

**1. It is packaged as a library.** Its own README says so: *"A library jar, not an app: a consuming
Quarkus application pulls it in and gets the receiver, the routes and the tools."* §4 fixes this.

**2. Nothing sends it anything.** This is the real defect and it is invisible from inside the repo.

The overlay that pointed exporters at the receiver — `OtelEnvironment.forLaunch(...)`, which builds
`OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf`, `OTEL_SERVICE_NAME` and
`OTEL_RESOURCE_ATTRIBUTES` (carrying `qits.repository.id` / `qits.workspace.id`) — was **dropped**
during the daemon extraction. `migration-plan.md` §3.3 records it as deliberate dead-code removal:
its only callers were `CommandService.launchService` and `beginServiceRun`, both confirmed to have
no production callers. It survives only in `../qits`, in `monolith-only.txt`.

But the live path that launches dev servers is now the daemon's `ServiceSupervisor`, and that path
**never had the overlay**. Verified end to end:

- `ConfigParser` parses the `otel:` toggle from `.config/qits/repository.yml` (`ConfigParser.java:162`);
- it is carried into `ServiceDecl.otel()` (`ServiceSupervisor.java:237`);
- it is round-tripped back out by `ConfigJson.java:91`;
- **nothing reads it.** `overlayEnv` applies `decl.environment()` — the user's own declared env — and
  nothing else.

So the `otel: true` toggle is parsed, echoed, and ignored. The receiver has no senders and no
process. Both halves are broken, and the toggle round-tripping through the config is exactly why
nobody noticed.

**The work, in order:**

> **Steps 1 and 2 are out of scope — see §6.** *(2026-07-29.)* They are the sender side, and nothing
> waits on them: a workspace's dev servers run, they just do not export telemetry. Steps 3 and 4
> landed without them.

1. ~~**Rebuild the OTLP overlay in the daemon, beside `ServiceSupervisor`.**~~ `migration-plan.md` §3.3
   already nominated this home: *"If service launches ever need the OTLP overlay again it belongs
   beside `ServiceSupervisor`."* Port `OtelEnvironment.forLaunch` from `../qits`, gate it on
   `decl.otel()`, and merge it *under* `decl.environment()` so a service's own declared env still
   wins. Assert the toggle actually reaches the child process — the missing test is what let this rot.
2. ~~**Repoint the endpoint.**~~ In the monolith the exporter dialled qits itself. Split, it must dial
   `qits-observability` on `qits-net`. That is a change of meaning, not a config edit: the daemon
   learns the address from the container env it is already given, so the host must inject an
   observability endpoint alongside the thirteen `QITS_WORKSPACE_DAEMON_*` vars
   (`WorkspaceContainerFactory`) rather than deriving it from the qits host.
3. **Package it per §4.** Including the MCP root-path (`quarkus.mcp.server.repository.http.root-path`)
   without which it refuses to start, and `quarkus.rest.path=/api` without which the ingest path
   moves and every exporter 404s silently.
4. ~~**Settle the segment.**~~ **Done** — ingest is now `POST /observability/api/otel/v1/*`.
   Exporters are configured with a literal URL, so this one could not be
   deferred the way a browser-facing path can — whatever address step 2 injects has to be an address
   that actually resolves.

**Open decision — does the standalone service keep the ephemeral store?** `TelemetryStore` is
in-memory by design, with a documented two-tier eviction policy, and a JVM restart empties it. That
is defensible for an in-process buffer inside the monolith. As an independently restartable,
independently deployed process it means a routine redeploy silently discards every workspace's
telemetry. Adding persistence is a datasource, a Flyway lineage and a retention policy this repo
does not have today. **Recommendation: keep it ephemeral for now** — it is a deliberate, documented
design and changing it is a feature, not part of making the process bootable — but record the
consequence rather than discovering it after the first restart.

## 5. Order

`qits-observability` first (§4a), because its defect is a live capability regression rather than a
packaging gap, and because nothing downstream depends on the answer. Then prove the plain recipe on
the smallest and repeat.

1. **`qits-observability`** — §4a: the sender side, then the recipe, then the segment.
2. **`qits-stt`** — 6 files, no datasource, no ports, no MCP. The recipe with nothing else attached.
   Also the only repo needing the openapi dependency added, so step 3 gets exercised there.
3. **`qits-ci`** — own Flyway lineage, first datasource-bearing boot.
4. **`qits-artifacts`** — same, plus raw vertx routes (`/git/*`) that sit outside `quarkus.rest.path`;
   confirm they still resolve in a packaged build.
5. **`qits-projects`** — largest surface, MCP, a websocket.
6. **`qits-workspaces`** — last, because §3's `@DefaultBean` lands here and it is the only repo where
   packaging is not purely additive.

Items 2–6 are each an independent commit in a single submodule, with no cross-repo coupling — which
is why the packaging work can go first. Item 1 is the exception: §4a steps 1 and 2 touch
`qits-workspace-daemon` and `qits-workspaces` as well, because the sender side lives there.

## 6. Deliberately out of scope

Named so nobody widens the change mid-flight:

- **No Dockerfiles, no compose.** A repo that produces a `quarkus-run.jar` and boots is the
  deliverable. Images are a deployment concern and the topology is still open.
- **No auth.** `forwardauth` per service lands *on top* of this and names this as its
  prerequisite. It has since landed; see `migration-plan.md` §9 item 4.
- **No coexistence with the monolith.** *(Added 2026-07-28.)* Nothing here is designed to run beside
  a monolith or to share a database, volume or session with one. qits is deployed clean, as these
  services and nothing else — see `migration-plan.md` §1, "This is a source-tree invariant, not a
  deployment strategy". The gateway's `/` catch-all and `PublicPaths.onTheMonolith` were deleted
  rather than deferred, so an unclaimed path is a 404 and the monolith-relative spellings are no
  longer an anonymous surface.
- **No REST clients.** §3's `@DefaultBean` is a scaffold, not the HTTP `RepositoryLookup`.
- **No OTLP sender side.** *(Added 2026-07-29 — this is §4a steps 1 and 2, deferred rather than
  done.)* A workspace's dev servers do not export telemetry: the `otel:` toggle in
  `.config/qits/repository.yml` is parsed and carried but never reaches a launched process, and no
  qits service exports either, so `qits-observability` receives nothing. A nice-to-have — it costs
  observability of a user's own dev servers, and nothing is blocked on it. The receiver itself is
  finished: packaged, native, and addressable at `POST /observability/api/otel/v1/*`, so the day
  senders exist there is nothing to build on this side.
- **No segment/path decision.** Four of six services could not be reached through their own gateway
  segment. This change did not fix it — but the generated `docs/openapi.yml` per repo made the
  mismatch a document diff instead of an argument, and all six have since adopted their segment.
- ~~**No native build.** Fast-jar only. Native is the gateway's concern and its own budget question.~~
  **Reversed, 2026-07-28.** All seven services now compile to a GraalVM native binary; see §9. The
  reasoning above was wrong on both halves: native was not the gateway's concern alone (it is what
  every service's restart cost is made of), and the "budget question" assumed a container build —
  with a GraalVM on `.sdkmanrc` a binary costs 35s–2m20s of local compile and no docker at all.

## 7. Risks

- **Augmentation surfaces latent CDI errors.** `@QuarkusTest` augments the *test* classpath, where
  `Fake*` beans satisfy things production has no bean for. `qits-workspaces` is the known case
  (§3); others may appear only when the build goal runs. This is the recipe finding bugs, not
  causing them — the ordering in §5 exists so they are found cheaply.
- **Ordinal collisions.** Promoting a key into `application.properties` that `domain` also ships at
  ordinal 100 silently pins it at the app level and breaks a deployment's ability to override via
  environment. Keep step 2 minimal and resist moving config "up for visibility".
- **The suite flakes (`migration-plan.md` §9 items 14, 20)** are still unexplained. Packaging adds
  an augmentation per module and may make them more frequent. Do not attribute a new flake to this
  change without checking those items first.

## 8. Done when

All six repos build from a clone of themselves alone, boot from `quarkus-run.jar`, serve
`/q/openapi` and `/q/swagger-ui`, and carry a checked-in `docs/openapi.yml` whose operation set is
exactly what that service is meant to serve.

---

## 9. Native, 2026-07-28 — what §6 got wrong

Status: **done for all seven.** Each repo's `service/` module (the gateway is single-module) carries
`<packaging>quarkus</packaging>` and a `native` profile, and `.sdkmanrc` names `25.0.2-graalce`.

| Repo | Commit | Boot | Build |
|---|---|---|---|
| `qits-stt` | `6b511c5` | 0.014s | 34s |
| `qits-observability` | `2b3e6aa` | 0.025s | 1m02s |
| `qits-gateway` | `e531868` | 0.017s | 52s |
| `qits-ci` | `134f48b` | 0.190s | 1m46s |
| `qits-artifacts` | `e1c5c01` | 0.033s | 1m12s |
| `qits-projects` | `5c9f951` | 0.050s | 1m00s |
| `qits-workspaces` | `190f54e` | 0.145s | 53s |

Fast-jar boot was 0.85–2.9s. `qits-workspaces` still refuses to start without a `RepositoryLookup`
(§3) — its gate was that the binary fails *identically* to the fast-jar, which it does.

### The toolchain was the whole finding

`.sdkmanrc` named `25.0.2-open` everywhere — a JDK with no `native-image`. Quarkus does not fail on
that: it logs `Cannot find the native-image ... Attempting to fall back to container build` and
compiles under a 1.8 GB Mandrel image. **Green either way**, which is why `qits-gateway` had claimed
native compilation since its first commit without anyone noticing it was a docker build. Declaring
the GraalVM is what makes "produces a binary" true rather than "produces a binary, somehow".

Grep every native build for that line. A verification that does not is not one.

### What a passing `mvn verify` does not tell you

Fourteen defects were found. **Four failed the build loudly; the other ten compiled green** — four
killed the binary at boot, six let it run and answer wrongly. Native-image resolves at build time, so
these land at runtime in the binary while `@QuarkusTest` — which runs on the JVM, where reflection
needs no registration and `application.properties` is an ordinary runtime source — stays green.

Three recurred across repos, found independently before anyone compared notes:

- **`AUTO_SERVER=TRUE` in the shipped H2 url** (ci, artifacts, projects×2, workspaces). Starts H2's
  TCP server; `org.h2.server.TcpServer` is not in the image, so the binary **died at boot** while
  every suite passed on in-memory H2. Dropped rather than registered: a single-process service does
  not want a second opener, or a DB port on `qits-net`.
- **A `static final HttpClient`** (observability, artifacts). Class initialisers run at image-build
  time; native-image rejects a live client in the heap. Now a bean field in `@PostConstruct`.
- **Unregistered DTOs** (artifacts, projects, workspaces). A resource method returning `Response`
  has no signature to infer from, so the type gets no registration and the route 500s — or worse,
  workspaces' capture reported it as `400 Malformed payload`.

And two that generalise beyond their repo:

- **Injecting a build-time `quarkus.*` key.** `CaptureCorsRoute` read `quarkus.rest.path`; build-time
  items are absent from a binary's runtime config, so it silently took its `defaultValue`, registered
  the preflight on an unreachable path, and left the real endpoint answering browsers 200 with no
  CORS headers. The value is now spelled once as the application-owned `qits.rest.path`, with
  `quarkus.rest.path` derived from it. `ServiceProxyRoute` keeps its `quarkus.http.root-path` and
  says why.
- **A missing reflection registration presenting as a plausible 404.** JGit's `Config.getEnum`
  recovers constants via `getMethod("values")`; unregistered, opening any repository threw,
  `GitHostRoutes.open` returned null, and **every** git route 404'd exactly like an unknown repo id.
  Nothing logged. `GitHostRoutes` now logs the swallowed cause at debug.

### The gate that catches this class of bug

Five repos gained a `@QuarkusIntegrationTest` over the **packaged artifact** — fast-jar normally, the
binary under `-Dnative`. It is the only place these are visible. Write them to exercise the *shipped*
config (relocate `user.home`; do not restate the datasource in test resources), or they pass against
a default no deployment can boot.

### ~~`qits-workspace-daemon` does not currently native-compile~~

**Migrated** to `daemons/qits-workspace-daemon`, which owns its own native build and documents it
there.
