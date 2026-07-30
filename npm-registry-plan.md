# npm in qits-artifacts: hosted registry, proxy cache, and the Angular publish loop

Status: **implemented, unpushed.** Written 2026-07-30; implemented the same day across
qits-artifacts, qits-ci, qits-integrations-angular, qits-spa-ui-components and qits-spa-home
(commits on each submodule's local `main`). The publish → install loop was proven end to end
against a locally-run registry binary: both libraries published, a scratch install resolved them,
and the app's lockfile was generated through the live proxy (cold install 10.6 s / warm 1.7 s over
568 tarballs). Two client-side facts settled empirically along the way: npm 10.9.4 still enforces
`ENEEDAUTH` (the dummy `_authToken` line stays), and a committed project `.npmrc` outranks
`~/.npmrc`, so repos that commit one use `npm_config_*` environment overrides in CI instead of the
§5 preamble (recorded in qits-ci's README).

Two revisions during the live e2e. **Builds are hermetic:** a docker-build RUN step can reach the
public internet but never the platform registry (probed: not via qits-net, host networking, or a
host-gateway alias), so anything installing `@qits/*` runs in the pipeline's step container on
qits-net and image builds only package prebuilt output. **§6's spa-home shape changed:** no nginx
image and no separate container — qits-gateway carries `qits-spa-home` as a git submodule at its
Quinoa ui-dir and serves the SPA at the front door; spa-home's own pipeline is just the sandboxed
install/lint/test/build that keeps its main green.

The goal is the full loop: `qits-integrations-angular` (real, ng-packagr, Angular 21) and
`qits-spa-ui-components` (empty seed, to be scaffolded) publish npm packages from green pipelines
into qits-artifacts; `qits-spa-home` (empty seed, to be scaffolded) installs them from there; and
*every* `npm install` in CI resolves through a pull-through cache of npmjs so registry.npmjs.org is
hit once per tarball, not once per run. `RepositoryType`'s javadoc already reserves the seam ("the
deferred protocol types (maven/npm/docker) slot in as new constants"); this plan fills it in.

## 1. Shape: two repository types, one path stack

Two new enum constants, mirroring the namespacing rule `proxy-pulling-normal-images.md` already
settled (cached upstream content and published content must not share a namespace, and the mirror
must reject pushes outright):

- **`NPM_PACKAGES`** (wire `npm-packages`) — hosted, accepts publishes. Seeded row: `npm`.
- **`NPM_PROXY`** (wire `npm-proxy`) — pull-through cache of an upstream. Seeded row: `npmjs`.
  Any `PUT` here is a 4xx by type, not by configuration.

Both follow the `OCI_IMAGES` protocol-type pattern: empty `allowedMediaTypes`, zero `maxBytes`
(their bytes bypass `BlobService`; real limits are config keys), routes on a raw Vert.x stack
registered via `@Observes Router`, all DB work behind a control-package service whose public
methods carry `@ActivateRequestContext`/`@Transactional`.

Unlike docker, npm accepts any registry URL — so no second root-level mount, no second
`QitsService` extra prefix. The stack lives at

    /artifacts/npm/<repository>/…

inside the segment the gateway already routes to this service. The first path segment after
`/artifacts/npm/` is the `artifact_repository` row, exactly like OCI's first-segment rule; the
seeded rows give the two registry roots:

    http://qits-artifacts:8080/artifacts/npm/npm/      # hosted
    http://qits-artifacts:8080/artifacts/npm/npmjs/    # proxy

Consumers never need a merged "group" view — npm scope routing does it client-side, one `.npmrc`:

    registry=<proxy root>          # everything
    @qits:registry=<hosted root>   # ours

so all internal packages are published under the `@qits/` scope (`@qits/angular` already is).

## 2. Wire protocol, hosted

The minimum npm and pnpm actually need:

| Method | Path (under `/artifacts/npm/<repo>`) | Behavior |
|---|---|---|
| `GET` | `/<pkg>` | packument, assembled per-request from rows |
| `GET` | `/<pkg>/-/<file>.tgz` | tarball via `BlobStore.locate` + `sendFile` |
| `PUT` | `/<pkg>` | publish (json doc with `versions`, `dist-tags`, base64 `_attachments`) |
| `PUT` | over an existing version | 403 — versions are immutable, matching append-only |
| `DELETE` | anywhere | 405 `UNSUPPORTED`, like the OCI registry — no unpublish, no GC yet |
| anything else | `/-/…` (search, audit, login) | protocol-shaped 404; npm degrades gracefully |

Publish decodes the attachment, recomputes `shasum` (sha1) and `integrity` (sha512) and rejects a
mismatch with the client's claim — the npm analog of "a blob that does not hash to its name is not
a blob". The tarball is staged through `BlobStore.stage()` (single request — no incremental
session needed), so its *storage* key is its sha256 while `integrity`/`shasum` are stored columns
re-emitted in packuments; the store stays sha256-only.

