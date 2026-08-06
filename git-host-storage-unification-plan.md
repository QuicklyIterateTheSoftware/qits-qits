# Unifying the git host onto the platform's blob storage

Status: **EXECUTED ON THE LOCAL PLATFORM, 2026-08-06.** The user gave the go the same day the
cheap proof ran. The flip followed section 5.4's discipline: full mirror backup of all 41
repositories first, `-e QITS_REPOSITORIES_GIT_STORAGE=dfs` added to qits-artifacts' cd run-args
(backup at `application.properties.bak-prefdfs` on the qits-cd-config volume), qits-cd restarted,
the current sha redeployed by replaying `build-succeeded`, then every repository imported through
the wire (`PUT` create + `--mirror` push, `qits-artifacts` itself last) and verified with the three
checks: `ls-remote` ref-for-ref against the pre-flip record, fresh-clone `git fsck --full` clean,
`HEAD` match. 41/41 passed. The file-backed bares stay untouched on the `qits-repositories` volume
as the rollback (a config flip back), per this plan's one invariant.

Every path was then verified live on DFS, each with a real run, not an assertion:

- **Protection**: a tokenless direct push to `main` is refused with the documented message; the
  `qits.token` and `qits.release` bypasses both work.
- **Post-receive → CI**: workspace branch creations and ordinary pushes each produced a green run;
  every run clones from the DFS host.
- **Repository lifecycle over HTTP**: qits-projects created a repository by importing another
  DFS-served repository (ref-for-ref identical); registration delete leaves the git repository
  serving — correct, the host deliberately has no delete verb.
- **History reads**: branches and commit logs through qits-projects' mirror cache.
- **The release train**: epic + task workspaces, integrate (merge + push, branch auto-deleted),
  release onto protected `main` (version stamp, annotated tag, `--atomic` main-plus-tag with
  `qits.release`), then `SCMRelease` → event-triggered run on `main`'s head → `BuildSuccessful` →
  `SoftwareRelease` (npm/sv-train), correctly parented.
- **Workspace provisioning**: a workspace container provisioned to RUNNING with the daemon's clone
  from the DFS host inside it, then discarded clean.
- **Service deploy**: a qits-stt push built and deployed from a DFS-served clone
  (container swapped to the new sha).
- **The self-hosting path**: qits-artifacts rebuilt and redeployed **itself** from its own
  DFS-served repository (`a84b2cb`), and the store served all repositories unchanged across its
  own restart.

Standing consequences: never run `DfsGarbageCollector` (§1.7 — it doubles the footprint; posture
⚖2(b) is now live). The `DfsBlockCache` rides JGit's 32 MiB default; today's whole git host fits
in it.

**Later the same day the user retired the file backend entirely**, overriding ⚖4's
one-release-cycle grace. In order, each step verified before the next: the volume mount left
qits-artifacts' run-args and the host served all repositories without it; the `qits-repositories`
volume was **deleted** (final tarball: `~/qits-git-bares-final-2026-08-06.tar.gz`); the file
backend left the codebase (qits-artifacts `508e598` — provider, selection seam, `storage` and
`data-dir` properties, Dockerfile paths, dual-backend tests; 504 tests green, packaged git ITs
prove the native binary); and `qits-local-up.sh` stopped seeding bares — a fresh platform now
creates repositories over the wire (`PUT` + push) once the host answers (home repo `6843faf`,
syntax-checked but not yet exercised by a fresh bootstrap). The dfs-only image built and
**deployed itself from the DFS store**, and a clone + branch push/delete round-trip passed on the
new binary. Rollback is roll-forward: every prior image sha serves the same DFS store.

The evidence below is the decision record as it stood. Earlier the same day the cheap proof had
run against the **live image** — no longer the spike:

- A second qits-artifacts container (the deployed image, `b0718dd7`) on port 8090 with
  `storage=dfs` and a scratch store booted clean in 0.09 s; migrations V4 (pack catalog) and V5
  (ref protection) applied.
- `PUT /artifacts/git/qits-workspaces` created the repository; a `--mirror` push imported the
  platform's largest real history (6,411 objects) in 0.16 s.
- All three checks green: `ls-remote` matched the live host ref-for-ref (symbolic `HEAD`
  included), a fresh clone (0.10 s) passed `git fsck --full`, and `HEAD` matched (`3d440c1`).
- Bonus, both confirmed on the shipped engine: the packs lived only in the blob store
  (`/data/repositories` stayed empty), and a `git push --atomic main + tag` landed with a clean
  fsck after it — the release flow's requirement (⚖1) holds outside the spike.

The proof instance was ephemeral and is torn down; reproducing it takes about a minute with the
commands above. What remains pending is the decision itself, not evidence for it.

