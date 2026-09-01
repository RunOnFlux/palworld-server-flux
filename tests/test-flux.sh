#!/bin/bash
# Unit tests for the pure parts of the Flux additions: the decision table that
# decides whether a server is broken, the admin password parser, the JSON field
# reader and the UDP queue reader. No container and no Palworld server needed.
#
#   ./tests/test-flux.sh

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

FLUX_GUARD_LOG=""            # keep the tests off any real volume
FLUX_SETTINGS_INI="${tmp}/PalWorldSettings.ini"
# shellcheck source=scripts/flux-lib.sh
source "${repo_root}/scripts/flux-lib.sh"

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

echo "flux_classify"
# args: auth_ok info_ok metrics_ok fps uptime prev_uptime rxq rxq_limit save_present
check "a healthy server" ok "$(flux_classify 1 1 1 59 1200 1140 960 65536 1)"
check "an idle but healthy server (no players, low fps is still non-zero)" \
  ok "$(flux_classify 1 1 1 30 90 30 0 65536 1)"
check "first sample of the boot, no previous uptime" \
  ok "$(flux_classify 1 1 1 59 60 "" 0 65536 1)"

# Mode A: the socket backs up while everything else still looks fine. This is the
# one that has to win even when the REST API is answering.
check "queue over the limit" stalled "$(flux_classify 1 1 1 59 5000 4940 110400 65536 1)"
check "queue at the limit" stalled "$(flux_classify 1 1 1 59 5000 4940 65536 65536 1)"
check "queue just under the limit" ok "$(flux_classify 1 1 1 59 5000 4940 65535 65536 1)"
check "a busy but healthy queue" ok "$(flux_classify 1 1 1 59 5000 4940 17584 65536 1)"

# Mode A: the API stops answering altogether.
check "REST API gone" unresponsive "$(flux_classify 1 0 0 "" "" 4940 0 65536 1)"

# Mode B: the process and the API are up, the world is not.
check "metrics gone while info answers" worldless "$(flux_classify 1 1 0 "" "" 4940 0 65536 1)"
check "zero fps" worldless "$(flux_classify 1 1 1 0 12 749 0 65536 1)"
# The shape this failure actually takes in production: a 200 with a body we
# cannot get a serverfps out of. It held for hours on every server we have logs
# for, so it has to be a conviction and not an "unknown".
check "200 with no readable serverfps" worldless "$(flux_classify 1 1 1 "" 44 22727 0 65536 1)"
check "200 with no readable serverfps, and uptime climbing again" \
  worldless "$(flux_classify 1 1 1 "" 104 44 0 65536 1)"
check "uptime went backwards" worldless "$(flux_classify 1 1 1 59 12 749 0 65536 1)"
check "uptime equal to the previous sample" ok "$(flux_classify 1 1 1 59 749 749 0 65536 1)"
check "the save vanished" worldless "$(flux_classify 1 1 1 59 5000 4940 0 65536 0)"

# Bad credentials must never convict: a 401 looks exactly like a dead API.
check "401 with everything else fine" ok "$(flux_classify 0 0 0 "" "" 4940 0 65536 1)"
check "401 does not stop the socket check" stalled "$(flux_classify 0 0 0 "" "" 4940 110400 65536 1)"
check "401 does not stop the save check" worldless "$(flux_classify 0 0 0 "" "" 4940 0 65536 0)"

# ...and the hole that leaves. With the API refusing us, mode B has no symptom the
# rules above can see: process up, socket drained, save file on disk. Resident
# memory is the one signature left, so it is allowed to convict there and only
# there — a server whose API is answering has better things to say about itself
# than its allocator does.
check "401 plus memory collapse is a world unload" \
  worldless "$(flux_classify 0 0 0 "" "" 4940 0 65536 1 1)"
check "memory collapse never overrules a server reporting fps" \
  ok "$(flux_classify 1 1 1 59 5000 4940 0 65536 1 1)"
check "memory collapse does not change a healthy 401 either way" \
  ok "$(flux_classify 0 0 0 "" "" 4940 0 65536 1 0)"
