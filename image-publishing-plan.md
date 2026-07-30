# Publishing images from green pipelines — plan

Written 2026-07-30. The last missing pipeline stage between a push and a running container:
nothing in the platform produces an application image. qits-cd deploys by convention
(`<registry>/qits/<application>:<sha>`), qits-ci announces green runs to it, the registry is
tokenless for producers — and every real deployment today honestly records `IMAGE_MISSING`,
because no producer exists. This plan closes that gap.

## 1. The model: the pipeline's final step produces and uploads the image

A repository that wants its green builds deployable declares it in the same file that declares its
pipeline, `.config/qits/ci-post-receive.yml`:

```yaml
steps:
  - image: qits/build-images/ci-base:latest
    script: ./mvnw -B -ntp verify
publish:
  name: qits-gateway            # required: the image path segment — see §3
  dockerfile: docker/Dockerfile # default; relative to the repo root
  context: .                    # default; relative to the repo root
```

The `publish` block is the run's **final step**: it executes only after every declared step went
green, it is recorded as one more step row on the run (index `steps.size()`, the produced
reference in the `image` column, the docker build/push tail in `output`), and its failure makes
the run **FAILED** — a pipeline whose artifact was not produced is not green, and half-green runs
that deploy nothing but read as deployable are exactly the confusion this column of the run view
exists to prevent. The CD notification already fires only after the run's terminal row commits,
so "cd was told" now implies "the image exists": `IMAGE_MISSING` stops being the expected outcome
and becomes what its javadoc always claimed — the signal that a convention was broken.

A repo with no `publish` block behaves exactly as today: green runs, notifications, and cd
recording `IMAGE_MISSING` for any environment that tracks it (an environment may legitimately
track applications whose images are produced elsewhere).

**Declared as a pipeline stage, executed host-side.** The step sandbox never gets a docker socket
— that boundary stays. The publish stage is executed by qits-ci itself, which already holds the
socket and already shells the docker CLI; its vocabulary grows `build`, `push` and `rmi` for
exactly this stage. What that costs is stated plainly in §5 rather than discovered later.

## 2. Execution mechanics (qits-ci)

On the existing single-threaded run worker, after `runSteps` ends green and before `finishRun`:

1. **Checkout.** Clone the pushed sha from ci's own per-repo bare cache
   (`<data-dir>/repos/<repoId>.git` — GitConfigFetcher fetched the branch ref during the config
   read, so the sha is present) into a temp dir under `<data-dir>/publish/`, `git checkout <sha>`,
   delete after. A sha force-pushed away between the run and the publish fails the checkout and
   the publish honestly. ci's own `git` against ci-owned state — the GitConfigFetcher stance,
   never pipeline content as a host process.
2. **Build.** `docker build -t <registry-host>/<image-repository>/<name>:<sha>
   -f <dockerfile> <context>`, via `CiProcess` (bounded tail, hard timeout — its own
   `qits.ci.publish-timeout-seconds`, default generous: the platform's own images run a native
   compile inside a Mandrel builder stage and want minutes and ~4 GB).
3. **Push.** `docker push <ref>`. No credential — the registry is tokenless for producers
   (qits-artifacts commit `143c695`), which is what keeps this stage free of a credential store.
4. **Cleanup.** Best-effort `docker rmi <ref>` after a successful push, so host-local tags do not
   accumulate unboundedly; the builder layer cache is deliberately left alone (it is what makes
   the second build of a service fast). Daemon-level cache growth is an ops concern
   (`docker builder prune`), noted in §8.

Serialization is inherited and accepted: publishes queue on the run worker like everything else,
so a slow native build delays every pipeline behind it. That is the same tradeoff the worker
already makes for steps, and parallelism remains the explicit follow-up it already was.

Cancellation: a cancel that lands before the publish stage skips it (the run is red anyway); the
publish itself is not interruptible mid-`docker build` beyond its timeout.

## 3. Conventions and validation

- **`publish.name` is the contract with qits-cd.** cd derives
  `<registry>/<repository>/<application>:<sha>` from the *environment's* application name; the
  publisher must tag the same reference, and the only thing that links them is this name. So:
  `publish.name` must equal the `name` the environment's application row carries — by convention,
  the repository's own name. It is required (ci knows the repo only as a UUID and can default
  nothing), and validated with the same dns-label rule cd applies (`[a-z0-9][a-z0-9-]{0,62}`,
  since it is an image path segment and a future hostname label). Nothing enforces cross-repo
  uniqueness — see §8.
- **`dockerfile` and `context`** are repo-relative, validated against traversal (no leading `/`,
  no `..` segments), resolved against the checkout and required to stay inside it.
- **The registry coordinates get ONE spelling.** cd shipped `qits.cd.registry-host` +
  `qits.cd.image-repository`; ci would now need the same two facts, and two services spelling one
  deployment fact differently is the drift the receiver-named-key convention exists to prevent.
  Rename to the receiver's name — `qits.artifacts.registry-host` (default `qits-artifacts:8080`,
  with the "as resolvable by the DOCKER DAEMON, not by this process" caveat both services must
  carry) and `qits.artifacts.image-repository` (default `qits`) — shipped as defaults from both
  consumers' config, overridden once per deployment. The cd rename is a straight substitution
  (config keys, docs, no behavior).
