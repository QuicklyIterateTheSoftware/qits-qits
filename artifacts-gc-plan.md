# Garbage collection for the artifacts system: five strategies, one sweep

Status: **DECISIONS SETTLED 2026-08-05 — and they supersede this document's shape.** The user
answered the four ⚖ with a simpler model than §6 offered; §6's options are history, the
settlement below is the design. The standing rule stands: nothing deletes a byte until a dry-run
report has been reviewed. This platform has never deleted a byte; that changes here deliberately
or not at all.

## Settlement (user, 2026-08-05)

- **Two generic strategies, not five bespoke ones, configured per repository type:**
  1. *Cache types* (the proxy/mirror repositories — npm-proxy, oci-mirror, and kin):
     **delete everything unaccessed for $configured days.** Access tracking (shipped
     2026-08-02) is the basis.
  2. *Own types* (the platform's own artifacts — own npm, maven, docker images, daemon
     binaries…): **always keep the last released versions; delete the unaccessed rest.**
     Own-ness is what earns version protection; the version-keep circumvents the access rule
     only for own types.
  The mapping type → (strategy, window) is configuration.
- **Live pins are fetched by the GC process at sweep time, from the services that own them:**
  deployment-pinned image shas from qits-cd (qits-cd owns what "rollback-relevant" means and
  answers it; unreachable ⇒ the run aborts), the daemon pin from qits-ci's `GET
  /ci/api/daemon`. Pinned artifacts are never deleted regardless of access age. This answers
  ⚖2, ⚖3 and ⚖4 in one shape: the rowless legacy daemon blob needs no allowlist and no
  adoption — it is kept iff a live pin references it and ages out like anything else if not.
- **The GC engine is its own maven module** (`qits-artifacts-gc` or similar) in the
  qits-artifacts repo: a process modeled from within qits-artifacts, not artifacts domain.
- ⚖1's npm-proxy question dissolves: the cache strategy covers it; no parking, no blunt
  structural rule.

## The framing, which is load-bearing

There is **no single GC strategy** in this design, and there must not be one in the
implementation. The lens cannot sit on the blob storage: a blob is content-addressed bytes with no
meaning of its own, so "is this blob garbage" is not a question the blob store can answer. The
question lives one level up, in the **repository types** — the five constants of `RepositoryType`
(`services/qits-artifacts/artifacts/src/main/java/eu/wohlben/qits/artifacts/entity/RepositoryType.java:25`):
the git host, `oci-images` (docker), `npm-packages` (own npm), `ci-screenshots` (pictures),
`ci-videos` (videos). **Each of those logical systems gets its own GC system**, owning its own
notion of a dead identity, its own hazards, and its own rollout switch.

One rule for every implementer, stated here so nobody "helpfully" refactors it away: **docker's
and npm's strategies are similar today by coincidence, not by identity.** Both happen to reduce to
"releases stay, keep the latest prerelease" — but what a release *is*, what "latest" *is*, and
what deleting one *breaks* are entirely different in the two systems (sections below). They are
designed separately here and they are implemented separately: two strategy classes, two
workstreams, no shared policy code, no retention-rule framework. The only shared substrate is
deletion *mechanics* — the reference census and the blob sweep — which carries zero policy.

What a per-type strategy kills is an **identity**: a tag, a version, a pack description, a record
row. What actually frees disk is a **blob**, and a blob may only die when *no* type references it
any longer, because the store dedupes globally across types and repositories. The reconciliation
between those two statements is the hard design problem, and it is section 3.

## 1. What was measured (2026-08-01, live platform)

Every number below was read from the running platform or the checked-out sources. The browse API
shipped this week (`cb9f6b6`, `a138c46` in qits-artifacts) and is what made most of this
measurable at all.

### 1.1 The store, in seven figures

`GET /artifacts/api/store/summary`, live:

    ociPerImageSumBytes      5,830,203,554
    ociUnionBytes            5,479,048,925   (5.10 GiB)
    orphanBytes                130,419,952   (124.4 MiB)
    npmPublishedBytes              200,011   (195 KiB)
    npmProxyTarballBytes       171,951,885   (164 MiB)
    npmProxyPackumentBytes     660,287,820   (chars in H2, not on disk)
    diskTotalBytes           5,781,620,773   (5.38 GiB)

The identity `diskTotal = ociUnion + npmPublished + npmProxyTarballs + orphans` is computed
byte-exactly by deployed code
(`services/qits-artifacts/artifacts/src/main/java/eu/wohlben/qits/artifacts/control/ArtifactExplorerService.java:177-222`),
from one disk walk (`BlobDiskIndex`) and one manifest-closure pass (`OciManifestFootprints`).
Beside the blob store: the H2 file is 747 MB, 85% of it the npm-proxy packument CLOBs, and the git
host volume is 21 MB across 19 repositories — still file-backed, unchanged from the
storage-unification plan's measurement.

### 1.2 OCI is the bloat, and most of it is dead already

The `qits` repository holds 10 images, **110 tags, 183 manifests**. Of the tags, 108 are 40-hex
commit shas (post-receive pushes `:$QITS_CI_SHA` per commit), one is a stray short sha
(`qits-observability:2994a5e`, pushed once beside its full form), and exactly one is a release
version (`qits-stt:2026.801.85448`, from the first docker release pipeline). There is no literal
`-main.g<sha>` suffix in docker — the sha tag *is* the prerelease coordinate, and the version tag
is the release coordinate, a new tag beside the sha, not a replacement
(the SCM-release split's measured docker chain, docs/scm-release-split-notes.md).

**73 of 183 manifests have no tag at all.** A tag re-push (replayed post-receive, release re-run,
the same sha rebuilt) moves the tag row to the new manifest and leaves the old manifest row
behind. Measured by fetching every tagged manifest from `/v2` on :8081 and computing the blob
union:

    union over the 110 TAGGED manifests      3.79 GiB over 436 blobs
    ociUnion over all 183 manifests          5.10 GiB
    reachable ONLY from untagged manifests   ≈ 1.31 GiB

Nothing on this platform pulls by digest — qits-cd builds every ref as `qits/<app>:<sha>`
(`services/qits-cd/cd/src/main/java/eu/wohlben/qits/cd/control/ImageRefs.java:19`) — so those
1.31 GiB are reachable from no coordinate anyone uses. They are dead identities before any policy
is written.

### 1.3 What CD actually pins, and why the keep-rule must be chosen, not inherited

`GET /cd/api/deployments?environmentId=9fc2480c-…`: **74 rows, 9 ACTIVE** (one per application).
Each row pins a `commitSha`; the container was created from `qits/<app>:<sha>` and a restart pulls
that ref again — deleting a pinned tag surfaces later as `IMAGE_MISSING`, far from its cause.

Cross-referencing rows against tags: 71 of 110 tags are named by *some* deployment row; 39 by
none. Two keep-scenarios were computed over the real blob unions:

    scenario A: keep ACTIVE pins + version tags + newest sha per image
                keep 0.52 GiB  →  reclaims 3.27 GiB of the tagged union (86%)
    scenario B: keep every sha ANY deployment row ever named
                keep 3.69 GiB  →  reclaims 0.10 GiB (3%)

So the single decision that determines whether this GC does anything at all is **which
deployment rows count as rollback-relevant**. "All of them" reclaims nothing; "ACTIVE only" gives
CD no rollback target. That is ⚖2.

Adding scenario A's reclaim to the untagged-only 1.31 GiB: the heuristic removes **≈ 4.6 GiB of
the 5.10 GiB OCI union**. With npm-proxy parked, the whole store drops from 5.38 GiB to roughly
1 GiB. The user's claim — the simple rules remove most of the bloat — is measured true.

### 1.4 npm-packages is tiny, and is the right first proof

Two packages, 12 versions, 195 KiB total. `@qits/ui-components`: six unsuffixed versions
(`0.0.1`–`0.0.4`, `2026.801.63140`, `2026.801.85149`) and four `-main.g<sha7>` prereleases (two
per calver base); dist-tags `{latest: 2026.801.85149, main: 2026.801.85149-main.gd43d710}`.
`@qits/angular`: `0.0.1` plus one prerelease. The heuristic (unsuffixed stay; newest prerelease
per package stays) deletes **three versions** today. The bytes are noise — this strategy exists
for hygiene and to prove the machinery on the smallest possible blast radius, and among the three
is the task-branch mispublish `2026.801.63140-main.gab854a1` the handoff flagged, which is
exactly the kind of identity this GC is for.

Two constraints are load-bearing here. The registry refuses every client delete with 405 by
design (`services/qits-artifacts/service/src/main/java/eu/wohlben/qits/npm/NpmRoutes.java:123-130`
for unpublish; `…/registry/RegistryRoutes.java:135-142` for OCI), and version immutability
carries the whole-publish latest-guard: republish is 403
(`…/artifacts/control/NpmRegistryService.java:122-140`), and `requireLatestMayMoveTo`
(`NpmRegistryService.java:268-292`) refuses a publish that would move `latest` backwards. GC must
not weaken either — see 4.3.

### 1.5 The orphans are not all garbage — one of them runs CI

`orphanBytes` = 124.4 MiB in three ELF blobs with no row of any kind, uploaded through the OCI
blob-upload session with no manifest. But the live qits-ci container carries
`QITS_CI_DAEMON_VERSION=c04a603e95cf…` and resolves
`http://qits-artifacts:8080/v2/qits/ci-daemon/blobs/sha256:{version}`
(ship-the-ci-daemon.md:15); the blob at that digest exists on the volume (43,123,792 B, verified
in the container). **A sweep that deletes "everything referenced by no row" deletes the binary
every CI step downloads, and CI dies platform-wide.** The census's notion of "referenced" must
grow a class for configuration-pinned digests, or the daemon must get a real identity. That is
⚖3, and it is the single best reason the sweep ships dry-run first.

