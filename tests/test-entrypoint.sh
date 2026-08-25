#!/bin/bash
# Integration test for PID 1, run against a built image with a stub in place of
# upstream's init.sh. It proves what the image promises about how a server comes
# back, without downloading five gigabytes of Palworld:
#
#   1. a broken server is restarted IN PLACE, in seconds, without the container
#      ending and without the platform being involved
#   2. players are warned in game first, and a server that recovers during the
#      countdown is left alone
#   3. `docker stop` still reaches upstream's own SIGTERM handler (which is what
#      saves the world on a redeploy) and is never followed by a restart
#   4. a server that will not stay up stops being restarted and the container ends
#      instead, so the platform can rebuild or move it
#
#   ./tests/test-entrypoint.sh [image]        (default: palworld-server-flux:local)

set -uo pipefail

IMAGE="${1:-palworld-server-flux:local}"
CONTAINER=flux-entrypoint-test
tmp="$(mktemp -d)"
chmod 0755 "${tmp}"
trap 'rm -rf "${tmp}"; docker rm -f "${CONTAINER}" >/dev/null 2>&1' EXIT

failures=0
check() {
  local label="$1" expected="$2" actual="$3"
  if [ "${expected}" = "${actual}" ]; then
    printf '  ok   %s\n' "${label}"
  else
    printf '  FAIL %s: expected [%s], got [%s]\n' "${label}" "${expected}" "${actual}"
    failures=$((failures + 1))
  fi
}
logs() { docker logs "${CONTAINER}" 2>&1; }

# A single `docker logs` read can come back short while the container is busy, and
# a line that is genuinely there then reads as missing — which looks like a broken
# feature rather than a busy machine. Retry briefly before concluding it is absent;
# a line that never arrives still fails, just five seconds later.
saw() {
  for _ in $(seq 1 5); do
    logs | grep -qF "$1" && { echo yes; return; }
    sleep 1
  done
  echo no
}

cat >"${tmp}/init.sh" <<'STUB'
#!/bin/bash
# Stands in for upstream's init.sh. STUB_MODE picks the behaviour under test.
trap 'echo "stub: SIGTERM received"; exit 7' TERM
echo "stub: started as $(id -un)"
case "${STUB_MODE:-linger}" in
  exit)   sleep 2; echo "stub: exiting on its own"; exit 3 ;;
  ignore) trap '' TERM; while true; do sleep 1; done ;;   # refuses to die politely
  server)
    # Stands in for a running Palworld server: a process with the name the guard
    # looks for, and the two REST endpoints it reads, served from a file the test
    # rewrites to make the world disappear underneath it.
    printf '{"serverfps":59,"currentplayernum":1,"uptime":600,"days":523}' > /tmp/metrics.json
    python3 -c '
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/v1/api/metrics"):
            body = open("/tmp/metrics.json","rb").read()
        elif self.path.startswith("/v1/api/info"):
            body = b"{\"version\":\"stub\"}"
        else:
            self.send_error(404); return
        self.send_response(200)
        self.send_header("Content-Type","application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 8212), H).serve_forever()
' &
    ( exec -a PalServer-Linux-Shipping sleep 600 ) &
    game_pid=$!
    echo "stub: fake server up (pid ${game_pid})"
    wait "${game_pid}"
    echo "stub: fake server gone, ending like start.sh does"
    exit 0
    ;;
  *)      while true; do sleep 1; done ;;
esac
STUB
chmod 0755 "${tmp}/init.sh"

# `docker rm -f` returns before the name is actually free, so the next `docker run`
# can lose the race and fail with a name conflict. Everything after that reads the
# OLD container's logs, which shows up as an unrelated assertion failing.
remove_container() {
  docker rm -f "${CONTAINER}" >/dev/null 2>&1
  for _ in $(seq 1 30); do
    docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER}" || return 0
    sleep 1
  done
  echo "  FAIL could not remove the previous test container"
  failures=$((failures + 1))
  return 1
}

# run_stub <mode> [-e VAR=value ...]
run_stub() {
  local mode="$1"; shift
  remove_container || return 1
  docker run -d --name "${CONTAINER}" \
    -e STUB_MODE="${mode}" \
    -e FLUX_RESTART_GRACE=5 \
    -e FLUX_RESTART_BACKOFF=1 \
    -e FLUX_GUARD_INTERVAL=2 \
    "$@" \
    -v "${tmp}/init.sh:/home/steam/server/init.sh:ro" \
    "${IMAGE}" >/dev/null
  for _ in $(seq 1 30); do
    logs | grep -q "stub: started" && return 0
    sleep 1
  done
  echo "  FAIL container never started the stub"
  logs | tail -20
  return 1
}

