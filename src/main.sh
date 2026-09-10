#!/usr/bin/env bash

# This project is highly dependent on chenxiaolong's projects.
# Project PixeneOS needs to be up-to-date with chenxiaolong's projects

# make code more robust by catching unset variables, detecting errors in pipelines, and halting execution upon encountering errors
set -o nounset -o pipefail -o errexit

source src/fetcher.sh
source src/util_functions.sh

# Build one device and flavor, given `device`, `preinit` and `root`. Assigning
# every per entry value here is what keeps one entry out of the next.
# release.yml sources this script for OUTPUTS[PATCHED_OTA] and
# GRAPHENEOS[OTA_TARGET], so the build has to leave them set in this shell.
function build_entry() {
  DEVICE_NAME="${1}"
  MAGISK[PREINIT]="${2}"
  ADDITIONALS[ROOT]="${3}"

  # Resolved per device: get_latest_version keeps whatever is already set
  VERSION[GRAPHENEOS]=""

  # Fetch the latest version of GrapheneOS and Magisk
  get_latest_version
  # Check for requirements and download them accordingly
  check_and_download_dependencies
  # Patch the OTA, sign it
  create_and_make_release
}

function main() {
  if [[ "${INTERACTIVE_MODE}" == "true" ]]; then
    log "Running in interactive mode...\n"
    check_toml_env
  fi

  local entry device preinit root flavor entry_list
  local -a entries=()

  # Assigned on its own line: a process substitution would hide a failure to
  # expand the list from errexit, and `local x=$(...)` would mask it too
  entry_list=$(parse_devices)
  mapfile -t entries <<<"${entry_list}"

  for entry in "${entries[@]}"; do
    IFS=':' read -r device preinit root <<<"${entry}"
    flavor=$([[ "${root}" == 'true' ]] && echo 'magisk' || echo 'rootless')
    log "Building \`${device}\` (${flavor})...\n"

    build_entry "${device}" "${preinit}" "${root}"

    # One update info file per flavor, they would otherwise overwrite each other
    if [[ ${#entries[@]} -gt 1 && -f "${device}.json" ]]; then
      mv "${device}.json" "${device}-${flavor}.json"
    fi
  done
}

main "$@"