The packument is **derived state**: built per-request from `npm_version` rows + `npm_dist_tag`
rows, never stored, so it cannot become a second source of truth (the same reasoning that keeps
OCI tags in one table). `Accept: application/vnd.npm.install-v1+json` (the abbreviated form both
clients send) can receive the full document — spec-legal, and an optimization to trim later.

**Things to settle here:**

- **`dist.tarball` must be an absolute URL** — npm refuses relative. The OCI path-form-`Location`
  trick does not transfer. Settled: build it from `X-Forwarded-Host`/`X-Forwarded-Proto` when
  present, else the request authority — the gateway emits the `X-Forwarded-*` set on every proxied
  request by default (`EdgeHeaders`, `qits.gateway.forwarded.enabled=true`), and a direct
  qits-net client has no forwarding hop, so the fallback is the authority it actually dialled
  (`qits-artifacts:8080`). No config key names a deployment fact.
- **Auth: none, at all** — the exact threat model of the OCI registry (tokenless in both
  directions on qits-net; commit `143c695` precedent). Push is internal-only; the server neither
  requires nor reads any credential. One client-side wrinkle to verify in phase 1: the npm CLI
  historically refuses `npm publish` when no credential is configured for the target registry —
  `ENEEDAUTH` is a CLI pre-flight that never reaches the wire. If current npm still enforces it,
  the CI preamble carries one dummy `_authToken` line the server never sees; that is npm-client
  ceremony, not an auth scheme, and it is dropped the moment npm accepts an anonymous publish.

## 3. Wire protocol, proxy

The miss path from `proxy-pulling-normal-images.md`, translated:

- **Packument GET**: serve from cache when fresh; on expiry revalidate upstream with
  `ETag`/`If-None-Match`; on miss fetch, **rewrite every `dist.tarball` to point at this proxy**,
  store doc + etag + fetched-at, serve. Packuments are *mutable* (new versions appear), hence the
  TTL — `qits.artifacts.npm.proxy.packument-ttl`, default `PT5M`. When upstream is down, serve
  stale: CI keeps working through an npmjs outage, which is half the point of the feature.
- **Tarball GET**: cache hit is `sendFile`, unchanged code. Miss streams from upstream through
  `BlobStore.stage()` (hash-while-streaming for free), promotes, serves. Tarballs are immutable —
  cached forever. The client end-to-end-verifies `integrity` from the packument we re-emit
  unmodified, so the proxy cannot silently corrupt a package even in principle.
- **Upstream**: `qits.artifacts.npm.proxy.upstream`, default `https://registry.npmjs.org`. No
  credential needed (npmjs has no Docker-Hub-style anonymous pull limit); the config key exists so
  a token can appear later without a schema change.
- **Growth**: unbounded, same as the OCI mirror — `artifact-access-tracking.md` is the
  prerequisite for cleanup and now has *two* forcing functions. Nothing new to decide here; this
  plan inherits that one.

## 4. Data model — `V3__npm_registry.sql`

One Flyway migration on the existing lineage (no renumbering):

- widen `ck_artifact_repository_type` (drop by name, re-add with `NPM_PACKAGES`, `NPM_PROXY`);
- `npm_version` — PK `(repository, package_name, version)`; `tarball_blob_id` (sha256 hex, the
  `BlobStore` key), `integrity`, `shasum`, `manifest_json` (the version's manifest verbatim, CLOB
  — packument assembly is then one query), `created_at`. FK `repository`.
- `npm_dist_tag` — PK `(repository, package_name, tag)` → `version`, `updated_at`. **The only
  mutable table**, the exact analog of `oci_tag`.
- `npm_proxy_packument` — PK `(repository, package_name)`; `doc` CLOB, `etag`, `fetched_at`.
  Proxied tarballs get `npm_version` rows too (minus publish-side fields they lack), written
  lazily when a tarball is first pulled, so the tarball route is one code path for both types.

Entities follow `OciManifest`/`OciTag`: `@IdClass` plain classes with public no-arg ctors, DAOs as
`PanacheRepositoryBase`.

## 5. CI: publishing is the pipeline's last ordinary step

