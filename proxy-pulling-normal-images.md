# Pull-through cache: qits-artifacts as a registry mirror for base images

Status: **SHIPPED AND OBSERVED (2026-08-01)** — seeded 2026-07-29, settled in the morning (the
four ⚖ rulings stand inline), implemented and proven live the same day. The body below is the
settled design, kept as the record; §9's rollout steps are the ones executed. The measured chain:

- **BW** `f827ff2` (qits-artifacts) — the `oci-mirror` type, the upstream entity with CRUD, push
  refusal by type, the append-only GC stub.
- **BX** `4ba41ea` (qits-artifacts) — the miss path, double-pull proven on small images: cold
  pulls fetch lazily (busybox, 5 fetches; the s390x child on demand proving the Hub bearer
  dance), post-`rmi` pulls zero upstream fetches.
- **BY** — the FROM rewrite, all 12 repos green: qits-stt paid two manifest fetches cold, and
  the seven service builds after it fetched nothing upstream. The layer fill was deferred — the
  host daemon already held every base layer, so the mirror had manifests and no layer bytes.
- **CA** `c20a78f` (qits-spa-artifacts) — the upstream panel, `/artifacts/` → Mirrors.
- Bootstrap exception `30005f3` (superproject) — seed builds pipe their Dockerfiles through
  `seed_dockerfile` (mirror prefixes back to direct upstreams); pipeline builds keep the mirror.
- **BZ**, this closure — the forced layer fill and the offline proof, live on the canary
  (`qits-stt` at `ba2d5d71`):
  - Forcing the fill took more than `docker rmi` of the base tags: an orphaned
    `qits/mandrel-musl-builder` tag, 212 dangling intermediate images (33.3 GB,
    `docker image prune`) and the buildkit cache (`docker builder prune`) all pinned the base
    layers. ubi-minimal's single layer stayed pinned by every running service image — and never
    mattered: the store's global content-addressed blobs already carried it via the pushed
    `qits/*` images, so the mirror fetched only its child manifest (429 B) and config (5,936 B).
  - The forced cold rebuild (run `3f1a4545`, 97 s) pulled the mandrel builder through the
    mirror: one child manifest plus 15 blobs, **591,829,686 bytes fetched from quay.io**.
    `ociMirrorBytes` went 4,874,507 → **636,363,653**. §6 estimated 1.5–2.5 GiB for the full
    set; the graalvmce builder stays manifest-only until a bootstrap rerun next pulls it.
  - The offline check (run `243e49bb`, 106 s): green with **zero upstream requests** — the
    mirror's fetch counter read 18 before and after, no serve-stale lines — and no cache growth
    on a later build (§9 step 4's property). Byte check: the largest cached layer
    (203,879,195 B) served from mirror disk in 0.21 s, digest-exact.
  - The untouchable and GC figures moved only where expected: orphan (130,419,952 B) and all
    three npm figures byte-identical across the whole proof; `gc/plan` reports `oci-mirror`
    kept 8 / reclaimable 0 under "append-only pending access tracking"; `oci-images` dead grew
    270 → 340 only because the proof's rebuilds superseded their own predecessors.

Operating knowledge lives in the qits-artifacts README ("The pull-through mirror") and in
local-platform.md ("The base images pull through the platform's own mirror").

The intent, in the user's own frame: **transparently proxy every `FROM` image a docker build
pulls, cache it, and serve the next pull from disk — the npmjs proxy, for images.** The seed's
mechanism survives: qits-artifacts already speaks the OCI Distribution API, so the cache is **a
miss path** — on a manifest or blob GET the registry does not have, fetch from the configured
upstream, verify the digest while streaming (`BlobStore.stage` does that anyway), promote, serve.
A hit is the existing code unchanged.

What measurement changed is the *client* half. Truly transparent interception — no ref changes
anywhere — is not available: docker's `registry-mirrors` covers Docker Hub only, and the
platform's base images do not live there (1.3). The closest feasible shape, and the settled
design: **a generalized pull-through with one namespace per registered upstream, plus a one-time
rewrite of the 24 `FROM` lines to pull through it.** After that single mechanical edit, every
build pull flows through the cache with zero curation — new base images, new tags, new upstream
orgs all just work. That is the feature.

## 1. What was measured (2026-08-01, live platform + sources)

### 1.1 The registry surface the cache extends

- `/v2` is a raw Vert.x route at the **host root** (`services/qits-artifacts/service/src/main/java/eu/wohlben/qits/registry/RegistryPaths.java:27`),
  because docker resolves `<host>/<name>:<tag>` against `<host>/v2/` and accepts no path prefix
  (`RegistryRoutes.java:32-49`). Verified live: 200 on `:8081/v2/` (direct) and `:8080/v2/`
  (gateway — `services/qits-gateway/src/main/java/eu/wohlben/qits/gateway/QitsService.java:43`,
  allow-listed unauthenticated at `security/PublicPaths.java:59`).
- Image names split on the **first** slash: repository, then image
  (`artifacts/src/main/java/eu/wohlben/qits/artifacts/control/OciImageName.java:33-48`). The
  grammar (`:23-26`) accepts multi-segment images and dots inside components, so
  `quay/quarkus/ubi9-quarkus-mandrel-builder-image` parses today as repository `quay`, image
  `quarkus/ubi9-…`. Verified live: `GET :8081/v2/library/alpine/manifests/latest` → 404
  `NAME_UNKNOWN`, because no such repository row exists and rows are never created implicitly
  (`OciRegistryService.java:47-74`).
- The two miss shapes the cache hooks into: `serveManifest`'s
  `resolveManifest(...).orElseThrow(...)` (`RegistryRoutes.java:452`, → 404 `MANIFEST_UNKNOWN`)
  and `serveBlob`'s `blobStore.locate` catch (`RegistryRoutes.java:189-192`, → 404
  `BLOB_UNKNOWN`). Both already run on worker threads (`blockingHandler`), so an upstream fetch
  can block there without new plumbing.
