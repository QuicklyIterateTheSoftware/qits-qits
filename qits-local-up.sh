#!/bin/sh
# qits-local-up.sh — bootstrap the qits platform on your workstation's docker daemon, THROUGH the
# platform's own pipeline. Meant to be run as a throwaway container from the qits-qits repo root:
#
#   docker run -it --rm \
#     -v /var/run/docker.sock:/var/run/docker.sock \
#     -v "$PWD":/out \
#     docker:cli sh /out/qits-local-up.sh
#
# The architecture, in one line: hand-build the platform's build/deploy core once, publishing the
# shared eventstream jar into the seed artifact registry on the way; from then on the platform
# deploys all of its components through its own pipeline.
#
# Every deployable (observability, idp, stt, projects, workspaces, events, gateway, artifacts, ci,
# cd) is an application of qits-cd's "qits" main environment (branch main, network qits-net): pushed to
# the platform's git host, built by qits-ci from the repo's own .config/qits/ci-post-receive.yml,
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
#   QITS_PUSH_TOKEN     the git host's push token — what `-o qits.token=<value>` must equal to
#                       push the default branch directly once protection is on
#                       (default local-dev)
#   QITS_MACHINE_AUTH   1 = machine-token enforcement ON for ci, cd and artifacts (default 1)
#   QITS_IDP_CLIENT_<ID>_SECRET
#                       pin one client's secret instead of letting this script generate it
#                       (<ID> is the client id uppercased with dashes as underscores, e.g.
#                       QITS_IDP_CLIENT_QITS_CI_SECRET)
#
# On that last one: releasing is a thing the platform does — qits-workspaces' release endpoint
# merges, stamps a version and pushes, and the git host protects each repo's default branch against
# everything else. This bootstrap is the standing exception: it pushes nine repos to main by
# definition, before any workspaces service exists to release through. So it configures a token
# and presents it. The value is a knob and NOT a secret — a deployment that wants no escape hatch
# at all simply leaves `qits.repositories.git.push-token` unset, and then nothing overrides.
#
# On machine auth: qits-idp is part of the seed AND an application, exactly like the other four.
# Its client secrets are GENERATED on the first run and recorded in .qits-bootstrap.env, because a
# rotated secret locks every service out until it too is redeployed — the same "must be stable
# across reruns" property the push token has, arrived at from the other direction (that value is
# named in the docs, these never leave the machine). The gate is ON by default: enforcement that
# only ever runs in production is enforcement nobody has tested. QITS_MACHINE_AUTH=0 turns it off
# for a bring-up that wants the old network-trust behaviour.
#
# Each hop has TWO switches and both are set here: the receiver's gate, and the sender's
# quarkus-oidc-client, which ships disabled and posts bare until enabled. Locally they move
# together — enforce without enabling the senders and every push 401s at qits-ci with nothing in
# the log to say why.
#
# Known gaps, stated rather than hidden:
#   - Adding qits-idp made the environment ten applications where an existing platform's is nine,
#     and qits-cd has no add-application endpoint. The first rerun after this change therefore
#     takes the RECREATE branch below, which tears the environment's containers down — the
#     cd-managed core included. Read qits-idp-local-wiring.md before rerunning against a platform
#     that is already up.
#   - qits-dns (which ships a Dockerfile) and qits-spa-home are not part of either set, so
#     neither is deployed. qits-projects announces to qits-dns fire-and-forget; its absence is
#     one WARN per project creation.
#   - qits/workspace:latest layers the daemon onto a toolchain base this script cannot conjure;
#     workspace containers need that image supplied separately.
#   - The gateway is built with QITS_VARIANT=local: EXPLICITLY UNAUTHENTICATED. Never publish the
#     image or the port beyond your machine.
#   - Until qits-observability's deployment goes ACTIVE, every seed service logs an OTLP export
#     warning per batch. It self-heals the moment the alias resolves.
#   - Seed builds pull their base images STRAIGHT from quay.io and registry.access.redhat.com. The
#     Dockerfiles name the platform's own image mirror, and this script rewrites those refs back
#     (see seed_dockerfile), so a cold start needs reach to the upstreams and pays full price. Only
#     builds through the pipeline, on a platform that is already up, are served from the cache.

set -eu

ORG_URL=${QITS_ORG_URL:-https://github.com/QuicklyIterateTheSoftware}
PORT=${QITS_PORT:-8080}
REGISTRY_PORT=${QITS_REGISTRY_PORT:-8081}
SKIP_BUILD=${QITS_SKIP_BUILD:-0}
DEPLOY_TIMEOUT=${QITS_DEPLOY_TIMEOUT:-3600}
SRC=${QITS_SRC:-/qits-src}
# A fixed default rather than a generated one, on purpose: this value has to be the SAME across
# reruns (the run-args carry it into every artifacts deployment, the push loop presents it) and it
# has to be nameable in the docs that teach the escape hatch. A per-run random would satisfy
# neither, and would buy no secrecy on a platform whose gateway ships unauthenticated.
PUSH_TOKEN=${QITS_PUSH_TOKEN:-local-dev}
MACHINE_AUTH=${QITS_MACHINE_AUTH:-1}
[ "$MACHINE_AUTH" = 1 ] && MACHINE_REQUIRED=true || MACHINE_REQUIRED=false
# The OUTBOUND half, and a SEPARATE switch from the gate above. quarkus-oidc-client ships DISABLED,
# so a service given an issuer address and a secret still posts BARE until this is set — which is
# the failure with no error message: gate on and this unset, the git host's post-receive to qits-ci
# and ci's build-succeeded to qits-cd both answer 401, and CI silently stops on every push. It is
# always set together with that service's secret; a client enabled without one refuses to boot.
#
# It follows the gate here because QITS_MACHINE_AUTH=0 means "the platform as it was before the
# idp", at both ends. A real deployment moves the two independently — senders first, receivers
# after — which is what lets one hop be turned on at a time.
MACHINE_CLIENT=$MACHINE_REQUIRED

# The seed: hand-built for the FIRST boot only. On later runs any of these already replaced by a
# cd deployment is skipped at compose-up, and the deploy loop below hands the rest over.
# qits-idp is in here because the three services that enforce machine auth are: a seed ci that
# cannot reach an issuer answers 401 to the git host's very first post-receive.
CORE="gateway artifacts ci cd idp"
# Everything the platform deploys through itself — the environment's applications. Order matters:
# observability first (quiets OTLP warnings earliest), idp next (every later application's tokens
# are minted by it, and its own cutover must not fall inside another application's deploy window),
# the seed's own repos last, cd at the very end (its deployment is the self-update handoff: the cd
# API blinks while the successor takes over and adopts the row).
DEPLOYABLES="observability idp stt projects workspaces events gateway artifacts ci cd"

# The static clients qits-idp seeds from config. The list is the contract's, and every one of them
# gets a secret here — a client without one is refused `invalid_client` exactly like a wrong one,
# so an unused client costs nothing and a used one that was forgotten costs a debugging session.
IDP_CLIENTS="qits-ci qits-cd qits-artifacts qits-workspaces qits-gateway"

ENV_NAME=qits
ARTIFACTS=http://qits-artifacts:8080
CD=http://qits-cd:8080
CI=http://qits-ci:8080
# The issuer string, and the address consumers dial. One value: the discovery document derives
# /token and /jwks from it, and a consumer whose issuer differs by one character rejects every
# token at validation. Direct on qits-net — the idp is deliberately NOT on the gateway's route
# table in phase 1, since /idp/token behind an unauthenticated gateway is a token vending machine.
IDP=http://qits-idp:8080/idp

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m !! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }

