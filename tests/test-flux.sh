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
check "uptime went backwards" worldless "$(flux_classify 1 1 1 59 12 749 0 65536 1)"
check "uptime equal to the previous sample" ok "$(flux_classify 1 1 1 59 749 749 0 65536 1)"
check "the save vanished" worldless "$(flux_classify 1 1 1 59 5000 4940 0 65536 0)"

# Bad credentials must never convict: a 401 looks exactly like a dead API.
check "401 with everything else fine" ok "$(flux_classify 0 0 0 "" "" 4940 0 65536 1)"
check "401 does not stop the socket check" stalled "$(flux_classify 0 0 0 "" "" 4940 110400 65536 1)"
check "401 does not stop the save check" worldless "$(flux_classify 0 0 0 "" "" 4940 0 65536 0)"

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
