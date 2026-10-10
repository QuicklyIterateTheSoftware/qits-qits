# Publish only what changed

USER RULE 2026-10-09: "if the protocol has no changes, it should not publish — like the golden
masters." A release whose artifact content did not change publishes no new version of that
artifact, so no consumer is bumped for nothing.

Epic: qits-112. Branches: `external/publish-if-changed` on the platform git host.

## Why

Since 2026-10-09 ~12:00 qits-runner-javalib and qits-ci-runner-daemon bumped each other without
end. runner-javalib pins `qits-ci-runner-protocol` in TEST scope; ci-runner-daemon depends on
`qits-runner-protocol` and `qits-runner-toolkit`. Every release published new versions, so each side
bumped the other and every consumer, and their release requests lost QA again and again.

Evidence (store, `GET /artifacts/content-hashes/maven/<g:a>/-/<v>`):

- `qits-runner-protocol`: the same hash `v1:sha256:ef55840d…` on all 12 versions 144219…184810.
  The hash already ignores a pure version stamp and the test-scope pin.
- `qits-runner-toolkit`: a new hash on every version. The only difference between two versions is
  the pom's link to `qits-runner-protocol` at the new version (protocol was always published, so the
  link points at the new version, and the SBOM line for the linked sibling carries that version).

So the hash was right; the policy (`publish: always`) was the problem.

## What exists already (found, not built)

