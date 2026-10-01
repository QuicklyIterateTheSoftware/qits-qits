# The local platform: bring-up and updates

Status: **working, proven end-to-end 2026-07-30** (first full run: ~13 minutes on a 24-core
workstation, all four pipeline deployments ACTIVE and healthy).

[`qits-local-up.sh`](qits-local-up.sh) bootstraps the whole platform on the workstation's docker
daemon **through the platform's own pipeline**: it hand-builds only the build/deploy core, and
that core builds and deploys everything else the way it would in production. The bootstrap itself
is [`components/qits-bootstrap/qits-bootstrap-cli`](components/qits-bootstrap/qits-bootstrap-cli), a CLI the script compiles and runs; its
README is the reference for knobs and known gaps. This document is the *flow* — what to run when
something changes.

Two sets to keep straight:

| set | members | managed by | updated by |
|---|---|---|---|
| **deployer-managed** | all eleven: observability, idp, stt, projects, workspaces, events, platform-docs, gateway, artifacts, ci, **and qits-deployments itself** | qits-deployments — sha-addressed registry images, `qits-pd-` container names | a git push |
| **bootstrap-made** | the ci-daemon binary, the deployer's config extras (rendered once and imported into qits-configuration, which the deployer reads at runtime — see the bootstrap README's phase list), and the seed postgres with its `qits_deployments` role and database | the bootstrap | a bootstrap rerun |
| **built and published, like anything else** | the five `qits/build-images/*` step images | qits-build-images-oci, whose own pipelines run on upstream `docker:28-dind` through the mirror | a qits-build-images-oci release, and a re-pull on any host that lost them |
| **the build plane** | the `qits-buildkitd` container (pinned `moby/buildkit`) and its `qits-buildkitd-state` cache volume | made by the bootstrap on the host network for the seed builds, then re-ensured onto `qits-net` by qits-containers from its first deployment on — one container, one cache, two phases of ownership | a pin bump in qits-containers (`qits.containers.buildkit.image`); `unwrap` removes it, a rebootstrap remakes it |

The third row used to be part of the second, and 2026-08-20 is why it is not. Every recipe names a
step image *unqualified*, so docker resolved it against Docker Hub and it only ever worked because
the bootstrap had left a copy in the host's local store. A `docker system prune` then deleted the
platform's whole CI plane — `pull access denied for qits/build-images/ci-base` on every build in
every repository — with a bootstrap rerun as the only recovery, and no run left that could fix it,
because the pipeline that publishes those images ran on one of them.

Both halves of that are closed. qits-ci resolves an unqualified platform image against the registry
(`CiStepImage`), so a host that lost them re-pulls rather than rebuilds. And qits-build-images-oci's own pipelines
run on `docker:28-dind`, an upstream image through the OCI mirror, so nothing it publishes is needed
to publish it — which is what took these off the bootstrap entirely rather than merely making them
recoverable. The enabling change was in qits-ci-daemon: a step image must provide `git` and a
downloader, and a shell, but no longer `bash` specifically.

The deployer-managed set has two shapes, and each repo's `.config/qits/deployments.yml` says which
it is:

- **environment applications** — `qits-stt`, `qits-workspaces` and their siblings. One instance per
  environment. They belong to the `dev` tier (network `qits-net`), deploy at the released version
  coordinate, and run as `qits-pd-dev-qits-<name>-<id8>`.
- **platform services** — the other eight, `qits-deployments` included. One instance for
  the whole platform, no environment, deployed at their released version, running as
  `qits-pd-platform-qits-<name>-<id8>`. The word used to be *singleton*: it named a cardinality
  where what is meant is which plane a service lives on.

`main` is the integration trunk on both planes — a push to it builds and deploys nothing. A release
reaches either plane the same way: a release request, a version, a tag. The plane a repository lands
on is a property of its `deployments.yml` (`deployment_target: platform` or not), not of a branch;
the `platform/main` and `environment/*` deploy refs were retired on 2026-09-04.

Nothing registers an application by hand: a release registers or updates the application from that
repo's spec.

**The deployer (qits-deployments) holds the topology itself** — the environments, the services and
the links between them are rows in its own postgres database, and its own API is the door an
operator and the bootstrap use. That is the merge: the topology used to be `qits-serviceregistry`,
reached over HTTP, so a decision that is one transaction had to be agreed between two services.
One component, one socket, one database. It is in the seed swarm stack beside the idp because
nothing can create the `dev` tier or deploy anything until it answers.