# wait_for <text> <seconds>
# A timeout is reported as its own failure. Without that, every assertion that
# followed failed instead, which reads like a broken feature rather than a busy
# machine — and these containers do get slow when something else is saturating the
# disk.
wait_for() {
  for _ in $(seq 1 "$2"); do
    logs | grep -qF "$1" && return 0
    sleep 1
  done
  printf '  FAIL timed out after %ss waiting for: %s\n' "$2" "$1"
  failures=$((failures + 1))
  return 1
}

echo "a restart requested from inside, with a server that will not go quietly"
if run_stub ignore; then
  docker exec "${CONTAINER}" touch /tmp/flux-restart-requested
  wait_for "starting the server (generation 2)" 60
  check "the wedged generation is forced down" yes "$(saw 'still winding down; forcing this generation to end')"
  check "a fresh server is started in place" yes "$(saw 'starting the server (generation 2)')"
  check "the container never ended" true "$(docker inspect -f '{{.State.Running}}' ${CONTAINER})"
  # A marker that outlives the generation it belonged to killed a healthy server on a
  # real box: a scheduled restart fired in the gap between two generations, found
  # nothing to stop, and left the request behind for the next one to obey.
  check "the request does not outlive the generation" 1 \
    "$(docker exec ${CONTAINER} test -f /tmp/flux-restart-requested; echo $?)"
  sleep 12   # longer than FLUX_RESTART_GRACE: a stale marker would fire by now
  check "and the fresh generation is left alone" 0 \
    "$(logs | grep -c 'starting the server (generation 3)')"
fi

echo "docker stop"
if run_stub linger; then
  docker stop -t 30 "${CONTAINER}" >/dev/null
  check "the signal reached init" yes "$(saw 'stub: SIGTERM received')"
  check "init's own exit code is passed through" 7 "$(docker wait ${CONTAINER})"
  check "and nothing was restarted afterwards" no "$(saw 'generation 2')"
fi

echo "a server that will not stay up"
if run_stub exit -e FLUX_RESTART_MAX_ATTEMPTS=2; then
  check "it gives up and ends the container" 42 "$(timeout 60 docker wait ${CONTAINER})"
  check "and says why" yes "$(saw 'restarts within 3600s')"
  check "after restarting it in place twice" yes "$(saw 'starting the server (generation 3)')"
fi

echo "the same server under FLUX_RESTART_MODE=container"
if run_stub exit -e FLUX_RESTART_MODE=container; then
  check "the container ends on the first exit" 42 "$(timeout 60 docker wait ${CONTAINER})"
  check "with no in-place restart at all" no "$(saw 'generation 2')"
fi

echo "a world that unloads under a healthy server"
if run_stub server -e FLUX_GUARD_FAILURES=2 -e FLUX_GUARD_MIN_UPTIME=0 -e FLUX_GUARD_RESTART_DELAY=4; then
  wait_for "healthy for the first time" 30
  check "a working server is left alone" yes "$(saw 'healthy for the first time')"

  # The signature from the incident: same process, uptime restarted from zero, no
  # world behind the API.
  docker exec "${CONTAINER}" sh -c 'printf "{\"serverfps\":0,\"currentplayernum\":0,\"uptime\":12,\"days\":0}" > /tmp/metrics.json'
  wait_for "starting the server (generation 2)" 60
  check "the world loss is detected" yes "$(saw 'worldless 2/2 (rest=200 metrics=1 fps=0')"
  check "players are warned before anything happens" yes "$(saw 'warning players and restarting in 4s')"
  check "the server is killed" yes "$(saw 'sending SIGKILL to PalServer-Linux-Shipping')"
  check "and replaced in place" yes "$(saw 'starting the server (generation 2)')"
  check "the container never ended" true "$(docker inspect -f '{{.State.Running}}' ${CONTAINER})"
  check "the new server comes up healthy" yes "$(saw 'stub: fake server up')"
fi

echo "a server that recovers during the countdown"
if run_stub server -e FLUX_GUARD_FAILURES=2 -e FLUX_GUARD_MIN_UPTIME=0 -e FLUX_GUARD_RESTART_DELAY=20; then
  wait_for "healthy for the first time" 30
  docker exec "${CONTAINER}" sh -c 'printf "{\"serverfps\":0,\"uptime\":12}" > /tmp/metrics.json'
  wait_for "warning players and restarting in 20s" 30
  docker exec "${CONTAINER}" sh -c 'printf "{\"serverfps\":59,\"uptime\":900}" > /tmp/metrics.json'
  wait_for "restart cancelled" 40
  check "the restart is called off" yes "$(saw 'restart cancelled: the server recovered')"
  check "and nothing was killed" no "$(saw 'sending SIGKILL')"
  remove_container
fi

if [ "${failures}" -eq 0 ]; then
  echo "all entrypoint tests passed"
else
  echo "${failures} test(s) failed"
  exit 1
fi
