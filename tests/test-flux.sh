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

if [ "${failures}" -eq 0 ]; then
  echo "all tests passed"
else
  echo "${failures} test(s) failed"
  exit 1
fi
