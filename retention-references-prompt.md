# Prompt: close the registry-retention vs. released-references gap

(Stored for the next agent/server; written 2026-09-06 at the end of the buildkit epic. Hand this
file's body to an agent as its task.)

The qits platform's artifact retention (storage-lifecycle campaign, shipped 2026-09-05) evicts by
recency, but released trees reference **exact versions**: Dockerfile pins
(`ARG X=qits/workspace-base:<calver>`, rewritten only when the *consumer* releases), npm lockfile
`resolved` tarball URLs, and released poms' dependency versions. Measured failures on
2026-09-05/06: six services' QA folds died on `npm 404 @qits/ui-components@<evicted>`, and two
released versions (qits-workspace-daemon `2026.906.2716`, qits-projects-daemon) could not publish
their own artifacts because `qits/workspace-base:2026.904.223651` was evicted — i.e. any rebuild
of a non-tip released tree (QA fold, release-run re-fire, bootstrap replay, rollback rebuild)
fails.

Task: make "referenced by a released tree" a keep-reason in the eviction policy, the way
qits-containers' `ImageGc` keeps `IN_USE`/`LIVE_ROW`/pinned rather than "newest". Concretely:

1. Build the reference closure per store: for every repository's released tags still on `main`'s
   history (or a bounded window of recent releases), collect (a) `ARG`/`FROM` docker pins from
   committed Dockerfiles, (b) `@qits/*` versions from committed `package-lock.json` `resolved`
   entries, (c) released-pom dependency versions for platform jars. qits-maintenance's pin
   inventory already parses (a); reuse it rather than writing a second parser.
2. Feed that set into the eviction decision in the hosted registries (qits-artifacts /
   `qits-registries-javalib`, and qits-mirror's `qits.mirror.eviction.window.*` if hosted `@qits`
   content is also under it). A referenced version is kept regardless of age; unreferenced ones
   keep the existing recency window.
3. Fail open: if the reference closure cannot be computed, evict nothing that pass — the same
   doctrine as "a listing that protects throws rather than degrading".
4. Prove it: pick a version older than the retention window that a released lockfile pins, run a
   GC pass, and show it survives; and show a fold of that consumer goes green.

Context to read first: `qits-buildkit-plan.md` (wrapper root, "The wave, as it landed") for the
incident detail; `storage-lifecycle-plan.md` for the policy as shipped; qits-containers' `ImageGc`
for the keep-reason pattern. Do not "fix" consumers by bumping pins — the trains own the pins; the
policy is what is wrong.