repo_path() { case "$1" in
  ci-daemon) echo "daemons/qits-ci-daemon";;
  eventstream) echo "libs/qits-eventstream";;
  spa-ui-components) echo "libs/qits-spa-ui-components";;
  integrations-angular) echo "integrations/qits-integrations-angular";;
  integrations-quarkus) echo "integrations/qits-integrations-quarkus";;
  *) echo "services/qits-$1";;
esac; }

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
for name in ci-daemon eventstream spa-ui-components integrations-angular integrations-quarkus $DEPLOYABLES; do
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

# --- recorded run state ---------------------------------------------------------------------------
# What a previous bootstrap generated and this one must not change: the ci-daemon digest and the
# idp's client secrets. Read BEFORE anything needs them (the old script read it only on the
# skip-build path) so a full rerun keeps the secrets it issued last time — regenerating them would
# leave every already-deployed service holding a credential the idp no longer knows.
if [ -f /out/.qits-bootstrap.env ]; then . /out/.qits-bootstrap.env; fi

# --- seed builds ---------------------------------------------------------------------------------
# The committed Dockerfiles FROM the platform's own pull-through image mirror
# (localhost:8081/{quay,redhat,hub}/…), which IS qits-artifacts — one of the four services this
# phase hand-builds. A cold start cannot pull through the registry it is starting, so a seed build
# gets the same Dockerfile with the mirror prefixes rewritten back to the direct upstreams, fed on
# stdin. Nothing on disk changes: the context is untouched, and every steady-state build (CI's
# post-receive, on a running platform) still goes through the mirror.
# The Docker Hub refs written inline below (docker:cli, node:24-alpine) and the alpine/git runs
# further down are direct for the same reason, and are meant to stay that way.
seed_dockerfile() {
  sed -e 's|localhost:8081/quay/|quay.io/|g' \
      -e 's|localhost:8081/redhat/|registry.access.redhat.com/|g' \
      -e 's|localhost:8081/hub/|docker.io/|g' "$1"
}