- Tag→digest is the registry's **only mutable state** (`V2__oci_registry.sql:44-55`); a tag
  re-push updates the row in place (`OciRegistryService.bindManifest:97-109`). An OCI tag is
  npm's dist-tag analog, and it already has the mutable row a revalidation needs.
- Multi-arch is fully handled: all four manifest media types accepted
  (`artifacts/.../control/OciMediaTypes.java:8-13`), index children walked. One push-path rule
  matters here: `requireReferencesExist` (`OciRegistryService.java:142-158`) demands an index's
  children exist **before** the index binds. Pull order is the reverse — index first, children
  by digest afterward — so the mirror bind path must relax that rule (2.2).
- `DELETE` on `/v2/*` is 405 by design (`RegistryRoutes.java:134-142`); `/v2` carries no auth at
  all — write protection is the gateway's job (`RegistryRoutes.java:76-89`). Blobs are
  content-addressed and **global across repositories** (`BlobStore.java:24-30`), digest-verified
  while streaming (`BlobStore.java:163`), promoted through one write funnel (`:215-245`).

### 1.2 The npm-proxy precedent — the shapes to copy

`NpmUpstream` (`service/src/main/java/eu/wohlben/qits/npm/NpmUpstream.java`) is the platform's
existing pull-through cache, and its shapes transfer almost one-for-one:

| npm surface | behavior | OCI analog |
|---|---|---|
| packument (mutable) | TTL (`PT5M`) + `If-None-Match` revalidate (`:88-135`); **serve stale on upstream failure** (`serveStaleOrFail:203-211`); cold miss with upstream down → 502 | tag → manifest resolution (2.3) |
| tarball (immutable) | cached **forever**, no TTL, streamed through `stage`/`promote` (`:141-201`) | manifests-by-digest and blobs |
| upstream URL | config key with recorded rationale: "the key exists for the day a token is needed" (`service/.../microprofile-config.properties:96-99`; docs/npm-registry-notes.md) | upstream registry table (2.1), credential as a later additive column (2.4) |
| client | JDK `HttpClient` **instance** field, 10 s connect, 30 s doc / 10 min payload request timeouts (`:62-66,97-100,161`) | same, same reasons (native-image budget) |
| namespace | `npm` vs `npmjs` rows, two `RepositoryType`s, push refused **by type** with 405 (`NpmRoutes.publish:287-298`) | one row per upstream, one `OCI_MIRROR` type (2.1) |

The measured value of that cache: cold install 10.6 s / warm 1.7 s over 568 tarballs
(docs/npm-registry-notes.md). One pleasing loop: `RepositoryType.NPM_PROXY`'s javadoc already
cites "the namespacing rule the OCI mirror already settled" (`RepositoryType.java:95-105`) — this
seed's namespacing paragraph was consumed as precedent before the mirror was built.