check "the argument is optional, as every caller before it assumed" \
  ok "$(flux_classify 1 1 1 59 1200 1140 960 65536 1)"

# The classifier is pure, which is what makes the table above possible — and is
# also what let a rule that can never fire sit here passing for months. These
# drive a whole run of samples through the same streak accounting the guard loop
# uses, which is where that bug actually lived.
echo "flux_classify over a run of samples"

# args: rxq_limit, then one "fps:uptime" pair per sample.
# Returns the highest consecutive worldless streak the run would produce.
worldless_streak() {
  local limit="$1" prev="" streak=0 best=0 fps uptime verdict
  shift
  for sample in "$@"; do
    fps="${sample%%:*}"
    uptime="${sample##*:}"
    verdict="$(flux_classify 1 1 1 "${fps}" "${uptime}" "${prev}" 0 "${limit}" 1)"
    if [ "${verdict}" = "worldless" ]; then
      streak=$((streak + 1))
      [ "${streak}" -gt "${best}" ] && best="${streak}"
    else
      streak=0
    fi
    [ -n "${uptime}" ] && prev="${uptime}"
  done
  printf '%s' "${best}"
}

# The real trace, from 1785894699157 and six others: uptime resets once and then
# climbs again, and serverfps never comes back. Before the fix this peaked at 1
# and the guard watched the world stay dead for up to 19 hours.
check "a world that unloads and stays unloaded convicts" \
  3 "$(worldless_streak 65536 59:5565 59:5625 "":39 "":99 "":159)"

# The uptime rule on its own is an edge and cannot convict — that is why the
# rule above has to carry it. Left here so nobody re-derives it the hard way.
check "an uptime reset alone never reaches three" \
  1 "$(worldless_streak 65536 59:5565 59:5625 59:39 59:99 59:159)"

# And the case that must never convict: a healthy server, players or not.
check "a healthy run never strikes" \
  0 "$(worldless_streak 65536 59:60 59:120 30:180 59:240 59:300)"

# Which of those samples is worth acting on at once, and which wants confirming.
# Getting this wrong in the permissive direction restarts working servers, so the
# table below spells out every way a sample can fail to be proof.
echo "flux_worldless_is_proven"
proven() { if flux_worldless_is_proven "$@"; then printf yes; else printf no; fi; }
# args: verdict fps uptime prev_uptime rss_dropped auth_ok

# The incident sample itself: 1785894699157 at 04:30:23, uptime back to 34 from
# 1600 with no serverfps behind a 200, on the same PID.
check "no fps and the uptime counter restarted" yes "$(proven worldless "" 34 1600 0)"
check "fps zero and the uptime counter restarted" yes "$(proven worldless 0 34 1600 0)"
# The samples after it: the counter climbs again from its new base, so the edge is
# gone and only the memory that left with the world still says so.
check "no fps and memory gone, uptime climbing again" yes "$(proven worldless "" 95 34 1)"
check "no fps, uptime climbing, memory intact" no "$(proven worldless "" 95 34 0)"

# A working server, however it is dressed up.
check "a server reporting fps is never proof" no "$(proven worldless 59 34 1600 1)"
check "no previous sample to compare against" no "$(proven worldless "" 34 "" 0)"
check "no uptime at all" no "$(proven worldless "" "" 1600 0)"
check "uptime equal, not backwards" no "$(proven worldless "" 1600 1600 0)"
# Only a world unload can be proven this way. A stalled socket or a dead API says
# nothing about whether anyone is still connected, so both keep their countdown.
check "stalled is never proven" no "$(proven stalled "" 34 1600 1)"
check "unresponsive is never proven" no "$(proven unresponsive "" 34 1600 1)"
check "ok is never proven" no "$(proven ok "" 34 1600 1)"

# Behind a 401 the memory reading has nothing to be cross-checked against, so it
# convicts the patient way and never the fast one. Three minutes costs nothing on
# a server that has been unreachable for as long as its password has been wrong.
check "memory alone is not proof when the API will not talk to us" \
  no "$(proven worldless "" "" "" 1 0)"
check "the same evidence with the API answering is proof" \
  yes "$(proven worldless "" "" "" 1 1)"
