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
| **cd-managed** | all nine: observability, stt, projects, workspaces, events, gateway, ci, artifacts, **and qits-cd itself** | qits-cd's `qits` environment (branch `main`, network `qits-net`) — cd container names, sha-addressed registry images | a git push |
| **bootstrap-made** | the ci-daemon binary, the `ci-base` step image, cd's run-args file (the `qits-cd-config` volume) | the bootstrap | a bootstrap rerun |

Every component is an application of the `qits` environment, qits-cd included, and the steady
state has **zero compose-managed containers** — the compose seed exists only for a first boot,
after which each service's own pipeline deployment *replaces* its compose original: cd's replace
cutover stops whatever holds the application's alias (H2 files and published host ports allow
exactly one holder), starts the fresh container, health-gates it, and only then removes what it
stopped; a failed gate restarts it.

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

## Updating qits-cd

The same push as everything else — the handoff does the rest. If the new cd's gate fails, the
referee restarts the old one and its sweep records the `FAILED` row; if the handoff dies in a
way that leaves no cd running (both crash-looping images, say), recovery is `docker start` on
the stopped predecessor or a bootstrap rerun.

## Updating the qits-ci-daemon

The one flow that still needs a bootstrap rerun **without** `QITS_SKIP_BUILD`: it rebuilds the
binary, uploads the new blob, and regenerates the run-args file pinning the new digest — after
which qits-ci must be redeployed (any push to it) to pick the new env up.

## Changing what a deployed application gets at runtime

Volumes, env and sockets come from qits-cd's `qits.cd.run-args.<application>` config, which
lives in `config/application.properties` on the `qits-cd-config` volume. The source of truth is
the properties heredoc **in the script** — edit it there and rerun (`QITS_SKIP_BUILD=1`
suffices), which rewrites the volume; cd reads the key at `docker run` time, so the next
deployment of that application (empty commit push, at worst) applies it.

## Changing the environment's membership

qits-cd has no add-application endpoint: applications are fixed at environment creation. The
script owns this — it detects that the existing `qits` environment's application count differs
from its list and recreates the environment (tearing down its containers; they redeploy on the
next pushes). To add a fifth service: give the repo a `.config/qits/ci-post-receive.yml` and a
`docker/Dockerfile`, add its name to `DEPLOYABLES` in the script (plus run-args if it needs state), and
rerun.

## Teardown

    docker ps -aq --filter label=qits.cd.environment | xargs -r docker rm -f   # cd's deployments (the whole platform)
    docker compose -p qits -f docker-compose.qits.yml down        # leftover first-boot seed, if any
    docker volume ls -q | grep '^qits-' | xargs -r docker volume rm            # ALL local state: dbs, registry, git origins