Where OCI differs, and the TTL decision per surface: npm has one mutable document per package;
OCI has one mutable *pointer* per tag and everything else immutable. So the cache keeps
manifests-by-digest and blobs forever (the tarball rule) and revalidates only tags (the packument
rule) — cheaper than npm's revalidation, because a registry HEAD returns `Docker-Content-Digest`
(verified live against `/v2/qits/qits-stt/manifests/2026.801.85448`) and Docker Hub does not
count HEAD version checks against its pull limit (1.4).

### 1.3 The FROM inventory — where build pulls actually go

Every committed Dockerfile, measured. **Three distinct upstream refs, 24 external `FROM` lines,
12 files, two registries — neither of them Docker Hub:**

| ref | pulls from | used by |
|---|---|---|
| `quay.io/quarkus/ubi9-quarkus-mandrel-builder-image:jdk-25` | quay.io | 11 files (build stage): the ten `services/*/docker/Dockerfile` (e.g. `services/qits-artifacts/docker/Dockerfile:72`, `services/qits-stt/docker/Dockerfile:64`) + `daemons/qits-workspace-daemon/docker/Dockerfile:41` |
| `registry.access.redhat.com/ubi9/ubi-minimal:9.6` | Red Hat | the same 11 files (runtime stage, e.g. `services/qits-artifacts/docker/Dockerfile:173`) |
| `quay.io/quarkus/ubi10-quarkus-graalvmce-builder-image:jdk-25` | quay.io | `daemons/qits-ci-daemon/docker/Dockerfile.musl-builder:32` |

`Dockerfile.workspace` (`daemons/qits-workspace-daemon/docker/Dockerfile.workspace:27-32`) FROMs
only local `ARG` names (`qits/workspace:latest`, `qits/workspace-daemon:latest`) and is not
touched. The only Docker Hub pulls anywhere are three inline refs in `qits-local-up.sh`
(`docker:cli` :163, `node:24-alpine` :170/:180, `alpine/git` :392/:450) — bootstrap-time, before
qits-artifacts exists, so they **cannot** pull through the cache and stay as they are (a
cold-start cannot depend on the registry it is about to start).

Who resolves a `FROM`: the **host docker daemon**. CI docker steps get the socket mounted
(`CiDaemonLauncher.java:401-403`) and "the host's docker daemon, on the far side of the mounted
socket" runs the build (`:356-359`) — there is no dind and no step-container-side daemon
anywhere (grep-verified), so no step-side configuration of any kind is needed. And the host
daemon demonstrably reaches `localhost:8081` without TLS or insecure-registries changes:
qits-cd's every deploy pulls `localhost:8081/qits/<app>:<sha>` through it today
(`docker-compose.qits.yml:102,123`, `ImageRefs.java:19`), and 127.0.0.0/8 is in the daemon's
default insecure set (verified in `docker info`). A `FROM localhost:8081/…` line therefore works
on the build host with zero daemon configuration.

