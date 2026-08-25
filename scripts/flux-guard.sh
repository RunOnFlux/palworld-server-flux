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
# row before it believes it, and then ends the container so the platform brings it
# back (see flux-entrypoint.sh for who does the bringing back).
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

started_at="$(date -u +%s)"
prev_uptime=""
save_seen_once=0
seen_healthy=0
auth_ok=1
auth_warned_at=0
GUARD_VERDICT="ok"
GUARD_EVIDENCE=""
declare -A streak=([stalled]=0 [unresponsive]=0 [worldless]=0)

# Collects one sample. Sets GUARD_VERDICT and GUARD_EVIDENCE, and updates the
# state carried between samples (prev_uptime, auth_ok, save_seen_once). It must
# NOT be called in a command substitution: a subshell would throw that state away
# every cycle, and the guard would lose the one signal — a uptime counter that
# went backwards — that can only be seen by comparing two samples.
flux_guard_sample() {
  local metrics info_ok=0 metrics_ok=0 fps="" uptime="" rxq save_present code now

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
    fps="$(flux_json_num "${metrics}" serverfps)" || fps=""
    uptime="$(flux_json_num "${metrics}" uptime)" || uptime=""
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
  # A server that has never had a save is a server whose world has not been
  # written yet, not a server that lost one.
  if [ "${save_present}" = "1" ]; then
    save_seen_once=1
  elif [ "${save_seen_once}" = "0" ]; then
    save_present=1
  fi

  GUARD_VERDICT="$(flux_classify "${auth_ok}" "${info_ok}" "${metrics_ok}" "${fps}" \
    "${uptime}" "${prev_uptime}" "${rxq}" "${FLUX_GUARD_RXQ_BYTES}" "${save_present}")"
  GUARD_EVIDENCE="$(printf 'rest=%s metrics=%s fps=%s uptime=%s prev_uptime=%s rxq=%s save=%s pid=%s' \
    "${code}" "${metrics_ok}" "${fps:--}" "${uptime:--}" \
    "${prev_uptime:--}" "${rxq}" "${save_present}" "$(flux_game_pid)")"

  [ -n "${uptime}" ] && prev_uptime="${uptime}"
  return 0
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

flux_log "guard armed: every ${FLUX_GUARD_INTERVAL}s, ${FLUX_GUARD_FAILURES} strikes, rxq limit ${FLUX_GUARD_RXQ_BYTES} bytes, min uptime ${FLUX_GUARD_MIN_UPTIME}s, dry_run=${FLUX_GUARD_DRY_RUN}"

while true; do
  sleep "${FLUX_GUARD_INTERVAL}"

  # No game process means the container is already on its way out; nothing to do.
  [ -n "$(flux_game_pid)" ] || continue

  flux_guard_sample
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

  streak[$verdict]=$(( ${streak[$verdict]} + 1 ))
  flux_log "${verdict} ${streak[$verdict]}/${FLUX_GUARD_FAILURES} (${evidence})"

  [ "${streak[$verdict]}" -ge "${FLUX_GUARD_FAILURES}" ] || continue

  # Guards against acting on a server that never worked in the first place.
  age=$(( $(date -u +%s) - started_at ))
  if [ "${seen_healthy}" = "0" ]; then
    flux_log "holding: ${verdict} confirmed but this server has not been healthy once since boot (${age}s ago) — a restart would only loop"
    streak[$verdict]=0
    continue
  fi
  if [ "${age}" -lt "${FLUX_GUARD_MIN_UPTIME}" ]; then
    flux_log "holding: ${verdict} confirmed but the container is only ${age}s old (min ${FLUX_GUARD_MIN_UPTIME}s)"
    continue
  fi

  if [ "${FLUX_GUARD_DRY_RUN,,}" = "true" ]; then
    flux_log "DRY RUN: would restart now (${verdict}: ${evidence})"
    streak[$verdict]=0
    continue
  fi

  flux_log "ACTION ${verdict} confirmed ${FLUX_GUARD_FAILURES} times (${evidence}); warning players and restarting in ${FLUX_GUARD_RESTART_DELAY}s"
  flux_restart_countdown "${FLUX_GUARD_RESTART_DELAY}" "$(flux_guard_message "${verdict}")"

  # One last look before pulling the trigger. A server that came back during the
  # countdown does not need restarting, and this is the cheapest place to find out.
  if [ "${FLUX_GUARD_RESTART_DELAY}" -gt 0 ]; then
    flux_guard_sample
    if [ "${GUARD_VERDICT}" = "ok" ]; then
      flux_log "restart cancelled: the server recovered during the countdown (${GUARD_EVIDENCE})"
      flux_announce "The server recovered. No restart needed."
      for k in "${!streak[@]}"; do streak[$k]=0; done
      continue
    fi
  fi

  flux_force_restart "${verdict} confirmed ${FLUX_GUARD_FAILURES} times (${evidence})"
  exit 0
done