The question, in the user's terms: the git host models its persistence as block storage (bare repos
on a filesystem volume). Everything else on the platform persists through qits-artifacts' internal
content-addressed blob store plus H2. The preference is for one persistence layer. Is a unified git
host **sensibly feasible** — and if so, what does it cost?

The short version: **the git host is the easy half, and it is proven.** A spike ran this session
served real `git clone`, `git push`, an `--atomic` tag-plus-branch release push and a garbage
collection out of a content-addressed blob store, using the platform's own largest repository. The
expensive half is that three services reach into the bare repositories through the filesystem, and
**a `DfsRepository` has no filesystem representation at all** — the git CLI cannot open one. Every
one of those call sites has to go.

---

## 1. What was measured

Nothing below is inferred. Live reads were taken from the running platform; the JGit behaviour was
taken from a compiled spike driven by the real `git` CLI (`git version 2.53.0`) against
`org.eclipse.jgit:7.3.0.202506031305-r`, the version this repo pins
(`services/qits-artifacts/pom.xml:65`).

### 1.1 The live git host is tiny, and already un-garbage-collected

The whole `qits-repositories` volume is **21 MB across 19 repositories**. The largest bare is
`cdc57370-…` at 8.4 MB / 20,733 objects; the largest *platform* repository is `qits-workspaces` at
2.0 MB / 5,683 objects. Refs per repository run **1 to 3** — one branch, sometimes one tag.

The pack counts are the interesting number:

    qits-ci                  1,662 objects in  25 packs
    qits-spa-home              220 objects in  17 packs   + 9 loose (9 prune-packable)
    qits-artifacts           1,033 objects in  15 packs
    qits-workspaces          5,683 objects in  14 packs
    qits-spa-ui-components     194 objects in  13 packs   + 13 loose (13 prune-packable)

Two facts fall out of that table and both matter later:

- **Nothing ever repacks.** One push, one pack, forever. This is the no-GC posture working exactly as
  designed, on the filesystem, today. Moving to a blob store does not create that problem; it
  inherits it.
- **There are two writers into the object store, not one.** The packs are JGit's receive-pack. The
  *loose* objects — with `prune-packable` equal to the loose count, meaning they duplicate objects
  already in a pack — are the git CLI writing straight into the bare through a linked worktree. That
  is the coupling the SCM-release split measured (finding preserved in
  services/qits-workspaces/AGENTS.md and docs/scm-release-split-notes.md). **JGit's DFS storage has no loose
  object concept at all**, so this second writer cannot survive the change in any form.

### 1.2 The blob store is 250× larger than the git host

    /data/artifacts/blobs      5.3 GiB
    /data/artifacts/h2         746 MiB   (artifacts.mv.db, 782,778,368 bytes)
    /data/repositories          21 MB

The H2 bulk is the npm proxy's packument cache: `npm_proxy_packument.doc` is a `clob` holding
upstream's document verbatim, per package
(`services/qits-artifacts/artifacts/src/main/resources/db/artifacts/migration/V3__npm_registry.sql`,
the `npm_proxy_packument` block). Git metadata added to this database is noise against that: the
measured rate is **3 rows per push** (see 1.4), so the entire platform's history to date would be
roughly 1,400 rows.

**Git is a rounding error in this platform's storage.** That cuts both ways — it means unification
buys little capacity-wise, and it means the migration is cheap to stage and cheap to roll back.

### 1.3 The DFS abstraction is small, present, and the ref database is free

`org.eclipse.jgit.internal.storage.dfs` is in the pinned jar — 101 class entries, including
`InMemoryRepository`, so no extra dependency is needed to spike or to test.

A backend must implement exactly this much:

- `DfsObjDatabase` — **six** abstract methods: `newPack`, `commitPackImpl`, `rollbackPack`,
  `listPacks`, `openFile`, `writeFile`. Plus `getApproximateObjectCount()`, which `ObjectDatabase`
  declares abstract in 7.3 and `DfsObjDatabase` does not fill in.
- `DfsRepository` — `getObjectDatabase()` and `getRefDatabase()`.
- The ref database: **either** `DfsRefDatabase` (three abstract methods: `scanAllRefs`,
  `compareAndPut`, `compareAndRemove`, plus `getReflogReader(Ref)`) **or** the stock
  `DfsReftableDatabase`, which needs a `{}` subclass and nothing else.

`writeFile` returns a `DfsOutputStream`, which is not a plain `OutputStream`: it declares
`read(long position, ByteBuffer)`, so JGit reads back bytes it has not finished writing.
`openFile` returns a `ReadableChannel` with `position(long)` — **random access, not a stream**.