check "auth defaults to answering, as the guard always passes it" \
  yes "$(proven worldless "" 34 1600 0)"

echo "flux_rss_collapsed"
collapsed() { if flux_rss_collapsed "$@"; then printf yes; else printf no; fi; }
# args: rss peak, both in kB. Defaults: 1 GiB drop, 2 GiB minimum peak.
# The real numbers, off the crash dumps: 3.2 GB peak, 1.05 GB at the crash.
check "the drop from the crash dumps" yes "$(collapsed 1030908 3168996)"
check "a peak that never got big enough to lose a gigabyte" no "$(collapsed 500000 1500000)"
check "a drop just under the threshold" no "$(collapsed 2097153 3145728)"
check "a drop exactly at the threshold" yes "$(collapsed 2097152 3145728)"
check "memory at its peak" no "$(collapsed 3145728 3145728)"
check "no reading at all is not a collapse" no "$(collapsed 0 3145728)"
check "the signal can be switched off" no \
  "$(FLUX_GUARD_RSS_DROP_KB=0 collapsed 1030908 3168996)"

echo "flux_guard_wait"
mkdir -p "${tmp}/proc/7777"
rss_is() { printf 'VmRSS:\t %s kB\n' "$1" >"${tmp}/proc/7777/status"; }
# Returns 0 on a normal wait and 1 when it came back early. Timed, because the
# whole point is the wait it does not do.
waited_for() {
  local t0 t1
  t0="$(date +%s)"
  FLUX_PROC_ROOT="${tmp}/proc" FLUX_GUARD_INTERVAL="$1" FLUX_GUARD_RSS_POLL="$2" \
    flux_guard_wait "$3" 7777 "${4:-3168996}" >/dev/null
  local rc=$?
  t1="$(date +%s)"
  printf '%s after %ss' "$([ "${rc}" = 0 ] && printf full || printf early)" "$((t1 - t0))"
}
rss_is 3168996
check "memory holding up waits the whole interval" "full after 3s" "$(waited_for 3 1 1)"
rss_is 1030908
check "a collapse cuts the wait short" "early after 1s" "$(waited_for 6 1 1)"
check "and is ignored when the wake is not armed" "full after 2s" "$(waited_for 2 1 0)"
check "a poll at or above the interval is just a sleep" "full after 1s" "$(waited_for 1 5 1)"
check "polling can be switched off entirely" "full after 1s" "$(waited_for 1 0 1)"
# The signal itself off means there is nothing to wake on, however fast we look.
check "no memory signal, no early wake" "full after 2s" \
  "$(FLUX_GUARD_RSS_DROP_KB=0 waited_for 2 1 1)"
# A world that never grew big enough to lose a gigabyte cannot produce a collapse,
# so the wait must not spend a single read looking for one.
check "a peak too small to fall from is a plain sleep" "full after 2s" \
  "$(waited_for 2 1 1 1500000)"
check "and so is a generation with no peak yet" "full after 2s" \
  "$(waited_for 2 1 1 0)"

echo "flux_game_rss_kb"
mkdir -p "${tmp}/proc/4242"
printf 'Name:\tPalServer-Lin\nVmPeak:\t 7344700 kB\nVmRSS:\t 3168996 kB\nThreads:\t 42\n' \
  >"${tmp}/proc/4242/status"
check "reads VmRSS for a pid" 3168996 "$(FLUX_PROC_ROOT=${tmp}/proc flux_game_rss_kb 4242)"
check "a pid with no status file reads zero" 0 "$(FLUX_PROC_ROOT=${tmp}/proc flux_game_rss_kb 9999)"

echo "flux_times"
check "one sample" once "$(flux_times 1)"
check "three samples" "3 times" "$(flux_times 3)"

echo "flux_restart_counts_against_budget"
counts() { if flux_restart_counts_against_budget "$1"; then printf yes; else printf no; fi; }
# Ending the container costs a full SteamCMD install — 9m08s on the log this came
# from — and hands the app back to the platform's 30s loop. It has to be spent on
# the failures a fresh container could actually fix.
check "a world unload is the restart working, not the container failing" \
  no "$(counts 'worldless confirmed once (rest=200 metrics=1 fps=- uptime=34)')"
