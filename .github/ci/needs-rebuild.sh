#!/bin/bash
# Which upstream release does this build use, and does the scheduled run have anything to publish?
#
#   .github/ci/needs-rebuild.sh <image> <upstream repo>
#
# Environment: FORCE_VERSION (optional, a workflow_dispatch input: an upstream tag to build),
#              GITHUB_EVENT_NAME, GITHUB_OUTPUT.
# Writes to $GITHUB_OUTPUT:
#   version      the upstream STABLE release (vX.Y.Z) to build on: FORCE_VERSION, or the newest
#   build        true or false
#
# A push or a manual run always builds. A SCHEDULED run (Mondays) builds only when there is
# something to apply, because every image published as :latest restarts every server running it
# (FluxOS compares each app's tag digest every six hours and soft-redeploys onto a new one, with no
# warning in game), and a rebuild of unchanged inputs still gets a new digest. Three things make a
# scheduled run build NOW:
#   1. upstream cut a new STABLE release (vX.Y.Z; :latest, :dev and the v2 / v2.7 aliases are
#      deliberately ignored, they move with upstream's main branch): the newest differs from the
#      org.opencontainers.image.base.version label of the published :latest, or
#   2. a security update is waiting in the published image for a package the server really runs on
#      (URGENT below: the C library, TLS, certificates, curl, zlib, the C++ runtime, the
#      libraries SteamCMD's 32-bit side needs), or
#   3. main has commits the published image does not have: :latest records the commit it was built
#      from (label org.opencontainers.image.revision), and at least one commit since then touches
#      an image INPUT (the Dockerfile, VERSION, every path a COPY/ADD takes). README, tests and
#      .github changes do not count. A published image with no revision label counts as pending
#      (one extra rebuild, after which it is labelled). Needs the full git history
#      (actions/checkout fetch-depth: 0).
# Anything else waiting (a non-security package update) is left for the first Monday of the month.
# The base is Debian (13), so the origins checked are Debian and Debian-Security, not Ubuntu.
# Measured with the base of 2026-10-20: 55 updates waiting, one of them flagged Debian-Security.
set -euo pipefail

image="${1:?image}"
base_repo="${2:?upstream repo}"
out="${GITHUB_OUTPUT:-/dev/stdout}"

# The version to build on.
version="${FORCE_VERSION:-}"
if [ -z "${version}" ]; then
  version="$(curl -fsSL "https://hub.docker.com/v2/repositories/${base_repo}/tags?page_size=100&ordering=last_updated" \
    | jq -r '.results[].name' \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -V | tail -1 || true)"
fi
[ -n "${version}" ] || { echo "::error::could not resolve a stable vX.Y.Z tag for ${base_repo}"; exit 1; }
echo "version=${version}" >>"${out}"
echo "newest stable upstream release: ${version}"

if [ "${GITHUB_EVENT_NAME:-}" != "schedule" ]; then
  echo "build=true" >>"${out}"
  echo "a ${GITHUB_EVENT_NAME:-manual} run: building"
  exit 0
fi

# Packages whose security updates are applied the same week.
URGENT='^(libc6|libc6-i386|libc-bin|libssl[0-9a-z.]*|openssl|ca-certificates|curl|libcurl[0-9a-z.-]*|libgnutls[0-9a-z.]*|libnghttp2-[0-9a-z]*|zlib1g|libstdc\+\+6|libgcc-s1|lib32gcc-s1|lib32stdc\+\+6)(:[a-z0-9]+)?$'
monthly=false
[ "$(date -u +%d)" -le 7 ] && monthly=true

now=()
later=()

# A label of the published image (one platform, or the amd64 entry of a multi-platform one).
published_label() {
  docker buildx imagetools inspect "${image}:latest" --format '{{json .Image}}' 2>/dev/null \
    | jq -r --arg k "$1" 'if has("config") then . else ([to_entries[] | select(.key | test("amd64")) | .value][0] // {}) end
                          | .config.Labels[$k] // empty' || true
}

# 1. A new upstream release.
published="$(published_label org.opencontainers.image.base.version)"
if [ "${published}" != "${version}" ]; then
  now+=("upstream released ${version} (the published image is on ${published:-<none>})")
else
  echo "already on ${version}"
fi

# 3. Commits on main the published image does not have.
head_sha="$(git rev-parse HEAD)"
revision="$(published_label org.opencontainers.image.revision)"
pending=false
inputs=(Dockerfile VERSION)
while read -r line; do
  read -ra words <<<"${line}"
  words=("${words[@]:1}")
  sources=()
  for w in "${words[@]}"; do
    [[ "${w}" == --* ]] || sources+=("${w}")
  done
  unset 'sources[${#sources[@]}-1]'
  inputs+=("${sources[@]}")
# (A COPY continued with a trailing backslash is joined first.)
done < <(sed -e ':a' -e '/\\$/{N;s/\\\n/ /;ba}' Dockerfile | grep -E '^(COPY|ADD)[[:space:]]' | grep -v -- '--from=' || true)
if [ -z "${revision}" ]; then
  pending=true
  now+=("the published image records no revision (built before this check): pending")
elif [ "${revision}" = "${head_sha}" ]; then
  echo "the published image was built from HEAD (${head_sha:0:12})"
elif ! git cat-file -e "${revision}^{commit}" 2>/dev/null; then
  pending=true
  now+=("the published revision ${revision:0:12} is not in this checkout's history: pending")
else
  ahead="$(git rev-list --count "${revision}..${head_sha}" -- "${inputs[@]}")"
  if [ "${ahead}" -gt 0 ]; then
    pending=true
    now+=("${ahead} commit(s) since the published ${revision:0:12} touch the image inputs (${inputs[*]})")
  else
    echo "no commit since the published ${revision:0:12} touches the image inputs (${inputs[*]})"
  fi
fi
echo "pending=${pending}"

# 2. Updates the published image is missing, as root.
# "Inst <package> [<installed>] (<candidate> <origin> ..." per package.
# Only Debian's own archive counts. The build runs apt-get upgrade, so what a rebuild applies is
# exactly what is listed here.
updates="$(docker run --rm --pull always --user 0 --entrypoint sh "${image}:latest" -c \
  'apt-get update -qq >/dev/null 2>&1 && apt-get -s upgrade 2>/dev/null | grep "^Inst " | grep -E " Debian(-Security)?:"' || true)"
security="$(grep -- 'Debian-Security' <<<"${updates}" | awk '{print $2}' || true)"
urgent="$(grep -E "${URGENT}" <<<"${security}" || true)"
other="$(grep -c . <<<"${updates}" || true)"
if [ -n "${urgent}" ]; then
  now+=("security updates for $(tr '\n' ' ' <<<"${urgent}")")
fi
if [ "${other:-0}" -gt 0 ]; then
  echo "waiting in the published image: $(awk '{print $2}' <<<"${updates}" | tr '\n' ' ')"
  later+=("${other} package update(s) are waiting")
fi

if [ "${#now[@]}" -gt 0 ]; then
  printf 'building now: %s\n' "${now[@]}"
  echo "build=true" >>"${out}"
elif [ "${#later[@]}" -gt 0 ] && [ "${monthly}" = true ]; then
  printf 'building (the monthly rebuild): %s\n' "${later[@]}"
  echo "build=true" >>"${out}"
elif [ "${#later[@]}" -gt 0 ]; then
  printf 'left for the monthly rebuild (first Monday): %s\n' "${later[@]}"
  echo "build=false" >>"${out}"
else
  echo "nothing new: ${image}:latest stays as it is, and no server restarts"
  echo "build=false" >>"${out}"
fi
