#!/usr/bin/env bash

# Contains the functions to fetch the required files. In short, this takes care of downloading the OTA, Magisk, and other dependencies.

source src/declarations.sh

# Fetch the latest version of GrapheneOS and Magisk and sets up the OTA URL
function get_latest_version() {
  local latest_grapheneos_version
  local latest_magisk_version

  # Without a device the release URL resolves to a 404 page that then becomes
  # the version string, so fail here rather than build a nonsense OTA URL
  if [[ -z "${DEVICE_NAME}" ]]; then
    error "Missing required param \`DEVICE_NAME\`.\n"
    return 1
  fi

  # Check the status code: `-f` fails the same way on every status over 400 and
  # would call a 503 a device with no release. A transport failure is 000.
  # Kept out of a pipeline too: a pipe reports sed's status, and whether curl's
  # survives would depend on the caller having set pipefail
  local raw http_status
  raw=$(curl -sL --max-time 30 --retry 2 --write-out '\n%{http_code}' \
    "${GRAPHENEOS[OTA_BASE_URL]}/${DEVICE_NAME}-${GRAPHENEOS[UPDATE_CHANNEL]}") || true
  http_status="${raw##*$'\n'}"
  latest_grapheneos_version=$(sed 's/ .*//' <<<"${raw%$'\n'*}")

  case "${http_status}" in
  200) ;;
  404)
    error "No GrapheneOS release for \`${DEVICE_NAME}\` on the \`${GRAPHENEOS[UPDATE_CHANNEL]}\` channel.\n"
    return 1
    ;;
  *)
    error "Could not read the release list for \`${DEVICE_NAME}\` (HTTP ${http_status}).\n"
    return 1
    ;;
  esac

  # A release is a ten digit date, and anything else would go on to name an
  # asset and a tag
  if [[ ! "${latest_grapheneos_version}" =~ ^[0-9]{10}$ ]]; then
    error "Unexpected GrapheneOS version for \`${DEVICE_NAME}\`: \`${latest_grapheneos_version}\`.\n"
    return 1
  fi
  # Annotated tags produce an extra `<tag>^{}` entry that must not become the version
  latest_magisk_version=$(
    git ls-remote --tags "${DOMAIN}/${MAGISK[REPOSITORY]}.git" |
      awk -F'\t' '{print $2}' |
      grep -E 'refs/tags/' |
      grep -v '\^{}$' |
      sed 's/refs\/tags\///' |
      sort -V |
      tail -n1
  )

  if [[ "${GRAPHENEOS[UPDATE_TYPE]}" == "install" ]]; then
    error "The update type is set to \`install\` which is not supported by AVBRoot.\nExiting..."
    exit 1
  fi

  # Construct the URLs
  GRAPHENEOS[OTA_TARGET]="${DEVICE_NAME}-${GRAPHENEOS[UPDATE_TYPE]}-${latest_grapheneos_version}"
  # e.g. https://releases.grapheneos.org/bluejay-stable
  GRAPHENEOS[OTA_URL]="${GRAPHENEOS[OTA_BASE_URL]}/${GRAPHENEOS[OTA_TARGET]}.zip"

  # e.g.  bluejay-ota_update-2024080200
  log "GrapheneOS OTA target: \`${GRAPHENEOS[OTA_TARGET]}\`\nGrapheneOS OTA URL: ${GRAPHENEOS[OTA_URL]}\n"

  if [[ -z "${VERSION[GRAPHENEOS]}" ]]; then
    VERSION[GRAPHENEOS]="${GRAPHENEOS_VERSION:-${latest_grapheneos_version}}"
  fi

  if [[ -z "${latest_magisk_version}" ]]; then
    error "Failed to get the latest Magisk version."
    exit 1
  else
    VERSION[MAGISK]="${latest_magisk_version}"
  fi
}

# Getter function to download the magisk, modules, signatures and tools
function get() {
  local filename="${1}"
  local url="${2}"
  local signature_url="${3:-}"

  log "Downloading \`${filename}\`..."

  # `my-avbroot-setup` is a special case as it is a git repository
  if [[ "${filename}" == "my-avbroot-setup" ]]; then
    git clone "${url}" "${WORKDIR}/tools/${filename}" && git -C "${WORKDIR}/tools/${filename}" checkout "${VERSION[AVBROOT_SETUP]}"
  else
    if [[ "${filename}" == "magisk" ]]; then
      suffix="apk"
    else
      suffix="zip"
    fi

    # Download the files directly to modules directory
    curl -sLf "${url}" --output "${WORKDIR}/modules/${filename}.${suffix}"

    if [[ "${filename}" != "my-avbroot-setup" ]]; then
      # Download signatures
      if [ -n "${signature_url}" ]; then
        log "Downloading signature for \`${filename}\`..."
        curl -sLf "${signature_url}" --output "${WORKDIR}/signatures/${filename}.zip.sig"
      fi

      # afsr, avbroot and custota-tool are binaries that need to be extracted and granted permissions
      if [[ "${filename}" == "afsr" || "${filename}" == "avbroot" || "${filename}" == "custota-tool" ]]; then
        log "Extracting and granting permissions for \`${filename}\`..."
        echo N | unzip -q -o "${WORKDIR}/modules/${filename}.zip" -d "${WORKDIR}/tools/${filename}"
        chmod +x "${WORKDIR}/tools/${filename}/${filename}"

        log "Cleaning up..."
        rm "${WORKDIR}/modules/${filename}.zip"
      fi
    fi
  fi
  log "\`${filename}\` downloaded."
}

# Function to check and download the dependencies
function download_ota() {
  local ota="${WORKDIR}/${GRAPHENEOS[OTA_TARGET]}.zip"

  # Set the URLs if not set
  if [ -z "${GRAPHENEOS[OTA_URL]}" ]; then
    get_latest_version
  fi

  # Download if not downloaded already
  if [ ! -f "${ota}" ]; then
    log "Downloading OTA from: ${GRAPHENEOS[OTA_URL]}...\nPlease be patient while the download happens."
    # Downloaded beside the target and moved into place only once it is whole:
    # without `-f` an error page becomes the zip, and a run killed part way
    # through leaves a partial one that the check above then treats as downloaded
    if ! curl -sLf --retry 2 "${GRAPHENEOS[OTA_URL]}" --output "${ota}.part"; then
      rm -f "${ota}.part"
      error "Failed to download the OTA from \`${GRAPHENEOS[OTA_URL]}\`.\n"
      return 1
    fi
    mv "${ota}.part" "${ota}"
    log "OTA downloaded to: \`${ota}\`\n"
  else
    log "OTA is already downloaded in: \`${ota}\`\n"
  fi
}