check "the nightly reboot is not a failure at all" \
  no "$(counts 'scheduled restart')"
check "the same, when it had to force the shutdown" \
  no "$(counts 'scheduled restart (server ignored the shutdown request)')"
check "a stalled socket still counts" \
  yes "$(counts 'stalled confirmed 3 times (rest=200 rxq=110400)')"
check "a dead REST API still counts" \
  yes "$(counts 'unresponsive confirmed 3 times (rest=000)')"
check "a server exiting on its own still counts" \
  yes "$(counts 'the server ended on its own (exit 0)')"

echo "flux_prune_crash_dumps"
FLUX_CRASH_DIR="${tmp}/Crashes"
mkdir -p "${FLUX_CRASH_DIR}"
for i in 1 2 3 4 5; do
  mkdir -p "${FLUX_CRASH_DIR}/crashinfo-Pal-pid-${i}/files"
  touch "${FLUX_CRASH_DIR}/crashinfo-Pal-pid-${i}/files/Diagnostics.txt"
  touch -d "2026-08-2${i} 04:00:00" "${FLUX_CRASH_DIR}/crashinfo-Pal-pid-${i}"
done
# Something that is not a dump. The volume is the customer's and this function
# deletes; it only ever deletes what the engine named.
mkdir -p "${FLUX_CRASH_DIR}/not-a-dump"
check "counts what is there" 6 "$(flux_crash_dump_count)"
check "keeping zero prunes nothing" 6 "$(FLUX_CRASH_KEEP=0 flux_prune_crash_dumps >/dev/null; flux_crash_dump_count)"
there() { if [ -d "${FLUX_CRASH_DIR}/$1" ]; then printf yes; else printf no; fi; }
check "keeps the newest two" 3 "$(FLUX_CRASH_KEEP=2 flux_prune_crash_dumps >/dev/null; flux_crash_dump_count)"
check "and they are the newest two" yes-yes "$(there crashinfo-Pal-pid-5)-$(there crashinfo-Pal-pid-4)"
check "the oldest are gone" no-no "$(there crashinfo-Pal-pid-1)-$(there crashinfo-Pal-pid-3)"
check "anything that is not a dump is left alone" yes "$(there not-a-dump)"
check "a missing directory is not an error" 0 \
  "$(FLUX_CRASH_DIR=${tmp}/nope flux_prune_crash_dumps >/dev/null; echo $?)"

echo "flux_boot_phase"
# args: installed pid_present
check "a fresh container is still pulling the game" \
  installing "$(flux_boot_phase 0 0)"
check "files on disk but the server not launched yet" \
  starting "$(flux_boot_phase 1 0)"
check "the process is up and reading the world in" \
  loading "$(flux_boot_phase 1 1)"
# A half-finished pull leaves PalServer.sh on disk without the appmanifest, and
# upstream would call that not-installed too. Never report past `installing` on it.
check "a process without the files is still installing" \
  installing "$(flux_boot_phase 0 1)"

echo "flux_game_installed"
FLUX_GAME_LAUNCHER="${tmp}/PalServer.sh"
FLUX_GAME_MANIFEST="${tmp}/appmanifest_2394010.acf"
installed_says() { if flux_game_installed; then printf yes; else printf no; fi; }
check "nothing on disk" no "$(installed_says)"
touch "${FLUX_GAME_LAUNCHER}"
check "launcher without the manifest is not installed" no "$(installed_says)"
touch "${FLUX_GAME_MANIFEST}"
check "both present" yes "$(installed_says)"
rm -f "${FLUX_GAME_LAUNCHER}" "${FLUX_GAME_MANIFEST}"

echo "flux_json_num exit codes"
check "an integer" 59 "$(flux_json_num '{"serverfps":59,"uptime":12}' serverfps)"
flux_json_num '{"uptime":12}' serverfps >/dev/null; check "absent key returns 1" 1 "$?"
flux_json_num '{"serverfps":nan,"uptime":12}' serverfps >/dev/null; check "nan returns 2" 2 "$?"
flux_json_num '{"serverfps":null,"uptime":12}' serverfps >/dev/null; check "null returns 2" 2 "$?"
flux_json_num '{"serverfps":-1,"uptime":12}' serverfps >/dev/null; check "a negative integer still parses" 0 "$?"

