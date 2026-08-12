# The Quinoa + Angular setup

How a qits service serves its own SPA. This is the record of the configuration chosen in July 2026
when the five service SPAs landed — the reference to check against before changing any of it, and
the recipe for the next service that grows a client. Every choice below was either measured on the
packaged artifact or bought with a bug; the reasoning travels with the rule so a deviation is a
decision, not an accident.

The shape: each service owns one gateway segment (`/projects`, `/ci`, …) and serves everything under
it itself — its REST API at `/<segment>/api`, and its Angular client at `/<segment>/` via
[Quinoa](https://docs.quarkiverse.io/quarkus-quinoa/dev/), which builds the SPA during `mvn package`
and serves it from the service process. The client lives in its own repository and reaches the
service as a git submodule at Quinoa's default `web-ui-dir`, so the path is a convention rather than
a setting.

## The frontend repository (`qits-spa-<name>`)

- The **default Angular CLI starter**: standalone components, routing (`app.routes.ts` +
  `provideRouter`), **no SSR** — no `@angular/ssr`, no `server.ts`. The build is static files; the
  service serves them.
- **Angular 21.2** — deliberately not 22. Angular CLI 22 requires node `^22.22.3 || ^24.15.0`, and
  the platform's node is 22.22.0 (Fedora RPM). Quinoa shells out to the *host's* node during
  `mvn package`, so the client must stay on an Angular the platform node can run. Revisit when the
  platform node moves past 22.22.3 — then `ng update` all clients together.
- **`baseHref` in `angular.json`** (build target options) set to `"/<segment>/"`, trailing slash
  included. This is the client's spelling of the segment: the browser resolves asset URLs against
  it, so a value that disagrees with where the app is mounted yields a page that loads and then
  fetches its own JavaScript from the wrong place — and no server-side test can see it.
- CLI-default `.gitignore` (`/node_modules`, `/dist`); `package-lock.json` committed.

Each client is a submodule **twice**: in this superproject at `frontends/qits-spa-<name>`, and in
its backend at `service/src/main/webui`. Both entries follow the platform submodule convention
(`--name <bare repo name>`, `ignore = all`, `update = merge`, `branch = main`).

## The backend service

### Dependency

`io.quarkiverse.quinoa:quarkus-quinoa` **2.8.2**, version pinned in the root pom (Quinoa is in no
BOM). 2.8.2 is the last release built against a Quarkus *older* than the platform's 3.34.6
(3.27.3 LTS — the compatible direction); 2.8.3 is built against 3.36.2, ahead of the platform. Bump
Quinoa only when the platform's Quarkus passes the version a release is built against.

**`quarkus-undertow` must never be on the classpath** — its presence breaks Quinoa's production
static serving (the qits-artifacts README carries the history). Check `dependency:tree` before
adding anything that sounds like a web framework.

### `application.properties`

```properties
quarkus.quinoa.ui-root-path=/<segment>
quarkus.quinoa.enable-spa-routing=true
quarkus.quinoa.build-dir=dist/qits-spa-<name>/browser
quarkus.quinoa.ignored-path-prefixes=/api,/q[,per-service extras]
```

- **`ui-root-path`** mounts the SPA under the segment. The segment is now spelled in four places
  that move together: this key, `quarkus.rest.path`, `quarkus.http.non-application-root-path`, and
  the client's `baseHref` (in another repo).
- **`enable-spa-routing`** makes deep links (`/<segment>/some/route`) fall back to `index.html`, so
  the Angular router owns them across a page reload.
- **`build-dir`** is pinned explicitly to the Angular output (`dist/<app>/browser`). Quinoa's
  Angular detection can resolve this from the client's `angular.json` on its own, and
  qits-workspaces currently relies on that — the one standing deviation, to be aligned when that
  file is next touched. The pinned form is the convention: the platform's style is to spell a value
  where its failure would land, and a wrong pin fails loudly ("Quinoa build directory not found").
- **`ignored-path-prefixes` follows one rule.** Leave it unset when `quarkus.rest.path` plus
  `quarkus.http.non-application-root-path` name the service's *complete* machine surface — Quinoa
  derives the ignore list from those two keys and the list cannot drift. Set it the moment a
  literal route exists outside them (an MCP root, a git host, a websocket path), because a request
  matching no route is rerouted to `index.html` and answers `200 text/html`, which a machine client
  parses as data; the correct answer to a mistyped machine path is a 404. Two traps, both measured:
  - Setting the key **replaces** the derivation rather than extending it — so `/api` and `/q` must
    be repeated by hand. Drop either and the API answers mistyped paths with `index.html`.
  - Values are matched **after** `ui-root-path` is stripped, so they are **relative** (`/api`,
    never `/<segment>/api`). An absolute value matches nothing and is indistinguishable from an
    unset key — the failure that hides.
  - A path **outside** the ui-root needs no entry and cannot have one. Quinoa mounts the SPA
    fallback at `/<segment>/*` only, and every entry is resolved relative to the ui-root — both
    read from 2.8.2's own sources (`QuinoaProcessor`, `QuinoaConfig.ignoredPathPrefixes`). A
    root-level wire protocol (`/git`, `/v2`) therefore gets the router's own 404 with no entry
    anywhere. An entry that *looks* root-level — `/v2` in qits-artifacts' list — is really
    `/artifacts/v2`: a guard that the misroute shape *under the segment* answers 404, not a page.

  websockets-next claims **only the upgrade handshake**: a plain GET on a `@WebSocket` path falls
  through to the SPA, which is why daemon sockets need an entry even though route ordering protects
  the upgrade. Ignoring a prefix stops the SPA *reroute*; it does not unregister the real route.

  Today no service qualifies for the unset form — each carries at least one literal:

  | Service | List | The literal that forces it |
  |---|---|---|
  | qits-projects | `/api,/q,/mcp` | MCP root `/projects/mcp` |
  | qits-workspaces | `/api,/q,/daemon,/service,/container` | daemon socket + two proxies + stream dial-back |
  | qits-ci | `/api,/q,/daemon` | `@WebSocket("/ci/daemon")` |
  | qits-observability | `/api,/q,/mcp` | MCP root |
  | qits-artifacts | `/api,/q,/npm,/maven,/daemons,/docs,/v2` | hosted registry, daemon-binary and docs routes under `/artifacts`; `/v2` guards the misroute shape `/artifacts/v2` |
  | qits-githost | `/api,/q,/git` | `/git` guards the misroute shape `/githost/git`; the real wire protocol at root `/git` is outside the fallback's reach |
  | qits-platform-mirror | `/api,/q` | nothing beyond the derived pair — its protocol roots (`/artifacts/npm`, `/artifacts/maven`, `/v2`) sit outside `/mirror` |

  Add a literal route and its prefix entry **in the same commit**.

### Node: the host's, except where there is none

**`quarkus.quinoa.package-manager-install` never goes in `application.properties`.** Local and CI
`mvnw` builds use the node on `PATH` — no build silently downloads a toolchain (that road ends in
another proxy cache). The two install flags appear in exactly one place, the Dockerfile's build
stage, because the Mandrel builder image ships no node at all:

```dockerfile
RUN ./mvnw -B -ntp -pl service -am package -Dnative -DskipTests \
      -Dquarkus.native.native-image-xmx=4g \
      -Dquarkus.quinoa.package-manager-install=true \
      -Dquarkus.quinoa.package-manager-install.node-version=22.22.0
```

The version is pinned so the image build is reproducible. A machine with no node fails at Quinoa's
npm invocation — that is the intended failure, and the fix is node on `PATH`, not the install key.

### The submodule is load-bearing in three places

An uninitialised gitlink is an *empty directory*, and that is the one case Quinoa treats as a
misconfiguration rather than "no client": the build stops at `No package.json found in Web UI
directory`. Three places assume the checkout, and each ships its own fix:

1. **A developer clone** — the clone-alone rule reads "clone **and** `git submodule update --init`".
   `mvn test` still needs neither node nor the submodule (Quinoa is disabled by default in test
   mode); `mvn verify` runs `package` on its way to failsafe, so it — like `mvn package` — needs
   both (measured: an empty `webui/` stops it at "No package.json found in Web UI directory").
2. **The image build** — `.dockerignore` must exclude `**/node_modules` and the client's `dist`
   (a host-built `node_modules` leaking into the context is a client built by the wrong toolchain,
   since Quinoa reuses one rather than reinstalling).
3. **The repo's own CI** — the daemon's clone is shallow and does not recurse, so
   `.config/qits/ci-post-receive.yml` runs
   `git submodule update --init --depth 1 service/src/main/webui` before `docker build`.

### Testing

Quinoa is **disabled by default in tests**: no `@QuarkusTest` builds or serves the client, so a
unit test asserting anything about `/<segment>/` passes against a process with no client in it.
What the SPA is actually served as is proven only against the **packaged artifact** — the
`PackagedSurfaceIT` pattern. The minimum probes for any change touching this setup:

- `/<segment>/` → 200 HTML with the correct `<base href>`
- a deep link → 200 `index.html` (SPA fallback)
- `/<segment>/api/<real>` → the API's own answer, `/<segment>/api/nope` → 404, never HTML
- every literal machine path, mistyped → 404, never HTML

### The platform arch rules

Every new service enables the shared ArchUnit rules from day one — they are how platform
conventions fail a build instead of a review. One test-scope dependency:

```xml
<dependency>
    <groupId>eu.wohlben.qits</groupId>
    <artifactId>qits-arch-rules</artifactId>
    <version>${qits.arch-rules.version}</version>
    <scope>test</scope>
</dependency>
```

and one test class in the service module:

```java
@AnalyzeClasses(packages = "eu.wohlben.qits.<service>",
    importOptions = ImportOption.DoNotIncludeTests.class)
class ArchRulesTest {
  @ArchTest static final ArchTests CAUSATION = ArchTests.in(CausationRowRules.class);
}
```

Today the rules guard causation-traced rows: every `@Entity` either implements `CausedRow` (with
`@EntityListeners(CausationStamp.class)` and its own `causation_id` migration) or declares
`@Uncaused`. The qits-integrations-quarkus README is the reference; new rule sets added there
arrive here as one more `@ArchTest` line.

### The container image build: an address for the platform Maven repository

A service that depends on any `eu.wohlben.qits:*` jar cannot build its image without being told
where the platform's own Maven repository is. **The address is always derived from injected env,
never spelled literally** — the artifacts store is an environment service and its alias carries the
tier, so a written-down URL is correct in exactly one environment.

Two doctrines exist, and **which one applies is decided by the build's network**:

| Build network | Build-arg value | Why |
|---|---|---|
| `--network host` (**the target**) | `--build-arg QITS_MAVEN_REPOSITORY_URL="http://$QITS_REGISTRY/artifacts/maven/maven"` | Buildkit is the builder format the platform targets and it **refuses custom networks** (`network mode "qits-net" not supported by buildkit`). Host networking reaches the registry's host-published address. |
| `--network qits-net` (**deprecated fallback**) | `--build-arg QITS_MAVEN_REPOSITORY_URL="$QITS_MAVEN_REGISTRY_URL"` | The wire alias, resolvable only on qits-net. It still works on step images whose older docker CLI falls back to the legacy builder — that is the only reason it survives. |

New repositories take the host doctrine. Reference: qits-githost `f5ae4bb`; qits-projects `509e04a`
is the qits-net form.

**The build-arg alone is not enough, and this is the half that is easy to miss.** Maven blocks
plain-HTTP repositories and **exempts only localhost**, so a Dockerfile that runs Maven against the
platform's HTTP registry fails with the blocker rather than with a connection error — the build-arg
just moves the failure. Every such Dockerfile therefore passes a settings file with an
**exact-id mirror**, which beats the blocker for that one repository and nothing else:

```xml
<!-- .qits-maven-settings.xml, repo root. All seven existing copies are identical. -->
<settings xmlns="http://maven.apache.org/SETTINGS/1.2.0" …>
  <mirrors>
    <mirror>
      <id>qits-maven-network</id>
      <mirrorOf>qits-maven</mirrorOf>
      <url>${env.QITS_MAVEN_REPOSITORY_URL}</url>
    </mirror>
  </mirrors>
</settings>
```

`mirrorOf` names the repository **id** the pom declares. A wildcard would permit arbitrary HTTP
repositories; the exact id permits only the one address the build was handed.

In `docker/Dockerfile`'s builder stage, three lines — `ENV` as well as `ARG`, because the settings
file reads `${env.…}`:

```dockerfile
ARG QITS_MAVEN_REPOSITORY_URL=http://localhost:8081/artifacts/maven/maven
ENV QITS_MAVEN_REPOSITORY_URL=$QITS_MAVEN_REPOSITORY_URL
…
RUN ./mvnw -B -ntp -s .qits-maven-settings.xml -pl service -am package -Dnative -DskipTests \
      -Dqits.maven.repository.url="$QITS_MAVEN_REPOSITORY_URL" \
      …
```

The `ARG` default is the developer-host URL so a plain host-side `docker build` still works; the
blocker exempts localhost, which is why a developer's build needs no settings file at all. The
Dockerfile is doctrine-agnostic — it takes whatever address the CI recipe hands it, so switching a
repository from qits-net to host networking touches the recipe only.

### The datasource resilience baseline

Every service depends on `qits-db-core` at **runtime**:

```xml
<dependency>
    <groupId>eu.wohlben.qits</groupId>
    <artifactId>qits-db-core</artifactId>
    <version>…</version>
</dependency>
```

…and **every postgresql datasource carries exactly these three lines**, substituting the service's
own datasource name:

```properties
quarkus.datasource.<name>.jdbc.driver=eu.wohlben.qits.db.PatientPgDriver
quarkus.datasource.<name>.jdbc.validate-on-borrow=true
quarkus.datasource.<name>.jdbc.acquisition-timeout=15S
```

- **`jdbc.driver`** points the pool at `PatientPgDriver`, which delegates to `org.postgresql.Driver`
  and, when the database is not there, keeps asking for up to 14s instead of failing at once. It
  retries SQLState `08*` (refused, unreachable, connect timeout) and `57P03` ("the database system
  is starting up"); a wrong password or a missing database fails on the first attempt. The URL stays
  a plain `jdbc:postgresql:` one — the injected `QITS_RESOURCE_*_URL` contract is untouched.
- **`validate-on-borrow`** (Quarkus default `false`) tests a connection before handing it to a
  caller and evicts it if it is dead. Without it, a database restart leaves the pool full of dead
  connections that are handed out until something else notices — and the patient driver never runs,
  because nothing ever asks for a new connection.
- **`acquisition-timeout`** (Quarkus default `5S`) bounds how long a request waits on a starved
  pool. 15S because a real cutover takes longer than five seconds to settle, and because it must
  outlast the driver's own 14s deadline — otherwise the caller gets a generic acquisition timeout
  instead of the database's real refusal.

All three or none. Each line does less than it reads as without the other two.

**Why holding is safe, including for writes.** Patience sits at connection **creation**, before the
request has executed anything: no early acknowledgement, no buffering, no deferred apply. A request
that outlives the deadline gets the real failure and nothing has happened anywhere. That is what
makes this universal, where retrying an *operation* is not — a write whose commit acknowledgement
was lost still committed, and a second attempt would do it twice. Measured 2026-08-11: 240 calls
across an 8.2s hard outage, zero failures, straddling calls held ~8.6s and succeeded ~0.3s after
postgres accepted again; the measurements are in `db-patience-plan.md`.

**Where it does not reach: a connection that died mid-flight**, after statements ran. Retrying those
is only safe for reads, so it stays explicit: wrap the seam in **`DbRetry`** (same jar), which
retries connection-class failures only, to a short deadline, and rethrows everything else at once.
Reads a caller is waiting on and bookkeeping that runs after something irreversible are its call
sites; a bare `insert` is not.

**A write that must survive the same loss goes through `DbRetry.inNewTx` instead.** It owns the
transaction — every attempt is a fresh `requiringNew` on a fresh connection — so it can tell the
failures that certainly did not commit from the ones nobody can place, and it retries only the
first: a lost connection thrown out of the body. Everything the transaction manager reports,
including a rollback it claims, is rethrown, because Narayana spells "the commit could not be
delivered" and "the transaction was rolled back" with one exception type. Two call-site rules follow:
flush inside the body (`Panache.flush()`) so an ORM's write lands in the phase that is
classifiable, and reach for plain `DbRetry` where the write is idempotent by construction — an
upsert or a natural key is safe under any retry, and only the call site can know that.

**Enforce it, do not remember it.** With the test-scope `qits-arch-rules` dependency already added
in step 7:

```java
class DatasourceBaselineTest {
  @Test
  void everyPostgresDatasourceCarriesTheBaseline() {
    DatasourceBaselineRules.assertBaseline();
  }
}
```

It finds every datasource the service declares as `db-kind=postgresql` and fails the build naming
each one that is missing a line. A future service that skips the baseline learns it from its own
build, not from a review.

Two companion rules, both bought with the 2026-08-11 incident:

- **A failed read is a 5xx, never a "not found".** qits-githost swallowed a `JDBCConnectionException`
  from a catalog read and answered 404 for a repository that exists, which every caller downstream
  treated as fact. Fixed in `fe26a6c`. "I could not ask" and "the answer is no" are different
  answers and must not share a status code.
- **Cross-service writes during bootstrap keep client-side retry.** The pool settings help a service
  survive its own datasource; they say nothing about a peer that is still starting.

### The machine-token validation baseline

Every service that validates machine tokens carries **the same five-part `quarkus.oidc` block**,
substituting nothing but its own issuer address:

```properties
quarkus.oidc.tenant-enabled=${qits.auth.machine.required:false}
quarkus.oidc.auth-server-url=http://qits-platform-idp:8080/idp
quarkus.oidc.application-type=service
quarkus.oidc.discovery-enabled=false
quarkus.oidc.jwks-path=jwks
quarkus.oidc.connection-delay=30S
quarkus.oidc.token.audience=${qits.auth.machine.audience}
quarkus.oidc.token.forced-jwk-refresh-interval=PT5S
```

- **`tenant-enabled`** follows the rollout gate, so the extension is inert wherever
  `qits.auth.machine.required` is still false — one switch, not two that can disagree.
  **`application-type=service`** makes it a resource server: a bad bearer is a 401, never a redirect
  to a login page a machine cannot follow.
- **`discovery-enabled=false` + `jwks-path`** because the issuer string is a public URL while the
  fetch happens on the platform's own network — a discovery document would name addresses the
  process cannot reach. The path is *joined* onto `auth-server-url`, so it is `jwks`, not
  `/idp/jwks`. The gateway is the exception and keeps discovery on: it reaches the public issuer.
- **`connection-delay`** retries the boot-time JWKS fetch instead of falling back to lazy. Without
  it there is one attempt, and the first request carrying a bearer pays for the failure. It does not
  make idp a hard dependency — when the window expires, startup continues with a WARN.
- **`token.audience`** spelled from the same key the guards read, so validation and `MachineAuth`
  cannot drift into accepting a token the guard then refuses.
- **`token.forced-jwk-refresh-interval`** is how fast a **rotated** idp key is picked up. Rotation is
  rare: idp persists its signing key in its database, so a redeploy keeps it, and only an operator
  retiring a key — or an idp landing on an empty database — mints a new one. Until the new key
  arrives every validator holds the old set; an unknown `kid` buys **one** JWKS refresh, and the
  Quarkus 3.34.6 default `10M` is the *minimum* before the next. That one attempt landing while idp
  is down or mid-cutover means ten minutes of 401s for every caller. `PT5S` ends the window seconds
  after idp answers again, and costs at most one JWKS fetch per five seconds on the platform's own
  network.

**These keys stay per-service; they do not move into `qits-auth-core`'s shipped defaults.** Measured
2026-08-12: a `quarkus.oidc.*` key in that jar's `microprofile-config.properties` makes every
consumer *without* the quarkus-oidc extension log `Unrecognized configuration key "…" was provided;
it will be ignored` at boot. `qits-platform-mirror` is such a consumer today. The repetition is the
price of not putting a warning into an unrelated service's every start — so it is a documented
pattern instead of a shared default.

**The residual, and who absorbs it.** A JWKS refresh that fails because idp is unreachable surfaces
to the caller as a plain **401**, indistinguishable from a bad token. Nothing in this block changes
that; it only shortens how long it lasts. A machine caller on a critical seam therefore holds
through 401s briefly rather than failing its work. The worked example is qits-ci's
`CiDaemonLauncher`: `qits.ci.containers.launch-patience` (`PT90S`) retries a launch that came back
401, which is safe because `ensure` is an idempotent PUT keyed on the step's own container name — a
second attempt adopts what the first may have created rather than duplicating it. Retry on 401 is
only correct where that property holds; where it does not, the call fails and the caller is told.

### Known wart

Bare `/<segment>` (no trailing slash) is a **404** — Quinoa mounts at `/<segment>/*`, which does not
match the bare segment (upstream quinoa issue #960). `/<segment>/` works. This affects all clients
identically; a redirect would be a gateway-level decision, deliberately not solved per-service.

## The landing-page exception: qits-spa-home at the gateway

One client deliberately deviates from the recipe above, in exactly four ways — everything else
(Angular 21 on npm, standard scaffold, host node locally) is the same. `qits-spa-home` is the
platform landing page, served by **qits-gateway** from a submodule at its `src/main/webui`:

1. **It mounts at `/`, not under a segment.** The gateway has no segment of its own, so
   `ui-root-path` stays at Quinoa's default `/` and the client's `angular.json` sets **no**
   `baseHref` (the default `/` is correct). Do not copy either fact into a segment-mounted client.
2. **Precedence replaces the ignore list.** The gateway's proxy catch-all runs at route order
   20 000 — wedged between Quinoa's static resources (1 060) and its SPA fallback (40 000), orders
   read from the jars, not assumed — and calls `next()` on an empty route-table match. A configured
   segment therefore proxies (nested deep paths included: `/ci/runs/123` longest-prefix-matches
   `/ci` and forwards verbatim) **without appearing in any list**, and only unclaimed paths fall
   through to the landing page. `ignored-path-prefixes` holds just `/api,/q` — the gateway's own
   machine surfaces, the same policy as every other service. The route table is the single source
   of segment truth; there is no second spelling to drift.
3. **Leaving the SPA is a routing rule, not a link list.** spa-home's `**` route: hit on the
   *initial* navigation (the gateway already decided nothing owns this URL) it renders a 404 view;
   hit on a *subsequent* in-app navigation it performs a full `window.location.assign`, and the
   gateway serves whichever micro frontend owns the segment. Loop-free by construction, and the SPA
   holds no segment knowledge. Cross-app links in templates are plain `href` anchors, never
   `routerLink`.
4. **The image build packages a prebuilt `dist/`.** spa-home depends on `@qits/*` packages that
   exist only on the platform's own npm registry, and a docker `RUN` can reach that registry by no
   address — so the pipeline's step container (on `qits-net`) runs the install and build, and the
   Dockerfile neuters Quinoa's install/ci/build commands to `--version`, staging the bundle it was
   handed. A missing bundle fails loudly ("Quinoa build directory not found").

One caveat that travels with npm and the platform registry, wherever `@qits/*` is consumed:
`package-lock.json` records **absolute** `resolved` tarball URLs, `npm ci` fetches by those URLs
and ignores the configured registry, and npm's `replace-registry-host` is broken for registries
mounted under a path prefix (arborist concatenates paths). CI recipes therefore rewrite the
lockfile's `resolved` **origins** from the injected registry env before `npm ci`; the committed
lockfile keeps the developer-host origin, which is correct locally.

## Checklist: adding the next SPA-serving service

1. Scaffold the client (Angular CLI defaults, no SSR), set `baseHref` to `"/<segment>/"`, push.
2. Superproject: submodule at `frontends/qits-spa-<name>` with the standard entry config.
3. Backend: submodule at `service/src/main/webui` (same config), quinoa 2.8.2, the four
   `application.properties` keys above with their reasoning in comments.
4. Decide `ignored-path-prefixes` by enumerating every literal route — then *measure* on the
   packaged jar that mistyped machine paths 404.
5. Dockerfile install flags, `.dockerignore` entries, CI-recipe submodule init.
6. **Name the binary**, both keys — see below.
7. Enable the platform arch rules: test-scope `qits-arch-rules` plus the three-line
   `ArchRulesTest` above.
8. Give the image build the Maven repository address: `.qits-maven-settings.xml`, the Dockerfile's
   `ARG`/`ENV`/`-s` trio, and the CI recipe's `--build-arg` in the doctrine its network requires.
9. Depend on `qits-db-core`, set the three datasource resilience lines on every postgresql
   datasource, add the `DatasourceBaselineTest`, and reach for `DbRetry` at read seams that must
   survive a cutover mid-flight.
10. Prove it: package, boot the fast-jar, run the probe list.

### Naming the native binary: two keys, not one

```properties
quarkus.package.output-name=qits-<name>
quarkus.package.jar.add-runner-suffix=false
```

Every service on the platform carries this pair, and it appeared in no document until
qits-platform-docs shipped with only the first line. **`output-name` alone does not remove the
suffix** — Quarkus still emits `qits-<name>-runner`, so the runtime stage's
`COPY --from=build /src/target/qits-<name>` fails on a path that does not exist, *after* the
multi-minute native compile has been paid for. The key says `jar.` and governs the native
executable's name too, which is the reason it is easy to read as inapplicable and skip.

The name is spelled a second time in `docker/Dockerfile`'s `COPY` line, and a third in the failsafe
plugin's `native.image.path` where a repo has native ITs. They move together.

Not strictly a Quinoa concern — it applies to every native service, SPA or not — but this is the
platform's service-scaffolding recipe and step 5 already covers the Dockerfile, so it belongs on the
same checklist rather than in a document nobody would think to open.