`image-publishing-plan.md` settled the model — publishing is not a platform seam, it is a step
that runs a tool. `npm publish` fits even better than `docker push` did: it needs **no docker
socket, no host daemon, no root-equivalence** — just HTTP from the step container to
`qits-artifacts:8080` over qits-net, which every step already has. These become the platform's
first non-`docker: true` publish pipelines.

What the platform adds (all in qits-ci, mirroring the `QITS_REGISTRY` precedent):

1. **Two env vars injected into every step container** by `CiDaemonLauncher.buildArgv`:
   `QITS_NPM_REGISTRY_URL` (from `qits.artifacts.npm.hosted-url`, default
   `http://qits-artifacts:8080/artifacts/npm/npm/`) and `QITS_NPM_PROXY_URL` (from
   `qits.artifacts.npm.proxy-url`, default `…/npmjs/`). Note the caveat is the *opposite* of
   `QITS_REGISTRY`'s: these are dialled by the step container itself on qits-net, not by the host
   docker daemon — the defaults are the in-network alias, and the compose override
   (`localhost:8081`) must **not** apply to them. `CiDaemonLauncherTest`'s literal argv assertion
   changes in the same commit; README boundary table gains the two names.
2. **A node build image**: `qits/build-images/node-base` — `FROM node:24-alpine`,
   `apk add --no-cache git bash curl`, `corepack enable`. Satisfies the daemon's
   git/bash/downloader contract; built where `ci-base` is built (the `qits-local-up.sh`
   bootstrap), not repo-defined — same existing fact, one more image.

Nothing else. No secrets mechanism (there is nothing to keep secret), no new step vocabulary, no
pipeline schema change.