Both requirements land inside `BlobStore`'s existing shape rather than against it:
`BlobStore.locate(String)` already hands out an absolute `Path` for zero-copy serving
(`services/qits-artifacts/artifacts/src/main/java/eu/wohlben/qits/artifacts/control/BlobStore.java:225`),
which is exactly what a `FileChannel`-backed `ReadableChannel` needs. The write side does **not**
fit as-is: `BlobStore.IncrementalStage` is write-only
(`BlobStore.java:79-158`), so the adapter must stage into its own read-write temp file and hand the
finished file to `promote()` — a real but small addition.

### 1.4 The spike: a content-addressed git host, driven by the real git CLI

Written to `scratchpad/Spike.java` (throwaway, in no repository): a `DfsRepository` whose pack files
are stored as sha256-addressed files under a fan-out directory — the shape of `BlobStore` — served
through a transcription of `GitHostRoutes`' three smart-HTTP endpoints.

**Everything works.** Clone of an empty repo, ten sequential pushes, annotated tag, fresh clone,
`DfsGarbageCollector`, push after GC. Zero server-side exceptions. The routes needed **no structural
change**: `DfsRepository extends Repository`, so `GitHostRoutes.infoRefs` and
`GitHostRoutes.service` (`:178-268`) are untouched — only `open()` at `:280-302` changes.

Two bugs the spike hit are worth passing on, because an implementer will hit both:

- **`DfsOutputStream.close()` is called more than once.** A promote-on-close that is not idempotent
  fails the second call with `NoSuchFileException` on its own temp file, and the symptom is
  `UnpackException: Exception while parsing pack stream` on *every* push.
- **`getRefDatabase()` must return a cached instance.** Constructing a new one per call silently
  breaks ref reads.

### 1.5 The ref-backend choice decides whether the release flow survives

This is the load-bearing measurement of the whole document. The two ref backends were driven through
the release flow's actual requirements:

| | `DfsRefDatabase` (rows) | `DfsReftableDatabase` |
|---|---|---|
| `atomic` in the receive-pack advertisement | **absent** | **present** |
| `git push --atomic main + tag` | **`fatal: the receiving end does not support --atomic push`** | succeeds |
| non-forced re-point of an existing tag | rejected (`already exists`) | rejected (`already exists`) |
| atomic push where one ref is refused | n/a | **all three rejected, `main` unmoved** |
| push options (`-o`) reach the hook | yes | yes |
| reflogs | none (`getReflogReader` returns null) | native |
| where refs live | new H2 rows | reftable blobs in the same pack store |
| new storage primitives needed | ref table + compare-and-swap | **none** |

The advertisement lines, verbatim from the spike:

    DfsRefDatabase       … side-band-64k delete-refs report-status quiet ofs-delta push-options …
    DfsReftableDatabase  … side-band-64k delete-refs report-status quiet atomic ofs-delta push-options …

`services/qits-artifacts/CLAUDE.md` records that `--atomic` **works today** on the file-backed store
and that a release push "should pass `--atomic` — otherwise a duplicate version rejects the tag while
its merge commit lands on main". `ReleaseIntegrator` passes it
(`services/qits-workspaces/domain/src/main/java/eu/wohlben/qits/workspaces/control/ReleaseIntegrator.java:594-620`).

**So a plain `DfsRefDatabase` backend would break the shipped release flow on day one**, and the
reftable backend both preserves it and needs *less* code. That is an unusual and welcome shape: the
better option is also the smaller one.

The reftable run also reported `refs=0 refCas=0` in the spike's own instrumentation — confirming the
refs went nowhere near the row store. The ref database rides `openFile`/`writeFile` like everything
else.

### 1.6 Performance, on the platform's largest real history

The 8.4 MB / 20,733-object bare, copied out of the live volume and pushed into the blob-store-backed
repository:

    seed push (20,733 objects)          0.59 s wall, 19 MB RSS
    clone from DFS                      0.75 s cold, 0.46 s warm
    clone from the file-backed bare     0.26 s          (same JGit, same objects — the baseline)
    20 further incremental pushes    →  22 packs, 65 blob rows, 65 blob files
    clone after those 20 pushes         0.39 s          (no degradation — DfsBlockCache)
    DfsGarbageCollector                 409 ms, 22 packs → 2
    clone after GC                      0.23 s

For scale, the live host over HTTP today: `qits-workspaces` clones in **0.09 s**, `qits-projects` in
0.06 s, `qits-ci` in 0.04 s.

**Blob storage is roughly two times slower than the filesystem for a cold clone and identical once
warm, at a scale where both are under a second.** Performance is not the objection.

`DfsBlockCache` defaults to a **32 MiB** limit in 64 KiB blocks. The entire live git host is 21 MB,
so at today's size the whole platform's git fits in the default cache — which is why the "after 20
pushes" clone did not degrade. It is JVM heap in a process that also carries a 1088 MB global body
ceiling for OCI layers, so the number must be set deliberately rather than inherited.

