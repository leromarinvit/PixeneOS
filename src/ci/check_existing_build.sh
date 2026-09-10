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
# `.assets[]?` keeps the script alive when the tag has no release
existing_assets=$(curl -sL "${repo_url}" | jq -r '.assets[]?.name')

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
