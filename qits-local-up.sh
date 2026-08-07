#!/bin/sh
# qits-local-up.sh — bring the qits platform up on this workstation's docker daemon, THROUGH the
# platform's own pipeline.
#
# The choreography lives in cli/qits-cli-bootstrap now, a Quarkus command-mode CLI that runs on the
# host. This file compiles that CLI and runs it, so the entry point people know still works:
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
# Three things this adds around the binary:
#   - it compiles the CLI when the sources are newer, so a checkout is never run stale;
#   - it names the wrapper repository, so the run is the same from any working directory;
#   - it puts the clones and the log beside the CLI, where its .gitignore already covers them.
#
# Knobs of its own:
#   QITS_CLI_BUILD   auto (default) = compile when the sources are newer than the binary
#                    always = compile every time; never = run what is there, fail if nothing is
#   JAVA_HOME        the GraalVM to compile with; taken from cli/qits-cli-bootstrap/.sdkmanrc
#                    under ~/.sdkman when unset

set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CLI="$ROOT/cli/qits-cli-bootstrap"
RUNNER="$CLI/target/qits-cli-bootstrap-1.0.0-SNAPSHOT-runner"

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
elif [ ! -x "$RUNNER" ]; then
  echo "no binary at $RUNNER and QITS_CLI_BUILD=never" >&2
  exit 2
fi

# --- run -------------------------------------------------------------------------------------
# The CLI falls back to bootstrap only when it is given nothing at all, so a leading flag would be
# an unknown top-level option. Name the mode when the first argument is one of bootstrap's flags.
case "${1:-}" in
  -h|--help|-V|--version) ;;
  ''|-*) set -- bootstrap "$@" ;;
esac

echo "log: $QITS_LOG_FILE"
exec "$RUNNER" "$@"
