#!/bin/sh
# qits-local-up.sh — bootstrap the qits platform on your workstation's docker daemon, THROUGH the
# platform's own pipeline. Meant to be run as a throwaway container from the qits-qits repo root:
#
#   docker run -it --rm \
#     -v /var/run/docker.sock:/var/run/docker.sock \
#     -v "$PWD":/out \
#     docker:cli sh /out/qits-local-up.sh
#
# The architecture, in one line: hand-build the platform's build/deploy core once to get the ball
# rolling — from then on the platform deploys ALL of its components through its own pipeline.
#
# Every deployable (observability, stt, projects, workspaces, gateway, artifacts, ci, cd) is an
# application of qits-cd's "qits" main environment (branch main, network qits-net): pushed to the
# platform's git host, built by qits-ci from the repo's own .config/qits/ci-post-receive.yml,
# published to the platform's registry, and cut over by qits-cd's replace cutover — which stops
# whatever holds the application's alias first, so even the compose-seeded originals of the first
# boot hand themselves over and reappear under cd's own container names.
#
# qits-cd updates ITSELF via the handoff: deploying qits-cd starts the successor, a detached
# referee stops the old instance and arbitrates the health gate, and the successor's startup
# sweep adopts the deployment row. cd's run-args therefore live on the qits-cd-config volume
# (config/application.properties) rather than in compose env — the successor must inherit them.
# Still hand-built: the ci-base step image and the ci-daemon binary — the two things the
# pipeline cannot make for itself.
#
# Everything durable — images, containers, volumes, qits-net — lands on the HOST daemon through
# the mounted socket; this container is disposable. The generated compose file (the seed stack
# only) is copied to /out, along with .qits-bootstrap.env recording the ci-daemon digest.
#
# When /out is the qits-qits repo (submodules initialised), sources are cloned FROM YOUR LOCAL
# CHECKOUTS — local commits included, which is what makes this a dev loop: commit in a submodule,
# rerun with QITS_SKIP_BUILD=1, and the push redeploys it through the pipeline. Without that,
# sources come from GitHub main.
#
# Cost, honestly: every seed image and every pipeline run is a cold GraalVM native build (~4 GB
# RAM, maven downloads uncached). First run is measured in hours, not minutes. Reruns skip what
# exists (QITS_SKIP_BUILD=1 for the seed; unchanged repos push up-to-date and trigger nothing).
#
# Knobs (env):
#   QITS_ORG_URL        git org for GitHub fallback (default https://github.com/QuicklyIterateTheSoftware)
#   QITS_PORT           host port the gateway publishes             (default 8080)
#   QITS_REGISTRY_PORT  host port qits-artifacts publishes for the  (default 8081)
#                       DOCKER DAEMON's pulls/pushes — localhost registries are HTTP-allowed
#                       by docker without daemon config, which is the whole trick
#   QITS_SKIP_BUILD     1 = seed images + daemon binary exist, skip to compose/push
#   QITS_DEPLOY_TIMEOUT seconds to wait per application deployment  (default 3600)
#
# Known gaps, stated rather than hidden:
#   - qits-dns and qits-spa-home ship no Dockerfile and are not part of either set. qits-projects
#     announces to qits-dns fire-and-forget; its absence is one WARN per project creation.
#   - qits/workspace:latest layers the daemon onto a toolchain base this script cannot conjure;
#     workspace containers need that image supplied separately.
#   - The gateway is built with QITS_VARIANT=local: EXPLICITLY UNAUTHENTICATED. Never publish the
#     image or the port beyond your machine.
#   - Until qits-observability's deployment goes ACTIVE, every seed service logs an OTLP export
#     warning per batch. It self-heals the moment the alias resolves.

set -eu

