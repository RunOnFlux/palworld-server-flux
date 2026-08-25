#!/bin/bash
# PID 1, and the supervisor.
#
# Upstream's image ends the container whenever the game ends: start.sh runs
# PalServer in the foreground and init.sh walks out behind it. Recovery then
# depends on the platform noticing and starting the container again — on live
# FluxOS that is the masterSlaveApps loop, a 30 second cycle gated on syncthing
# health and on FDM still pointing at this node.
#
# This entrypoint does what lloesche/valheim-server does for Valheim (supervisord
# with autorestart=true): it supervises. init.sh runs as a child in its own
# process group, and when the server ends — because the guard killed it, because
# the scheduled restart asked for it, or because it crashed on its own — the
# generation is swept and a fresh one is started, in place, in seconds, with the
# platform never involved. The container's own lifecycle is left alone.
#
# The platform is the fallback, not the mechanism: after FLUX_RESTART_MAX_ATTEMPTS
# in-place restarts inside FLUX_RESTART_WINDOW seconds, this stops trying and ends
# the container so FluxOS can rebuild it (or move it), which is the right answer to
# a server that cannot stay up. FLUX_RESTART_MODE=container skips straight to that.
#
# What it does not touch: `docker stop`. A signal from the platform is honoured,
# forwarded to init.sh so upstream's own SIGTERM handler saves the world, and the
# supervisor does NOT restart anything afterwards.
#
# It also fills in ADMIN_PASSWORD from PalWorldSettings.ini when the env var is
# empty, which is the case on every server we sell. Upstream authenticates all of
# its container-side REST calls with that variable, so without this the nightly
# restart, the backups and the graceful shutdown all fail with a 401. Same fix as
# our open upstream PR #931, applied one level up so it works on any base version.

set -uo pipefail
# shellcheck source=scripts/flux-lib.sh
source /home/steam/server/flux-lib.sh

FLUX_RESTART_MODE="${FLUX_RESTART_MODE:-process}"
FLUX_RESTART_MAX_ATTEMPTS="${FLUX_RESTART_MAX_ATTEMPTS:-5}"
FLUX_RESTART_WINDOW="${FLUX_RESTART_WINDOW:-3600}"
FLUX_RESTART_BACKOFF="${FLUX_RESTART_BACKOFF:-10}"

# A marker left behind by a previous life of this container would be read as a
# restart that was never asked for. /tmp survives a container restart (the
# writable layer is not recreated), so clear it before anything else.
rm -f "${FLUX_RESTART_MARKER}"

# The persistent log lives on the app volume. Create it before writing into it and
# hand it to the user init.sh chowns the volume to.
if [ -d "$(dirname "${FLUX_GUARD_LOG}")" ]; then
  touch "${FLUX_GUARD_LOG}" 2>/dev/null && chown "${PUID:-1000}:${PGID:-1000}" "${FLUX_GUARD_LOG}" 2>/dev/null
fi

flux_log "flux-entrypoint starting (image ${FLUX_IMAGE_VERSION:-unknown}, base ${FLUX_BASE_VERSION:-unknown}, restart mode ${FLUX_RESTART_MODE})"

cd /home/steam/server || exit 1

# Whether the operator supplied one. If they did, it wins for the life of the
# container and the ini is never consulted — same precedence as upstream PR #931.
admin_password_from_env=0
[ -n "${ADMIN_PASSWORD:-}" ] && admin_password_from_env=1

init_pid=""
init_pgid=""
guard_pid=""
terminating=0
generation=0
own_pgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
declare -a restart_history=()

# shellcheck disable=SC2329  # invoked by the trap below
term_handler() {
  terminating=1
  flux_log "signal received: stopping for good, no restart will follow"
  [ -n "${init_pid}" ] && kill -TERM "${init_pid}" 2>/dev/null
}
trap term_handler TERM INT

# Upstream authenticates all of its container-side REST calls (the graceful save
# on SIGTERM, backups, rcon.yaml) as admin:${ADMIN_PASSWORD} — the env var, which
# is empty on every server we sell, because DISABLE_GENERATE_SETTINGS=true means
# the customer's password lives in PalWorldSettings.ini instead. Filling it in
# here fixes every one of those paths at once, which is what our upstream PR #931
# does inside the image; doing it in the wrapper means it holds on any base
# version, and becomes a harmless no-op the day the PR merges.
#
# Re-read once per generation rather than once per container: a password changed
# from the dashboard then takes effect at the next restart instead of never.
resolve_admin_password() {
  local resolved=""
  [ "${admin_password_from_env}" = "1" ] && return 0
  resolved="$(flux_admin_password_from_ini)" || resolved=""
  if [ "${resolved}" != "${ADMIN_PASSWORD:-}" ]; then
    if [ -n "${resolved}" ]; then
      flux_log "ADMIN_PASSWORD is not set; using AdminPassword from ${FLUX_SETTINGS_INI} for the container's own REST calls"
    else
      flux_log "WARN no admin password in the environment or in ${FLUX_SETTINGS_INI}; the container's REST calls will be unauthorized until one is set"
    fi
  fi
  ADMIN_PASSWORD="${resolved}"
  export ADMIN_PASSWORD
}

