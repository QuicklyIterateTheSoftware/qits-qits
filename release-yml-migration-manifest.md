# `.config/qits/release.yml` migration manifest

**Work order.** 46 repositories still commit the hand-written pair
`.config/qits/ci-event-release-request.yml` + `.config/qits/ci-event-release.yml`; 3
(`qits-coding-agents`, `qits-database-oci`, `qits-observability-frontend`) already carry
`release.yml`. Each entry below gives the file to write verbatim, the archetype, whether it
overrides a slot and why, and the trap.

## Rules that apply to every entry

- **Deleting the pair is part of the migration.** While `release.yml` is present at `main`, qits-ci
  skips the two legacy files with a WARN naming both paths. Leave them and the WARN is permanent.
- **`artifacts:` is never defaulted in an archetype.** qits-projects reads it out of the repository
  at the tag, so every publishing repository spells its own block, on ONE flow-style line per entry
  — the extractors in `java-service`, `oci` and `daemon` are a `sed` over one line.
- **The `sbom:` path is where the BUILDING step writes.** The composed postlude PUTs it per declared
  artifact, and it runs inside one single step — so the path has to exist in THAT step's container.
  Never re-add a `curl -X PUT .../artifacts/sboms/...` to a script.
- **THE WHOLE POSTLUDE LANDS ON ONE STEP, AND STEPS SHARE NOTHING.** `CiReleaseComposer.postludeStep`
  appends the entire SBOM postlude to the LAST step that declares `build:` or `docker:`, and a CI
  step has no working directory in common with any other: each is an ephemeral container that does
  its own `git clone` (`CiRunService.runSteps`, `CiDaemonLauncher.buildWorkloadSpec` mounts no
  volume, `Workspace.prepare()` re-clones, and `CiDaemonGateIT` asserts that no state crosses
  steps). So **declaring `sbom:` on an artifact whose document is written by a LATER, non-building
  step emits a submit for a file that does not exist in the postlude's container, and FAILS THE
  RELEASE.** The pattern instead — the one the three daemons now use for their protocol jars —
  is to declare that artifact WITHOUT `sbom:` and submit it inline at the end of the step that
  generates it:

      qits artifacts publish sbom submit \
        --type maven --name "<groupId:artifactId>" \
        --version "$QITS_VERSION" --file <path>

  The `qits` CLI is on PATH in every composed release step, and its submit runs the same policy the
  postlude runs, identical-bytes-is-success included. This is NOT a return to the hand-written
  `curl -X PUT`: same CLI, same policy, merely on the step that holds the file.
- **`-Dit.test` does not live in `release.yml`** — the document's vocabulary is five keys
  (`archetype`, `release-request`, `release`, `artifacts`, `userflows`) and refuses a sixth. The
  fourteen services carrying a story list must also commit `.config/qits/userflow-stories`, one class
  name per line; the archetype turns it into `-Dit.test=<list>`. **The list file and `release.yml`
  land in the same commit**, or those repositories silently run their whole IT catalogue.
- **No step opts out of the gate.** Every step of phase one gates. The quoted slots below carried a
  per-step `gating: false` on their story steps when this manifest was written; ticket 9441bc6e
  removed the flag estate-wide and qits-ci now REFUSES the key at parse time, so the blocks here are
  quoted without it and a slot that re-adds it will not compile.
- **A declared slot replaces the archetype's slot ENTIRELY.** There is no per-step merging.
- **The QA build and the release build must stay byte-identical buildctl invocations.** Where a
  repository overrides one of them, it overrides the other in the same commit.

---

# Batch 1 — libraries (6)

## qits-eventstream-javalib — `maven-library`, no override

```yaml
archetype: maven-library
artifacts:
  - { type: maven, name: "eu.wohlben.qits:qits-eventstream", sbom: target/sbom.json }
```

Single module, so the reactor-root `makeBom` lands on plain `target/sbom.json`. The hand-written QA
step is the archetype's line for line, `user: build` included (zonky's initdb refuses root), and
`.qits-maven-settings.xml` is present so the archetype's unconditional `-s` resolves.

**Trap.** The archetype drops the `curl .../qits-eventstream-$version.pom` replay probe and its
`exit 0`: `qits-publish` has no maven arm, so the deploy is unguarded and a republish is the Maven
registry's answer rather than the recipe's. The SBOM half is strictly better — `makeBom` now runs
even on a run whose deploy was a no-op.

## qits-integrations-quarkus-javalib — `maven-library`, **overrides `release-request:`**

```yaml
archetype: maven-library
artifacts:
  - { type: maven, name: "eu.wohlben.qits:qits-auth-core", sbom: qits-auth-core/target/sbom.json }
  - { type: maven, name: "eu.wohlben.qits:qits-arch-rules", sbom: qits-arch-rules/target/sbom.json }
  - { type: maven, name: "eu.wohlben.qits:qits-db-core", sbom: qits-db-core/target/sbom.json }
  - { type: maven, name: "eu.wohlben.qits:qits-environment-core", sbom: qits-environment-core/target/sbom.json }
  - { type: maven, name: "eu.wohlben.qits:qits-service-mock", sbom: qits-service-mock/target/sbom.json }

# THIS REPOSITORY HAS NO .qits-maven-settings.xml. The archetype's QA step passes
# `-s .qits-maven-settings.xml` unconditionally, and Maven refuses to start on a settings file that
# does not exist — so the gating step would fail before it resolved anything. The release slot is
# NOT overridden: it already guards on the file's presence. Delete this slot the day the settings
# file lands, and the archetype's `user: build` and repository property come with it.
release-request:
  - image: qits/build-images/maven-base:latest
    timeout-seconds: 1800
    script: |
      ./mvnw -B -ntp verify
```

**Why the `sbom:` paths are what they are.** The archetype's release runs `makeBom` at the reactor
root with no `-pl`, so every module writes its own `<module>/target/sbom.json`; here the module
directories and the artifactIds are the same five strings. The hand-written file's per-module
`-pl` loop is therefore not reproduced and does not need to be.

## qits-registries-javalib — `maven-library`, no override

```yaml
archetype: maven-library
artifacts:
  - { type: maven, name: "eu.wohlben.qits:qits-blobstore", sbom: blobstore/target/sbom.json }
  - { type: maven, name: "eu.wohlben.qits:qits-registries-common", sbom: common/target/sbom.json }
  - { type: maven, name: "eu.wohlben.qits:qits-registries-npm", sbom: npm/target/sbom.json }
  - { type: maven, name: "eu.wohlben.qits:qits-registries-maven", sbom: maven/target/sbom.json }
  - { type: maven, name: "eu.wohlben.qits:qits-registries-oci", sbom: oci/target/sbom.json }
```

**The directory and the coordinate differ here and the manifest is the only place both are
written**: `blobstore/` publishes as `qits-blobstore`, `common/` as `qits-registries-common`. The
`sbom:` path takes the DIRECTORY, the `name:` takes the artifactId. Neither may be guessed from the
other, which is exactly what the hand-written file's `directory:artifactId` pairs were for.

`user: build` is the archetype's default, which is what this repository's QA step already declares.

**Trap — a diagnostic is dropped.** The hand-written QA step runs `id` and, on failure, cats every
`*.dumpstream` and `df -h`. Four gating runs on 2026-09-01 were unreadable without it. The archetype
has no such block. If that diagnostic must survive, this repository declares its own
`release-request:` reproducing the archetype's command plus the trap; otherwise accept the loss
knowingly.

## qits-userflows-javalib — `maven-library`, **overrides BOTH slots**

```yaml
archetype: maven-library
artifacts:
  - { type: maven, name: "eu.wohlben.qits:qits-userflows", sbom: qits-userflows/target/sbom.json }

# BOTH SLOTS ARE OVERRIDDEN AND NEITHER IS OPTIONAL. This repository has no `mvnw` wrapper and no
# `.qits-maven-settings.xml` in its tree, and it builds on `userflows-base` rather than `maven-base`
# — the archetype's `./mvnw … -s .qits-maven-settings.xml` would fail on a missing file twice over.
# The day the wrapper and the settings file land, delete both slots and this file is three lines.
release-request:
  - image: qits/build-images/userflows-base:latest
    timeout-seconds: 1800
    script: |
      mvn -B -ntp verify

release:
  - image: qits/build-images/userflows-base:latest
    timeout-seconds: 1800
    script: |
      mvn -B -ntp deploy -DskipTests \
        -DaltDeploymentRepository="qits::default::$QITS_MAVEN_REGISTRY_URL"
      # `-pl qits-userflows` because the jar is the module and the root is a `pom` parent. The
      # composed postlude submits qits-userflows/target/sbom.json for the artifact above.
      mvn -B -ntp -DskipTests -pl qits-userflows \
        org.cyclonedx:cyclonedx-maven-plugin:2.9.1:makeBom \
        -DoutputFormat=json -DoutputName=sbom -DschemaVersion=1.6
```

## qits-integrations-angular-jslib — `npm-library`, no override

```yaml
archetype: npm-library
artifacts:
  - { type: npm, name: "@qits/angular", sbom: sbom.json }
```

One `dist/qits-integrations-angular/package.json`, which is what the archetype finds; the
tag-versus-manifest assertion, the replay/dist-tag policy and the publish-if-absent guard all move
into `qits-publish npm plan` unchanged. `package.json` carries no `build-storybook` script, so the
archetype skips the workbench half and there is **no `docs` entry** here.

**Trap — this ADDS an SBOM.** The hand-written release publishes none. The archetype generates
`sbom.json` with cdxgen either way; declaring `sbom:` is what makes the postlude submit it. Drop
`, sbom: sbom.json` if publishing a first bill of materials for `@qits/angular` is not wanted in
this commit.

## qits-ui-components-jslib — `npm-library`, no override

```yaml
archetype: npm-library
artifacts:
  - { type: npm, name: "@qits/ui-components", sbom: sbom.json }
  - { type: docs, name: "@qits/ui-components" }
```

The repeated name is the point: a tarball and a workbench at two addresses. Only the npm entry
carries `sbom:` — the storybook bundle has no bill of materials. `build-storybook` is present in
`package.json`, so the archetype runs it in both slots exactly as the pair did.

---

# Batch 2 — frontends (14)

**Every one of these is the same one-line file.** They publish nothing: the consuming service carries
them as a Quinoa submodule and builds the bundle into its own image, so there is no `artifacts:`, no
`userflows:` and no `release:` slot — a phase nobody declares steps for gets no trigger document and
therefore no run.

```yaml
archetype: spa-frontend
```

Applies verbatim to: `qits-artifacts-frontend`, `qits-ci-frontend`,
`qits-configuration-platform-frontend`, `qits-deployments-platform-frontend`, `qits-docs-frontend`,
`qits-events-platform-frontend`, `qits-githost-frontend`, `qits-idp-platform-frontend`,
`qits-maintenance-platform-frontend`, `qits-mirror-platform-frontend`,
`qits-orchestrator-platform-frontend`, `qits-projects-frontend`, `qits-system-platform-frontend`,
`qits-workspaces-frontend`.

Measured: strip comments and normalise the repository name and twelve of the fourteen hand-written
QA files are byte-identical to each other and to the recipe. The two that differ, differ by one
line, and that line is the trap below.

**Trap — `qits-projects-frontend` GAINS A LINT GATE.** Its hand-written file has no
`npm run lint`, but `package.json` carries a `lint` script and the tree carries an
`eslint.config.js`, and the recipe calls `npm run --if-present lint`. Migrating turns lint ON for
this repository. Run `npm ci && npm run lint` in a clone before landing; if it is red, fix the lint
or remove the script in the same commit, because the alternative is a release request that cannot
reach a gating verdict.

**Not a trap — `qits-docs-frontend`.** It also omits `npm run lint`, and it has no `lint` script and
no eslint config, so `--if-present` is a no-op and behaviour is identical. Adding the script later is
what turns the check on, with no pipeline edit.

---

# Batch 3 — daemons, OCI, CLIs (8)

## qits-ci-daemon — `daemon`, **overrides BOTH slots**

