#!/bin/bash
echo "== containers on host:"
docker ps --format '{{.ID}} {{.Names}} {{.Image}}' 2>&1
echo
echo "== maven/mirror env of every container:"
for c in $(docker ps -q); do
  n=$(docker inspect -f '{{.Name}}' "$c")
  e=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c" | grep -E "QITS_MAVEN|MIRROR|PROXY" || true)
  if [ -n "$e" ]; then echo "-- $n"; echo "$e"; fi
done
echo
echo "== host-netns reachability of mirror.dev.localhost:8080 (what a docker-build RUN sees):"
docker run --rm --network host registry.dev.localhost:8080/qits/build-images/ci-base:latest sh -c '
  getent hosts mirror.dev.localhost || echo "NO-DNS for mirror.dev.localhost"
  wget -O /dev/null "http://mirror.dev.localhost:8080/mirror/maven/central/aopalliance/aopalliance/1.0/aopalliance-1.0.pom" 2>&1 | tail -2
  getent hosts registry.dev.localhost || echo "NO-DNS for registry.dev.localhost"
' 2>&1 | tail -8