ORG_URL=${QITS_ORG_URL:-https://github.com/QuicklyIterateTheSoftware}
PORT=${QITS_PORT:-8080}
REGISTRY_PORT=${QITS_REGISTRY_PORT:-8081}
SKIP_BUILD=${QITS_SKIP_BUILD:-0}
DEPLOY_TIMEOUT=${QITS_DEPLOY_TIMEOUT:-3600}
SRC=${QITS_SRC:-/qits-src}

# The seed: hand-built for the FIRST boot only. On later runs any of these already replaced by a
# cd deployment is skipped at compose-up, and the deploy loop below hands the rest over.
CORE="gateway artifacts ci cd"
# Everything the platform deploys through itself — the environment's applications. Order matters:
# observability first (quiets OTLP warnings earliest), the seed's own repos last, cd at the very
# end (its deployment is the self-update handoff: the cd API blinks while the successor takes
# over and adopts the row).
DEPLOYABLES="observability stt projects workspaces gateway artifacts ci cd"

ENV_NAME=qits
ARTIFACTS=http://qits-artifacts:8080
CD=http://qits-cd:8080

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m !! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }

repo_path() { case "$1" in ci-daemon) echo "daemons/qits-ci-daemon";; *) echo "services/qits-$1";; esac; }

# --- preflight -----------------------------------------------------------------------------------
say "preflight"
docker version >/dev/null 2>&1 \
  || die "cannot reach a docker daemon — run with -v /var/run/docker.sock:/var/run/docker.sock"
docker compose version >/dev/null 2>&1 \
  || die "docker compose plugin missing — use the docker:cli image (or newer docker CLI)"
for tool in git curl jq; do
  command -v "$tool" >/dev/null 2>&1 || {
    say "installing $tool"
    if   command -v apk      >/dev/null 2>&1; then apk add --no-cache -q "$tool"
    elif command -v microdnf >/dev/null 2>&1; then microdnf -y install "$tool"
    elif command -v apt-get  >/dev/null 2>&1; then apt-get -qq update && apt-get -qq install -y "$tool"
    else die "no $tool and no known package manager"
    fi
  }
done
# The local checkouts under /out belong to the host user, and this container is root — without
# this, git refuses them as dubiously owned and every local-source clone fails.
git config --global --add safe.directory '*'
# This script joins qits-net mid-run to talk to the seed services directly (their APIs publish no
# host ports), which only works when it IS a container on the same daemon.
SELF=$(cat /etc/hostname)
docker inspect "$SELF" >/dev/null 2>&1 \
  || die "not running as a container on the mounted daemon — use the docker run from the header"
DOCKER_GID=$(stat -c %g /var/run/docker.sock 2>/dev/null || echo 0)

# --- sources -------------------------------------------------------------------------------------
say "cloning sources into $SRC"
mkdir -p "$SRC"
# DEPLOYABLES covers the CORE names, so one pass clones everything.
for name in ci-daemon $DEPLOYABLES; do
  repo="qits-$name"
  local_src="/out/$(repo_path "$name")"
  if [ -e "$local_src/.git" ]; then from="$local_src"; else from="$ORG_URL/$repo.git"; fi
  if [ -d "$SRC/$repo/.git" ]; then
    git -C "$SRC/$repo" pull --ff-only -q 2>/dev/null || warn "$repo: pull failed, using what is checked out"
  else
    git clone -q --branch main --single-branch "$from" "$SRC/$repo"
  fi
  printf '  %-22s %s  (%s)\n' "$repo" "$(git -C "$SRC/$repo" rev-parse --short HEAD)" "$from"
done