The platform runs as a **docker swarm stack**, not compose: the seed is `docker stack deploy`d once,
and each service's own pipeline deployment then replaces its seed original with swarm's own
stop-first rolling update. qits-deployments' own database is postgres (`qits-oci-postgresql`), not
H2 — see the bootstrap README's phase list for the current cutover ordering and mechanics, which
have moved on from the per-container H2-lock handoff this section used to describe.

Every service is fronted by the platform edge at `https://<app>.qits.<domain>` now — see the
bootstrap README's `QITS_DOMAIN`/`QITS_ACME_MODE` entries for what that requires. The gateway's
pipeline still publishes the **local** (unauthenticated) variant on purpose: this flow feeds a
one-machine platform; anything fronting more than one machine builds the oauth variant and must
not consume that image.

## First run

**A domain is required.** Since qits-bootstrap-cli `2026.930.190457` a bootstrap without
`QITS_DOMAIN` is refused up front, before anything is built (exit 2): the platform addresses every
service by subdomain, and CI in particular reaches it only through its public names
(`ci.qits.<domain>`, `idp.qits.<domain>`, `registry.qits.<domain>`, and so on), so a domain-less boot
could never pass. `QITS_PUBLIC_IP` is mandatory beside it (the A records the domain needs, since
this platform serves no DNS of its own — they go in at your provider *before* the run), and
`QITS_ACME_MODE` must be `production`: the CI runner trusts no staging or self-signed certificate,
so anything else is refused before the boot starts. See the bootstrap README's `QITS_DOMAIN` /
`QITS_PUBLIC_IP` / `QITS_ACME_MODE` entries for the exact constraints on each.

From this repo's root, submodules initialised (sources are cloned from your local checkouts,
local commits included — GitHub `main` is only the fallback):

    QITS_DOMAIN=<your domain> QITS_PUBLIC_IP=<this host's public IPv4> QITS_ACME_MODE=production \
        ./qits-local-up.sh

It runs **on the host** now, not as a container: the script compiles `components/qits-bootstrap/qits-bootstrap-cli` and
runs the binary, which shells the host's docker and git. Nothing needs the socket mounted. The run
shows what it is doing on the terminal and, through the bootstrap's own edge, in a browser at the
address printed on the run's first line (`https://<domain>` once a real certificate is issued,
plain `http://<domain>` on the very first cold boot before one exists).
`./qits-local-up.sh unwrap` takes the platform off the machine again.

It writes a generated swarm stack file and `.qits-bootstrap.env` back into this directory. Both are
generated, machine-specific state and gitignored. The env file is the credential continuity: the
pinned ci-daemon digest, the idp client secrets, and the postgres passwords
(`PG_SUPERUSER_PASSWORD`, `PG_DEPLOYMENTS_PASSWORD`) — lose it with a surviving postgres volume
and the superuser is locked out, because `POSTGRES_PASSWORD` only applies when the data dir is
first created.

The bootstrap starts postgres before the deployer and provisions the deployer's own role and
database over JDBC from the host, through `127.0.0.1:5433` (`QITS_PG_PORT`). Every later
database is created by the deployer itself: a repo declares `resources: postgresql:db` in its
`deployments.yml`, and provisioning runs before its container starts.

Every knob, mode and flag is the CLI's: see [components/qits-bootstrap/qits-bootstrap-cli/README.md](components/qits-bootstrap/qits-bootstrap-cli/README.md).

## Updating a pipeline-deployed service

The everyday loop, and since 2026-09-04 it has one door into `main`: a **release request**.

**A push builds nothing.** Per-push CI is gone — there is no `ci-post-receive.yml` in any repository
and no `environment/*` branch to promote onto. Push your branch, then ask qits-projects for a
release request naming it:

    curl -sS -X POST -H "Authorization: Bearer $PTOK" -H 'Content-Type: application/json' \
        https://projects.qits.<domain>/projects/api/repositories/<repoId>/release-requests \
        -d '{"branch":"<your branch>","summary":"<what this release is>"}'

qits-projects folds `main`, that branch and any released tags still in flight onto a backing branch
`release/<id>`, and re-folds whenever one of them moves. `.config/qits/release.yml`'s request phase
builds that fold; a **green verdict on it is the quality gate, with no exceptions** — every step of
that pipeline gates, and no step may opt out. Over a green one, Auto Release stamps the calendar
version (`release(2026.801.55529): …`), bumps the manifests, tags, and publishes `SCMRelease`.

`POST /workspaces/api/workspaces/<id>/integrate` still merges a workspace's branch into its
**parent** branch — a `task/…` landing on its `epic/…` — with no version, no bump and no event.
Aimed at a workspace whose parent is `main` it refuses with 409 `reason: RELEASE_REQUIRED`: only a
release request writes `main`.