**The step scripts' shared preamble** writes `.npmrc` from the injected env — no deployment fact
in any repo:

    cat > ~/.npmrc <<EOF
    registry=${QITS_NPM_PROXY_URL}
    @qits:registry=${QITS_NPM_REGISTRY_URL}
    ${QITS_NPM_REGISTRY_URL#http:}:_authToken=qits-ci   # npm-CLI ceremony only — see §2; server reads nothing
    EOF

(the parameter-expansion strip turns the URL into the `//host/path/` form npm keys credentials
by — worth putting in the pipeline docs verbatim, it is the one non-obvious line; the whole line
disappears if phase 1 shows npm publishes without it).

**Versioning convention: publish-if-absent.** The publish step reads the version from the
library's `package.json`, skips (successfully) when the registry already has it, publishes
otherwise. Releases are gated by ordinary version-bump commits; re-runs and doc-only pushes stay
green without touching the registry; immutability is never fought. Per-sha prerelease channels
(`0.0.2-dev.<sha>` under a `next` dist-tag) are a later nicety, not part of this plan.

Pipeline shape for a library repo (`.config/qits/ci-post-receive.yml`, their first ever):

    steps:
      - image: qits/build-images/node-base:latest
        timeout-seconds: 1800
        script: |
          <write ~/.npmrc as above>
          pnpm install --frozen-lockfile
          pnpm lint && pnpm test
          pnpm build
          ver=$(node -p "require('./projects/<lib>/package.json').version")
          if npm view "@qits/<name>@$ver" version >/dev/null 2>&1; then
            echo "version $ver already published — skipping"
          else
            npm publish dist/<lib>
          fi

Single step to start, like every existing pipeline; splitting test from publish costs a second
`pnpm install`, which the proxy makes cheap but not free — revisit when there is dependency
caching to pair it with.

## 6. The three repos

**`qits-integrations-angular`** (real code, the pilot):
- Publish `dist/qits-integrations-angular` — the ng-packagr output — not the repo root. This
  *dissolves* the documented git-install contraptions rather than contradicting them: the root
  `package.json` keeps `private: true` (it is the workspace harness, and AGENTS.md's "blocks
  registry publishing (intended)" stays true *of the root*); the consumer-side
  `pnpm.onlyBuiltDependencies` allowlist and the `prepare`-build both exist only because consumers
  built from git, and a registry tarball ships prebuilt.
- `projects/qits-integrations-angular/package.json` becomes the single source of truth for
  name/version (ng-packagr generates the published manifest from it); the root's copy of
  name/version and its `files`/`exports` git-install shape are removed once a registry version is
  published. README §Install flips from `git+https…#sha` to the scoped-registry `.npmrc`;
  AGENTS.md/BOOTSTRAP.md prose updated in the same change.
- Gets the pipeline above.

**`qits-spa-ui-components`** (empty seed): scaffold an Angular 21 workspace with one library
project — `@qits/ui-components` — copying the integrations repo's proven layout (`angular.json`
with `@angular/build:ng-packagr`, `projects/<lib>/ng-package.json`, vitest, eslint,
`check-exports.mjs`). Same pipeline file, different project name. Being greenfield, it starts
registry-first: no git-install era, no migration prose.

**`qits-spa-home`** (empty seed, the consumer that closes the loop): scaffold an Angular 21
application depending on `@qits/angular` and `@qits/ui-components` as ordinary semver deps. A
committed `.npmrc` carries only the *routing* (`@qits:registry=` + `registry=`) pointed at
`http://localhost:8081/artifacts/npm/…` — the local platform's host-published qits-artifacts
port, the same address the host docker daemon already dials — so a developer on the deployment
host installs directly, inside the trusted surface; CI's preamble overwrites with the qits-net
alias URLs. Access from outside the host goes through the gateway's usual auth and is out of
scope here (§7). Its pipeline is
install → test → build → then the standard `docker: true` image step (nginx serving `dist/`)
pushing `qits-spa-home:$QITS_CI_SHA`, at which point qits-cd deploys it like any other component
and `qits-local-up.sh`'s "no image exists: qits-spa-home" carve-outs come out.

## 7. Gateway

**No change.** The threat model is docker's, verbatim: producers and consumers are internal,
dialling `qits-artifacts:8080` on qits-net, and that surface is deliberately open. Externally,
`/artifacts/npm/**` simply falls under the gateway's usual session auth like any other
non-allowlisted artifacts path — no `PublicPaths` entry, no method split, nothing npm-specific.
Whether the npm CLI can operate *through* that auth from outside is explicitly out of scope; if
external installs are ever wanted, that is a future decision made then, not a hole pre-cut now.

## 8. Traps carried over from the OCI work (all already paid for once)

- **Native image**: parse packuments as `JsonNode`, build responses as `JsonObject` — no DTOs in
  raw Vert.x handlers, or the binary 500s where the JVM build was green (`dto/UploadResult` scar).
- **Scoped names on the wire**: npm requests `/@qits%2fangular`; after decoding, the path segment
  contains `/`. The OCI regex discipline applies verbatim — greedy name group, every group named
  or non-capturing, `HEAD` routes registered explicitly.
- **Body limits**: the publish `PUT` carries the tarball base64-inflated (×4/3) inside JSON and is
  buffered whole — a stated-limit `BodyHandler` with `qits.artifacts.npm.max-publish-size`
  (default `32M`), well under the global ceiling so the application 413 wins the race. Proxy
  streaming goes through the same `OciRequestBody`-style discipline on the response side.
- **`@ActivateRequestContext`** on every public method of the new control service.
- **Tests clone-alone, no docker**: synthesize tarball + packument in memory à la
  `TinyImage`/`OciClient`, drive with JDK `HttpClient`; `PackagedProcessIT` proves the third route
  stack coexists in the binary.

## 9. Order of work

1. **qits-artifacts, hosted**: enum constants + V3 migration + `NpmRoutes`/`NpmRegistryService` +
   seeder rows + tests. Exit: `npm publish` and `npm install @qits/x` loop green against a local
   binary.
2. **qits-artifacts, proxy**: upstream client, packument rewrite/TTL, tarball miss path. Exit:
   `npm install left-pad --registry …/npmjs/` twice, second run served with upstream unplugged.
3. **qits-ci**: `node-base` image, the two env vars, launcher test, docs. Exit: a pipeline step
   resolves both registries by env alone.
4. **qits-integrations-angular**: package reshaping + pipeline. Exit: green push on main →
   `npm view @qits/angular` answers from the hosted repo.
5. **qits-spa-ui-components**: scaffold + pipeline. Exit: `@qits/ui-components` published.
6. **qits-spa-home**: scaffold consuming both scoped packages via the proxy + image pipeline +
   cd wiring. Exit: the page serves from a cd-deployed container whose build never spoke to
   npmjs directly.

## 10. Out of scope, deliberately

- **Cache/version GC** — inherited by `artifact-access-tracking.md`, which now has three clients.
- **Prerelease/sha channels and dist-tag mutation APIs** — publish-if-absent covers the loop.
- **npm search/audit/login endpoints** — 404s the clients tolerate.
- **Dependency caching across steps** — `finish-ci-feature.md` Phase E; the proxy is this plan's
  answer to install cost, volumes are that plan's.
- **Any auth, and any external npm access** — standing posture: internal push and install are
  open on qits-net exactly like `/v2`; outside the host, `/artifacts/npm/**` sits behind the
  gateway's usual session auth untouched, and whether npm clients work through it is not this
  plan's problem. The dummy `_authToken` line, if npm still demands one, is client ceremony and
  documented as such.