# --- seed builds ---------------------------------------------------------------------------------
if [ "$SKIP_BUILD" != 1 ]; then
  say "building the seed images (GraalVM native — ~4 GB RAM each, this takes a while)"
  for name in $CORE; do
    say "build qits/$name:latest"
    extra=""
    # A shipped gateway must say whether it authenticates; `local` is the unauthenticated
    # workstation variant.
    [ "$name" = gateway ] && extra="--build-arg QITS_VARIANT=local"
    # shellcheck disable=SC2086
    docker build -t "qits/$name:latest" -f "$SRC/qits-$name/docker/Dockerfile" $extra "$SRC/qits-$name" \
      || die "build of qits/$name failed"
  done

  # The step image pipeline configs name. Contract: git, bash, wget-or-curl (the ci-daemon
  # bootstrap), plus the docker CLI for docker:true publish steps. Nothing in the tree builds
  # this yet, so the bootstrap does.
  say "build qits/build-images/ci-base:latest"
  printf 'FROM docker:cli\nRUN apk add --no-cache git bash curl\n' \
    | docker build -q -t qits/build-images/ci-base:latest - >/dev/null

  # The ci-daemon: a fully static musl native binary. Its documented recipe runs mvnw on the host
  # with container-build=true; inside this container that would need bind mounts the socket
  # boundary cannot honour (paths resolve on the HOST), so the build runs INSIDE the builder
  # image instead — docker cp carries the source in and the binary out, and container-build is
  # switched off because we are already in the container it would launch.
  say "build the qits-ci-daemon binary (musl static native)"
  docker build -t qits/graalvmce-musl-builder:jdk-25 \
    -f "$SRC/qits-ci-daemon/docker/Dockerfile.musl-builder" "$SRC/qits-ci-daemon/docker"
  # --entrypoint: the builder image entrypoints to native-image itself.
  cid=$(docker create --user root --entrypoint bash qits/graalvmce-musl-builder:jdk-25 \
    -c 'cd /qits-build && ./mvnw -B -ntp -pl ci-daemon -am package -Dnative -DskipTests -Dquarkus.native.container-build=false')
  docker cp "$SRC/qits-ci-daemon" "$cid:/qits-build"
  docker start -a "$cid" || { docker rm -f "$cid" >/dev/null; die "ci-daemon build failed"; }
  docker cp "$cid:/qits-build/ci-daemon/target/qits-ci-daemon" /qits-ci-daemon
  docker rm "$cid" >/dev/null
  DAEMON_SHA=$(sha256sum /qits-ci-daemon | cut -d' ' -f1)
  say "ci-daemon digest: sha256:$DAEMON_SHA"
  [ -d /out ] && printf 'DAEMON_SHA=%s\n' "$DAEMON_SHA" > /out/.qits-bootstrap.env
else
  # The digest is the one run-pinned value the compose file needs; a skip-build rerun reads the
  # recorded one.
  [ -f /out/.qits-bootstrap.env ] && . /out/.qits-bootstrap.env
  [ -n "${DAEMON_SHA:-}" ] || die "QITS_SKIP_BUILD=1 but no recorded DAEMON_SHA (/out/.qits-bootstrap.env)"
fi

# --- the seed compose ----------------------------------------------------------------------------
say "generating the seed compose file"
if [ -d /out ]; then COMPOSE=/out/docker-compose.qits.yml; else COMPOSE=/tmp/docker-compose.qits.yml; fi

cat > "$COMPOSE" <<EOF
# Generated by qits-local-up.sh — the SEED of the local qits platform: only the services that
# build and deploy the rest. Everything else (observability, stt, projects, workspaces) is
# deployed by qits-cd through the main pipeline and is deliberately NOT in this file — look for
# it in \`docker ps\` under qits-cd-qits-* container names, redeployed on every green push.
#
# Manage with: docker compose -p qits -f $(basename "$COMPOSE") ps|logs -f|down
# (compose down leaves cd-deployed containers running; remove those via cd's API or docker.)

name: qits

networks:
  qits-net:
    # The one shared network: seed services, cd-deployed applications and ci step containers all
    # join it and resolve each other by alias. External because the bootstrap (or a previous
    # stack, or qits-ci's own boot) may have created it already — compose refuses to adopt a
    # network it did not label.
    name: qits-net
    external: true

