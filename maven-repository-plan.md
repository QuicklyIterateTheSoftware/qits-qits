# A maven repository type for qits-artifacts

Status: **SETTLED (2026-08-02)** — all four ⚖ are ruled; the rulings and their reasoning are
recorded in §4. Two of them overruled this document's recommendations (⚖1, ⚖3) and are marked
as the user's call. Everything else was verified against the checked-out sources; the citations
are inline.

The goal, in one line: the smallest maven repository type that lets the platform **publish and
resolve its own library** — `eu.wohlben.qits:qits-eventstream` — so that `mvn deploy` has
somewhere to land and the two consumers can drop the vendored-submodule workaround that this
gap forced on them. Per the rulings, the type ships with **full timestamped SNAPSHOT support**
and is joined, after the publish lands, by a **pull-through cache of Maven Central**.

---

## 1. Why: the workaround, measured in the tree

`libs/qits-eventstream` is a standalone maven repository: one parentless pom, one jar,
`eu.wohlben.qits:qits-eventstream:1.0.0-SNAPSHOT`
(`libs/qits-eventstream/pom.xml:27-29`). It was never published anywhere, because
qits-artifacts has no repository type that can hold it — the README says so in its "deliberately
not here" list: *"A maven repository type. The same seam again, a third protocol."*
(`services/qits-artifacts/README.md:1205`).

Both consumers therefore vendor it as a **git submodule built in place by their maven reactor**.
Verified, per repository:

- **qits-ci** — `.gitmodules:7-12` (`eventstream/`), `<module>eventstream</module>`
  (`pom.xml:53`), and a `dependencyManagement` pin of `qits-eventstream` at
  **`${project.version}`** (`pom.xml:133-137`). That pin works only by coincidence: qits-ci's
  root and the submodule both happen to be `1.0.0-SNAPSHOT` today. Reactor resolution is strict
  GAV — the moment the root moves and the library does not, the pin resolves to nothing.
- **qits-workspaces** — same shape: `.gitmodules:7-9`, `pom.xml:50`,
  `service/pom.xml:66-68`.
- **Both pipelines** fetch the submodule by hand because the CI daemon's clone does not
  recurse: `git submodule update --init --depth 1 eventstream` in
  `services/qits-ci/.config/qits/ci-post-receive.yml:46` and `ci-event-release.yml:84`, and in
  `services/qits-workspaces/.config/qits/ci-post-receive.yml:52` and
  `ci-event-release.yml:87`. `services/qits-ci/docker/Dockerfile:21` carries the same coupling
  as a comment (an uninitialised `eventstream/` stops maven at `Child module … does not exist`
  before anything compiles).
- **The release flow broke on it.** qits-workspaces' `MavenVersionBumper` walks the reactor of
  the repository being released; releasing qits-ci walked into the `eventstream/` submodule and
  failed (the release worktree never initialises submodules). The fix is an **uncommitted**
  working-tree change — `git status` in `services/qits-workspaces` shows
  ` M domain/src/main/java/eu/wohlben/qits/workspaces/control/MavenVersionBumper.java` (+48/−1)
  adding a gitlink skip read from `.gitmodules`. It is the platform's release machinery carrying
  an uncommitted patch because one library has no home. The vendoring ultimately took qits-ci
  down in the local environment — the incident this plan exists to close.

The workaround's whole cost is that a **library is being distributed as source**. The fix is
the boring one: publish the jar, depend on the jar.

## 2. The seam that already exists

Every claim below was read out of `services/qits-artifacts` at the commit this plan was written
against.

- **The type seam predicted maven.** `RepositoryType`'s class javadoc: *"the deferred protocol
  types (maven, and now npm/docker) slot in as new constants without touching the core"*
  (`artifacts/…/entity/RepositoryType.java:11-12`). A new constant is a code change plus a
  check-constraint widening — the constraint is named `ck_artifact_repository_type` since V2
  precisely so the widening is a one-liner (`RepositoryType.java:22-23`,
  `V2__oci_registry.sql:1-16`).
- **The npm type is the template, and it is small.** A wire package in `service`
  (`eu.wohlben.qits.npm`: routes, path grammar, error envelope — 3 classes of substance), a
  control bean in `artifacts` doing the database work (`NpmRegistryService`), entities as
  Panache active records (`NpmVersion`, `NpmDistTag`, …), one Flyway migration (V3), one seeded
  row pair. The OCI mirror later proved the pattern scales to a third protocol type with two
  more tables (V7).
- **The npm proxy is the pull-through template.** A single configured upstream as a config key
  (`qits.artifacts.npm.proxy.upstream`, default `https://registry.npmjs.org`) rather than the
  oci-mirror's row-per-upstream table — right for exactly one upstream; TTL + `ETag`
  revalidation for the mutable documents, cached verbatim; immutable bytes fetched lazily on
  first miss, streamed through `BlobStore.stage` (hashing for free), promoted, and given their
  identity row lazily so the serve path stays one code path (`NpmRegistryService
  .recordProxiedVersion`); stale content served when the upstream is unreachable. Its client is
  a plain JDK `HttpClient` — no extension, no reflection registration — held in an instance
  field, because a static one freezes into the native image heap (the AGENTS.md table lists
  `NpmUpstream` and three siblings for exactly this).
- **The pull-through lessons are already written down.** `docs/npm-registry-notes.md` records
  what the npm proxy buys, measured (cold install 10.6 s / warm 1.7 s over 568 tarballs) and
  why the upstream needs no credential (npmjs has no Docker-Hub-style anonymous pull limit; the
  config key exists so a token can appear later without a schema change).
  `proxy-pulling-normal-images.md` adds the mirror's: upstream-request counters are the only
  honest assertions, fixture content must be unique per RUN because blobs dedupe globally, and
  a mirror error is a 502 or a 404, never a 500.
