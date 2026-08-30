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
| **deployer-managed** | all eleven: observability, idp, stt, projects, workspaces, events, platform-docs, gateway, artifacts, ci, **and qits-platform-deployments itself** | qits-platform-deployments — sha-addressed registry images, `qits-pd-` container names | a git push |
| **bootstrap-made** | the ci-daemon binary, the deployer's run-args file (the `qits-platform-deployments-config` volume — the git host's push token among them), and the seed postgres with its `qits_deployments` role and database | the bootstrap | a bootstrap rerun |
| **built and published, like anything else** | the five `qits/build-images/*` step images | qits-build-images-oci, whose own pipelines run on upstream `docker:28-dind` through the mirror | a qits-build-images-oci release, and a re-pull on any host that lost them |

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
  environment. They belong to the `dev` tier (branch `environment/dev`, network `qits-net`), deploy
  from that branch, and run as `qits-pd-dev-qits-<name>-<id8>`.
- **platform services** — the other eight, `qits-platform-deployments` included. One instance for
  the whole platform, no environment, deployed from `platform/main`, running as
  `qits-pd-platform-qits-<name>-<id8>`. The word used to be *singleton*: it named a cardinality
  where what is meant is which plane a service lives on.

`main` is the integration trunk on both planes — a push to it builds and deploys nothing. A release
reaches the platform by fast-forwarding `platform/main` onto it.

Nothing registers an application by hand: a green build on the branch that deploys a repo
registers or updates it from that repo's spec.

**The deployer holds the topology itself** — the environments, the services and the links between
them are rows in its own database, and `/platform-deployments/api/environments` is the door an
operator and the bootstrap use. That is the merge: the topology used to be `qits-serviceregistry`,
reached over HTTP, so a decision that is one transaction had to be agreed between two services.
One component, one socket, one database. It is in the compose seed beside the idp because nothing
can create the `dev` tier or deploy anything until it answers.

The steady state has **zero compose-managed containers** — the compose seed exists only for a
first boot, after which each service's own pipeline deployment *replaces* its compose original:
the deployer's replace cutover stops whatever holds the application's alias (H2 files and published
host ports allow exactly one holder), starts the fresh container, health-gates it, and only then
removes what it stopped; a failed gate restarts it.

**qits-platform-deployments updates itself via the handoff**: deploying it starts the successor
(retrying on the H2 lock under its restart policy) and launches a detached referee that stops the
old instance, awaits the successor's health gate, and removes whichever side lost — restarting the
old one on a missed gate. The successor's startup sweep adopts the deployment row it finds itself
named on. Expect the `/platform-deployments` surface to blink for a few seconds during the swap;
there is no old↔new channel — the H2 lock is the mutex, the row is the state, docker is the
lifecycle. Its run-args live in `config/application.properties` on the
`qits-platform-deployments-config` volume (not compose env) exactly so the successor inherits them.

The gateway's pipeline publishes the **local** (unauthenticated) variant on purpose: this flow
feeds a one-machine platform; anything fronting more than one machine builds the oauth variant
and must not consume that image.

## First run

From this repo's root, submodules initialised (sources are cloned from your local checkouts,
local commits included — GitHub `main` is only the fallback):

    ./qits-local-up.sh

It runs **on the host** now, not as a container: the script compiles `components/qits-bootstrap/qits-bootstrap-cli` and
runs the binary, which shells the host's docker and git. Nothing needs the socket mounted. The run
shows what it is doing on the terminal and at `http://localhost:8480` in a browser.
`./qits-local-up.sh unwrap` takes the platform off the machine again.

It writes `docker-compose.qits.yml` and `.qits-bootstrap.env` back into this directory. Both are
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

The everyday loop, and it has two doors into `main`.

**Release is the normal one.** `POST /workspaces/api/workspaces/<id>/release` merges the
workspace's branch into `main`, stamps the calendar version onto the merge commit itself
(`release(2026.801.55529): …`) and pushes that commit to the git host — an ordinary push, so
everything in the paragraph below happens exactly as it always did. It then fast-forwards
`environment/dev` to the same commit, which is the push that deploys; a non-fast-forward is an
error the release reports rather than forces. It also publishes an `SCMRelease` event on the bus.

Its sibling `POST /workspaces/api/workspaces/<id>/integrate` merges into the branch's **parent**
branch instead — a `task/…` landing on its `epic/…` — with no version, no bump and no event. Aimed
at a workspace whose parent is `main` it refuses with 409 `reason: RELEASE_REQUIRED`. Only release
writes `main`.

**A direct push is the escape hatch, and the deployment decides whether it exists.** What deploys
is a push to `environment/dev` — pushing only `main` builds the image and stops there. `main` is a
protected ref on the git host, so updating it needs a push option carrying this host's configured
push token; `environment/dev` is not protected, but carry the token there too and one command
shape covers both:

    cd components/qits-observability/qits-observability-service
    git commit ...
    git push -o qits.token=local-dev http://localhost:8080/artifacts/git/qits-observability \
        main HEAD:environment/dev

