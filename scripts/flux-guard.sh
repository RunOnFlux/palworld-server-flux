#!/bin/bash
# The in-container health probe.
#
# Palworld has two ways of going down that leave the container, the process and
# every health signal the platform can see in perfect shape (documented at length
# in the README):
#
#   A. the game stops draining its own UDP socket and/or its REST API stops
#      answering, after hours of the memory leak. Process alive, nobody can join.
#   B. the world unloads: same PID, resident memory drops by over a gigabyte, the
#      server's uptime counter restarts from zero, metrics report no world. The
#      port still accepts connections, so players get in and hit a black screen,
#      and the dashboard keeps saying Online.
#
# Neither recovers on its own and only a restart clears them. This loop samples
# the server once a minute, needs the same verdict FLUX_GUARD_FAILURES times in a
# row before it believes it — unless the sample already proves the world is gone,
# which costs a restart nothing to act on immediately (flux_worldless_is_proven) —
# and then kills the game process. What happens next is
# flux-entrypoint.sh's call, not ours: under the default FLUX_RESTART_MODE=process
# it sweeps the generation and starts a fresh one inside the same container, in
# about thirty seconds and without re-downloading anything. The container only
# ends once that has been tried FLUX_RESTART_MAX_ATTEMPTS times in an hour, or
# under FLUX_RESTART_MODE=container.
#
# Started in the background by flux-entrypoint.sh. Also usable as a one-shot:
#   flux-guard.sh --check   prints the verdict, exits 0 when healthy

set -uo pipefail
# shellcheck source=scripts/flux-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/flux-lib.sh"

FLUX_GUARD_ENABLED="${FLUX_GUARD_ENABLED:-true}"
FLUX_GUARD_INTERVAL="${FLUX_GUARD_INTERVAL:-60}"
# Consecutive bad samples before acting. Three at sixty seconds means a real
# fault costs three minutes and a one-off hitch costs nothing.
FLUX_GUARD_FAILURES="${FLUX_GUARD_FAILURES:-3}"
# A normal server's UDP receive queue reads a few KB at its busiest; the frozen
# ones we have on record sat at 90-110 KB and never came down.
FLUX_GUARD_RXQ_BYTES="${FLUX_GUARD_RXQ_BYTES:-65536}"
# Nothing is convicted before the server has been seen healthy once since boot,
# and never in the first FLUX_GUARD_MIN_UPTIME seconds. Loading a large world
# takes minutes, and a server that comes up broken is not made better by being
# restarted in a loop.
FLUX_GUARD_MIN_UPTIME="${FLUX_GUARD_MIN_UPTIME:-300}"
# Log the verdict but never act. Use it to watch a fleet before arming it.
FLUX_GUARD_DRY_RUN="${FLUX_GUARD_DRY_RUN:-false}"
# Grace between deciding and acting, announced in-game. Costs a minute of downtime
# on a server that is already down, and buys two things: anyone still connected
# gets told why, and a server that recovers inside the window is left alone.
FLUX_GUARD_RESTART_DELAY="${FLUX_GUARD_RESTART_DELAY:-60}"
# How much of the metrics body to keep for the log line on a bad sample. Enough
# for the whole document a healthy server sends; short enough not to matter.
FLUX_GUARD_BODY_CHARS="${FLUX_GUARD_BODY_CHARS:-240}"
# Seconds of disagreement between the wall clock and the monotonic one, from one
# sample to the next, before it is called a step and logged. Two seconds is well
# clear of NTP slewing and of this loop's own jitter. 0 stops looking.
FLUX_GUARD_CLOCK_SKEW="${FLUX_GUARD_CLOCK_SKEW:-2}"