if [ "$SKIP_BUILD" != 1 ]; then
  # qits-artifacts consumes qits-auth-core, while also being the Maven registry that owns it in
  # steady state. Break that first-boot cycle with a temporary, script-owned file repository.
  # It is removed before the real artifacts container claims the registry port.
  AUTH_SEED_CONTAINER=""
  cleanup_auth_seed() {
    [ -z "${AUTH_SEED_CONTAINER:-}" ] || docker rm -f "$AUTH_SEED_CONTAINER" >/dev/null 2>&1 || true
  }
  trap cleanup_auth_seed EXIT HUP INT TERM
  if ! curl -fsS -o /dev/null "http://host.docker.internal:${REGISTRY_PORT}/artifacts/maven/maven/eu/wohlben/qits/qits-auth-core/1.0.0/qits-auth-core-1.0.0.pom" 2>/dev/null; then
    say "seeding qits-auth-core 1.0.0 for the first artifacts build"
    docker volume create qits-maven-seed >/dev/null
    auth_cid=$(docker create --user root --entrypoint sh -v qits-maven-seed:/repo maven:3.9-eclipse-temurin-25 \
      -c 'cd /src && mvn -B -ntp deploy -DskipTests -DaltDeploymentRepository=seed::default::file:///repo')
    docker cp "$SRC/qits-integrations-quarkus/." "$auth_cid:/src"
    docker start -a "$auth_cid" || { docker rm -f "$auth_cid" >/dev/null; die "qits-auth-core seed failed"; }
    docker rm "$auth_cid" >/dev/null
    AUTH_SEED_CONTAINER=qits-maven-seed-http
    docker rm -f "$AUTH_SEED_CONTAINER" >/dev/null 2>&1 || true
    docker run -d --name "$AUTH_SEED_CONTAINER" -p "127.0.0.1:${REGISTRY_PORT}:80" \
      -v qits-maven-seed:/usr/share/nginx/html/artifacts/maven/maven:ro nginx:alpine >/dev/null
  fi
  say "building the seed images (GraalVM native — ~4 GB RAM each, this takes a while)"
  for name in $CORE; do
    if [ "$name" = ci ]; then
      # qits-ci consumes qits-eventstream from the Maven repository it will use in steady state.
      # Bring up artifacts alone, publish the dependency reproducibly, then let the CI image build.
      say "starting seed artifacts for the Maven bootstrap"
      if [ -n "$AUTH_SEED_CONTAINER" ]; then
        docker rm -f "$AUTH_SEED_CONTAINER" >/dev/null
        AUTH_SEED_CONTAINER=""
      fi
      docker network inspect qits-net >/dev/null 2>&1 || docker network create qits-net >/dev/null
      docker network connect qits-net "$SELF" 2>/dev/null || true
      docker volume create qits-artifacts-data >/dev/null
      docker volume create qits-repositories >/dev/null
      if ! docker ps --format '{{.Names}}' | grep -q '^qits-artifacts$'; then
        docker rm -f qits-artifacts >/dev/null 2>&1 || true
        docker run -d --name qits-artifacts --network qits-net \
          -p "127.0.0.1:${REGISTRY_PORT}:8080" \
          -e QUARKUS_DATASOURCE_ARTIFACTS_JDBC_URL=jdbc:h2:file:/data/artifacts/h2/artifacts \
          -e QITS_ARTIFACTS_BLOBS_DIR=/data/artifacts/blobs \
          -e QITS_CI_INTAKE_URL=http://qits-ci:8080/ci/api/events/post-receive \
          -e QITS_REPOSITORIES_GIT_PUSH_TOKEN="$PUSH_TOKEN" \
          -e QITS_REPOSITORIES_GIT_PROTECT_DEFAULT_BRANCH=true \
          -v qits-artifacts-data:/data -v qits-repositories:/data/repositories \
          qits/artifacts:latest >/dev/null
      fi
      i=0
      until curl -fsS -o /dev/null "http://host.docker.internal:${REGISTRY_PORT}/artifacts/q/health/ready" 2>/dev/null \
         || curl -fsS -o /dev/null "http://qits-artifacts:8080/artifacts/q/health/ready" 2>/dev/null; do
        i=$((i + 5)); [ "$i" -gt 120 ] && die "qits-artifacts not ready after 120s"
        sleep 5
      done

      say "publishing qits-eventstream 1.0.0 into seed artifacts"
      if curl -fsS -o /dev/null "$ARTIFACTS/artifacts/maven/maven/eu/wohlben/qits/qits-eventstream/1.0.0/qits-eventstream-1.0.0.jar"; then
        echo "  qits-eventstream 1.0.0 already published"
      else
        maven_cid=$(docker create --network qits-net --user root --entrypoint sh maven:3.9-eclipse-temurin-25 \
          -c 'cd /src && mvn -B -ntp deploy -DskipTests -DaltDeploymentRepository=qits::default::http://qits-artifacts:8080/artifacts/maven/maven')
        docker cp "$SRC/qits-eventstream/." "$maven_cid:/src"
        docker start -a "$maven_cid" || { docker rm -f "$maven_cid" >/dev/null; die "qits-eventstream publish failed"; }
        docker rm "$maven_cid" >/dev/null
      fi

      say "publishing qits-auth-core 1.0.0 into seed artifacts"
      if curl -fsS -o /dev/null "$ARTIFACTS/artifacts/maven/maven/eu/wohlben/qits/qits-auth-core/1.0.0/qits-auth-core-1.0.0.jar"; then
        echo "  qits-auth-core 1.0.0 already published"
      else
        auth_cid=$(docker create --network qits-net --user root --entrypoint sh maven:3.9-eclipse-temurin-25 \
          -c 'cd /src && mvn -B -ntp deploy -DskipTests -DaltDeploymentRepository=qits::default::http://qits-artifacts:8080/artifacts/maven/maven')
        docker cp "$SRC/qits-integrations-quarkus/." "$auth_cid:/src"
        docker start -a "$auth_cid" || { docker rm -f "$auth_cid" >/dev/null; die "qits-auth-core publish failed"; }
        docker rm "$auth_cid" >/dev/null
      fi

      say "publishing the shared UI package into seed artifacts"
      node_cid=$(docker create --network qits-net --user root --entrypoint sh node:24-alpine -c '
        set -eu
        apk add --no-cache git >/dev/null
        git clone -q /src /src-004
        cd /src-004
        git checkout -q 9f9648482d6fe025cc7af9bd4496afab417f33f9
        corepack enable
        cat > /root/.npmrc <<EOF
registry=https://registry.npmjs.org/
@qits:registry=http://qits-artifacts:8080/artifacts/npm/npm/
//qits-artifacts:8080/artifacts/npm/npm/:_authToken=qits-bootstrap
EOF
        pnpm install --frozen-lockfile
        pnpm build
        cd dist/qits-spa-ui-components
        npm view @qits/ui-components@0.0.4 version >/dev/null 2>&1 || npm publish

        cd /src
        pnpm install --frozen-lockfile
        pnpm build
        cd dist/qits-spa-ui-components
        version=$(node -p "require(\"./package.json\").version")
        npm view "@qits/ui-components@$version" version >/dev/null 2>&1 || npm publish
      ')
      docker cp "$SRC/qits-spa-ui-components/." "$node_cid:/src"
      docker start -a "$node_cid" || { docker rm -f "$node_cid" >/dev/null; die "UI package publish failed"; }
      docker rm "$node_cid" >/dev/null

      say "publishing the Angular integration package into seed artifacts"
      angular_cid=$(docker create --network qits-net --user root --entrypoint sh node:24-alpine -c '
        set -eu
        apk add --no-cache git >/dev/null
        git clone -q /src /src-001
        cd /src-001
        git checkout -q 3f405717f14f0942399340d84db4ef0ca3769101
        corepack enable
        cat > /root/.npmrc <<EOF
registry=https://registry.npmjs.org/
@qits:registry=http://qits-artifacts:8080/artifacts/npm/npm/
//qits-artifacts:8080/artifacts/npm/npm/:_authToken=qits-bootstrap
EOF
        pnpm install --frozen-lockfile
        pnpm build
        version=$(node -p "require(\"./dist/qits-integrations-angular/package.json\").version")
        npm view "@qits/angular@$version" version >/dev/null 2>&1 || npm publish ./dist/qits-integrations-angular
      ')
      docker cp "$SRC/qits-integrations-angular/." "$angular_cid:/src"
      docker start -a "$angular_cid" || { docker rm -f "$angular_cid" >/dev/null; die "Angular integration publish failed"; }
      docker rm "$angular_cid" >/dev/null
    fi
    say "build qits/$name:latest"
    # Seed services only need their APIs. Their Dockerfiles intentionally consume an already-built
    # SPA, but a clean checkout has no dist directory and the hosted npm registry does not exist
    # until artifacts starts. Supply a deterministic placeholder; the normal post-receive pipeline
    # later builds and deploys the real client from the same commit.
    git -C "$SRC/qits-$name" submodule update --init --depth 1
    case "$name" in
      gateway) seed_ui=src/main/webui/dist/qits-spa-home/browser;;
      *) seed_ui=service/src/main/webui/dist/qits-spa-$name/browser;;
    esac
    mkdir -p "$SRC/qits-$name/$seed_ui"
    printf '<!doctype html><html><body>qits bootstrap</body></html>\n' \
      > "$SRC/qits-$name/$seed_ui/index.html"
    extra=""
    # A shipped gateway must say whether it authenticates; `local` is the unauthenticated
    # workstation variant.
    [ "$name" = gateway ] && extra="--build-arg QITS_VARIANT=local"
    # shellcheck disable=SC2086
    seed_dockerfile "$SRC/qits-$name/docker/Dockerfile" \
      | docker build --network host -t "qits/$name:latest" -f - $extra "$SRC/qits-$name" \
      || die "build of qits/$name failed"
  done

  # The step image pipeline configs name. Contract: git, bash, wget-or-curl (the ci-daemon
  # bootstrap), plus the docker CLI for docker:true publish steps. Nothing in the tree builds
  # this yet, so the bootstrap does.
  say "build qits/build-images/ci-base:latest"
  printf 'FROM docker:cli\nRUN apk add --no-cache git bash curl\n' \
    | docker build -q -t qits/build-images/ci-base:latest - >/dev/null

  # The same for node pipelines. Same contract (git, bash, a downloader) on a node base, plus
  # corepack for pnpm. No docker CLI: an npm publish goes to qits-artifacts over qits-net as
  # ordinary HTTP, so such a step never declares docker:true.
  say "build qits/build-images/node-base:latest"
  printf 'FROM node:24-alpine\nRUN apk add --no-cache git bash curl && corepack enable\n' \
    | docker build -q -t qits/build-images/node-base:latest - >/dev/null

  # node-base plus the docker CLI, for a frontend's publish step: the app builds in the step
  # container (which is on qits-net and can reach the registry), and the docker build only COPYs
  # the built dist into a runtime image. Build-time network is deliberately not relied on —
  # buildkit RUN steps cannot reach qits-net, the VM-host loopback, or a host-gateway alias on
  # every daemon this platform targets, so an image build that fetches packages is unbuildable
  # on some of them by construction.
  say "build qits/build-images/node-docker-base:latest"
  printf 'FROM node:24-alpine\nRUN apk add --no-cache git bash curl docker-cli && corepack enable\n' \
    | docker build -q -t qits/build-images/node-docker-base:latest - >/dev/null

  # The ci-daemon: a fully static musl native binary. Its documented recipe runs mvnw on the host
  # with container-build=true; inside this container that would need bind mounts the socket
  # boundary cannot honour (paths resolve on the HOST), so the build runs INSIDE the builder
  # image instead — docker cp carries the source in and the binary out, and container-build is
  # switched off because we are already in the container it would launch.
  say "build the qits-ci-daemon binary (musl static native)"
  seed_dockerfile "$SRC/qits-ci-daemon/docker/Dockerfile.musl-builder" \
    | docker build -t qits/graalvmce-musl-builder:jdk-25 -f - "$SRC/qits-ci-daemon/docker"
  # --entrypoint: the builder image entrypoints to native-image itself.
  cid=$(docker create --user root --entrypoint bash qits/graalvmce-musl-builder:jdk-25 \
    -c 'cd /qits-build && ./mvnw -B -ntp -pl ci-daemon -am package -Dnative -DskipTests -Dquarkus.native.container-build=false')
  docker cp "$SRC/qits-ci-daemon" "$cid:/qits-build"
  docker start -a "$cid" || { docker rm -f "$cid" >/dev/null; die "ci-daemon build failed"; }
  docker cp "$cid:/qits-build/ci-daemon/target/qits-ci-daemon" /qits-ci-daemon
  docker rm "$cid" >/dev/null
  DAEMON_SHA=$(sha256sum /qits-ci-daemon | cut -d' ' -f1)
  say "ci-daemon digest: sha256:$DAEMON_SHA"