```yaml
archetype: daemon
artifacts:
  - { type: daemon, name: qits-ci-daemon, sbom: out/sbom.json }
  # THE PIN AND THE PROTOCOL, IN ONE JAR — the same artifact qits-workspace-daemon settled on, for
  # the same reason. `ci-daemon-protocol` was already the wire contract both sides speak; what it
  # gained is `CiDaemonBinary.VERSION`, filtered from `${project.version}` at build time, so the
  # jar's version IS the version of the binary published beside it and cannot drift from it by an
  # edit somebody forgot. qits-ci pins this coordinate in its pom and takes the daemon version from
  # the constant.
  #
  # AND IT CARRIES NO `sbom:`, WHICH IS NOT THE DOCUMENT GOING MISSING. The postlude runs in ONE
  # step — the last one that builds — and a step container shares nothing with the next: the jar's
  # document is written by `makeBom` in the maven step below, whose files the builder step has never
  # seen. So the jar submits its own document, through the same `qits` CLI and the same policy the
  # postlude would have used. An `sbom:` here would make the builder step submit a path that does
  # not exist in it.
  - { type: maven, name: "eu.wohlben.qits:qits-ci-daemon-protocol" }

# THE QA HALF IS THIS REPOSITORY'S, AND THE ARCHETYPE'S HEADER SAYS SO. Two things live here that
# a compile does not: the JVM suite, and a smoke probe that really STARTS A CONTAINER on the built
# binary and asserts it refuses to run with no environment (exit 2). That probe needs a docker
# socket, which is why this step keeps `docker: true` — the archetype's `build: true` gives a
# builder and no socket.
release-request:
  - image: qits/build-images/maven-base:latest
    timeout-seconds: 1800
    script: |
      export QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}"
      ./mvnw -B -ntp -s .qits-maven-settings.xml verify

  - image: qits/build-images/ci-base:latest
    docker: true
    timeout-seconds: 3600
    script: |
      maven_root="${QITS_MAVEN_REGISTRY_URL%/}"
      musl_url=$(sed -n 's/^ARG MUSL_URL=//p' docker/Dockerfile.musl-builder)
      zlib_url=$(sed -n 's/^ARG ZLIB_URL=//p' docker/Dockerfile.musl-builder)
      : "${musl_url:?docker/Dockerfile.musl-builder declares no ARG MUSL_URL}"
      : "${zlib_url:?docker/Dockerfile.musl-builder declares no ARG ZLIB_URL}"
      musl_url="$maven_root${musl_url#*/artifacts/maven/maven}"
      zlib_url="$maven_root${zlib_url#*/artifacts/maven/maven}"
      builder="$QITS_BUILD_REGISTRY/$QITS_IMAGE_REPOSITORY/graalvmce-musl-builder:jdk-25"
      buildctl build --frontend dockerfile.v0 \
        --local context=docker --local dockerfile=docker \
        --opt filename=Dockerfile.musl-builder \
        --opt build-arg:MUSL_URL="$musl_url" \
        --opt build-arg:ZLIB_URL="$zlib_url" \
        --output "type=image,name=$builder,push=true"
      # BYTE-IDENTICAL TO THE RELEASE SLOT'S EXPORT. Change one, change the other.
      buildctl build --frontend dockerfile.v0 \
        --local context=. --local dockerfile=docker \
        --opt target=binary \
        --opt build-arg:BUILDER_IMAGE="$builder" \
        --opt build-arg:QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}" \
        --output type=local,dest=out
      # THE EXPORT STAYS IN out/ AND MUST NOT BE "SIMPLIFIED" TO /tmp/qits-ci-daemon: that path is
      # the RUNNING daemon of this very step's container, and writing it is ETXTBSY.
      probe=$(docker create alpine:3 /qits-ci-daemon)
      docker cp out/qits-ci-daemon "$probe:/qits-ci-daemon"
      docker start -a "$probe" || true
      code=$(docker inspect -f '{{.State.ExitCode}}' "$probe")
      docker rm "$probe" >/dev/null
      [ "$code" = 2 ] || { echo "a daemon run with no environment exited $code, expected 2" >&2; exit 1; }
      echo "qits-ci-daemon built: $(sha256sum out/qits-ci-daemon | cut -d' ' -f1)"

# THE RELEASE HALF IS THIS REPOSITORY'S TOO, FOR ONE REASON THE ARCHETYPE DOES NOT COVER: two
# artifacts of two kinds leave this tree, and `daemon` publishes the binary and nothing else. The
# first step below IS the archetype's, verbatim apart from spelling the one name it would have read
# back out of `artifacts:`; the second is the pin-and-protocol jar, which needs maven and therefore
# a second image. It is deliberately AFTER the binary publish: the jar is what tells qits-ci which
# binary to fetch, so a jar that resolves before its binary is in the store is a pin pointing at
# nothing. The reverse ordering is the safe one — a binary nobody has been told about yet is just
# bytes.
release:
  - image: qits/build-images/ci-base:latest
    build: true
    timeout-seconds: 3600
    script: |
      maven_root="${QITS_MAVEN_REGISTRY_URL%/}"
      musl_url=$(sed -n 's/^ARG MUSL_URL=//p' docker/Dockerfile.musl-builder)
      zlib_url=$(sed -n 's/^ARG ZLIB_URL=//p' docker/Dockerfile.musl-builder)
      : "${musl_url:?docker/Dockerfile.musl-builder declares no ARG MUSL_URL}"
      : "${zlib_url:?docker/Dockerfile.musl-builder declares no ARG ZLIB_URL}"
      musl_url="$maven_root${musl_url#*/artifacts/maven/maven}"
      zlib_url="$maven_root${zlib_url#*/artifacts/maven/maven}"
      builder="$QITS_BUILD_REGISTRY/$QITS_IMAGE_REPOSITORY/graalvmce-musl-builder:jdk-25"
      buildctl build --frontend dockerfile.v0 \
        --local context=docker --local dockerfile=docker \
        --opt filename=Dockerfile.musl-builder \
        --opt build-arg:MUSL_URL="$musl_url" \
        --opt build-arg:ZLIB_URL="$zlib_url" \
        --output "type=image,name=$builder,push=true"
      # THE QA PIPELINE'S BUILD, BYTE FOR BYTE.
      buildctl build --frontend dockerfile.v0 \
        --local context=. --local dockerfile=docker \
        --opt target=binary \
        --opt build-arg:BUILDER_IMAGE="$builder" \
        --opt build-arg:QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}" \
        --output type=local,dest=out
      # GENERATED, NEVER SUBMITTED — the postlude PUTs it for the artifact that declares it. It has
      # to come out of the same build as the binary: the reactor and its resolved dependency tree
      # exist only in there, and this step's container carries no maven at all.
      buildctl build --frontend dockerfile.v0 \
        --local context=. --local dockerfile=docker \
        --opt target=sbom \
        --opt build-arg:BUILDER_IMAGE="$builder" \
        --opt build-arg:QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}" \
        --output type=local,dest=out
      # The export loses the mode bit, so the chmod is not optional: a static binary that cannot be
      # executed is a green build that publishes nothing runnable.
      chmod +x out/qits-ci-daemon
      qits-publish daemon submit \
        --name qits-ci-daemon --version "$QITS_VERSION" --file out/qits-ci-daemon

  - image: qits/build-images/maven-base:latest
    timeout-seconds: 1800
    script: |
      # ALREADY PUBLISHED IS A SKIP, NOT A FAILURE, and the parent is checked beside the child: a
      # `-am` deploy writes both, and a run that resolved only one of them has published half a
      # coordinate. Re-running a maven deploy is a no-op; re-running it against an occupied
      # coordinate is not, so the guard stays.
      if curl -fsS -o /dev/null \
        "$QITS_MAVEN_REGISTRY_URL/eu/wohlben/qits/qits-ci-daemon-protocol/$QITS_VERSION/qits-ci-daemon-protocol-$QITS_VERSION.pom" \
        && curl -fsS -o /dev/null \
          "$QITS_MAVEN_REGISTRY_URL/eu/wohlben/qits/$QITS_VERSION/qits-$QITS_VERSION.pom"; then
        echo "qits-ci-daemon-protocol $QITS_VERSION and its parent are already published — skipping"
        exit 0
      fi
      # THE REACTOR ROOT RIDES ALONG ON `-am` AND IS DELIBERATELY NOT DECLARED: a `pom` parent
      # carries no bytes worth an SBOM, and it has to be deployed or the child coordinate resolves
      # to nothing.
      QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}" \
      QITS_MAVEN_AUTH_USR="${QITS_COMMISSIONED_CLIENT_ID-}" \
      QITS_MAVEN_AUTH_PSW="${QITS_COMMISSIONED_CLIENT_SECRET-}" \
      ./mvnw -B -ntp -s .qits-maven-settings.xml -pl ci-daemon-protocol -am deploy -DskipTests \
        -Dqits.maven.repository.url="$QITS_MAVEN_REGISTRY_URL" \
        -DaltDeploymentRepository="qits::default::$QITS_MAVEN_REGISTRY_URL"
      QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}" \
      ./mvnw -B -ntp -s .qits-maven-settings.xml -pl ci-daemon-protocol -DskipTests \
        -Dqits.maven.repository.url="$QITS_MAVEN_REGISTRY_URL" \
        org.cyclonedx:cyclonedx-maven-plugin:2.9.1:makeBom \
        -DoutputFormat=json -DoutputName=sbom -DschemaVersion=1.6
      # SUBMITTED HERE BECAUSE THE POSTLUDE CANNOT REACH IT — see the artifact's comment above. The
      # CLI is on this step's PATH like any release step's, and its idempotency policy is the one
      # the postlude runs, so a re-fired release resubmitting identical bytes is still green.
      qits artifacts publish sbom submit \
        --type maven --name "eu.wohlben.qits:qits-ci-daemon-protocol" \
        --version "$QITS_VERSION" --file ci-daemon-protocol/target/sbom.json
```

**Trap — the release slot is NOT the archetype's any more.** An earlier draft of this manifest said
it was, and it was right until `ci-daemon-protocol` became a PUBLISHED coordinate. Two artifacts of
two kinds now leave this tree and `daemon` publishes the binary and nothing else, so the whole slot
is spelled here: the archetype's build step with the binary publish, then a maven step on a second
image for the jar. The two steps cannot swap: the jar is what tells qits-ci which binary to fetch.

**Trap — the protocol entry must not declare `sbom:`.** `ci-daemon-protocol/target/sbom.json` is
written by `makeBom` in the maven step, which builds nothing, so the postlude lands on the buildctl
step above it and would submit a path that step has never seen. The maven step submits it itself,
through the same CLI and the same policy.

**Trap — the 409 policy changes on purpose.** The hand-written release treats an occupied coordinate
as a HARD FAILURE. `qits-publish daemon submit` runs the one policy: occupied with identical bytes is
success (re-fired release, rebootstrap replay, retried step all go green), occupied with DIFFERENT
bytes is a hard failure naming both digests. The maven deploy has no such policy of its own, which
is what the already-published guard in front of it is for — drop it and a re-fired release is a hard
failure on an occupied coordinate.

**Trap — the toolchain image.** `docker/Dockerfile.musl-builder` is this repository's, and the
archetype's presence guard is what lets a sibling ride the recipe without owning it. Do not delete
the guard when reading the archetype's release slot.

## qits-projects-daemon — `java-service` (nominal), **overrides BOTH slots**