echo "flux_admin_password"
write_ini() { printf '[/Script/Pal.PalGameWorldSettings]\nOptionSettings=(Difficulty=None,ServerPassword="pw",AdminPassword=%s,PublicPort=8211)\n' "$1" >"${FLUX_SETTINGS_INI}"; }

write_ini '"adminPass"'
check "reads the ini" adminPass "$(flux_admin_password_from_ini)"
write_ini '"p@ss w0rd$&=,"'
check "keeps special characters" 'p@ss w0rd$&=,' "$(flux_admin_password_from_ini)"
printf 'OptionSettings=(AdminPassword="adminPass")\r\n' >"${FLUX_SETTINGS_INI}"
check "strips carriage returns" adminPass "$(flux_admin_password_from_ini)"
printf 'OptionSettings=(AdminPassword = "spaced")\n' >"${FLUX_SETTINGS_INI}"
check "tolerates spaces around the assignment" spaced "$(flux_admin_password_from_ini)"
printf ';OptionSettings=(AdminPassword="commentedOut")\nOptionSettings=(AdminPassword="live")\n' >"${FLUX_SETTINGS_INI}"
check "ignores commented lines" live "$(flux_admin_password_from_ini)"
printf 'OptionSettings=(AdminPassword="")\nOptionSettings=(AdminPassword="live")\n' >"${FLUX_SETTINGS_INI}"
check "an empty value does not hide a later one" live "$(flux_admin_password_from_ini)"
write_ini '""'
flux_admin_password_from_ini >/dev/null 2>&1
check "an empty password is rejected" 1 "$?"
FLUX_SETTINGS_INI="${tmp}/does-not-exist" flux_admin_password_from_ini "${tmp}/does-not-exist" >/dev/null 2>&1
check "a missing file is rejected" 1 "$?"
write_ini '"fromIni"'
# shellcheck disable=SC2119
check "the env var wins" fromEnv "$(ADMIN_PASSWORD=fromEnv flux_admin_password)"
# shellcheck disable=SC2119
check "an empty env var falls back to the ini" fromIni "$(ADMIN_PASSWORD='' flux_admin_password)"

echo "seeding a new server's settings"
FLUX_DEFAULT_INI="${repo_root}/scripts/PalWorldSettings.default.ini"
seed_dir="${tmp}/seed"
mkdir -p "${seed_dir}"

# The state a brand new server is actually left in: the file exists and is empty,
# because the engine rewrote the game's all-defaults sample as nothing.
printf '\n' >"${seed_dir}/empty.ini"
: >"${seed_dir}/zero.ini"
check "an empty file is not populated" 1 "$(flux_ini_is_populated "${seed_dir}/empty.ini"; echo $?)"
check "a zero-byte file is not populated" 1 "$(flux_ini_is_populated "${seed_dir}/zero.ini"; echo $?)"
check "a missing file is not populated" 1 "$(flux_ini_is_populated "${seed_dir}/nope.ini"; echo $?)"
check "the game's sample is populated" 0 "$(flux_ini_is_populated "${FLUX_DEFAULT_INI}"; echo $?)"