**A direct push to `main` is the escape hatch, and it deploys nothing.** `main` is a protected ref
on the git host, so updating it needs a push option carrying this host's configured push token:

    cd components/qits-observability/qits-observability-service
    git commit ...
    git push -o qits.token=local-dev https://githost.qits.<domain>/artifacts/git/qits-observability main

It puts the commit on `main` and stops there — no build, no image, no deployment, and no version
identity for the deployer to pull. It is a way to unstick a repository, not a way to ship.

`local-dev` is what `qits-local-up.sh` configures; `QITS_PUSH_TOKEN` changes it. A deployment that
configures **no** token has no escape hatch at all — unset matches nothing, and neither does empty,
so there is deliberately no "leave it blank and it opens". The option travels inside the pack
protocol rather than in a header, so the same command works against any of the platform's public
names for the git host. Creating a ref is never guarded, only updating or deleting the default
one — which is why the bootstrap's first push of a fresh repo needs nothing.

The RELEASE is the deployment: `SCMRelease` → qits-ci runs the repo's
`.config/qits/ci-event-release.yml` (build `docker/Dockerfile`, push to the registry at
`registry.qits.<domain>`) → the green run and the `SCMRelease` meet and qits-ci announces
`SoftwareRelease` → qits-deployments opens a Deployment Request for that version coordinate, reads
the repo's `deployments.yml` at the released tag, registers the application if it is new, pulls,
health-gates the fresh container on `qits-net`, and only then removes the old one (swarm's own
stop-first rolling update). `main` is finalized once that deployment is live. Watch it land:

    docker ps                                                                        # the step container, then the new deployment
    curl -s https://deployments.qits.<domain>/platform-deployments/api/environments  # the environment id
    curl -s 'https://deployments.qits.<domain>/platform-deployments/api/deployments?environmentId=<id>' | jq   # newest-first, with detail on failures
    curl -s https://deployments.qits.<domain>/platform-deployments/api/applications | jq  # environment apps and platform services, flattened

The deployments listing is scoped to an environment, so platform-service deployments are not in it;
`docker ps` under `qits-pd-platform-qits-*` is what shows those.

A failed build or gate leaves the previous container serving (`FAILED` / `IMAGE_MISSING` on the
deployment row, with the log tail in `detail`); nothing to clean up.

Alternatively `QITS_SKIP_BUILD=1` on a bootstrap rerun pushes every repo and skips the seed
builds — unchanged repos push up-to-date and trigger nothing.

## Updating qits-artifacts / qits-ci

The same push as any other service — they are deployer applications. Expect a few seconds of downtime
on artifacts updates (the replace cutover stops the old container through the health
gate; the host port rebinds when the fresh one starts). A failed gate restarts the old container.

## Updating qits-deployments

