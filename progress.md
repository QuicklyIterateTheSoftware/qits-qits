# Progress: maven repository type (unblocking qits-eventstream)

Started 2026-08-02. The thread this tracks: `libs/qits-eventstream` was extracted into a
standalone maven repo but never published — qits-artifacts has no maven repository type.
Previous agents worked around it by vendoring eventstream as a git submodule + reactor module
in consumers; that fragility took qits-ci down and left the local env unsalvageable.
Program: tear down env → implement the maven type → publish eventstream → unwrap the
workarounds → clean re-bootstrap.

## Done

- **Commit archaeology — the workaround chain to unwrap:**
  - qits-ci `3ff84c0` (Jul 31): eventstream vendored as submodule at `eventstream/`, built
    in-reactor, pinned `${project.version}` (services/qits-ci/pom.xml:135); hand-rolled
    `git submodule update --init eventstream` in `.config/qits/ci-post-receive.yml:46` and
    `ci-event-release.yml:84`; docker/Dockerfile comments make the init mandatory. Break
    mechanism: the daemon clones `--depth 50` without recursion → empty `eventstream/` →
    the maven reactor refuses the build.
  - qits-workspaces `3728fcd` (Aug 1): same pattern (services/qits-workspaces/pom.xml:126).
  - qits-workspaces, **uncommitted**: `MavenVersionBumper.java` locally modified to skip
    gitlinked submodules during version bumps (+48/−1, never committed — mid-fix when things
    fell apart). Also an untracked `.claude/` dir there.
  - Note: `${project.version}` pins resolve only via reactor trickery; the lib itself is
    `1.0.0-SNAPSHOT`. A published world needs a literal pin.
- **Local env torn down completely** (subagent): 9 cd-managed containers removed, 22 volumes
  removed (all platform state — git origins, H2 DBs, OCI blob store, mirror cache — plus a
  workspace volume, 5 probe volumes, 6 anonymous orphans), `qits-net` removed. Images kept
  as build cache. Ports 8080/8081 free; host ready for a clean `qits-local-up.sh`.
- **`maven-repository-plan.md` written and SETTLED (2026-08-02)** — 539 lines, house style.
  User rulings on the four ⚖:
  - ⚖1 **Full timestamped SNAPSHOT support now** (overruled the release-only recommendation).
    Server stays a dumb path store; snapshot metadata derived, not rewritten.
  - ⚖2 Mirror npm naming: type `MAVEN_PACKAGES`, slug `maven-packages`, URL
    `/artifacts/maven/maven/<group/path>/...`, seeded row `maven`; proxy adds `MAVEN_PROXY`
    + seeded `central`.
  - ⚖3 **Maven Central pull-through IN scope** (overruled the park recommendation), sequenced
    strictly after the blocker fix (workstream CQ — nothing in CQ delays CM).
  - ⚖4 Clone-alone weakening accepted + documented (AGENTS.md amendment is part of the unwrap).

## Workstream map (from the settled plan)

CH substrate (type, V8, entity, seeder, census, explorer switches, store summary
`mavenPublishedBytes`+`mavenProxyBytes`, GC claim) → CI wire for releases (GET/HEAD/PUT,
derived metadata + checksums, release immutability) → CJ SNAPSHOTs → CK packaged/native
proof → **CM publish qits-eventstream 1.0.0 + resolve-back + a real 1.0.1-SNAPSHOT deploy
(victory condition)** → CN ∥ CO unwrap qits-ci / qits-workspaces (incl. MavenVersionBumper
revert) → CQ Central pull-through → CR proxy packaged proof + adoption → CP browse/SPA
(anytime after CI).

## Where we are right now

