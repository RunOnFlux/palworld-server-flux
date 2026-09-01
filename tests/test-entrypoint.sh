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
    # rewrites to make the world disappear underneath it. Two flag files let a test
    # reach the states the file alone cannot describe:
    #   /tmp/force401  every request is refused, the way a server with no
    #                  AdminPassword refuses ours
    #   /tmp/stall     headers go out and then nothing does, which is what a wedged
    #                  game thread looks like from the probe's side
    printf '{"serverfps":59,"currentplayernum":1,"uptime":600,"days":523}' > /tmp/metrics.json
    ( exec -a PalServer-Linux-Shipping sleep 600 ) &
    game_pid=$!
    GAME_PID="${game_pid}" python3 -c '
import http.server, os, time
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        # /v1/api/stop is the game telling the community list it is leaving, and
        # the reason the guard asks before it kills. Off unless a test asks for it:
        # every case written before this one expects the SIGKILL.
        if os.path.exists("/tmp/force401"):
            self.send_response(401)
            self.send_header("Content-Length","0")
            self.end_headers(); return
        if self.path.startswith("/v1/api/stop") and os.path.exists("/tmp/honourstop"):
            self.send_response(200)
            self.send_header("Content-Length","2")
            self.end_headers()
            self.wfile.write(b"ok")
            os.kill(int(os.environ["GAME_PID"]), 9)
            return
        self.send_error(404)
    def do_GET(self):
        if os.path.exists("/tmp/force401"):
            self.send_response(401)
            self.send_header("Content-Length","0")
            self.end_headers(); return
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
        if os.path.exists("/tmp/stall"):
            # Single threaded on purpose: one wedged request wedges the whole API,
            # which is the mode A shape. Clearing the flag lets it go again.
            while os.path.exists("/tmp/stall"): time.sleep(0.2)
            return
        self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 8212), H).serve_forever()
' &
    # A /proc the test can write to, so a world unload can take its gigabytes with
    # it the way a real one does. Only used when FLUX_PROC_ROOT points here.
    if [ -n "${FLUX_FAKE_PROC:-}" ]; then
      mkdir -p "${FLUX_FAKE_PROC}/${game_pid}"
      printf 'Name:\tPalServer-Lin\nVmRSS:\t %s kB\n' "${FAKE_RSS_KB:-3168996}" \
        >"${FLUX_FAKE_PROC}/${game_pid}/status"
    fi
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

# wait_for_count <text> <times> <seconds>
# For a line that comes once per generation. `wait_for` on one of those is
# satisfied by the previous generation's copy and returns before anything has
# happened, which turns the next step into a race.
wait_for_count() {
  for _ in $(seq 1 "$3"); do
    [ "$(logs | grep -cF "$1")" -ge "$2" ] && return 0
    sleep 1
  done
  printf '  FAIL timed out after %ss waiting for %s copies of: %s\n' "$3" "$2" "$1"
  failures=$((failures + 1))
  return 1
}