The same release request as everything else — the deployer is a platform service, so its deployment
is not in the environment's listing. What differs is the cutover: it is updating the swarm service
it is itself running as, which is why it is deployed as an ordinary swarm service with a stop-first
`update_config` rather than through its own in-process handoff logic — see the bootstrap README's
phase list for the current ordering (`qits-oci-postgresql`, the deployer's own database, cuts over
immediately before it, deliberately never queued beside a consumer's). Recovery from a failed
cutover is the bootstrap README's territory, not a hand-rolled referee.

## Updating the qits-ci-daemon

The one flow that still needs a bootstrap rerun **without** `QITS_SKIP_BUILD`: it rebuilds the
binary, uploads the new blob, and regenerates the run-args file pinning the new digest — after
which qits-ci must be redeployed (any push to it) to pick the new env up.

## The base images pull through the platform's own mirror

Every committed Dockerfile `FROM`s `mirror.dev.localhost:8080/quay/…` or
`mirror.dev.localhost:8080/redhat/…` (every `*.localhost` name resolves to loopback by itself, so
there is no hosts file to edit for a developer's own `docker build`):
qits-artifacts is a pull-through cache for the upstream registries, one namespace per registered
upstream (`quay`, `redhat`, `hub`). The first pull of a reference fetches from its upstream,
verifies the digest and keeps the bytes forever; every later pull is served from disk. Once a
base image has been pulled once, every later build succeeds with the internet down — an expired
tag serves stale, and only a never-cached reference fails (502, naming the upstream). Manage the
upstreams in the explorer at `https://artifacts.qits.<domain>/artifacts/` → Mirrors, or over
`https://artifacts.qits.<domain>/artifacts/api/mirror-upstreams`; deleting one stops future
fetching but keeps the cache.

Three facts an operator needs:

- **The bootstrap is the one exception.** Seed builds run before qits-artifacts exists, so
  `qits-local-up.sh` pipes their Dockerfiles through `seed_dockerfile`, which rewrites the
  mirror prefixes back to the direct upstream refs. Pipeline builds keep the mirror — and a
  `FROM` that hits the mirror while qits-artifacts is mid-cutover fails that build; rerun it.
- **Every upstream is anonymous.** A `docker login` on the daemon never travels through a
  pull-through hop — the mirror dials upstream as itself. A private upstream needs a
  server-side credential, a future column on the upstream row; its first planned use is a
  Docker Hub PAT on the first observed 429.
- **The cache only grows.** Append-only by decision (proxy-pulling-normal-images.md ⚖2) until
  access tracking lands. `GET /artifacts/api/gc/plan` reports the `oci-mirror` type all-kept
  ("append-only pending access tracking"), and `ociMirrorBytes` in
  `/artifacts/api/store/summary` is the current size.

One host-side trap, measured while proving the fill: the docker daemon keeps base layers alive
long after `docker rmi` — dangling intermediate images and the buildkit cache both pin them —
so "remove the tag and rebuild" does not force a re-pull until those go too. Nothing about the
platform needs that; it only matters when deliberately testing the mirror's offline posture.

**CI builds resolve those same committed spellings through the platform builder now, not the host
daemon.** A `docker: true` step is handed `$BUILDKIT_HOST` (the `qits-buildkitd` container on
`qits-net`) and `$QITS_BUILD_REGISTRY`; the builder's own registry config rewrites
`registry.dev.localhost:8080` / `mirror.dev.localhost:8080` (and the two host-published ports) to
the in-network aliases, so one committed `FROM` spelling serves both a developer's `docker build`
and the platform's `buildctl`. `qits-buildkit-plan.md` is the whole migration; the kill switch is
`QITS_CI_BUILDKIT_ENABLED=false` on qits-ci.

## Changing what a deployed application gets at runtime

Volumes, env and sockets come from the deployer's per-application config extras. The source of
truth is still the generated properties **in `components/qits-bootstrap/qits-bootstrap-cli`** — edit
it there and rerun (`--skip-build` suffices). A cold boot writes those extras onto the deployer's
config volume for its own seed-stack startup, then imports the same properties file into
qits-configuration and points the running deployer at it (`QITS_PLATFORM_DEPLOYMENTS_EXTRAS_URL`);
from that import on, qits-configuration — not the volume — is what the deployer reads at deploy
time, and it refuses a deployment it cannot read from there. See the bootstrap README's phase list
(around the config-extras and config-becomes-platform-state phases) for the exact mechanics before
relying on this in a pinch.

## Changing the environment's membership

Membership is **derived**, so there is nothing to edit and nothing to recreate: the first release
registers the application from the repo's `.config/qits/deployments.yml`, and later releases update
it. Registration is a row in the deployer's own database, written in the
same transaction that reads it. The bootstrap only ever reconciles the environment row itself, by
`PATCH` — it never deletes it, because a `DELETE` tears down every container of the environment, the
deployer-managed core included.

To add a service: give the repo a `.config/qits/ci-event-release-request.yml` and a
`.config/qits/ci-event-release.yml`, a `docker/Dockerfile` and a `deployments.yml` if it needs
anything but the defaults, then open a release request for it. Add its name
to `DEPLOYABLES` in `components/qits-bootstrap/qits-bootstrap-cli`'s `PlatformModel` (plus run-args if it needs state) so
the bootstrap carries it too.

## Teardown

    ./qits-local-up.sh unwrap --dry-run           # what would go
    ./qits-local-up.sh unwrap                     # containers, networks and images; volumes stay
    ./qits-local-up.sh unwrap --with-data-volumes # also the qits-*-data volumes (dbs, registry blobs, git origins); config volumes stay
    ./qits-local-up.sh unwrap --with-volumes      # ALL local state, the config volumes included

`--with-data-volumes` is the reset that keeps identity: the run-args config volume (push token,
client secrets) and `.qits-bootstrap.env` survive, so the next bootstrap reuses every recorded
credential instead of minting new ones.

`unwrap` sweeps both label namespaces — `qits.platform.deployments.*` and the retired
`qits.cd.*` — so it also cleans a machine last bootstrapped before the merge-back.

**`--with-volumes` destroys the git host.** Its repositories are the platform's own origins, and
the release train pushes tags there and not to GitHub, so check for anything the git host holds
alone before running it:

    git ls-remote --tags https://githost.qits.<domain>/artifacts/git/<repo>
    git ls-remote --tags https://github.com/QuicklyIterateTheSoftware/<repo>.git

A rebootstrap recreates the git host from the local checkouts, so what is committed and pushed
comes back; what only ever existed on the platform does not.