### 1.6 The git host: the debt is designed, the collector exists, the delete does not

The DFS migration (storage-unification plan, workstreams AT–AY) is in flight: the `git-storage`
module exists in the qits-artifacts working tree (untracked, workstream AV) with both ports
declared. `PackCatalog.commit(repositoryId, add, remove)` already expresses exactly what a repack
needs — add the new pack, drop the superseded ones, atomically — and its javadoc states the
current posture in one line: *"Dropping a description frees nothing — the blobs stay, because the
store has no delete"*
(`services/qits-artifacts/git-storage/src/main/java/eu/wohlben/qits/githost/storage/PackCatalog.java:12-13`,
`PackBlobStore.java:25-28`). The catalog table (V4) and the service adapters (workstream AW) have
not landed yet — the migrations directory still ends at V3.

The measured shape of the debt, from the unification plan: one pack triple (pack, index,
reftable) per push, no deletes, ~75 blobs per repository per year — and running
`DfsGarbageCollector` without a delete **doubles** the footprint (7.8 MB → 15 MB, measured).
⚖2 of that plan was settled *"(b) now, (a) later, and write (b) down"*. **This document is the
"(a) later" arriving**: it supplies the delete primitive that turns the recorded no-GC posture
into a safe repack-and-reclaim posture, without reopening anything that plan settled.