- **Wire conventions the maven type must keep**, all load-bearing and all verified:
  - Raw Vert.x routes, the segment a **literal in the code** — `NpmPaths.BASE = "/artifacts/npm"`
    (`service/…/npm/NpmPaths.java:41`). No config key moves it.
  - The first path segment after the base is the `artifact_repository` row, same rule as `/v2`
    (`NpmRoutes.java:49-51`). Repositories are not created implicitly; unknown names 404 with a
    message naming the ensure endpoint (`NpmRegistryService.requireNpmRepository`).
  - Every byte goes through `BlobStore.stage`/`promote` — the store's one write funnel
    (`BlobStore.java:68,215`) — so tarballs/jars dedupe globally with image layers, and
    `BlobDiskIndex` invalidation comes for free.
  - No DTOs on wire routes, ever — responses are built as `JsonObject`/text so nothing needs
    `@RegisterForReflection`; `registry` and `npm` together add **zero** native-image
    configuration (AGENTS.md, "What not to fix").
  - The control bean carries `@ActivateRequestContext`/`@Transactional` on every method,
    because a raw Vert.x route has no CDI request context (`NpmRegistryService.java:28-32`).
    Drop one and the route fails at runtime only.
  - Served blobs go out as zero-copy `sendFile` with `CACHE_CONTROL: immutable` where the
    content is immutable (`NpmRoutes.serveTarball`).
  - HEAD is **not** derived from GET by Vert.x; every GET route needs its HEAD twin
    (`NpmRoutes.java:95-102`).
- **The Flyway lineage ends at V7** (`V7__oci_mirror.sql`). The numbering rule is written into
  V7's own header: no plan reserves a number — take the next free V at land time and
  re-enumerate the check constraint from the `RepositoryType` enum as it stands in the tree.
  `OciMirrorMigrationTest` pins the enumeration by looping over `values()`, so a constant added
  without its migration fails the suite, not the deployment.
- **GC is a seam, not a framework.** `GcStrategy` beans are discovered over
  `Instance<GcStrategy>` (`GcPlanner.java:40`); the plan report lists **every type, always**,
  including unclaimed ones ("no strategy registered" is a report, not an error). Two claiming
  shapes exist to copy: the mirror's honest *"nothing dies, said out loud"*
  (`OciMirrorGcStrategy`) and the CI types' fail-closed-at-first-row stubs
  (`CiScreenshotsGcStrategy`). Section 3.8 picks between them and says why.
- **The explorer's per-type switches are exhaustive.** `ArtifactExplorerService.itemCount` and
  `sizeOf` (`ArtifactExplorerService.java:239-254`) switch over `RepositoryType` with no
  default — a seventh constant is a **compile error** until the explorer handles it. That is a
  feature: the type cannot land half-wired.
- **The store summary is a byte-exact identity, test-pinned.** `diskTotal = ociUnion +
  npmPublished + npmProxyTarballs + orphans`, computed from one `LiveBlobCensus` reading
  (`ArtifactExplorerService.storeSummary`, :182-193; `StoreSummary` carries the eight figures).
  `LiveBlobCensus.take()` pre-creates a live set per enum constant (`LiveBlobCensus.java:162-164`)
  but only fills the sets it knows; a maven blob unknown to the census would be misreported as
  an **orphan** — servable, row-less-looking, untouchable. Wiring the census is therefore part
  of the first landing, not a follow-up (3.11).
- **The gateway needs nothing.** It routes `/artifacts/*` verbatim by prefix
  (`services/qits-gateway` RouteTable/QitsService — `/v2` is the only extra prefix, and it is
  docker's hardcode, not a precedent maven needs). `/artifacts/maven/**` rides the existing
  segment exactly as `/artifacts/npm/**` does.
- **One config line must move.** `quarkus.quinoa.ignored-path-prefixes=/api,/q,/git,/npm,/v2`
  (`service/src/main/resources/application.properties:84`) is a hand-kept copy that **replaces**
  Quinoa's derivation; without `/maven` appended, a maven path matching no route answers
  `200 text/html` — the SPA — where a maven client needs a 404. `PackagedProcessIT` holds the
  guard on that list.

## 3. The design

### 3.1 URL shape and the repository rows

    /artifacts/maven/<repository>/<group/path>/<artifact>/<version>/<file>

The npm shape verbatim: npm lives at `/artifacts/npm/npm/<pkg>`, so maven lives at
`/artifacts/maven/maven/eu/wohlben/qits/qits-eventstream/1.0.0/qits-eventstream-1.0.0.jar`.
The first segment is the repository row. Two rows are seeded alongside the existing five in
`ArtifactsRepositorySeeder`, mirroring npm's pair (⚖2):

| Type | Wire name | Seeded row | What it is |
|---|---|---|---|
| `MAVEN_PACKAGES` | `maven-packages` | `maven` | hosted — accepts deploys |
| `MAVEN_PROXY` | `maven-proxy` | `central` | a pull-through cache of Maven Central; a `PUT` is `405` |

The proxy row's *implementation* is its own workstream (CQ, after the publish lands — the
blocker fix must not wait on the cache); its name and type are settled here so the URL
convention is written down once. Consumers declare **both** repositories, ours first: maven
consults its repository list in order for every coordinate, so our library resolves from the
hosted repository and everything else falls through to the cache. That is the whole routing
story — no merged "group" view, for the same reason npm needs none (the client does the
routing).

Maven accepts a repository URL of any depth (it is the base of every path it appends), so —
like npm and unlike `/v2` — there is no root-level segment, no gateway change, and no extra
prefix on `QitsService.ARTIFACTS`. Additional maven repositories are created with the ordinary
ensure endpoint, `{"type":"maven-packages"}`, token-guarded like every other write there.