- **Parser rules match the existing ones**: SafeConstructor, unknown keys inside `publish`
  rejected, the block optional, `steps` unchanged.

## 4. Registry prerequisites — close them in qits-artifacts

- **Self-seed the `qits` repository row.** The registry rejects a push to an unknown first
  segment (`404 NAME_UNKNOWN`), and the row is today a manual `PUT`. qits-artifacts already
  self-seeds `ci-screenshots` and `ci-videos` at startup; add `qits` (type `oci-images`) to that
  seeder so a fresh deployment can receive a push with zero manual steps.
- **The daemon must reach and trust the registry.** Deployment facts, not code: the address in
  `qits.artifacts.registry-host` is dialled by the *host's* docker daemon, which resolves nothing
  on qits-net — so a deployment publishes the registry on a host-reachable address and, while it
  speaks plain HTTP, adds it to the daemon's `insecure-registries`. Belongs in the deployment
  guide next to the docker-socket mount.

## 5. Security posture, stated plainly

`docker build` executes repo-controlled build instructions: `RUN` lines run as root inside
unsandboxed build containers on the host daemon, with network, without the cap-drop/no-privileges
fence step containers get. This is more privilege than any pipeline content has had anywhere in
the platform, and it is accepted **for the POC** under the same posture as the token removals:
sources on this platform are currently trusted, and intra-network hardening is a parked,
platform-wide decision. The fence that *does* stay: the step sandbox still never sees a socket,
`docker exec` stays out of the vocabulary, every value entering the build argv
(`name`/`dockerfile`/`context`/sha) is allowlist-validated, and `CiProcess` never shell-splits.
The later fix — an unprivileged builder (rootless BuildKit or equivalent) behind the same
`ImagePublisher` seam — replaces the executor without touching the model, which is the reason the
seam exists (§6). qits-ci's AGENTS.md invariant ("the docker vocabulary is container lifecycle
only") must be amended consciously in the same change, not silently contradicted.

## 6. Changes, by repo

**qits-ci** (the bulk):
1. `CiConfigParser`/`CiPipeline`: optional `publish` block (`name`, `dockerfile`, `context`),
   validation per §3.
2. `ImagePublisher` seam in `ci/control` (the `CiStepRunner` arrangement): interface + result
   record (`published` / `failed(detail)` / produced ref), sole production implementation
   `service/publish/DockerImagePublisher` shelling git + docker via `CiProcess`; a scripted
   `FakeImagePublisher` keeps `mvn verify` docker-free.
3. `CiRunService`: run the publish stage after green steps, write the synthetic step row, fail
   the run on a failed publish, keep the CD notification strictly after.
4. Config: `qits.ci.publish-timeout-seconds`, plus the shared
   `qits.artifacts.registry-host`/`image-repository` keys.
5. Tests: parser cases; seam semantics at `CiRunServiceTest` level (green publishes, red does
   not, failed publish reddens the run and suppresses the CD announcement); a docker-tagged
   `CiPublishGateIT` (`extended`) that really builds a tiny fixture Dockerfile and pushes to a
   throwaway local registry, skipping without docker like the other gates.
6. Docs: README pipeline schema + boundary table, AGENTS.md vocabulary amendment (§5).

**qits-artifacts**: the `qits` row in the startup seeder (§4). Nothing else — the registry is
ready.

**qits-cd**: rename to the shared registry keys (§3); no behavior change. Its `IMAGE_MISSING`
docs get one line lighter ("nothing publishes images yet" becomes "the repo declares no publish
block, or the convention broke").

**Deployment guide** (monolith repo): registry host reachability + `insecure-registries` beside
the existing multi-stack section.

## 7. Verifying end to end

Clone-alone `mvn verify` green in each repo with the fakes; `-Dnative` green in qits-ci (the
publisher adds no reflection — argv assembly and `CiProcess` only). Then the real loop on a
deployment: push to a tracked branch → run goes green with a final publish step row naming the
ref → `GET /v2/qits/<name>/manifests/<sha>` answers → cd's deployment row goes `ACTIVE` and the
container serves on the environment's network.

## 8. Out of scope, deliberately

- **The unprivileged builder** — the accepted risk in §5, replaced behind the seam when the
  platform-wide hardening lands.
- **Image/layer GC** — per-sha tags into an append-only registry is exactly the churn
  `artifact-access-tracking.md` is the prerequisite for; nothing here may depend on deletion.
- **Cross-repo `publish.name` uniqueness** — a convention (use the repo's name), not yet an
  enforcement; two repos publishing one name last-writer-wins today. Enforcing it needs an
  authority that knows repo names, which ci deliberately is not.
- **Extra tags** (`:branch`, `:latest`), multi-arch, remote build caches — none needed by the
  sha-addressed deploy convention.