started_at="$(date -u +%s)"
prev_uptime=""
save_seen_once=0
seen_healthy=0
auth_ok=1
auth_warned_at=0
# The highest resident memory this generation has reached. Carried between
# samples for the same reason prev_uptime is: the fault is a fall from it, and a
# single reading cannot show a fall.
rss_peak=0
GUARD_VERDICT="ok"
GUARD_EVIDENCE=""
GUARD_BODY=""
GUARD_PROVEN=0
GUARD_PID=""
GUARD_RSS_DROPPED=0
# The early wake in flux_guard_wait is an edge: it fires once per collapse and
# stays down until a full sample sees memory back above the line. Without that, a
# fall the sample then calls healthy would wake us every few seconds forever.
rss_wake_armed=1
# The wall clock and the monotonic clock, as of the last sample, and how far apart
# they have drifted since the first one. Every server we run sets
# ALLOW_NEGATIVE_DELTA_TIME=true, which does not stop a host stepping its clock —
# it stops the engine treating the step as fatal and leaves it running on whatever
# state that produced. Nobody has ever looked at whether these nodes actually do
# it, and two file reads a minute is what looking costs.
wall_prev=""
mono_prev=""
wall_start=""
mono_start=""
clock_steps=0
declare -A streak=([stalled]=0 [unresponsive]=0 [worldless]=0)

# Collects one sample. Sets GUARD_VERDICT and GUARD_EVIDENCE, and updates the
# state carried between samples (prev_uptime, auth_ok, save_seen_once). It must
# NOT be called in a command substitution: a subshell would throw that state away
# every cycle, and the guard would lose the one signal — a uptime counter that
# went backwards — that can only be seen by comparing two samples.
flux_guard_sample() {
  local metrics info_ok=0 metrics_ok=0 fps="" uptime="" players="" rxq save_present code now
  local fps_rc=0 pid rss rss_dropped=0

  # Metrics first, and on a healthy server that is the only call made. The game
  # writes a line to its own console for REST activity, and this loop runs for
  # the life of the server: one request a minute is a cost worth paying, two is
  # not. /v1/api/info is only asked for when metrics already failed, to tell an
  # API that is gone (mode A) from an API that is answering with no world behind
  # it (mode B).
  flux_rest metrics && metrics_ok=1
  metrics="${FLUX_REST_BODY}"
  code="${FLUX_REST_CODE}"
  if [ "${metrics_ok}" = "1" ]; then
    info_ok=1
    fps="$(flux_json_num "${metrics}" serverfps)" || fps_rc=$?
    [ "${fps_rc}" = "0" ] || fps=""
    uptime="$(flux_json_num "${metrics}" uptime)" || uptime=""
    # Free: it rides along in the body we already asked for, and it is the field
    # that turns "the world died" into "the world died and nobody was on it".
    players="$(flux_json_num "${metrics}" currentplayernum)" || players=""
  elif [ "${code}" != "401" ] && [ "${code}" != "403" ]; then
    flux_rest info && info_ok=1
    code="${FLUX_REST_CODE}"
  fi

  # A 401 is not a sick server, it is our own credentials. It happens on a server
  # whose ini has no AdminPassword at all, and it must never be read as a fault:
  # convicting on it would restart a perfectly healthy world every few minutes.
  if [ "${code}" = "401" ] || [ "${code}" = "403" ]; then
    auth_ok=0
    now="$(date -u +%s)"
    if [ $((now - auth_warned_at)) -ge 3600 ]; then
      auth_warned_at="${now}"
      flux_log "WARN REST API returned ${code}: no usable admin password (checked ADMIN_PASSWORD and ${FLUX_SETTINGS_INI}). Socket and save-file checks stay active; REST checks are disabled until this is fixed."
    fi
  else
    auth_ok=1
  fi

  rxq="$(flux_udp_rxq "${PORT:-8211}")"
  save_present="$(flux_save_present)"

  # Read once and reused for the evidence line, so the pid in the log is the pid
  # the memory reading came from.
  pid="$(flux_game_pid)"
  rss="$(flux_game_rss_kb "${pid}")"
  [ "${rss}" -gt "${rss_peak}" ] && rss_peak="${rss}"
  flux_rss_collapsed "${rss}" "${rss_peak}" && rss_dropped=1
  # Read by the loop: the pid and peak the wait between samples watches, and the
  # level it re-arms the early wake on.
  GUARD_PID="${pid}"
  GUARD_RSS_DROPPED="${rss_dropped}"

  # A server that has never had a save is a server whose world has not been
  # written yet, not a server that lost one.
  if [ "${save_present}" = "1" ]; then
    save_seen_once=1
  elif [ "${save_seen_once}" = "0" ]; then
    save_present=1
  fi

  GUARD_VERDICT="$(flux_classify "${auth_ok}" "${info_ok}" "${metrics_ok}" "${fps}" \
    "${uptime}" "${prev_uptime}" "${rxq}" "${FLUX_GUARD_RXQ_BYTES}" "${save_present}" \
    "${rss_dropped}")"
  # Whether this one sample already settles it. Read by the loop to decide how
  # many strikes to wait for and whether a countdown would reach anybody.
  GUARD_PROVEN=0
  flux_worldless_is_proven "${GUARD_VERDICT}" "${fps}" "${uptime}" "${prev_uptime}" \
    "${rss_dropped}" "${auth_ok}" && GUARD_PROVEN=1
  # fps=- is ambiguous on its own and the ambiguity cost us months: "no such
  # field" and "the field is there and says nan" are different bugs. rc 2 is the
  # second one.
  local fps_shown="${fps:--}"
  [ -z "${fps}" ] && [ "${fps_rc}" = "2" ] && fps_shown="unreadable"

  GUARD_EVIDENCE="$(printf 'rest=%s metrics=%s fps=%s players=%s uptime=%s prev_uptime=%s rxq=%s save=%s rss=%sM peak=%sM pid=%s' \
    "${code}" "${metrics_ok}" "${fps_shown}" "${players:--}" "${uptime:--}" \
    "${prev_uptime:--}" "${rxq}" "${save_present}" \
    "$((rss / 1024))" "$((rss_peak / 1024))" "${pid}")"

  # Kept for the caller to log when it does not like the verdict. Without it a
  # strike says "fps=-" and nothing else, and there is no way after the fact to
  # tell what the server actually replied — which is exactly the hole that hid
  # this failure. Newlines flattened so one strike stays one line.
  GUARD_BODY=""
  if [ "${metrics_ok}" = "1" ] && [ -n "${metrics}" ]; then
    GUARD_BODY="$(printf '%s' "${metrics:0:${FLUX_GUARD_BODY_CHARS}}" | tr -d '\r\n')"
  fi

  [ -n "${uptime}" ] && prev_uptime="${uptime}"
  return 0
}