For a platform service it is the `platform/main` push that deploys, and `environment/dev` that does
nothing. Both refs in one push means two CI runs of the same commit —
add `-o qits.no-ci` to a separate push of the ref that is not deploying if the second cold build
is worth avoiding.

`local-dev` is what `qits-local-up.sh` configures; `QITS_PUSH_TOKEN` changes it. A deployment that
configures **no** token has no escape hatch at all — unset matches nothing, and neither does empty,
so there is deliberately no "leave it blank and it opens". The option travels inside the pack
protocol rather than in a header, so the same command works through the gateway (`:8080`), against
`qits-artifacts:8080` on qits-net, and against the host-mapped `:8081`. Creating a ref is never
guarded, only updating or deleting the default one — which is why the bootstrap's first push of a
fresh repo needs nothing.

That push IS the deployment: post-receive → qits-ci runs the repo's
`.config/qits/ci-post-receive.yml` (build `docker/Dockerfile`, push
`localhost:8081/qits/<repo>:<sha>`) → green run announces the branch and sha to
qits-platform-deployments → the deployer reads the repo's `deployments.yml` at that sha, registers
the application if it is new, pulls, health-gates the fresh container on `qits-net`, and only then
removes the old one. Watch it land:

    docker ps                                                          # the step container, then the new deployment
    curl -s localhost:8080/platform-deployments/api/environments       # the environment id
    curl -s 'localhost:8080/platform-deployments/api/deployments?environmentId=<id>' | jq   # newest-first, with detail on failures
    curl -s localhost:8080/platform-deployments/api/applications | jq  # environment apps and platform services, flattened

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

## Updating qits-platform-deployments

The same push as everything else — the deployer is a platform service, so `platform/main` is the
ref that deploys it, and its deployment is not in the environment's listing. What differs is the
cutover: it cannot stop its own container in-process, so it hands over. The handoff does the rest.
If the successor's gate fails, the referee restarts the old one and its sweep records the `FAILED`
row; if the handoff dies in a way that leaves no deployer running (both crash-looping images, say),
recovery is `docker start` on the stopped predecessor or a bootstrap rerun.

## Updating the qits-ci-daemon

The one flow that still needs a bootstrap rerun **without** `QITS_SKIP_BUILD`: it rebuilds the
binary, uploads the new blob, and regenerates the run-args file pinning the new digest — after
which qits-ci must be redeployed (any push to it) to pick the new env up.

## The base images pull through the platform's own mirror

Every committed Dockerfile `FROM`s `localhost:8081/quay/…` or `localhost:8081/redhat/…`:
qits-artifacts is a pull-through cache for the upstream registries, one namespace per registered
upstream (`quay`, `redhat`, `hub`). The first pull of a reference fetches from its upstream,
verifies the digest and keeps the bytes forever; every later pull is served from disk. Once a
base image has been pulled once, every later build succeeds with the internet down — an expired
tag serves stale, and only a never-cached reference fails (502, naming the upstream). Manage the
upstreams in the explorer at `/artifacts/` → Mirrors, or over
`/artifacts/api/mirror-upstreams`; deleting one stops future fetching but keeps the cache.

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

## Changing what a deployed application gets at runtime

Volumes, env and sockets come from the deployer's `qits.platform.deployments.run-args.<application>`
config, which lives in `config/application.properties` on the `qits-platform-deployments-config`
volume. The source of truth is the generated properties **in `components/qits-bootstrap/qits-bootstrap-cli`** — edit it
there and rerun (`--skip-build` suffices), which rewrites the volume; the deployer reads the key at
`docker run` time, so the next deployment of that application (empty commit push, at worst) applies
it.

## Changing the environment's membership

Membership is **derived**, so there is nothing to edit and nothing to recreate: the first green
build on `environment/dev` registers the application from the repo's `.config/qits/deployments.yml`,
and later builds update it. Registration is a row in the deployer's own database, written in the
same transaction that reads it. The bootstrap only ever reconciles the environment row itself, by
`PATCH` — it never deletes it, because a `DELETE` tears down every container of the environment, the
deployer-managed core included.

To add a service: give the repo a `.config/qits/ci-post-receive.yml`, a `docker/Dockerfile` and a
`deployments.yml` if it needs anything but the defaults, then push `environment/dev`. Add its name
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

    git ls-remote --tags http://localhost:8081/artifacts/git/<repo>
    git ls-remote --tags https://github.com/QuicklyIterateTheSoftware/<repo>.git

A rebootstrap recreates the git host from the local checkouts, so what is committed and pushed
comes back; what only ever existed on the platform does not.