### 1.7 The cost nobody can wish away: GC becomes a storage amplifier

`DfsGarbageCollector` works, and it is fast. But in a store that never deletes, it does not reclaim —
it **duplicates**:

    before GC   22 packs   7,832,117 bytes across 65 blob files
    after GC     2 packs  14,749,384 bytes across 68 blob files

The repacked pack is written; the 22 originals are dropped from the *catalog* and keep their bytes
forever. On disk the repository went from 7.8 MB to **15 MB**, against 8.4 MB for the bare it
replaces. One GC run nearly doubled the footprint.

`BlobStore` has no delete (there is no `delete` method on it at all —
`BlobStore.java:29-280`), and neither does the platform. So the platform's options are: never GC and
accumulate one pack triple per push forever, or teach `BlobStore` to delete. There is no third
option, and it must be decided before the first repository moves, not after.

### 1.8 Per-repository config has no home under DFS

`DfsRepository.getConfig()` returns a `DfsConfig`, whose `load()` and `save()` are no-ops — an
in-memory `StoredConfig` with nothing behind it.

`ProtectedRefHook` reads the bare's own config to decide protection per repository:

    services/…/githost/ProtectedRefHook.java:166
      return repo.getConfig().getBoolean("qits", "protectDefaultBranch", protectByDefault);

Under DFS that call always returns the platform default. The per-repository override — which
`qits-artifacts/CLAUDE.md` describes as "a deployment exempts one repo by writing one line into a
file that travels with the volume", and which `GitHostTest` uses as its whole mechanism for turning
protection on — **ceases to exist**. It needs a row, and `GitHostTest` needs a different lever.

`protectedRef(repo)` at `:181-188` reads `repo.getFullBranch()`, i.e. `HEAD`. That one is fine: under
reftable, `HEAD` is a symbolic ref in the ref database and survives (`git ls-remote` returned it in
the spike).

---

## 2. The couplings, priced

Three services touch the volume through the filesystem. Everything else — qits-ci, qits-cd, both
daemons, gateway, events, stt, observability, every lib and integration — is HTTP-only and is
**unaffected**. qits-ci is the reference pattern: it keeps its *own* private bare cache on its own
volume and fills it by fetching over HTTP
(`services/qits-ci/ci/src/main/java/eu/wohlben/qits/ci/control/GitConfigFetcher.java:186-234`).

The decisive constraint: **the git CLI cannot open a `DfsRepository`.** Not "slowly", not "with a
shim" — there is no directory to point `--git-dir` at. So every `git` invocation below has exactly
three possible fates: become an HTTP round trip, become a fetch into a local cache (the qits-ci
pattern), or move in-process into qits-artifacts as JGit.

### 2.1 qits-artifacts — the target, not a cost

    service/…/githost/GitHostRoutes.java:97-98    the data-dir config property
    service/…/githost/GitHostRoutes.java:284-291  Path.of(dataDir, repoId, "origin")
                                                  + FileRepositoryBuilder().setGitDir(…).build()
    service/…/githost/ProtectedRefHook.java:166   per-repo config read  (see 1.8)
    service/…/githost/ProtectedRefHook.java:256-260  derives the repoId from the directory path

`open()` is the entire seam. `infoRefs` and `service` above it never learn the difference.

### 2.2 qits-projects — repository lifecycle, ~35 call sites

`domain/…/control/RepositoryService.java` is the bulk. The operations that **cannot be expressed over
the git wire protocol at all**, and therefore need new API on qits-artifacts:

    :211-217   git clone --mirror <upstream> <origin>      repository CREATION
    :515-524   git init --bare + symbolic-ref HEAD         repository CREATION
    :229       git symbolic-ref HEAD refs/heads/main       sets the default branch — no wire verb
    :701-703   git remote add --mirror=fetch               mutates the bare's config — no wire verb
    :1804-1806 deleteRecursively(Path.of(dataDir, repoId)) repository DELETION
    RepositoryDiscoveryService.java:38-48                  lists the whole volume at startup —
                                                           there is no "enumerate repositories" verb

Plus history reads that git has no wire verb for:
`CommitService.java:85, 137, 166, 197` (`git log --name-only`, show, diff) and
`GitSubmoduleParser.java:36` → `GitExecutor.showFile` (`git show <rev>:.gitmodules`).

And two things on the volume that are **not git at all** and must move independently:
`MetadataService.java:62-63` (`<data-dir>/<repoId>/metadata/repository.json`) and the skeleton
scratch directory at `RepositoryService.java:767-820`.

The rest — `for-each-ref`, `branch`, `branch -D`, `update-ref`, `symbolic-ref --short`, `ls-remote`
— is straightforwardly expressible over HTTP.

