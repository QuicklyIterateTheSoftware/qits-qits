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
set -uo pipefail

REPO_ID="dc85aa7d-cf9c-440a-a375-f82c2400c449"
REPO_URL="https://github.com/QuicklyIterateTheSoftware/qits-system-platform-service.git"
BRANCH="maintenance/frontend"
REFSPEC="+refs/heads/${BRANCH}:refs/heads/${BRANCH}"
EXPECTED_GH="bac334c9df0d84c219c0df1b514f42cef602fc6c"
EXPECTED_PLAT="fdb67a7f6c48c34474f1d9449ddaaa6198c2b845"

echo "== locating dev-qits-projects container =="
docker ps --format '{{.ID}} {{.Names}}' | grep -i projects || true
CID=$(docker ps --format '{{.ID}} {{.Names}}' | grep dev-qits-projects | head -1 | awk '{print $1}')
if [ -z "${CID:-}" ]; then
  echo "FATAL: dev-qits-projects container not found"
  exit 1
fi
echo "container=$CID"

echo "== locating the mirror =="
MIRROR=""
for CAND in "/data/mirrors/${REPO_ID}.git" "/data/projects/mirrors/${REPO_ID}.git"; do
  if docker exec "$CID" test -f "$CAND/HEAD" 2>/dev/null; then MIRROR="$CAND"; break; fi
done
if [ -z "$MIRROR" ]; then
  echo "-- probing --"
  docker exec "$CID" sh -c "find / -maxdepth 5 -type d -name 'mirrors' 2>/dev/null" || true
  FOUND=$(docker exec "$CID" sh -c "find / -maxdepth 6 -type d -name '${REPO_ID}.git' 2>/dev/null | head -1" | tr -d '\r')
  MIRROR="$FOUND"
fi
if [ -z "$MIRROR" ]; then
  echo "FATAL: could not locate the mirror for $REPO_ID inside the container"
  exit 1
fi
echo "mirror=$MIRROR"

echo "== mirror's own ref =="
PLAT=$(docker exec "$CID" git --git-dir="$MIRROR" rev-parse "refs/heads/${BRANCH}" | tr -d '\r')
echo "mirror ${BRANCH} = $PLAT (expected $EXPECTED_PLAT)"
if [ "$PLAT" != "$EXPECTED_PLAT" ]; then
  echo "NOTE: the mirror has moved since diagnosis; pushing what the mirror holds, which is still"
  echo "      exactly the platform's own tip for this one branch."
fi

echo "== GitHub ref state BEFORE =="
docker exec "$CID" git ls-remote "$REPO_URL" "refs/heads/${BRANCH}"

echo "== corrective push: $REFSPEC =="
docker exec "$CID" git --git-dir="$MIRROR" \
  -c credential.helper="store --file=/data/git-credentials" \
  push --end-of-options "$REPO_URL" "$REFSPEC"
PUSH_RC=$?
echo "push rc=$PUSH_RC"

echo "== GitHub ref state AFTER =="
docker exec "$CID" git ls-remote "$REPO_URL" "refs/heads/${BRANCH}"

exit $PUSH_RC