`BlobStore` today has no delete of any kind — its public surface is stage, promote, exists, open,
locate, size (`services/qits-artifacts/artifacts/src/main/java/eu/wohlben/qits/artifacts/control/BlobStore.java:30-289`),
and `promote` is documented as the store's one write funnel (`BlobStore.java:38`).

### 1.7 Pictures and videos: zero rows

`ci-screenshots` and `ci-videos` hold zero `artifact_record` rows — the golden-diff loop has
never produced anything. They are named types and get named strategies (4.4, 4.5), however small.

## 2. The two-layer model: identities die per type, blobs die by census

The design separates two operations that must never be one:

**Identity GC** — per repository-type, each with its own strategy, schedule and config flag. It
deletes *rows* (and, for git, catalog entries): an `oci_tag`, the `oci_manifest`s unreachable
from surviving tags, an `npm_version`, a `PackDescription`, an `artifact_record`. Identity GC
frees no bytes. It changes what the store *means*: after it runs, some blobs are referenced by
nothing.

**The blob sweep** — one shared mechanism, no policy. It computes the union of every type's live
blob set, diffs that against the disk, and deletes files no type references. It does not know
what a tag or a version is; it only knows the census.

This split is what makes "each type gets its own GC" compatible with "blobs dedupe globally": the
strategies never touch bytes, so no strategy can free a blob another type still needs, by
construction. A blob shared by an image layer and (hypothetically) anything else survives until
*both* sides have dropped it.