```yaml
archetype: java-service
artifacts:
  - { type: docker, name: qits/projects-daemon, sbom: .sbom/sbom.json }
  - { type: docker, name: qits/project-agent, sbom: sbom-project-agent.json }
  # THE RUNNABLE DAEMON, as a plain file. Not a third image and not a regression to anything
  # retired: it is a `--opt target=binary` export OF THE SAME BUILD the first entry pushes, so the
  # two coordinates cannot name different bytes and there is still one native compile and one
  # reactor. What asks for it is qits-projects' pin test: it starts THIS daemon, at exactly the
  # version its pom pins, against localhost and round-trips the real control socket before any agent
  # container does. A container would need docker, and a CI step container has none.
  - { type: daemon, name: qits-projects-daemon, sbom: .sbom/sbom.json }
  # THE PIN AND THE PROTOCOL, IN ONE JAR. qits-projects-service used to read the agent image version
  # out of `env.QITS_PROJECTS_AGENT_IMAGE_VERSION`, a qits-configuration entry its release listener
  # rewrote on every release of this repository — so a new agent image reached a real refinement run
  # without the pair ever having been built together. Now the version travels as the version of the
  # artifact that also carries the wire contract.
  #
  # IT CARRIES NO `sbom:`, AND THE DOCUMENT IS NOT LOST. The postlude runs in ONE step — the last
  # one that builds — and a step container shares nothing with the next: the jar's document is
  # written by `makeBom` in the maven step below, whose files the builder step has never seen. So
  # that step submits its own document through the same `qits` CLI the postlude would have used. An
  # `sbom:` here would make the builder step submit a path that does not exist in it.
  - { type: maven, name: "eu.wohlben.qits:qits-projects-daemon-protocol" }

# TWO IMAGES FROM ONE TREE, WHICH NO ARCHETYPE PUSHES. java-service's extractor refuses anything but
# exactly one docker entry, and the second image is a different Dockerfile (`Dockerfile.projects`)
# with two build-args the recipe does not pass — BASE, pinned to a CalVer of qits/workspace-base and
# read out of that Dockerfile, and DAEMON_IMAGE, the ref the first build just pushed. A jar and a
# runnable daemon leave the same tree besides. The archetype is named for the family only; it
# contributes no step.
release-request:
  - image: qits/build-images/maven-base:latest
    timeout-seconds: 1800
    script: |
      export QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}"
      export QITS_MAVEN_REPOSITORY_URL="$QITS_MAVEN_REGISTRY_URL"
      ./mvnw -B -ntp -s .qits-maven-settings.xml verify \
        -Dqits.maven.repository.url="$QITS_MAVEN_REPOSITORY_URL"

  - image: qits/build-images/ci-base:latest
    build: true
    timeout-seconds: 3600
    script: |
      ref="$QITS_BUILD_REGISTRY/$QITS_IMAGE_REPOSITORY/projects-daemon:$QITS_CI_SHA"
      buildctl build --frontend dockerfile.v0 \
        --local context=. --local dockerfile=docker \
        --opt build-arg:QITS_MAVEN_REPOSITORY_URL="$QITS_MAVEN_REGISTRY_URL" \
        --opt build-arg:QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}" \
        --secret id=qits-client-id,src=/tmp/qits-client-id \
        --secret id=qits-client-secret,src=/tmp/qits-client-secret \
        --output "type=image,name=$ref,push=true"

release:
  - image: qits/build-images/ci-base:latest
    build: true
    timeout-seconds: 7200
    script: |
      base_version=$(sed -nE 's#^ARG BASE=qits/workspace-base:(.+)$#\1#p' docker/Dockerfile.projects)
      case "$base_version" in
        ''|*[!0-9.]*) echo "ARG BASE in docker/Dockerfile.projects is not a CalVer pin: $base_version" >&2; exit 1 ;;
      esac
      repository="$QITS_BUILD_REGISTRY/$QITS_IMAGE_REPOSITORY/projects-daemon"
      buildctl build --frontend dockerfile.v0 \
        --local context=. --local dockerfile=docker \
        --opt build-arg:QITS_MAVEN_REPOSITORY_URL="$QITS_MAVEN_REGISTRY_URL" \
        --opt build-arg:QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}" \
        --secret id=qits-client-id,src=/tmp/qits-client-id \
        --secret id=qits-client-secret,src=/tmp/qits-client-secret \
        --output "type=image,name=$repository:$QITS_VERSION,push=true"

      agent="$QITS_BUILD_REGISTRY/$QITS_IMAGE_REPOSITORY/project-agent:$QITS_VERSION"
      buildctl build --frontend dockerfile.v0 \
        --local context=. --local dockerfile=docker \
        --opt filename=Dockerfile.projects \
        --opt "build-arg:BASE=$QITS_BUILD_REGISTRY/$QITS_IMAGE_REPOSITORY/workspace-base:$base_version" \
        --opt "build-arg:DAEMON_IMAGE=$repository:$QITS_VERSION" \
        --secret id=qits-client-id,src=/tmp/qits-client-id \
        --secret id=qits-client-secret,src=/tmp/qits-client-secret \
        --output "type=image,name=$agent,push=true"

      # GENERATED, NEVER SUBMITTED — the postlude PUTs both documents declared above.
      buildctl build --frontend dockerfile.v0 \
        --local context=. --local dockerfile=docker \
        --opt target=sbom \
        --opt build-arg:QITS_MAVEN_REPOSITORY_URL="$QITS_MAVEN_REGISTRY_URL" \
        --opt build-arg:QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}" \
        --secret id=qits-client-id,src=/tmp/qits-client-id \
        --secret id=qits-client-secret,src=/tmp/qits-client-secret \
        --output type=local,dest=.sbom

      # THE AGENT IMAGE LAYERS THE DAEMON ONTO workspace-base AND DECLARES NO MANIFEST, so its whole
      # bill of materials is those two refs — which is what `from-dockerfile` reads out of the FROM
      # lines. BOTH BUILD-ARGS ARE PASSED, and neither is optional: without them the tool resolves
      # the file's own ARG defaults and would write `qits/projects-daemon:latest` for an image this
      # release never built, and an unqualified base the build never pulled. With them it names the
      # two references the builds above really resolved, registry host and all, which is the
      # hand-written document this replaces.
      qits-publish sbom from-dockerfile \
        --root-name qits/project-agent --root-version "$QITS_VERSION" \
        --dockerfile docker/Dockerfile.projects \
        --build-arg BASE="$QITS_BUILD_REGISTRY/$QITS_IMAGE_REPOSITORY/workspace-base:$base_version" \
        --build-arg DAEMON_IMAGE="$repository:$QITS_VERSION" \
        -o sbom-project-agent.json

      # THE RUNNABLE JAR, out of the same build again: qits-projects' pin test starts this file
      # rather than a container, and a CI step container has no docker to run one in.
      buildctl build --frontend dockerfile.v0 \
        --local context=. --local dockerfile=docker \
        --opt target=binary \
        --opt build-arg:QITS_MAVEN_REPOSITORY_URL="$QITS_MAVEN_REGISTRY_URL" \
        --opt build-arg:QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}" \
        --secret id=qits-client-id,src=/tmp/qits-client-id \
        --secret id=qits-client-secret,src=/tmp/qits-client-secret \
        --output type=local,dest=.binary

      # THE FILENAME IS NOT THE ARTIFACT NAME: `qits-projects-daemon` is published from a file
      # called `qits-projects-daemon.jar`.
      qits-publish daemon submit \
        --name qits-projects-daemon --version "$QITS_VERSION" \
        --file .binary/qits-projects-daemon.jar

    # A SECOND STEP ON A SECOND IMAGE, because this one needs maven and the one above needs
    # buildctl. It is deliberately AFTER the image and daemon publishes: the jar is what tells
    # qits-projects which agent image to run, so a jar that resolves before its images are in the
    # registry is a pin pointing at nothing.
  - image: qits/build-images/maven-base:latest
    timeout-seconds: 1800
    script: |
      # ALREADY PUBLISHED IS A SKIP, NOT A FAILURE, and the parent is checked beside the child: a
      # `-am` deploy writes both, and a run that resolved only one of them published half a
      # coordinate.
      if curl -fsS -o /dev/null \
        "$QITS_MAVEN_REGISTRY_URL/eu/wohlben/qits/qits-projects-daemon-protocol/$QITS_VERSION/qits-projects-daemon-protocol-$QITS_VERSION.pom" \
        && curl -fsS -o /dev/null \
          "$QITS_MAVEN_REGISTRY_URL/eu/wohlben/qits/$QITS_VERSION/qits-$QITS_VERSION.pom"; then
        echo "qits-projects-daemon-protocol $QITS_VERSION and its parent are already published — skipping"
        exit 0
      fi
      # THE REACTOR ROOT RIDES ALONG ON `-am` AND IS DELIBERATELY NOT DECLARED: a `pom` parent
      # carries no bytes worth an SBOM, and it has to be deployed or the child resolves to nothing.
      QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}" \
      QITS_MAVEN_AUTH_USR="${QITS_COMMISSIONED_CLIENT_ID-}" \
      QITS_MAVEN_AUTH_PSW="${QITS_COMMISSIONED_CLIENT_SECRET-}" \
      ./mvnw -B -ntp -s .qits-maven-settings.xml -pl projects-daemon-protocol -am deploy -DskipTests \
        -Dqits.maven.repository.url="$QITS_MAVEN_REGISTRY_URL" \
        -DaltDeploymentRepository="qits::default::$QITS_MAVEN_REGISTRY_URL"
      QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}" \
      ./mvnw -B -ntp -s .qits-maven-settings.xml -pl projects-daemon-protocol -DskipTests \
        -Dqits.maven.repository.url="$QITS_MAVEN_REGISTRY_URL" \
        org.cyclonedx:cyclonedx-maven-plugin:2.9.1:makeBom \
        -DoutputFormat=json -DoutputName=sbom -DschemaVersion=1.6
      # SUBMITTED HERE BECAUSE THE POSTLUDE CANNOT REACH IT — see the artifact's comment above. The
      # CLI is on this step's PATH like any release step's, and its idempotency policy is the one
      # the postlude runs.
      qits artifacts publish sbom submit \
        --type maven --name "eu.wohlben.qits:qits-projects-daemon-protocol" \
        --version "$QITS_VERSION" --file projects-daemon-protocol/target/sbom.json
```

**Trap — the ordering, and the two build-args.** The two images are ordered: `DAEMON_IMAGE` names
the ref the first build pushed, so the second build cannot move above the first. The same two values
have to reach `from-dockerfile`, and an earlier draft of this manifest omitted them, which would
have shipped a WRONG document rather than a thinner one — `DockerfileSbom.java` in
qits-platform-access-cli resolves `${VAR}` from `--build-arg` FIRST and the file's own ARG defaults
second, so with the flags missing `${DAEMON_IMAGE}` resolves through `${DAEMON_VERSION}` to
`qits/projects-daemon:latest`, an image this release never built, and `BASE` to an unqualified ref
nothing ever pulled. **Both flags are mandatory.** What was verified beyond that: the tool emits the
same shape as the hand-written printf block it replaces — one root component, one component per
`FROM` base, and the `dependsOn` edges between them — and it REFUSES an unresolved variable rather
than guessing at one, which is the check that would have caught the omission at the wrong end of a
release.

## qits-workspace-daemon — `java-service` (nominal), **overrides BOTH slots**

```yaml
archetype: java-service
artifacts:
  # THE IMAGE ENTRY AND THE DAEMON ENTRY NAME THE SAME DOCUMENT ON PURPOSE, which is what the
  # hand-written file PUT twice: one build produces both, so one bill of materials describes both.
  - { type: docker, name: qits/workspace, sbom: .sbom/sbom.json }
  - { type: daemon, name: qits-workspace-daemon, sbom: .sbom/sbom.json }
  # THE PROTOCOL MODULE, published from the maven step below.
  #
  # IT CARRIES NO `sbom:`, AND THE DOCUMENT IS NOT LOST. The postlude runs in ONE step — the last
  # one that builds — and a step container shares nothing with the next: this jar's document is
  # written by `makeBom` in the maven step, whose files the builder step has never seen. So that
  # step submits its own document through the same `qits` CLI the postlude would have used. An
  # `sbom:` here would make the builder step submit a path that does not exist in it.
  - { type: maven, name: "eu.wohlben.qits:qits-workspace-daemon-protocol" }

# THREE ARTIFACTS OF THREE DIFFERENT TYPES OUT OF ONE TREE — an image, a daemon jar and a published
# protocol module. No archetype publishes more than one kind, so both slots are this repository's.
release-request:
  - image: qits/build-images/maven-base:latest
    timeout-seconds: 1800
    script: |
      export QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}"
      export QITS_MAVEN_REPOSITORY_URL="$QITS_MAVEN_REGISTRY_URL"
      ./mvnw -B -ntp -s .qits-maven-settings.xml verify \
        -Dqits.maven.repository.url="$QITS_MAVEN_REPOSITORY_URL"

  - image: qits/build-images/ci-base:latest
    build: true
    timeout-seconds: 7200
    script: |
      ref="$QITS_BUILD_REGISTRY/$QITS_IMAGE_REPOSITORY/workspace:$QITS_CI_SHA"
      buildctl build --frontend dockerfile.v0 \
        --local context=. --local dockerfile=docker \
        --opt build-arg:QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}" \
        --opt build-arg:QITS_MAVEN_REPOSITORY_URL="$QITS_MAVEN_REGISTRY_URL" \
        --secret id=qits-client-id,src=/tmp/qits-client-id \
        --secret id=qits-client-secret,src=/tmp/qits-client-secret \
        --output "type=image,name=$ref,push=true"

release:
  - image: qits/build-images/ci-base:latest
    build: true
    timeout-seconds: 7200
    script: |
      ref="$QITS_BUILD_REGISTRY/$QITS_IMAGE_REPOSITORY/workspace:$QITS_VERSION"
      buildctl build --frontend dockerfile.v0 \
        --local context=. --local dockerfile=docker \
        --opt build-arg:QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}" \
        --opt build-arg:QITS_MAVEN_REPOSITORY_URL="$QITS_MAVEN_REGISTRY_URL" \
        --secret id=qits-client-id,src=/tmp/qits-client-id \
        --secret id=qits-client-secret,src=/tmp/qits-client-secret \
        --output "type=image,name=$ref,push=true"

      buildctl build --frontend dockerfile.v0 \
        --local context=. --local dockerfile=docker \
        --opt target=sbom \
        --opt build-arg:QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}" \
        --opt build-arg:QITS_MAVEN_REPOSITORY_URL="$QITS_MAVEN_REGISTRY_URL" \
        --secret id=qits-client-id,src=/tmp/qits-client-id \
        --secret id=qits-client-secret,src=/tmp/qits-client-secret \
        --output type=local,dest=.sbom

      buildctl build --frontend dockerfile.v0 \
        --local context=. --local dockerfile=docker \
        --opt target=binary \
        --opt build-arg:QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}" \
        --opt build-arg:QITS_MAVEN_REPOSITORY_URL="$QITS_MAVEN_REGISTRY_URL" \
        --secret id=qits-client-id,src=/tmp/qits-client-id \
        --secret id=qits-client-secret,src=/tmp/qits-client-secret \
        --output type=local,dest=.binary

      # THE FILENAME IS NOT THE ARTIFACT NAME: the daemon is published as `qits-workspace-daemon`
      # from a file called `qits-workspace-daemon.jar`. Spelled out rather than found, because this
      # export directory also holds nothing else worth guessing at.
      qits-publish daemon submit \
        --name qits-workspace-daemon --version "$QITS_VERSION" \
        --file .binary/qits-workspace-daemon.jar

  - image: qits/build-images/maven-base:latest
    timeout-seconds: 1800
    script: |
      # ALREADY PUBLISHED IS A SKIP, NOT A FAILURE, and the parent is checked beside the child: a
      # `-am` deploy writes both, and a run that resolved only one of them published half a
      # coordinate.
      if curl -fsS -o /dev/null \
        "$QITS_MAVEN_REGISTRY_URL/eu/wohlben/qits/qits-workspace-daemon-protocol/$QITS_VERSION/qits-workspace-daemon-protocol-$QITS_VERSION.pom" \
        && curl -fsS -o /dev/null \
          "$QITS_MAVEN_REGISTRY_URL/eu/wohlben/qits/$QITS_VERSION/qits-$QITS_VERSION.pom"; then
        echo "qits-workspace-daemon-protocol $QITS_VERSION and its parent are already published — skipping"
        exit 0
      fi
      # THE REACTOR ROOT RIDES ALONG ON `-am` AND IS DELIBERATELY NOT DECLARED: a `pom` parent
      # carries no bytes worth an SBOM, and it has to be deployed or the child resolves to nothing.
      QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}" \
      QITS_MAVEN_AUTH_USR="${QITS_COMMISSIONED_CLIENT_ID-}" \
      QITS_MAVEN_AUTH_PSW="${QITS_COMMISSIONED_CLIENT_SECRET-}" \
      ./mvnw -B -ntp -s .qits-maven-settings.xml -pl workspace-daemon-protocol -am deploy -DskipTests \
        -Dqits.maven.repository.url="$QITS_MAVEN_REGISTRY_URL" \
        -DaltDeploymentRepository="qits::default::$QITS_MAVEN_REGISTRY_URL"
      QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}" \
      ./mvnw -B -ntp -s .qits-maven-settings.xml -pl workspace-daemon-protocol -DskipTests \
        -Dqits.maven.repository.url="$QITS_MAVEN_REGISTRY_URL" \
        org.cyclonedx:cyclonedx-maven-plugin:2.9.1:makeBom \
        -DoutputFormat=json -DoutputName=sbom -DschemaVersion=1.6
      # SUBMITTED HERE BECAUSE THE POSTLUDE CANNOT REACH IT — see the artifact's comment above. The
      # CLI is on this step's PATH like any release step's, and its idempotency policy is the one
      # the postlude runs.
      qits artifacts publish sbom submit \
        --type maven --name "eu.wohlben.qits:qits-workspace-daemon-protocol" \
        --version "$QITS_VERSION" --file workspace-daemon-protocol/target/sbom.json
```

