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
# Overridable so the tests can feed the parser a fixture instead of the kernel.
FLUX_PROC_UDP="${FLUX_PROC_UDP:-/proc/net/udp}"
FLUX_PROC_UDP6="${FLUX_PROC_UDP6:-/proc/net/udp6}"
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
  local path="$1" data="${2:-}" pw out code
  FLUX_REST_BODY=""
  FLUX_REST_CODE="000"
  # shellcheck disable=SC2119
  pw="$(flux_admin_password)" || pw=""
  if [ -n "${data}" ] || flux_rest_is_post "${path}"; then
    out=$(curl -sS -m "${FLUX_REST_TIMEOUT}" -u "admin:${pw}" -w $'\n%{http_code}' \
      -X POST --json "${data}" "http://127.0.0.1:${REST_API_PORT:-8212}/v1/api/${path}" 2>/dev/null)
  else
    out=$(curl -sS -m "${FLUX_REST_TIMEOUT}" -u "admin:${pw}" -w $'\n%{http_code}' \
      -H 'Accept: application/json' "http://127.0.0.1:${REST_API_PORT:-8212}/v1/api/${path}" 2>/dev/null)
  fi
  code="${out##*$'\n'}"
  [[ "${code}" =~ ^[0-9]{3}$ ]] || code="000"
  # Both are read by the other scripts, which shellcheck cannot see from here.
  # shellcheck disable=SC2034
  FLUX_REST_CODE="${code}"
  # shellcheck disable=SC2034
  FLUX_REST_BODY="${out%$'\n'*}"
  [ "${code}" = "200" ]
}

# Numeric field out of a JSON body without pulling in jq. Prints nothing (and
# returns 1) when the key is absent, which the caller must treat as "unknown"
# rather than as zero: "no answer" and "zero fps" are different verdicts.
flux_json_num() {
  local body="$1" key="$2" match
  match=$(printf '%s' "${body}" | grep -o "\"${key}\"[[:space:]]*:[[:space:]]*-\?[0-9][0-9]*" | head -1) || true
  [ -n "${match}" ] || return 1
  printf '%s' "${match##*[[:space:]:]}"
}

# --- system probes ----------------------------------------------------------
flux_game_pid() { pgrep -f "${FLUX_GAME_PROCESS}" 2>/dev/null | head -1; }

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
#   $4 fps          serverfps from metrics, empty when unknown
#   $5 uptime       uptime from metrics, empty when unknown
#   $6 prev_uptime  the previous sample's uptime, empty when unknown
#   $7 rxq          bytes queued on the game's UDP socket
#   $8 rxq_limit    threshold for the queue
#   $9 save_present 1/0, from flux_save_present
#
# Prints one of: ok | stalled | unresponsive | worldless
flux_classify() {
  local auth_ok="$1" info_ok="$2" metrics_ok="$3" fps="$4" uptime="$5" \
    prev_uptime="$6" rxq="$7" rxq_limit="$8" save_present="$9"

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
  if [ -n "${fps}" ] && [ "${fps}" -eq 0 ]; then
    printf 'worldless'
    return
  fi
  if [ -n "${uptime}" ] && [ -n "${prev_uptime}" ] && [ "${uptime}" -lt "${prev_uptime}" ]; then
    printf 'worldless'
    return
  fi

  printf 'ok'
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
# We SIGKILL rather than ask the server to shut down gracefully, and we never ask
# it to save first. In every state that gets us here the in-memory world is
# already gone or frozen, and telling a broken server to save risks writing that
# emptiness over the customer's last good save. What a kill costs is the interval
# since the last autosave, which was lost the moment the fault happened.
#
# Enforcing the deadline is flux-entrypoint.sh's job, not ours: it runs as root
# and can always end the container, while the scheduled reboot runs from cron as
# the steam user and cannot signal init.
#
# $1 reason, recorded for the log and for flux-entrypoint.sh's exit code.
flux_force_restart() {
  local reason="$1" pid
  flux_log "RESTART requested: ${reason}"
  printf '%s\n' "${reason}" >"${FLUX_RESTART_MARKER}" 2>/dev/null || true

  pid="$(flux_game_pid)"
  if [ -n "${pid}" ]; then
    flux_log "sending SIGKILL to ${FLUX_GAME_PROCESS} (pid ${pid})"
    kill -KILL "${pid}" 2>/dev/null || flux_log "WARN could not signal pid ${pid} (running as $(id -un))"
  else
    flux_log "no ${FLUX_GAME_PROCESS} process found; the container is already on its way out"
  fi
}