# Reads both clocks and says so out loud when they disagree. Called once per
# sample, right after it, so a step that lands next to a world unload is a line
# next to a line rather than something to be inferred afterwards. It decides
# nothing: a stepped clock is not by itself a fault, and no verdict reads this.
flux_guard_check_clock() {
  local wall mono skew
  wall="$(date -u +%s)"
  mono="$(flux_monotonic)"
  if [ -z "${wall_prev}" ]; then
    wall_start="${wall}"
    mono_start="${mono}"
  elif [ "${FLUX_GUARD_CLOCK_SKEW}" -gt 0 ] 2>/dev/null; then
    skew="$(flux_clock_skew "$((wall - wall_prev))" "$((mono - mono_prev))")"
    # ${skew#-} is the size of it, whichever way it went. Backwards is the one
    # ALLOW_NEGATIVE_DELTA_TIME exists for; forwards is the same host doing the
    # same thing and is worth the same line.
    if [ "${skew#-}" -ge "${FLUX_GUARD_CLOCK_SKEW}" ] 2>/dev/null; then
      clock_steps=$((clock_steps + 1))
      flux_log "the host stepped its clock: the wall clock moved ${skew}s more than the monotonic one since the last sample (step ${clock_steps} this generation)"
    fi
  fi
  wall_prev="${wall}"
  mono_prev="${mono}"
}

