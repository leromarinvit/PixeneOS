#!/usr/bin/env bash

# release.yml sources src/main.sh and reads OUTPUTS[PATCHED_OTA] and
# GRAPHENEOS[OTA_TARGET] out of the sourcing shell. Left unset, the release is
# published with no assets and the update info file points at one that does not
# exist. No other gate can see that, so assert it here.

set -o nounset -o pipefail -o errexit

# Inside the checkout, so `git rev-parse` in generate_ota_info still resolves.
# Absolute, because the trap has to fire after this script has cd'd into it
scratch=$(mktemp -d -p "${PWD}")
trap 'rm -rf "${scratch}"' EXIT

cp -r src "${scratch}/src"

# Replace the network and patching steps, keep the assignments they make
cat >>"${scratch}/src/util_functions.sh" <<'STUBS'
function get_latest_version() {
  VERSION[GRAPHENEOS]="00000000"
  VERSION[MAGISK]="v0.0"
  GRAPHENEOS[OTA_TARGET]="${DEVICE_NAME}-ota_update-${VERSION[GRAPHENEOS]}"
}
function check_and_download_dependencies() { :; }
function create_and_make_release() { generate_ota_info; }
STUBS

cd "${scratch}"
DEVICE_NAME="bluejay" INTERACTIVE_MODE="false" . src/main.sh

if [[ -z "${OUTPUTS[PATCHED_OTA]}" || -z "${GRAPHENEOS[OTA_TARGET]}" ]]; then
  echo "::error::Sourcing \`src/main.sh\` left OUTPUTS[PATCHED_OTA] or GRAPHENEOS[OTA_TARGET] unset; release.yml reads both from the sourcing shell."
  exit 1
fi

echo "ok   sourcing src/main.sh exports ${OUTPUTS[PATCHED_OTA]}"