**Traps.** (1) The image entry and the daemon entry deliberately name the SAME `.sbom/sbom.json`,
which is what the hand-written file PUT twice — the postlude will submit it once per entry, under
two artifact identities, as before. (2) **THE PROTOCOL ENTRY MUST NOT DECLARE `sbom:`, and an
earlier draft of this manifest got that wrong.** `workspace-daemon-protocol/target/sbom.json` is
written by `makeBom` in the LAST step, which builds nothing — so the postlude lands on the buildctl
step above it, where that file has never existed, and the release fails on a submit for a missing
path. The maven step submits the document itself, through the same CLI and the same policy. (3) The
maven half deploys `-pl … -am`, so the reactor ROOT pom is deployed too and is deliberately not
declared: a `pom` parent carries no bytes worth an SBOM. It is also why the skip guard checks the
parent coordinate beside the child — a re-fired release must find both, or half a coordinate is
published. (4) The daemon publish's 409 policy softens from hard-fail to identical-bytes-is-success,
as with qits-ci-daemon.

## qits-build-images-oci — `oci` (nominal), **overrides BOTH slots**

```yaml
archetype: oci
artifacts:
  - { type: docker, name: qits/build-images/ci-base, sbom: sbom-ci-base.json }
  - { type: docker, name: qits/build-images/maven-base, sbom: sbom-maven-base.json }
  - { type: docker, name: qits/build-images/userflows-base, sbom: sbom-userflows-base.json }
  - { type: docker, name: qits/build-images/node-base, sbom: sbom-node-base.json }
  - { type: docker, name: qits/build-images/node-docker-base, sbom: sbom-node-docker-base.json }

# FIVE IMAGES FROM FIVE DIRECTORIES, WHICH THE oci ARCHETYPE'S HEADER NAMES AS THE OVERRIDE CASE.
# And this repository cannot ride any archetype's step image anyway: the images it builds ARE
# qits/build-images/*, so a recipe running on `ci-base:latest` would bootstrap itself. It builds on
# UPSTREAM `docker:28-dind` with `docker: true`, not buildctl — deliberately, and the one repository
# on the platform for which that is correct.
release-request:
  - image: docker:28-dind
    docker: true
    timeout-seconds: 3600
    script: |
      images='ci-base maven-base userflows-base node-base node-docker-base'
      for image in $images; do
        docker build \
          -f "$image/Dockerfile" \
          -t "qits-build-images-oci-push/$image:$QITS_CI_SHA" \
          .
      done

release:
  - image: docker:28-dind
    docker: true
    timeout-seconds: 3600
    script: |
      images='ci-base maven-base userflows-base node-base node-docker-base'
      for image in $images; do
        repository="$QITS_REGISTRY/$QITS_IMAGE_REPOSITORY/build-images/$image"
        docker build -f "$image/Dockerfile" -t "$repository:$QITS_VERSION" .
        docker tag "$repository:$QITS_VERSION" "$repository:latest"
      done
      for image in $images; do
        repository="$QITS_REGISTRY/$QITS_IMAGE_REPOSITORY/build-images/$image"
        docker push "$repository:$QITS_VERSION"
        docker push "$repository:latest"
      done
      # ONE DOCUMENT PER IMAGE, each at the path its artifact entry declares. `from-dockerfile`
      # replaces ~100 lines of sed/case/printf per image; the generated paths are what the postlude
      # submits, so nothing here PUTs anything.
      for image in $images; do
        qits-publish sbom from-dockerfile \
          --root-name "qits/build-images/$image" --root-version "$QITS_VERSION" \
          --dockerfile "$image/Dockerfile" \
          -o "sbom-$image.json"
      done
```