- **CH–CK LANDED (2026-08-02)** in services/qits-artifacts, four commits, head `16f40fa`
  (committed in-submodule per house convention, nothing pushed):
  - CH `6447400` — `MAVEN_PACKAGES` type, V8 migration + `maven_artifact` table, entity,
    seeder row `maven`, census, store summary (`mavenPublishedBytes` live; `mavenProxyBytes`
    as commented `0L` until CQ's V9), mirror-shaped "nothing dies" GC strategy.
  - CI `2d715b3` — the wire: GET/HEAD/PUT at `/artifacts/maven/maven/<path>`, DELETE 405,
    derived metadata + checksums, `requireClaimMatches` verification, release immutability,
    streaming PUT via `OciRequestBody` (widened to public), 128M cap.
  - CJ `c511979` — SNAPSHOTs: timestamped unique+immutable, literal `-SNAPSHOT` mutable,
    version-level metadata with derived `<snapshotVersions>`, 404 for non-unique-only dirs.
  - CK `16f40fa` — packaged proof: `/maven` in quinoa ignored-prefixes, PackagedProcessIT
    release+snapshot cases. "Zero new native config" verified by diff.
  - Verify: `./mvnw verify` 421 tests green; `./mvnw verify -Dnative` 23 ITs green
    (1 opt-in skip by design). README/AGENTS.md brought current.
- Plan deviation recorded: `mavenProxyBytes` is a commented `0L` (can't read the census
  without CQ's MAVEN_PROXY constant) — structurally honest, CQ adds one line.
- **Re-bootstrap restarted from zero (2026-08-02, ~13:30 local).** The detached/manual attempt was
  discarded with every qits container, volume and network. The acceptance gate is now one clean
  invocation of `qits-local-up.sh`; no operator-built artifact is an input.
- **CM + CN + CO implementation landed locally:** eventstream `7929a40` is version `1.0.0`;
  qits-ci `241556b` and qits-workspaces `12951f4` resolve that literal version from
  `http://localhost:8081/artifacts/maven/maven`. Both eventstream gitlinks/reactor modules and all
  pipeline submodule initialisation were removed. The abandoned uncommitted
  `MavenVersionBumper` gitlink-skipping change was restored.
- **Bootstrap dependency stages are now script-owned and observed from empty volumes:** seed
  artifacts starts before CI is built; the script deploys qits-eventstream with Maven, then builds
  and publishes `@qits/ui-components` at both versions required by existing locks (`0.0.4` and
  `2026.801.85149`). Seed images receive deterministic placeholder SPAs and are replaced by their
  normal full pipeline deployments. The observed qits-ci native reactor had four local modules —
  no `eventstream/` — and resolved the published jar successfully.
- **Clean unattended run PASSED (2026-08-02 ~15:10 local): nine of nine applications ACTIVE.**
  It began with no qits containers, volumes or network and ended normally from the documented single
  `docker run … qits-local-up.sh` invocation. The script built seed images, deployed eventstream
  through Maven, published the exact historical npm tarballs required by committed lock integrity
  (`@qits/ui-components@0.0.4`, `@qits/angular@0.0.1`) plus the current UI release, then pushed every
  service through qits-ci/qits-cd. Final ACTIVE heads include workspaces `12951f4`, ci `31f3d68`, cd
  `2146f91`, and artifacts `16f40fa`.
- Clean-gate defects fixed en route: deterministic placeholder seed SPAs; compose leaves the early
  artifacts process alone; direct npmjs fetch for bootstrap-only source builds; CI failure detection
  prevents hour-long phantom deployment waits; qits-ci V5 and qits-cd V3 remove H2 2.4.240's
  session-bound enum checks (the same defect family already observed in qits-workspaces).

## Open / watch-items

- CM requires a running qits-artifacts → re-bootstrap slots between CK and CM.
- Known recorded finding (not solved by the plan): `/artifacts/api` writes are unguarded
  live (gateway PublicPaths allowlist + blank token) — the maven PUT surface inherits this.
- When unwrapping: also revert the uncommitted `MavenVersionBumper.java` change and decide
  the untracked `.claude/` dir in qits-workspaces; pin consumers at the literal `1.0.0`.