volumes:
  # The three-way on-disk contract (bare git origins): qits-projects clones into it,
  # qits-artifacts serves it, qits-workspaces branches from it — and the bootstrap seeds the
  # platform's own repos into it. Explicitly named: cd's run-args reference these volumes by name.
  qits-repositories:
    name: qits-repositories
  qits-artifacts-data:
    name: qits-artifacts-data
  qits-ci-data:
    name: qits-ci-data
  qits-cd-data:
    name: qits-cd-data
  # Mounted by cd-DEPLOYED containers via qits.cd.run-args, not by any service below.
  qits-projects-data:
    name: qits-projects-data
  qits-workspaces-data:
    name: qits-workspaces-data
  qits-stt-data:
    name: qits-stt-data
  # cd's run-args config (config/application.properties), written by the bootstrap. A volume
  # rather than env so a self-update's successor inherits it — env cannot nest these values.
  qits-cd-config:
    name: qits-cd-config

services:
  qits-gateway:
    image: qits/gateway:latest
    container_name: qits-gateway
    ports:
      - "${PORT}:8080"
    environment:
      # The route table: an entry is both the on-switch and the target. Aliases of the
      # pipeline-deployed four resolve the moment cd cuts them over; until then those routes 502.
      QITS_GATEWAY_PROXY_HOSTS_ARTIFACTS: qits-artifacts   # also claims root-level /v2 (OCI registry)
      QITS_GATEWAY_PROXY_HOSTS_CI: qits-ci
      QITS_GATEWAY_PROXY_HOSTS_CD: qits-cd
      QITS_GATEWAY_PROXY_HOSTS_OBSERVABILITY: qits-observability
      QITS_GATEWAY_PROXY_HOSTS_PROJECTS: qits-projects
      QITS_GATEWAY_PROXY_HOSTS_WORKSPACES: qits-workspaces
      QITS_GATEWAY_PROXY_HOSTS_STT: qits-stt
    networks: [qits-net]
    # No depends_on: on later runs compose starts only the services cd does not already manage,
    # and a dependency would resurrect a compose sibling next to its cd-managed replacement.
    restart: unless-stopped

  qits-artifacts:
    image: qits/artifacts:latest
    container_name: qits-artifacts
    ports:
      # For the HOST daemon only: ci publish steps push and cd pulls through the host's docker
      # daemon, which cannot resolve qits-net aliases. localhost:${REGISTRY_PORT} is in docker's
      # default insecure list, so plain HTTP needs no daemon config.
      - "127.0.0.1:${REGISTRY_PORT}:8080"
    environment:
      QUARKUS_DATASOURCE_ARTIFACTS_JDBC_URL: jdbc:h2:file:/data/artifacts/h2/artifacts
      QITS_ARTIFACTS_BLOBS_DIR: /data/artifacts/blobs
      # Where the git host's post-receive hook delivers. Fire-and-forget: wrong host = CI
      # silently never runs.
      QITS_CI_INTAKE_URL: http://qits-ci:8080/ci/api/events/post-receive
    volumes:
      - qits-artifacts-data:/data
      - qits-repositories:/data/repositories
    networks: [qits-net]
    restart: unless-stopped

  qits-ci:
    image: qits/ci:latest
    container_name: qits-ci
    # Unprivileged uid stays; the socket group is all it needs.
    group_add: ["${DOCKER_GID}"]
    environment:
      QUARKUS_DATASOURCE_CI_JDBC_URL: jdbc:h2:file:/data/ci/h2/ci
      # ci's own fetch of the pushed ref, and the same base as seen from inside a step
      # container — steps join qits-net, so both resolve the git host directly.
      QITS_CI_GIT_HOST_URL: http://qits-artifacts:8080/artifacts
      QITS_CI_CONTAINER_GIT_URL: http://qits-artifacts:8080/artifacts
      QITS_CI_NETWORK: qits-net
      # Injected into publish steps as QITS_REGISTRY: dialled by the HOST daemon (see the
      # qits-artifacts ports note).
      QITS_ARTIFACTS_REGISTRY_HOST: localhost:${REGISTRY_PORT}
      # The binary every step container downloads and execs — uploaded by this bootstrap, digest
      # pinned. Blank would mean every run fails as never-registered.
      QITS_CI_DAEMON_VERSION: "${DAEMON_SHA}"
    volumes:
      - qits-ci-data:/data
      - /var/run/docker.sock:/var/run/docker.sock
    networks: [qits-net]
    restart: unless-stopped

  qits-cd:
    image: qits/cd:latest
    container_name: qits-cd
    group_add: ["${DOCKER_GID}"]
    environment:
      QUARKUS_DATASOURCE_CD_JDBC_URL: jdbc:h2:file:/data/cd/h2/cd
      # cd pulls through the HOST daemon too — same reasoning as ci's registry host.
      QITS_ARTIFACTS_REGISTRY_HOST: localhost:${REGISTRY_PORT}
      # Per-application run-args live in the qits-cd-config volume (config/application.properties,
      # written below), NOT here: a self-update's successor must inherit them, and env cannot
      # nest those values.
    volumes:
      - qits-cd-data:/data
      - qits-cd-config:/work/config
      - /var/run/docker.sock:/var/run/docker.sock
    networks: [qits-net]
    restart: unless-stopped
