#!/bin/bash
# Shared helpers for the Flux additions to the Palworld server image.
#
# Sourced by flux-entrypoint.sh (PID 1), flux-guard.sh (the health probe) and
# flux-reboot.sh (the scheduled restart). Sourcing MUST have no side effect
# beyond defining functions and defaults: tests/test-flux.sh sources this file
# directly and drives the pure functions with table data.
#
# Nothing here depends on upstream's helper_functions.sh. That file authenticates
# against the REST API with the ADMIN_PASSWORD env var only, which is empty on
# every server we sell (see flux_admin_password below), and it is free to change
# shape between upstream releases. Our own recovery path must not inherit either
# problem.

# --- paths ------------------------------------------------------------------
# On Flux only /palworld/Pal/Saved is a persistent volume (the app spec mounts
# `g:/palworld/Pal/Saved`). Everything else in the image is the container's
# writable layer and is thrown away on a redeploy, so the guard's log lives under
# Saved, where it also shows up in the dashboard's file browser.
FLUX_SETTINGS_INI="${FLUX_SETTINGS_INI:-/palworld/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini}"
FLUX_SAVE_GLOB="${FLUX_SAVE_GLOB:-/palworld/Pal/Saved/SaveGames/0/*/Level.sav}"
FLUX_GUARD_LOG="${FLUX_GUARD_LOG:-/palworld/Pal/Saved/flux-guard.log}"
FLUX_GUARD_LOG_MAX_LINES="${FLUX_GUARD_LOG_MAX_LINES:-2000}"

# Written by flux-entrypoint.sh so the guard and the scheduled reboot can escalate
# to the process that keeps the container alive.
FLUX_INIT_PIDFILE="${FLUX_INIT_PIDFILE:-/tmp/flux-init.pid}"
FLUX_RESTART_MARKER="${FLUX_RESTART_MARKER:-/tmp/flux-restart-requested}"

FLUX_GAME_PROCESS="${FLUX_GAME_PROCESS:-PalServer-Linux-Shipping}"
# Overridable so the tests can feed the parsers a fixture instead of the kernel.
FLUX_PROC_UDP="${FLUX_PROC_UDP:-/proc/net/udp}"
FLUX_PROC_UDP6="${FLUX_PROC_UDP6:-/proc/net/udp6}"
FLUX_PROC_ROOT="${FLUX_PROC_ROOT:-/proc}"
FLUX_REST_TIMEOUT="${FLUX_REST_TIMEOUT:-10}"

# --- logging ----------------------------------------------------------------
flux_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# One line to stdout (so it lands in `docker logs` and in the dashboard console)
# and one to the persistent log, which is the only copy that survives the restart
# we are about to cause.
flux_log() {
  local line
  line="$(flux_now) [flux] $*"
  printf '%s\n' "$line"
  if [ -n "${FLUX_GUARD_LOG}" ]; then
    # The braces matter: a redirection that cannot be opened reports itself on
    # stderr before `|| true` gets a chance, and this runs every minute.
    { printf '%s\n' "$line" >>"${FLUX_GUARD_LOG}"; } 2>/dev/null || true
  fi
}

# Keeps the persistent log bounded. Called once per guard cycle; a rewrite only
# happens on the rare cycle where the file is actually over the limit.
flux_log_rotate() {
  local lines
  [ -f "${FLUX_GUARD_LOG}" ] || return 0
  lines=$(wc -l <"${FLUX_GUARD_LOG}" 2>/dev/null || echo 0)
  [ "${lines:-0}" -gt "${FLUX_GUARD_LOG_MAX_LINES}" ] || return 0
  if tail -n "$((FLUX_GUARD_LOG_MAX_LINES / 2))" "${FLUX_GUARD_LOG}" >"${FLUX_GUARD_LOG}.tmp" 2>/dev/null; then
    mv "${FLUX_GUARD_LOG}.tmp" "${FLUX_GUARD_LOG}" 2>/dev/null || rm -f "${FLUX_GUARD_LOG}.tmp"
  else
    rm -f "${FLUX_GUARD_LOG}.tmp"
  fi
}