Also measured, and demoted to a footnote by this design: the host daemon is Docker Desktop
(29.5.3) with no `registry-mirrors` configured and a daemon config the platform does not manage.
`registry-mirrors` is Docker-Hub-only, and the table above shows the platform's bytes are not on
Docker Hub — so transparent daemon-level mirroring was never the mechanism here. If the operator
one day sets `"registry-mirrors": ["http://localhost:8081"]` in Docker Desktop settings, bare
Hub pulls (`docker pull alpine`) get mirrored too via the `hub` namespace (2.1's remap footnote);
nice if configured, not load-bearing.

One cost named honestly: after the rewrite, these Dockerfiles build only where a platform
registry answers on `localhost:8081`. Today the only place these images are built *is* that host
(CI post-receive on the platform), so the coupling is real but currently costless.

### 1.4 The upstreams' rules (docs.docker.com fetched 2026-08-01; quay/Red Hat from their public behavior)

- **Docker Hub**: anonymous **100 pulls / 6 h per IPv4**; authenticated Personal 200/6 h. A pull
  is counted on manifest **GET**; **HEAD version checks are free**; blob downloads are not
  separately counted; a multi-arch pull counts once per architecture fetched. Consequence: tag
  revalidation by HEAD costs nothing, and the lazy child-fetch order (2.2) is also the
  rate-limit-correct one.
- **quay.io** and **registry.access.redhat.com**: anonymous pulls, no documented Hub-style
  anonymous pull quota today. Both speak the same Distribution API; auth, where demanded, is the
  same 401 → `WWW-Authenticate: Bearer realm=…` token dance. A generic bearer-challenge client
  covers all three upstreams; per-upstream credentials are config (2.4).
- On this single-host platform every consumer already exits one IPv4 address, so the seed's
  worry that a mirror *concentrates* consumers does not apply: the cache strictly **reduces**
  upstream traffic (hits and HEAD revalidations are free).
- Docker-documented client behavior, relevant only to the footnote mode: a failed
  `registry-mirrors` mirror makes the daemon fall back to Docker Hub directly. Explicit
  `localhost:8081/…` refs have no fallback — the offline posture in section 5 is what covers
  them.

### 1.5 What is in flight beside this plan

- The GC substrate is live in the qits-artifacts tree: `GcStrategy` (one strategy per type, no
  shared policy, fail-closed — `GcStrategy.java:31-80`), `GcPlanner` per-type dispatch
  (`GcPlanner.java:51-80`), the dry-run-only `BlobSweep`, the 7-day grace window — and the first
  strategy (`OciImageGcStrategy`, workstream BB) is being implemented **right now, uncommitted**.
  Its keep-rules classify tags as calver-or-build-sha and keep anything unclassified
  (`OciImageGcStrategy.java:204-218`).
- daemon-artifact-identity-plan.md (settled, workstreams BH–BL) also widens the
  `ck_artifact_repository_type` check constraint. Two plans, one constraint — section 4 states
  the sequencing rule.

## 2. The design: generalized lazy pull-through

### 2.1 One namespace per registered upstream (⚖1 — settled, with a modification)

A new `RepositoryType.OCI_MIRROR` (wire `oci-mirror`, protocol-type profile: empty media-type
sets, zero cap — the `OCI_IMAGES` javadoc is the template). Upstreams are **rows in a new
entity, not config keys** — the user's modification to ⚖1, for discoverability: config keys are
invisible; a table has a UI. One table, `oci_mirror_upstream`:

    domain   PK    the registry's domain — docker.io, quay.io, registry.access.redhat.com
    slug     uniq  the local namespace segment — hub, quay, redhat
    (credential columns arrive later, additively — 2.4)

**Prefilled via migration** with those three rows (static public domains, unlike the
live-platform digests the daemon plan rightly keeps out of its lineage). The domain is the
upstream's identity; the mirror client derives the API endpoint from it (`https://<domain>/v2/…`,
with the one well-known exception `docker.io` → `registry-1.docker.io`). Each upstream row is
paired with an `artifact_repository` row named by its slug, type `OCI_MIRROR` — created in the
same transaction by the prefill and by every CRUD create, so namespace resolution on the miss
path is a table read, never a config lookup.

**CRUD under `/artifacts/api/mirror-upstreams`** (list/get/create/delete), following
`RepositoryController`'s conventions. Two notes for the implementer: writes must be added to
`ArtifactsTokenFilter`'s guarded prefix set (`Set.of("repositories","store","gc")`,
`ArtifactsTokenFilter.java:36,59-64`) or the route ships unguarded — the exact trap the daemon
plan records; and deleting an upstream removes the row (new misses in that namespace 404 again)
but leaves the repository row and all cached content in place, consistent with the append-only
posture (⚖2). A follow-up workstream (CA) gives the artifacts explorer SPA a management panel
over this API.

Cached content lives as ordinary `oci_manifest`/`oci_tag` rows under
`(repository=<slug>, image=<upstream path>)`: `quay/quarkus/ubi9-quarkus-mandrel-builder-image`,
`hub/library/alpine`. The existing first-slash grammar parses all of it with no change (1.1).
For the `hub` namespace only, a single-component image (`hub/alpine`) normalizes to
`library/<name>`, matching the docker daemon's own Hub normalization.

Pushes to any mirror namespace are **rejected outright by type**, the npm two-part shape
(`NpmRegistryService.requireNpmRepository` returns the type, the route refuses —
`NpmRoutes.publish:287-298`): every `/v2` write handler already starts with
`requireOciRepository` (`RegistryRoutes.java:233,262,292,300,482`), which gains the type
branch → 405 naming `oci-mirror`.

⚖1's declined alternative, for the record: **one** `mirror` row with the upstream as the
image's first segment (`mirror/quay/quarkus/…`) — fewer rows, longer refs, a row name that
means nothing, and per-upstream anything (credentials, a future per-upstream TTL) with no row
to hang on. The settled per-upstream shape makes `docker pull localhost:8081/quay/…` read like
what it is, and the entity gives every future per-upstream property its home.