# What the two clocks add up to over the whole generation, for the capture line.
flux_guard_clock_drift() {
  [ -n "${wall_start}" ] && [ -n "${wall_prev}" ] || { printf '0'; return; }
  flux_clock_skew "$((wall_prev - wall_start))" "$((mono_prev - mono_start))"
}

# True when some verdict already has strikes against it. While that holds, the
# wait between samples is left exactly as configured — bringing samples forward
# inside a strike run would turn three strikes into fifteen seconds and hand a
# run of unlucky samples the power to restart a healthy server.
flux_guard_striking() {
  local k
  for k in "${!streak[@]}"; do
    [ "${streak[$k]}" -gt 0 ] && return 0
  done
  return 1
}

# What the players are told, per verdict. Deliberately plain: whoever reads it is
# already staring at a server that does not work.
flux_guard_message() {
  case "$1" in
    stalled)      printf 'This server has stopped responding to network traffic.' ;;
    unresponsive) printf 'This server has stopped responding.' ;;
    worldless)    printf 'The world is no longer loaded on this server.' ;;
    *)            printf 'This server needs to restart.' ;;
  esac
}

# --- one-shot mode (docker HEALTHCHECK) -------------------------------------
if [ "${1:-}" = "--check" ]; then
  FLUX_GUARD_LOG=""   # a health check must not write to the customer's volume
  flux_guard_sample
  printf '%s %s\n' "${GUARD_VERDICT}" "${GUARD_EVIDENCE}"
  [ "${GUARD_VERDICT}" = "ok" ]
  exit $?
fi

# --- the loop ---------------------------------------------------------------
if [ "${FLUX_GUARD_ENABLED,,}" != "true" ]; then
  flux_log "guard disabled (FLUX_GUARD_ENABLED=${FLUX_GUARD_ENABLED})"
  exit 0
fi

flux_log "guard armed: every ${FLUX_GUARD_INTERVAL}s (memory watched every ${FLUX_GUARD_RSS_POLL}s), ${FLUX_GUARD_FAILURES} strikes (1 when the world loss is proven), rxq limit ${FLUX_GUARD_RXQ_BYTES} bytes, rss drop $((FLUX_GUARD_RSS_DROP_KB / 1024))M, min uptime ${FLUX_GUARD_MIN_UPTIME}s, dry_run=${FLUX_GUARD_DRY_RUN}"