# --- admin password ---------------------------------------------------------
# Upstream authenticates every container-side REST call (auto reboot, backup,
# graceful shutdown on `docker stop`) as admin:${ADMIN_PASSWORD} — the env var.
# We deploy with DISABLE_GENERATE_SETTINGS=true so that customer edits survive a
# reboot, which means the password the customer types lands in
# PalWorldSettings.ini and the env var stays empty: every one of those calls gets
# a 401 and fails silently. This is the fix in
# https://github.com/thijsvanloef/palworld-server-docker/pull/931 (open, ours);
# flux-entrypoint.sh also exports the result as ADMIN_PASSWORD before handing over
# to upstream's init.sh, so upstream's own code paths are fixed too, on whatever
# base image version we happen to be pinned to.
#
# Only the quoted form the server and compile-settings.sh write is matched.
# Commented lines are skipped and the last non-empty value wins, so a file that
# keeps an older or blank AdminPassword above the live one still resolves right.
flux_admin_password_from_ini() {
  local config_file="${1:-${FLUX_SETTINGS_INI}}"
  local pattern='AdminPassword[[:space:]]*=[[:space:]]*"([^"]*)"'
  local line password=""

  [ -r "${config_file}" ] || return 1

  while IFS= read -r line || [ -n "${line}" ]; do
    line="${line//$'\r'/}"
    [[ "${line}" =~ ^[[:space:]]*[\;#] ]] && continue
    if [[ "${line}" =~ ${pattern} ]] && [ -n "${BASH_REMATCH[1]}" ]; then
      password="${BASH_REMATCH[1]}"
    fi
  done <"${config_file}"

  [ -n "${password}" ] || return 1
  printf '%s' "${password}"
}

# ADMIN_PASSWORD wins when set, so this changes nothing for a setup that already
# works. Optional argument is the settings file, used by the tests.
# shellcheck disable=SC2120
flux_admin_password() {
  if [ -n "${ADMIN_PASSWORD:-}" ]; then
    printf '%s' "${ADMIN_PASSWORD}"
    return 0
  fi
  flux_admin_password_from_ini "$@"
}

# --- REST API ---------------------------------------------------------------
# Endpoints the game only accepts as POST, even when there is nothing to send.
# /v1/api/save is the one that matters here and it answers 404 to a GET, which reads
# exactly like "this server has no save endpoint" rather than "you used the wrong
# verb" — upstream carries the same list for the same reason.
flux_rest_is_post() {
  case "$1" in
    save|stop|shutdown|announce|kick|ban|unban) return 0 ;;
    *) return 1 ;;
  esac
}

# Sets FLUX_REST_BODY and FLUX_REST_CODE, and returns 0 only on a 200.
#
# It hands the body back in a global rather than printing it because the status
# code matters as much as the body: "nobody is listening" (000) and "our
# credentials are wrong" (401) are opposite verdicts, and a caller that had to
# reach for "$(flux_rest ...)" would run this in a subshell and lose the code.
flux_rest() {
  local path="$1" data="${2:-}" pw out code rc
  FLUX_REST_BODY=""
  FLUX_REST_CODE="000"
  # shellcheck disable=SC2119
  pw="$(flux_admin_password)" || pw=""
  if [ -n "${data}" ] || flux_rest_is_post "${path}"; then
    out=$(curl -sS -m "${FLUX_REST_TIMEOUT}" -u "admin:${pw}" -w $'\n%{http_code}' \
      -X POST --json "${data}" "http://127.0.0.1:${REST_API_PORT:-8212}/v1/api/${path}" 2>/dev/null)
    rc=$?
  else
    out=$(curl -sS -m "${FLUX_REST_TIMEOUT}" -u "admin:${pw}" -w $'\n%{http_code}' \
      -H 'Accept: application/json' "http://127.0.0.1:${REST_API_PORT:-8212}/v1/api/${path}" 2>/dev/null)
    rc=$?
  fi
  code="${out##*$'\n'}"
  [[ "${code}" =~ ^[0-9]{3}$ ]] || code="000"

  # A reply curl could not finish is not a reply, whatever status line came with
  # it. This is not theoretical: a server that sends its headers and then stops —
  # which is what a wedged game thread looks like from here — leaves curl exiting
  # 28 with %{http_code} already set to 200, and an empty body behind it. Read
  # literally that is "the API answered 200 and reported no world", so a stalled
  # server was diagnosed as a world unload: the wrong word in the log, the wrong
  # sentence announced to the players, and now the wrong side of the restart
  # budget, since a world unload is deliberately never charged to it. 000 is what
  # this actually is, and it is what every other kind of no-answer already reports.
  # An HTTP status curl delivered in full — 401, 404, 500 — still comes through:
  # those are answers, and curl exits 0 for all of them.
  if [ "${rc}" -ne 0 ]; then
    code="000"
    out=""
  fi
  # Both are read by the other scripts, which shellcheck cannot see from here.
  # shellcheck disable=SC2034
  FLUX_REST_CODE="${code}"
  # shellcheck disable=SC2034
  FLUX_REST_BODY="${out%$'\n'*}"
  [ "${code}" = "200" ]
}

# Numeric field out of a JSON body without pulling in jq. Prints nothing on
# anything it cannot turn into an integer, and the exit code says which kind of
# nothing it was:
#
#   0  the key was there and held an integer, which is printed
#   1  the key is not in the body at all
#   2  the key is there but the value is not a plain integer — null, nan, inf,
#      a bare fraction, scientific notation
#
# The three used to be two, and the difference matters. "zero fps", "no fps
# field" and "fps came back as nan" are three different statements about a
# server, and a caller that cannot tell the last two apart cannot describe the
# fault in a log line or in a bug report upstream. Callers that only care whether
# they got a number can keep ignoring the code; flux_classify does exactly that,
# on purpose, because both flavours of nothing mean the same thing to it.
flux_json_num() {
  local body="$1" key="$2" match
  match=$(printf '%s' "${body}" | grep -o "\"${key}\"[[:space:]]*:[[:space:]]*-\?[0-9][0-9]*" | head -1) || true
  if [ -z "${match}" ]; then
    printf '%s' "${body}" | grep -q "\"${key}\"[[:space:]]*:" && return 2
    return 1
  fi
  printf '%s' "${match##*[[:space:]:]}"
}

# --- system probes ----------------------------------------------------------
flux_game_pid() { pgrep -f "${FLUX_GAME_PROCESS}" 2>/dev/null | head -1; }

# Resident memory of the game process, in kB, straight out of /proc. Prints 0
# when there is no process to ask, which every caller reads as "no reading", not
# as "zero bytes".
#
# This is the signature the README has always described for both failure modes and
# the one thing the probe never actually measured. Mode B takes gigabytes with it:
# in all five crash dumps from 1785894699157 the process was down to 1.05 GB
# against a peak of 3.2 GB, which is to say the world had already unloaded before
# the segfault that produced the dump. The number costs one small read per minute.
# Parsed in the shell rather than with awk on purpose. flux_guard_wait calls this
# every few seconds rather than every minute, and a fork per glance is a poor way
# to pay for something advertised as free.
flux_game_rss_kb() {
  local pid="${1:-}"
  [ -n "${pid}" ] || pid="$(flux_game_pid)"
  [ -n "${pid}" ] || { printf '0'; return; }
  flux_proc_status_field "${pid}" VmRSS
}

# One field out of /proc/<pid>/status, by name and without the unit: VmRSS and
# VmHWM come back in kB, Threads as a count. Prints 0 for a field or a process
# that is not there, which every caller reads as "no reading" rather than "zero".
flux_proc_status_field() {
  local pid="$1" want="$2" key value
  [ -n "${pid}" ] || { printf '0'; return; }
  while read -r key value _; do
    if [ "${key}" = "${want}:" ]; then
      printf '%s' "${value}"
      return
    fi
  done 2>/dev/null <"${FLUX_PROC_ROOT}/${pid}/status"
  printf '0'
}

# How far resident memory has to fall below this generation's own peak before the
# fall means the world went away rather than the allocator breathing. A gigabyte
# is what the README observed and is far outside anything a loaded world does.
FLUX_GUARD_RSS_DROP_KB="${FLUX_GUARD_RSS_DROP_KB:-1048576}"
# ...and how big the peak must have been for the drop to be worth believing. A
# server whose world never occupied two gigabytes cannot lose one of them, and
# rather than guess about small worlds the signal simply switches itself off.
FLUX_GUARD_RSS_MIN_PEAK_KB="${FLUX_GUARD_RSS_MIN_PEAK_KB:-2097152}"

# Pure. True when this reading, against the highest one seen in this generation,
# is a collapse rather than normal movement. Setting FLUX_GUARD_RSS_DROP_KB=0
# turns the whole signal off.
#   $1 rss   current reading in kB, 0 when unknown
#   $2 peak  highest reading this generation, in kB
flux_rss_collapsed() {
  local rss="${1:-0}" peak="${2:-0}"
  [ "${FLUX_GUARD_RSS_DROP_KB}" -gt 0 ] || return 1
  [ "${rss}" -gt 0 ] || return 1
  [ "${peak}" -ge "${FLUX_GUARD_RSS_MIN_PEAK_KB}" ] || return 1
  [ "$((peak - rss))" -ge "${FLUX_GUARD_RSS_DROP_KB}" ]
}

# How often to glance at resident memory while waiting for the next full sample.
# 0 disables the early wake and leaves the guard on a plain fixed cadence.
FLUX_GUARD_RSS_POLL="${FLUX_GUARD_RSS_POLL:-5}"

# The gap between two full samples. Normally just a sleep.
#
# Resident memory is the only signal here that costs nothing to look at: a read
# from /proc, invisible to the game, where every REST call writes a line into the
# server's own console and is therefore rationed to one a minute. So during the
# wait it is glanced at every FLUX_GUARD_RSS_POLL seconds, and a collapse cuts the
# wait short. Detection stops being an average of half the sample interval and
# becomes a few seconds.
#
# It never decides anything. All it does is bring forward the full sample that
# was going to run at the end of the wait anyway, and that sample is judged by
# exactly the same rules it always was. Two things keep it honest, and both are
# the caller's to pass in:
#
#   - it is only ever armed when the guard currently believes the server is fine.
#     Inside a strike run the cadence is left alone, because three strikes has to
#     go on meaning three minutes rather than fifteen seconds.
#   - it is an edge, not a level. A collapse that the full sample then calls
#     healthy — memory really can be handed back for benign reasons — must not
#     wake us again five seconds later, and again, forever: that would be a REST
#     call every five seconds for the life of the generation. The caller disarms
#     on the wake and only re-arms when a sample sees memory back above the line.
#
# $1  1 when an early wake is armed, anything else to just wait
# $2  pid to watch, empty to look one up
# $3  highest resident memory seen this generation, in kB
# Returns 0 on a normal wait, 1 when it came back early.
flux_guard_wait() {
  local armed="$1" pid="$2" peak="$3" waited=0 step rss
  step="${FLUX_GUARD_RSS_POLL}"
  # Nothing to watch for: not armed, polling off or slower than the interval, the
  # signal switched off, or a generation whose world never grew big enough to lose
  # a gigabyte. Bail before the loop rather than inside it, so a server this can
  # never fire on does not pay a single extra read for it.
  if [ "${armed}" != "1" ] || [ "${step}" -le 0 ] 2>/dev/null || \
     [ "${step}" -ge "${FLUX_GUARD_INTERVAL}" ] || \
     [ "${FLUX_GUARD_RSS_DROP_KB}" -le 0 ] || \
     [ "${peak:-0}" -lt "${FLUX_GUARD_RSS_MIN_PEAK_KB}" ]; then
    sleep "${FLUX_GUARD_INTERVAL}"
    return 0
  fi

  while [ "${waited}" -lt "${FLUX_GUARD_INTERVAL}" ]; do
    [ $((waited + step)) -gt "${FLUX_GUARD_INTERVAL}" ] && step=$((FLUX_GUARD_INTERVAL - waited))
    sleep "${step}"
    waited=$((waited + step))
    rss="$(flux_game_rss_kb "${pid}")"
    if flux_rss_collapsed "${rss}" "${peak}"; then
      flux_log "resident memory fell to $((rss / 1024))M from this generation's peak of $((peak / 1024))M; sampling now rather than in $((FLUX_GUARD_INTERVAL - waited))s"
      return 1
    fi
  done
  return 0
}

# Bytes sitting unread in the receive queue of the game's UDP socket, straight
# out of /proc (no ss/netstat in the image). A healthy server drains this every
# tick and it reads a few KB at most; a frozen game thread lets it climb and
# stick, which is what "could not reach host" looks like from the outside while
# the process is still alive and the container still healthy.
flux_udp_rxq() {
  local port="${1:-${PORT:-8211}}" hex addr queues v max=0
  printf -v hex '%04X' "${port}"
  while read -r _ addr _ _ queues _; do
    [ "${addr##*:}" = "${hex}" ] || continue
    [[ "${queues}" =~ ^[0-9A-Fa-f]+:[0-9A-Fa-f]+$ ]] || continue
    v=$((16#${queues#*:}))
    [ "${v}" -gt "${max}" ] && max="${v}"
  done < <(cat "${FLUX_PROC_UDP:-/proc/net/udp}" "${FLUX_PROC_UDP6:-/proc/net/udp6}" 2>/dev/null)
  printf '%s' "${max}"
}

# How many crash dumps the game has left behind. Each SIGSEGV writes one directory
# under Saved/Crashes, which is on the persistent volume and therefore survives
# everything — so the count is a free record of how often this world has crashed,
# across container rebuilds and node moves alike. Logged once per generation; it
# is the only crash telemetry we have until the engine writes a Pal.log.
FLUX_CRASH_DIR="${FLUX_CRASH_DIR:-/palworld/Pal/Saved/Crashes}"
flux_crash_dump_count() {
  local n
  n=$(find "${FLUX_CRASH_DIR}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
  printf '%s' "${n:-0}"
}

# How many to keep. Nothing has ever deleted these: they land on the one directory
# that survives a redeploy, which is the customer's paid storage, and a world that
# crashes the way 1785894699157 does adds five a day forever. 0 disables pruning.
FLUX_CRASH_KEEP="${FLUX_CRASH_KEEP:-20}"

# Deletes all but the newest FLUX_CRASH_KEEP dumps. Called once per generation,
# where it costs one directory listing on a directory that holds tens of entries.
#
# Only ever touches directories named the way the engine names them, and only
# inside FLUX_CRASH_DIR. The newest are what anyone would look at; the count that
# came before the prune is logged, so what is lost is the dumps, not the record
# that this world has been crashing.
flux_prune_crash_dumps() {
  local keep="${FLUX_CRASH_KEEP}" removed=0 dir
  [ "${keep}" -gt 0 ] 2>/dev/null || return 0
  [ -n "${FLUX_CRASH_DIR}" ] && [ -d "${FLUX_CRASH_DIR}" ] || return 0

  while IFS= read -r dir; do
    [ -n "${dir}" ] || continue
    rm -rf -- "${dir}" 2>/dev/null && removed=$((removed + 1))
  done < <(find "${FLUX_CRASH_DIR}" -mindepth 1 -maxdepth 1 -type d -name 'crashinfo-*' \
    -printf '%T@\t%p\n' 2>/dev/null | sort -rn | tail -n "+$((keep + 1))" | cut -f2-)

  [ "${removed}" -gt 0 ] && flux_log "pruned ${removed} old crash dump(s) from ${FLUX_CRASH_DIR}, keeping the newest ${keep}"
  return 0
}

# --- capturing what the fault looked like ------------------------------------
# The guard convicts on a handful of numbers and then destroys the evidence: the
# process it is about to kill is the only copy of what went wrong. Twenty world
# unloads on 1785894699157 inside thirty-four hours produced no crash dump, not
# one engine line on stdout and nothing in the container log but our own verdict.
# "Why does this world unload every seventy minutes" has, today, no data behind it.
#
# So before the kill, once, everything that is cheap to read and gone a second
# later:
#
#   - the engine's own log. Only its [LOG] lines reach stdout; Saved/Logs is on
#     the persistent volume and holds the rest, including whatever it had to say
#     in the seconds before the world went away.
#   - the process's own high-water mark, which is the peak our once-a-minute
#     sampling can only approximate.
#   - the container's memory ceiling and its OOM counters. A world that unloads
#     with the cgroup against its limit is a sizing problem; one that unloads with
#     gigabytes to spare is a game bug. Nothing here can tell those apart today.
#   - how far the wall clock has drifted from the monotonic one. Every server we
#     run sets ALLOW_NEGATIVE_DELTA_TIME=true, which does not fix a clock that
#     steps backwards — it stops the engine asserting when it does, and leaves it
#     to carry on with whatever state that produced. If these nodes step their
#     clocks, this is where it shows up.
#   - what /v1/api/info still says: the one endpoint a worldless server keeps
#     answering properly.
#
# Best effort throughout. A reading that cannot be taken is reported as missing,
# and nothing here decides anything — the verdict was reached before it ran.
FLUX_GAME_LOG_DIR="${FLUX_GAME_LOG_DIR:-/palworld/Pal/Saved/Logs}"
FLUX_FAULT_LOG_LINES="${FLUX_FAULT_LOG_LINES:-40}"
FLUX_CGROUP_ROOT="${FLUX_CGROUP_ROOT:-/sys/fs/cgroup}"
FLUX_PROC_UPTIME="${FLUX_PROC_UPTIME:-/proc/uptime}"

# The newest *.log the engine has written, or nothing. UE names it after the
# project (Pal.log) and rotates the previous one to Pal-backup-<stamp>.log, so
# "newest" is the right answer rather than a fixed name.
flux_newest_game_log() {
  local newest
  [ -d "${FLUX_GAME_LOG_DIR}" ] || return 1
  newest="$(find "${FLUX_GAME_LOG_DIR}" -maxdepth 1 -type f -name '*.log' \
    -printf '%T@\t%p\n' 2>/dev/null | sort -rn | head -1 | cut -f2-)"
  [ -n "${newest}" ] || return 1
  printf '%s' "${newest}"
}

# Seconds since boot, integer, from /proc/uptime. It is the clock that cannot be
# stepped, which is the whole point of reading it.
flux_monotonic() {
  local up rest
  read -r up rest 2>/dev/null <"${FLUX_PROC_UPTIME}" || { printf '0'; return; }
  printf '%s' "${up%%.*}"
}

# Pure. How far the wall clock moved that the monotonic clock did not, between two
# samples. Zero on a machine whose clock only ticks; negative when the wall clock
# was stepped backwards, which is the case ALLOW_NEGATIVE_DELTA_TIME exists for.
#   $1 wall seconds elapsed   $2 monotonic seconds elapsed
flux_clock_skew() {
  printf '%s' "$(( ${1:-0} - ${2:-0} ))"
}

# What the whole container is allowed and how close it is to it, as one line, from
# cgroup v2 or v1 — whichever this kernel presents. Returns non-zero when neither
# is readable, which an unprivileged container is entitled to.
flux_cgroup_memory() {
  local root="${FLUX_CGROUP_ROOT}" current="" max="" oom=0 oom_kill=0 failcnt="" key value
  if [ -r "${root}/memory.current" ]; then
    current="$(cat "${root}/memory.current" 2>/dev/null)"
    max="$(cat "${root}/memory.max" 2>/dev/null)"
    if [ -r "${root}/memory.events" ]; then
      while read -r key value; do
        case "${key}" in
          oom) oom="${value}" ;;
          oom_kill) oom_kill="${value}" ;;
        esac
      done <"${root}/memory.events"
    fi
    printf 'current=%s max=%s oom=%s oom_kill=%s' \
      "$(flux_mib "${current}")" "$(flux_mib "${max}")" "${oom}" "${oom_kill}"
    return 0
  fi
  if [ -r "${root}/memory/memory.usage_in_bytes" ]; then
    current="$(cat "${root}/memory/memory.usage_in_bytes" 2>/dev/null)"
    max="$(cat "${root}/memory/memory.limit_in_bytes" 2>/dev/null)"
    # v1 has no oom_kill counter to read; failcnt counts the times an allocation
    # hit the limit, which answers the same question one step earlier.
    failcnt="$(cat "${root}/memory/memory.failcnt" 2>/dev/null)"
    printf 'current=%s max=%s failcnt=%s' \
      "$(flux_mib "${current}")" "$(flux_mib "${max}")" "${failcnt:-0}"
    return 0
  fi
  return 1
}

# Bytes as megabytes, and the two ways a cgroup says "no limit" as the word.
flux_mib() {
  local v="${1:-}"
  [[ "${v}" =~ ^[0-9]+$ ]] || { printf 'unlimited'; return; }
  # cgroup v1 writes its no-limit as PAGE_COUNTER_MAX * PAGE_SIZE, a number in the
  # exabytes. Anything past a petabyte is that, not a reading.
  [ "${v}" -gt 1125899906842624 ] && { printf 'unlimited'; return; }
  printf '%sM' "$((v / 1048576))"
}

# Everything above, into the log, at the moment of a conviction.
#   $1 verdict   what the guard decided, for the first line
#   $2 pid       the game process, from the sample that convicted it
#   $3 skew      cumulative clock skew this generation, in seconds (optional)
flux_capture_fault() {
  local verdict="$1" pid="${2:-}" skew="${3:-}" log line cg

  flux_log "capturing the state of this ${verdict} server before the restart destroys it"

  if [ -n "${pid}" ]; then
    flux_log "  process: pid=${pid} rss=$(($(flux_proc_status_field "${pid}" VmRSS) / 1024))M high-water=$(($(flux_proc_status_field "${pid}" VmHWM) / 1024))M virtual=$(($(flux_proc_status_field "${pid}" VmSize) / 1024))M threads=$(flux_proc_status_field "${pid}" Threads)"
  else
    flux_log "  process: gone before we could read it"
  fi

  if cg="$(flux_cgroup_memory)"; then
    flux_log "  container memory: ${cg}"
  else
    flux_log "  container memory: no cgroup accounting visible from in here"
  fi

  [ -n "${skew}" ] && flux_log "  clock: the wall clock has moved ${skew}s more than the monotonic one since this generation started (ALLOW_NEGATIVE_DELTA_TIME is on, so a backwards step is tolerated rather than fatal)"

  if flux_rest info; then
    flux_log "  /v1/api/info said: ${FLUX_REST_BODY:0:${FLUX_GUARD_BODY_CHARS:-240}}"
  else
    flux_log "  /v1/api/info answered HTTP ${FLUX_REST_CODE}"
  fi

  if log="$(flux_newest_game_log)"; then
    flux_log "  the last ${FLUX_FAULT_LOG_LINES} lines of ${log}:"
    while IFS= read -r line; do
      flux_log "  | ${line}"
    done < <(tail -n "${FLUX_FAULT_LOG_LINES}" "${log}" 2>/dev/null | tr -d '\r')
  else
    flux_log "  no engine log under ${FLUX_GAME_LOG_DIR}: this build writes nothing there, so its [LOG] lines on stdout are all there is"
  fi

  return 0
}

# --- the engine's own log ----------------------------------------------------
# The game writes nothing under Pal/Saved/Logs, which is why every capture so far
# has had a hole where its most useful line should be. It is not that the engine
# has no log to give: its own crash handler goes looking for exactly that file and
# fails, in the same breath, every time —
#
#   ERROR FILE_IO_POSIX.CC:145] open /palworld/Pal/Saved/Logs/Pal.log
#   ERROR CRASH_REPORT_EXCEPTION_HANDLER.CC:284] attachment /palworld/Pal/Saved/Logs/Pal.log
#
# UE writes it when the server is launched with -log, and upstream 2.7.3 has no way
# to add an argument: start.sh assembles STARTCOMMAND from a fixed list of env
# vars (PORT, QUERY_PORT, COMMUNITY, PALWORLD_ALLOW_NEGATIVE_DELTA_TIME, the
# threading pair, ENABLE_GAMEDATA_API) and stops. An EXTRA_ARGS upstream is the
# right home for this and is worth a PR, the way the admin password was; until
# then the argument goes on the game's own launcher shim.
#
# PalServer.sh is a five line wrapper around the binary and SteamCMD rewrites it on
# every install, so this is applied once per generation and is a no-op on the ones
# that already have it. Nothing is written to the persistent volume and nothing
# survives a redeploy. It only patches the single line that ends with the game's
# own argument list, so a launcher of any other shape is left exactly as it is —
# including the arm64 copy start.sh derives from it, which is built from this one.
#
# The one generation it cannot help is the first of a brand new container: the game
# is not on disk yet at that point, because init.sh is what installs it.
FLUX_ENGINE_LOG="${FLUX_ENGINE_LOG:-true}"

flux_enable_engine_log() {
  local launcher="${1:-${FLUX_GAME_LAUNCHER}}"
  [ "${FLUX_ENGINE_LOG,,}" = "true" ] || return 0
  [ -f "${launcher}" ] || return 0
  # Only on the launch line, and only as its own argument: a bare "-log" would also
  # be found inside something like --login, in a launcher we have never seen.
  if grep -q 'PalServer-Linux-Shipping.* -log\( \|$\)' "${launcher}" 2>/dev/null; then
    return 0
  fi
  if ! grep -q 'PalServer-Linux-Shipping' "${launcher}" 2>/dev/null; then
    flux_log "WARN ${launcher} does not look like the launcher we know; leaving it alone, so there will be no engine log"
    return 0
  fi
  if sed -i '/PalServer-Linux-Shipping/ s|\( Pal "\$@"\)$|\1 -log|' "${launcher}" 2>/dev/null &&
     grep -q 'PalServer-Linux-Shipping.* -log\( \|$\)' "${launcher}" 2>/dev/null; then
    flux_log "added -log to ${launcher}, so the engine writes ${FLUX_GAME_LOG_DIR}/Pal.log for this generation"
  else
    flux_log "WARN could not add -log to ${launcher}; the engine will go on writing no log"
  fi
  return 0
}

# UE renames the previous Pal.log out of the way on every launch, and this image
# starts a generation several times a day onto a volume the customer pays for. Same
# shape and same discipline as flux_prune_crash_dumps: newest kept, one glob, one
# directory, and the count said out loud. 0 keeps them all.
FLUX_ENGINE_LOG_KEEP="${FLUX_ENGINE_LOG_KEEP:-5}"

flux_prune_engine_logs() {
  local keep="${FLUX_ENGINE_LOG_KEEP}" removed=0 f
  [ "${keep}" -gt 0 ] 2>/dev/null || return 0
  [ -n "${FLUX_GAME_LOG_DIR}" ] && [ -d "${FLUX_GAME_LOG_DIR}" ] || return 0

  while IFS= read -r f; do
    [ -n "${f}" ] || continue
    rm -f -- "${f}" 2>/dev/null && removed=$((removed + 1))
  done < <(find "${FLUX_GAME_LOG_DIR}" -mindepth 1 -maxdepth 1 -type f -name 'Pal-backup-*.log' \
    -printf '%T@\t%p\n' 2>/dev/null | sort -rn | tail -n "+$((keep + 1))" | cut -f2-)

  [ "${removed}" -gt 0 ] && flux_log "pruned ${removed} old engine log(s) from ${FLUX_GAME_LOG_DIR}, keeping the newest ${keep}"
  return 0
}

# --- the crash dumps our own stop leaves behind ------------------------------
# /v1/api/stop does not exit cleanly. The game takes the request, shuts its REST
# API down and then aborts: signal 6, one crashinfo directory, every single time.
# Two dumps taken a day apart carry the same PCallStackHash and differ only in
# where ASLR put libc, and their SecondsSinceStart lands on the second we asked.
#
# That matters because of what it buries. Before this image asked politely, a dump
# on the volume meant the game had crashed; the old SIGKILL could not be caught and
# left none. Now a server restarting ten times a day writes ten, and
# flux_prune_crash_dumps keeps the newest twenty — so a real crash dump, the kind
# worth reading, would be gone inside two days.
#
# So the ones we caused are removed, and only those: a dump is ours when it was
# written after the moment we asked the server to stop, which is the mtime of the
# restart marker. PID 1 does it, after the generation has ended — the guard cannot,
# because the sweep kills it while the dump is still being written. What went is
# named in the log, so the record outlives the directory.
#
# $1 the epoch second we asked; 0 or empty when this restart was not ours to blame
FLUX_CRASH_DROP_OWN="${FLUX_CRASH_DROP_OWN:-true}"

flux_drop_stop_crash_dumps() {
  local requested_at="${1:-0}" removed=0 stamp dir
  [ "${FLUX_CRASH_DROP_OWN,,}" = "true" ] || return 0
  [ "${requested_at}" -gt 0 ] 2>/dev/null || return 0
  [ -n "${FLUX_CRASH_DIR}" ] && [ -d "${FLUX_CRASH_DIR}" ] || return 0

  while IFS="$(printf '\t')" read -r stamp dir; do
    [ -n "${dir}" ] || continue
    [ "${stamp%%.*}" -ge "${requested_at}" ] 2>/dev/null || continue
    if rm -rf -- "${dir}" 2>/dev/null; then
      removed=$((removed + 1))
      flux_log "removed $(basename "${dir}"): written while we were stopping the server, so it is the abort our own /v1/api/stop causes and not a crash of this world"
    fi
  done < <(find "${FLUX_CRASH_DIR}" -mindepth 1 -maxdepth 1 -type d -name 'crashinfo-*' \
    -printf '%T@\t%p\n' 2>/dev/null)

  return 0
}

# --- boot phase -------------------------------------------------------------
# What a customer is waiting for, in four words, from the moment the container
# starts until players can join.
#
# It exists because the dashboard has no other honest answer during a boot. A
# container that is still pulling 5.15 GB through SteamCMD is up, its domain
# resolves, and the app is registered — every signal the website reads says
# "running" while nobody can play for nine minutes.
#
# The website could read this off upstream's own log lines instead, and must not:
# "****Starting Installation****" and "(0x61) downloading, progress:" belong to
# another project and are free to change shape on any release. This is our
# contract, in our log, in the same one-line-per-change shape as everything else
# here — parse `[flux] phase=<name>` and nothing else. Percentages, if the UI
# wants them, can come from upstream's progress lines as a best-effort extra that
# degrades to nothing without taking the phase down with it.
#
# The phases, in order:
#   installing  the game is not on disk yet (a fresh container, every time — only
#               Pal/Saved is persistent, so this is the nine minute case)
#   starting    files are there, the server process has not been launched yet
#   loading     the process is up and reading the world into memory
#   ready       announced separately, by the guard's "server healthy for the
#               first time this boot" line, because the guard is what knows
#
# Pure, and for the same reason flux_classify is: the tests drive the table.
#   $1 installed   1 when the game files and the appmanifest are both on disk
#   $2 pid_present 1 when a game process exists
flux_boot_phase() {
  local installed="$1" pid_present="$2"
  [ "${installed}" = "1" ]   || { printf 'installing'; return; }
  [ "${pid_present}" = "1" ] || { printf 'starting';   return; }
  printf 'loading'
}

# The same two files upstream's own IsInstalled() checks, so we agree with it
# about what "installed" means and cannot report ready on a half-finished pull.
FLUX_GAME_LAUNCHER="${FLUX_GAME_LAUNCHER:-/palworld/PalServer.sh}"
FLUX_GAME_MANIFEST="${FLUX_GAME_MANIFEST:-/palworld/steamapps/appmanifest_2394010.acf}"
flux_game_installed() {
  [ -e "${FLUX_GAME_LAUNCHER}" ] && [ -e "${FLUX_GAME_MANIFEST}" ]
}

# 1 when at least one world save exists on disk, 0 otherwise.
flux_save_present() {
  local f
  for f in ${FLUX_SAVE_GLOB}; do
    [ -f "${f}" ] && { printf '1'; return 0; }
  done
  printf '0'
}

# --- classification ---------------------------------------------------------
# The verdict for ONE sample. Pure by construction: every input is an argument
# and nothing is read from the system, so the whole decision table is unit
# tested in tests/test-flux.sh.
#
#   $1 auth_ok      0 = the REST API rejected our credentials, so no REST-derived
#                       signal can be trusted and only the socket and the save
#                       file are allowed to convict
#   $2 info_ok      1 = /v1/api/info answered 200
#   $3 metrics_ok   1 = /v1/api/metrics answered 200
#   $4 fps          serverfps from metrics; empty means the server answered but
#                       would not give us a number, which is a fault, not an
#                       unknown — see the rule below
#   $5 uptime       uptime from metrics, empty when unknown
#   $6 prev_uptime  the previous sample's uptime, empty when unknown
#   $7 rxq          bytes queued on the game's UDP socket
#   $8 rxq_limit    threshold for the queue
#   $9 save_present 1/0, from flux_save_present
#  $10 rss_dropped  1 when resident memory has collapsed from this generation's
#                       peak, from flux_rss_collapsed. Optional; absent reads as 0
#
# Prints one of: ok | stalled | unresponsive | worldless
flux_classify() {
  local auth_ok="$1" info_ok="$2" metrics_ok="$3" fps="$4" uptime="$5" \
    prev_uptime="$6" rxq="$7" rxq_limit="$8" save_present="$9" \
    rss_dropped="${10:-0}"

  # Mode A, the socket half. Checked first and without auth: it is the one signal
  # that is true even when the REST API is answering happily.
  if [ "${rxq:-0}" -ge "${rxq_limit}" ]; then
    printf 'stalled'
    return
  fi

  # A save that was there and is not there any more. No auth needed either.
  if [ "${save_present}" = "0" ]; then
    printf 'worldless'
    return
  fi

  # Mode B seen from outside the REST API, and the only rule that can see it at
  # all when our credentials are refused. A 401 blinds every rule below it, and
  # the two rules above are no help: in mode B the process is up, the socket is
  # drained and the save file is still on disk, so a server whose world has gone
  # reads as perfectly healthy for as long as the password stays wrong.
  #
  # Deliberately gated on the credentials rather than applied everywhere: when the
  # API does answer it says more about the world than memory ever can, and a
  # server reporting fps above zero has no business being convicted by its
  # allocator. This is the hole, and only the hole.
  if [ "${auth_ok}" != "1" ] && [ "${rss_dropped}" = "1" ]; then
    printf 'worldless'
    return
  fi

  # Everything below reads the REST API. With broken credentials a 401 looks
  # exactly like a dead server, so we refuse to convict on it.
  if [ "${auth_ok}" != "1" ]; then
    printf 'ok'
    return
  fi

  # Mode A, the REST half: the whole API stopped answering.
  if [ "${info_ok}" != "1" ]; then
    printf 'unresponsive'
    return
  fi

  # Mode B: the process is up and the API answers, but there is no world behind
  # it. Any one of these is enough — a healthy server always serves metrics, runs
  # above 0 fps, and never restarts its own uptime counter.
  if [ "${metrics_ok}" != "1" ]; then
    printf 'worldless'
    return
  fi

  # No usable serverfps behind a 200 is the same verdict as zero fps, and it is
  # the one that matters most: it is the shape this failure actually takes.
  #
  # Read seven servers' logs and the world-unloaded state always looks the same —
  # metrics answers 200, uptime restarts from near zero, and serverfps stops
  # coming back as a number. Requiring a parseable fps here (the old
  # `[ -n "${fps}" ] && ...`) meant the signature of the fault was the very thing
  # that skipped the rule written to catch it, so the verdict stayed 'ok' for as
  # long as the fault lasted: 79 of 176 observed server-hours across that sample,
  # once for 19h37m straight.
  #
  # This is a level, not an edge. It holds for every sample until the server is
  # restarted, so it accumulates strikes and convicts, which is what the rule
  # below cannot do. Convicting here is safe because a server that is merely
  # starting up answers 000 rather than a 200 with no fps in it, and because
  # nothing is convicted before FLUX_GUARD_MIN_UPTIME and a first healthy sample.
  if [ -z "${fps}" ] || [ "${fps}" -eq 0 ]; then
    printf 'worldless'
    return
  fi

  # An edge, and deliberately kept as one: the counter drops once and then climbs
  # again from its new base, so this can only ever fire on a single sample and can
  # never reach FLUX_GUARD_FAILURES on its own. It earns its place twice over —
  # it names the moment the world went away in the log, and together with a
  # missing serverfps it is what flux_worldless_is_proven acts on immediately.
  if [ -n "${uptime}" ] && [ -n "${prev_uptime}" ] && [ "${uptime}" -lt "${prev_uptime}" ]; then
    printf 'worldless'
    return
  fi

  printf 'ok'
}

# Pure. True when a single sample is already proof that the world is gone, rather
# than evidence that wants confirming.
#
# The distinction buys back three minutes of a five minute recovery. Waiting for
# three strikes and then warning the players for another minute is right for a
# server that might be having a bad moment; it is dead weight for one that has
# demonstrably lost its world, and the log from 1785894699157 shows the cost. Over
# 41 hours that world died 28 times and came back to a player within one to two
# minutes on five of them — each time only because the process had also crashed
# and skipped our slow path. On the sixth (10:15:47) the player reconnected 1m57s
# after the world went, and the patient path would still have been counting.
#
# Nothing here can be true of a working server:
#   $1 verdict      from flux_classify; anything but worldless is never proof
#   $2 fps          a loaded world always answers with a usable serverfps
#   $3 uptime       )  the server's own counter, which only a new world restarts
#   $4 prev_uptime  )
#   $5 rss_dropped  the gigabytes the world occupied have gone back to the kernel
#   $6 auth_ok      whether the REST API is talking to us at all
flux_worldless_is_proven() {
  local verdict="$1" fps="$2" uptime="$3" prev_uptime="$4" rss_dropped="${5:-0}" \
    auth_ok="${6:-1}"

  [ "${verdict}" = "worldless" ] || return 1

  # Acting on one sample is only safe while the server is still answering us.
  # Behind a 401 the memory reading is the single thing we have and there is
  # nothing to cross-check it against, so it is allowed to convict — that is the
  # hole it was added to close — but only the patient way, with three samples and
  # a countdown. Three minutes is nothing against a server that has been
  # unreachable for as long as its password has been wrong.
  [ "${auth_ok}" = "1" ] || return 1

  # Everything below describes a server that will not give us a working serverfps.
  # On its own that is not proof — one unlucky sample can lose the field — which
  # is exactly why it has to be joined by one of the two signals after it.
  { [ -z "${fps}" ] || [ "${fps}" -eq 0 ]; } || return 1

  # Proof one: the uptime counter restarted. A server does not un-age. The only
  # thing that resets it is a world that is not the world we were watching, and
  # the same PID in the evidence line says nobody restarted the process for us.
  if [ -n "${uptime}" ] && [ -n "${prev_uptime}" ] && [ "${uptime}" -lt "${prev_uptime}" ]; then
    return 0
  fi

  # Proof two: the memory the world lived in went back to the kernel. Slower to
  # arm than the uptime edge (it needs a peak to compare against) but it is a
  # level rather than an edge, so it still holds on the samples after the one
  # where the counter jumped — which is what covers a sample lost to a timeout.
  [ "${rss_dropped}" = "1" ]
}

# "once" / "3 times", so a log line about a single sample reads like English.
flux_times() {
  if [ "${1:-}" = "1" ]; then printf 'once'; else printf '%s times' "${1:-0}"; fi
}

# --- seeding a brand new server's settings file ----------------------------
# A fresh Palworld server ends up with an EMPTY PalWorldSettings.ini. Upstream's
# start.sh copies the game's DefaultPalWorldSettings.ini into place, but that file
# is a sample in which every value equals the game's default, so the engine writes
# it straight back out as nothing. What is left is a one-byte file, and from then
# on: REST is off, so the scheduled restart cannot authenticate, the health probe
# can never see the server working, and the dashboard's own reconcile refuses to
# touch a file with no OptionSettings line to patch. Nothing recovers on its own.
#
# So the server is given a settings file before the game ever starts, holding the
# three values a server we run needs and the game's sample does not provide. They
# are all non-default, which is also what makes the file survive: the engine keeps
# what differs from its defaults.
#
# Only ever written when there is no OptionSettings line to lose — a populated file
# belongs to the customer and is never touched here. The game's own sample is
# preferred as the base whenever it exists (it does from the second boot onward,
# and it carries whatever settings the current game version added); the copy baked
# into this image is the fallback for the very first boot, before the install has
# put the game's own file on disk.
FLUX_DEFAULT_INI="${FLUX_DEFAULT_INI:-/home/steam/server/PalWorldSettings.default.ini}"
FLUX_GAME_DEFAULT_INI="${FLUX_GAME_DEFAULT_INI:-/palworld/DefaultPalWorldSettings.ini}"
FLUX_SEED_AUTOSAVE_SPAN="${FLUX_SEED_AUTOSAVE_SPAN:-60.000000}"

# 24 characters, no look-alikes, from the kernel. Matches what the dashboard
# generates, so a password seeded here and one seeded there are indistinguishable.
flux_generate_password() {
  LC_ALL=C tr -dc 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789' </dev/urandom | head -c 24
}

# True when the file holds a settings line worth keeping.
flux_ini_is_populated() {
  [ -s "$1" ] && grep -q 'OptionSettings=(' "$1" 2>/dev/null
}

# Sets one key inside the single OptionSettings=(...) line, replacing it in place
# when it is already there and inserting it at the front when it is not. Values are
# matched up to the next , or ) so a key that is present but malformed is still
# recognised as present — matching narrowly would insert a duplicate.
flux_ini_set() {
  local ini="$1" key="$2" value="$3"
  if printf '%s' "${ini}" | grep -q "${key}=[^,)]*"; then
    printf '%s' "${ini}" | sed "s/${key}=[^,)]*/${key}=${value}/"
  else
    printf '%s' "${ini}" | sed "s/OptionSettings=(/OptionSettings=(${key}=${value},/"
  fi
}

# The settings file a server we run should start life with. Reads a base ini on
# stdin, prints the seeded one.
flux_ini_seed() {
  local ini password
  ini="$(cat)"
  password="$(flux_generate_password)"
  ini="$(flux_ini_set "${ini}" RESTAPIEnabled True)"
  ini="$(flux_ini_set "${ini}" AutoSaveSpan "${FLUX_SEED_AUTOSAVE_SPAN}")"
  flux_ini_set "${ini}" AdminPassword "\"${password}\""
}

# Writes it, once, for a server that has none. Never returns non-zero: a server
# that cannot be seeded still boots, it just boots the way it used to.
flux_seed_ini_if_missing() {
  local dir base tmp
  dir="$(dirname "${FLUX_SETTINGS_INI}")"

  if flux_ini_is_populated "${FLUX_SETTINGS_INI}"; then
    return 0
  fi

  if [ -r "${FLUX_GAME_DEFAULT_INI}" ]; then
    base="${FLUX_GAME_DEFAULT_INI}"
  elif [ -r "${FLUX_DEFAULT_INI}" ]; then
    base="${FLUX_DEFAULT_INI}"
  else
    flux_log "WARN no settings file and no template to build one from; the server will boot with the game's defaults and no REST API"
    return 0
  fi

  mkdir -p "${dir}" 2>/dev/null
  tmp="${FLUX_SETTINGS_INI}.flux-seed"
  if flux_ini_seed <"${base}" >"${tmp}" 2>/dev/null && [ -s "${tmp}" ] && mv "${tmp}" "${FLUX_SETTINGS_INI}" 2>/dev/null; then
    chown "${PUID:-1000}:${PGID:-1000}" "${FLUX_SETTINGS_INI}" 2>/dev/null
    flux_log "no server settings found: wrote a fresh PalWorldSettings.ini from $(basename "${base}") with the REST API on, a random admin password, and a ${FLUX_SEED_AUTOSAVE_SPAN%%.*}s autosave"
  else
    rm -f "${tmp}" 2>/dev/null
    flux_log "WARN could not write ${FLUX_SETTINGS_INI}; the server will boot with the game's defaults and no REST API"
  fi
  return 0
}

# --- warning the players ---------------------------------------------------
# Best effort by design. In most of the states that get us here there is nobody
# left to warn: mode B has already dropped every player, and a stalled or
# unresponsive server cannot be asked to announce anything. It costs one REST
# call to try, and on the occasions it does land the players learn why their
# server went away, so failures are ignored rather than reported.
flux_announce() {
  flux_rest announce "{\"message\":\"$1\"}" >/dev/null 2>&1 || true
}

# Counts down to a restart, announcing in-game at 30 and 10 seconds left.
# $1 seconds, $2 the sentence that explains why.
flux_restart_countdown() {
  local remaining="$1" why="$2" next mark
  [ "${remaining}" -gt 0 ] 2>/dev/null || return 0
  flux_announce "${why} Restarting in ${remaining} seconds."
  while [ "${remaining}" -gt 0 ]; do
    next=0
    for mark in 30 10; do
      if [ "${remaining}" -gt "${mark}" ]; then next="${mark}"; break; fi
    done
    sleep "$((remaining - next))"
    remaining="${next}"
    [ "${remaining}" -gt 0 ] && flux_announce "Restarting in ${remaining} seconds."
  done
}

# --- forcing the server down -------------------------------------------------
# Killing the game is what ends a generation: upstream's start.sh runs PalServer
# in the foreground, so its exit walks init.sh out and hands control back to the
# supervisor in flux-entrypoint.sh, which starts a fresh server in place (or ends
# the container, under FLUX_RESTART_MODE=container).
#
# We never ask it to save first, and we are never polite for long. In every state
# that gets us here the in-memory world is already gone or frozen, and telling a
# broken server to save risks writing that emptiness over the customer's last good
# save. What ending it costs is the interval since the last autosave, which was
# lost the moment the fault happened.
#
# But it is asked to stop before it is killed, and that is not politeness for its
# own sake. A server started with -publiclobby registers itself with Pocketpair's
# community list on every boot, and a SIGKILL never tells the list it is leaving:
# the entry is orphaned there until it times out, the next generation registers a
# second one beside it, and each one also lands in the Recent Servers list of
# every client that ever joined — where nothing on this side can ever remove it.
# Twenty in-place restarts a day is twenty of those. /v1/api/stop is the game's
# own forced stop and, unlike /v1/api/shutdown, it is documented to write nothing.
#
# "Documented" is not "observed", and this path may never write:
# FLUX_FORCE_STOP_WAIT=0 turns the whole attempt off and goes back to killing the
# process outright, and the save on disk is stamped before and after so that a
# stop that does write is caught the first time it happens rather than the first
# time a customer notices. The wait is short by design — the deadline in
# flux-entrypoint.sh is sixty seconds, and everything here has to fit inside it
# with room for the sweep.
#
# Enforcing that deadline is flux-entrypoint.sh's job, not ours: it runs as root
# and can always end the generation, while the scheduled reboot runs from cron as
# the steam user and cannot signal init.
#
# $1 reason, recorded for the log and for flux-entrypoint.sh's exit code.
FLUX_FORCE_STOP_WAIT="${FLUX_FORCE_STOP_WAIT:-8}"

flux_force_restart() {
  local reason="$1" pid code waited save_before=""
  flux_log "RESTART requested: ${reason}"
  printf '%s\n' "${reason}" >"${FLUX_RESTART_MARKER}" 2>/dev/null || true

  pid="$(flux_game_pid)"
  if [ -z "${pid}" ]; then
    flux_log "no ${FLUX_GAME_PROCESS} process found; this generation is already on its way out"
    return 0
  fi

  if [ "${FLUX_FORCE_STOP_WAIT:-0}" -gt 0 ] 2>/dev/null; then
    save_before="$(flux_save_stamp)" || save_before=""
    flux_rest stop >/dev/null 2>&1
    code="${FLUX_REST_CODE}"
    # 000 is not a refusal here. A server that takes the request and goes down
    # before it finishes answering leaves curl with nothing to read, which is
    # exactly what a working stop looks like from this side.
    case "${code}" in
      200|000)
        if waited="$(flux_wait_for_exit "${pid}" "${FLUX_FORCE_STOP_WAIT}")"; then
          flux_log "asked the server to stop (HTTP ${code}) and it went down on its own after ${waited}s, so its community-list entry leaves with it"
          flux_warn_if_save_changed "${save_before}"
          return 0
        fi
        flux_log "asked the server to stop (HTTP ${code}) but it was still up ${waited}s later"
        ;;
      *)
        flux_log "the server would not take a stop request (HTTP ${code})"
        ;;
    esac
    flux_warn_if_save_changed "${save_before}"
  fi

  flux_log "sending SIGKILL to ${FLUX_GAME_PROCESS} (pid ${pid})"
  kill -KILL "${pid}" 2>/dev/null || flux_log "WARN could not signal pid ${pid} (running as $(id -un))"
}