else
  # The digest is a run-pinned value the compose file needs; a skip-build rerun uses the recorded
  # one, read above.
  [ -n "${DAEMON_SHA:-}" ] || die "QITS_SKIP_BUILD=1 but no recorded DAEMON_SHA (/out/.qits-bootstrap.env)"
fi

# --- the idp's client secrets ----------------------------------------------------------------------
# Every static client ships without a secret and is unusable until a deployment gives it one, so
# this is where the local platform's credentials come from. Precedence: an explicit
# QITS_IDP_CLIENT_<ID>_SECRET, else what a previous run recorded, else a fresh random.
#
# Random rather than a fixed default, which is where this parts ways with QITS_PUSH_TOKEN: that
# value has to be nameable in the docs that teach the escape hatch, and these are never typed by
# anyone. The whole set is written back below together with the digest.
say "resolving the idp's client secrets"
for client in $IDP_CLIENTS; do
  key=$(echo "$client" | tr 'a-z-' 'A-Z_')
  # Read the override and the recorded value indirectly — POSIX sh has no ${!var}.
  given=$(eval "printf '%s' \"\${QITS_IDP_CLIENT_${key}_SECRET:-}\"")
  kept=$(eval "printf '%s' \"\${IDP_SECRET_${key}:-}\"")
  value=$given
  [ -n "$value" ] || value=$kept
  [ -n "$value" ] || value=$(head -c 32 /dev/urandom | sha256sum | cut -c1-32)
  eval "IDP_SECRET_${key}=\$value"
  printf '  %-18s %s\n' "$client" "$([ -n "$given" ] && echo given || { [ -n "$kept" ] && echo kept || echo generated; })"
