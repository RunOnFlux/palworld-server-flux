#!/bin/bash
# PID 1.
#
# Runs upstream's init.sh as a child instead of replacing it, so every upstream
# behaviour (steamcmd update, config generation, crontab, autopause, the SIGTERM
# handler that saves the world on `docker stop`) is untouched. What this adds
# around it:
#
#   1. ADMIN_PASSWORD is filled in from PalWorldSettings.ini when the env var is
#      empty, which is the case on every server we sell. Upstream authenticates
#      all of its container-side REST calls with that variable, so without this
#      the nightly restart, the backups and the graceful shutdown all fail with a
#      401. Same fix as our open upstream PR #931, applied one level up so it
#      works on any base image version.
#   2. The health probe (flux-guard.sh) runs alongside the server.
#   3. Signals still reach init.sh, so `docker stop` saves the world as before.
#   4. A restart asked for by the guard or by the scheduled reboot always ends the
#      container, within a bounded time, with a distinguishable exit code.
#
# What actually restarts the container is the platform, since nothing inside a
# container can restart it:
#   - live FluxOS (7.3.0): our components carry the `g:` flag, so Docker's own
#     restart policy is 'no' and the masterSlaveApps loop (30 s cycle) starts the
#     container again on the same node, and therefore the same IP and ports,
#     while FDM still points there.
#   - FluxOS 8.x: appReconciler restarts on the Docker `die` event under an
#     effective 'always' policy, with a backoff ladder.
# Neither reads the exit code today. We still exit 42 rather than 0 so that the
# intent is on the record, and so the day a policy honours exit codes
# ('on-failure') a deliberate restart is not mistaken for a clean stop.

set -uo pipefail
# shellcheck source=scripts/flux-lib.sh
source /home/steam/server/flux-lib.sh

# A marker left behind by the previous life of this container would make the
# deadline watcher below fire on boot and restart-loop the server. /tmp survives a
# container restart (the writable layer is not recreated), so clear it first.
rm -f "${FLUX_RESTART_MARKER}"

# The persistent log lives on the app volume. Create it before dropping anything
# into it and hand it to steam, which is who init.sh chowns the volume to.
if [ -d "$(dirname "${FLUX_GUARD_LOG}")" ]; then
  touch "${FLUX_GUARD_LOG}" 2>/dev/null && chown "${PUID:-1000}:${PGID:-1000}" "${FLUX_GUARD_LOG}" 2>/dev/null
fi

flux_log "flux-entrypoint starting (image ${FLUX_IMAGE_VERSION:-unknown}, base ${FLUX_BASE_VERSION:-unknown})"

if [ -z "${ADMIN_PASSWORD:-}" ]; then
  if ADMIN_PASSWORD="$(flux_admin_password_from_ini)"; then
    export ADMIN_PASSWORD
    flux_log "ADMIN_PASSWORD was empty; using AdminPassword from ${FLUX_SETTINGS_INI} for the container's own REST calls"
  else
    flux_log "WARN no admin password in the environment or in ${FLUX_SETTINGS_INI}; the container's REST calls will be unauthorized until one is set"
  fi
fi

cd /home/steam/server || exit 1

init_pid=""
guard_pid=""
deadline_pid=""

# shellcheck disable=SC2329  # invoked by the trap below
term_handler() {
  flux_log "signal received, forwarding to init (pid ${init_pid})"
  [ -n "${init_pid}" ] && kill -TERM "${init_pid}" 2>/dev/null
}
trap term_handler TERM INT

./init.sh "$@" &
init_pid=$!
printf '%s' "${init_pid}" >"${FLUX_INIT_PIDFILE}"

# Once a restart has been asked for, the container has a deadline. Upstream's exit
# path waits on child processes (backup, restore, player logging) and a wedged one
# would leave the container up with no game in it, which is the failure this image
# exists to end.
(
  while [ ! -f "${FLUX_RESTART_MARKER}" ]; do sleep 2; done
  sleep "${FLUX_RESTART_GRACE:-60}"
  if kill -0 "${init_pid}" 2>/dev/null; then
    flux_log "restart was requested ${FLUX_RESTART_GRACE:-60}s ago and init is still alive; killing it"
    kill -KILL "${init_pid}" 2>/dev/null
  fi
) &
deadline_pid=$!

# The guard decides for itself whether it is enabled and says so in the log, so
# it is always started: a server with the probe switched off should say that out
# loud rather than look identical to one where it silently never ran.
/home/steam/server/flux-guard.sh &
guard_pid=$!

# Waiting by polling rather than by `wait` alone: a trapped signal interrupts
# `wait` and makes it report 128+signal instead of the child's real status, and
# whether the child had already exited by then is a race. Polling keeps the
# handler free to run and leaves the status to be collected once, afterwards.
while kill -0 "${init_pid}" 2>/dev/null; do
  sleep 1
done
wait "${init_pid}"
rc=$?

[ -n "${guard_pid}" ] && kill "${guard_pid}" 2>/dev/null
[ -n "${deadline_pid}" ] && kill "${deadline_pid}" 2>/dev/null
rm -f "${FLUX_INIT_PIDFILE}"

if [ -f "${FLUX_RESTART_MARKER}" ]; then
  reason="$(cat "${FLUX_RESTART_MARKER}" 2>/dev/null)"
  rm -f "${FLUX_RESTART_MARKER}"
  flux_log "container exiting on purpose: ${reason} (init exited ${rc}, reporting 42)"
  exit 42
fi

flux_log "init exited ${rc}"
exit "${rc}"