**Traps.** (1) **`:latest` is a second tag every archetype has retired**, and it is load-bearing
here — every other repository's step declares `qits/build-images/<x>:latest`. Do not drop it.
(2) `$QITS_REGISTRY` (the host daemon's view), not `$QITS_BUILD_REGISTRY`: this pipeline pushes
through a docker daemon, not through the platform builder. (3) **Land this repository LAST in its
batch and watch the next run of every other repository**: a bad release here breaks the step images
the other 45 pipelines run on. (4) The hand-written SBOM PUT shells `docker run … ci-base:$version`
purely to get a `curl` — the postlude removes that whole contortion.

## qits-workspace-editor-oci — `oci` (nominal), **overrides BOTH slots**

```yaml
archetype: oci
artifacts:
  - { type: docker, name: qits/workspace-editor, sbom: sbom.json }
  - { type: maven, name: "eu.wohlben.qits:qits-workspace-editor-image", sbom: target/sbom.json }

# AN IMAGE AND A JAR OUT OF ONE TREE: the oci archetype pushes exactly one image and publishes
# nothing else, and its extractor refuses a second entry outright. Both slots are this repository's.
release-request:
  - image: qits/build-images/ci-base:latest
    build: true
    timeout-seconds: 7200
    script: |
      ref="$QITS_BUILD_REGISTRY/$QITS_IMAGE_REPOSITORY/workspace-editor:$QITS_CI_SHA"
      buildctl build --frontend dockerfile.v0 \
        --local context=. --local dockerfile=. \
        --output "type=image,name=$ref,push=true"

  - image: qits/build-images/maven-base:latest
    timeout-seconds: 1800
    script: |
      QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}" \
      QITS_MAVEN_AUTH_USR="${QITS_COMMISSIONED_CLIENT_ID-}" \
      QITS_MAVEN_AUTH_PSW="${QITS_COMMISSIONED_CLIENT_SECRET-}" \
      ./mvnw -B -ntp -s .qits-maven-settings.xml verify \
        -Dqits.maven.repository.url="$QITS_MAVEN_REGISTRY_URL"

release:
  - image: qits/build-images/ci-base:latest
    build: true
    timeout-seconds: 7200
    script: |
      ref="$QITS_BUILD_REGISTRY/$QITS_IMAGE_REPOSITORY/workspace-editor:$QITS_VERSION"
      buildctl build --frontend dockerfile.v0 \
        --local context=. --local dockerfile=. \
        --output "type=image,name=$ref,push=true"
      # THE FROM LINES, PLUS THE ONE THING NO DOCKERFILE PARSER CAN KNOW. `from-dockerfile` resolves
      # `${…}` FROMs from their global ARG defaults and writes the base components; the vendored
      # openvscode-server is an ADD of a tarball, so its component and its pinned SHA-256 are read
      # out of the Dockerfile's own ARGs and appended. See the trap.
      qits-publish sbom from-dockerfile \
        --root-name qits/workspace-editor --root-version "$QITS_VERSION" \
        --dockerfile Dockerfile \
        -o sbom.json

  - image: qits/build-images/maven-base:latest
    timeout-seconds: 1800
    script: |
      QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}" \
      QITS_MAVEN_AUTH_USR="${QITS_COMMISSIONED_CLIENT_ID-}" \
      QITS_MAVEN_AUTH_PSW="${QITS_COMMISSIONED_CLIENT_SECRET-}" \
      ./mvnw -B -ntp -s .qits-maven-settings.xml deploy -DskipTests \
        -Dqits.maven.repository.url="$QITS_MAVEN_REGISTRY_URL" \
        -DaltDeploymentRepository="qits::default::$QITS_MAVEN_REGISTRY_URL"
      QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}" \
      ./mvnw -B -ntp -s .qits-maven-settings.xml -DskipTests \
        -Dqits.maven.repository.url="$QITS_MAVEN_REGISTRY_URL" \
        org.cyclonedx:cyclonedx-maven-plugin:2.9.1:makeBom \
        -DoutputFormat=json -DoutputName=sbom -DschemaVersion=1.6
```

**Trap — this migration can SILENTLY THIN AN SBOM.** The hand-written generator emits a
`pkg:generic/openvscode-server@<OPENVSCODE_VERSION>` component carrying the `OPENVSCODE_SHA256`
hash, validated to 64 hex characters, and that is the single most interesting fact in the document:
the editor is the product. `qits-publish sbom from-dockerfile` describes `FROM` lines. **Confirm the
tool emits the openvscode component before deleting the hand-written block**; if it does not, keep
the printf/ARG-reading block in this slot and revisit when the tool grows an `ADD`-url arm.

## qits-workspace-oci — `oci` (nominal), **overrides BOTH slots**

```yaml
archetype: oci
artifacts:
  - { type: docker, name: qits/workspace-base, sbom: sbom.json }

# ONE IMAGE, AND STILL NOT THE ARCHETYPE'S. The build CONTEXT has to be prepared first: the
# Dockerfile pins `ARG QITS_CLI_VERSION`, and the matching qits CLI binary has to be fetched into
# the context before buildctl runs — behind a client-credentials token minted at the idp, because
# the artifacts store answers 401 without a bearer. The oci recipe prepares nothing and passes no
# build-arg, so it would push an image with no CLI in it and nothing would say so.
release-request:
  - image: qits/build-images/ci-base:latest
    build: true
    timeout-seconds: 7200
    script: |
      cli_version=$(sed -nE 's#^ARG QITS_CLI_VERSION=(.+)$#\1#p' Dockerfile)
      : "${cli_version:?Dockerfile declares no ARG QITS_CLI_VERSION; the image pins no qits CLI}"
      : "${QITS_ARTIFACTS_URL:?the artifacts store address is not injected}"
      : "${QITS_COMMISSIONED_CLIENT_ID:?no commissioned client id}"
      : "${QITS_COMMISSIONED_CLIENT_SECRET:?no commissioned client secret}"
      : "${QITS_GIT_AUTH_TOKEN_URL:?no idp token endpoint injected}"
      cli_token=$(curl -fsS --connect-timeout 5 --max-time 30 \
        -u "$QITS_COMMISSIONED_CLIENT_ID:$QITS_COMMISSIONED_CLIENT_SECRET" \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        --data "grant_type=client_credentials&audience=qits-platform" \
        "$QITS_GIT_AUTH_TOKEN_URL" \
        | sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
      : "${cli_token:?the idp minted no qits-platform bearer for the commissioned client}"
      # THE FILE IS CALLED `qits` BECAUSE THAT IS WHAT THE DOCKERFILE COPIES AND WHAT THE IMAGE PUTS
      # ON $PATH. The ARTIFACT it comes from is `qits-platform-access-cli`; the two names differ on
      # purpose and neither may be changed here.
      curl -fsSL --retry 2 --retry-delay 2 -H "Authorization: Bearer $cli_token" \
        -o qits "$QITS_ARTIFACTS_URL/artifacts/daemons/qits-platform-access-cli/$cli_version"
      [ -s qits ] || { echo "the qits CLI download is empty" >&2; exit 1; }
      ref="$QITS_BUILD_REGISTRY/$QITS_IMAGE_REPOSITORY/workspace-base:$QITS_CI_SHA"
      buildctl build --frontend dockerfile.v0 \
        --local context=. --local dockerfile=. \
        --output "type=image,name=$ref,push=true"

release:
  - image: qits/build-images/ci-base:latest
    build: true
    timeout-seconds: 7200
    script: |
      cli_version=$(sed -nE 's#^ARG QITS_CLI_VERSION=(.+)$#\1#p' Dockerfile)
      : "${cli_version:?Dockerfile declares no ARG QITS_CLI_VERSION; the image pins no qits CLI}"
      : "${QITS_ARTIFACTS_URL:?the artifacts store address is not injected}"
      : "${QITS_COMMISSIONED_CLIENT_ID:?no commissioned client id}"
      : "${QITS_COMMISSIONED_CLIENT_SECRET:?no commissioned client secret}"
      : "${QITS_GIT_AUTH_TOKEN_URL:?no idp token endpoint injected}"
      cli_token=$(curl -fsS --connect-timeout 5 --max-time 30 \
        -u "$QITS_COMMISSIONED_CLIENT_ID:$QITS_COMMISSIONED_CLIENT_SECRET" \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        --data "grant_type=client_credentials&audience=qits-platform" \
        "$QITS_GIT_AUTH_TOKEN_URL" \
        | sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
      : "${cli_token:?the idp minted no qits-platform bearer for the commissioned client}"
      curl -fsSL --retry 2 --retry-delay 2 -H "Authorization: Bearer $cli_token" \
        -o qits "$QITS_ARTIFACTS_URL/artifacts/daemons/qits-platform-access-cli/$cli_version"
      [ -s qits ] || { echo "the qits CLI download is empty" >&2; exit 1; }
      ref="$QITS_BUILD_REGISTRY/$QITS_IMAGE_REPOSITORY/workspace-base:$QITS_VERSION"
      buildctl build --frontend dockerfile.v0 \
        --local context=. --local dockerfile=. \
        --output "type=image,name=$ref,push=true"
      qits-publish sbom from-dockerfile \
        --root-name qits/workspace-base --root-version "$QITS_VERSION" \
        --dockerfile Dockerfile \
        -o sbom.json
```

**Trap.** The two slots are byte-identical except for the tag, and the fetch must stay in BOTH: a QA
build that skipped it would gate a context the release does not build. **`qits` in the context is a
downloaded artifact, not a build output** — it must stay out of `.dockerignore`'s way and out of any
"clean the tree" step somebody adds later.

## qits-bootstrap-cli — `cli`, no override

```yaml
archetype: cli
```

**One line, and the absences are the statement.** No `artifacts:`, no `userflows:`, and **no
`release:` slot anywhere**: this repository publishes nothing, declares no `deployments.yml`, and a
phase nobody declares steps for gets no trigger document and therefore no run. That is why it has
only a `ci-event-release-request.yml` today and no `ci-event-release.yml`.

The hand-written QA step is the archetype's exactly: `maven-base`, `user: build`, 1800s,
`./mvnw -B -ntp -s .qits-maven-settings.xml verify`. No `QITS_MAVEN_REPOSITORY_URL` in either — the
pom is parentless with no qits dependency, so the platform registry is never dialled.

**Trap — the binary name.** This repository's program is still called `qits`, the same word
`qits-platform-access-cli` publishes its own binary under, and **a separate ticket renames it**. This
migration must not touch it: the `cli` archetype names no binary and publishes nothing, so there is
nothing here to rename, and adding an `artifacts:` entry "while we're in the file" would both create
a publication that does not exist and pre-empt that ticket's decision.

**Not a gate to trust.** The archetype's header says it out loud: unit tests only, no `*IT.java`,
the phases that shell docker are deliberately untested. A green run here is not "the bootstrap
works".

## qits-platform-access-cli — `daemon` (nominal), **overrides BOTH slots**

```yaml
archetype: daemon
artifacts:
  - { type: daemon, name: qits-platform-access-cli, sbom: out/sbom.json }

# THE daemon ARCHETYPE'S OWN HEADER NAMES THIS REPOSITORY AS THE ONE THAT RIDES ITS OWN RECIPES, and
# the reason is the build: there is no `docker/Dockerfile.musl-builder` and no BUILDER_IMAGE here.
# `docker/Dockerfile` takes MUSL_URL and ZLIB_URL directly, so the archetype's invocation would pass
# an argument this Dockerfile does not declare and omit the two it needs.
release-request:
  - image: qits/build-images/ci-base:latest
    build: true
    timeout-seconds: 3600
    script: |
      : "${QITS_MAVEN_REGISTRY_URL:?}"
      maven_root="${QITS_MAVEN_REGISTRY_URL%/}"
      musl_url=$(sed -n 's/^ARG MUSL_URL=//p' docker/Dockerfile)
      zlib_url=$(sed -n 's/^ARG ZLIB_URL=//p' docker/Dockerfile)
      : "${musl_url:?docker/Dockerfile declares no ARG MUSL_URL}"
      : "${zlib_url:?docker/Dockerfile declares no ARG ZLIB_URL}"
      musl_url="$maven_root${musl_url#*/artifacts/maven/maven}"
      zlib_url="$maven_root${zlib_url#*/artifacts/maven/maven}"
      buildctl build --frontend dockerfile.v0 \
        --local context=. --local dockerfile=docker \
        --opt target=binary \
        --opt build-arg:MUSL_URL="$musl_url" \
        --opt build-arg:ZLIB_URL="$zlib_url" \
        --opt build-arg:QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}" \
        --output type=local,dest=out
      # THE BINARY IS `out/qits` AND THE ARTIFACT IS `qits-platform-access-cli`. The mismatch is the
      # ordinary case rather than a slip, and this migration does not touch either name.
      chmod +x out/qits
      ./out/qits --help >/dev/null
      # A binary that prints Quarkus build-time configuration on --help is unusable as a CLI.
      noise=$(QUARKUS_ANALYTICS_DISABLED=true ./out/qits --help 2>&1) || true
      case "$noise" in
        *ConfigRecorder*|*"Build time property"*)
          echo "$noise" >&2
          echo "the binary prints Quarkus configuration noise under QUARKUS_ANALYTICS_DISABLED" >&2
          exit 1 ;;
      esac
      echo "qits built: $(sha256sum out/qits | cut -d' ' -f1)"

release:
  - image: qits/build-images/ci-base:latest
    build: true
    timeout-seconds: 3600
    script: |
      : "${QITS_MAVEN_REGISTRY_URL:?}"
      maven_root="${QITS_MAVEN_REGISTRY_URL%/}"
      musl_url=$(sed -n 's/^ARG MUSL_URL=//p' docker/Dockerfile)
      zlib_url=$(sed -n 's/^ARG ZLIB_URL=//p' docker/Dockerfile)
      : "${musl_url:?docker/Dockerfile declares no ARG MUSL_URL}"
      : "${zlib_url:?docker/Dockerfile declares no ARG ZLIB_URL}"
      musl_url="$maven_root${musl_url#*/artifacts/maven/maven}"
      zlib_url="$maven_root${zlib_url#*/artifacts/maven/maven}"
      # BYTE-IDENTICAL BUILD ARGS ACROSS THE TWO INVOCATIONS, or the sbom stage is a second native
      # compile instead of a cache hit on the resolve that produced the binary.
      buildctl build --frontend dockerfile.v0 \
        --local context=. --local dockerfile=docker \
        --opt target=binary \
        --opt build-arg:MUSL_URL="$musl_url" \
        --opt build-arg:ZLIB_URL="$zlib_url" \
        --opt build-arg:QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}" \
        --output type=local,dest=out
      buildctl build --frontend dockerfile.v0 \
        --local context=. --local dockerfile=docker \
        --opt target=sbom \
        --opt build-arg:MUSL_URL="$musl_url" \
        --opt build-arg:ZLIB_URL="$zlib_url" \
        --opt build-arg:QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}" \
        --output type=local,dest=out
      chmod +x out/qits
      ./out/qits --help >/dev/null
      qits-publish daemon submit \
        --name qits-platform-access-cli --version "$QITS_VERSION" --file out/qits
```

**Traps.** (1) **Do not rename `out/qits`.** qits-workspace-oci fetches this artifact by the name
`qits-platform-access-cli` and writes it into its build context as `qits`; both spellings are load-
bearing in a different repository. (2) The 409 hard-fail becomes `qits-publish`'s
identical-bytes-is-success policy. (3) `chmod +x` is not optional — the local export loses the mode
bit, and a static binary that cannot be executed is a green build that publishes nothing runnable.

---

# Batch 4 — services (18)

All eighteen are `archetype: java-service`. What each one owes beyond the archetype:

- **`artifacts:`** — one `docker` entry (plus a `docs` entry where it publishes one), always with
  `sbom: .sbom/sbom.json`.
- **`userflows:`** — `true` where the bundle's site is the repository's own name, the spelled site
  otherwise. Ten of the eighteen publish under a name that is NOT the repository's.
- **`.config/qits/userflow-stories`** — a sibling file, not a key, wherever the hand-written QA step
  carries `-Dit.test`. Fourteen do. Four (`qits-artifacts-service`, `qits-docs-service`,
  `qits-githost-service`, `qits-stt-service`) deliberately keep no list and get no file: their pom
  decides which ITs run, which the archetype header records as the better shape.

**Two differences shared by several repositories and deliberately NOT overridden.**
`qits-edge-platform-service` and `qits-stt-service` build on `ci-base` where the archetype uses
`node-docker-base` — a superset image, and neither repository has a webui submodule, so the recipe's
submodule walk pays nothing. `qits-containers-service`, `qits-edge-platform-service` and
`qits-stt-service` pass no `-Dquarkus.quinoa=false`; the archetype passes it, which is an unknown
property with no extension present and is inert.

## qits-idp-platform-service

```yaml
archetype: java-service
artifacts:
  - { type: docker, name: qits/qits-platform-idp, sbom: .sbom/sbom.json }
userflows: true
```
Also commit `.config/qits/userflow-stories`: `TokenIssuanceBootstrapIT`, `BootstrapDocumentsIT`,
`CommissionedCredentialIT`, `CommissionRefusalsIT`, `FrontDoorRefusalsIT`,
`ReservedRoleNamespaceIT`. No override. **Trap** — image name `qits/qits-platform-idp` is not
derivable from the repository name; it is why the recipe reads the declaration.

## qits-deployments-platform-service

```yaml
archetype: java-service
artifacts:
  - { type: docker, name: qits/qits-deployments, sbom: .sbom/sbom.json }
userflows: true
```
`userflow-stories`: `TokenValidationBootstrapIT`, `DeploymentConfigurationIT`, `BuildDeploymentIT`,
`PlatformOverviewIT`, `AccessRefusalIT`. No override.

## qits-events-platform-service

```yaml
archetype: java-service
artifacts:
  - { type: docker, name: qits/qits-events, sbom: .sbom/sbom.json }
userflows: true
```
`userflow-stories`: `EventBusBootstrapIT`, `DisjointInterestsIT`, `SubscriptionFramesIT`,
`ReplayFromTheLogIT`, `QuietBusIT`, `OperatorInvestigationIT`. No override.

## qits-orchestrator-platform-service

```yaml
archetype: java-service
artifacts:
  - { type: docker, name: qits/qits-platform-orchestrator, sbom: .sbom/sbom.json }
userflows: true
```
`userflow-stories`: `TokenValidationBootstrapIT`, `GarbageCollectionRunIT`, `PeerFailureIT`,
`RunHistoryIT`, `DeletionRefusalIT`. No override.

## qits-system-platform-service

```yaml
archetype: java-service
artifacts:
  - { type: docker, name: qits/qits-platform-system, sbom: .sbom/sbom.json }
userflows: true
```
`userflow-stories`: `TokenValidationBootstrapIT`, `HostOverviewIT`, `TerminalRefusalIT`,
`TerminalSessionIT`. No override.

## qits-edge-platform-service

```yaml
archetype: java-service
artifacts:
  - { type: docker, name: qits/qits-platform-edge, sbom: .sbom/sbom.json }
userflows: true
```
`userflow-stories`: `ForwardAuthBootstrapIT`, `AnonymousReadIT`, `SessionlessWallIT`,
`SpaFreshnessIT`, `StreamingPassthroughIT`, `UpstreamOutageIT`, `VhostRoutingIT`. No override; no
submodule, no webui, `ci-base` → `node-docker-base` is a benign widening.

## qits-projects-service

```yaml
archetype: java-service
artifacts:
  - { type: docker, name: qits/qits-projects, sbom: .sbom/sbom.json }
userflows: qits-projects
```
`userflow-stories`: `TokenValidationBootstrapIT`, `ProjectCatalogueIT`, `EpicPlanningIT`,
`AccessRefusalIT`, `CatalogueReviewIT`. No override.

## qits-observability-service

```yaml
archetype: java-service
artifacts:
  - { type: docker, name: qits/qits-observability, sbom: .sbom/sbom.json }
userflows: qits-observability
```
`userflow-stories`: `TelemetryBootstrapIT`, `BufferEvictionIT`, `ParentTierIT`, `UnreadableExportIT`,
`OperatorInvestigationIT`, `QuietReadsIT`, `OneDoorEachIT`. No override. The site is
`@userflows/qits-observability`, not the repository name — spell it.

## qits-githost-service

```yaml
archetype: java-service
artifacts:
  - { type: docker, name: qits/qits-githost, sbom: .sbom/sbom.json }
userflows: qits-githost
```
**No `userflow-stories` file** — this repository's pom decides which ITs run, deliberately. No
override.

## qits-workspaces-service

```yaml
archetype: java-service
artifacts:
  - { type: docker, name: qits/qits-workspaces, sbom: .sbom/sbom.json }
userflows: qits-workspaces
```
`userflow-stories`: `TokenValidationBootstrapIT`, `WorkspaceProvisionIT`, `EditorEnsureIT`,
`OperatorReadsIT`, `MergeDoorRefusalIT`. No override.

## qits-stt-service

```yaml
archetype: java-service
artifacts:
  - { type: docker, name: qits/qits-stt, sbom: .sbom/sbom.json }
userflows: qits-stt
```
**No `userflow-stories` file.** No override; no submodule.

## qits-artifacts-service — **overrides `release-request:`**

```yaml
archetype: java-service
artifacts:
  - { type: docker, name: qits/qits-artifacts, sbom: .sbom/sbom.json }
userflows: qits-artifacts

# THE VERIFY HERE RUNS WITH QUINOA ON, which is the opposite of every sibling and of the recipe.
# The stories exercise the served SPA, so the client is built inside this step —
# `package-manager-install` plus a pinned node version, and `quinoa.ci` — and `-Dquarkus.quinoa=false`
# would take the thing under test away. The step also runs on `userflows-base` as `pwuser` rather
# than on `maven-base` as `build`, and wants 3600s rather than 2400. Four reasons, one slot.
release-request:
  - image: qits/build-images/node-docker-base:latest
    build: true
    timeout-seconds: 3600
    script: |
      origin_parent="${QITS_CI_REPOSITORY_URL%/*}"
      webui_dirs=""
      if [ -f .gitmodules ]; then
        for key in $(git config -f .gitmodules --name-only --get-regexp '^submodule\..*\.path$'); do
          name=${key#submodule.}
          name=${name%.path}
          path=$(git config -f .gitmodules --get "$key")
          git -c "submodule.$name.url=$origin_parent/$name" submodule update --init "$path"
          if [ -f "$path/package.json" ]; then
            webui_dirs="$webui_dirs $path"
          fi
        done
      fi
      npm_hosted_origin=$(node -p 'new URL(process.env.QITS_NPM_REGISTRY_URL).origin')
      npm_proxy_origin=$(node -p 'new URL(process.env.QITS_NPM_PROXY_URL).origin')
      npm_hosted_path=$(node -p 'new URL(process.env.QITS_NPM_REGISTRY_URL).pathname')
      for dir in $webui_dirs; do
        (
          cd "$dir"
          if [ -f package-lock.json ]; then
            sed -i -E \
              -e "s#(\"resolved\": \")https?://[^/\"]+#\1$npm_proxy_origin#" \
              -e "s#(\"resolved\": \")https?://[^/\"]+($npm_hosted_path)#\1$npm_hosted_origin\2#" \
              package-lock.json
          fi
          env npm_config_registry="$QITS_NPM_PROXY_URL" \
              "npm_config_@qits:registry=$QITS_NPM_REGISTRY_URL" \
              npm ci --no-audit --no-fund
          npm run build
        )
      done
      buildctl build --frontend dockerfile.v0 \
        --local context=. --local dockerfile=docker \
        --opt build-arg:QITS_MAVEN_REPOSITORY_URL="$QITS_MAVEN_REGISTRY_URL" \
        --opt build-arg:QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}" \
        --secret id=qits-client-id,src=/tmp/qits-client-id \
        --secret id=qits-client-secret,src=/tmp/qits-client-secret

  # `user: pwuser` and NOT a switch inside the script: a step container starts --cap-drop=ALL, so
  # `su` cannot switch user at all. userflows-base carries a passwd-backed non-root user.
  - image: qits/build-images/userflows-base:latest
    user: pwuser
    timeout-seconds: 3600
    script: |
      export QITS_MAVEN_REPOSITORY_URL="$QITS_MAVEN_REGISTRY_URL"
      export QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}"
      ./mvnw -B -ntp -s .qits-maven-settings.xml verify \
        -Dqits.maven.repository.url="$QITS_MAVEN_REPOSITORY_URL" \
        -Dquarkus.quinoa.package-manager-install=true \
        -Dquarkus.quinoa.package-manager-install.node-version=22.22.0 \
        -Dquarkus.quinoa.ci=true
      tar -czf /tmp/userstories.tgz -C service/target/userstories .
      status=$(curl -sS -o /tmp/docs-publish.out -w '%{http_code}' \
        -X PUT --data-binary @/tmp/userstories.tgz \
        -H "X-Artifacts-Meta-git.branch.name: $QITS_CI_BRANCH" \
        -H "X-Artifacts-Meta-git.commit.hash: $QITS_CI_SHA" \
        -H "X-Artifacts-Meta-git.repository.name: qits-artifacts" \
        "$QITS_DOCS_URL/@userflows/qits-artifacts/-/$QITS_CI_SHA")
      case "$status" in
        201) echo "published userflows for qits-artifacts@$QITS_CI_SHA ($QITS_CI_BRANCH)" ;;
        409) echo "userflows for qits-artifacts@$QITS_CI_SHA are already published — skipping" ;;
        *)   echo "docs publish failed: HTTP $status"; cat /tmp/docs-publish.out; exit 1 ;;
      esac
```

**Traps.** (1) **The story step must stay LAST** — everything after a failing step is SKIPPED, so
the ordering is the whole of what "a red verify must not cost the image" can mean: by the time a
story can fail, the step before it has already published. Ordering buys the image and nothing more.
The step itself gates like every other, and a red verify therefore costs the RELEASE — deliberately
(see `.config/qits/release-archetypes/java-service.yml`'s header, and the 2026-09-06 fourteen-hour
stall it records). (2) `userflows: qits-artifacts` is still declared even though this
slot does its own bundle: the key is what qits-projects reads, and it replaced a substring grep for
`@userflows/<site>` in the QA script — a grep that stops working the moment the script is composed.
(3) The release slot is the archetype's and pushes `qits/qits-artifacts`; this repository's store IS
the SBOM and docs destination, so an outage here is an outage of its own release.

## qits-docs-service — **overrides `release:`**

```yaml
archetype: java-service
artifacts:
  - { type: docker, name: qits/qits-docs, sbom: .sbom/sbom.json }
  - { type: docs, name: "@guides/qits-platform" }
userflows: qits-docs

# A SECOND PUBLICATION BESIDE THE IMAGE: `docs/guides/` is the platform's contract pages, and this
# is the one repository that may publish them. The site is the PLATFORM'S name, not this
# repository's, which is exactly why the entry is spelled. java-service publishes one image and
# nothing else, so the whole release slot is here.
release:
  - image: qits/build-images/node-docker-base:latest
    build: true
    timeout-seconds: 3600
    script: |
      declared=$(sed -n \
        's/^[[:space:]]*-[[:space:]]*{[[:space:]]*type:[[:space:]]*docker[[:space:]]*,[[:space:]]*name:[[:space:]]*\([^,}[:space:]]*\).*/\1/p' \
        .config/qits/release.yml)
      image=${declared#*/}
      ref="$QITS_BUILD_REGISTRY/$QITS_IMAGE_REPOSITORY/$image:$QITS_VERSION"
      echo "releasing $ref"

      origin_parent="${QITS_CI_REPOSITORY_URL%/*}"
      webui_dirs=""
      if [ -f .gitmodules ]; then
        for key in $(git config -f .gitmodules --name-only --get-regexp '^submodule\..*\.path$'); do
          name=${key#submodule.}
          name=${name%.path}
          path=$(git config -f .gitmodules --get "$key")
          git -c "submodule.$name.url=$origin_parent/$name" submodule update --init "$path"
          if [ -f "$path/package.json" ]; then
            webui_dirs="$webui_dirs $path"
          fi
        done
      fi
      npm_hosted_origin=$(node -p 'new URL(process.env.QITS_NPM_REGISTRY_URL).origin')
      npm_proxy_origin=$(node -p 'new URL(process.env.QITS_NPM_PROXY_URL).origin')
      npm_hosted_path=$(node -p 'new URL(process.env.QITS_NPM_REGISTRY_URL).pathname')
      for dir in $webui_dirs; do
        (
          cd "$dir"
          if [ -f package-lock.json ]; then
            sed -i -E \
              -e "s#(\"resolved\": \")https?://[^/\"]+#\1$npm_proxy_origin#" \
              -e "s#(\"resolved\": \")https?://[^/\"]+($npm_hosted_path)#\1$npm_hosted_origin\2#" \
              package-lock.json
          fi
          env npm_config_registry="$QITS_NPM_PROXY_URL" \
              "npm_config_@qits:registry=$QITS_NPM_REGISTRY_URL" \
              npm ci --no-audit --no-fund
          npm run build
        )
      done

      buildctl build --frontend dockerfile.v0 \
        --local context=. --local dockerfile=docker \
        --opt build-arg:QITS_MAVEN_REPOSITORY_URL="$QITS_MAVEN_REGISTRY_URL" \
        --opt build-arg:QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}" \
        --secret id=qits-client-id,src=/tmp/qits-client-id \
        --secret id=qits-client-secret,src=/tmp/qits-client-secret \
        --output "type=image,name=$ref,push=true"

      buildctl build --frontend dockerfile.v0 \
        --local context=. --local dockerfile=docker \
        --opt target=sbom \
        --opt build-arg:QITS_MAVEN_REPOSITORY_URL="$QITS_MAVEN_REGISTRY_URL" \
        --opt build-arg:QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}" \
        --secret id=qits-client-id,src=/tmp/qits-client-id \
        --secret id=qits-client-secret,src=/tmp/qits-client-secret \
        --output type=local,dest=.sbom

      # THE GUIDES BUNDLE. `-C docs/guides .` so the pages are the bundle's roots.
      tar -czf /tmp/guides.tgz -C docs/guides .
      qits-publish docs submit \
        --site "@guides/qits-platform" --version "$QITS_VERSION" --archive /tmp/guides.tgz \
        --meta git.commit.hash="$QITS_CI_SHA" \
        --meta git.repository.name=qits-docs
```

**Traps.** (1) **No `userflow-stories` file** — the pom decides. (2) The QA half needs no override:
this repository's gating step runs no `./mvnw` at all (the suite runs inside the image build's
builder stage, with no `-DskipTests`), which is what the archetype's gating step already does. (3)
Single-module: the stories land in `target/userstories`, which the recipe's
`find . -maxdepth 3 -path '*/target/userstories'` reaches. (4) The `docs` entry carries no `sbom:` —
a guides bundle has no bill of materials.