while true; do
  early=0
  [ "${rss_wake_armed}" = "1" ] && ! flux_guard_striking && early=1
  # Returns non-zero when it cut the wait short, which also spends the edge: the
  # sample below is what decides, and if it decides the server is fine the wake
  # stays down until memory comes back above the line.
  flux_guard_wait "${early}" "${GUARD_PID}" "${rss_peak}" || rss_wake_armed=0

  # No game process means the container is already on its way out; nothing to do.
  [ -n "$(flux_game_pid)" ] || continue

  flux_guard_sample
  flux_guard_check_clock
  [ "${GUARD_RSS_DROPPED}" = "1" ] || rss_wake_armed=1
  verdict="${GUARD_VERDICT}"
  evidence="${GUARD_EVIDENCE}"

  if [ "${verdict}" = "ok" ]; then
    if [ "${seen_healthy}" = "0" ]; then
      seen_healthy=1
      flux_log "server healthy for the first time this boot (${evidence})"
    fi
    for k in "${!streak[@]}"; do streak[$k]=0; done
    flux_log_rotate
    continue
  fi

  # Patience is for evidence that might be a hiccup. A sample that already proves
  # the world is gone gets none: waiting two more minutes and then announcing a
  # countdown into a world that does not exist is three minutes of a five minute
  # recovery spent on nobody's behalf. See flux_worldless_is_proven.
  if [ "${GUARD_PROVEN}" = "1" ]; then
    needed=1
    delay=0
  else
    needed="${FLUX_GUARD_FAILURES}"
    delay="${FLUX_GUARD_RESTART_DELAY}"
  fi

  streak[$verdict]=$(( ${streak[$verdict]} + 1 ))
  # Past the threshold the fraction stops meaning anything — a held server prints
  # "worldless 7/3" and reads like a counter that has run away. It only happens
  # under the min-uptime hold below, and there the honest line says so.
  if [ "${streak[$verdict]}" -gt "${needed}" ]; then
    flux_log "${verdict} still, ${streak[$verdict]} samples in (${evidence})"
  else
    flux_log "${verdict} ${streak[$verdict]}/${needed} (${evidence})"
  fi
  # Only on the first strike of a run: enough to diagnose, not enough to flood a
  # server that stays broken for hours.
  if [ -n "${GUARD_BODY}" ] && [ "${streak[$verdict]}" = "1" ]; then
    flux_log "  metrics said: ${GUARD_BODY}"
  fi

  [ "${streak[$verdict]}" -ge "${needed}" ] || continue

  # Guards against acting on a server that never worked in the first place.
  age=$(( $(date -u +%s) - started_at ))
  if [ "${seen_healthy}" = "0" ]; then
    flux_log "holding: ${verdict} confirmed but this server has not been healthy once since boot (${age}s ago) — a restart would only loop"
    streak[$verdict]=0
    continue
  fi
  # A fresh guard is started for every generation, so this is the age of the
  # generation, not of the container — the distinction matters when reading the
  # log of a container that has been up for days.
  #
  # It does not apply to a proven world loss. The rule is there for a world that is
  # still loading and for a server that comes up broken, and neither can be true
  # here: the check above has already established that this generation was healthy
  # once, which means a loaded world answering with fps, and the proof is that the
  # same process then lost it. Holding anyway is what cost 1787015974836 four
  # minutes of a dead world at 09:22:55 — three of them spent re-proving, on the
  # slow path, something one sample had already settled.
  if [ "${age}" -lt "${FLUX_GUARD_MIN_UPTIME}" ] && [ "${GUARD_PROVEN}" != "1" ]; then
    flux_log "holding: ${verdict} confirmed but this generation is only ${age}s old (min ${FLUX_GUARD_MIN_UPTIME}s)"
    continue
  fi

  if [ "${FLUX_GUARD_DRY_RUN,,}" = "true" ]; then
    flux_log "DRY RUN: would restart now (${verdict}: ${evidence})"
    streak[$verdict]=0
    continue
  fi

  if [ "${delay}" -gt 0 ]; then
    flux_log "ACTION ${verdict} confirmed $(flux_times "${needed}") (${evidence}); warning players and restarting in ${delay}s"
  else
    flux_log "ACTION ${verdict} confirmed $(flux_times "${needed}") (${evidence}); the world is provably gone, so there is nobody to warn — restarting now"
  fi
  flux_restart_countdown "${delay}" "$(flux_guard_message "${verdict}")"

  # One last look before pulling the trigger. A server that came back during the
  # countdown does not need restarting, and this is the cheapest place to find out.
  if [ "${delay}" -gt 0 ]; then
    flux_guard_sample
    if [ "${GUARD_VERDICT}" = "ok" ]; then
      flux_log "restart cancelled: the server recovered during the countdown (${GUARD_EVIDENCE})"
      flux_announce "The server recovered. No restart needed."
      for k in "${!streak[@]}"; do streak[$k]=0; done
      continue
    fi
  fi

  # Read the scene before disturbing it. Everything flux_capture_fault looks at
  # dies with the process a second from now, and the verdict has already been
  # reached — nothing it prints can change what happens next.
  flux_capture_fault "${verdict}" "${GUARD_PID}" "$(flux_guard_clock_drift)"

  # The reason starts with the verdict on purpose: flux-entrypoint.sh reads it
  # back off the marker to decide whether this restart says anything is wrong with
  # the container. See flux_restart_counts_against_budget.
  flux_force_restart "${verdict} confirmed $(flux_times "${needed}") (${evidence})"
  exit 0
done
