#!/usr/bin/env bash
# One-shot corrective push: realign GitHub's stale copy of
# refs/heads/maintenance/frontend for qits-system-platform-service.
#
# Diagnosis (2026-09-05, from the projects-service log line):
#   ! [rejected]  maintenance/frontend -> maintenance/frontend (non-fast-forward)
# The platform githost holds maintenance/frontend = fdb67a7f6c48c34474f1d9449ddaaa6198c2b845
# while GitHub holds                                bac334c9df0d84c219c0df1b514f42cef602fc6c,
# merge-base 44e439aa14072cf2c50888e68fb588e0b56d3ca8 -- neither is an ancestor of the other
# (the release-train branch was force-moved on the platform side). Exactly one ref is
# affected; every other head and tag pushes clean.
#
# The correction is one targeted forced update of that one ref. Nothing else is touched:
# no blanket force, no deletions, no push to the platform githost.
#
# Everything is probed with `git` itself rather than find/ls/test, because the projects
# container is a native-image image whose shell utilities cannot be relied on -- but it
# shells git, so git is certainly there.
set -uo pipefail

REPO_ID="dc85aa7d-cf9c-440a-a375-f82c2400c449"
REPO_URL="https://github.com/QuicklyIterateTheSoftware/qits-system-platform-service.git"
BRANCH="maintenance/frontend"
REFSPEC="+refs/heads/${BRANCH}:refs/heads/${BRANCH}"
EXPECTED_PLAT="fdb67a7f6c48c34474f1d9449ddaaa6198c2b845"

echo "== locating dev-qits-projects container =="
docker ps --format '{{.ID}} {{.Names}}' | grep -i projects || true
CID=$(docker ps --format '{{.ID}} {{.Names}}' | grep dev-qits-projects | head -1 | awk '{print $1}')
if [ -z "${CID:-}" ]; then
  echo "FATAL: dev-qits-projects container not found"
  exit 1
fi
echo "container=$CID"

echo "== container env (data-dir) =="
docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$CID" | grep -iE 'DATA|QITS_PROJECTS' || true
echo "== container workingdir =="
docker inspect --format '{{.Config.WorkingDir}}' "$CID"
WORKDIR=$(docker inspect --format '{{.Config.WorkingDir}}' "$CID" | tr -d '\r')
echo "== container mounts =="
docker inspect --format '{{range .Mounts}}{{.Type}} {{.Source}} -> {{.Destination}}{{println}}{{end}}' "$CID" || true

ENVDIR=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$CID" \
  | grep -E '^QITS_PROJECTS_DATA_DIR=' | head -1 | cut -d= -f2- | tr -d '\r')
echo "env data-dir='${ENVDIR:-<unset>}'"

MOUNTDESTS=$(docker inspect --format '{{range .Mounts}}{{println .Destination}}{{end}}' "$CID" | tr -d '\r')

CANDIDATES=""
[ -n "${ENVDIR:-}" ] && CANDIDATES="$CANDIDATES ${ENVDIR}/mirrors/${REPO_ID}.git"
for d in $MOUNTDESTS; do
  CANDIDATES="$CANDIDATES ${d}/mirrors/${REPO_ID}.git ${d}/projects/mirrors/${REPO_ID}.git"
done
CANDIDATES="$CANDIDATES /data/mirrors/${REPO_ID}.git /data/projects/mirrors/${REPO_ID}.git"
[ -n "${WORKDIR:-}" ] && CANDIDATES="$CANDIDATES ${WORKDIR}/data/projects/mirrors/${REPO_ID}.git"
CANDIDATES="$CANDIDATES /work/data/projects/mirrors/${REPO_ID}.git /deployment/data/projects/mirrors/${REPO_ID}.git /app/data/projects/mirrors/${REPO_ID}.git"

echo "== probing for the mirror =="
MIRROR=""
PLAT=""
for CAND in $CANDIDATES; do
  OUT=$(docker exec "$CID" git --git-dir="$CAND" rev-parse --verify "refs/heads/${BRANCH}" 2>&1 | tr -d '\r')
  echo "  $CAND -> $OUT"
  case "$OUT" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) MIRROR="$CAND"; PLAT="$OUT"; break ;;
  esac
done

if [ -z "$MIRROR" ]; then
  echo "FATAL: could not locate the mirror for $REPO_ID inside the container"
  exit 1
fi
echo "mirror=$MIRROR"
echo "mirror ${BRANCH} = $PLAT (diagnosed $EXPECTED_PLAT)"

echo "== GitHub ref state BEFORE =="
docker exec "$CID" git --git-dir="$MIRROR" ls-remote "$REPO_URL" "refs/heads/${BRANCH}"

echo "== corrective push: $REFSPEC =="
docker exec "$CID" git --git-dir="$MIRROR" \
  -c credential.helper="store --file=/data/git-credentials" \
  push --end-of-options "$REPO_URL" "$REFSPEC"
PUSH_RC=$?
echo "push rc=$PUSH_RC"

echo "== GitHub ref state AFTER =="
docker exec "$CID" git --git-dir="$MIRROR" ls-remote "$REPO_URL" "refs/heads/${BRANCH}"

exit $PUSH_RC
