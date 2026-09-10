#!/usr/bin/env bash

# Decide whether the release workflow needs to build.
#
# Reads from the environment:
#   DEVICE_NAME         Device code name
#   GRAPHENEOS_VERSION  GrapheneOS version to release
#   REPOSITORY          GitHub repository as `owner/name`
#   ROOT                "true" builds the magisk flavor, anything else rootless
#   FORCE_UPDATE        "true" rebuilds the current version on module updates
#
# Writes build_needed to GITHUB_OUTPUT; the workflow skips the build steps when it
# is false, so an already released version is a no-op rather than a failed run.
# Writes FORCE_REBUILD=true to GITHUB_ENV when an existing asset gets replaced.

set -o nounset -o pipefail -o errexit

function decide() {
  echo "build_needed=${1}" >>"${GITHUB_OUTPUT:-/dev/null}"
  exit 0
}

build_flavor=$([[ "${ROOT:-false}" == "true" ]] && echo 'magisk' || echo 'rootless')

# Check if the tag exists
if ! git show-ref --tags "${GRAPHENEOS_VERSION}" --quiet; then
  echo -e "Tag with GrapheneOS version ${GRAPHENEOS_VERSION} does not exist. Creating one..."
  decide true
fi

echo -e "Tag with GrapheneOS version ${GRAPHENEOS_VERSION} already exists. Looking for assets..."
# Fetch the release information for the tag
repo_url="https://api.github.com/repos/${REPOSITORY}/releases/tags/${GRAPHENEOS_VERSION}"

# Unauthenticated, this shares a 60 per hour limit with every other runner on
# the same address. A throttled reply parses as a release with no assets, which
# reads as "rebuild", so every scheduled run would rebuild and republish
auth=()
if [[ -n "${GH_TOKEN:-}" ]]; then
  auth=(--header "Authorization: Bearer ${GH_TOKEN}")
fi

release_body=$(mktemp)
trap 'rm -f "${release_body}"' EXIT
http_status=$(curl -sL --max-time 30 --retry 2 "${auth[@]}" \
  --output "${release_body}" --write-out '%{http_code}' "${repo_url}" || true)

case "${http_status}" in
404)
  # The tag exists but carries no release yet
  echo -e "No release for ${GRAPHENEOS_VERSION} yet. Proceeding with build..."
  decide true
  ;;
200) ;;
*)
  echo "::error::Could not read the ${GRAPHENEOS_VERSION} release of ${REPOSITORY} (HTTP ${http_status:-000})."
  exit 1
  ;;
esac

# A proxy or captive portal can answer 200 with something that is not a release.
# An empty body and an unrelated object both survive `jq` and read as a release
# with no assets, which is the rebuild path again
if [[ "$(jq 'type == "object" and has("assets")' <"${release_body}" 2>/dev/null)" != "true" ]]; then
  echo "::error::The ${GRAPHENEOS_VERSION} release of ${REPOSITORY} did not parse as a release."
  exit 1
fi

existing_assets=$(jq -r '.assets[]?.name' <"${release_body}")

# Assets of the current flavor, e.g. bluejay-2026081300-rootless-abc1234.zip
zip_regex="^${DEVICE_NAME}-${GRAPHENEOS_VERSION}-${build_flavor}-.*\.zip$"
existing_zip=$(grep -E "${zip_regex}" <<<"${existing_assets}" | head -n1 || true)
existing_csig=$(grep -E "${zip_regex%$}\.csig$" <<<"${existing_assets}" | head -n1 || true)

if [[ -z "${existing_zip}" || -z "${existing_csig}" ]]; then
  echo -e "Assets with \`${build_flavor}\` flavor are missing. Proceeding with build..."
  decide true
fi

if [[ "${FORCE_UPDATE:-false}" != "true" ]]; then
  echo -e "::notice::Asset with \`${build_flavor}\` flavor already exists. Nothing to do."
  decide false
fi

# FORCE_UPDATE is enabled: rebuild the current GrapheneOS version only if a
# module got an update since the commit that built the existing asset.
# The commit hash is part of the asset name, see generate_ota_info.
last_commit=$(sed -E 's/^.*-([0-9a-f]{7,40})(-dirty)?\.zip$/\1/' <<<"${existing_zip}")

if ! git cat-file -e "${last_commit}^{commit}" 2>/dev/null; then
  echo -e "Commit \`${last_commit}\` from asset \`${existing_zip}\` is unknown. Proceeding with rebuild..."
  echo "FORCE_REBUILD=true" >>"${GITHUB_ENV:-/dev/null}"
  decide true
fi

module_changes=$(git diff "${last_commit}" HEAD -- src/declarations.sh | grep -E '^[+-]VERSION\[' || true)
if [[ -z "${module_changes}" ]]; then
  echo -e "No module updates since \`${last_commit}\`. Skipping rebuild..."
  decide false
fi

echo -e "Module updates since \`${last_commit}\`:\n${module_changes}\nProceeding with rebuild..."
echo "FORCE_REBUILD=true" >>"${GITHUB_ENV:-/dev/null}"
decide true