# Waits up to $2 seconds for pid $1 to leave. Prints the seconds waited either
# way; returns 0 only if it went. /proc rather than `kill -0`, which cannot tell
# a process that has exited from one this user may not signal.
flux_wait_for_exit() {
  local pid="$1" seconds="${2:-0}" waited=0
  while :; do
    if [ ! -d "${FLUX_PROC_ROOT}/${pid}" ]; then
      printf '%s' "${waited}"
      return 0
    fi
    [ "${waited}" -lt "${seconds}" ] || break
    sleep 1
    waited=$((waited + 1))
  done
  printf '%s' "${waited}"
  return 1
}

# mtime and size of the newest save on disk, as one opaque string. It is only ever
# compared against itself, and it exists for one reason: so that a shutdown path
# which is supposed to write nothing can be caught writing something.
flux_save_stamp() {
  local f newest=""
  for f in ${FLUX_SAVE_GLOB}; do
    [ -f "${f}" ] || continue
    if [ -z "${newest}" ] || [ "${f}" -nt "${newest}" ]; then
      newest="${f}"
    fi
  done
  [ -n "${newest}" ] || return 1
  stat -c '%Y %s' "${newest}" 2>/dev/null
}

# The alarm for the paragraph above. Loud on purpose and names its own off switch:
# a world that has already unloaded must never be the thing that gets written.
flux_warn_if_save_changed() {
  local before="${1:-}" after
  [ -n "${before}" ] || return 0
  after="$(flux_save_stamp)" || return 0
  [ "${after}" != "${before}" ] || return 0
  flux_log "WARN the save on disk changed while the server was being stopped (${before} -> ${after}). /v1/api/stop is writing, which it must not do on a world that may already be gone — set FLUX_FORCE_STOP_WAIT=0 to go back to killing the process outright."
}

