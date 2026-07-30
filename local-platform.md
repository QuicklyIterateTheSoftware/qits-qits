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
| **seed** | qits-gateway (local variant), qits-artifacts, qits-ci, qits-cd, the qits-ci-daemon binary, `qits/build-images/ci-base` | compose (`docker-compose.qits.yml`, generated) | a git push + bootstrap rerun (tag swap) |
| **pipeline-deployed** | qits-observability, qits-stt, qits-projects, qits-workspaces | qits-cd's `qits` environment (branch `main`, network `qits-net`) | a git push |

The seed is hand-built only for the **first boot**: the bootstrap's last act pushes the seed
repos through the pipeline too (publish-only — no environment tracks them) and re-points the
running containers at those images, so the final state is pipeline-produced end to end. What
stays genuinely hand-built: the `ci-base` step image and the ci-daemon binary — the two things
the pipeline cannot yet make for itself. The gateway's pipeline publishes the **local**
(unauthenticated) variant on purpose: this flow feeds a one-machine platform; a deployment that
fronts anything beyond one machine builds the oauth variant and must not consume that image.

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

## Updating a seed service

Commit in qits-gateway / qits-artifacts / qits-ci / qits-cd, then rerun the bootstrap with
`QITS_SKIP_BUILD=1`: it pushes the seed repos through the pipeline, waits for the published
images, re-tags them over `qits/<name>:latest` and `up -d` recreates exactly the changed
containers. (The push-only fast path from the section above also works to *publish* a seed
image, but nothing re-points the running container until a bootstrap rerun does the swap.)

A qits-ci-daemon change is the one seed flow that still needs a full rerun **without**
`QITS_SKIP_BUILD` — the rerun rebuilds the binary, uploads the new blob, and the regenerated
compose pins the new digest on qits-ci.

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
`docker/Dockerfile`, add its name to `APPS` in the script (plus run-args if it needs state), and
rerun.

## Teardown

    docker compose -p qits -f docker-compose.qits.yml down        # the seed
    docker ps -aq --filter label=qits.cd.environment | xargs -r docker rm -f   # cd's deployments
    docker volume ls -q | grep '^qits-' | xargs -r docker volume rm            # ALL local state: dbs, registry, git origins
