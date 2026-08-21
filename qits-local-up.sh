#!/bin/sh
# qits-local-up.sh — bring the qits platform up on this workstation's docker daemon, THROUGH the
# platform's own pipeline.
#
# The choreography lives in cli/qits-cli-bootstrap, a Quarkus command-mode CLI that runs INSIDE a
# container: the image carries the JRE, the docker CLI trio and git, and the host's docker socket
# is mounted into it. So the only thing this workstation has to have is docker.
#
#   ./qits-local-up.sh                     bootstrap the platform
#   ./qits-local-up.sh --skip-build        the seed images and the daemon binary exist already
#   ./qits-local-up.sh unwrap              take the platform off this machine (volumes stay)
#   ./qits-local-up.sh unwrap --dry-run    list what unwrap would remove
#
# Modes, flags and every QITS_* variable pass straight through. What they all are:
# cli/qits-cli-bootstrap/README.md. The shell port that used to be this file is in git history
# (`git log -- qits-local-up.sh`); its operational comments were carried into the CLI's sources.
#
# There are two ways in, and what decides between them is whether this file is sitting in a
# wrapper checkout:
#
#   WARM — it is. Compile the CLI, run it on the host, and let its host half do the rest: that
#          half builds the payload image from cli/qits-cli-bootstrap, mounts the wrapper, the
#          clones and the log, publishes the browser view and relays the exit code. Everything the
#          run needs is already on the machine, so this is the full path.
#
#   COLD — `curl -fsSL <raw url>/qits-local-up.sh | sh` on a bare box. There is no $0 to resolve,
#          no checkout to compile and no toolchain to compile with, so this path skips the host
#          half: it has the daemon build the payload image straight from the CLI's git URL and
#          runs it in the current directory. The CLI clones the wrapper itself, and every later
#          run from that checkout is a warm one.
#
# Knobs:
#   QITS_CLI_BUILD   warm only. auto (default) = compile when the sources are newer than the
#                    binary; always = compile every time; never = run what is there, fail if
#                    nothing is
#   JAVA_HOME        warm only. The GraalVM to compile with; taken from
#                    cli/qits-cli-bootstrap/.sdkmanrc under ~/.sdkman when unset
#   QITS_WRAPPER_DIR warm: defaults to this repository. Cold: leave it unset — the CLI clones the
#                    wrapper into the current directory, which is the only host path mounted
#   QITS_SRC         where the clones go. Warm: defaults beside the CLI. Cold: keep it relative,
#                    for the same reason
#   QITS_LOG_FILE    the run log. Same rule as QITS_SRC
#   QITS_ORG_URL     the git org. Cold reads it here as well, to know where to build the payload
#                    image from — from the environment only, because .env is the payload's to read
#
# Every other QITS_* reaches the container by name on both paths, and .env in the working
# directory reaches it by that directory being the container's too.

set -e

# --- which path ---------------------------------------------------------------------------------
# Warm is "$0 names a readable file, and that file is in a wrapper checkout". Piped to a shell, $0
# is the shell's own name and no such file is there — that absence is the test, because nothing
# else about a bare box can be relied on. .gitmodules is the wrapper's marker, the one the CLI
# looks for too.
here=$(dirname -- "$0")
ROOT=
if [ -r "$0" ] && [ -f "$here/.gitmodules" ]; then
  ROOT=$(CDPATH= cd -- "$here" && pwd)
fi

# The CLI falls back to bootstrap only when it is given nothing at all, so a leading flag would be
# an unknown top-level option. Name the mode when the first argument is one of bootstrap's flags.
case "${1:-}" in
  -h|--help|-V|--version) ;;
  ''|-*) set -- bootstrap "$@" ;;
esac