EOF

# cd's per-application run arguments, as a config file on a named volume: quarkus reads
# config/application.properties next to the binary (the cd image's WORKDIR is /work), and a
# self-update's successor mounts the same volume via its own run-args entry below — which is the
# whole reason this is a file and not compose env.
say "writing cd's run-args config volume"
cat > /tmp/cd-run-args.properties <<RUNARGS
# Generated by qits-local-up.sh — qits.cd.run-args.<application>: what each deployed container
# needs beyond its image. Whitespace-split, appended verbatim between cd's flags and the image.
qits.cd.run-args.qits-gateway=-p ${PORT}:8080 -e QITS_GATEWAY_PROXY_HOSTS_ARTIFACTS=qits-artifacts -e QITS_GATEWAY_PROXY_HOSTS_CI=qits-ci -e QITS_GATEWAY_PROXY_HOSTS_CD=qits-cd -e QITS_GATEWAY_PROXY_HOSTS_OBSERVABILITY=qits-observability -e QITS_GATEWAY_PROXY_HOSTS_PROJECTS=qits-projects -e QITS_GATEWAY_PROXY_HOSTS_WORKSPACES=qits-workspaces -e QITS_GATEWAY_PROXY_HOSTS_STT=qits-stt
qits.cd.run-args.qits-artifacts=-p 127.0.0.1:${REGISTRY_PORT}:8080 -v qits-artifacts-data:/data -v qits-repositories:/data/repositories -e QUARKUS_DATASOURCE_ARTIFACTS_JDBC_URL=jdbc:h2:file:/data/artifacts/h2/artifacts -e QITS_ARTIFACTS_BLOBS_DIR=/data/artifacts/blobs -e QITS_CI_INTAKE_URL=http://qits-ci:8080/ci/api/events/post-receive
qits.cd.run-args.qits-ci=-v qits-ci-data:/data -v /var/run/docker.sock:/var/run/docker.sock --group-add ${DOCKER_GID} -e QUARKUS_DATASOURCE_CI_JDBC_URL=jdbc:h2:file:/data/ci/h2/ci -e QITS_CI_GIT_HOST_URL=http://qits-artifacts:8080/artifacts -e QITS_CI_CONTAINER_GIT_URL=http://qits-artifacts:8080/artifacts -e QITS_CI_NETWORK=qits-net -e QITS_ARTIFACTS_REGISTRY_HOST=localhost:${REGISTRY_PORT} -e QITS_CI_DAEMON_VERSION=${DAEMON_SHA}
qits.cd.run-args.qits-cd=-v qits-cd-data:/data -v qits-cd-config:/work/config -v /var/run/docker.sock:/var/run/docker.sock --group-add ${DOCKER_GID} -e QUARKUS_DATASOURCE_CD_JDBC_URL=jdbc:h2:file:/data/cd/h2/cd -e QITS_ARTIFACTS_REGISTRY_HOST=localhost:${REGISTRY_PORT}
qits.cd.run-args.qits-stt=-v qits-stt-data:/data -e QITS_SPEECH_HOME=/data/speech
qits.cd.run-args.qits-projects=-v qits-projects-data:/data -v qits-repositories:/data/repositories -e QUARKUS_DATASOURCE_PROJECTS_JDBC_URL=jdbc:h2:file:/data/projects/h2/projects -e QUARKUS_DATASOURCE_EPICS_JDBC_URL=jdbc:h2:file:/data/epics/h2/epics
qits.cd.run-args.qits-workspaces=-v qits-workspaces-data:/data -v qits-repositories:/data/repositories -v /var/run/docker.sock:/var/run/docker.sock --group-add ${DOCKER_GID} -e QUARKUS_DATASOURCE_WORKSPACES_JDBC_URL=jdbc:h2:file:/data/workspaces/h2/workspaces -e QITS_PROJECTS_URL=http://qits-projects:8080
RUNARGS
docker volume create qits-cd-config >/dev/null
docker run --rm -i -v qits-cd-config:/cfg --entrypoint sh alpine/git \
  -c 'cat > /cfg/application.properties && chown 1001:0 /cfg/application.properties' \
  < /tmp/cd-run-args.properties

