# Publishing images from green pipelines — plan

Written 2026-07-30, remodelled the same day: the first draft made publishing a special stage
qits-ci executed host-side behind a seam. That was badly modelled for a CI system — publishing is
not a new kind of thing, it is `docker build && docker push`, and a pipeline already has a word
for "run these commands after the others went green": a step. So it is a step. What the platform
adds is only the one thing a step is missing today: a way to reach a docker daemon.

## 1. The model: publishing is the pipeline's last ordinary step

```yaml
steps:
  - image: qits/build-images/ci-base:latest
    script: ./mvnw -B -ntp verify
  - image: qits/build-images/ci-base:latest
    docker: true                      # ← the only new concept in the platform
    timeout-seconds: 3600             # native builds want minutes; the knob already exists
    script: |
      ref="$QITS_REGISTRY/$QITS_IMAGE_REPOSITORY/qits-gateway:$QITS_CI_SHA"
      docker build -t "$ref" -f docker/Dockerfile .
      docker push "$ref"
      docker rmi "$ref" || true       # keep host tags from accumulating; layer cache stays
```

Everything composes from what already exists. Steps are sequential, so the push runs only if the
build steps went green; a failed push is a failed step is a **FAILED run**, so the CD
announcement (which fires only on `SUCCESS`) keeps implying "the image exists"; the sha is
already in the container as `$QITS_CI_SHA`; the per-step `timeout-seconds` already covers slow
native builds; the recorded step row already captures the build/push output. No new archetype, no
publish schema, no synthetic rows, and qits-ci itself still never builds anything — its own
docker vocabulary stays container-lifecycle-only, untouched.

`docker: true` (per step, default false) bind-mounts the host's docker socket into that step's
container. The step image supplies the docker CLI (the `build-images/ci-base` image grows it, or
a step names any image that carries one alongside the existing git/bash/downloader contract). The
CLI streams the build context from the step's own checkout to the daemon; the daemon builds,
pushes, and resolves the registry address — all host-side, which is what makes it work and is
also what §4 is about.

## 2. What qits-ci changes

1. **Parser**: the optional per-step `docker` boolean in `CiConfigParser`/`CiPipeline.CiStepDecl`.
2. **Launcher**: `CiDaemonLauncher.buildArgv` adds `-v <socket>:<socket>` when the step declares
   it; the socket path is `qits.ci.docker-socket-path` (default `/var/run/docker.sock`) so a
   nonstandard daemon stays a config fact. The sandbox flags stay as they are — cap-drop and
   no-new-privileges cost a socket client nothing, and the flags keep meaning what they mean for
   every step that does not opt in.
3. **Environment**: every step container additionally receives `QITS_REGISTRY` and
   `QITS_IMAGE_REPOSITORY` (from the shared keys in §3), so a publish script names no deployment
   fact. `$QITS_CI_SHA` is already there.
4. **Tests**: parser cases; a `CiDaemonLauncherTest` argv case (the mount present exactly when
   declared, absent otherwise — the absence is the security assertion); the docker-backed gate
   grows one step that proves a `docker: true` container can really answer `docker version`
   through the mounted socket, skipping without docker like the rest of the `extended` tags.
5. **Docs**: README pipeline schema; AGENTS.md's untrusted-input section amended *consciously* —
   see §5. The boundary table gains the two injected env names.

**qits-cd**: rename its registry keys to the shared spelling (§3); no behavior change. Its
`IMAGE_MISSING` docs lighten: the state now means "the pipeline publishes nothing, or the tag
convention broke", not "nothing in the platform can publish".

**qits-artifacts**: self-seed the `qits` repository row (type `oci-images`) alongside
`ci-screenshots`/`ci-videos`, so a fresh deployment accepts a push with zero manual steps. The
registry itself is ready (tokenless for producers, commit `143c695`).

## 3. Conventions

- **The tag is the contract with qits-cd.** cd pulls
  `<registry>/<repository>/<application>:<sha>` where `<application>` is the environment's
  application name — by convention the repository's name. The publish script must tag exactly
  that, and the only enforcement is the convention plus `IMAGE_MISSING` telling on a mismatch.
  Nothing enforces cross-repo name uniqueness either; see §6.
- **The registry coordinates get ONE spelling**, named after their owner:
  `qits.artifacts.registry-host` (default `qits-artifacts:8080`) and
  `qits.artifacts.image-repository` (default `qits`), shipped as defaults from both qits-ci
  (which injects them into step containers) and qits-cd (which derives pull references), each
  carrying the same caveat: the address is dialled by the **docker daemon**, not by either
  service.

## 4. Deployment prerequisites

The build and the push both happen in the *host's* daemon (the step's CLI is just a client), so
the registry address must be resolvable and trusted from there: publish it on a host-reachable
address, set `qits.artifacts.registry-host` accordingly, and add it to the daemon's
`insecure-registries` while it speaks plain HTTP. Belongs in the deployment guide next to the
docker-socket mount qits-ci already documents — it is the same class of fact, and now the same
socket serves both.

## 5. Security posture, stated plainly

A `docker: true` step is **root-equivalent on the host**. The socket is the daemon, the daemon is
root: such a step can mount host paths, start privileged containers, and leave the sandbox at
will — the cap-drop flags fence the step's own process tree, not what the daemon will do on its
behalf. This is accepted **for the POC** under the standing posture (sources are trusted;
intra-network hardening is parked and will be addressed platform-wide), and it is *opt-in per
step*: every step that does not declare `docker: true` keeps exactly the sandbox it has today,
which is why the launcher test asserts the mount's absence as much as its presence.

The later fix costs the platform nothing here, and that is this model's quiet advantage over the
host-side draft: an unprivileged builder (rootless BuildKit or equivalent) is just a different
step image that no longer needs the socket — the `docker: true` flag stops being declared,
nothing in qits-ci changes. The invariant prose in qits-ci's AGENTS.md ("no repo-controlled code
gains a docker socket") must be rewritten in the same change to say what is true now: not gains
one *silently* — a step declares it, the config diff shows it, and the run row records that step
like any other.

## 6. Out of scope, deliberately

- **The unprivileged builder** — a future step image, per §5; no platform seam required.
- **Image/layer GC** — per-sha tags into an append-only registry is the churn
  `artifact-access-tracking.md` is the prerequisite for; scripts `docker rmi` their own host tag
  and daemon-cache growth stays an ops concern (`docker builder prune`).
- **Cross-repo tag uniqueness** — convention (use the repo's name), not enforcement; ci
  deliberately does not know repo names and is not the authority.
- **Extra tags** (`:branch`, `:latest`), multi-arch, remote build caches — nothing the
  sha-addressed deploy convention needs.

## 7. Verifying end to end

Clone-alone `mvn verify` green in each repo (the flag is argv assembly — no new fakes needed);
`-Dnative` green in qits-ci. Then the real loop on a deployment: push to a tracked branch → the
run's final step builds and pushes through the mounted socket →
`GET /v2/qits/<name>/manifests/<sha>` answers → cd's deployment row goes `ACTIVE` and the
container serves on the environment's network.