done

if [ -d /out ]; then
  {
    printf 'DAEMON_SHA=%s\n' "$DAEMON_SHA"
    for client in $IDP_CLIENTS; do
      key=$(echo "$client" | tr 'a-z-' 'A-Z_')
      eval "printf 'IDP_SECRET_%s=%s\n' \"\$key\" \"\$IDP_SECRET_${key}\""
    done
  } > /out/.qits-bootstrap.env
fi

# --- the seed compose ----------------------------------------------------------------------------
say "generating the seed compose file"
if [ -d /out ]; then COMPOSE=/out/docker-compose.qits.yml; else COMPOSE=/tmp/docker-compose.qits.yml; fi

cat > "$COMPOSE" <<EOF
# Generated by qits-local-up.sh — the SEED of the local qits platform: only the services that
# build and deploy the rest. Everything else (observability, stt, projects, workspaces, events) is
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
  # THE SIGNING KEY LIVES HERE. An idp on ephemeral storage comes up healthy and mints a new
  # keypair on every recreate, invalidating every token in flight with nothing in any log to say
  # why — which is why its image refuses to boot without the url that points at this volume.
  qits-idp-data:
    name: qits-idp-data
  # Mounted by cd-DEPLOYED containers via qits.cd.run-args, not by any service below.
  qits-projects-data:
    name: qits-projects-data
  qits-workspaces-data:
    name: qits-workspaces-data
  qits-stt-data:
    name: qits-stt-data
  qits-events-data:
    name: qits-events-data
  # cd's run-args config (config/application.properties), written by the bootstrap. A volume
  # rather than env so a self-update's successor inherits it — env cannot nest these values.
  qits-cd-config:
    name: qits-cd-config