say "starting the seed stack"
docker network inspect qits-net >/dev/null 2>&1 || docker network create qits-net >/dev/null
# Only what cd does not already manage: a compose service whose application has a live cd-managed
# container must NOT be resurrected next to it — cd's own container included, once a self-update
# handoff has made cd one of its own deployments.
UP=""
for name in cd gateway artifacts ci; do
  if docker ps --format '{{.Names}}' | grep -q "^qits-cd-$ENV_NAME-qits-$name-"; then
    echo "  qits-$name is cd-managed — compose leaves it alone"
  else
    UP="$UP qits-$name"
  fi
done
if [ -n "$UP" ]; then
  # shellcheck disable=SC2086
  docker compose -p qits -f "$COMPOSE" up -d $UP
else
  echo "  the whole seed is cd-managed — compose has nothing to start"
fi

# --- join the platform's network -----------------------------------------------------------------
docker network connect qits-net "$SELF" 2>/dev/null || true

wait_seed() {
  for name in artifacts ci cd; do
    i=0
    until curl -fsS -o /dev/null "http://qits-$name:8080/$name/q/health/ready"; do
      i=$((i + 5)); [ "$i" -gt 120 ] && die "qits-$name not ready after 120s — docker logs qits-$name"
      sleep 5
    done
    echo "  qits-$name ready"
  done
}
say "waiting for the seed services"
wait_seed

# --- publish the ci-daemon binary ----------------------------------------------------------------
say "publishing the ci-daemon binary to the registry"
if curl -fsS -o /dev/null "$ARTIFACTS/v2/qits/ci-daemon/blobs/sha256:$DAEMON_SHA"; then
  echo "  blob already present"
else
  [ -f /qits-ci-daemon ] || die "daemon binary not in this container and blob absent — rerun without QITS_SKIP_BUILD"
  code=$(curl -s -o /tmp/upload.out -w '%{http_code}' -X POST \
    -H 'Content-Type: application/octet-stream' --data-binary @/qits-ci-daemon \
    "$ARTIFACTS/v2/qits/ci-daemon/blobs/uploads/?digest=sha256:$DAEMON_SHA")
  [ "$code" = 201 ] || die "daemon upload answered $code: $(cat /tmp/upload.out)"
  echo "  uploaded sha256:$DAEMON_SHA"