### 2.3 qits-workspaces — worktrees and ref writes, ~25 call sites

The two that decide the shape of the whole migration:

    ReleaseIntegrator.java:335-359   git worktree add --detach <dir> <target>   ON THE BARE
    WorkspaceService.java:1843-1877  git worktree prune / add / merge / remove  ON THE BARE

A linked worktree shares the bare's ref store and object store. That is exactly what makes today's
release fast — merge, bump, commit and tag all land in the served repository with no transfer at all
— and it is exactly what a DFS backend removes, because there is no bare to add a worktree to.

Around them, operations that need objects locally regardless of protocol:

    ReleaseIntegrator.java:275-276   git merge-base --is-ancestor
    ReleaseIntegrator.java:304-310   git merge-tree --write-tree  (preflight)
    WorkspaceService.java:713-719    git rev-list --left-right --count  (ahead/behind)
    WorkspaceService.java:753-754    git merge-tree --write-tree  (would-conflict)

And ref writes that are already recorded as defective. This is the part that changes the argument:

- `WorkspaceService.java:198-206` creates a branch with `git branch` on the bare.
- `WorkspaceService.java:1504, 1814, 1944` and `ReleaseIntegrator.java:584` delete refs on the bare.
- `WorkspaceService.java:1827-1884` merges through a worktree and writes the target ref **with no
  push**.
- `RepositoryService.java:814, 1043, 1168, 1174, 1333` write refs with `update-ref` on the bare.
- `RepositoryService.java:767-820` writes the project-skeleton commit straight into the bare.

**Every one of those fires no `post-receive`, so no CI run exists for it.** The platform already
knows: `GitHostAddress.java:1-30` says in so many words that this context *could* write refs directly
and does not for release, because "a filesystem ref update fires no `post-receive`, so nothing
downstream learns". The release flow's own stated goal — receive-pack is the sole writer of `main` —
is a partial statement of the property a DFS host would enforce everywhere by construction.

`WorkspaceMetadataStore.java:73-78` writes `<data-dir>/<repoId>/metadata/workspace_<id>.json`: again
not git, again on the same volume, again needing its own home.

### 2.4 The bootstrap, and the tests

`qits-local-up.sh:446-451` seeds each platform repository with a throwaway `alpine/git` container:
`git init -q --bare -b main /repos/qits-<name>/origin`. A fourth writer, and pure creation. The
mounts are at `qits-local-up.sh:372, 376, 387` (cd run-args for artifacts, projects, workspaces) and
`docker-compose.qits.yml:22-25, 83-84`. Each of the three images also bakes `/data/repositories`
(`services/qits-artifacts/docker/Dockerfile:188,197` and the equivalents in projects and workspaces).

The test harnesses encode the same layout and will move with it: `GitHostFixture.java:49-77`,
`PackagedProcessIT.java:81,504,521`, `TestOrigin.java:55`, `ReleaseControllerTest.java:60-61`, and
roughly a dozen more.

### 2.5 Pricing the release flow's rewrite

The worktree shortcut has to become clone-or-fetch plus push. The measured price of that is small:
cloning the platform's largest repository from the live git host over HTTP takes **0.09 s**. Even a
full clone per release adds under a tenth of a second to a flow the handoff records as taking 60
seconds from release call to last event.

So the cost of losing the worktree is **not** performance. It is that `ReleaseIntegrator`'s careful
safety property — "steps 2 to 6 move no ref anywhere", built on a *detached* worktree
(`ReleaseIntegrator.java:207-208`) — has to be re-established in a different medium, and that
`merge-tree`, `merge-base` and `rev-list --count` need somewhere to run. Two honest options:

- **A local cache in qits-workspaces**, exactly qits-ci's pattern: a private bare per repository on
  `qits-workspaces-data`, filled by fetch over HTTP, where every existing `git` command runs
  unchanged. Smallest diff by a wide margin; keeps the git CLI; costs a second copy of 21 MB.
- **In-process JGit inside qits-artifacts**, exposing merge/preflight/branch operations as API. Truly
  one copy of the bytes, and it is the only shape that ends the "two writers" problem completely —
  but it moves merge semantics into the artifacts service, which today "owns no tables at all" and
  deliberately shares nothing with the blob store.

---

## 3. The verdict

**PLAUSIBLE-WITH-PRECONDITIONS.**

The git host itself is not merely plausible, it is **demonstrated**: a content-addressed
`DfsRepository` served clone, push, atomic tag-plus-branch release push and garbage collection of the
platform's largest real history, through an unmodified transcription of `GitHostRoutes`, in one
session. The abstraction is small (six methods plus a `{}` subclass), it is in the pinned JGit jar,
performance is sub-second and within 2× of the filesystem, and the ref backend that costs *less* code
is also the one that preserves `--atomic`.