## qits-configuration-platform-service — **overrides `release-request:`**

```yaml
archetype: java-service
artifacts:
  - { type: docker, name: qits/qits-configuration, sbom: .sbom/sbom.json }
userflows: qits-configuration

# TWO FLAGS OUTSIDE THE RECIPE'S ALLOW-LIST: `-Dtest=SKIPNONE -Dsurefire.failIfNoSpecifiedTests=false`,
# which keep the UNIT suites out of the story run. The recipe composes `-Dit.test` from
# `.config/qits/userflow-stories` and passes nothing else, and a story selection alone would drag
# every surefire suite along with it here. Everything else in this slot IS the recipe's, verbatim.
release-request:
  - image: qits/build-images/node-docker-base:latest
    build: true
    timeout-seconds: 3600
    script: |
      origin_parent="${QITS_CI_REPOSITORY_URL%/*}"
      webui_dirs=""
      if [ -f .gitmodules ]; then
        for key in $(git config -f .gitmodules --name-only --get-regexp '^submodule\..*\.path$'); do
          name=${key#submodule.}
          name=${name%.path}
          path=$(git config -f .gitmodules --get "$key")
          git -c "submodule.$name.url=$origin_parent/$name" submodule update --init "$path"
          if [ -f "$path/package.json" ]; then
            webui_dirs="$webui_dirs $path"
          fi
        done
      fi
      npm_hosted_origin=$(node -p 'new URL(process.env.QITS_NPM_REGISTRY_URL).origin')
      npm_proxy_origin=$(node -p 'new URL(process.env.QITS_NPM_PROXY_URL).origin')
      npm_hosted_path=$(node -p 'new URL(process.env.QITS_NPM_REGISTRY_URL).pathname')
      for dir in $webui_dirs; do
        (
          cd "$dir"
          if [ -f package-lock.json ]; then
            sed -i -E \
              -e "s#(\"resolved\": \")https?://[^/\"]+#\1$npm_proxy_origin#" \
              -e "s#(\"resolved\": \")https?://[^/\"]+($npm_hosted_path)#\1$npm_hosted_origin\2#" \
              package-lock.json
          fi
          env npm_config_registry="$QITS_NPM_PROXY_URL" \
              "npm_config_@qits:registry=$QITS_NPM_REGISTRY_URL" \
              npm ci --no-audit --no-fund
          npm run build
        )
      done
      buildctl build --frontend dockerfile.v0 \
        --local context=. --local dockerfile=docker \
        --opt build-arg:QITS_MAVEN_REPOSITORY_URL="$QITS_MAVEN_REGISTRY_URL" \
        --opt build-arg:QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}" \
        --secret id=qits-client-id,src=/tmp/qits-client-id \
        --secret id=qits-client-secret,src=/tmp/qits-client-secret

  - image: qits/build-images/maven-base:latest
    user: build
    timeout-seconds: 2400
    script: |
      export QITS_MAVEN_REPOSITORY_URL="$QITS_MAVEN_REGISTRY_URL"
      export QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}"
      ./mvnw -B -ntp -s .qits-maven-settings.xml verify \
        -Dqits.maven.repository.url="$QITS_MAVEN_REPOSITORY_URL" \
        -Dquarkus.quinoa=false \
        -Dtest=SKIPNONE -Dsurefire.failIfNoSpecifiedTests=false \
        -DskipITs=false \
        "-Dit.test=TokenValidationBootstrapIT,ConfigurationImportIT,DeploymentConfigurationIT,OperatorEditIT,AccessRefusalIT,ImageReleasePinIT"
      stories_dir=$(find . -maxdepth 3 -type d -path '*/target/userstories' | head -1)
      : "${stories_dir:?the verify produced no */target/userstories}"
      tar -czf /tmp/userstories.tgz -C "$stories_dir" .
      status=$(curl -sS -o /tmp/docs-publish.out -w '%{http_code}' \
        -X PUT --data-binary @/tmp/userstories.tgz \
        -H "X-Artifacts-Meta-git.branch.name: $QITS_CI_BRANCH" \
        -H "X-Artifacts-Meta-git.commit.hash: $QITS_CI_SHA" \
        -H "X-Artifacts-Meta-git.repository.name: qits-configuration" \
        "$QITS_DOCS_URL/@userflows/qits-configuration/-/$QITS_CI_SHA")
      case "$status" in
        201) echo "published userflows for qits-configuration@$QITS_CI_SHA ($QITS_CI_BRANCH)" ;;
        409) echo "userflows for qits-configuration@$QITS_CI_SHA are already published — skipping" ;;
        *)   echo "docs publish failed: HTTP $status"; cat /tmp/docs-publish.out; exit 1 ;;
      esac
```

**Trap — the story list is INSIDE this slot, so there is NO `userflow-stories` file here.** Two
places holding one list is how a class silently stops running. If the two surefire flags are ever
dropped, delete the slot and add the file in the same commit — never both at once.

## qits-maintenance-platform-service — **overrides `release-request:`**