services:
  # The issuer. No published host port and no gateway route: in phase 1 nothing outside qits-net
  # talks to it, and /idp/token reachable from the host through an unauthenticated gateway would be
  # a token vending machine. Phase 3's user flows are what put it on the route table.
  qits-idp:
    image: qits/idp:latest
    container_name: qits-idp
    environment:
      # Not a default the image could ship: the signing key lands in this database, and the image
      # refuses to boot rather than write it into a container layer.
      QUARKUS_DATASOURCE_IDP_JDBC_URL: jdbc:h2:file:/data/idp/h2/idp
      # The 'iss' of every token and the base of every endpoint the discovery document advertises.
      # Spelled here although it equals the shipped default, for the reason every other address in
      # this file is spelled: an address a deployment inherits silently is one nobody knows to
      # change. Consumers below carry the same string; a mismatch is rejected at validation.
      QITS_IDP_ISSUER: ${IDP}
      # Generated by this bootstrap, recorded in .qits-bootstrap.env, and handed to the matching
      # service below. A client without a secret is refused, never open.
      QITS_IDP_CLIENT_QITS_CI_SECRET: "${IDP_SECRET_QITS_CI}"
      QITS_IDP_CLIENT_QITS_CD_SECRET: "${IDP_SECRET_QITS_CD}"
      QITS_IDP_CLIENT_QITS_ARTIFACTS_SECRET: "${IDP_SECRET_QITS_ARTIFACTS}"
      # Unused in phase 1 (qits-workspaces' agents are phase 2, the gateway's user flows phase 3).
      # Seeded anyway: the cost is a config line, and the cost of the omission is invalid_client on
      # a path nobody was looking at.
      QITS_IDP_CLIENT_QITS_WORKSPACES_SECRET: "${IDP_SECRET_QITS_WORKSPACES}"
      QITS_IDP_CLIENT_QITS_GATEWAY_SECRET: "${IDP_SECRET_QITS_GATEWAY}"
      # The one claim grant phase 1 needs. The git host announces every push to ci's intake, which
      # checks the token's project claim against the repo the event names — and the git host speaks
      # for ALL repos, so its grant is the wildcard. The idp only states the claim; qits-ci's own
      # enforcement is what reads '*' as covering every value.
      QITS_IDP_CLIENT_QITS_ARTIFACTS_CLAIMS_PROJECT: "*"
    volumes:
      - qits-idp-data:/data
    networks: [qits-net]
    restart: unless-stopped

  qits-gateway:
    image: qits/gateway:latest
    container_name: qits-gateway
    ports:
      - "${PORT}:8080"
    environment:
      # The route table: an entry is both the on-switch and the target. Aliases of the
      # pipeline-deployed five resolve the moment cd cuts them over; until then those routes 502.
      QITS_GATEWAY_PROXY_HOSTS_ARTIFACTS: qits-artifacts   # also claims root-level /v2 (OCI registry)
      QITS_GATEWAY_PROXY_HOSTS_CI: qits-ci
      QITS_GATEWAY_PROXY_HOSTS_CD: qits-cd
      QITS_GATEWAY_PROXY_HOSTS_OBSERVABILITY: qits-observability
      QITS_GATEWAY_PROXY_HOSTS_PROJECTS: qits-projects
      QITS_GATEWAY_PROXY_HOSTS_WORKSPACES: qits-workspaces
      QITS_GATEWAY_PROXY_HOSTS_STT: qits-stt
      QITS_GATEWAY_PROXY_HOSTS_EVENTS: qits-events
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
      # The default branch's escape hatch: a push carrying -o qits.token=<this> is let through
      # even when protection is on. Unset would mean no value matches and nothing overrides —
      # which is the shipped default everywhere else, and which this bootstrap cannot live with
      # (it pushes main nine times before a release endpoint exists to go through).
      QITS_REPOSITORIES_GIT_PUSH_TOKEN: "${PUSH_TOKEN}"
      # Protection stays ON here too: the bootstrap's own pushes carry the token above, and a
      # rerun that silently disarmed the seatbelt AC flipped live would be the quiet failure.
      QITS_REPOSITORIES_GIT_PROTECT_DEFAULT_BRANCH: "true"
      # Machine auth. Inbound: the admin writes under /artifacts/api demand a bearer addressed to
      # qits-artifacts. Outbound: the git host's post-receive announcement to qits-ci carries one.
      # Nothing here fails a service whose image predates the change — an unknown key is ignored.
      QITS_AUTH_MACHINE_REQUIRED: "${MACHINE_REQUIRED}"
      QUARKUS_OIDC_AUTH_SERVER_URL: ${IDP}
      # The outbound switch, and the secret it must never travel without. qits-artifacts names the
      # secret QITS_ARTIFACTS_CLIENT_SECRET in its own application.properties — the canonical
      # QUARKUS_OIDC_CLIENT_CREDENTIALS_SECRET would override it too, but one spelling is enough
      # and the file's own is the one that documents itself.
      QUARKUS_OIDC_CLIENT_CLIENT_ENABLED: "${MACHINE_CLIENT}"
      QUARKUS_OIDC_CLIENT_AUTH_SERVER_URL: ${IDP}
      QITS_ARTIFACTS_CLIENT_SECRET: "${IDP_SECRET_QITS_ARTIFACTS}"
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
      # The eventstream library (the outbox) owns its own datasource, whose shipped default sits
      # under \${user.home} — which a container has not got, so H2 refuses the url at Flyway and the
      # binary dies at boot. Every deployment of ci must spell this twin; so must the seed.
      # (The backslash is load-bearing: this heredoc is unquoted, and an unescaped \${user.home}
      # is a bad substitution that kills the whole bootstrap at compose-generation time.)
      QUARKUS_DATASOURCE_EVENTSTREAM_JDBC_URL: jdbc:h2:file:/data/eventstream/h2/eventstream
      # ci's own fetch of the pushed ref, and the same base as seen from inside a step
      # container — steps join qits-net, so both resolve the git host directly.
      QITS_CI_GIT_HOST_URL: http://qits-artifacts:8080/artifacts
      QITS_CI_CONTAINER_GIT_URL: http://qits-artifacts:8080/artifacts
      QITS_CI_NETWORK: qits-net
      # Injected into publish steps as QITS_REGISTRY: dialled by the HOST daemon (see the
      # qits-artifacts ports note).
      QITS_ARTIFACTS_REGISTRY_HOST: localhost:${REGISTRY_PORT}
      # The npm roots (QITS_NPM_REGISTRY_URL / QITS_NPM_PROXY_URL) are deliberately NOT overridden
      # here: a step container dials THOSE itself, on qits-net, so ci's shipped defaults
      # (http://qits-artifacts:8080/artifacts/npm/...) are already right. Copying the localhost
      # mapping above onto them would point every npm install at the step container's own loopback.
      # The binary every step container downloads and execs — uploaded by this bootstrap, digest
      # pinned. Blank would mean every run fails as never-registered.
      QITS_CI_DAEMON_VERSION: "${DAEMON_SHA}"
      # Machine auth. Inbound: /ci/api/events/* demands a bearer addressed to qits-ci whose project
      # claim covers the event's repo (this is what replaces X-CI-Token). Outbound: the
      # build-succeeded notify to qits-cd carries one. qits-ci names no secret placeholder of its
      # own, so the canonical QUARKUS_OIDC_CLIENT_CREDENTIALS_SECRET is the one that carries it.
      QITS_AUTH_MACHINE_REQUIRED: "${MACHINE_REQUIRED}"
      QUARKUS_OIDC_AUTH_SERVER_URL: ${IDP}
      QUARKUS_OIDC_CLIENT_CLIENT_ENABLED: "${MACHINE_CLIENT}"
      QUARKUS_OIDC_CLIENT_AUTH_SERVER_URL: ${IDP}
      QUARKUS_OIDC_CLIENT_CREDENTIALS_SECRET: "${IDP_SECRET_QITS_CI}"
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
      # Machine auth, inbound only: /cd/api/events/build-succeeded demands a bearer addressed to
      # qits-cd. cd calls no guarded endpoint of anyone else in phase 1, so it needs no oidc-client
      # and holds no secret of its own — its client exists at the idp and goes unused.
      QITS_AUTH_MACHINE_REQUIRED: "${MACHINE_REQUIRED}"
      QUARKUS_OIDC_AUTH_SERVER_URL: ${IDP}
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
qits.cd.run-args.qits-gateway=-p ${PORT}:8080 -e QITS_GATEWAY_PROXY_HOSTS_ARTIFACTS=qits-artifacts -e QITS_GATEWAY_PROXY_HOSTS_CI=qits-ci -e QITS_GATEWAY_PROXY_HOSTS_CD=qits-cd -e QITS_GATEWAY_PROXY_HOSTS_OBSERVABILITY=qits-observability -e QITS_GATEWAY_PROXY_HOSTS_PROJECTS=qits-projects -e QITS_GATEWAY_PROXY_HOSTS_WORKSPACES=qits-workspaces -e QITS_GATEWAY_PROXY_HOSTS_STT=qits-stt -e QITS_GATEWAY_PROXY_HOSTS_EVENTS=qits-events
# The push token rides here so it is already in place when the default branch's protection is
# switched on: turning protection on is then one property on the artifacts side, not a two-part
# change that could leave a running platform locked out of its own bootstrap.
qits.cd.run-args.qits-artifacts=-p 127.0.0.1:${REGISTRY_PORT}:8080 -v qits-artifacts-data:/data -v qits-repositories:/data/repositories -e QUARKUS_DATASOURCE_ARTIFACTS_JDBC_URL=jdbc:h2:file:/data/artifacts/h2/artifacts -e QITS_ARTIFACTS_BLOBS_DIR=/data/artifacts/blobs -e QITS_CI_INTAKE_URL=http://qits-ci:8080/ci/api/events/post-receive -e QITS_REPOSITORIES_GIT_PUSH_TOKEN=${PUSH_TOKEN} -e QITS_REPOSITORIES_GIT_PROTECT_DEFAULT_BRANCH=true -e QITS_AUTH_MACHINE_REQUIRED=${MACHINE_REQUIRED} -e QUARKUS_OIDC_AUTH_SERVER_URL=${IDP} -e QUARKUS_OIDC_CLIENT_CLIENT_ENABLED=${MACHINE_CLIENT} -e QUARKUS_OIDC_CLIENT_AUTH_SERVER_URL=${IDP} -e QITS_ARTIFACTS_CLIENT_SECRET=${IDP_SECRET_QITS_ARTIFACTS}
qits.cd.run-args.qits-ci=-v qits-ci-data:/data -v /var/run/docker.sock:/var/run/docker.sock --group-add ${DOCKER_GID} -e QUARKUS_DATASOURCE_CI_JDBC_URL=jdbc:h2:file:/data/ci/h2/ci -e QUARKUS_DATASOURCE_EVENTSTREAM_JDBC_URL=jdbc:h2:file:/data/eventstream/h2/eventstream -e QITS_CI_GIT_HOST_URL=http://qits-artifacts:8080/artifacts -e QITS_CI_CONTAINER_GIT_URL=http://qits-artifacts:8080/artifacts -e QITS_CI_NETWORK=qits-net -e QITS_ARTIFACTS_REGISTRY_HOST=localhost:${REGISTRY_PORT} -e QITS_CI_DAEMON_VERSION=${DAEMON_SHA} -e QITS_EVENTS_URL=http://qits-events:8080 -e QITS_AUTH_MACHINE_REQUIRED=${MACHINE_REQUIRED} -e QUARKUS_OIDC_AUTH_SERVER_URL=${IDP} -e QUARKUS_OIDC_CLIENT_CLIENT_ENABLED=${MACHINE_CLIENT} -e QUARKUS_OIDC_CLIENT_AUTH_SERVER_URL=${IDP} -e QUARKUS_OIDC_CLIENT_CREDENTIALS_SECRET=${IDP_SECRET_QITS_CI}
qits.cd.run-args.qits-cd=-v qits-cd-data:/data -v qits-cd-config:/work/config -v /var/run/docker.sock:/var/run/docker.sock --group-add ${DOCKER_GID} -e QUARKUS_DATASOURCE_CD_JDBC_URL=jdbc:h2:file:/data/cd/h2/cd -e QITS_ARTIFACTS_REGISTRY_HOST=localhost:${REGISTRY_PORT} -e QITS_AUTH_MACHINE_REQUIRED=${MACHINE_REQUIRED} -e QUARKUS_OIDC_AUTH_SERVER_URL=${IDP}
# The idp's own deployment. The volume is the whole point: the signing key is in that database, and
# a redeploy that lands on a fresh one invalidates every token in flight. The claims grant is the
# git host's wildcard — it announces pushes for every repo, so its project claim covers every value.
qits.cd.run-args.qits-idp=-v qits-idp-data:/data -e QUARKUS_DATASOURCE_IDP_JDBC_URL=jdbc:h2:file:/data/idp/h2/idp -e QITS_IDP_ISSUER=${IDP} -e QITS_IDP_CLIENT_QITS_CI_SECRET=${IDP_SECRET_QITS_CI} -e QITS_IDP_CLIENT_QITS_CD_SECRET=${IDP_SECRET_QITS_CD} -e QITS_IDP_CLIENT_QITS_ARTIFACTS_SECRET=${IDP_SECRET_QITS_ARTIFACTS} -e QITS_IDP_CLIENT_QITS_WORKSPACES_SECRET=${IDP_SECRET_QITS_WORKSPACES} -e QITS_IDP_CLIENT_QITS_GATEWAY_SECRET=${IDP_SECRET_QITS_GATEWAY} -e QITS_IDP_CLIENT_QITS_ARTIFACTS_CLAIMS_PROJECT=*
qits.cd.run-args.qits-stt=-v qits-stt-data:/data -e QITS_SPEECH_HOME=/data/speech
qits.cd.run-args.qits-projects=-v qits-projects-data:/data -v qits-repositories:/data/repositories -e QUARKUS_DATASOURCE_PROJECTS_JDBC_URL=jdbc:h2:file:/data/projects/h2/projects -e QUARKUS_DATASOURCE_EPICS_JDBC_URL=jdbc:h2:file:/data/epics/h2/epics
# QITS_ARTIFACTS_URL is where release PUSHES the release commit — the git host, over HTTP, so
# the ordinary post-receive fires and the ordinary pipeline builds it. The value equals the
# service's own shipped default; it is spelled here because every other cross-service address in
# this file is spelled here, and an address a deployment inherits silently is an address nobody
# knows to change.
# The eventstream twin (same pair qits-ci carries above): a release publishes SoftwareRelease
# through the shared bus client, whose outbox owns its own datasource. The shipped default sits
# under a home directory a container has not got, so every deployment spells the url; the file
# stays under /data, which is already the mounted volume. QITS_EVENTS_URL is where the outbox
# drains to.
# QITS_WORKSPACE_GIT_HOST (qits.workspace.git-host) is the address a WORKSPACE container uses to
# reach this platform — git clone/push, OTLP, the agent's MCP servers and the daemon control
# socket are all composed as http://<this>:8080/... It must be spelled, because the sentinel
# "auto" is wrong on this topology and wrong silently: auto detects WSL2 and answers the primary
# LAN IPv4, which is the address of the machine when qits runs ON the host — but qits-workspaces
# runs in a container here, so what it measures is its OWN container's address and every
# container->platform URL 404s. Provisioning fails for every workspace, on every repository.
# qits-gateway, not qits-workspaces or qits-artifacts: it is the one name on qits-net that fronts
# the WHOLE platform, so all four of those paths resolve through one value, each under its owning
# service's segment. Port stays 8080 (qits.workspace.qits-port), which is the gateway's.
qits.cd.run-args.qits-workspaces=-v qits-workspaces-data:/data -v qits-repositories:/data/repositories -v /var/run/docker.sock:/var/run/docker.sock --group-add ${DOCKER_GID} -e QUARKUS_DATASOURCE_WORKSPACES_JDBC_URL=jdbc:h2:file:/data/workspaces/h2/workspaces -e QUARKUS_DATASOURCE_EVENTSTREAM_JDBC_URL=jdbc:h2:file:/data/eventstream/h2/eventstream -e QITS_PROJECTS_URL=http://qits-projects:8080 -e QITS_ARTIFACTS_URL=http://qits-artifacts:8080 -e QITS_EVENTS_URL=http://qits-events:8080 -e QITS_WORKSPACE_GIT_HOST=qits-gateway
qits.cd.run-args.qits-events=-v qits-events-data:/data -e QUARKUS_DATASOURCE_EVENTS_JDBC_URL=jdbc:h2:file:/data/events/h2/events
RUNARGS
docker volume create qits-cd-config >/dev/null
docker run --rm -i -v qits-cd-config:/cfg --entrypoint sh alpine/git \
  -c 'cat > /cfg/application.properties && chown 1001:0 /cfg/application.properties' \
  < /tmp/cd-run-args.properties