start_generation() {
  generation=$((generation + 1))
  resolve_admin_password
  flux_log "starting the server (generation ${generation})"

  # Its own process group, so a generation can be swept whole. Without it, a
  # restart would leave supercronic, player_logging and the autopause helpers
  # behind, and the next generation would start a second copy of each.
  setsid ./init.sh "$@" &
  init_pid=$!
  init_pgid="$(ps -o pgid= -p "${init_pid}" 2>/dev/null | tr -d ' ')"
  printf '%s' "${init_pid}" >"${FLUX_INIT_PIDFILE}"

  /home/steam/server/flux-guard.sh &
  guard_pid=$!
}

# Ends everything that belongs to the generation that just finished.
sweep_generation() {
  [ -n "${guard_pid}" ] && kill "${guard_pid}" 2>/dev/null
  guard_pid=""

  if [ -n "${init_pgid}" ] && [ "${init_pgid}" != "${own_pgid}" ]; then
    kill -TERM "-${init_pgid}" 2>/dev/null
    sleep 2
    kill -KILL "-${init_pgid}" 2>/dev/null
  else
    # setsid did not give us a group of our own; fall back to the children we
    # can name, and never signal our own group — that would take PID 1 with it.
    flux_log "WARN no separate process group for this generation; sweeping children individually"
    [ -n "${init_pid}" ] && pkill -KILL -P "${init_pid}" 2>/dev/null
  fi
  rm -f "${FLUX_INIT_PIDFILE}"
}

# Waits for the current generation to end. Returns init.sh's exit status, and
# keeps the guard alive for as long as the server is: a probe that died silently
# is a server with no protection at all.
wait_for_generation() {
  local rc marker_seen=0 now
  while kill -0 "${init_pid}" 2>/dev/null; do
    sleep 1

    # A restart that was asked for has a deadline. Upstream's exit path waits on
    # child processes (backup, restore, player logging) and a wedged one would
    # leave the container up with no game in it, which is the failure this image
    # exists to end.
    if [ -f "${FLUX_RESTART_MARKER}" ]; then
      now="$(date -u +%s)"
      [ "${marker_seen}" = "0" ] && marker_seen="${now}"
      if [ $((now - marker_seen)) -ge "${FLUX_RESTART_GRACE:-60}" ]; then
        flux_log "WARN a restart was requested ${FLUX_RESTART_GRACE:-60}s ago and the server is still winding down; forcing this generation to end"
        kill -KILL "${init_pid}" 2>/dev/null
      fi
    fi

    if [ -n "${guard_pid}" ] && ! kill -0 "${guard_pid}" 2>/dev/null && [ ! -f "${FLUX_RESTART_MARKER}" ]; then
      flux_log "WARN the health probe exited on its own; starting it again"
      /home/steam/server/flux-guard.sh &
      guard_pid=$!
    fi
  done
  # Collected once, after the fact: a trapped signal interrupts `wait` and makes
  # it report 128+signal instead of the child's real status.
  wait "${init_pid}"
  rc=$?
  return "${rc}"
}

# True while the in-place restarts still look like recovery rather than a loop.
within_restart_budget() {
  local now cutoff kept=()
  now="$(date -u +%s)"
  cutoff=$((now - FLUX_RESTART_WINDOW))
  for t in "${restart_history[@]}"; do
    [ "${t}" -ge "${cutoff}" ] && kept+=("${t}")
  done
  kept+=("${now}")
  restart_history=("${kept[@]}")
  [ "${#restart_history[@]}" -le "${FLUX_RESTART_MAX_ATTEMPTS}" ]
}

while true; do
  start_generation "$@"
  wait_for_generation
  rc=$?

  reason=""
  if [ -f "${FLUX_RESTART_MARKER}" ]; then
    reason="$(cat "${FLUX_RESTART_MARKER}" 2>/dev/null)"
    rm -f "${FLUX_RESTART_MARKER}"
  fi

  sweep_generation

  if [ "${terminating}" = "1" ]; then
    flux_log "stopped on request (init exited ${rc})"
    exit "${rc}"
  fi

  if [ -z "${reason}" ]; then
    reason="the server ended on its own (exit ${rc})"
  fi

  if [ "${FLUX_RESTART_MODE}" != "process" ]; then
    flux_log "container exiting on purpose: ${reason} (restart mode ${FLUX_RESTART_MODE}, reporting 42)"
    exit 42
  fi

  if ! within_restart_budget; then
    flux_log "${reason} — but that is ${#restart_history[@]} restarts within ${FLUX_RESTART_WINDOW}s. Something here is not fixable by restarting, so the container is ending instead and the platform can rebuild or move it (reporting 42)."
    exit 42
  fi

  flux_log "${reason} — restarting the server in place (${#restart_history[@]}/${FLUX_RESTART_MAX_ATTEMPTS} within ${FLUX_RESTART_WINDOW}s), in ${FLUX_RESTART_BACKOFF}s"
  sleep "${FLUX_RESTART_BACKOFF}"
done
