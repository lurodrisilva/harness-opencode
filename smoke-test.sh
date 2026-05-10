#!/usr/bin/env bash
# Build the image, run a container, hit the documented endpoints, tear down.
# Exit 0 on success, non-zero on the first failure with a useful diagnostic.
#
# Env knobs:
#   IMAGE             tag to build/use (default: opencode-smoke:test)
#   CONTAINER         container name (default: opencode-smoke)
#   HOST_PORT         host port to bind on loopback (default: 14096)
#   EXPECTED_VERSION  opencode version expected in /global/health (default: 1.14.40)
#   NONROOT_UID       expected runtime UID (default: 65532)
#   SKIP_BUILD        if set+nonempty, reuse the existing $IMAGE instead of rebuilding
#   KEEP_IMAGE        if set+nonempty, do not `docker rmi` $IMAGE on exit (faster reruns)

set -euo pipefail

IMAGE="${IMAGE:-opencode-smoke:test}"
CONTAINER="${CONTAINER:-opencode-smoke}"
HOST_PORT="${HOST_PORT:-14096}"
EXPECTED_VERSION="${EXPECTED_VERSION:-1.14.40}"
NONROOT_UID="${NONROOT_UID:-65532}"
SKIP_BUILD="${SKIP_BUILD:-}"
KEEP_IMAGE="${KEEP_IMAGE:-}"

cleanup() {
    local rc=$?
    if [ $rc -ne 0 ]; then
        echo
        echo "=== smoke test failed (rc=$rc) ===" >&2
        echo "=== container logs (last 50 lines) ===" >&2
        docker logs --tail 50 "$CONTAINER" >&2 2>&1 || true
    fi
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    if [ -z "$KEEP_IMAGE" ]; then
        docker rmi "$IMAGE" >/dev/null 2>&1 || true
    fi
    return $rc
}
trap cleanup EXIT

step() { printf '\n=== %s ===\n' "$*"; }

if [ -z "$SKIP_BUILD" ]; then
    step "build image"
    docker build --platform linux/amd64 -t "$IMAGE" .
else
    step "reusing existing image (SKIP_BUILD set): $IMAGE"
fi

# Bind on the host loopback only — the container runs the unauthenticated
# default (no OPENCODE_SERVER_PASSWORD), so don't make it reachable from the
# rest of the LAN even briefly.
step "start container on 127.0.0.1:$HOST_PORT"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d \
    --name "$CONTAINER" \
    --platform linux/amd64 \
    -p "127.0.0.1:${HOST_PORT}:4096" \
    "$IMAGE" >/dev/null

step "wait for /global/health to come up"
ready=0
for attempt in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:${HOST_PORT}/global/health" >/dev/null 2>&1; then
        echo "ready after ${attempt}s"
        ready=1
        break
    fi
    sleep 1
done
if [ "$ready" -ne 1 ]; then
    echo "ERROR: /global/health never returned 200 within 30s" >&2
    exit 1
fi

step "check /global/health body"
HEALTH="$(curl -fsS "http://127.0.0.1:${HOST_PORT}/global/health")"
echo "body: $HEALTH"
echo "$HEALTH" | grep -q '"healthy":true' \
    || { echo "ERROR: missing healthy:true" >&2; exit 1; }
echo "$HEALTH" | grep -q "\"version\":\"${EXPECTED_VERSION}\"" \
    || { echo "ERROR: version mismatch (want ${EXPECTED_VERSION})" >&2; exit 1; }

step "check /doc body"
DOC_HEAD="$(curl -fsS "http://127.0.0.1:${HOST_PORT}/doc" | head -c 64)"
echo "head: $DOC_HEAD"
case "$DOC_HEAD" in
    '{"openapi":"3.1.'*) ;;
    *) echo "ERROR: /doc body did not start with OpenAPI 3.1 JSON" >&2; exit 1 ;;
esac

step "verify nonroot UID"
ACTUAL_UID="$(docker inspect -f '{{.Config.User}}' "$CONTAINER")"
echo "container user: ${ACTUAL_UID:-<unset>}"
if [ "$ACTUAL_UID" != "nonroot" ] && [ "$ACTUAL_UID" != "$NONROOT_UID" ]; then
    echo "ERROR: container user is '$ACTUAL_UID', expected 'nonroot' or '$NONROOT_UID'" >&2
    exit 1
fi

# The warning prints AFTER DB migration completes, which can take a couple of
# seconds on a fresh container — independently of when /global/health starts
# answering. Poll for it instead of checking once.
step "verify the unsecured-server warning is logged when OPENCODE_SERVER_PASSWORD is unset"
warned=0
for attempt in $(seq 1 20); do
    if docker logs "$CONTAINER" 2>&1 | grep -q "OPENCODE_SERVER_PASSWORD is not set"; then
        echo "warning observed after ${attempt}s"
        warned=1
        break
    fi
    sleep 1
done
if [ "$warned" -ne 1 ]; then
    echo "ERROR: expected unsecured-server warning in logs within 20s" >&2
    echo "--- full logs ---" >&2
    docker logs "$CONTAINER" >&2 2>&1
    exit 1
fi

step "verify server is listening on 0.0.0.0:4096 (parsed from logs)"
if ! docker logs "$CONTAINER" 2>&1 | grep -q "opencode server listening on http://0.0.0.0:4096"; then
    echo "ERROR: expected listening log line not found" >&2
    exit 1
fi

step "ALL CHECKS PASSED"
