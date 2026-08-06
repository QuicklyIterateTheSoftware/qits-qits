# The local platform: bring-up and updates

Status: **working, proven end-to-end 2026-07-30** (first full run: ~13 minutes on a 24-core
workstation, all four pipeline deployments ACTIVE and healthy).

[`qits-local-up.sh`](qits-local-up.sh) bootstraps the whole platform on the workstation's docker
daemon **through the platform's own pipeline**: it hand-builds only the build/deploy core, and
that core builds and deploys everything else the way it would in production. The script's header
is the reference for knobs and known gaps; this document is the *flow* — what to run when
something changes.

Two sets to keep straight:

| set | members | managed by | updated by |
|---|---|---|---|
| **cd-managed** | all ten: observability, stt, projects, workspaces, events, gateway, ci, artifacts, idp, **and qits-cd itself** | qits-cd — sha-addressed registry images, cd container names | a git push |
| **bootstrap-made** | the ci-daemon binary, the `ci-base` step image, cd's run-args file (the `qits-cd-config` volume — the git host's push token among them) | the bootstrap | a bootstrap rerun |

The cd-managed set has two shapes, and each repo's `.config/qits/deployments.yml` says which it
is:

- **environment applications** — everything but the two below. They belong to the `dev`
  environment (branch `environment/dev`, network `qits-net`), deploy from that branch, and run as
  `qits-cd-dev-qits-<name>-<id8>`.
- **singletons** — `qits-cd` and `qits-idp`. One instance for the whole platform, no environment,
  deployed from `main`, running as `qits-cd-singleton-qits-<name>-<id8>`.

Nothing registers an application by hand: a green build on the branch that deploys a repo
registers or updates it from that repo's spec.

The steady state has **zero compose-managed containers** — the compose seed exists only for a
first boot, after which each service's own pipeline deployment *replaces* its compose original:
cd's replace cutover stops whatever holds the application's alias (H2 files and published host
ports allow exactly one holder), starts the fresh container, health-gates it, and only then
removes what it stopped; a failed gate restarts it.

**qits-cd updates itself via the handoff**: deploying `qits-cd` starts the successor (retrying
on the H2 lock under its restart policy) and launches a detached referee that stops the old
instance, awaits the successor's health gate, and removes whichever side lost — restarting the
old cd on a missed gate. The successor's startup sweep adopts the deployment row it finds itself
named on. Expect the cd API to blink for a few seconds during the swap; there is no old↔new
channel — the H2 lock is the mutex, the row is the state, docker is the lifecycle. cd's run-args
live in `config/application.properties` on the `qits-cd-config` volume (not compose env) exactly
so the successor inherits them.

The gateway's pipeline publishes the **local** (unauthenticated) variant on purpose: this flow
feeds a one-machine platform; anything fronting more than one machine builds the oauth variant
and must not consume that image.

## First run

From this repo's root, submodules initialised (sources are cloned from your local checkouts,
local commits included — GitHub `main` is only the fallback):

    docker run -it --rm \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v "$PWD":/out \
      docker:cli sh /out/qits-local-up.sh

It writes `docker-compose.qits.yml` and `.qits-bootstrap.env` (the pinned ci-daemon digest) back
into this directory. Both are generated, machine-specific state and gitignored.

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

    cd services/qits-observability
    git commit ...
    git push -o qits.token=local-dev http://localhost:8080/artifacts/git/qits-observability \
        main HEAD:environment/dev

For the two singletons (`qits-cd`, `qits-idp`) it is the `main` push that deploys, and
`environment/dev` that does nothing. Both refs in one push means two CI runs of the same commit —
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
`localhost:8081/qits/<repo>:<sha>`) → green run announces the branch and sha to qits-cd → cd reads
the repo's `deployments.yml` at that sha, registers the application if it is new, pulls,
health-gates the fresh container on `qits-net`, and only then removes the old one. Watch it land:

    docker ps                                      # the step container, then the new deployment
    curl -s localhost:8080/cd/api/environments     # the environment id
    curl -s 'localhost:8080/cd/api/deployments?environmentId=<id>' | jq   # newest-first, with detail on failures
    curl -s localhost:8080/cd/api/applications | jq  # environment apps and singletons, flattened

The deployments listing is scoped to an environment, so singleton deployments are not in it;
`docker ps` under `qits-cd-singleton-qits-*` is what shows those.

A failed build or gate leaves the previous container serving (`FAILED` / `IMAGE_MISSING` on the
deployment row, with the log tail in `detail`); nothing to clean up.

Alternatively `QITS_SKIP_BUILD=1` on a bootstrap rerun pushes every repo and skips the seed
builds — unchanged repos push up-to-date and trigger nothing.

## Updating qits-gateway / qits-artifacts / qits-ci

The same push as any other service — they are cd applications. Expect a few seconds of downtime
on gateway or artifacts updates (the replace cutover stops the old container through the health
gate; the host port rebinds when the fresh one starts). A failed gate restarts the old container.

## Updating qits-cd

The same push as everything else, except that cd is a singleton: `main` is the ref that deploys
it, and its deployment is in no environment listing. The handoff does the rest. If the new cd's
gate fails, the referee restarts the old one and its sweep records the `FAILED` row; if the
handoff dies in a way that leaves no cd running (both crash-looping images, say), recovery is
`docker start` on the stopped predecessor or a bootstrap rerun.

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

Volumes, env and sockets come from qits-cd's `qits.cd.run-args.<application>` config, which
lives in `config/application.properties` on the `qits-cd-config` volume. The source of truth is
the properties heredoc **in the script** — edit it there and rerun (`QITS_SKIP_BUILD=1`
suffices), which rewrites the volume; cd reads the key at `docker run` time, so the next
deployment of that application (empty commit push, at worst) applies it.

## Changing the environment's membership

Membership is **derived**, so there is nothing to edit and nothing to recreate: the first green
build on `environment/dev` registers the application from the repo's `.config/qits/deployments.yml`,
and later builds update it. The bootstrap only ever reconciles the environment row itself, by
`PATCH` — it never deletes it, because a `DELETE` tears down every container of the environment,
the cd-managed core included.

To add a service: give the repo a `.config/qits/ci-post-receive.yml`, a `docker/Dockerfile` and a
`deployments.yml` if it needs anything but the defaults, then push `environment/dev`. Add its name
to `DEPLOYABLES` in the script (plus run-args if it needs state) so the bootstrap carries it too.

## Teardown

    docker ps -aq --filter label=qits.cd.application | xargs -r docker rm -f   # cd's deployments, environment apps and singletons alike
    docker compose -p qits -f docker-compose.qits.yml down        # leftover first-boot seed, if any
    docker volume ls -q | grep '^qits-' | xargs -r docker volume rm            # ALL local state: dbs, registry, git origins