echo "a brand new server with no settings file"
if run_stub linger; then
  ini=/palworld/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini
  check "it is given one before the game starts" 0 \
    "$(docker exec "${CONTAINER}" test -s "${ini}"; echo $?)"
  check "with the REST API on" True \
    "$(docker exec "${CONTAINER}" grep -o 'RESTAPIEnabled=[^,)]*' "${ini}" | cut -d= -f2 | tr -d '\r\n')"
  check "with a 60 second autosave" 60.000000 \
    "$(docker exec "${CONTAINER}" grep -o 'AutoSaveSpan=[^,)]*' "${ini}" | cut -d= -f2 | tr -d '\r\n')"
  check "with an admin password" 24 \
    "$(docker exec "${CONTAINER}" grep -o 'AdminPassword="[^"]*"' "${ini}" | sed 's/.*="//;s/"//' | tr -d '\r\n' | wc -c)"
  check "and the password is picked up for the container's own calls" yes \
    "$(saw 'using AdminPassword from')"
fi

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
  # world behind the API. That pair cannot happen to a working server, so it is
  # acted on at once — no second and third strike, and no countdown announced into
  # a world that is not there to hear it. On 1785894699157 that patience cost three
  # minutes of every five minute recovery, 23 times over.
  docker exec "${CONTAINER}" sh -c 'printf "{\"serverfps\":0,\"currentplayernum\":0,\"uptime\":12,\"days\":0}" > /tmp/metrics.json'
  wait_for "starting the server (generation 2)" 60
  check "the world loss is detected" yes "$(saw 'worldless 1/1 (rest=200 metrics=1 fps=0')"
  check "and acted on without waiting for more of the same" \
    yes "$(saw 'the world is provably gone, so there is nobody to warn — restarting now')"
  check "no countdown is announced to an empty world" no "$(saw 'warning players and restarting in 4s')"
  check "the scene is read before it is destroyed" \
    yes "$(saw 'capturing the state of this worldless server')"
  check "including what the API could still tell us" yes "$(saw '/v1/api/info said')"
  check "the server is killed" yes "$(saw 'sending SIGKILL to PalServer-Linux-Shipping')"
  check "and replaced in place" yes "$(saw 'starting the server (generation 2)')"
  check "the container never ended" true "$(docker inspect -f '{{.State.Running}}' ${CONTAINER})"
  check "the new server comes up healthy" yes "$(saw 'stub: fake server up')"
fi

echo "a server that recovers during the countdown"
# Deliberately the OTHER shape of a world loss: serverfps stops coming back but the
# uptime counter keeps climbing, which is every sample after the one where the
# world actually went. That is evidence, not proof, so it still costs two strikes
# and still warns the players — and is still allowed to change its mind.
if run_stub server -e FLUX_GUARD_FAILURES=2 -e FLUX_GUARD_MIN_UPTIME=0 -e FLUX_GUARD_RESTART_DELAY=20; then
  wait_for "healthy for the first time" 30
  docker exec "${CONTAINER}" sh -c 'printf "{\"currentplayernum\":0,\"uptime\":900}" > /tmp/metrics.json'
  wait_for "warning players and restarting in 20s" 30
  check "unproven evidence still waits for a second opinion" yes "$(saw 'worldless 2/2')"
  docker exec "${CONTAINER}" sh -c 'printf "{\"serverfps\":59,\"uptime\":960}" > /tmp/metrics.json'
  wait_for "restart cancelled" 40
  check "the restart is called off" yes "$(saw 'restart cancelled: the server recovered')"
  check "and nothing was killed" no "$(saw 'sending SIGKILL')"
fi

# A killed server never tells Pocketpair's community list it is going, so the entry
# is orphaned there and the next generation registers a second one beside it —
# which is what the duplicates in a player's Recent Servers list are made of. The
# guard asks first, and only kills what will not go.
echo "a convicted server that takes the stop request"
if run_stub server -e FLUX_GUARD_MIN_UPTIME=0 -e FLUX_GUARD_RESTART_DELAY=0 \
  -e FLUX_FORCE_STOP_WAIT=15; then
  wait_for "healthy for the first time" 30
  docker exec "${CONTAINER}" sh -c 'touch /tmp/honourstop'
  docker exec "${CONTAINER}" sh -c 'printf "{\"serverfps\":0,\"currentplayernum\":0,\"uptime\":12,\"days\":0}" > /tmp/metrics.json'
  wait_for "starting the server (generation 2)" 60
  check "the server is asked to stop rather than killed" \
    yes "$(saw 'and it went down on its own after')"
  check "so no SIGKILL is needed" no "$(saw 'sending SIGKILL')"
  check "and the generation is replaced as usual" yes "$(saw 'starting the server (generation 2)')"
  check "nothing wrote to the save on the way out" no "$(saw 'WARN the save on disk changed')"
  check "the container never ended" true "$(docker inspect -f '{{.State.Running}}' ${CONTAINER})"
fi

# 1787015974836, generation 2: healthy at 09:21:55, world proved gone at 09:22:55,
# and not restarted until 09:26:58 — the min-uptime rule held a proof, the proof
# expired while it was held (the uptime counter climbs again from its new base),
# and what was left took the patient path. Four minutes of a dead world, three of
# them re-proving something one sample had settled.
echo "a world that unloads before the min-uptime rule expires"
if run_stub server -e FLUX_GUARD_MIN_UPTIME=300 -e FLUX_GUARD_RESTART_DELAY=4; then
  wait_for "healthy for the first time" 30
  docker exec "${CONTAINER}" sh -c 'printf "{\"serverfps\":0,\"currentplayernum\":0,\"uptime\":12,\"days\":0}" > /tmp/metrics.json'
  wait_for "starting the server (generation 2)" 60
  check "a proven loss is not held by the age of the generation" \
    no "$(saw 'holding: worldless')"
  check "and is still acted on at once" \
    yes "$(saw 'the world is provably gone, so there is nobody to warn — restarting now')"
  check "the generation is replaced" yes "$(saw 'starting the server (generation 2)')"
  check "the container never ended" true "$(docker inspect -f '{{.State.Running}}' ${CONTAINER})"
fi

echo "a world that keeps unloading"
# A rebuilt container cannot fix a bug in the game that only reproduces on this
# customer's save, and buying one costs a full SteamCMD install. Restarts that the
# in-place restart demonstrably fixes must not spend the budget that ends the
# container — with FLUX_RESTART_MAX_ATTEMPTS=1, the old accounting ended it here.
if run_stub server -e FLUX_GUARD_FAILURES=2 -e FLUX_GUARD_MIN_UPTIME=0 \
    -e FLUX_GUARD_RESTART_DELAY=0 -e FLUX_RESTART_MAX_ATTEMPTS=1; then
  unload() { docker exec "${CONTAINER}" sh -c 'printf "{\"serverfps\":0,\"uptime\":12}" > /tmp/metrics.json'; }
  wait_for "healthy for the first time" 30
  unload
  wait_for "starting the server (generation 2)" 60
  wait_for_count "healthy for the first time" 2 60
  unload
  wait_for "starting the server (generation 3)" 60
  check "a world unload is not charged to the restart budget" \
    yes "$(saw 'not counted against the 1-in-3600s budget')"
  check "so the container is still up after more unloads than the budget allows" \
    true "$(docker inspect -f '{{.State.Running}}' ${CONTAINER})"
fi

# Everything below drives the guard through a writable /proc, so the memory the
# world lives in can be taken away from it the way a real unload does.
fake_proc=(-e FLUX_PROC_ROOT=/tmp/fakeproc -e FLUX_FAKE_PROC=/tmp/fakeproc)
collapse_rss() {
  docker exec "${CONTAINER}" sh -c \
    'for d in /tmp/fakeproc/*/; do printf "VmRSS:\t 1030908 kB\n" > "$d/status"; done'
}

echo "a world that unloads without moving the uptime counter"
# Every sample after the one where the world went: serverfps stops coming back but
# uptime climbs on from its new base, so the edge that proves it is already gone.
# Resident memory is the half that is a level rather than an edge, and it is what
# covers a sample lost to a timeout — 3.2 GB down to 1.0 GB, the real numbers off
# the crash dumps.
if run_stub server "${fake_proc[@]}" -e FLUX_GUARD_FAILURES=3 -e FLUX_GUARD_MIN_UPTIME=0 \
    -e FLUX_GUARD_RESTART_DELAY=4; then
  wait_for "healthy for the first time" 30
  check "the peak is picked up while the world is loaded" yes "$(saw 'peak=3094M')"
  docker exec "${CONTAINER}" sh -c 'printf "{\"currentplayernum\":0,\"uptime\":900}" > /tmp/metrics.json'
  collapse_rss
  wait_for "starting the server (generation 2)" 60
  check "the collapse is what convicts" yes "$(saw 'worldless 1/1 (rest=200 metrics=1 fps=- players=0 uptime=900')"
  check "and it is visible in the evidence" yes "$(saw 'rss=1006M peak=3094M')"
  check "acted on at once, with no countdown" \
    yes "$(saw 'the world is provably gone, so there is nobody to warn — restarting now')"
  check "the container never ended" true "$(docker inspect -f '{{.State.Running}}' ${CONTAINER})"
fi

echo "the same world unload behind a 401"
# The hole the memory signal was added to close: with the API refusing us, mode B
# has no symptom the other rules can see. It convicts — but the patient way, since
# there is nothing left to cross-check a single reading against.
if run_stub server "${fake_proc[@]}" -e FLUX_GUARD_FAILURES=3 -e FLUX_GUARD_MIN_UPTIME=0 \
    -e FLUX_GUARD_RESTART_DELAY=4; then
  wait_for "healthy for the first time" 30
  docker exec "${CONTAINER}" sh -c 'touch /tmp/force401'
  collapse_rss
  wait_for "starting the server (generation 2)" 90
  check "a world unload is seen at all through a 401" yes "$(saw 'worldless 1/3 (rest=401')"
  check "but never on one sample" yes "$(saw 'worldless 3/3 (rest=401')"
  check "and the players are still warned" yes "$(saw 'warning players and restarting in 4s')"
  check "the bad credentials are called out too" yes "$(saw 'no usable admin password')"
  docker exec "${CONTAINER}" sh -c 'rm -f /tmp/force401'
fi

echo "a world that unloads between two samples"
# The wait between samples is where the remaining detection latency lives: half a
# sample interval on average, and nothing about the REST API can be made cheaper
# to ask. Memory can — it is a read from /proc, invisible to the game — so it is
# watched all the way through the wait. The collapse is dropped in immediately
# after a sample, so the next scheduled one is nearly a full interval away and
# everything below has to time out without the early wake.
if run_stub server "${fake_proc[@]}" -e FLUX_GUARD_INTERVAL=30 -e FLUX_GUARD_RSS_POLL=1 \
    -e FLUX_GUARD_FAILURES=3 -e FLUX_GUARD_MIN_UPTIME=0 -e FLUX_GUARD_RESTART_DELAY=4; then
  wait_for "healthy for the first time" 60
  docker exec "${CONTAINER}" sh -c 'printf "{\"currentplayernum\":0,\"uptime\":900}" > /tmp/metrics.json'
  collapse_rss
  wait_for "sampling now rather than in" 12
  check "the wait is cut short by the collapse" yes "$(saw 'resident memory fell to 1006M')"
  wait_for "starting the server (generation 2)" 15
  check "and the sample it brings forward decides as it always would" \
    yes "$(saw 'worldless 1/1')"
fi

echo "memory that falls without the world going with it"
# The failure mode of the idea above: a collapse the full sample then calls
# healthy is still a collapse on the next glance, and on the one after that. Left
# as a level it would wake the guard every second for the life of the generation,
# each wake costing a REST call. It is an edge — one wake per fall, re-armed only
# when memory comes back.
if run_stub server "${fake_proc[@]}" -e FLUX_GUARD_INTERVAL=10 -e FLUX_GUARD_RSS_POLL=1 \
    -e FLUX_GUARD_FAILURES=3 -e FLUX_GUARD_MIN_UPTIME=0; then
  wait_for "healthy for the first time" 60
  collapse_rss                      # ...while metrics keeps reporting fps 59
  wait_for "sampling now rather than in" 20
  sleep 15
  check "it wakes once, not once a second" 1 "$(logs | grep -c 'sampling now rather than in')"
  check "and nothing is restarted over it" no "$(saw 'generation 2')"
  # Memory back where it was: the wake re-arms, and a second fall is seen again.
  docker exec "${CONTAINER}" sh -c \
    'for d in /tmp/fakeproc/*/; do printf "VmRSS:\t 3168996 kB\n" > "$d/status"; done'
  sleep 12
  collapse_rss
  wait_for_count "sampling now rather than in" 2 20
  check "a later fall is seen again" 2 "$(logs | grep -c 'sampling now rather than in')"
fi

echo "a server that sends its headers and then stops"
# curl exits 28 with %{http_code} already set to 200 and an empty body behind it.
# Read literally that is "the API answered and reported no world" — a stalled
# server diagnosed as a world unload, which is the wrong word in the log and now
# the wrong side of the restart budget too.
if run_stub server -e FLUX_GUARD_FAILURES=2 -e FLUX_GUARD_MIN_UPTIME=0 \
    -e FLUX_GUARD_RESTART_DELAY=0 -e FLUX_REST_TIMEOUT=2 -e FLUX_RESTART_MAX_ATTEMPTS=1; then
  wait_for "healthy for the first time" 30
  docker exec "${CONTAINER}" sh -c 'touch /tmp/stall'
  wait_for "starting the server (generation 2)" 90
  # The discriminating one is the second: before the fix the first strike after
  # the stall was `worldless 1/2 (rest=200 metrics=1 fps=-`. The first assertion
  # holds either way, because a wedged single-threaded API stops answering
  # outright on the samples after it, and is here only to pin the verdict's shape.
  check "a stall reads as no answer at all" yes "$(saw 'unresponsive 1/2 (rest=000')"
  check "and is never mistaken for a world unload" no "$(saw 'worldless')"
  check "so it is charged to the restart budget" yes "$(saw '(1/1 within 3600s)')"
  docker exec "${CONTAINER}" sh -c 'rm -f /tmp/stall'
  remove_container
fi

if [ "${failures}" -eq 0 ]; then
  echo "all entrypoint tests passed"
else
  echo "${failures} test(s) failed"
  exit 1
fi