Both constants carry the protocol-type profile all existing protocol types carry —
`MAVEN_PACKAGES(Set.of(), Set.of(), 0L)`: bytes arrive on the wire routes and go straight to
`BlobStore`, so there is no media type to sniff and no metadata to require; the empty
media-type set is what makes the zero cap safe (`RepositoryType.java`, the `OCI_IMAGES`
javadoc, which the new constants' javadoc cites verbatim). The real cap is a config knob,
`qits.artifacts.maven.max-artifact-size` (default 128M — jars are megabytes at most; the
eventstream jar measures 47,940 bytes, built from the 18-file source tree in
`libs/qits-eventstream/target/`; the knob exists because a `BodyHandler` buffers and a raw
stream is uncapped — the git host's `max-pack-size` lesson).

### 3.2 The wire

```
GET|HEAD /artifacts/maven/<repo>/<path…>          resolve an artifact, a pom, metadata, a checksum
PUT      /artifacts/maven/<repo>/<path…>          deploy — mvn deploy / gradle publish compatible
DELETE   anywhere under the base                  405 — no undeploy; the append-only stance, verbatim
anything else under the base                      404 with a short text body, never the SPA's HTML
```

What a stock client actually does against this surface:

- **`mvn deploy`** (deploy plugin 3.x): one `PUT` per file — the jar, the pom, then each
  file's checksums (`.sha1`, `.md5`; `.sha256`/`.sha512` when configured) — then a `GET` of
  `maven-metadata.xml` (tolerates 404), a merge, and a `PUT` of the merged metadata plus its
  checksums. For a `-SNAPSHOT` version the plugin deploys **unique, timestamped** filenames
  (`qits-eventstream-1.0.1-20260802.123456-3.jar`, the maven-3 default) and additionally PUTs
  the version-level `maven-metadata.xml` that lists them. Every 2xx expectation is per-file;
  there is no session, no upload protocol, no lock.
- **Gradle `publish`** (`maven-publish`): the same shape, plus a `.module` Gradle-metadata file
  and all four checksum algorithms by default; snapshots are timestamped the same way. The
  dumb-path store handles all of it without knowing what a `.module` is.
- **Resolution** (both): `GET` the pom, `GET` the jar, `GET` the checksums (sha1 by default
  policy), `GET maven-metadata.xml` at artifact level when the version is a range or
  `RELEASE`/`LATEST`, and at version level when the version is a `-SNAPSHOT` — on a 404 there
  the resolver falls back to the literal `-SNAPSHOT` filename.

The path grammar is one regex with a named `(?<path>…)` tail, the `RegistryPaths`/`NpmPaths`
pattern. Every group named or non-capturing — vertx-web silently falls back to positional
params when the counts disagree (`NpmPaths.java:18-22`). A PUT path must parse as
`<group segments>/<artifact>/<version>/<file>` with the file starting with `<artifact>-` and
the version directory either a release version or ending in `-SNAPSHOT`; a path that does not
parse is a 400, because the metadata derivation (3.4) reads structure out of paths and a store
that accepts unparseable paths serves unanswerable metadata later. `maven-metadata.xml` and
its checksum siblings, at any depth, are recognised by name and routed to the metadata handler
instead. Vert.x' `normalizedPath()` collapses dot-segments before routing, so `..` never
reaches the handler — the same property `NpmPathsTest` pins for npm, pinned again here.

The PUT body is **streamed**, not buffered: the route reads through the same limit-aware
`VertxInputStream` wrapper the registry uses (`registry/OciRequestBody`), because a raw Vert.x
route reading `HttpServerRequest` itself is bounded by nothing — the global 1088M ceiling only
gates a declared `Content-Length` (AGENTS.md, `BodyCeilingProbeTest` findings) — and a
`BodyHandler` would buffer the whole artifact into memory. Bytes stream into
`BlobStore.stage(in, cap)`; hashing to sha256 happens inside the stage, for free, exactly as
for npm tarballs and OCI layers.

Errors are a small `MavenErrors` envelope on the `NpmErrors` pattern: status code plus a short
plain-text body. Maven clients read the status and log the body; no JSON contract exists to
honour.

### 3.3 Storage: one table, one blob per path

```sql
create table maven_artifact (
    repository varchar(255) not null,
    path varchar(1024) not null,          -- the full maven-layout path, relative to the repo root
    blob_id varchar(64) not null,         -- sha256 of the bytes; the BlobStore key
    size_bytes bigint not null,           -- the one protocol table that gets a size: free at stage time
    created_at timestamp(6) with time zone not null,
    primary key (repository, path)
);
```

The npm entity pattern (`NpmVersion` + `NpmVersionRepository`): a Panache active record with an
`@IdClass(MavenArtifactId)`, a same-context foreign key to `artifact_repository(name)` exactly
like V3's three and V6's one, and the DB work in an `artifacts/control/MavenRegistryService`
bean carrying the `@ActivateRequestContext`/`@Transactional` pair on every method. No
`artifact_record` rows — protocol types never write those (the explorer's `?meta.` query
returning empty for protocol repositories is the standing, documented behaviour).

The path is the natural key and the **only** lookup the wire needs: GET resolves one row, PUT
inserts one row, metadata derivation prefix-scans `path like '<ga>/%'` — an index read at this
store's scale (the platform will hold dozens of artifacts, not Maven Central's millions; stated
so the design's simplicity is priced against the right number). The proxy's cached bytes land
in this same table under their own repository, written lazily on first pull — the
`recordProxiedVersion` precedent that keeps the serve path one code path (3.9).

Content addressing does what it does everywhere else in this service: two paths holding the
same bytes share one blob; the census (3.11) attributes the blob to the type through this
table.

### 3.4 `maven-metadata.xml` is derived state — the packument precedent, at two levels

The npm type's central decision transfers word for word: **the metadata document is assembled
per request from rows and never stored, so it cannot become a second source of truth**
(README, "The wire": the packument is derived state). Maven has the document at two levels and
both derive from `maven_artifact` rows:

- **Artifact level** (`<groupId>/<artifactId>/maven-metadata.xml`): `<versions>` is the
  distinct version directories present; `<latest>` is the highest version by maven ordering
  and `<release>` the highest non-`SNAPSHOT` one — with ⚖1 ruled for full snapshot support the
  two genuinely differ, and both are served; `<lastUpdated>` is `yyyyMMddHHmmss` UTC of the
  newest row.
- **Version level** (`…/<version>-SNAPSHOT/maven-metadata.xml`): the snapshot directory's
  timestamped filenames parse back into the `<snapshotVersions>` list — each
  `artifact-version-yyyyMMdd.HHmmss-buildNo[.ext]` name contributes a `<snapshotVersion>` with
  its extension (and classifier when present), the `<snapshot><timestamp>/<buildNumber>` block
  takes the newest, and `<lastUpdated>` follows. This is the document a resolver reads to map
  `1.0.1-SNAPSHOT` to `qits-eventstream-1.0.1-20260802.123456-3.jar`. A snapshot directory
  holding **only** literal `-SNAPSHOT`-named files (a non-unique deploy) has nothing to derive
  and answers **404** — deliberately, because the resolver's defined fallback for a missing
  version-level document is exactly that literal filename, and serving an empty document would
  pre-empt the fallback with nothing in it.

Version ordering needs a small comparator — numeric tokens, qualifier rank with `SNAPSHOT`
below release. This is not `ComparableVersion`'s whole grammar; it is the subset the platform's
own versions exercise (`1.0.0`, calver `2026.801.85448`), written as one tested class with the
refusal-honesty npm's semver guard has: a version token that cannot be ordered is sorted last
and the document still serves, because a metadata `GET` that 500s breaks every consumer of the
repository at once. Group-level metadata (a path of group segments only) is legal maven and
derives the same way.

**The client's own `PUT` of `maven-metadata.xml` (and its checksums, at either level) is
accepted and discarded.** Every deploy plugin sends it; refusing would break `mvn deploy` on
its final request, after every artifact already landed. Storing it would serve a merge the
client computed, which goes stale the moment a second deploy lands — the exact
second-source-of-truth the derived document exists to prevent. So: `201`, nothing persisted,
`GET` serves the derived document.

### 3.5 Checksums are derived and verified, never stored

Every stored file serves `.md5`, `.sha1`, `.sha256` and `.sha512` siblings, computed at `GET`
time from the blob bytes (all four are one `MessageDigest` pass each; at platform jar sizes
this is milliseconds, and no cache is justified — measured against the real thing: the
eventstream jar is 47,940 bytes, and the platform's largest plausible jar is still single-digit
megabytes). md5 stays because legacy clients still ask for it; sha256/sha512 because modern
ones do. The store itself stays sha256-only, exactly as npm keeps sha1/sha512 in columns while
the blob key is sha256.

A checksum the client `PUT`s is **verified, not stored**: the handler recomputes the digest of
the referenced artifact's blob and answers `400` on mismatch — `requireClaimMatches`
verbatim (`NpmRoutes.java:418-435`), the npm restatement of "a blob that does not hash to its
name is not a blob". A match stores nothing: the checksum is derivable, so a stored copy is a
second source of truth that can only ever disagree. Metadata checksum PUTs are the one
exception — accepted without verification, because the client's metadata is a merge of its own
and our derived document legitimately differs (3.4).

### 3.6 Immutability and SNAPSHOTs — the three path classes (⚖1, ruled: full support)

With timestamped snapshots in the main design, the path space has three classes and each gets
the honest rule:

- **Release paths** are immutable, the npm 403 verbatim: a re-`PUT` with **identical bytes**
  (same sha256) is a `201` no-op — deploy retries are normal, and content addressing makes
  idempotency free — and a re-`PUT` with **different bytes** is `403`, naming the version and
  the rule: a coordinate that resolved to two different jars over its lifetime is the
  mutability this registry exists to refuse.
- **Timestamped snapshot files** (`…-20260802.123456-3.jar`) are unique by construction — one
  deploy, one filename — so they take the release rule unchanged: identical is a no-op,
  different bytes at the same timestamped name is a 403 that means the client's clock or build
  counter collided, which is worth saying loudly rather than absorbing.
- **Literal `-SNAPSHOT` filenames** (`qits-eventstream-1.0.1-SNAPSHOT.jar`, what a client with
  `uniqueVersion=false` deploys) are **mutable**: the coordinate is a moving target by
  definition, and a 403 here would break a legitimate redeploy while buying nothing — the
  timestamped form above is what every modern client sends, so this class exists for
  compatibility, not as the platform's own convention.

The deploy and resolve flows need no server-side rewriting: the **client** computes the
timestamped names (maven-3 `uniqueVersion` default, and Gradle likewise) and PUTs them as
ordinary files; the server's whole snapshot machinery is the version-level metadata derivation
of 3.4 plus the path grammar admitting `-SNAPSHOT` version directories. That is the smallest
honest form of "full snapshot support": unique files, derived snapshot metadata, resolver
fallback preserved.

### 3.7 Authentication: the npm posture verbatim, plus one recorded finding

**No login here either** — not a token, not a guard, nothing. The threat model is the OCI/npm
one word for word: producers and consumers are internal, dialling `qits-artifacts:8080` on
qits-net; from outside, `/artifacts/maven/**` is **not** on the gateway's `PublicPaths`, so it
falls under ordinary session auth like `/artifacts/npm/**` does (`PublicPaths.java` — the
allowlist names `/artifacts/git/`, `/artifacts/api`, and `/v2` for reads only, nothing else of
artifacts). No allowlist entry is added; whether a maven client can operate *through* session
auth from outside is out of scope, exactly as for npm. `ArtifactsTokenFilter` does not apply:
it is JAX-RS-only and sees no raw Vert.x route, by design
(`ArtifactsTokenFilter.java:24-29`). The proxy's upstream hop needs no credential either —
repo1.maven.org has no Docker-Hub-style anonymous pull limit, the same shape npmjs has
(`docs/npm-registry-notes.md`); the upstream config key exists so a credential can appear later
without a schema change, for the reason recorded there.

**The known finding, recorded and not solved here.** `/artifacts/api` and `/artifacts/api/` are
on the gateway's token-free `PublicPaths` for **all methods** (`PublicPaths.java:107-111`), on
the reasoning that the service's static-token filter guards the writes — and the live
deployment ships `qits.artifacts.token` **blank**, which makes that guard inert (README,
"Garbage collection", states this honestly). So the blob-store JSON API's writes — repository
ensure, blob upload, the GC sweep POST — are reachable through the front door today. The maven
surface does not worsen this: it adds no public path and shares the trusted-network posture.
The fix belongs to the standing qits-idp direction; per the recorded decision, no interim
token scheme is invented meanwhile. This plan changes nothing about it and says so rather than
leaving it to be rediscovered.

Client-side, no ceremony is needed at all: unlike npm's `ENEEDAUTH` pre-flight, maven sends no
credential unless challenged, and this server never challenges. A pipeline's
`distributionManagement` needs no matching `<server>` entry.

### 3.8 GC: one claim and one honest non-claim

`MavenPackagesGcStrategy` — `@Singleton` (the report names strategies by simple class name; a
normal-scoped bean answers through its client proxy), claiming `MAVEN_PACKAGES`, planning
`nothingDies` under a `note()`, keeping the default `apply` that refuses any condemning plan.
It takes the mirror's shape rather than the CI stubs': the CI shape fails closed *when rows
appear*, which made sense for types expected to stay empty; this type has rows from its first
hour — that is its purpose — so a fail-closed-at-rows stub would report `error` on every GC
plan forever, training the reader to ignore the one signal that means something.

The note is updated for ⚖1 as ruled — it can no longer say snapshots don't exist, because
they do from the first snapshot deploy: **releases are never eligible** (npm's rule and
docker's calver rule both reduce to this; a maven release repository is the purest form of
it), and **timestamped snapshot files accumulate** at one file-set per snapshot deploy —
priced honestly: jar plus pom at eventstream's 47,940-byte scale is noise, and even a CI
cadence of snapshot deploys is single-digit MiB per library per year. The cleanup rule is
named so the type is never silently absorbed into "misc" when someone wants the bytes back:
*snapshot cleanup — keep the newest N timestamped builds per (group, artifact, snapshot
version); releases never eligible*. Until that rule is implemented the posture is append-only,
said out loud, the mirror's precedent exactly.

`MAVEN_PROXY` is **deliberately unclaimed**, the `npm-proxy` line verbatim: its content is a
re-fetchable cache of upstream, its policy is eviction rather than retention, and eviction is
access-based — `artifact-access-tracking.md`'s territory. "No strategy registered for
maven-proxy" is the honest report of a decision recorded here rather than taken by drift (3.9).

The census wiring that makes any of this safe is in 3.11 and ships in the first workstream.

### 3.9 The Maven Central pull-through (⚖3, ruled: in scope)

**The history, recorded honestly before the design.** The npm proxy shipped together with the
hosted npm type; its *eviction* was then parked — `artifacts-gc-plan.md` ⚖1 ruled (a): cache
eviction is access-based cleanup, `artifact-access-tracking.md`'s first real client, and the
proxy grows unbounded until then (~800 MB measured at the time, ≈630 MiB of it packument CLOBs
in H2). `docs/npm-registry-notes.md` preserves what the proxy buys anyway: cold install 10.6 s
/ warm 1.7 s over 568 tarballs, the only install-time quantification of a pull-through cache
on the platform. This document recommended keeping Maven Central out of scope for the same
reasons; **the user ruled it in** — the recorded context stands, and the proxy below is
designed as settled, inheriting the parked-eviction posture with its eyes open (3.8).

The design is the npm proxy's, translated, with the oci-mirror's two additions where maven's
shape demands them:

- **One upstream, as a config key** — `qits.artifacts.maven.proxy.upstream`, default
  `https://repo1.maven.org/maven2`. The npm-proxy shape, not the oci-mirror's upstream table:
  there is exactly one upstream, so a row per upstream buys nothing; the key is also the test
  seam (the suites point it at an in-process stub, the `StubNpmRegistry` pattern). A
  `maven-proxy` repository fronts it; a `PUT` there is `405` **by type**, the namespacing rule
  every proxy type here carries: cached upstream content and published content never share a
  namespace, and no repository drifts from one meaning to the other because
  `ArtifactRepositoryService.ensure` makes a type immutable.
- **Artifacts are immutable, so a miss fetches once and keeps forever.** GET of a non-metadata
  path: row lookup → `sendFile` on a hit. On a miss: one upstream `GET` streamed through
  `BlobStore.stage` (hashing while streaming, for free), promote, write the `maven_artifact`
  row lazily, serve — the `recordProxiedVersion` precedent that keeps the tarball route one
  code path for both types. Growth is unbounded, exactly like the npm proxy's;
  `artifact-access-tracking.md` is the prerequisite for cleanup and now has a third waiting
  client.
- **Upstream's checksum is verified while streaming — the oci-mirror's untrusted-upstream
  rule.** A push from inside qits-net needs no verification (wrong bytes are promoted under
  their own true digest and cost nothing); bytes from the internet are not trusted. On a miss
  the proxy first fetches upstream's `.sha1` for the path (one small GET; Central serves them
  for every artifact), then streams the artifact and **deletes the staged file and answers
  `502` if the stream does not hash to upstream's claim**. That is what preserves the
  end-to-end argument npm's proxy makes with `integrity`: the client verifies against our
  derived checksums (computed honestly), we verified our bytes against upstream's at ingest —
  the chain holds transitively, and at no point does a hash this service computed vouch for
  bytes nobody checked. An artifact whose checksum upstream cannot produce is unverifiable and
  refused with the same 502 — acceptable against Central, which guarantees them, and stated so
  the refusal is a decision rather than a surprise.
- **Metadata is mutable, so it is cached with a TTL — the packument precedent.**
  `maven-metadata.xml` at any level changes upstream without anything here changing (a new
  release appears; a snapshot deploy lands), so it is cached in a
  `maven_proxy_metadata (repository, path, doc, etag, fetched_at)` table with
  `qits.artifacts.maven.proxy.metadata-ttl` (default `PT5M`, the npm packument TTL) and
  revalidated with the stored `ETag` on expiry — a `304` instead of a document. The document
  is stored **verbatim** and needs no rewriting at all, which is the one way maven is kinder
  than npm: maven metadata carries no absolute URLs, so there is no `dist.tarball` to re-point
  per request. When upstream is unreachable the stale copy is served anyway — CI keeps
  resolving through a Central outage, which is half of why this exists. One TTL covers
  snapshot metadata too: a fresher snapshot may be served up to one TTL late, which is the
  documented price of not hammering Central on every build.
- **Errors are the mirror's, verbatim.** Upstream unreachable with nothing cached → **`502`**,
  naming the upstream. Upstream asked and has no such path → **`404`**, naming the registry
  that was asked. Never a `500`: a network miss is not this service failing, and collapsing
  502 into 404 sends whoever is debugging a failed build to the wrong repository — the single
  most expensive wrong answer a proxy can give.
- **Every upstream wait carries a timeout and there are no retries**:
  `qits.artifacts.maven.proxy.timeout` (default `PT30S`) bounds one upstream request; the
  artifact transfer itself is bounded by `qits.artifacts.maven.max-artifact-size`, the same
  knob the hosted type is bounded by — one answer to "how large a jar is this deployment
  willing to hold", the npm `max-publish-size` precedent of one knob covering both directions.
- **The upstream client is a plain JDK `HttpClient`** in an instance field — no extension, no
  reflection registration, the `NpmUpstream` shape including its native-image rule. The suite
  cannot exercise real TLS by construction (clone-alone, no network), so — as with npm — **a
  deployment gets one manual smoke against real Central, once, on the native binary**:
  `curl -s http://<host>/artifacts/maven/central/org/apache/maven/maven/maven-metadata.xml | head`.

### 3.10 The Flyway migrations

Two migrations, each taking the next free V at its own land time (the rule is V7's own:
re-enumerate from the enum as it stands in the tree; `OciMirrorMigrationTest`, which loops
`RepositoryType.values()` over the real migration directory, is the guard that each constant
and its constraint widening land in the same commit):

1. **V8** (workstream CH): drop and re-add `ck_artifact_repository_type` with
   `MAVEN_PACKAGES` appended — the one-liner V2 made it, `if exists` keeping it re-runnable —
   and create `maven_artifact` (3.3) with its same-context foreign key to
   `artifact_repository(name)`.
2. **V9** (workstream CQ): the same one-liner for `MAVEN_PROXY`, plus `maven_proxy_metadata`
   (3.9) with its own same-context foreign key.

No prefills: both seeded rows (`maven`, `central`) come from the startup seeder, matching how
`npm`, `npmjs` and `qits` arrived — migrations prefill only what is static platform knowledge
(the three OCI upstreams), and seeded repository rows are not that.

### 3.11 Census, explorer, and the store summary

**Mandatory in the first landing** (without it, deployed jars are misreported as orphans on the
honesty panel):

- `LiveBlobCensus.take()` gains the maven half — `maven_artifact.blob_id` per repository, sized
  from the row (3.3 carries `size_bytes`, the one protocol table that has it, so no disk read
  and no null size like npm's). This is the `records.listDistinctBlobs` pattern at
  `LiveBlobCensus.java:186-189`, and it fills **both** maven types' live sets from the start —
  the `tarballs(hosted, …)` / `tarballs(proxied, …)` split at `LiveBlobCensus.java:192-195`
  verbatim — so CQ adds no census code when it turns the proxy on.
- The two exhaustive switches (`ArtifactExplorerService.java:239-254`) gain
  `MAVEN_PACKAGES, MAVEN_PROXY ->` arms: `itemCount` = artifact rows (files — one number with a
  type-dependent meaning, the standing convention; a proxied artifact appears only once
  pulled, the npm listing rule), `sizeOf` = the union over distinct blob ids. The compile error
  the enum addition causes is the wiring checklist working as designed.
- `StoreSummary` gains **`mavenPublishedBytes`** and **`mavenProxyBytes`**, and the identity
  becomes `diskTotal = ociUnion + npmPublished + npmProxyTarballs + mavenPublished +
  mavenProxy + orphans`. Both fields land in CH — the proxy figure reads zero until CQ fills
  it, which is the honest number, and the identity never changes shape twice. The explorer's
  byte-exactness tests are the proof and are updated in the same change — additive JSON
  fields, so the SPA breaks nothing by not knowing them yet.

**Follow-up** (named, not priced into the landings): browse routes for maven
(`GET /artifacts/api/repositories/{repo}/maven/…` — a GAV tree is a shape npm's
`packages`/`versions` pair does not fit, so it is its own small controller), and the SPA panel
showing the new summary figures (`frontends/qits-spa-artifacts`, a submodule change). Neither
gates the motivating flow.

### 3.12 Native image and tests

No new dependencies: XML is built as text (the derived documents are small; DOM/JAXB would buy
reflection surface for nothing), digests are `MessageDigest`, the upstream client and the test
clients are the JDK `HttpClient`. The two standing wire rules apply unchanged: **no DTOs on
wire routes** (responses are text/bytes/`JsonObject`), and every DB-touching method carries
the `@ActivateRequestContext`/`@Transactional` pair. If this type ever seems to need
native-image configuration, something reflective has crept in — the `registry`/`npm` bar is
zero.

The suites are the npm/OCI shapes again:

- **Hosted**: `maven/TinyArtifact` synthesises a real jar in memory, `maven/MavenClient`
  drives PUT/GET/HEAD round trips over the JDK `HttpClient` (no RestAssured — the path grammar
  and the percent-encoding questions are the point, same as npm), plus a `MavenPathsTest`
  pinning the grammar. Snapshot cases drive the real client flow: timestamped deploy,
  version-level metadata derivation, resolver-fallback 404 on a non-unique-only directory.
- **Proxy**: `maven/StubMavenCentral`, an in-process JDK `HttpServer` upstream driven over
  HTTP rather than by touching its fields — Quarkus instantiates a `QuarkusTestProfile` in two
  classloaders, so a static singleton exists twice (the `StubNpmRegistry` lesson). Every claim
  the cache makes is a claim about **upstream request counts**, so assert counters, not bytes
  — a test that only checked the content came back passes identically against a proxy that
  caches nothing. Fixture content is unique per **RUN**, never reused across runs: blobs
  dedupe globally and nothing wipes `target/artifacts-svc-test-blobs`, so reused content is a
  blob-store hit and the fetch count comes out one short with nothing saying why (the mirror
  suites' RUN-salt rule).

`PackagedProcessIT` gains a deploy-and-resolve case over HTTP for the hosted type and a
pull-through case for the proxy — the only place the route stacks are proved to coexist in the
packaged binary, the only place the Quinoa ignore-prefix change is exercised, and the only
thing that exercises the upstream `HttpClient` in the binary. There is **no network** in any
suite, so nothing stubs Maven Central except the in-process stub; the one real-Central smoke
is the deployment's, once (3.9).

The acceptance proof the suites cannot give is a **real `mvn deploy` and a real `mvn verify`
against the running service** — which is exactly workstream CM below. If an opt-in IT driving
real maven is ever wanted (the `OciConformanceIT` shape), it is its own later decision; the
guarded-by-unit-tests rule from the conformance section applies: anything it would prove must
be provable by `mvn verify` alone.

## 4. The decisions ⚖ — ruled 2026-08-02

**⚖1 — SNAPSHOT support: RULED, full timestamped support now (option (c)).**
This document recommended (a) release-only; **the user overruled** and took the largest
option. It lands as: unique timestamped snapshot files computed client-side and stored as
ordinary paths; version-level `maven-metadata.xml` derived from the timestamped filenames
(3.4), with the 404 fallback preserved for non-unique-only directories; the three path-class
immutability rules of 3.6; and the GC strategy's note updated to say snapshots exist and
accumulate, with the cleanup rule named (3.8). What made (c) cheaper than it looked is what
makes it honest: the server stays a dumb path store — the whole snapshot machinery is
derivation, not rewriting. It gets its own workstream (CJ) inside the hosted type's landing,
not a follow-up.

**⚖2 — the URL and the row name: RULED, mirror npm exactly.**
As recommended: `MAVEN_PACKAGES`, wire name `maven-packages`, segment `/artifacts/maven`,
seeded hosted row `maven`; the proxy type is `MAVEN_PROXY` with seeded row `central`, the
`npmjs`-names-the-upstream convention. One convention, no new vocabulary.

**⚖3 — a Maven Central pull-through cache: RULED, in scope.**
This document recommended out-of-scope, on the npm-proxy-parked history;
**the user overruled**. The history is recorded at the top of 3.9 rather than erased — the
eviction question is genuinely unresolved and is inherited knowingly: `MAVEN_PROXY` is
deliberately unclaimed by any GC strategy, and `artifact-access-tracking.md` gains its third
waiting client. The design is the npm proxy's translated (single config-key upstream, TTL +
ETag metadata cache, lazy immutable artifacts, serve-stale) with the oci-mirror's
untrusted-upstream verification added, and it is sequenced **after** the publish: the blocker
fix does not wait on the cache.

**⚖4 — the consumers' clone-alone rule weakens: RULED, accepted and documented.**
As recommended. Today a clone of qits-ci or qits-workspaces builds green with nothing but a
JDK **because the library is vendored**; the unwrapping replaces it with a repository URL:

```xml
<repository><id>qits-artifacts</id><url>${qits.maven.repository.url}</url></repository>
```

with the property defaulting to `http://qits-artifacts:8080/artifacts/maven/maven` (right on
qits-net, where CI builds and workspace containers live — and the shared `~/.m2` every
workspace container mounts caches it there), overridable to the local platform's address for
host-side development. A clone **off** the platform network can no longer resolve the
dependency — the rule weakens from "a JDK alone" to "a JDK plus the platform's maven
repository", the npm pipelines already pay exactly this price (`QITS_NPM_PROXY_URL` is passed
as environment, and a clone off qits-net cannot `npm ci` either), and both repos' AGENTS.md
say so in the unwrapping workstreams. Publishing to Maven Central, the durable answer, is its
own project (§6).

## 5. Workstreams

Letters continue after CG (the oci-mirror plan's last); CL is taken by
observability-ui-plan.md, so the sequence runs CH–CK, CM–CR. CH–CK are the hosted type; CM
publishes the library; CN/CO unwrap the consumers; CQ/CR are the pull-through, after the
publish per ⚖3; CP is the named follow-up batch.

- **CH — the substrate** (`services/qits-artifacts`): the `MAVEN_PACKAGES` constant with its
  javadoc citing the `OCI_IMAGES` profile; the `MavenArtifact` entity, id class and Panache
  repository; **V8** (constraint + table + FK); the seeder's `maven` row; the census's maven
  half for both maven types; the two explorer switch arms; `StoreSummary.mavenPublishedBytes`
  and `mavenProxyBytes` with the identity's tests; `MavenPackagesGcStrategy` claiming the type
  (3.8). Nothing here serves a request — and `mvn verify` proves the type is fully wired into
  everything that enumerates types.
- **CI — the wire, releases** (`services/qits-artifacts`): `eu.wohlben.qits.maven` in
  `service` (`MavenRoutes`, `MavenPaths`, `MavenErrors`), `MavenRegistryService` in
  `artifacts/control`, artifact-level metadata derivation and the version comparator,
  checksum derivation and verification, streaming PUT through the limit-aware stream,
  `qits.artifacts.maven.max-artifact-size`. The suite: `TinyArtifact` + `MavenClient` round
  trips, `MavenPathsTest`, deploy/resolve/immutability/derived-metadata cases. After CI, a
  JVM-fast-jar process deploys and resolves releases.
- **CJ — SNAPSHOT support** (`services/qits-artifacts`, ⚖1 as ruled): the path grammar's
  `-SNAPSHOT` version directories, the three path-class immutability rules (3.6), the
  version-level snapshot metadata derivation with its `<snapshotVersions>` assembly and the
  non-unique-only 404 fallback (3.4), and the snapshot cases in the suite driving the real
  client flow. Its own workstream because it is the ruling's price tag, kept visibly separate
  from the release wire it extends.
- **CK — the packaged proof** (`services/qits-artifacts`): `/maven` appended to
  `quarkus.quinoa.ignored-path-prefixes` (the hand-kept line at
  `application.properties:84`, comment updated like `/npm`'s), the `PackagedProcessIT`
  deploy-and-resolve cases (release and snapshot), and `./mvnw verify -Dnative` green. This is
  the gate that JGit's lessons built: nothing ships on a JVM-only green.
- **CM — publish qits-eventstream 1.0.0** (`libs/qits-eventstream`): set the version to
  `1.0.0`, add the `distributionManagement` block (or pass
  `-DaltDeploymentRepository=…::default::http://localhost:8081/artifacts/maven/maven` — decided
  at land time; the block in the pom is the durable answer, the flag is the no-diff proof),
  `mvn deploy` against the deployed local platform, tag `v1.0.0` in the library's own
  repository. Then resolve it back: a throwaway consumer pom with the repository declared,
  `mvn -U verify`, and a `curl` of the derived `maven-metadata.xml` naming `1.0.0`. A snapshot
  deploy of the next development version (`1.0.1-SNAPSHOT`) proves CJ end to end against the
  real service. **This is the plan's first real victory condition.**
- **CN — unwrap qits-ci** (`services/qits-ci`): remove the `eventstream` submodule and its
  `.gitmodules` entry, the `<module>eventstream</module>` reactor line, and the two
  `git submodule update --init --depth 1 eventstream` pipeline lines
  (`ci-post-receive.yml:46`, `ci-event-release.yml:84`) plus the Dockerfile comment; declare
  the repository (⚖4) and pin `qits-eventstream` at the **literal** `1.0.0` in
  `dependencyManagement` — a literal because the bumper no longer walks the library, and a
  literal survives every bump of the root. Update `pom.xml`'s module comment, README and
  AGENTS.md where they describe the vendoring — including the ⚖4 amendment of the clone-alone
  rule, in writing. `mvn verify` green with no `eventstream/` directory present is the proof.
- **CO — unwrap qits-workspaces** (`services/qits-workspaces`): the same five removals
  (`pom.xml:50`, `service/pom.xml:66-68`, `.gitmodules:7-9`,
  `ci-post-receive.yml:52`, `ci-event-release.yml:87`), the literal pin, the docs — **and the
  revert of the uncommitted `MavenVersionBumper.java` gitlink-skip change** (+48/−1 in the
  working tree at planning time). Once no released repository carries a submodule reactor
  module, the skip defends a shape that no longer exists; the bumper's "a module that resolves
  to a missing pom is a loud failure" becomes the correct behaviour again. The
  `version-fixtures/maven-reactor` test fixture models qits-ci's old reactor and is adjusted
  in the same change.
- **CP — the follow-ups, batched and optional** (`services/qits-artifacts` +
  `frontends/qits-spa-artifacts`): the maven browse routes (3.11), the SPA's store-summary
  figures, and — when someone wants the bytes back — the snapshot cleanup rule the GC
  strategy's note already names.
- **CQ — the Maven Central pull-through** (`services/qits-artifacts`, ⚖3 as ruled; after CM):
  the `MAVEN_PROXY` constant, **V9** (constraint + `maven_proxy_metadata`), the seeder's
  `central` row, the upstream client, the miss path with streaming checksum verification, the
  TTL/ETag metadata cache with serve-stale, the 405-by-type deploy refusal, the
  502/404/never-500 error semantics. The proxy suite: `StubMavenCentral`, counter assertions,
  RUN-unique fixtures.
- **CR — the proxy's packaged proof and adoption** (`services/qits-artifacts`, then consumer
  repos by opt-in): the `PackagedProcessIT` pull-through case, `./mvnw verify -Dnative` green,
  the one real-Central smoke on the native binary, and the documented consumer change —
  adding `/artifacts/maven/central/` as the second repository entry after `/artifacts/maven/maven/`
  (⚖2's ordered-pair convention) so third-party resolution rides the cache. Adoption is per
  consumer and never blocks the platform: direct Central resolution keeps working everywhere
  it works today.

Dispatch shape: CH → CI → CJ → CK → CM → (CN ∥ CO) → CQ → CR; CP anytime after CI. Nothing in
CN/CO starts before CM's resolve-back proof, because unwrapping against an unpublished library
is the incident this plan closes, replayed. Nothing in CQ delays CM: the vendored-submodule
removal is the goal, the cache is the follow-on.

## 6. Out of scope, named so it stays out

- **Access-based eviction of the proxy cache** — `artifact-access-tracking.md`'s feature, its
  third waiting client; the append-only posture is recorded in 3.8/3.9 with the npm-proxy
  history beside it.
- **Snapshot cleanup GC** — the rule is named in the strategy's note (keep newest N per
  snapshot version; releases never eligible) and lands when someone wants the bytes back, in
  CP at the earliest. The accumulation is priced in 3.8 and is noise at platform scale.
- **Guarding the wire surface** — the trusted-network posture is the platform's, the
  `/artifacts/api` write-guard finding is recorded in 3.7, and the standing qits-idp direction
  owns both. No interim token scheme is invented here.
- **Publishing to Maven Central** — the durable answer to ⚖4's clone-alone weakening and a
  project of its own (signing, staging, namespace proof).
- **A group/virtual repository view** — maven resolves its repository list in order
  client-side; the ordered pair of 3.1 is the whole routing story, the same reason npm needs
  no merged view.
- **Upstream credentials and multiple upstreams** — Central is anonymous (3.7); a second
  upstream or a credential arrives as an additive change the day one is needed, the
  oci-mirror's recorded posture.