# --- what a restart says about the container ---------------------------------
# Pure. True when this restart is evidence that something here is wrong in a way
# a fresh container might fix, and so is allowed to count against
# FLUX_RESTART_MAX_ATTEMPTS and eventually end the container.
#
# Not every restart is that. Ending the container costs a full SteamCMD install —
# nine minutes and eight seconds on 1785894699157, measured — and hands the app to
# the platform's 30 second masterSlaveApps loop on the way back. That price is
# worth paying for a server that cannot stay up, because a rebuild moves it to
# clean disk and possibly a different node. It buys nothing at all against a bug
# in the game that only reproduces on this customer's save: the world would unload
# on the new container too, and we would have traded a 90 second restart for a
# nine minute one. That same log reached 3 of 5 in an hour twice; a world dying
# every 27 minutes while idle gets to 5 without trying.
#
# So the budget is spent only on the failures a rebuild has any claim on:
#
#   worldless          the in-place restart IS the fix, and it worked 28/28 times.
#                      A worldless server that does not come back is caught by the
#                      guard's own "not been healthy once since boot" hold, which
#                      never convicts and so never restarts anything.
#   scheduled restart  not a failure at all. Charging the nightly reboot one of
#                      five was always wrong.
#   everything else    the leak, a dead REST API, a server exiting on its own —
#                      counted, exactly as before.
#
# $1 the reason string flux-entrypoint.sh is about to log.
flux_restart_counts_against_budget() {
  case "$1" in
    worldless*)           return 1 ;;
    "scheduled restart"*) return 1 ;;
    *)                    return 0 ;;
  esac
}