### 2.1 The census is already built — reuse it, do not reinvent it

The reference census this design needs is the one `storeSummary()` already computes to name the
orphans (`ArtifactExplorerService.java:177-222`): the OCI closure via
`OciManifestFootprints.union` (which walks index children, so a child manifest of a live index is
live), the npm tarball blob ids, and every `artifact_record` blob. It is deployed, it is
byte-exact against the disk walk, and its cache invalidation is already wired to the store's one
write funnel (`BlobDiskIndex.java:26-31`). The sweep's census is **the same computation with two
additions**:

- pack blobs: everything any `PackCatalog.list(repo)` returns, once the catalog exists (AW);
- pinned digests: the configuration-pinned set from ⚖3 (today: the live ci-daemon binary).

Extract it from the explorer service into a `LiveBlobCensus` that both the summary endpoint and
the sweep call, so the number the UI shows and the set the sweep protects can never drift. One
census, two readers — not a second census.

### 2.2 The delete primitive, and its constraints

`BlobStore` grows exactly one new method: `delete(blobId)`. Constraints, each tied to a thing
immutability currently guarantees:

- **Only the sweep calls it.** No route, no per-type strategy, no admin endpoint reaches it. The
  registries' 405s stay exactly as they are — client-facing deletion semantics are not being
  introduced (`RegistryRoutes.java:135-142`, `NpmRoutes.java:123-130`); GC is an internal
  process, not an API.
- **OCI digest stability is untouched by construction**: the sweep only deletes blobs the OCI
  closure does not reach, so no digest a surviving manifest names can disappear. The hazard is
  entirely in identity GC choosing the wrong survivors — priced per type in section 4.
- **The upload race is closed in-process, not by hope.** The known race: a client's blob-exists
  probe (or npm dedupe) answers "have it" for a blob the sweep is about to unlink; the manifest
  or packument that references it lands after the unlink. Two belts, both cheap on one node:
  the sweep never deletes a blob whose file mtime is younger than a grace window (proposed:
  7 days — covers any in-flight upload session by orders of magnitude), and the sweep re-runs
  the census immediately before unlinking and takes a short in-process mutex against
  `promote`/manifest-PUT for the final check-and-unlink of each blob. Both writers live in one
  JVM (`BlobStore.java:38`), which is what makes this sufficient.
- **Delete then invalidate**: each unlink invalidates `BlobDiskIndex`, same as promote does, so
  the summary stays honest through a sweep.

Deleted packument CLOBs are the one reclaim that is *not* a blob unlink: H2's `.mv.db` does not
shrink on row deletion. If ⚖1 brings npm-proxy in scope, freeing the 630 MB requires a compaction
step (`SHUTDOWN COMPACT` at a maintenance restart) and the plan must say so rather than report
bytes that never come back.

## 3. Also in reach: what this composes with, and what it supersedes

- **artifact-access-tracking.md (parked).** Last-accessed-based cleanup is *that* feature's job.
  The heuristics here are **structural** — they read what things *are* (a release, a superseded
  prerelease, an untagged manifest), never how recently they were used. The composition later is
  clean and worth stating now: the structural rules define what may **never** be deleted
  (releases, pins); access data will decide **when** to delete what remains eligible. Access
  tracking, when built, drives the same identity-GC and sweep substrate — it adds an input, not a
  second mechanism.
- **The explorer plan's parked retention idea** — "last build per branch while the branch exists"
  for prereleases. Superseded here, deliberately: post-receive publishes only main-suffixed
  coordinates today (`<version>-main.g<sha7>`; per-branch publish coordinates do not exist), so
  the branch-scoped rule has nothing to scope over. The per-type rules in section 4 replace it.
  If per-branch publishing ever appears, the rule returns as an amendment to the affected type's
  strategy — not as a cross-type framework.
- **git-host-storage-unification-plan.md ⚖2** — settled "(b) now, (a) later"; this is (a),
  arriving consistent with the PackCatalog port (1.6 above). Nothing in that plan's 5.1 module
  boundary changes: the `git-storage` module still never depends on `artifacts`; the GC driver
  and the delete live behind the ports it already declares.