Footnote, the `registry-mirrors` remap: a daemon-configured mirror client requests bare Hub
names (`/v2/library/alpine/…`). On GET/HEAD only, a first segment matching **no** repository row
(today's guaranteed 404, `OciRegistryService.java:61-74`) remaps into `(hub, <full name>)` when
a `hub` upstream is configured. Existing repositories always win, so `/v2/qits/…` never reaches
the remap; the known consequence — a Hub org named like a local repository is shadowed — is
documented, correct precedence here. This exists so the optional Docker Desktop setting works;
nothing else depends on it.

### 2.2 The miss path — one shared implementation for all upstreams

All fetches stream through the existing verify-promote funnel; nothing new touches disk
directly. The repository row names the upstream; everything else is identical per namespace.

- **Manifest by digest** (immutable): not in `(repo, image)` → upstream
  `GET /v2/<image>/manifests/<digest>` accepting all four media types
  (`OciMediaTypes.java:8-13`), verify the body's sha256 equals the requested digest, promote the
  bytes as a blob, insert the `oci_manifest` row, serve. Cached forever — the tarball rule.
- **Blob** (immutable): not on disk → upstream `GET /v2/<image>/blobs/<digest>`, streamed
  through `BlobStore.stage` (digest computed as it streams, `BlobStore.java:163`), refused on
  mismatch, promoted, served. Cached forever. Capped by the existing
  `qits.artifacts.oci.max-layer-size` (1G) — the builders' largest compressed layers sit in the
  high hundreds of MB, so the cap holds today, but it is the first knob to check if an upstream
  layer ever exceeds it.
- **Manifest by tag** (mutable): section 2.3.
- **Child ordering, deliberately relaxed**: the push path's `requireReferencesExist`
  (`OciRegistryService.java:142-158`) is not applied to mirror binds. A pulled index binds
  immediately; children arrive when the client requests them by digest, each fetch its own miss.
  Lazy is also cheapest — it never pays an upstream for an architecture nobody pulled (1.4). A
  mirror index may therefore reference children with no local row; BW pins that the census
  tolerates this (the manifest walk is lenient by construction,
  `OciManifestParser.sizedReferences:96-125`, but the property gets a test, not an assumption).
- **Scope**: the miss hook fires only for `OCI_MIRROR` rows (plus the remap footnote). The hit
  path for `qits/*` and every existing repository is the existing code, unchanged — the seed's
  sentence, still true.

### 2.3 Tag freshness: HEAD-revalidate, serve stale

A small companion table (same migration as the type), the `npm_proxy_packument` shape without
the CLOB: `oci_mirror_tag_check(repository, image_name, tag, checked_at)`.

On a tag GET in a mirror namespace:

1. Row fresh (`checked_at` within `tag-ttl`) → serve local. Zero upstream traffic.
2. Stale → upstream **HEAD** (free on Hub, cheap everywhere), compare `Docker-Content-Digest`
   against the stored `oci_tag.manifest_digest`. Equal → touch `checked_at`, serve local.
   Moved → one GET, verify, promote, `bindManifest` (the tag row's designed mutation,
   `OciRegistryService.java:97-109`), serve.
3. Upstream unreachable or 5xx → **serve the stale copy** and log, exactly
   `NpmUpstream.serveStaleOrFail` (`:203-211`). Cold miss with upstream down → 502, npm's
   wording.

Default `tag-ttl`: `PT1H`, one global key. This matters more than it did in the Hub-only
framing: `jdk-25` and `9.6` are **mutable tags** that Quarkus and Red Hat move under toolchain
and security updates, and TTL+revalidate is what keeps builds current with zero curation — the
exact ops burden the republishing alternative would hand to a human (section 3).

### 2.4 Upstream client and credentials (⚖3 — settled: anonymous only at launch)

`MirrorUpstream`, modeled line-for-line on `NpmUpstream`: a JDK `HttpClient` **instance** field
(never static — the native-image rule, `NpmUpstream.java:55-61`), 10 s connect, 30 s manifest /
10 min blob request timeouts, no retries, plus a generic bearer-challenge handler (401 → parse
`WWW-Authenticate` → token GET → retry) with an in-memory per-scope token cache honoring
`expires_in`. The same handler serves all upstreams. One config key remains:
`qits.artifacts.oci.mirror.tag-ttl = PT1H` (2.3).

**The clarification the ruling needed, recorded because the intuition is natural and wrong:**
a client's `docker login` does **not** carry through a pull-through hop. The daemon
authenticates to the registry it dials — this one — and the mirror dials the upstream **as
itself**; there is no mechanism by which a client credential traverses the hop. So a private
upstream requires a **server-side** credential the mirror owns, which becomes an additive
column pair on `oci_mirror_upstream` (username/token per domain) the day it is needed —
credentialed upstreams then ride the token GET as Basic auth, one code path already in the
client. Until that column exists, **private registries are explicitly out of scope**; every
launch upstream is anonymous, which today costs nothing: quay and Red Hat have no Hub-style
quota (1.4), and Hub faces a measured demand of zero after the rewrite. The first planned use
of the credential column is a Hub PAT the first time a 429 appears in the logs — the npm
upstream-key rationale with the day already scheduled.

## 3. The alternative, weighed honestly: a republishing pipeline

The user's suspected fallback: skip the miss path entirely. A pipeline (or script) pulls each
base image from upstream, retags it, and pushes it into the existing registry (ordinary
`OCI_IMAGES` rows under a `base` repository); Dockerfiles FROM the local name. It deserves a
fair price list, because at today's scale it is genuinely viable:

**Republish costs:** a curated list (3 refs today — trivially small); a *place to run* (the
platform has no scheduler: CI runs on push events, so refresh is a manual script or a bootstrap
step, and "did anyone refresh the builder since the CVE" becomes a human's job); an edit per
new base image forever; and mutable-tag staleness ops — `jdk-25` moves upstream and nothing
notices until someone re-runs the pipeline. **Republish advantages:** near-zero new registry
code (push paths exist and are proven), no internet in the serving path ever, and it could ship
this week.

**Pull-through costs:** BX is several days of real code (token dance, two fetch paths, tag
revalidation, tests). **Pull-through advantages:** zero curation forever — a new `FROM`, a new
tag, a new upstream org needs nobody's permission; staleness is a TTL, not a task; the npm
precedent already proved the shape end to end on this exact platform.

The numbers that decide it: the curated list is 3 today, but both republish cost lines recur
*forever* (every new base image, every upstream move), while pull-through's cost is paid once.
The FROM-rewrite workstream is **identical under both designs** — either way the Dockerfiles
point at `localhost:8081/<ns>/…` — so republishing saves only BX, and buys a standing ops duty
on a platform whose stated taste (the npm proxy, this seed) is caches that manage themselves.
Republishing is also not more offline-robust: both designs serve cached bytes without internet;
only the *first* fetch of anything needs the world, in both.

**⚖4, settled: pull-through.** Republishing stands recorded here as the weighed-and-declined
fallback — still reachable later at only BX's cost, since the type, the namespaces, and the
rewritten FROMs are common to both designs.

## 4. Two plans, one constraint: the sequencing rule

`ck_artifact_repository_type` is maintained by full re-enumeration: each widening migration
drops and recreates it naming **every** value (`V3__npm_registry.sql:7-11` is the pattern,
executed twice already). **Three in-flight workstreams claim migration numbers in this
lineage**: this plan's BW (constraint widening + `oci_mirror_upstream` + `oci_mirror_tag_check`),
the daemon plan's BH (constraint widening + `daemon_binary`), and the GC plan's BC, whose npm
republish-tombstone migration is being implemented right now. The rule, binding all three:

- A plan reserves **no** migration number. The daemon plan's "this is V6" is a slot, not a
  name; BC's and BW's numbers are equally unclaimed until they land.
- Each workstream takes the **next free V number in the tree at land time**, whatever its plan
  guessed. BC touches no constraint and only needs a number; BH and BW each recreate the
  constraint enumerating the **union** — the `RepositoryType` enum in the tree at land time is
  the source of truth the migration copies, so whichever widens second necessarily includes the
  first one's value.
- Seeded and prefilled rows are per-plan and idempotent; they cannot conflict.

No coordination beyond "take the next number, copy the enum you can see" is required, and none
of the three blocks another.

## 5. Blast radius: the serving path now touches three upstreams

qits-artifacts is the git host, the npm registry, and the OCI registry. Its OCI serving path
calling out — now to **three** public registries — is the platform's first hard runtime
dependency on the public internet while serving a request, and after the FROM-rewrite it sits
under **every service build**. The posture is the npm proxy's, inherited wholesale, and it is
what makes the rewrite safe:

- Scoped: the miss hook fires only in mirror namespaces. `qits/*`, npm, git — unchanged code,
  no new failure mode. qits-cd's deploy pulls never touch it.
- Bounded: timeouts on every upstream wait (2.4); worker-thread blocking is the accepted npm
  cost; per-upstream failure is independent (a quay outage cannot affect a `redhat/…` pull).
- Offline, in order of exposure: digest-addressed manifests and blobs serve forever with no
  upstream contact; stale tags **serve stale** — so once a base image has been pulled once,
  every later build succeeds with the internet down; only a never-cached ref fails (502). A
  fresh platform's first build needed the internet before this plan and still does. The cache
  makes an offline platform strictly more capable, never less.

## 6. Garbage collection (⚖2 — settled: append-only)

The GC framework this seed predates now exists (1.5), and its doctrine binds: one type, one
strategy, no shared policy. Two facts force a strategy *class* regardless of policy:

- `GcPlanner` dispatches per type; an unclaimed type is a gap, two claimants are a collision
  (`GcPlanner.java:60-74`).
- Mirror tags (`jdk-25`, `9.6`, `latest`) are neither calver nor build-sha. Inside `OCI_IMAGES`
  they would hit BB's unclassified-means-keep rule (`OciImageGcStrategy.java:204-218`) and
  distort its report. The separate type keeps BB's rules clean.

So BW ships an `OciMirrorGcStrategy` stub that claims `OCI_MIRROR` and reports everything kept,
rule named "append-only pending access tracking". The policy question is ⚖2, and the honest
numbers grew with the re-scope: the initial fill is no longer three small Hub images but the
real base set — the mandrel builder (1.8 GiB uncompressed in the host store), the graalvmce
builder (2.5 GiB), ubi-minimal (150 MiB). The store keeps **compressed** layers, so the
one-time cost is estimated **1.5–2.5 GiB** against today's 5.38 GiB store — call it half a
store, once. Ongoing growth is upstream tag movement stranding superseded manifests: at the
builders' observed cadence (toolchain releases), estimated low GiB per year, not per month.

A cache's eviction is access-based — which is exactly why npm-proxy eviction was parked for
artifact-access-tracking.md (artifacts-gc-plan.md ⚖1; the user chose parking). The mirror is
the second client of that decision. Mirror rows join the blob census automatically (the OCI
live set is the manifest closure over `oci_manifest` rows; BW pins that the new type's rows are
walked), so nothing cached is ever sweepable by accident.

## 7. The decisions ⚖ — all four ruled 2026-08-01

**⚖1 — namespace shape.** *Settled: a row per upstream — with the user's modification that the
upstream map is a **database entity with a CRUD API and a UI**, not a config map (their reason:
discoverability; config keys are invisible).* The design is 2.1: `oci_mirror_upstream` keyed by
domain, carrying the slug, prefilled with docker.io→`hub`, quay.io→`quay`,
registry.access.redhat.com→`redhat`; the miss path resolves namespaces from the table; the
explorer SPA gains a management panel (workstream CA). The declined one-row remap shape is
recorded in 2.1.

**⚖2 — GC posture at launch.** *Settled: append-only*, behind the type-claiming
`OciMirrorGcStrategy` stub, at the recorded price — estimated 1.5–2.5 GiB one-time fill plus
low-GiB-per-year drift (section 6). The structural bound (mirror manifests reachable from no
current tag and no cached index die after the grace window) stands recorded as the named first
amendment if measured drift outruns the estimate; access tracking remains the durable eviction
basis, as already decided for npm-proxy.

**⚖3 — upstream credentials.** *Settled as clarified: anonymous upstreams only at launch.* The
clarification is recorded in 2.4 — client `docker login` never traverses a pull-through hop;
the mirror dials upstream as itself, so private registries need a server-side credential, which
arrives later as an additive column on the entity. Private upstreams are out of scope until
that column exists; its first planned use is a Hub PAT on the first observed 429.

**⚖4 — lazy pull-through vs the republishing pipeline.** *Settled: pull-through.* The full
weighing is section 3; republishing stands as the weighed-and-declined fallback, reachable
later at only BX's cost.

## 8. Workstreams

Letters continue after BV.

- **BW — the mirror type, the upstream entity, and its API** (`services/qits-artifacts`; about
  two days): the migration per the section-4 rule (constraint widening + `oci_mirror_upstream`
  with its three prefilled rows and paired repository rows + `oci_mirror_tag_check`),
  `RepositoryType.OCI_MIRROR` (protocol-type profile), the CRUD API at
  `/artifacts/api/mirror-upstreams` with its write routes added to `ArtifactsTokenFilter`'s
  guarded set, table-driven namespace resolution, push refusal by type (405, npm's two-part
  shape), the Hub single-component normalization and the `registry-mirrors` remap footnote,
  the `OciMirrorGcStrategy` append-only stub claiming the type, and two pinned properties: the
  census walks mirror rows, and the census tolerates an index child with no local row. No
  upstream fetch yet — a mirror miss still 404s.
- **BX — the miss path** (`services/qits-artifacts`; the real work, several days):
  `MirrorUpstream` reading the upstream table, the generic bearer-challenge client with
  per-scope token cache (anonymous only at launch, ⚖3), the digest-manifest and blob
  fetch-verify-promote paths, the tag path (TTL, HEAD revalidate, GET on movement, serve-stale,
  502 cold), and tests modeled on `NpmProxyRevalidationTest` plus one wire test that the real
  pull shape — index → child → blobs, lazy order — round-trips against a fake upstream.
- **BY — the FROM rewrite** (12 submodule repos; mechanical, ~a day of fan-out): the 24 lines
  of 1.3 move to `localhost:8081/quay/…` and `localhost:8081/redhat/…`, `services/qits-stt`
  first as the live proof (section 9). Sequenced strictly **after** BX is deployed (a
  rewritten FROM against a mirror-less registry is a broken build), and honestly noted: 12
  repos × one push each on the single serialized CI worker, and the first post-rewrite build
  of each repo pays the cold fill. `qits-local-up.sh`'s three bootstrap Hub refs are
  explicitly not rewritten (1.3).
- **BZ — deployment doc + the live proof** (qits-artifacts README + this repo's docs; half a
  day): the reach statement (1.3), the anonymous-only credential posture and the
  login-does-not-traverse clarification (2.4), the Docker Desktop `registry-mirrors` footnote
  with the shadowing and fallback notes, and the rollout proof below, executed live.
- **CA — the upstream management panel** (`frontends/qits-spa-artifacts`; about a day): a page
  in the artifacts explorer listing `oci_mirror_upstream` rows with add/remove over BW's API —
  the discoverability the user ruled ⚖1 for. Read view shows domain, slug, and the namespace's
  cached image count; remove warns that cached content stays (2.1).

Dispatch shape: BW → BX → deploy → BY → BZ, CA anytime after BW's API is deployed. BW's
migration coordinates with the daemon plan's BH and the GC plan's in-flight BC only through
the section-4 rule. Nothing here blocks, or is blocked by, BB or the sweep.

## 9. Rollout, proven with one build

1. BW+BX ride an ordinary release and deploy of qits-artifacts.
2. Smoke, before any rewrite:
   `docker pull localhost:8081/quay/quarkus/ubi9-quarkus-mandrel-builder-image:jdk-25` — one
   command exercises namespace, tag fetch, index, child, and blob paths, and pre-fills the
   biggest cache entry.
3. BY rewrites one repo first (`services/qits-stt`, the smallest docker consumer); its push
   triggers the ordinary post-receive build, and **the proof is that build**: it goes green
   with the mirror logs showing upstream fetches only for what step 2 did not already cache.
   Then, on the host: `docker rmi` the pulled base refs and rebuild — the second build
   completes with **zero upstream fetches** in the mirror log. That is the feature, observed:
   every `FROM` served from local disk.
4. Fan BY across the remaining 11 repos; `GET /artifacts/api/store/summary` afterwards shows
   the fill (estimated 1.5–2.5 GiB, section 6) — and no further growth on later builds.
5. Watch for 429/5xx per upstream in the qits-artifacts logs; a Hub 429 is ⚖3's trigger.

## Out of scope, named so it stays out

- **Managing the host daemon's configuration** — Docker Desktop owns it; the platform
  documents, never writes. `registry-mirrors` remains an optional operator nicety (1.3).
- **Rewriting `qits-local-up.sh`'s bootstrap pulls** — a cold start cannot depend on the
  registry it is about to start.
- **Access-based eviction** — artifact-access-tracking.md's feature; the mirror joins
  npm-proxy as its second waiting client (⚖2).
- **Signing / content-trust verification** — digest verification is the integrity property
  this platform claims; the trusted-net posture stands.
- **Serving the mirror to anything off qits-net** — `/v2` stays anonymous-read behind the
  existing gateway posture; no new auth surface.