fi

# --- the platform's own repositories on its own git host -----------------------------------------
# repoId doubles as the on-disk directory and the clone path; the charset allows readable names,
# and readable beats capability-opaque on a workstation.
say "seeding the platform's repositories on the git host"
for name in $DEPLOYABLES; do
  docker run --rm -v qits-repositories:/repos --entrypoint sh alpine/git -c \
    "git init -q --bare -b main /repos/qits-$name/origin && chown -R 1001:0 /repos/qits-$name"
  echo "  qits-$name -> /artifacts/git/qits-$name"
done

# --- the main environment ------------------------------------------------------------------------
# One standing environment: branch main, the shared network (cd adopts an existing network rather
# than recreating it), one application per pipeline-deployed repo. The name 'qits' is deliberate:
# qits-projects' self-seed will later announce the same name and land on the idempotent 409.
say "creating the '$ENV_NAME' main environment in qits-cd"
apps_json=$(for name in $DEPLOYABLES; do
  hp="/$name/q/health/ready"
  # The gateway's non-application root is /q — it owns the whole path space, no segment prefix.
  [ "$name" = gateway ] && hp="/q/health/ready"
  printf '{"repoId":"qits-%s","name":"qits-%s","healthPath":"%s"}\n' "$name" "$name" "$hp"
done | jq -s .)
payload=$(jq -n --argjson apps "$apps_json" \
  '{name: "'"$ENV_NAME"'", branch: "main", network: "qits-net", applications: $apps}')
code=$(curl -s -o /tmp/env.out -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -d "$payload" "$CD/cd/api/environments")
case "$code" in
  201) ENV_ID=$(jq -r .environment.id /tmp/env.out) ;;
  409)
    ENV_ID=$(curl -fsS "$CD/cd/api/environments" \
      | jq -r --arg n "$ENV_NAME" '.environments[] | select(.name == $n) | .id')
    have=$(curl -fsS "$CD/cd/api/environments/$ENV_ID" | jq '.environment.applications | length')
    if [ "$have" != "$(echo "$apps_json" | jq length)" ]; then
      # A leftover or seed-created environment without our applications; cd has no
      # add-application endpoint, so replace it (tears down its containers; they redeploy).
      warn "environment '$ENV_NAME' exists with $have applications — recreating"
      curl -fsS -X DELETE "$CD/cd/api/environments/$ENV_ID" >/dev/null
      code=$(curl -s -o /tmp/env.out -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
        -d "$payload" "$CD/cd/api/environments")
      [ "$code" = 201 ] || die "environment re-create answered $code: $(cat /tmp/env.out)"
      ENV_ID=$(jq -r .environment.id /tmp/env.out)
    fi
    ;;
  *) die "environment create answered $code: $(cat /tmp/env.out)" ;;
esac
echo "  environment $ENV_NAME ($ENV_ID)"

# --- push, build, deploy — one application at a time ---------------------------------------------
# Sequential on purpose: each push triggers a cold native build on the host daemon (~4 GB), and a
# workstation rarely wants eight at once. Every deployable takes the same path — push, and if the
# push was a no-op but the application still lacks an ACTIVE deployment at HEAD (a recreated
# environment, an image published on an earlier run), the build-succeeded event is posted by hand:
# the intake is open on qits-net and the image is already in the registry.
say "pushing the platform through its own pipeline"
overall=0
for name in $DEPLOYABLES; do
  repo="qits-$name"
  say "$repo: push -> ci build -> cd deploy"
  # The pipeline config is committed in the repos; older checkouts get it overlaid here so the
  # bootstrap never pushes a repo that triggers nothing.
  if [ ! -f "$SRC/$repo/.config/qits/ci-post-receive.yml" ]; then
    warn "$repo has no pipeline config — overlaying the standard publish step"
    mkdir -p "$SRC/$repo/.config/qits"
    cat > "$SRC/$repo/.config/qits/ci-post-receive.yml" <<PIPELINE