Three preconditions, and none of them is inside the git host:

1. **`BlobStore` must learn to delete, or GC must be renounced in writing.** Measured: one
   `DfsGarbageCollector` run took a repository from 7.8 MB to 15 MB. Without deletes, the unified
   store grows monotonically at three blobs per push and GC makes it worse, not better. This is the
   one precondition with a hard number attached and it must be settled first.
2. **qits-projects and qits-workspaces must stop touching the filesystem** — roughly 60 call sites
   across two services, including six operations (create, delete, enumerate, set-HEAD, config
   mutation, worktree) that have no git wire verb and therefore need new API. This is larger than the
   git host change by an order of magnitude and it is the real project.
3. **Per-repository state needs a home**: `[qits] protectDefaultBranch`, and the two JSON sidecar
   trees (`metadata/repository.json`, `workspaces/workspace_*.json`) that live on the volume and have
   nothing to do with git.

**Is it a good trade?** On storage-engine grounds alone, no — git is 21 MB against 5.3 GiB of blobs,
so unification buys 0.4% of the platform's bytes and costs two services' worth of rewriting. The
argument that makes it worth doing is a different one, and it is stronger:

> The couplings this migration must remove are **already recorded as defects**. Filesystem ref writes
> fire no `post-receive`, so a dozen branch creations, deletions, merges and skeleton commits happen
> today with no CI run and no event. `GitHostAddress.java` says so explicitly. The release flow
> already declared the goal — receive-pack is the sole writer of `main`. A DFS-backed host makes
> receive-pack the sole writer of **everything**, by construction, because there is no other door.

So the recommendation is to treat this as **an integrity change that happens to unify storage**,
sequenced so the payoff arrives before the risk. Precondition 2 is worth doing on its own merits,
independent of storage; it can be done first, against the filesystem-backed host, and verified by
watching CI runs appear where none appear today. Only when it is done does the storage swap become a
small change with a config flag.

Doing it in the other order — DFS first, couplings after — means a flag day across three services
with the platform's own origins on the line. That is the one sequence to refuse.

---

## 4. The decisions ⚖

**⚖1 — reftable, or ref rows in H2?**
The measurement in 1.5 is one-sided: `DfsReftableDatabase` advertises `atomic`, preserves
all-or-nothing refusal, brings reflogs, and needs **no new storage primitive** — refs become blobs in
the same pack store. `DfsRefDatabase` needs a table, a compare-and-swap and two more methods, and
**breaks `git push --atomic`**, which the shipped release flow passes.
The price of reftable is that refs stop being queryable: no `SELECT` will ever answer "what is
`main` in repository X" — you go through JGit. Today nothing does that in SQL, so the price is
currently zero and would be paid by a future feature.
*Recommendation: reftable.* It is smaller, and it is the only one that keeps the release flow.

**⚖2 — does `BlobStore` learn to delete?**
Section 1.7 is the whole argument. Three sub-options: (a) add a delete confined to git pack blobs
and run `DfsGarbageCollector` on a schedule; (b) never GC and accept one pack triple per push
forever — at today's rate that is roughly 75 blobs per repository per year, which is genuinely fine
at this scale; (c) GC by rewriting the repository into a fresh repository id and abandoning the old
blobs, which is (b) wearing a hat.
*Recommendation: (b) now, (a) later, and write (b) down.* The measured growth rate does not justify
introducing deletes into a store whose immutability is load-bearing for OCI and npm. But "we do not
GC git" must be a recorded decision with a number beside it, not an omission — because the one thing
that must never happen is someone running `DfsGarbageCollector` to save space and doubling the
footprint.

**⚖3 — where does the merge machinery run once the worktree is gone?**
A local mirror cache in qits-workspaces (qits-ci's proven pattern, smallest diff, keeps the git CLI,
costs a second 21 MB copy) versus in-process JGit inside qits-artifacts (one copy of the bytes,
ends the two-writer problem completely, but puts merge semantics into a service that deliberately
owns no domain).
*Recommendation: the cache.* It is the pattern the platform already runs, it keeps
`ReleaseIntegrator`'s logic intact rather than rewriting merge in JGit, and it can be built and
proven **before** any storage change. It also leaves the qits-artifacts option open.

