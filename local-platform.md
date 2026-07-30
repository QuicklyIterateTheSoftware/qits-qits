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
| **cd-managed** | qits-observability, qits-stt, qits-projects, qits-workspaces, qits-gateway, qits-ci, qits-artifacts | qits-cd's `qits` environment (branch `main`, network `qits-net`) — cd container names, sha-addressed registry images | a git push |
| **the fixpoint** | qits-cd's own container (plus the ci-daemon binary and the `ci-base` step image) | compose (`docker-compose.qits.yml`, generated) | a bootstrap rerun |

Every component is an application of the `qits` environment, qits-cd included. The compose seed
exists only to get the ball rolling: on the first pass each seed service's own pipeline
deployment *replaces* its compose-seeded original — cd's replace cutover stops whatever holds
the application's alias (H2 files and published host ports allow exactly one holder), starts the
fresh container, health-gates it, and only then removes what it stopped; a failed gate restarts
it. The one exception is qits-cd itself: cd refuses to stop the instance performing the
deployment, so a qits-cd push publishes the image and records an honest `FAILED` row until the
planned self-update (the successor shuts down its predecessor) exists — until then cd's
container stays compose-managed and is updated by rerunning the bootstrap without
`QITS_SKIP_BUILD`. The gateway's pipeline publishes the **local** (unauthenticated) variant on
purpose: this flow feeds a one-machine platform; anything fronting more than one machine builds
the oauth variant and must not consume that image.

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

The everyday loop. Commit in the submodule, then push it to the platform's own git host — the
gateway allowlists `/artifacts/git/**`, so this works straight from the host:

    cd services/qits-observability
    git commit ...
    git push http://localhost:8080/artifacts/git/qits-observability main

That push IS the deployment: post-receive → qits-ci runs the repo's
`.config/qits/ci-post-receive.yml` (build `docker/Dockerfile`, push
`localhost:8081/qits/<repo>:<sha>`) → green run announces to qits-cd → cd pulls, health-gates the
fresh container on `qits-net`, and only then removes the old one. Watch it land:

    docker ps                                      # the step container, then the new deployment
    curl -s localhost:8080/cd/api/environments     # the environment id
    curl -s 'localhost:8080/cd/api/deployments?environmentId=<id>' | jq   # newest-first, with detail on failures

A failed build or gate leaves the previous container serving (`FAILED` / `IMAGE_MISSING` on the
deployment row, with the log tail in `detail`); nothing to clean up.

Alternatively `QITS_SKIP_BUILD=1` on a bootstrap rerun pushes every repo and skips the seed
builds — unchanged repos push up-to-date and trigger nothing.

## Updating qits-gateway / qits-artifacts / qits-ci

The same push as any other service — they are cd applications. Expect a few seconds of downtime
on gateway or artifacts updates (the replace cutover stops the old container through the health
gate; the host port rebinds when the fresh one starts). A failed gate restarts the old container.

## Updating qits-cd or the qits-ci-daemon

Rerun the bootstrap **without** `QITS_SKIP_BUILD`: it rebuilds cd's image (and the daemon binary,
uploading the new blob and pinning the new digest into qits-ci's run-args) and compose recreates
cd's container. Pushing qits-cd also publishes its pipeline image — the deployment row just
records `FAILED (self-update pending)` until the successor-shuts-down-predecessor mechanism
exists.

## Changing what a deployed application gets at runtime

Volumes, env and sockets for pipeline-deployed containers come from qits-cd's
`qits.cd.run-args.<application>` config (`QITS_CD_RUN_ARGS_*` in the generated compose). The
source of truth is the compose heredoc **in the script** — edit it there, rerun the bootstrap
(`QITS_SKIP_BUILD=1` suffices), and the next deployment of that application picks it up. cd only
reads the key at `docker run` time, so a redeploy (empty commit push, at worst) applies it.

## Changing the environment's membership

qits-cd has no add-application endpoint: applications are fixed at environment creation. The
script owns this — it detects that the existing `qits` environment's application count differs
from its list and recreates the environment (tearing down its containers; they redeploy on the
next pushes). To add a fifth service: give the repo a `.config/qits/ci-post-receive.yml` and a
`docker/Dockerfile`, add its name to `DEPLOYABLES` in the script (plus run-args if it needs state), and
rerun.

## Teardown

    docker compose -p qits -f docker-compose.qits.yml down        # the seed
    docker ps -aq --filter label=qits.cd.environment | xargs -r docker rm -f   # cd's deployments
    docker volume ls -q | grep '^qits-' | xargs -r docker volume rm            # ALL local state: dbs, registry, git origins
