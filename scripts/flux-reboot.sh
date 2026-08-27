#!/bin/bash
# The scheduled restart. Upstream's crontab line points at auto_reboot.sh, which
# in this image is a symlink to this file, so an existing app spec needs no change
# to pick this up.
#
# Why it is not upstream's auto_reboot.sh:
#
#   1. Upstream asks the server to save and refuses to shut down if the save
#      fails ("Do not shutdown if not able to save"). On a server that is leaking,
#      frozen or worldless — the only servers a restart actually matters for —
#      the save is exactly what fails, so the nightly restart silently does
#      nothing on the nights it is needed. Ours always ends with the server down:
#      it tries the polite route first and then stops asking. Worth knowing that
#      the polite route usually is not available — across seven servers, five of
#      six nightly restarts found no world to save and went ahead without one.
#   2. Upstream authenticates as admin:${ADMIN_PASSWORD}, the env var, which is
#      empty on every server we sell; the ini holds the real password. We read
#      both (flux_admin_password).
#   3. Upstream's exit is a plain "the game ended". Ours leaves a marker, which is
#      how PID 1 tells a restart we asked for apart from a server that died on its
#      own, and what arms the deadline that stops a wedged shutdown hanging the
#      generation forever. The marker does NOT end the container: under the
#      default FLUX_RESTART_MODE=process the supervisor starts the next generation
#      in place, so a nightly restart costs about thirty seconds and no download.
#
# Env (upstream's names, unchanged):
#   AUTO_REBOOT_WARN_MINUTES              in-game countdown before the restart
#   AUTO_REBOOT_EVEN_IF_PLAYERS_ONLINE    restart anyway when someone is playing

set -uo pipefail
# shellcheck source=scripts/flux-lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/flux-lib.sh"

WARN_MINUTES="${AUTO_REBOOT_WARN_MINUTES:-5}"
EVEN_IF_PLAYERS_ONLINE="${AUTO_REBOOT_EVEN_IF_PLAYERS_ONLINE:-false}"
# How long to let the server shut itself down before we stop being polite.
GRACEFUL_WAIT="${FLUX_REBOOT_GRACEFUL_WAIT:-90}"

# Number of players from the metrics endpoint. Prints nothing when the server
# cannot be asked, which the caller reads as "restart it anyway" — a server we
# cannot query is precisely the one that needs the restart.
players_online() {
  flux_rest metrics || return 1
  flux_json_num "${FLUX_REST_BODY}" currentplayernum
}

# True while the world is still loaded and ticking. Guards the save: asking a
# worldless server to save can write that emptiness over the last good save.
world_is_loaded() {
  local fps
  flux_rest metrics || return 1
  fps="$(flux_json_num "${FLUX_REST_BODY}" serverfps)" || return 1
  [ "${fps}" -gt 0 ]
}

announce() {
  flux_rest announce "{\"message\":\"$1\"}" >/dev/null 2>&1 || true
}

countdown() {
  local minutes="$1" i
  [[ "${minutes}" =~ ^[0-9]+$ ]] || return 0
  for ((i = minutes; i > 0; i--)); do
    if [ "${i}" -eq 1 ]; then
      announce "Server will restart in 1 minute"
      sleep 30
      announce "Server will restart in 30 seconds"
      sleep 30
    else
      announce "Server will restart in ${i} minutes"
      sleep 60
    fi
  done
}

main() {
  local players waited=0

  players="$(players_online)" || players=""
  flux_log "scheduled restart starting (players=${players:-unknown}, even_if_players_online=${EVEN_IF_PLAYERS_ONLINE})"

  if [ "${EVEN_IF_PLAYERS_ONLINE,,}" != "true" ]; then
    if [ -n "${players}" ] && [ "${players}" -gt 0 ]; then
      flux_log "skipping: ${players} player(s) online"
      exit 0
    fi
    # Deliberate, but say so out loud. The "cannot ask" branch is not the rare
    # case it reads like: a server whose world has unloaded answers 200 with no
    # player count in it, and that is the state most servers are in by the time
    # this runs. Silently, AUTO_REBOOT_EVEN_IF_PLAYERS_ONLINE=false then does
    # nothing at all, and someone reading the setting deserves to know.
    if [ -z "${players}" ]; then
      flux_log "WARN could not read the player count; restarting anyway, which overrides AUTO_REBOOT_EVEN_IF_PLAYERS_ONLINE=false"
    fi
  fi

  # Nothing to stop: the supervisor is already dealing with whatever happened, and
  # asking for a restart of a server that is not running would leave a marker behind
  # for the NEXT generation to trip over.
  if [ -z "$(flux_game_pid)" ]; then
    flux_log "no server process running; leaving this to the supervisor"
    exit 0
  fi

  # From here on the server WILL go down. The marker goes in first so that
  # however the process ends — polite shutdown, SIGKILL, or the server dying on
  # its own halfway through — PID 1 knows this was on purpose.
  printf '%s\n' "scheduled restart" >"${FLUX_RESTART_MARKER}" 2>/dev/null || true

  if [ -n "${players}" ] && [ "${players}" -gt 0 ]; then
    countdown "${WARN_MINUTES}"
  fi

  if world_is_loaded; then
    announce "Server is saving and restarting now"
    if flux_rest save; then
      flux_log "world saved"
    else
      flux_log "WARN save returned HTTP ${FLUX_REST_CODE}; restarting anyway"
    fi
  else
    flux_log "WARN world is not loaded (or cannot be queried); skipping the save so nothing overwrites the last good one"
  fi

  # Accepted is not the same as done. On a server whose world has already gone,
  # every observed shutdown ended in a segfault about a second later rather than a
  # clean exit — same outcome, so nothing here needs to change, but it is why the
  # graceful wait below almost never gets used.
  if flux_rest shutdown '{"waittime":1,"message":"Restarting"}'; then
    flux_log "shutdown accepted, waiting up to ${GRACEFUL_WAIT}s for the server to exit"
  else
    flux_log "WARN shutdown returned HTTP ${FLUX_REST_CODE}"
  fi

  while [ "${waited}" -lt "${GRACEFUL_WAIT}" ]; do
    [ -n "$(flux_game_pid)" ] || { flux_log "server exited on its own after ${waited}s"; exit 0; }
    sleep 5
    waited=$((waited + 5))
  done

  flux_log "server still up after ${GRACEFUL_WAIT}s; forcing it down"
  flux_force_restart "scheduled restart (server ignored the shutdown request)"
}

main "$@"