# --- cold: no checkout, so build the payload from git and run it here ----------------------------
if [ -z "$ROOT" ]; then
  # Same path as host/ContainerRun.SOCKET, and mounted at it: the payload drives THIS daemon.
  SOCKET=/var/run/docker.sock

  # Docker and nothing else. Everything the bootstrap shells — git, the docker CLI trio, a JRE —
  # is inside the image, and the image is built by the daemon from a URL, so this box needs no
  # toolchain of its own.
  command -v docker >/dev/null 2>&1 || {
    echo "docker is not installed, and it is the one thing this needs" >&2
    exit 2
  }
  docker info >/dev/null 2>&1 || {
    echo "cannot reach a docker daemon — is it running, and are you in its group?" >&2
    exit 2
  }
  [ -S "$SOCKET" ] || {
    echo "no docker socket at $SOCKET — the payload drives the daemon through it, so it has to be a local daemon" >&2
    exit 2
  }

  # The daemon fetches the repository itself: `#main` is the ref and -f names a path inside the
  # fetched tree, whose root is the build context — so the Dockerfile's COPY paths mean what they
  # mean in a checkout, and nothing is cloned on this box.
  #
  # The warm path tags this image by the content of the checkout it is built from. There is no
  # checkout to hash here, so the tag says how it was made instead, and the build runs every cold
  # boot — which is once per machine. It is deliberately not `qits/…`: unwrap sweeps that prefix
  # and would try to remove the image it is running from.
  image=qits-bootstrap:cold
  source=${QITS_ORG_URL:-https://github.com/QuicklyIterateTheSoftware}/qits-cli-bootstrap.git
  echo "building $image from $source"
  docker build -f docker/Dockerfile.bootstrap -t "$image" "$source#main"

  # THE MOUNT SET IS SMALL BECAUSE THE BOX IS EMPTY, not because this is a second copy of
  # host/ContainerRun. There is no wrapper to mount, no clone directory and no log file yet: the
  # CLI clones the wrapper into this directory, and QITS_SRC and QITS_LOG_FILE default relative to
  # it, so this one mount holds everything the run leaves behind. What is left is what a container
  # cannot do without — the socket it drives, the identity that owns the clone, a writable HOME
  # for a uid with no passwd entry, and the name that says which half of the binary this is.
  #
  # After this run the operator holds a real checkout and every later run is warm, where the Java
  # launcher owns the argv. A flag that needs more than "the box is empty" to justify it belongs
  # there, not here.
  work=$(pwd)

  # The durable progress supervisor. The warm/host launcher (HostLauncher) starts this; the cold
  # path has to as well, or the bootstrap edge below has no upstream and answers 503 on the browser
  # view. It owns the browser port (QITS_WEB_PORT, default 8480) and reads the worker's state from
  # the shared progress file, so a worker crash cannot take the public view down. The supervisor
  # tolerates a not-yet-written file. QITS_WEB=0 turns the whole view off.
  progressenv=
  if [ "${QITS_WEB:-1}" != 0 ]; then
    progressenv="-e QITS_PROGRESS_FILE=$work/.qits-bootstrap-progress.json"
    docker rm -f qits-bootstrap-progress >/dev/null 2>&1 || true
    docker run -d --name qits-bootstrap-progress --restart unless-stopped \
      --user "$(id -u):$(id -g)" -v "$work:$work" -w "$work" \
      -e QITS_WEB_BIND=true -e QITS_WEB_HOST=0.0.0.0 \
      "$image" progress-supervisor --state "$work/.qits-bootstrap-progress.json" >/dev/null \
      && echo "progress supervisor up (browser view served through the bootstrap edge)" \
      || echo "warning: progress supervisor did not start — the browser view will be unavailable"
  fi

  # Only when there is one to hand on: `-it` against a pipe is docker's "the input device is not a
  # TTY" and a stopped run. Under `curl | sh` there is none, so the run draws plain lines.
  tty=
  if [ -t 0 ] && [ -t 1 ]; then tty=-it; fi

  # Every QITS_* by NAME, so docker copies the value across and a secret stays out of this command
  # line. One contract: whatever configures a run here configures it inside.
  names=
  for name in $(env | sed -n 's/^\(QITS_[A-Za-z0-9_]*\)=.*/\1/p'); do
    [ "$name" = QITS_IN_CONTAINER ] || names="$names -e $name"
  done

  # $tty and $names are split on purpose: they hold docker flags and variable names, and neither
  # can contain a space.
  # shellcheck disable=SC2086
  exec docker run --rm $tty \
    -v "$SOCKET:$SOCKET" \
    --user "$(id -u):$(id -g)" \
    --group-add "$(stat -c %g "$SOCKET" 2>/dev/null || echo 0)" \
    -v "$work:$work" \
    -w "$work" \
    -e HOME=/tmp \
    -e QITS_IN_CONTAINER=1 \
    $progressenv \
    $names \
    "$image" "$@"
fi

# --- warm: compile the CLI and let its host half take over ---------------------------------------
CLI="$ROOT/cli/qits-cli-bootstrap"

# The version in the runner's name is release-stamped, so the name is not fixed. Take the newest.
resolve_runner() {
  RUNNER=$(ls -t "$CLI"/target/qits-cli-bootstrap-*-runner 2>/dev/null | head -n 1)
}
resolve_runner

# The payload image is built from this checkout, so it is not optional here — without it the CLI
# has nothing to build itself from.
[ -f "$CLI/pom.xml" ] || {
  echo "cli/qits-cli-bootstrap is not checked out — run: git submodule update --init" >&2
  exit 2
}

# The CLI reads QITS_SRC and QITS_LOG_FILE relative to the working directory, and finds the wrapper
# by walking up from it. Pin all three to this repository so where you stand cannot change what
# happens — an explicitly set variable still wins.
[ -n "${QITS_WRAPPER_DIR:-}" ] || { QITS_WRAPPER_DIR=$ROOT; export QITS_WRAPPER_DIR; }
[ -n "${QITS_SRC:-}" ]         || { QITS_SRC=$CLI/.qits-bootstrap-src; export QITS_SRC; }
[ -n "${QITS_LOG_FILE:-}" ]    || { QITS_LOG_FILE=$CLI/qits-bootstrap-cli.log; export QITS_LOG_FILE; }

# --- compile ---------------------------------------------------------------------------------
build_wanted() {
  case "${QITS_CLI_BUILD:-auto}" in
    always) return 0 ;;
    never)  return 1 ;;
    auto)
      [ -x "$RUNNER" ] || return 0
      # Any source or the pom newer than the binary means the binary is not what the checkout says.
      [ -n "$(find "$CLI/pom.xml" "$CLI/src/main" -newer "$RUNNER" -print 2>/dev/null | head -n 1)" ]
      ;;
    *) echo "QITS_CLI_BUILD must be auto, always or never" >&2; exit 2 ;;
  esac
}

