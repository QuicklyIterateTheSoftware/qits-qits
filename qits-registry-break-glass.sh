#!/usr/bin/env bash
# Break-glass: publish the registry's port directly while edge is being fixed.
#
# Normally CLOSED. Once the registry sits behind edge (unify-ingress), a wedged
# edge blocks every image pull — including the pull that would forward-fix
# edge. `open` restores a direct host port so the host daemon can pull; `close`
# removes it again. Opening needs no pull itself: the registry image is already
# on the node.
#
# KNOWN DOCKER BEHAVIOR, both verified 2026-08-13 on Docker 29.7.2:
# - `--publish-rm` matches by TARGET port, so `close` removes EVERY direct
#   publish of the registry — which is exactly the normally-closed end state.
#   Until the standing 8081 publish is dropped (the port-drop step of
#   unify-ingress), `close` removes that one too; re-add it with:
#     docker service update --update-order stop-first \
#       --publish-add mode=host,published=8081,target=8080 dev-qits-artifacts
# - Two host-mode publishes of the SAME target port collapse to one on the
#   container (bindings are keyed by target). `open` on a spare port beside a
#   standing publish converges in the spec but never binds — open only works
#   from zero publishes, which is the only state it is meant for.
#
# Swarm cannot bind a publish to loopback (no host-ip field in either mode),
# so `open` first adds an iptables rule that drops every non-loopback packet
# to the port. The rule goes in before the port opens and leaves after it
# closes — no exposure window. Both updates force stop-first: start-first
# deadlocks on host-mode ports (the old task still holds them).
set -euo pipefail

SERVICE=${QITS_REGISTRY_SERVICE:-dev-qits-artifacts}
TARGET_PORT=8080
ACTION=${1:-}
PORT=${2:-8081}

rule() { sudo iptables "$1" INPUT -p tcp --dport "$PORT" ! -i lo -j DROP; }

case "$ACTION" in
  open)
    rule -I
    docker service update --detach=false --update-order stop-first \
      --publish-add "mode=host,published=$PORT,target=$TARGET_PORT" "$SERVICE"
    echo "break-glass OPEN: 127.0.0.1:$PORT -> $SERVICE:$TARGET_PORT (non-loopback dropped)"
    ;;
  close)
    docker service update --detach=false --update-order stop-first \
      --publish-rm "mode=host,published=$PORT,target=$TARGET_PORT" "$SERVICE"
    rule -D
    echo "break-glass CLOSED: every direct publish of target $TARGET_PORT removed"
    ;;
  status)
    echo "published ports on $SERVICE:"
    docker service inspect "$SERVICE" --format '{{json .Spec.EndpointSpec.Ports}}'
    if sudo iptables -C INPUT -p tcp --dport "$PORT" ! -i lo -j DROP 2>/dev/null; then
      echo "iptables scope rule PRESENT for $PORT"
    else
      echo "no iptables scope rule for $PORT"
    fi
    ;;
  *)
    echo "usage: $0 open|close|status [port (default 8081)]" >&2
    exit 2
    ;;
esac