seeded="$(flux_ini_seed <"${FLUX_DEFAULT_INI}")"
check "the REST API is on" True "$(printf '%s' "${seeded}" | grep -o 'RESTAPIEnabled=[^,)]*' | cut -d= -f2)"
check "the autosave is 60" 60.000000 "$(printf '%s' "${seeded}" | grep -o 'AutoSaveSpan=[^,)]*' | cut -d= -f2)"
check "the admin password is 24 characters" 24 "$(printf '%s' "${seeded}" | grep -o 'AdminPassword="[^"]*"' | sed 's/.*="//;s/"//' | tr -d '\n' | wc -c)"
check "the password has no look-alike characters" "" "$(printf '%s' "${seeded}" | grep -o 'AdminPassword="[^"]*"' | sed 's/.*="//;s/"//' | tr -d 'a-km-zA-HJ-NP-Z2-9')"
check "every other setting is carried over" \
  "$(grep -c '=' "${FLUX_DEFAULT_INI}")" "$(printf '%s\n' "${seeded}" | grep -c '=')"
check "two seeds do not share a password" different \
  "$([ "$(flux_generate_password)" = "$(flux_generate_password)" ] && echo same || echo different)"

# Seeding a file that already has settings would be overwriting the customer.
cp "${FLUX_DEFAULT_INI}" "${seed_dir}/mine.ini"
sed -i 's/AutoSaveSpan=[^,)]*/AutoSaveSpan=15.000000/' "${seed_dir}/mine.ini"
before="$(cat "${seed_dir}/mine.ini")"
FLUX_SETTINGS_INI="${seed_dir}/mine.ini" flux_seed_ini_if_missing >/dev/null
check "a populated file is left exactly as it was" "${before}" "$(cat "${seed_dir}/mine.ini")"

# And the empty one is replaced.
FLUX_SETTINGS_INI="${seed_dir}/empty.ini" FLUX_GAME_DEFAULT_INI="${seed_dir}/nope.ini" flux_seed_ini_if_missing >/dev/null
check "an empty file is replaced" 0 "$(flux_ini_is_populated "${seed_dir}/empty.ini"; echo $?)"
check "and comes out with the REST API on" True "$(grep -o 'RESTAPIEnabled=[^,)]*' "${seed_dir}/empty.ini" | cut -d= -f2)"

echo "flux_rest_is_post"
# /v1/api/save answers 404 to a GET, which is indistinguishable from a server that
# does not have the endpoint. Getting this list wrong means the scheduled restart
# stops saving and nobody notices until someone loses an hour of play.
for endpoint in save stop shutdown announce kick ban unban; do
  flux_rest_is_post "${endpoint}"
  check "${endpoint} is POSTed" 0 "$?"
done
for endpoint in info metrics players settings; do
  flux_rest_is_post "${endpoint}"
  check "${endpoint} is a GET" 1 "$?"
done

echo "flux_json_num"
metrics='{"currentplayernum":2,"serverfps":59,"serverframetime":16.4,"maxplayernum":32,"uptime":749,"days":523}'
check "reads a field" 59 "$(flux_json_num "${metrics}" serverfps)"
check "reads a zero" 0 "$(flux_json_num '{"serverfps":0,"uptime":12}' serverfps)"
check "reads a field with spaces" 12 "$(flux_json_num '{"uptime" : 12}' uptime)"
flux_json_num "${metrics}" nosuchfield >/dev/null 2>&1
check "an absent field is not zero" 1 "$?"
flux_json_num "" serverfps >/dev/null 2>&1
check "an empty body is not zero" 1 "$?"

echo "flux_udp_rxq"
cat >"${tmp}/udp" <<'EOF'
  sl  local_address rem_address   st tx_queue:rx_queue tr tm->when retrnsmt   uid  timeout inode
  464: 00000000:2013 00000000:0000 07 00000000:0001AF40 00:00000000 00000000  1000        0 12345 2 0000000000000000 0
  465: 00000000:6987 00000000:0000 07 00000000:00000000 00:00000000 00000000  1000        0 12346 2 0000000000000000 0
EOF
: >"${tmp}/udp6"
check "reads the queue for the game port" 110400 "$(FLUX_PROC_UDP=${tmp}/udp FLUX_PROC_UDP6=${tmp}/udp6 flux_udp_rxq 8211)"
check "ignores other ports" 0 "$(FLUX_PROC_UDP=${tmp}/udp FLUX_PROC_UDP6=${tmp}/udp6 flux_udp_rxq 27015)"
check "an unbound port reads zero" 0 "$(FLUX_PROC_UDP=${tmp}/udp FLUX_PROC_UDP6=${tmp}/udp6 flux_udp_rxq 9999)"
cat >"${tmp}/udp6" <<'EOF'
  sl  local_address                         remote_address                        st tx_queue:rx_queue tr tm->when retrnsmt   uid  timeout inode
  466: 00000000000000000000000000000000:2013 00000000000000000000000000000000:0000 07 00000000:00016BC0 00:00000000 00000000  1000        0 12347 2 0000000000000000 0
EOF
check "reads IPv6 sockets too" 110400 "$(FLUX_PROC_UDP=${tmp}/udp FLUX_PROC_UDP6=${tmp}/udp6 flux_udp_rxq 8211)"

echo "flux_save_present"
mkdir -p "${tmp}/SaveGames/0/ABCD"
check "no save yet" 0 "$(FLUX_SAVE_GLOB="${tmp}/SaveGames/0/*/Level.sav" flux_save_present)"
touch "${tmp}/SaveGames/0/ABCD/Level.sav"
check "save on disk" 1 "$(FLUX_SAVE_GLOB="${tmp}/SaveGames/0/*/Level.sav" flux_save_present)"

echo "flux_proc_status_field"
# Same fixture the rss reader uses: one file, three fields, two of them not kB.
check "reads the high-water mark" 7344700 \
  "$(FLUX_PROC_ROOT=${tmp}/proc flux_proc_status_field 4242 VmPeak)"
check "reads a field that is not a size" 42 \
  "$(FLUX_PROC_ROOT=${tmp}/proc flux_proc_status_field 4242 Threads)"
check "a field that is not there reads zero" 0 \
  "$(FLUX_PROC_ROOT=${tmp}/proc flux_proc_status_field 4242 VmHWM)"
check "a process that is not there reads zero" 0 \
  "$(FLUX_PROC_ROOT=${tmp}/proc flux_proc_status_field 9999 VmRSS)"

echo "flux_wait_for_exit"
# /proc is the whole test: a directory that is there is a process that is still
# running, and one that is gone is one that left.
went() {
  local t0 t1 out rc
  t0="$(date +%s)"
  out="$(FLUX_PROC_ROOT=${tmp}/proc flux_wait_for_exit "$1" "$2")"
  rc=$?
  t1="$(date +%s)"
  printf '%s after %ss (reported %s)' \
    "$([ "${rc}" = 0 ] && printf gone || printf still-there)" "$((t1 - t0))" "${out}"
}
check "a process already gone costs no wait at all" "gone after 0s (reported 0)" \
  "$(went 9999 5)"
check "one that stays is given the whole deadline" "still-there after 2s (reported 2)" \
  "$(went 4242 2)"
check "a deadline of zero is one look and no sleep" "still-there after 0s (reported 0)" \
  "$(went 4242 0)"

echo "flux_save_stamp"
save_dir="${tmp}/stamp/SaveGames/0/ABCD"
mkdir -p "${save_dir}"
FLUX_SAVE_GLOB="${tmp}/stamp/SaveGames/0/*/Level.sav"
flux_save_stamp >/dev/null 2>&1
check "no save on disk is not a stamp" 1 "$?"
printf 'world' >"${save_dir}/Level.sav"
stamp_before="$(FLUX_SAVE_GLOB="${FLUX_SAVE_GLOB}" flux_save_stamp)"
check "an untouched save stamps the same twice" "${stamp_before}" \
  "$(FLUX_SAVE_GLOB="${FLUX_SAVE_GLOB}" flux_save_stamp)"
printf 'world and then some' >"${save_dir}/Level.sav"
check "a save that grew stamps differently" different \
  "$([ "$(FLUX_SAVE_GLOB="${FLUX_SAVE_GLOB}" flux_save_stamp)" != "${stamp_before}" ] && printf different || printf same)"

echo "flux_warn_if_save_changed"
# The alarm on the polite stop. It must fire on a write and stay silent otherwise,
# including when there was no save to compare against in the first place.
warned() {
  FLUX_SAVE_GLOB="${tmp}/stamp/SaveGames/0/*/Level.sav" flux_warn_if_save_changed "$1" \
    | grep -c 'WARN the save on disk changed'
}
check "a save that did not move says nothing" 0 \
  "$(warned "$(FLUX_SAVE_GLOB="${tmp}/stamp/SaveGames/0/*/Level.sav" flux_save_stamp)")"
check "a save that moved is shouted about" 1 "$(warned "${stamp_before}")"
check "nothing to compare against is not an alarm" 0 "$(warned "")"

echo "flux_newest_game_log"
logs="${tmp}/Logs"
mkdir -p "${logs}"
FLUX_GAME_LOG_DIR="${logs}" flux_newest_game_log >/dev/null 2>&1
check "an empty log directory is no log" 1 "$?"
touch -d '2026-08-30 03:00:00' "${logs}/Pal-backup-2026.08.30-03.00.00.log"
touch -d '2026-08-31 13:50:00' "${logs}/Pal.log"
touch -d '2026-08-31 14:00:00' "${logs}/Pal.txt"
check "the newest .log wins, whatever it is called" "${logs}/Pal.log" \
  "$(FLUX_GAME_LOG_DIR="${logs}" flux_newest_game_log)"
FLUX_GAME_LOG_DIR="${tmp}/no-such-dir" flux_newest_game_log >/dev/null 2>&1
check "a directory the engine never made is no log" 1 "$?"

echo "flux_mib"
check "bytes as megabytes" 2048M "$(flux_mib 2147483648)"
check "zero is a reading like any other" 0M "$(flux_mib 0)"
check "cgroup v2 says max when there is no limit" unlimited "$(flux_mib max)"
check "cgroup v1 says it in page counters" unlimited "$(flux_mib 9223372036854771712)"
check "and nothing at all is not a number either" unlimited "$(flux_mib "")"

echo "flux_cgroup_memory"
cg="${tmp}/cgroup"
mkdir -p "${cg}"
flux_cgroup_memory >/dev/null 2>&1
check "no accounting visible is not an answer" 1 "$(FLUX_CGROUP_ROOT=${cg} flux_cgroup_memory >/dev/null 2>&1; echo $?)"
printf '2076180480\n' >"${cg}/memory.current"
printf '2147483648\n' >"${cg}/memory.max"
printf 'low 0\nhigh 0\nmax 314\noom 2\noom_kill 1\n' >"${cg}/memory.events"
# The question this exists to answer: was the container against its ceiling when
# the world went, or nowhere near it.
check "cgroup v2, including the counter that names an OOM" \
  "current=1980M max=2048M oom=2 oom_kill=1" "$(FLUX_CGROUP_ROOT=${cg} flux_cgroup_memory)"
rm -f "${cg}/memory.events"
check "v2 without the events file still reports the ceiling" \
  "current=1980M max=2048M oom=0 oom_kill=0" "$(FLUX_CGROUP_ROOT=${cg} flux_cgroup_memory)"
mkdir -p "${cg}/memory"
printf '2076180480\n' >"${cg}/memory/memory.usage_in_bytes"
printf '9223372036854771712\n' >"${cg}/memory/memory.limit_in_bytes"
printf '12\n' >"${cg}/memory/memory.failcnt"
rm -f "${cg}/memory.current" "${cg}/memory.max"
check "cgroup v1, where failcnt is the closest thing to an OOM count" \
  "current=1980M max=unlimited failcnt=12" "$(FLUX_CGROUP_ROOT=${cg} flux_cgroup_memory)"

echo "flux_monotonic / flux_clock_skew"
printf '4368.42 8721.19\n' >"${tmp}/uptime"
check "seconds since boot, whole" 4368 "$(FLUX_PROC_UPTIME=${tmp}/uptime flux_monotonic)"
check "no /proc/uptime reads zero" 0 "$(FLUX_PROC_UPTIME=${tmp}/nope flux_monotonic)"
# A clock that only ticks. Both deltas agree and there is nothing to report.
check "two clocks that agree" 0 "$(flux_clock_skew 60 60)"
# The one ALLOW_NEGATIVE_DELTA_TIME exists for: wall time went backwards while the
# monotonic clock kept counting.
check "the wall clock stepped backwards" -37 "$(flux_clock_skew 23 60)"
check "and forwards" 40 "$(flux_clock_skew 100 60)"

if [ "${failures}" -eq 0 ]; then
  echo "all tests passed"
else
  echo "${failures} test(s) failed"
  exit 1
fi