say "starting the seed stack"
docker network inspect qits-net >/dev/null 2>&1 || docker network create qits-net >/dev/null
# The artifacts instance used while building seed images intentionally has no machine credentials:
# the IDP does not exist yet. Replace it now so compose starts the real service with the generated
# client secret; otherwise post-receive notifications silently reach CI without a bearer token.
if docker ps -a --format '{{.Names}}' | grep -q '^qits-artifacts$'; then
  echo "  replacing the bootstrap artifact registry with the authenticated seed service"
  docker rm -f qits-artifacts >/dev/null
fi
# Only what cd does not already manage: a compose service whose application has a live cd-managed
# container must NOT be resurrected next to it — cd's own container included, once a self-update
# handoff has made cd one of its own deployments.
UP=""
for name in idp cd gateway artifacts ci; do
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
  # idp first: with the gate on, the first push's post-receive needs a token, and this script's own
  # replayed build-succeeded needs one too. Bearer VALIDATION is lazy (discovery is off and the
  # JWKS path is configured, so no consumer fetches anything at boot), which is what makes an
  # all-at-once compose up safe — but ISSUANCE is not, so the issuer is waited for.
  for name in idp artifacts ci cd; do
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

# A machine token for this script's own calls into the platform. It borrows qits-ci's client rather
# than owning one: the only call that needs a token is the replayed build-succeeded below, which
# stands in for the announcement qits-ci never sent, and a token that says qits-ci is exactly what
# that event is. Same shape as the push token — the bootstrap presents the platform's own
# credentials because it IS the platform, before there is anything to go through.
idp_token() {
  curl -fsS -X POST "$IDP/token" -u "qits-ci:$IDP_SECRET_QITS_CI" \
    -d grant_type=client_credentials -d "audience=$1" \
    | jq -er .access_token
}

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

  # -o qits.token: the bootstrap's standing exception to "release is the only door into main".
  # The very first push of a repo creates the ref and needs nothing (creates are allowed by
  # design — an empty repo has no default branch to protect), but every rerun updates it, and an
  # update is exactly what protection guards. The option rides inside the pack protocol, so it
  # travels identically through the gateway, qits-net and the host-mapped port; it needs a git
  # host that advertises push-options, which every artifacts build since the protected-ref change
  # does.
  out=$(git -C "$SRC/$repo" push -o "qits.token=$PUSH_TOKEN" "$ARTIFACTS/artifacts/git/$repo" main 2>&1) \
    || die "push of $repo failed: $out"
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
    # With the gate on, cd's intake wants a bearer addressed to qits-cd. set -- carries the header
    # as ONE argument; an unquoted ${var:+-H ...} would word-split the header in half.
    if [ "$MACHINE_AUTH" = 1 ]; then
      token=$(idp_token qits-cd) || die "qits-idp issued no token for the build event — is the qits-ci client's secret in place?"
      set -- -H "Authorization: Bearer $token"
    else
      set --
    fi
    curl -fsS -o /dev/null -X POST -H 'Content-Type: application/json' "$@" \
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
    run_status=$(curl -fsS "$CI/ci/api/runs?repositoryId=$repo&limit=1" 2>/dev/null \
      | jq -r --arg sha "$sha" '.runs[] | select(.commitSha == $sha) | .status' 2>/dev/null \
      | head -1 || true)
    if [ "$run_status" = FAILED ] || [ "$run_status" = CONFIG_ERROR ]; then
      warn "$repo CI run ended $run_status before a deployment was created"
      overall=1
      break
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
echo "main:      written by /workspaces/{id}/release; a direct push needs -o qits.token=${PUSH_TOKEN}"
if [ "$MACHINE_AUTH" = 1 ]; then
  echo "machines:  ENFORCED on ci, cd, artifacts — issuer ${IDP} (no host port, no gateway route)"
  echo "           a token by hand: curl -u qits-ci:\$IDP_SECRET_QITS_CI -d grant_type=client_credentials \\"
  echo "                                 -d audience=qits-cd ${IDP}/token   (secrets: .qits-bootstrap.env)"
else
  echo "machines:  gate OFF (QITS_MACHINE_AUTH=0) — ci, cd and artifacts trust the network as before"
fi
[ -d /out ] && echo "seed compose + state saved to /out"
warn "not part of either set (no image exists): qits-dns, qits-spa-home"
warn "workspace containers need a qits/workspace:latest base image supplied separately"
exit "$overall"
