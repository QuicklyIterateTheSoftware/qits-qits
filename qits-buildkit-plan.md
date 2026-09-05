# Image builds through a platform-owned BuildKit, not the host docker

Status: **implemented in refinement, unproven against a live platform** — see "Status as shipped"
and "Handoff" below.

Today every image build on the platform runs on the **host docker daemon**: a CI step declares
`docker: true`, qits-containers mounts `/var/run/docker.sock`, and the step's `docker build`
is root-equivalent on the host. The builds also lean on host-side accidents — `--network host`
so a `RUN` can reach the edge vhosts on the host loopback, and the daemon's `registry-mirrors`
so unqualified `FROM` lines resolve. This plan moves the builds to one **platform-owned
buildkitd container**, reached over the platform network, so a build is a contained workload
like everything else and the socket can eventually stop being mounted at all.

## Contracts

### The builder container

| what | value | owner |
|---|---|---|
| container / network alias | `qits-buildkitd` on `qits-net` | qits-containers (registry row: owner `qits-containers`, workload `buildkit`, ref `buildkitd`) |
| address | `tcp://qits-buildkitd:1234` | the one spelling every consumer uses |
| image | `moby/buildkit:v0.33.0`, resolved by the host daemon through its `registry-mirrors` (the mirror's `hub` namespace) | pin in qits-containers config, `qits.containers.buildkit.image` |
| state | named volume `qits-buildkitd-state` at `/var/lib/buildkit` | created with the row, so `VolumeGc` classes it `LIVE_ROW` |
| privilege | `--privileged`, `oom-score-adj 500`, `pids-limit 4096`, no memory cap | see decisions |
| lifecycle | `EXPLICIT` policy → `--restart unless-stopped`, no idle sweep, no max age | qits-containers boot ensures it; the observer's two-strike demotion is the liveness check |

`buildkitd.toml` reaches the container the way every platform file reaches a container that
cannot be handed one: an `sh -c` prelude writes it from an environment value and `exec`s
buildkitd (the `BOOTSTRAP` / `QITS_CI_REGISTRY_AUTH_CONFIG` idiom). Its content is rendered
from qits-containers config, not committed as a file.

### Registry config (buildkitd.toml)

The committed Dockerfiles keep their `FROM` lines. The edge vhosts they name are resolvable
only from the host namespace, so buildkitd carries the rewrite:

    [registry."registry.dev.localhost:8080"]  mirrors = ["qits-platform-artifacts:8080"]
    [registry."mirror.dev.localhost:8080"]    mirrors = ["qits-platform-mirror:8080"]
    [registry."localhost:8081"]               mirrors = ["qits-platform-artifacts:8080"]
    [registry."localhost:8082"]               mirrors = ["qits-platform-mirror:8080"]
    [registry."qits-platform-artifacts:8080"] http = true
    [registry."qits-platform-mirror:8080"]    http = true

(The mirror serves `/v2/{hub,quay,redhat}/…`, so a `mirror.dev.localhost:8080/quay/…`
reference keeps its repository path unchanged under the rewrite. `docker.io` is deliberately
NOT mapped: no committed Dockerfile pulls a bare Hub name, and the host daemon's
`registry-mirrors` no longer applies once a build leaves it — a bare `FROM alpine` under
buildctl resolves Docker Hub directly, which the offline posture forbids; spell the mirror.)

Plus the storage bound: `[worker.oci] gc keepstorage = 20 GB` (decision below).

### What a step sees (the environment)

- `BUILDKIT_HOST=tcp://qits-buildkitd:1234` — injected by **qits-containers** into every
  workload spec that declared the docker socket (`hostDockerSocket=true`), *unless the caller
  already sent the key* (caller wins). Rationale: a workload that asked for the socket is a
  workload that builds; the address is qits-containers' deployment fact, exactly as the socket
  path is. The address is discovery, not privilege — any container on qits-net can dial the
  alias; the privilege boundary is network membership, and it is a bounded one (a build `RUN`
  is root inside buildkitd's container, never on the host).
- `QITS_BUILD_REGISTRY=qits-platform-artifacts:8080` — injected by **qits-ci** on
  `docker: true` steps: the registry *as the builder resolves it*, i.e. what a push ref is
  composed from (`$QITS_BUILD_REGISTRY/$QITS_IMAGE_REPOSITORY/<app>:<tag>`). `$QITS_REGISTRY`
  stays what it was — the host daemon's view — for the unconverted fleet.
- The run's commissioned credential, `DOCKER_CONFIG` and the auth document are unchanged;
  the document additionally names the build registry host, since buildctl picks a login by
  hostname exactly as the docker CLI does.

### The kill switch

`qits.ci.buildkit.enabled` (default **true**; `QITS_CI_BUILDKIT_ENABLED=false` on the qits-ci
deployment is the lever). Off, qits-ci injects `BUILDKIT_HOST=` and `QITS_BUILD_REGISTRY=`
**empty** — empty-never-absent is the platform's established off value (the mirror pair does
the same) — and an empty caller-sent `BUILDKIT_HOST` suppresses qits-containers' injection,
because the injection defers to any present key. Effect: unconverted recipes are untouched
(they never read either variable); converted recipes fail **loudly** at the first buildctl
call instead of silently building through the host socket. Reverting one repository is
reverting its recipe commit. qits-containers has its own infrastructure half,
`qits.containers.buildkit.enabled`, which stops owning the container and stops injecting.

### The buildctl invocation (the recipe shape)

    ref="$QITS_BUILD_REGISTRY/$QITS_IMAGE_REPOSITORY/<app>:<tag>"
    buildctl build --frontend dockerfile.v0 \
      --local context=. --local dockerfile=docker \
      --opt build-arg:QITS_MAVEN_CENTRAL_URL="${QITS_MAVEN_PROXY_URL:-}" \
      --secret id=qits-client-id,env=QITS_COMMISSIONED_CLIENT_ID \
      --secret id=qits-client-secret,env=QITS_COMMISSIONED_CLIENT_SECRET \
      --output type=image,name="$ref",push=true

- `buildctl` reads `$BUILDKIT_HOST` itself; no `--addr` is spelled.
- **No `--network host`**, and no equivalent: a `RUN` executes in buildkitd's network
  namespace on qits-net, so anything a build dials uses the **in-network** address —
  `$QITS_MAVEN_PROXY_URL`, not `$QITS_MAVEN_CENTRAL_MIRROR_URL` (that one is an edge vhost on
  the host loopback and is now unreachable from a build, by design).
- `push=true` replaces `docker push`: the image never enters any local store, so the
  one-build-one-tag rule loses its second half (there is no local store to leave an alias
  out of) but keeps its first (one build, one name).
- The SBOM export is the same invocation with `--opt target=sbom --output
  type=local,dest=.sbom` — same buildkitd, so every layer is a cache hit as before.
- Dockerfile secret mounts use the **file form** (`--mount=type=secret,id=…` read as
  `$(cat /run/secrets/…)`), never the `env=` mount form: the file form is the shape every
  dockerfile-frontend version serves, so a recipe is not coupled to the builder's frontend.

### Version pin

`v0.33.0` (latest stable, June 2026) in three places, each machine-readable where the bytes
are consumed: the buildkitd image (`qits.containers.buildkit.image` default), `buildctl` in
the step images (a `FROM moby/buildkit:v0.33.0 AS buildkit` stage + `COPY --from`, pulled
through the mirror — never a curl to GitHub, which would bypass the offline posture), and the
bootstrap (which reads no second copy: it runs the same image). Client/daemon skew within one
minor is fine; bump them in one campaign anyway.

### Resource caps

Container-level: no memory cap (a native compile wants ~6 GB and the step containers already
carry the per-step caps), `pids-limit 4096`, `oom-score-adj 500` so the kernel takes
buildkitd before a platform service. Build-level: `[worker.oci] max-parallelism` left at
default. Storage: gc `keepstorage` 20 GB in buildkitd.toml, plus the orchestrator-driven
`POST /containers/api/gc/build-cache` sweep extends to the owned buildkitd (the existing
`docker exec <builder> buildctl prune` argv, pointed at `qits-buildkitd` as well).

## Migration order

1. **qits-containers** ships the container, the injection and the gc extension. Nothing
   consumes it yet; the fleet is unchanged.
2. **qits-build-images** ships buildctl in `ci-base` and `node-docker-base` (the only two
   images `docker: true` steps use, verified estate-wide). Unconverted recipes ignore it.
3. **qits-ci** ships the kill switch and `QITS_BUILD_REGISTRY`.
4. Recipes convert **repo by repo**, `qits-workspace-daemon` first (this epic's
   representative: both its pipeline files and its Dockerfile — the two files' builds must
   stay byte-matched for the cache, so they convert together).
5. **qits-bootstrap-cli** moves its seed/toolchain/musl builds onto the same buildkitd and
   deletes the buildx builder.
6. End state (a later campaign, not this epic): a `build: true` step key that grants
   `BUILDKIT_HOST` *without* the socket; converted recipes swap `docker: true` for it;
   `docker: true` becomes the exception it should be. Until then a converted recipe keeps
   declaring `docker: true` — the privilege stays declared and diff-visible even though the
   script no longer uses the socket.

## What changes in each repository

- **qits-containers-service** — `Security` gains `privileged` (rendered `--privileged`;
  wire restated on both sides); a boot-time `PlatformBuildkit` ensures the row + container
  (the `SharedResources` slot, LaunchMode-guarded, never fails a boot); `ContainerRegistry`
  injects `BUILDKIT_HOST` into socket-holding specs; `BuildCacheGc` prunes the owned
  buildkitd; config keys `qits.containers.buildkit.{enabled,image,address,volume,…}`.
- **qits-build-images-oci** — a pinned buildkit stage in `ci-base` and `node-docker-base`,
  `COPY --from` of `/usr/bin/buildctl`.
- **qits-ci-service** — `qits.ci.buildkit.enabled` + `qits.ci.buildkit.registry-host`;
  the docker-step env block adds `QITS_BUILD_REGISTRY` (and the empty-pair off state); the
  auth document names the build registry; contract tests updated.
- **qits-workspace-daemon** — both `.config/qits/ci-event-*.yml` build steps to buildctl
  (push by digest-stable ref, SBOM by `--output type=local`), Dockerfile secret mounts to
  file form. `FROM` lines and the maintenance-owned base pin unchanged.
- **qits-bootstrap-cli** — boot creates the same `qits-buildkitd` (host network while the
  platform is not up, same pin, same state volume) before the first build; `Docker.build*`
  drive `buildctl` via `docker run --rm --entrypoint buildctl` of the same image (the host
  needs no buildctl binary); `--load` becomes `--output type=docker,dest=…` + `docker load`;
  the buildx builder create/rm and `-f -` stdin path are removed (the rewritten Dockerfile
  is written to a temp dir instead); teardown leaves the buildkitd standing (it is platform
  infrastructure now; qits-containers re-ensures it onto qits-net, keeping the cache volume)
  and still sweeps legacy `qits-bootstrap-builder*` builders.
- **Docs** — qits-ci README (step contract), local-platform.md (the builder in the tables),
  this plan's status.

## Decisions taken here, to confirm

- **Port 1234** (buildkitd's conventional port) and alias `qits-buildkitd`.
- **Pin `moby/buildkit:v0.33.0`.**
- **`--privileged`** rather than the rootless image: rootless needs seccomp/apparmor
  unconfined + `/dev/fuse` and slower overlay emulation; under the standing intra-network
  posture the contained-root trade is accepted, and rootless is the recorded hardening
  follow-up.
- **No TLS on the builder address**: every platform hop on qits-net is plain HTTP by the
  same posture; the buildkitd gRPC socket follows it.
- **20 GB `keepstorage`**, no container memory cap.
- **`QITS_BUILD_REGISTRY`** as the env name; key `qits.ci.buildkit.registry-host`, default
  `qits-platform-artifacts:8080`.
- **Both qits-workspace-daemon pipeline files convert together** (the matched-pair rule in
  the files themselves), though the epic named only the release recipe.
- **Caller-wins deference** for `BUILDKIT_HOST` (empty suppresses) as the kill-switch reach
  across the qits-ci → qits-containers seam, instead of a wire field.

## Status as shipped

- [x] qits-containers: buildkitd owned (`PlatformBuildkit`, boot-ensured, row-less like the shared
      volumes), `BUILDKIT_HOST` injected into socket-holding specs (caller wins, empty included),
      build-cache gc extended to the owned builder, `--privileged` rendered by a dedicated argv so
      no spec can express it. Full suite green.
- [x] qits-build-images: buildctl in ci-base and node-docker-base, copied from the pinned
      `moby/buildkit:v0.33.0` stage (mirror-riding, SBOM-visible).
- [x] qits-ci: `qits.ci.buildkit.enabled` (ON, `QITS_CI_BUILDKIT_ENABLED=false` is the lever) and
      `qits.ci.buildkit.registry-host` → `$QITS_BUILD_REGISTRY` on docker steps; OFF sends both
      keys empty, which also suppresses the containers-side injection. The auth document names the
      build registry. Full suite green.
- [x] qits-workspace-daemon: both pipeline files on buildctl with `push=true`, no `--network
      host`, mirror by its in-network route, secrets in file form on both sides; Dockerfile mounts
      converted to file form, base-pin line untouched.
- [x] qits-bootstrap-cli: seed images, step images and the musl-builder image through the same
      `qits-buildkitd` (created host-net before the first build, left standing for
      qits-containers); `--load` replaced by `--output type=docker` + `docker load`; buildx
      create/rm gone, legacy-builder sweep kept; suite green (599 tests). One recorded deviation:
      the buildctl client's scratch dirs live under `QITS_SRC/.buildkit` rather than `/tmp`,
      because the client is a container and its `-v` paths are the host daemon's to resolve.
- [x] docs: qits-ci README (`docker: true` section) and step-execution-flow diagram note,
      qits-containers README (the one owned container, argued), local-platform.md (the build-plane
      row and the mirror note), this file.

## Handoff

**Implemented**, per repository, all on branch `refining/image-builds-through-a-platform-owned-bu`
(committed, not pushed to GitHub):

- qits-containers-service — the owned builder, the env injection, the gc extension.
- qits-build-images-oci — buildctl in the two docker-step images.
- qits-ci-service — the kill switch, `$QITS_BUILD_REGISTRY`, the widened auth document.
- qits-workspace-daemon — the representative recipe pair + Dockerfile.
- qits-bootstrap-cli — the whole bootstrap build path.
- wrapper — this plan, local-platform.md.

**Proven by tests:**

- qits-containers `./mvnw verify`: the builder argv whole (privileged appears there and nowhere
  else), the boot pass converging on the pin (create / adopt / start / replace, volume never
  removed), the injection rules (socket-only, caller wins, empty wins, off = untouched), the gc
  sweep including the platform builder at the host's keep-storage, the exec belt staying closed.
- qits-ci `./mvnw verify`: the docker-step environment whole in both switch states (ON adds only
  `QITS_BUILD_REGISTRY` and never an address; OFF sends the pair empty and changes nothing else),
  the no-commission arm byte-identical plus the mode variables.
- qits-bootstrap-cli `./mvnw verify`: every emitted argv whole (buildkitd run, buildctl-in-a-
  container build, `docker load`), secrets masked and file-form, teardown leaving the builder and
  its volume, the legacy buildx sweep.

**Needs a running platform to prove** (in rough order of information value):

1. A real bootstrap: `moby/buildkit:v0.33.0` resolving through the host daemon's registry-mirrors,
   privileged host-net buildkitd answering on 127.0.0.1:1234, the musl toolchain `ADD
   http://localhost:8081/…` resolving from the builder's namespace, `--output type=docker` +
   `docker load` leaving tags exactly where `docker tag`/`docker create`/`stack deploy
   --resolve-image never` expect them, and the `QITS_SRC/.buildkit` scratch path being identical on
   both sides of the socket.
2. qits-containers' first deployment re-ensuring the bootstrap's builder onto `qits-net` with the
   cache volume intact, and a step container resolving `tcp://qits-buildkitd:1234`. One known
   ripple: the injected `BUILDKIT_HOST` enters the spec hash, so an existing long-lived
   socket-holding workload (an admin workspace) reads as spec-changed on its first ensure after the
   deploy — a one-time recreate where the caller asked for recreate-if-changed, a `KEEP` note where
   it did not.
3. A qits-workspace-daemon release request end to end: the buildkitd.toml rewrites serving the
   committed `FROM` vhosts, the Mandrel build's RUN reaching `$QITS_MAVEN_PROXY_URL` from the
   builder's namespace, `push=true` landing `qits/workspace:<sha>`/`:<version>` where
   qits-deployments pulls them, the SBOM export as a cache hit, and the commissioned credential
   flowing through the file-form secrets (including whether the in-network push is challenged at
   all — the auth-document widening is precautionary).
4. The kill switch flipped live: `QITS_CI_BUILDKIT_ENABLED=false` making the converted recipe fail
   on its `:?` guard with the message naming the cause, unconverted recipes unaffected.
5. The gc path: `POST /containers/api/gc/build-cache` pruning the owned builder (the orchestrator
   needs no change — the builder rides the existing call), and buildkitd's own gckeepstorage
   holding the volume near 20 GB.
6. The qits-containers packaged story catalogue (`-DskipITs=false -Dit.test=…`) — the platform
   builder is off in that profile by design; the six stories should be byte-stable, which was not
   re-run here.

**Not in this epic, recorded for the next:** a `build: true` step key granting `BUILDKIT_HOST`
without the socket; converting the remaining ~46 docker-step recipes (mechanical, per the
representative pair); dropping the socket mount from converted steps; rootless buildkitd; a
`docker.io` mirror stanza if a bare Hub `FROM` ever becomes legitimate.