steps:
  - image: qits/build-images/ci-base:latest
    docker: true
    timeout-seconds: 3600
    script: |
      ref="\$QITS_REGISTRY/\$QITS_IMAGE_REPOSITORY/$repo:\$QITS_CI_SHA"
      docker build -t "\$ref" -f docker/Dockerfile .
      docker push "\$ref"
      docker rmi "\$ref" || true
PIPELINE
    git -C "$SRC/$repo" add .config/qits/ci-post-receive.yml
    git -C "$SRC/$repo" -c user.name=qits-bootstrap -c user.email=bootstrap@qits.invalid \
      commit -q -m "Opt into CI: publish this repo's image from a green push"
  fi

  out=$(git -C "$SRC/$repo" push "$ARTIFACTS/artifacts/git/$repo" main 2>&1) || die "push of $repo failed: $out"
  sha=$(git -C "$SRC/$repo" rev-parse HEAD)

  newest() {
    curl -fsS "$CD/cd/api/deployments?environmentId=$ENV_ID" \
      | jq -r --arg n "$repo" '[.deployments[] | select(.applicationName == $n)][0] // {}'
  }

  row=$(newest)
  if [ "$(echo "$row" | jq -r .status)" = ACTIVE ] && [ "$(echo "$row" | jq -r .commitSha)" = "$sha" ]; then
    echo "  $repo already ACTIVE at $(echo "$sha" | cut -c1-7)"
    continue
  fi
  if echo "$out" | grep -qiE 'up.to.date'; then
    # No push, no event — but no ACTIVE deployment at HEAD either. The image exists from an
    # earlier run; hand cd the event it never got.
    echo "  $repo unchanged but not deployed at HEAD — posting the build event"
    curl -fsS -o /dev/null -X POST -H 'Content-Type: application/json' \
      -d "{\"runId\":\"bootstrap\",\"repoId\":\"$repo\",\"branch\":\"main\",\"commitSha\":\"$sha\"}" \
      "$CD/cd/api/events/build-succeeded"
  else
    echo "  pushed $(echo "$sha" | cut -c1-7), waiting for the deployment (a cold native build — be patient)"
  fi

  waited=0
  while :; do
    row=$(newest)
    status=$(echo "$row" | jq -r '.status // "PENDING"')
    if [ "$(echo "$row" | jq -r '.commitSha // ""')" = "$sha" ]; then
      case "$status" in
        ACTIVE)
          echo "  $repo ACTIVE ($(echo "$row" | jq -r .containerName))"; break ;;
        FAILED|IMAGE_MISSING)
          warn "$repo deployment $status: $(echo "$row" | jq -r '.detail // "no detail"' | head -c 400)"
          overall=1
          break ;;
      esac
    fi
    waited=$((waited + 10))
    [ "$waited" -ge "$DEPLOY_TIMEOUT" ] && { warn "$repo: no terminal deployment after ${DEPLOY_TIMEOUT}s (ci may still be building — watch docker ps and qits-ci logs)"; overall=1; break; }
    sleep 10
  done
done

# --- summary -------------------------------------------------------------------------------------
say "the platform"
docker ps --format 'table {{.Names}}\t{{.Status}}' | grep -E 'qits|NAMES' || true
echo
echo "gateway:   http://localhost:${PORT}/            (variant: local, UNAUTHENTICATED)"
echo "registry:  localhost:${REGISTRY_PORT} (host daemon only)"
echo "git host:  http://localhost:${PORT}/artifacts/git/<repoId>"
echo "dev loop:  commit in a repo, rerun with QITS_SKIP_BUILD=1 — the push redeploys it"
[ -d /out ] && echo "seed compose + state saved to /out"
warn "not part of either set (no image exists): qits-dns, qits-spa-home"
warn "workspace containers need a qits/workspace:latest base image supplied separately"
exit "$overall"