```yaml
archetype: java-service
artifacts:
  - { type: docker, name: qits/qits-platform-maintenance, sbom: .sbom/sbom.json }
userflows: true

# ONE FLAG OUTSIDE THE ALLOW-LIST: `-Dquarkus.http.test-port=0`. Both halves of this run bind a test
# port and a fixed one races itself; the repository's own AGENTS.md spells the gate command with it.
# The slot is otherwise the recipe verbatim — see the release-request in
# qits-configuration-platform-service above for the identical build half.
release-request:
  - image: qits/build-images/node-docker-base:latest
    build: true
    timeout-seconds: 3600
    script: |
      origin_parent="${QITS_CI_REPOSITORY_URL%/*}"
      webui_dirs=""
      if [ -f .gitmodules ]; then
        for key in $(git config -f .gitmodules --name-only --get-regexp '^submodule\..*\.path$'); do
          name=${key#submodule.}
          name=${name%.path}
          path=$(git config -f .gitmodules --get "$key")
          git -c "submodule.$name.url=$origin_parent/$name" submodule update --init "$path"
          if [ -f "$path/package.json" ]; then
            webui_dirs="$webui_dirs $path"
          fi
        done
      fi
      npm_hosted_origin=$(node -p 'new URL(process.env.QITS_NPM_REGISTRY_URL).origin')
      npm_proxy_origin=$(node -p 'new URL(process.env.QITS_NPM_PROXY_URL).origin')
      npm_hosted_path=$(node -p 'new URL(process.env.QITS_NPM_REGISTRY_URL).pathname')
      for dir in $webui_dirs; do
        (
          cd "$dir"
          if [ -f package-lock.json ]; then
            sed -i -E \
              -e "s#(\"resolved\": \")https?://[^/\"]+#\1$npm_proxy_origin#" \
              -e "s#(\"resolved\": \")https?://[^/\"]+($npm_hosted_path)#\1$npm_hosted_origin\2#" \
              package-lock.json
          fi
          env npm_config_registry="$QITS_NPM_PROXY_URL" \
              "npm_config_@qits:registry=$QITS_NPM_REGISTRY_URL" \
              npm ci --no-audit --no-fund
          npm run build
        )
      done
      buildctl build --frontend dockerfile.v0 \
        --local context=. --local dockerfile=docker \
        --opt build-arg:QITS_MAVEN_REPOSITORY_URL="$QITS_MAVEN_REGISTRY_URL" \
        --opt build-arg:QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}" \
        --secret id=qits-client-id,src=/tmp/qits-client-id \
        --secret id=qits-client-secret,src=/tmp/qits-client-secret

  - image: qits/build-images/maven-base:latest
    user: build
    timeout-seconds: 2400
    script: |
      export QITS_MAVEN_REPOSITORY_URL="$QITS_MAVEN_REGISTRY_URL"
      export QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}"
      ./mvnw -B -ntp -s .qits-maven-settings.xml verify \
        -Dqits.maven.repository.url="$QITS_MAVEN_REPOSITORY_URL" \
        -Dquarkus.http.test-port=0 \
        -Dquarkus.quinoa=false \
        -DskipITs=false \
        "-Dit.test=TokenValidationBootstrapIT,ScanCycleIT,InventoryIT,BumpIT,MaintenanceRefusalIT"
      stories_dir=$(find . -maxdepth 3 -type d -path '*/target/userstories' | head -1)
      : "${stories_dir:?the verify produced no */target/userstories}"
      tar -czf /tmp/userstories.tgz -C "$stories_dir" .
      status=$(curl -sS -o /tmp/docs-publish.out -w '%{http_code}' \
        -X PUT --data-binary @/tmp/userstories.tgz \
        -H "X-Artifacts-Meta-git.branch.name: $QITS_CI_BRANCH" \
        -H "X-Artifacts-Meta-git.commit.hash: $QITS_CI_SHA" \
        -H "X-Artifacts-Meta-git.repository.name: qits-maintenance-platform-service" \
        "$QITS_DOCS_URL/@userflows/qits-maintenance-platform-service/-/$QITS_CI_SHA")
      case "$status" in
        201) echo "published userflows@$QITS_CI_SHA ($QITS_CI_BRANCH)" ;;
        409) echo "userflows@$QITS_CI_SHA are already published — skipping" ;;
        *)   echo "docs publish failed: HTTP $status"; cat /tmp/docs-publish.out; exit 1 ;;
      esac
```

**Trap.** The story list lives in this slot, so **no `userflow-stories` file here either**. And this
repository's bump pipeline is the estate's only live pusher — a broken gate here stops dependency
bumps platform-wide, so land it on a quiet day.

## qits-mirror-platform-service — **overrides BOTH slots**

```yaml
archetype: java-service
artifacts:
  - { type: docker, name: qits/qits-platform-mirror, sbom: .sbom/sbom.json }
userflows: true

# THE MIRROR MAY NOT BUILD THROUGH THE MIRROR. Both builds pass
# `--opt build-arg:QITS_MAVEN_CENTRAL_URL=""` — a LITERAL empty string, not `${QITS_MAVEN_PROXY_URL:-}`
# — which deactivates the settings profile so Central is dialled directly. The recipe passes the
# proxy, which is this service itself: a deployment being replaced would be asked to proxy its own
# replacement's build. The empty value is the off switch and it is the whole reason both slots are
# here. The QA story step also wants 3600s rather than 2400 (the pull-through suites are slow).
release-request:
  - image: qits/build-images/node-docker-base:latest
    build: true
    timeout-seconds: 3600
    script: |
      origin_parent="${QITS_CI_REPOSITORY_URL%/*}"
      webui_dirs=""
      if [ -f .gitmodules ]; then
        for key in $(git config -f .gitmodules --name-only --get-regexp '^submodule\..*\.path$'); do
          name=${key#submodule.}
          name=${name%.path}
          path=$(git config -f .gitmodules --get "$key")
          git -c "submodule.$name.url=$origin_parent/$name" submodule update --init "$path"
          if [ -f "$path/package.json" ]; then
            webui_dirs="$webui_dirs $path"
          fi
        done
      fi
      npm_hosted_origin=$(node -p 'new URL(process.env.QITS_NPM_REGISTRY_URL).origin')
      npm_proxy_origin=$(node -p 'new URL(process.env.QITS_NPM_PROXY_URL).origin')
      npm_hosted_path=$(node -p 'new URL(process.env.QITS_NPM_REGISTRY_URL).pathname')
      for dir in $webui_dirs; do
        (
          cd "$dir"
          if [ -f package-lock.json ]; then
            sed -i -E \
              -e "s#(\"resolved\": \")https?://[^/\"]+#\1$npm_proxy_origin#" \
              -e "s#(\"resolved\": \")https?://[^/\"]+($npm_hosted_path)#\1$npm_hosted_origin\2#" \
              package-lock.json
          fi
          env npm_config_registry="$QITS_NPM_PROXY_URL" \
              "npm_config_@qits:registry=$QITS_NPM_REGISTRY_URL" \
              npm ci --no-audit --no-fund
          npm run build
        )
      done
      buildctl build --frontend dockerfile.v0 \
        --local context=. --local dockerfile=docker \
        --opt build-arg:QITS_MAVEN_REPOSITORY_URL="$QITS_MAVEN_REGISTRY_URL" \
        --opt build-arg:QITS_MAVEN_CENTRAL_URL="" \
        --secret id=qits-client-id,src=/tmp/qits-client-id \
        --secret id=qits-client-secret,src=/tmp/qits-client-secret

  - image: qits/build-images/maven-base:latest
    user: build
    timeout-seconds: 3600
    script: |
      export QITS_MAVEN_REPOSITORY_URL="$QITS_MAVEN_REGISTRY_URL"
      export QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}"
      ./mvnw -B -ntp -s .qits-maven-settings.xml verify \
        -Dqits.maven.repository.url="$QITS_MAVEN_REPOSITORY_URL" \
        -Dquarkus.quinoa=false \
        -DskipITs=false \
        "-Dit.test=PullThroughBootstrapIT,MavenPullThroughIT,NpmInstallThroughTheMirrorIT,ImagePullThroughIT,CacheInventoryIT,StaleThroughAnOutageIT,UpstreamRefusalIT"
      # SINGLE-MODULE: the stories land in target/userstories.
      tar -czf /tmp/userstories.tgz -C target/userstories .
      status=$(curl -sS -o /tmp/docs-publish.out -w '%{http_code}' \
        -X PUT --data-binary @/tmp/userstories.tgz \
        -H "X-Artifacts-Meta-git.branch.name: $QITS_CI_BRANCH" \
        -H "X-Artifacts-Meta-git.commit.hash: $QITS_CI_SHA" \
        -H "X-Artifacts-Meta-git.repository.name: qits-mirror-platform-service" \
        "$QITS_DOCS_URL/@userflows/qits-mirror-platform-service/-/$QITS_CI_SHA")
      case "$status" in
        201) echo "published userflows@$QITS_CI_SHA ($QITS_CI_BRANCH)" ;;
        409) echo "userflows@$QITS_CI_SHA are already published — skipping" ;;
        *)   echo "docs publish failed: HTTP $status"; cat /tmp/docs-publish.out; exit 1 ;;
      esac

release:
  - image: qits/build-images/node-docker-base:latest
    build: true
    timeout-seconds: 3600
    script: |
      declared=$(sed -n \
        's/^[[:space:]]*-[[:space:]]*{[[:space:]]*type:[[:space:]]*docker[[:space:]]*,[[:space:]]*name:[[:space:]]*\([^,}[:space:]]*\).*/\1/p' \
        .config/qits/release.yml)
      image=${declared#*/}
      ref="$QITS_BUILD_REGISTRY/$QITS_IMAGE_REPOSITORY/$image:$QITS_VERSION"
      echo "releasing $ref"

      origin_parent="${QITS_CI_REPOSITORY_URL%/*}"
      webui_dirs=""
      if [ -f .gitmodules ]; then
        for key in $(git config -f .gitmodules --name-only --get-regexp '^submodule\..*\.path$'); do
          name=${key#submodule.}
          name=${name%.path}
          path=$(git config -f .gitmodules --get "$key")
          git -c "submodule.$name.url=$origin_parent/$name" submodule update --init "$path"
          if [ -f "$path/package.json" ]; then
            webui_dirs="$webui_dirs $path"
          fi
        done
      fi
      npm_hosted_origin=$(node -p 'new URL(process.env.QITS_NPM_REGISTRY_URL).origin')
      npm_proxy_origin=$(node -p 'new URL(process.env.QITS_NPM_PROXY_URL).origin')
      npm_hosted_path=$(node -p 'new URL(process.env.QITS_NPM_REGISTRY_URL).pathname')
      for dir in $webui_dirs; do
        (
          cd "$dir"
          if [ -f package-lock.json ]; then
            sed -i -E \
              -e "s#(\"resolved\": \")https?://[^/\"]+#\1$npm_proxy_origin#" \
              -e "s#(\"resolved\": \")https?://[^/\"]+($npm_hosted_path)#\1$npm_hosted_origin\2#" \
              package-lock.json
          fi
          env npm_config_registry="$QITS_NPM_PROXY_URL" \
              "npm_config_@qits:registry=$QITS_NPM_REGISTRY_URL" \
              npm ci --no-audit --no-fund
          npm run build
        )
      done

      # BYTE-IDENTICAL TO THE QA BUILD ABOVE, EMPTY CENTRAL URL INCLUDED, plus the --output.
      buildctl build --frontend dockerfile.v0 \
        --local context=. --local dockerfile=docker \
        --opt build-arg:QITS_MAVEN_REPOSITORY_URL="$QITS_MAVEN_REGISTRY_URL" \
        --opt build-arg:QITS_MAVEN_CENTRAL_URL="" \
        --secret id=qits-client-id,src=/tmp/qits-client-id \
        --secret id=qits-client-secret,src=/tmp/qits-client-secret \
        --output "type=image,name=$ref,push=true"

      buildctl build --frontend dockerfile.v0 \
        --local context=. --local dockerfile=docker \
        --opt target=sbom \
        --opt build-arg:QITS_MAVEN_REPOSITORY_URL="$QITS_MAVEN_REGISTRY_URL" \
        --opt build-arg:QITS_MAVEN_CENTRAL_URL="" \
        --secret id=qits-client-id,src=/tmp/qits-client-id \
        --secret id=qits-client-secret,src=/tmp/qits-client-secret \
        --output type=local,dest=.sbom
```

**Trap.** Story list is in the slot; **no `userflow-stories` file**. And every other repository's
build resolves Central *through this service* — a release here that goes wrong takes the whole
estate's Maven and npm resolution with it.

## qits-containers-service — **overrides BOTH slots**