if build_wanted; then
  # A plain JDK 25 cannot produce a native image, so the GraalVM .sdkmanrc names wins over an
  # inherited JAVA_HOME — under `sdk env` the two are the same one anyway. Nothing found means
  # whatever JAVA_HOME says, and maven says what is wrong with it.
  if [ -f "$CLI/.sdkmanrc" ]; then
    candidate="$HOME/.sdkman/candidates/java/$(sed -n 's/^java=//p' "$CLI/.sdkmanrc")"
    [ -d "$candidate" ] && { JAVA_HOME=$candidate; export JAVA_HOME; }
  fi
  echo "compiling the CLI${JAVA_HOME:+ with $JAVA_HOME}"
  # No `clean`: it wipes the runner, and a failed build would then leave nothing to run.
  ( cd "$CLI" && ./mvnw -B -ntp package -Dnative -DskipTests )
  resolve_runner
  [ -x "$RUNNER" ] || { echo "the build finished but left no runner in $CLI/target" >&2; exit 2; }
elif [ ! -x "$RUNNER" ]; then
  echo "no binary at $RUNNER and QITS_CLI_BUILD=never" >&2
  exit 2
fi

# --- run -------------------------------------------------------------------------------------
# The working directory is the fourth thing pinned to this repository, and the only one the
# variables above cannot pin: the container's working directory becomes the launcher's, and that
# is what the launcher mounts, what .env is read from, and what a relative QITS_* path hangs off.
# Pinning it makes the mount set the same wherever the command was typed.
cd "$ROOT"

echo "log: $QITS_LOG_FILE"
exec "$RUNNER" "$@"
