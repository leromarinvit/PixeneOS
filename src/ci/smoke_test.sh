#!/usr/bin/env bash

# Verify that every download URL the project constructs still resolves.
# Catches renamed release assets and version drift before a release run does.

set -o nounset -o pipefail -o errexit

source src/util_functions.sh

FAILED=0

function check_url() {
  local name="${1}"
  local url="${2}"
  local status

  # `|| true` keeps errexit from ending the run, a failed request reports as 000
  status=$(curl -sIL --max-time 30 --retry 2 -o /dev/null -w '%{http_code}' "${url}" || true)
  if [[ "${status}" == "200" ]]; then
    echo "ok   ${name}: ${url}"
  else
    echo "::error::FAIL ${name} (HTTP ${status}): ${url}"
    FAILED=1
  fi
}

# Read the device configuration
check_toml_env

# Every configured device, so a fork that sets only `DEVICES` is covered too
device_list=$(parse_devices)
mapfile -t devices < <(cut -d: -f1 <<<"${device_list}" | sort -u)

# The GrapheneOS version is per device; the tool and Magisk versions are not, so
# one pass resolves everything the checks below need
declare -a ota_urls=()
for DEVICE_NAME in "${devices[@]}"; do
  get_latest_version
  ota_urls+=("${GRAPHENEOS[OTA_URL]}")
done

# Tools and modules from declarations
tool_list=$(supported_tools "cdd")
IFS=' ' read -r -a tools_array <<<"${tool_list}"

for tool in "${tools_array[@]}"; do
  # `my-avbroot-setup` is a git repository, cloning is checked elsewhere
  if [[ "${tool}" == "my-avbroot-setup" ]]; then
    continue
  fi

  construct_url "${tool}"
  check_url "${tool}" "${URL}"
  check_url "${tool}.sig" "${SIGNATURE_URL}"
done

# Magisk APK from the latest tag of the configured repository
check_url "magisk" "${DOMAIN}/${MAGISK[REPOSITORY]}/releases/download/${VERSION[MAGISK]}/Magisk-${VERSION[MAGISK]}.apk"

# The GrapheneOS OTA is per device
for index in "${!devices[@]}"; do
  check_url "grapheneos-ota (${devices[index]})" "${ota_urls[index]}"
done

exit "${FAILED}"
