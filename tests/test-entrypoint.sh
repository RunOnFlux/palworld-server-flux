#!/bin/bash
# Integration test for PID 1, run against a built image with a stub in place of
# upstream's init.sh. It proves the three things the image promises about how a
# container ends, without downloading five gigabytes of Palworld:
#
#   1. a restart asked for from inside always ends the container, even when init
#      refuses to go, and reports exit 42 so the reason is on the record
#   2. `docker stop` still reaches upstream's own SIGTERM handler, which is what
#      saves the world on a normal redeploy
#   3. an ordinary exit is passed through untouched
#
#   ./tests/test-entrypoint.sh [image]        (default: palworld-server-flux:local)

set -uo pipefail

IMAGE="${1:-palworld-server-flux:local}"
tmp="$(mktemp -d)"
chmod 0755 "${tmp}"
trap 'rm -rf "${tmp}"; docker rm -f flux-entrypoint-test >/dev/null 2>&1' EXIT

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

run_stub() {
  docker rm -f flux-entrypoint-test >/dev/null 2>&1
  docker run -d --name flux-entrypoint-test \
    -e STUB_MODE="$1" \
    -e FLUX_RESTART_GRACE=5 \
    -e FLUX_GUARD_INTERVAL=2 \
    -v "${tmp}/init.sh:/home/steam/server/init.sh:ro" \
    "${IMAGE}" >/dev/null
  # Wait for PID 1 to have started the child.
  for _ in $(seq 1 30); do
    docker logs flux-entrypoint-test 2>&1 | grep -q "stub: started" && return 0
    sleep 1
  done
  echo "  FAIL container never started the stub"
  docker logs flux-entrypoint-test 2>&1 | tail -20
  return 1
}

echo "a restart requested from inside"
if run_stub ignore; then
  docker exec flux-entrypoint-test touch /tmp/flux-restart-requested
  check "exit code says it was deliberate" 42 "$(docker wait flux-entrypoint-test)"
  check "init that ignores SIGTERM is killed anyway" 1 \
    "$(docker logs flux-entrypoint-test 2>&1 | grep -c 'still alive.*killing it')"
fi

echo "docker stop"
if run_stub linger; then
  docker stop -t 30 flux-entrypoint-test >/dev/null
  check "the signal reached init" 1 "$(docker logs flux-entrypoint-test 2>&1 | grep -c 'stub: SIGTERM received')"
  check "init's own exit code is passed through" 7 "$(docker wait flux-entrypoint-test)"
fi

echo "the server exits on its own"
if run_stub exit; then
  check "exit code is passed through" 3 "$(docker wait flux-entrypoint-test)"
  check "no restart is claimed" 0 "$(docker logs flux-entrypoint-test 2>&1 | grep -c 'exiting on purpose')"
fi

echo "the guard"
if run_stub linger; then
  check "it says it is armed" 1 "$(docker logs flux-entrypoint-test 2>&1 | grep -c 'guard armed')"
  check "it does not act with no server process" 0 \
    "$(docker logs flux-entrypoint-test 2>&1 | grep -c 'RESTART requested')"
  check "the health check reports unhealthy with no server" 1 \
    "$(docker exec flux-entrypoint-test /home/steam/server/flux-guard.sh --check >/dev/null 2>&1; echo $?)"
  docker rm -f flux-entrypoint-test >/dev/null 2>&1
fi

echo "a world that unloads under a healthy server"
docker rm -f flux-entrypoint-test >/dev/null 2>&1
docker run -d --name flux-entrypoint-test \
  -e STUB_MODE=server \
  -e FLUX_GUARD_INTERVAL=2 \
  -e FLUX_GUARD_FAILURES=2 \
  -e FLUX_GUARD_MIN_UPTIME=0 \
  -e FLUX_RESTART_GRACE=5 \
  -v "${tmp}/init.sh:/home/steam/server/init.sh:ro" \
  "${IMAGE}" >/dev/null
for _ in $(seq 1 30); do
  docker logs flux-entrypoint-test 2>&1 | grep -q "healthy for the first time" && break
  sleep 1
done
check "a working server is left alone" 1 \
  "$(docker logs flux-entrypoint-test 2>&1 | grep -c 'healthy for the first time')"

# The signature from the incident: same process, uptime restarted from zero, no
# world behind the API.
docker exec flux-entrypoint-test sh -c 'printf "{\"serverfps\":0,\"currentplayernum\":0,\"uptime\":12,\"days\":0}" > /tmp/metrics.json'
check "the container is restarted" 42 "$(timeout 60 docker wait flux-entrypoint-test)"
check "and says why" 1 "$(docker logs flux-entrypoint-test 2>&1 | grep -c 'RESTART requested: worldless')"
check "the evidence is in the log" yes \
  "$(docker logs flux-entrypoint-test 2>&1 | grep -q 'worldless 1/2 (rest=200 metrics=1 fps=0' && echo yes || echo no)"

if [ "${failures}" -eq 0 ]; then
  echo "all entrypoint tests passed"
else
  echo "${failures} test(s) failed"
  exit 1
fi