```yaml
archetype: java-service
artifacts:
  - { type: maven, name: "eu.wohlben.qits:qits-containers-core", sbom: core/target/sbom.json }
  - { type: maven, name: "eu.wohlben.qits:qits-containers-client", sbom: client/target/sbom.json }
  - { type: docker, name: qits/qits-containers, sbom: .sbom/sbom.json }
userflows: qits-containers

# TWO JARS AND AN IMAGE. maven-library's header names this repository as the case that is neither
# archetype: the image half is java-service's and the jar half is maven-library's, and no recipe
# does both. The QA half is three steps rather than two — a unit gate on `maven-base` as `build`
# BEFORE the image builds, because a broken jar must not cost a native compile.
release-request:
  - image: qits/build-images/maven-base:latest
    user: build
    timeout-seconds: 1800
    script: |
      export QITS_MAVEN_REPOSITORY_URL="$QITS_MAVEN_REGISTRY_URL"
      export QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}"
      ./mvnw -B -ntp -s .qits-maven-settings.xml verify \
        -Dqits.maven.repository.url="$QITS_MAVEN_REPOSITORY_URL"

  - image: qits/build-images/ci-base:latest
    build: true
    timeout-seconds: 3600
    script: |
      buildctl build --frontend dockerfile.v0 \
        --local context=. --local dockerfile=docker \
        --opt build-arg:QITS_MAVEN_REPOSITORY_URL="$QITS_MAVEN_REGISTRY_URL" \
        --opt build-arg:QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}" \
        --secret id=qits-client-id,src=/tmp/qits-client-id \
        --secret id=qits-client-secret,src=/tmp/qits-client-secret

  - image: qits/build-images/maven-base:latest
    user: build
    timeout-seconds: 2400
    script: |
      export QITS_MAVEN_REPOSITORY_URL="$QITS_MAVEN_REGISTRY_URL"
      export QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}"
      ./mvnw -B -ntp -s .qits-maven-settings.xml verify \
        -Dqits.maven.repository.url="$QITS_MAVEN_REPOSITORY_URL" \
        -DskipITs=false \
        "-Dit.test=TokenValidationBootstrapIT,HostBootstrapIT,WorkloadLifecycleIT,OwnershipBoundaryIT,WorkloadReapIT,AccessRefusalIT"
      stories_dir=$(find . -maxdepth 3 -type d -path '*/target/userstories' | head -1)
      : "${stories_dir:?the verify produced no */target/userstories}"
      tar -czf /tmp/userstories.tgz -C "$stories_dir" .
      status=$(curl -sS -o /tmp/docs-publish.out -w '%{http_code}' \
        -X PUT --data-binary @/tmp/userstories.tgz \
        -H "X-Artifacts-Meta-git.branch.name: $QITS_CI_BRANCH" \
        -H "X-Artifacts-Meta-git.commit.hash: $QITS_CI_SHA" \
        -H "X-Artifacts-Meta-git.repository.name: qits-containers" \
        "$QITS_DOCS_URL/@userflows/qits-containers/-/$QITS_CI_SHA")
      case "$status" in
        201) echo "published userflows for qits-containers@$QITS_CI_SHA ($QITS_CI_BRANCH)" ;;
        409) echo "userflows for qits-containers@$QITS_CI_SHA are already published — skipping" ;;
        *)   echo "docs publish failed: HTTP $status"; cat /tmp/docs-publish.out; exit 1 ;;
      esac

release:
  - image: qits/build-images/maven-base:latest
    timeout-seconds: 1800
    script: |
      export QITS_MAVEN_REPOSITORY_URL="$QITS_MAVEN_REGISTRY_URL"
      export QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}"
      # `-pl .,core,client`: the root pom is deployed as the two modules' parent and is deliberately
      # not a declared artifact. makeBom then runs `-pl core,client`, which is where the two
      # declared `sbom:` paths above come from.
      ./mvnw -B -ntp -s .qits-maven-settings.xml -pl .,core,client deploy -DskipTests \
        -Dqits.maven.repository.url="$QITS_MAVEN_REGISTRY_URL" \
        -DaltDeploymentRepository="qits::default::$QITS_MAVEN_REGISTRY_URL"
      ./mvnw -B -ntp -s .qits-maven-settings.xml -pl core,client -DskipTests \
        org.cyclonedx:cyclonedx-maven-plugin:2.9.1:makeBom \
        -DoutputFormat=json -DoutputName=sbom -DschemaVersion=1.6 \
        -Dqits.maven.repository.url="$QITS_MAVEN_REGISTRY_URL"

  - image: qits/build-images/ci-base:latest
    build: true
    timeout-seconds: 3600
    script: |
      declared=$(sed -n \
        's/^[[:space:]]*-[[:space:]]*{[[:space:]]*type:[[:space:]]*docker[[:space:]]*,[[:space:]]*name:[[:space:]]*\([^,}[:space:]]*\).*/\1/p' \
        .config/qits/release.yml)
      image=${declared#*/}
      ref="$QITS_BUILD_REGISTRY/$QITS_IMAGE_REPOSITORY/$image:$QITS_VERSION"
      echo "releasing $ref"
      buildctl build --frontend dockerfile.v0 \
        --local context=. --local dockerfile=docker \
        --opt build-arg:QITS_MAVEN_REPOSITORY_URL="$QITS_MAVEN_REGISTRY_URL" \
        --opt build-arg:QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}" \
        --secret id=qits-client-id,src=/tmp/qits-client-id \
        --secret id=qits-client-secret,src=/tmp/qits-client-secret \
        --output "type=image,name=$ref,push=true"
      buildctl build --frontend dockerfile.v0 \
        --local context=. --local dockerfile=docker \
        --opt target=sbom \
        --opt build-arg:QITS_MAVEN_REPOSITORY_URL="$QITS_MAVEN_REGISTRY_URL" \
        --opt build-arg:QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}" \
        --secret id=qits-client-id,src=/tmp/qits-client-id \
        --secret id=qits-client-secret,src=/tmp/qits-client-secret \
        --output type=local,dest=.sbom
```

**Traps.** (1) **The jar step goes FIRST in `release:`.** The postlude submits SBOMs on the last
building step, so the jars' documents must exist before the image step ends — and the image build
resolves nothing from this deploy, so the order is free. (2) No `userflow-stories` file: the list is
in the slot. (3) **qits-ci runs every step of every pipeline through this service.** A release that
goes wrong stops all CI; land it with the `extended` gates run by hand first.

## qits-ci-service — **overrides `release:`** — LAST

```yaml
archetype: java-service
artifacts:
  - { type: docker, name: qits/qits-ci, sbom: .sbom/sbom.json }
  - { type: docs, name: "@apidocs/qits-ci" }
userflows: qits-ci

# A SECOND PUBLICATION BESIDE THE IMAGE: `docs/openapi.yml` goes up as `@apidocs/qits-ci` at the
# released version. java-service pushes one image and publishes nothing else, so this slot is here.
# THE QA SLOT IS NOT OVERRIDDEN: `-Dit.test` is composed from `.config/qits/userflow-stories`
# beside this file, which is what keeps the three `extended` docker gates from running on a step
# container and failing there — the flag survives the migration as a FILE, not as a sixth key.
release:
  - image: qits/build-images/node-docker-base:latest
    build: true
    timeout-seconds: 3600
    script: |
      declared=$(sed -n \
        's/^[[:space:]]*-[[:space:]]*{[[:space:]]*type:[[:space:]]*docker[[:space:]]*,[[:space:]]*name:[[:space:]]*\([^,}[:space:]]*\).*/\1/p' \
        .config/qits/release.yml)
      image=${declared#*/}
      ref="$QITS_BUILD_REGISTRY/$QITS_IMAGE_REPOSITORY/$image:$QITS_VERSION"
      echo "releasing $ref"

      origin_parent="${QITS_CI_REPOSITORY_URL%/*}"
      webui_dirs=""
      if [ -f .gitmodules ]; then
        for key in $(git config -f .gitmodules --name-only --get-regexp '^submodule\..*\.path$'); do
          name=${key#submodule.}
          name=${name%.path}
          path=$(git config -f .gitmodules --get "$key")
          git -c "submodule.$name.url=$origin_parent/$name" submodule update --init "$path"
          if [ -f "$path/package.json" ]; then
            webui_dirs="$webui_dirs $path"
          fi
        done
      fi
      npm_hosted_origin=$(node -p 'new URL(process.env.QITS_NPM_REGISTRY_URL).origin')
      npm_proxy_origin=$(node -p 'new URL(process.env.QITS_NPM_PROXY_URL).origin')
      npm_hosted_path=$(node -p 'new URL(process.env.QITS_NPM_REGISTRY_URL).pathname')
      for dir in $webui_dirs; do
        (
          cd "$dir"
          if [ -f package-lock.json ]; then
            sed -i -E \
              -e "s#(\"resolved\": \")https?://[^/\"]+#\1$npm_proxy_origin#" \
              -e "s#(\"resolved\": \")https?://[^/\"]+($npm_hosted_path)#\1$npm_hosted_origin\2#" \
              package-lock.json
          fi
          env npm_config_registry="$QITS_NPM_PROXY_URL" \
              "npm_config_@qits:registry=$QITS_NPM_REGISTRY_URL" \
              npm ci --no-audit --no-fund
          npm run build
        )
      done

      buildctl build --frontend dockerfile.v0 \
        --local context=. --local dockerfile=docker \
        --opt build-arg:QITS_MAVEN_REPOSITORY_URL="$QITS_MAVEN_REGISTRY_URL" \
        --opt build-arg:QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}" \
        --secret id=qits-client-id,src=/tmp/qits-client-id \
        --secret id=qits-client-secret,src=/tmp/qits-client-secret \
        --output "type=image,name=$ref,push=true"

      buildctl build --frontend dockerfile.v0 \
        --local context=. --local dockerfile=docker \
        --opt target=sbom \
        --opt build-arg:QITS_MAVEN_REPOSITORY_URL="$QITS_MAVEN_REGISTRY_URL" \
        --opt build-arg:QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}" \
        --secret id=qits-client-id,src=/tmp/qits-client-id \
        --secret id=qits-client-secret,src=/tmp/qits-client-secret \
        --output type=local,dest=.sbom

      # ONE DOCUMENT, THE SECOND DECLARED ARTIFACT. `docs/openapi.yml` is committed and regenerated
      # by OpenApiSchemaExportTest, so the release's API surface is one tar and one submit.
      tar -czf /tmp/apidocs.tgz -C docs openapi.yml
      qits-publish docs submit \
        --site "@apidocs/qits-ci" --version "$QITS_VERSION" --archive /tmp/apidocs.tgz \
        --meta git.commit.hash="$QITS_CI_SHA" \
        --meta git.repository.name="$QITS_CI_REPO_NAME"
```

Also commit `.config/qits/userflow-stories`:

```
TokenValidationBootstrapIT
BuildExecutionIT
BuildTriggerIT
```

**Traps, and this repository gets the last slot of the campaign for all of them.**
(1) **`-Dit.test` is not optional here.** Without the list, `-DskipITs=false` pulls in
`CiDaemonHandshakeIT`, `CiDaemonGateIT` and `CiPackagedSurfaceIT`, which need a docker daemon, a
published daemon binary and a host-gateway route back to the JVM — none of which a step container
is. The list is the migration's own dependency: **write `userflow-stories` first, confirm a QA run
composes `-Dit.test=` with all three names, then delete the pair.**
(2) **This repository is the composer.** It reads `release.yml`, reads the wrapper's archetypes, and
composes both documents; a release that goes wrong here cannot be fixed by a pipeline, because the
thing that runs pipelines is what broke. Every other entry in this manifest depends on it working.
(3) **A retry re-composes the platform half at the run's own commit**, so a fixed prelude heals an
older failed release by retry — which is the loop the rest of this campaign relies on. Do not break
it by being the last thing to migrate and the first thing to be wrong.
(4) The `docs` entry carries no `sbom:` — an OpenAPI bundle has no bill of materials.

---

# All 49 repositories

| # | Repository | State |
|---|---|---|
| 1 | qits-coding-agents | migrated (`maven-library`) |
| 2 | qits-database-oci | migrated (`oci`) |
| 3 | qits-observability-frontend | migrated (`spa-frontend`) |
| 4 | qits-eventstream-javalib | Batch 1 |
| 5 | qits-integrations-quarkus-javalib | Batch 1 |
| 6 | qits-registries-javalib | Batch 1 |
| 7 | qits-userflows-javalib | Batch 1 |
| 8 | qits-integrations-angular-jslib | Batch 1 |
| 9 | qits-ui-components-jslib | Batch 1 |
| 10 | qits-artifacts-frontend | Batch 2 |
| 11 | qits-ci-frontend | Batch 2 |
| 12 | qits-configuration-platform-frontend | Batch 2 |
| 13 | qits-deployments-platform-frontend | Batch 2 |
| 14 | qits-docs-frontend | Batch 2 |
| 15 | qits-events-platform-frontend | Batch 2 |
| 16 | qits-githost-frontend | Batch 2 |
| 17 | qits-idp-platform-frontend | Batch 2 |
| 18 | qits-maintenance-platform-frontend | Batch 2 |
| 19 | qits-mirror-platform-frontend | Batch 2 |
| 20 | qits-orchestrator-platform-frontend | Batch 2 |
| 21 | qits-projects-frontend | Batch 2 |
| 22 | qits-system-platform-frontend | Batch 2 |
| 23 | qits-workspaces-frontend | Batch 2 |
| 24 | qits-ci-daemon | Batch 3 |
| 25 | qits-projects-daemon | Batch 3 |
| 26 | qits-workspace-daemon | Batch 3 |
| 27 | qits-build-images-oci | Batch 3 |
| 28 | qits-workspace-editor-oci | Batch 3 |
| 29 | qits-workspace-oci | Batch 3 |
| 30 | qits-bootstrap-cli | Batch 3 |
| 31 | qits-platform-access-cli | Batch 3 |
| 32 | qits-idp-platform-service | Batch 4 |
| 33 | qits-deployments-platform-service | Batch 4 |
| 34 | qits-events-platform-service | Batch 4 |
| 35 | qits-orchestrator-platform-service | Batch 4 |
| 36 | qits-system-platform-service | Batch 4 |
| 37 | qits-edge-platform-service | Batch 4 |
| 38 | qits-projects-service | Batch 4 |
| 39 | qits-observability-service | Batch 4 |
| 40 | qits-githost-service | Batch 4 |
| 41 | qits-workspaces-service | Batch 4 |
| 42 | qits-stt-service | Batch 4 |
| 43 | qits-artifacts-service | Batch 4 |
| 44 | qits-docs-service | Batch 4 |
| 45 | qits-configuration-platform-service | Batch 4 |
| 46 | qits-maintenance-platform-service | Batch 4 |
| 47 | qits-mirror-platform-service | Batch 4 |
| 48 | qits-containers-service | Batch 4 |
| 49 | qits-ci-service | Batch 4 — LAST |

**All 49 are submodules of this wrapper** (49 `[submodule]` entries in `.gitmodules`, 49 directories
under `components/<component>/<repo>`); none is "not a submodule".

## Override summary

| Overrides | Repositories |
|---|---|
| none — archetype whole | 6 javalib/jslib (minus 2 below), 14 frontends, qits-bootstrap-cli, 13 services |
| `release-request:` only | qits-integrations-quarkus-javalib, qits-ci-daemon, qits-artifacts-service, qits-configuration-platform-service, qits-maintenance-platform-service |
| `release:` only | qits-docs-service, qits-ci-service |
| both slots | qits-userflows-javalib, qits-projects-daemon, qits-workspace-daemon, qits-build-images-oci, qits-workspace-editor-oci, qits-workspace-oci, qits-platform-access-cli, qits-mirror-platform-service, qits-containers-service |

## `.config/qits/userflow-stories` — the sibling file this migration also writes

Ten services get one (the four other list-carrying services keep their list inside an overridden
slot instead): `qits-ci-service`, `qits-idp-platform-service`, `qits-deployments-platform-service`,
`qits-events-platform-service`, `qits-orchestrator-platform-service`,
`qits-system-platform-service`, `qits-edge-platform-service`, `qits-projects-service`,
`qits-observability-service`, `qits-workspaces-service`. Four services carry their list INSIDE an overridden
`release-request:` slot instead, so they must NOT also get the file — two places holding one list is
how a class silently stops running: `qits-configuration-platform-service`,
`qits-maintenance-platform-service`, `qits-mirror-platform-service`, `qits-containers-service`.

Four services get no list at all, on purpose — their poms decide which ITs run, which the archetype
documents as the better shape: `qits-artifacts-service`, `qits-docs-service`, `qits-githost-service`,
`qits-stt-service`.
