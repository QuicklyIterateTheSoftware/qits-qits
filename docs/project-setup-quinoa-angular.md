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
  | qits-artifacts | `/api,/q,/git,/v2` | git host routes; `/v2` so a misrouted registry client gets a 404 |

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
   `mvn verify` still needs neither node nor the submodule (Quinoa is disabled by default in test
   mode); `mvn package` needs both.
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

### Known wart

Bare `/<segment>` (no trailing slash) is a **404** — Quinoa mounts at `/<segment>/*`, which does not
match the bare segment (upstream quinoa issue #960). `/<segment>/` works. This affects all clients
identically; a redirect would be a gateway-level decision, deliberately not solved per-service.

## Checklist: adding the next SPA-serving service

1. Scaffold the client (Angular CLI defaults, no SSR), set `baseHref` to `"/<segment>/"`, push.
2. Superproject: submodule at `frontends/qits-spa-<name>` with the standard entry config.
3. Backend: submodule at `service/src/main/webui` (same config), quinoa 2.8.2, the four
   `application.properties` keys above with their reasoning in comments.
4. Decide `ignored-path-prefixes` by enumerating every literal route — then *measure* on the
   packaged jar that mistyped machine paths 404.
5. Dockerfile install flags, `.dockerignore` entries, CI-recipe submodule init.
6. Prove it: package, boot the fast-jar, run the probe list.