- **handoff.md's "Tag GC" queue item** — this document is that item. Note its git half resolves
  to *keep*: the annotated version tags releases create are release identities, and releases
  stay. No git ref is ever GC'd; git's reclaim is packs only (4.1).
- **The safety culture** — the qits-project-delete blast radius and the never-delete-a-bare
  invariant apply in spirit: origins and release identities are never eligible, and every
  strategy's eligible set is enumerable in a report before anything acts.

## 4. The strategies, one per repository-type

### 4.1 git host — pack GC, gated on the DFS migration

**What it is for:** exactly the bloat the unification plan warns about. Under DFS every push
writes a pack triple forever, and `DfsGarbageCollector` doubles the footprint unless superseded
packs can actually be deleted. This strategy makes the repack safe: after
`DfsGarbageCollector` → `PackCatalog.commit(add=newPacks, remove=supersededPacks)`, the removed
descriptions' blobs are referenced by no catalog entry, the census (2.1) stops counting them, and
the sweep reclaims them. The measured spike numbers say what to expect: 22 packs → 2 in 409 ms,
and the old ~7.8 MB becomes deletable instead of permanent.

**Liveness expression:** a pack blob is live iff some `PackCatalog.list(repositoryId)` entry
names it. The catalog is already the sole authority for visibility ("committing a pack
description is what makes bytes visible, and dropping one is what makes them invisible" —
`PackCatalog.java:11-13`); GC adds no second bookkeeping.