**⚖4 — does the file-backed backend stay?**
Keeping both backends behind one config property makes the rollout reversible and makes
`GitHostTest` able to prove both. It also means the file-backed code path never gets deleted.
*Recommendation: keep both through the rollout and for one full release cycle after it.* At 21 MB
the duplicate is free, and the git host serving the push that redeploys the git host is precisely the
place where an irreversible cutover is a bad idea (`ProtectedRefHook`'s "can this service still
receive its own redeploy" lesson, `qits-artifacts/CLAUDE.md`).

**⚖5 — which Flyway lineage owns the pack catalog?**
`qits-artifacts/CLAUDE.md` states flatly: *"The git host owns no tables at all."* A pack catalog
breaks that. Either put `V4__git_pack_catalog.sql` into the existing `artifacts` lineage — one
datasource, one migration path, and the invariant is amended in writing — or give the git host its
own named datasource and lineage, which is a second H2 file and a second Flyway config.
*Recommendation: the existing lineage, with the CLAUDE.md sentence rewritten in the same change.*
A stale invariant is worse than an amended one.

---

## 5. If it goes ahead: the implementation plan

### 5.1 The module boundary

The new storage logic is **its own Maven module** inside `services/qits-artifacts`, not woven into
`artifacts/` or `service/`. The reactor today is two modules
(`services/qits-artifacts/pom.xml:43-46`), with GAVs namespaced as `qits-artifacts-artifacts` and
`qits-artifacts-service`:

    qits-artifacts (pom)
    ├── artifacts     eu.wohlben.qits:qits-artifacts-artifacts    blob store + H2 + Flyway
    ├── git-storage   eu.wohlben.qits:qits-artifacts-git-storage  ← NEW, listed before service
    └── service       eu.wohlben.qits:qits-artifacts-service      routes, wiring, the deployable

`git-storage` contains, and contains only:

- `QitsDfsRepository extends DfsRepository`, `QitsDfsObjDatabase extends DfsObjDatabase`, the
  `DfsReftableDatabase` subclass, and a builder.
- **Two ports it declares itself**: a `PackBlobStore` (stage a readable-writable blob, promote it to
  a content address, locate an existing one) and a `PackCatalog` (list, commit, roll back pack
  descriptions for a repository id).
- Its own tests, with in-memory implementations of both ports, running the full clone / push /
  atomic-tag / GC suite the spike already proved. **These tests need no database, no docker and no
  Quarkus** — which keeps the repo's "a clone of this repo alone builds and tests green" rule intact.

Its only compile dependency is `org.eclipse.jgit`. It must **not** depend on
`qits-artifacts-artifacts`: that would be a dependency on another context, which
`qits-artifacts/CLAUDE.md` forbids under "Adding a dependency on another context — Don't."

**Name the awkwardness rather than hide it.** Because `git-storage` may not depend on `artifacts`,
and `artifacts` must not depend on `git-storage`, the two adapters can only live in `service` — the
one module that already depends on both:

- `service/…/githost/storage/BlobStorePackBlobStore` implements `PackBlobStore` over
  `artifacts/control/BlobStore`.
- `service/…/githost/storage/CatalogRepository` implements `PackCatalog` over a Panache entity.

The Flyway migration is the second seam that cannot sit in the new module: the lineage lives in
`artifacts/src/main/resources/db/artifacts/migration/`, so `V4__git_pack_catalog.sql` goes there and
nowhere else (see ⚖5). The new module therefore owns the *engine* and its contract; it owns neither
its bytes nor its rows. That is the boundary, stated deliberately.

The consumption seam in the existing code is one method:
`GitHostRoutes.open(String repoId)` at `services/qits-artifacts/service/src/main/java/eu/wohlben/qits/githost/GitHostRoutes.java:280-302`.
It becomes an injected `GitRepositoryProvider` port with two implementations — the existing
`FileRepositoryBuilder` one and the DFS one — selected by config, following the `Instance<T>` pattern
`RepositoryNameResolver` already sets at `:116`. Nothing above `open()` changes: `infoRefs` at
`:178-221` and `service` at `:224-268` take a `Repository` and are already backend-agnostic.

### 5.2 Native image — the gate that a green `mvn verify` will not catch

`service/` compiles to a GraalVM native image, and `qits-artifacts/CLAUDE.md` lists four JGit-shaped
regressions that were green in the JVM suite and dead in the binary. DFS adds more surface, minimum:

- `DfsBlockCache` is a large static cache and is the direct analogue of
  `jgit.internal.storage.file.WindowCache`, which is **already** in the
  `--initialize-at-run-time` list
  (`services/qits-artifacts/service/src/main/resources/application.properties:145`). Expect DFS to
  need the same.
- The reftable classes and `DfsConfig`'s enum reads may need entries in `githost/JGitReflection` —
  the class whose absence makes *every* git route 404 silently.

`PackagedProcessIT`, not `mvn verify`, is the gate. Its existing `git clone` / `git push` cases must
run against a DFS-backed repository before anyone calls this done.

### 5.3 Workstreams

Letters continue after AS. AT is independent of everything else and is worth doing whatever the
verdict on storage; AU is the precondition with the number attached.

- **AT — de-filesystem qits-workspaces and qits-projects, against the *existing* file-backed host.**
  Introduce the qits-ci-style local mirror cache (⚖3); convert every ref write to a push, every ref
  read to `ls-remote`, and every worktree flow to cache-plus-push. New API on qits-artifacts for the
  six verbs git has none for: create, delete, enumerate, set-HEAD, config get/set, and blob-at-path
  read. Move the two JSON sidecar trees off the volume. **Success is observable and does not need any
  storage change: CI runs and events appear for branch creations, merges and skeleton commits that
  produce none today.** This is the largest workstream and the one that carries the payoff.
- **AU — decide and record the GC posture (⚖2), and add `BlobStore` deletes if that is the answer.**
  Must land before any repository moves. Small, and blocking.
- **AV — the `git-storage` module.** The reactor entry, the DFS implementation, the two declared
  ports, and the offline test suite. Bounded by section 5.1; the spike is the proof it fits.
- **AW — the wiring and the catalog.** The two adapters in `service`, `V4__git_pack_catalog.sql`, the
  `GitRepositoryProvider` seam at `GitHostRoutes:280`, the per-repository protection row that
  replaces the config read at `ProtectedRefHook:166`, and the `GitHostTest` lever that goes with it.
- **AX — native image and the test matrix.** `JGitReflection` and `--initialize-at-run-time` entries;
  `GitHostTest` and `PackagedProcessIT` parameterised over both backends. Nothing ships until the
  packaged binary clones and pushes from DFS.
- **AY — the migration tool and the rollout.** An importer that reads a bare and pushes it into a DFS
  repository, plus the verifier described below.

AT and AV/AW are independent and can run in parallel. AU gates AY. AX gates everything shipping.

### 5.4 Migration order that never loses a repository

These bares **are** the platform's own git origins. The `qits` project delete blast radius applies:
losing them loses the platform's ability to build itself.

The invariant, in one line: **no bare is ever deleted, at any point in this plan.** The whole volume
is 21 MB. It stays, read-only, as the rollback.

1. Ship both backends with DFS **off** (⚖4). Nothing changes behaviour; the code is in the binary and
   the native IT proves it works.
2. Import a throwaway repository. Verify: `git ls-remote` matches the source ref-for-ref, a fresh
   clone's `git fsck` is clean, and `git rev-parse HEAD` matches.
3. Import `qits-stt` — a real repository with a real history that nothing else depends on. Run one
   full release through it: workspace, integrate, release, tag, `SCMRelease`, release pipeline,
   `SoftwareRelease`. Confirm the `--atomic` tag-plus-main push lands.
4. Import the remaining repositories one at a time, verifying each with the same three checks before
   moving on.
5. **`qits-artifacts` itself last.** It is the git host that serves the push that redeploys the git
   host; if its own repository is unreachable the platform cannot ship the fix.
6. Leave the file-backed bares in place for at least one full release cycle after the last import.

**Rollback** at any step is a config flip plus a redeploy: the file-backed bare is still there, still
current up to the moment of import, and the DFS copy is additive. The only work lost is pushes that
landed on DFS after the import — recoverable by pushing from any clone, since every repository has
clones in workspace containers and in qits-ci's cache.

### 5.5 What this costs, stated plainly

- **Latency**: cold clone roughly 2× the filesystem, warm clone identical, both under a second at
  this platform's sizes. Release gains under 0.1 s from cloning instead of using a worktree.
- **Storage**: three blobs per push (pack, index, reftable) with no deletes. Roughly 75 blobs per
  active repository per year at the current rate. Against 5.3 GiB of existing blobs, immaterial.
- **H2**: ~3 catalog rows per push. Against a 746 MB database that is 85% npm packument CLOBs,
  immaterial.
- **Heap**: `DfsBlockCache`, 32 MiB by default, in a process that also streams OCI layers under a
  1088 MB body ceiling. Must be set explicitly.
- **GC**: forbidden by default (⚖2), because running it doubles the footprint.
- **Code**: one new module of maybe 600 lines with its own offline suite; a one-method seam in
  `GitHostRoutes`; and — the real number — roughly 60 call sites across qits-projects and
  qits-workspaces, which is workstream AT and which the platform arguably wants regardless.

---

## 6. Out of scope, named so it stays out

- **Moving the npm packument cache out of H2.** It is 85% of a 746 MB database and it is the actual
  storage problem on this platform. It has nothing to do with git and it should not ride along.
- **Sharding, replication or multi-node anything.** DFS was designed for it; this platform is one
  node and the plan assumes it stays one node. Nothing here forecloses it.
- **Retention and tag GC.** Already parked in `handoff.md`; ⚖2 decides only the git *pack* posture.
- **The `qits-ci` private cache.** It is already HTTP-only and correct. It is the pattern to copy,
  not a thing to change.
- **Deleting the file-backed bares.** Explicitly never, within this plan.