| Target design | State |
|---|---|
| CLI content digest per ecosystem | Exists: `ContentHash` (`v1:sha256:`) in qits-platform-access-cli `publish/`. Maven: jar entries by name and bytes (no timestamps, no order), minus `META-INF/MANIFEST.MF` and `META-INF/maven/**`, plus the canonical SBOM (dependency graph, root's own version dropped). npm: tarball files, `package.json` without `version`, plus the SBOM. |
| Test/provided scope not counted | Test scope: yes (makeBom default leaves it out; the pom is not hashed). Provided: in the SBOM, so it counts. |
| qits-artifacts stores the digest per version, answers "newest" | Exists: `X-Artifacts-Content-Hash` on the pom/tarball PUT; `GET /artifacts/content-hashes/<type>/<name>/-/<version\|newest>`. |
| Publish only when the digest differs, else `unchanged since <v>` | Exists: `Decision` (`--if-changed`). |
| qits-ci records "unchanged since <v>", announces nothing | Exists: `ReleaseJoin` + `CiArtifactPresence` (qits-620). |
| qits-maintenance bumps only on real publications | Exists: maven/npm `mt_latest` moves only on `SoftwareRelease` (`bus/SoftwareReleaseListener`) and the daily registry scan. `SCMRelease` moves only GITLINK latest (`bus/ScmEventListener.onGitlinkReleased`). No change needed. |

## What changes

1. **Stop the loop now** — qits-runner-javalib `.config/qits/release.yml`: both jars
   `publish: if-changed`. Works with the CLI and qits-ci that run today. The next test-pin bump
   publishes nothing: protocol is unchanged, so toolkit links protocol at its newest version, which
   is the version its stored hash already names.
2. **CLI `--dry-run`** on `qits artifacts publish maven`: decides as `--if-changed`, uploads nothing,
   prints `changed`, `unchanged since <v>` or `published <v>`.
3. **Link groups publish together** (qits-ci composer): entries joined by `link:` share one
   `publish:` (parser refuses a mix). An if-changed group is asked with `--dry-run` first; if any
   member changed, every member publishes unconditionally (a linked sibling then sits at the release
   version), else nothing uploads. This keeps a shared consumer property (`qits.runner.version`)
   pointing at a version that exists for every member.
4. **`if-changed` is the default** for maven and npm in `release.yml`. It is a property of the
   artifact type (`CiArtifact.Type.releaseDefault()`), not a switch. `publish: always` opts out.
   Trigger files keep `always` as their default, so a composed document means what it says.
5. **Ecosystem registry in the CLI**: `ContentHash.type()` + `ContentHash.ALL`, one class per
   ecosystem (maven, npm). `Decision`, `ContentHashes` and link groups know no ecosystem. Test:
   unique type ids.

### Audit of "always" users before the default flip

Every maven/npm entry in the estate declares `sbom:` (needed by if-changed). The jars that pin an
image or binary of the same release stamp their own version into a resource
(`ci-runner-protocol`, `ci-daemon-protocol`, `projects-daemon-protocol`,
`workspace-daemon-protocol`, `workspace-editor-image`, `platform-access-cli-binary`), so their
content changes every release and they keep publishing every release. Nothing found that needs
"always" to stay correct.

## Deviations from the target design, and why

- **Platform dependencies are hashed by version, not by their digest.** The SBOM line keeps the
  dependency's version. With if-changed everywhere, a content-identical upstream no longer publishes
  a new version, so there is no bump to hash. Hashing by digest would only matter during the
  switch-over, and it needs a store read per dependency. Revisit if a chain still moves.
- **The pom is not hashed** (owner decision in `MavenContentHash`): what it says is either in the
  SBOM or not content. Effect is the same as "flattened pom with version blanked".
- **Registry is a list, not ServiceLoader.** The CLI is a Quarkus native image, which by default
  registers no ServiceLoader providers; a silent empty registry would break every publish.
- **`--dry-run` is maven only.** `link:` exists only for maven.
- **qits-artifacts is not generic yet.** The read route admits `maven|npm` only
  (`service/…/contenthash/ContentHashPaths.java:31`) and picks versions and order with
  `"maven".equals(ecosystem) ? … : …` (`ContentHashRoutes.java:84,170,178`). It works for the two
  ecosystems the default covers. Follow-up: one `EcosystemVersions` class per ecosystem (list
  versions, version order), found by id, with a unique-id test — the same shape as the CLI.

## Release order

1. qits-runner-javalib `external/publish-if-changed` — stops the loop. Independent of everything.
2. qits-platform-access-cli `external/publish-if-changed` (`--dry-run`, registry).
3. Wait until qits-maintenance has bumped qits-ci-service's CLI pin
   (`eu.wohlben.qits:qits-platform-access-cli-binary`) to that release.
4. qits-ci-service `external/publish-if-changed` (link groups, default flip). Releasing it before
   step 3 makes every link group (registries, coding-agents, runner) call `--dry-run` on a CLI that
   refuses it, and their release steps go red.

## Consequence: release version ≠ artifact version

A repository release `V` no longer means artifact `X@V` exists. Audit of every reader (read from
code, nothing run):

- **Real break — qits-maintenance adoption.** `adoption/ReleaseCoordinates.java:54` keeps only the
  artifacts whose version equals the release version, so an unchanged library drops out;
  `AdoptionEvaluator.java:189,196` then requires "carries V" from what V published (often only the
  image), while `DownstreamResolver.java:249` still lists consumers of the library at any version.
  Such a consumer reads PENDING for ever. Same one hop down at `AdoptionEvaluator.java:225`.
  Fix (not done yet): treat an unchanged artifact as published at its `unchanged since` version U
  and require "at least U". U has to come from qits-ci's per-artifact decision
  (`CiReleaseArtifactsSurface`) or from the store's newest version at V's time.
- **Holds while pin jars stamp their version** — `control/ArtifactGraph.java:428-442`
  (`CarriedArtifacts`, `CarriedImages`, `CarriedDaemons`): a pin on maven X at U keeps the image the
  same repository released at U. Correct as long as the pin jars change every release, which they do
  (they stamp `${project.version}`). A pin jar that stops stamping must declare `publish: always`.
- **Already handled**: qits-projects `ReleaseArtifacts.java:178-185` lists only published rows at V
  (cosmetic: it hides `unchanged since U` rows that `ReleaseDecisions.java:35` already carries; the
  panel could show them). Both frontends use the version the backend sends. Maintenance
  `SoftwareReleaseListener`, `SbomIngestService`, `SbomCheckService`, `ReleaseLedger` (pins read at
  the tag) and gitlink handling. qits-deployments acts on docker only
  (`PdSoftwareReleaseSubscriber.java:222,234`). qits-ci `ReleaseJoin.java:516-529,574-703` and the
  SBOM submit/check run only for published if-changed rows.

## Follow-ups

- Fix the adoption break in qits-maintenance (see the audit).
- Show `X — unchanged since U` in the release-request artifacts panel.
- qits-artifacts also refuses other ecosystems when it records a hash
  (`artifacts/…/control/JpaContentHashLedger.java:60-64`); the table key is already generic
  (`ContentHashId.java:16`).

- Hash platform dependencies by digest (see deviations).
- A generic digest store in qits-artifacts for every type (OCI, cargo, pypi, go); see deviations.
- qits-runner-javalib's test pin on `qits-ci-runner-protocol` is still bumped by maintenance, which
  its own pom comment forbids. The release that follows now publishes nothing, so it is harmless;
  a maintenance group that leaves the pin unclaimed would stop the release too.