**Trigger and cadence:** per repository, when its pack count crosses a threshold (proposed: 25 —
the worst live repo's count today) or on a coarse schedule. Not on every push: the repack costs
more than the pack it saves.

**What never dies:** refs. Version tags, branches, reflogs live in reftable blobs inside the same
catalog and are live by the same rule. Repository deletion is qits-projects' existing lifecycle,
not GC. The file-backed bares are out of scope forever (the migration plan's invariant).

**Gate:** meaningful only after AW (catalog) and AY (migration) land. Until repositories are on
DFS there is nothing to collect, and nothing here blocks AT–AY.

### 4.2 oci-images — releases stay, pins stay, the newest build stays, the rest dies

The docker rendering of the user's heuristic, mapped onto the coordinates that actually exist
(there is no literal suffix in docker — see 1.2):

**Keep, forever:** every non-sha tag that is a calver version (`2026.801.85448` today). That is
"releases stay". Cost: near zero — a release manifest shares its layers with its sha twin.

**Keep, while relevant:** every sha a qits-cd deployment row pins, for the row states ⚖2 selects
(recommended: ACTIVE plus the most recent previous distinct sha per application — the rollback
target). Plus the newest sha tag per image, which is "keep the latest build": it is the next
deploy's pull and the redeploy safety net for apps with no ACTIVE row (qits-spa-home's one tag
has no deployment row at all — measured).

**Delete:** every other sha tag (the stray short-sha `2994a5e` classifies as a sha tag and dies
with them), then every manifest row unreachable from a surviving tag — which includes the 73
untagged manifests. Reachability uses the same index-child closure as the census, so a child of a
kept index survives.

**The priced hazard:** `IMAGE_MISSING` on a CD restart or rollback that pulls a deleted `:sha>`.
Mitigations, all three: the keep-set is computed from CD's *live* answer
(`GET /cd/api/deployments`) fetched at GC time and re-fetched immediately before the tag
deletions apply; CD unreachable aborts the run with nothing deleted; and the newest-sha rule
means the next deployment's pull target is structurally never eligible. Who fetches the pins is
⚖4 — it is a new runtime dependency direction (qits-artifacts reading qits-cd) and the user
should choose it, not inherit it.

**Measured effect (1.2, 1.3):** ≈ 4.6 GiB of the 5.10 GiB OCI union becomes sweepable under the
recommended ⚖2 answer; scenario B proves the wrong answer reclaims 3%.

### 4.3 npm-packages — its own strategy, not docker's

Stated per the framing: this section resembles 4.2 and that resemblance is coincidence. Here the
identity is a **version string in a packument**, the suffix is literal, and the hazards are
registry semantics, not container pulls.

**Keep, forever:** every unsuffixed version — `0.0.1` through `2026.801.85149`. Releases stay,
including the pre-calver ones: consumers pin ranges (`^2026.801.85149`) and ranges must keep
resolving.

**Keep, while newest:** per package, the single newest `-main.g<sha7>` prerelease (the suffix
convention settled by the SCM-release split, docs/scm-release-split-notes.md), and — belt and braces — any version a dist-tag
currently names. Today those coincide: `main` names `2026.801.85149-main.gd43d710`, which is the
newest.

**Delete:** the other suffixed prereleases. Today that is three versions (1.4): both `63140`
prereleases (one of them the task-branch mispublish) and `85149-main.g21655ba`.

**Mechanics:** the served packument is assembled from `npm_version` rows at read time
(`NpmRegistryService.java:94`), so deleting a row cleanly removes the version from the document —
no stored document to rewrite. Delete the row and its dist-tag rows only if pointing at a kept
version (never delete a version a dist-tag names; move nothing). The tarball blob goes
unreferenced and the sweep takes it.

**What must not weaken:** the 405 on unpublish stays — GC is not unpublish semantics, and nothing
external gains a delete. The latest-guard keeps working untouched: it compares against the
`latest` dist-tag's version (`NpmRegistryService.java:268-292`), which is always a kept release.
Version immutability's meaning narrows honestly from "a version row is never touched" to "a
version, once published, is never *republished*" — the 403 on republish must hold **even for a
GC-deleted version**, or a deleted prerelease's name could be silently reused with different
bytes. The strategy therefore keeps a tombstone of deleted `(package, version)` pairs, and the
republish check consults it. That tombstone is npm's alone — docker needs nothing like it, which
is the coincidental-similarity rule earning its keep.

### 4.4 ci-screenshots — a named strategy with nothing to do yet

Zero rows. The strategy is a stub that ships its rule in writing and refuses to run while the
golden-diff loop produces nothing: when rows exist, keep the newest record per
`(git.branch.name, qits.userflow.name)` while the branch exists, delete records for deleted
branches. Liveness is `artifact_record.blob_id` — already in the census. The stub costs one class
and prevents the type from being silently absorbed into "misc" when the loop wakes up.

### 4.5 ci-videos — the same shape, its own strategy

Also zero rows, also a stub, deliberately its *own* stub: videos are orders of magnitude larger
per record, so its eventual rule is size-capped (newest N per userflow, N sized in bytes not
count) rather than screenshots' branch-scoped rule. Writing the two as one strategy today would
be the exact unification mistake this document forbids, at the cheapest place to demonstrate
the discipline.

### 4.6 npm-proxy — deliberately a decision, not a default (⚖1)

The user named five types; npm-proxy is not among them — and it is the largest real bloat outside
OCI: 660,287,820 chars of packument CLOBs (≈630 MiB, 85% of the 747 MB H2 file) plus 164 MiB of
tarballs, for 710 proxied packages. It is also the one store whose content is *reconstructible*: everything came from
upstream npmjs and can be re-fetched, so it is simultaneously the safest thing to delete and the
only deletion that costs a re-download later. Its natural policy is cache eviction —
access-based, which is artifact-access-tracking's territory, not a structural rule. Both honest
options are priced in ⚖1; this document does not choose.

## 5. Safety posture and rollout order

The platform has never deleted a byte. The order below is arranged so that the first real
deletion is the smallest possible one, and no deletion of any kind happens before its dry-run
report has been reviewed by the user.

1. **Substrate, no deletes** — `LiveBlobCensus` extracted, `BlobStore.delete` written but
   unreachable except by the sweep, sweep implemented **dry-run only**: it reports what it would
   unlink and cannot unlink.
2. **Dry-run reports for every strategy** — one JSON surface per type (`…/gc/plan`), each listing
   dead identities, kept identities with the keeping rule named, and bytes that would become
   sweepable. Plus the sweep's own report, which must visibly place the ci-daemon blob on the
   *kept* side (⚖3's proof). **The user reads these before anything else ships.**
3. **npm-packages goes live first** — three versions, ~KiB, and the packument assembly makes the
   result verifiable with one `GET /artifacts/npm/npm/@qits/ui-components`.
4. **oci-images**, in two steps: untagged-manifest removal first (no policy, only dead
   coordinates), the tag heuristic second, each behind its own flag.
5. **First real sweep** — manual trigger, once, after an H2 backup and a saved blob listing;
   verify the summary identity still balances and a CD restart of one app still pulls.
6. **git packs** — when AW/AY put repositories on DFS; per-repo threshold GC thereafter.
7. **Stubs (screenshots, videos)** ride along inert; **npm-proxy** if and as ⚖1 decides.

Every strategy and the sweep are independently config-flagged, default off, and every run —
dry or real — logs a per-type summary line, so "what did GC ever do" stays a question with an
answer.

## 6. The decisions ⚖

**⚖1 — npm-proxy: sixth strategy now, or parked for access tracking?**
(a) Park it: record here that proxy eviction is access-based cleanup, i.e.
artifact-access-tracking's first real client, and accept ~800 MB of cache (≈630 MiB of it in H2)
until then. (b) Take it now with a structural rule — evict any cached version that is not the
newest cached for its package and is older than a window, packument rows compacted at the next
maintenance restart — accepting that a structural rule on a cache is a blunt instrument and that
re-fetch costs return exactly as fast as builds re-request what was evicted.
*Recommendation, weakly held: (a) park it.* It is the biggest number in this document and the
smallest risk — nothing breaks, it only costs disk — and the access-tracking design it wants is
genuinely better than the blunt rule. But it is the user's number to spend.

**⚖2 — which CD deployment rows are rollback-relevant?**
The measured spread (1.3): keep-all-rows reclaims 3%; scenario A (ACTIVE plus the structural
keeps, nothing for rollback) reclaims 86% of the tagged union but leaves CD no rollback pull
target. Options: (a) ACTIVE only; (b) ACTIVE + the most
recent previous distinct sha per application; (c) ACTIVE + a time window (e.g. every sha deployed
in the last 7 days).
*Recommendation: (b).* It is the honest meaning of "rollback-relevant" on a platform whose
rollback is "redeploy the previous sha", it costs little (a previous sha shares its base layers
with the ACTIVE one), and it is computable from the same API response.

**⚖3 — the orphaned daemon binaries: allowlist, or a real identity?**
The live CI daemon binary is one of the three "orphan" blobs (1.5). (a) A configuration
allowlist: `qits.artifacts.gc.pinned-digests` holding the daemon digest; the census treats
pinned digests as referenced; the other two stale daemon builds (87,296,160 B, ≈83 MiB) become
sweepable. Two
config keys (this one and qits-ci's `QITS_CI_DAEMON_VERSION`) must then move together — the
same two-keys-move-together shape ship-the-ci-daemon.md already flags. (b) Give the daemon a
real identity first: the version-addressed `releases` surface priced in ship-the-ci-daemon.md
(a `RepositoryType` constant, a check-constraint widening, a route), after which the binary has
rows, the census sees it natively, and its own type gets its own (trivial) GC strategy like
everything else.
*Recommendation: (a) now — it is one config key and unblocks the sweep — with (b) recorded as
the durable fix that also closes ship-the-ci-daemon's deployment gap.*

**⚖4 — who supplies the CD pins to the OCI strategy?**
(a) qits-artifacts fetches `GET /cd/api/deployments` itself at GC time — one HTTP GET on trusted
qits-net (the standing posture: qits-net is trusted, no speculative schemes), but it is a new
runtime dependency direction: the artifacts service, deliberately domain-blind today, learns
where CD lives. (b) The keep-set arrives as data: the OCI strategy's run endpoint takes the
pinned-sha list in the request body, and some driver (an operator invocation first; later
whatever runs scheduled GC) assembles it — artifacts stays blind, at the cost of a driver that
must exist and be right.
*Recommendation: (a), with CD-unreachable aborting the run.* The purity argument for (b) is
real, but a driver that assembles the safety-critical input outside the service that acts on it
is a place for the two to drift, and drift here deletes images.

## 7. Per-type strategy summary

| type | identity that dies | keeps, always | keeps, conditionally | liveness expression | measured effect today | gate |
|---|---|---|---|---|---|---|
| git host | superseded pack descriptions (after repack) | all refs: version tags, branches | current packs | `PackCatalog.list` per repo | none yet (file-backed); prevents the 2× GC amplifier under DFS | AW + AY landed |
| oci-images | sha tags; manifests unreachable from kept tags (incl. 73 untagged) | calver version tags | CD-pinned shas (⚖2) + newest sha per image | footprint closure over kept manifests | ≈ 4.6 GiB of 5.10 GiB union sweepable | ⚖2, ⚖4; dry-run reviewed |
| npm-packages | suffixed `-main.g<sha7>` versions, except the newest per package | all unsuffixed versions; anything a dist-tag names | newest prerelease per package | tarball blob ids of kept versions | 3 versions, ~KiB (the proof case) | dry-run reviewed |
| ci-screenshots | records of deleted branches; superseded per (branch, userflow) | — | newest per (branch, userflow) | `artifact_record.blob_id` | zero rows — stub | rows exist |
| ci-videos | superseded per userflow beyond a byte budget | — | newest N per userflow, N in bytes | `artifact_record.blob_id` | zero rows — stub | rows exist |
| npm-proxy | ⚖1 | — | ⚖1 | packument/tarball rows | ~800 MB at stake (≈630 MiB in H2; needs compaction) | ⚖1 |

And beneath all of them, one sweep: `disk − (union of every live set above) − pinned digests`,
grace-windowed, re-censused before each unlink, dry-run until the user has read its output.

## 8. Workstreams

Letters continue after AY. The rule from the framing binds the split: BB and BC (and later BE/BF)
share **no policy code** — each owns its strategy class end to end. Only AZ and BA are shared,
and they are mechanics and reporting, never rules.

- **AZ — the shared substrate** (`services/qits-artifacts`): extract `LiveBlobCensus` from
  `ArtifactExplorerService` (summary endpoint and sweep both consume it); `BlobStore.delete`
  with the in-process mutex against `promote`; the sweep with grace window, pre-unlink
  re-census, `BlobDiskIndex` invalidation, and the pinned-digest set (⚖3a). Ships with the
  sweep hard-wired dry-run. Contains zero knowledge of tags, versions or packs.
- **BA — the dry-run report surfaces** (`services/qits-artifacts` + a page in
  `frontends/qits-spa-artifacts`): `GET …/gc/plan` per type plus the sweep's plan; the explorer
  gains a read-only GC panel showing them. This is the artifact the user reviews before
  anything in BB+ flips on.
- **BB — oci-images GC** (`services/qits-artifacts`, after AZ/BA and ⚖2/⚖4): the strategy of
  4.2 — untagged-manifest pass and tag heuristic as separate flags, CD-pin fetch with
  abort-on-unreachable, re-fetch before apply.
- **BC — npm-packages GC** (`services/qits-artifacts`, after AZ/BA): the strategy of 4.3,
  including the republish tombstone. Implemented without reference to BB, per the rule.
- **BD — git pack GC** (`services/qits-artifacts`, after AW and AY): the `DfsGarbageCollector`
  driver behind the `PackCatalog` ports, per-repo threshold, catalog commit as the kill. Stays
  consistent with the unification plan's 5.1 boundary — the driver depends on the ports, never
  on `artifacts` internals.
- **BE / BF — the two CI-type stubs** (`services/qits-artifacts`): rules written, execution
  refused at zero rows. Two workstreams on principle; each is an afternoon.
- **BG — npm-proxy** : exists only if ⚖1 chooses (b); includes the H2 compaction step and its
  maintenance-restart choreography.

Dispatch shape: AZ → BA → (BB ∥ BC) → first sweep → BD when the DFS migration is ready; BE/BF
anytime after AZ; BG per ⚖1. Nothing in any workstream deletes anything until its report from BA
has been reviewed.

## Out of scope, named so it stays out

- **Access-based retention** — artifact-access-tracking.md's feature; composes later (section 3).
- **Client-facing delete APIs** — the 405s are design, and remain.
- **Git ref GC, repository deletion, the file-backed bares** — never, per the standing plans.
- **A retention-rule framework, a policy DSL, or any unification of the docker and npm
  strategies** — forbidden by the framing, restated here at the exit so it is the last thing an
  implementer reads.
