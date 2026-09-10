#!/usr/bin/env bash

# This script is a part of the main script and is responsible for the utility functions used in the main script.

source src/declarations.sh
source src/exchange.sh
source src/fetcher.sh
source src/verifier.sh

# Function to check and download the dependencies
# This function checks for the required tools and downloads them if not found depending on the configuration done in the declarations file
function check_and_download_dependencies() {
  make_directories

  # Check for Python requirements
  if ! command -v python3 &>/dev/null; then
    error "Python 3 is required to run this script.\nExiting..."
    exit 1
  fi

  # Check if retry config is enabled
  if [[ "${ADDITIONALS[RETRY]}" == "true" ]]; then
    RETRY="true"
  else
    RETRY="false"
  fi

  # Check for required tools
  # If they're present, continue with the script
  # Else, download them by checking version from declarations
  tools=$(supported_tools "cdd") # Call the function and capture its output

  # Convert the space-separated string back into an array
  IFS=' ' read -r -a tools_array <<<"${tools}"

  for tool in "${tools_array[@]}"; do
    local flag
    flag=$(flag_check "${tool}")

    if [[ "${flag}" == 'false' ]]; then
      log "\`${tool}\` is **NOT** enabled in the configuration.\nSkipping...\n"
      continue
    fi

    if [ -f "${WORKDIR}/modules/${tool}.zip" ]; then
      log "\`${tool}.zip\` file already exists in \`${WORKDIR}/modules\`."
      continue
    fi

    if [ -d "${WORKDIR}/tools/${tool}" ]; then
      log "\`${tool}\` file already exists in \`${WORKDIR}/tools\`."
      continue
    fi

    RETRY_COUNT=0 # Reset retry count for each tool
    while true; do
      # Download the tool and verify the download
      download_dependencies "${tool}"
      verify_downloads "${tool}"
      [[ "${ADDITIONALS[RETRY]}" == "true" ]] && [[ "${RETRY}" == "true" ]] || break
    done
  done

  # Retry logic for magisk
  if [[ "${ADDITIONALS[ROOT]}" == 'true' ]]; then
    RETRY_COUNT=0 # Reset retry count for magisk
    while true; do
      # Magisk is an exception as it is an APK and hence we do the get call directly and verify
      URL="${DOMAIN}/${MAGISK[REPOSITORY]}/releases/download/${VERSION[MAGISK]}/Magisk-${VERSION[MAGISK]}.apk"
      log "URL for \`magisk\`: ${URL}"
      get "magisk" "${URL}"
      verify_downloads "magisk"

      [[ "${ADDITIONALS[RETRY]}" == "true" ]] && [[ "${RETRY}" == "true" ]] || break
    done
  fi
}

# Function to check the flag status
# If flag for a tool is disabled, it is not downloaded
function flag_check() {
  local tool="${1}"
  local tool_upper_case
  tool_upper_case=$(echo "${tool}" | tr '[:lower:]' '[:upper:]')

  if [[ "${tool}" == "my-avbroot-setup" ]]; then
    FLAG="${ADDITIONALS[MY_AVBROOT_SETUP]}"
  elif [[ "${tool}" == "custota-tool" ]]; then
    FLAG="${ADDITIONALS[CUSTOTA_TOOL]}"
  else
    FLAG="${ADDITIONALS[$tool_upper_case]}"
  fi

  if [[ "${FLAG}" == 'true' ]]; then
    echo 'true'
  else
    echo 'false'
  fi
}

# Function to create and make the release called by main script
function create_and_make_release() {
  if [[ ! -d $WORKDIR ]]; then
    warn "$WORKDIR is non-existent. Downloading the tools..."

    # Check for requirements and download them accordingly
    check_and_download_dependencies
  fi

  # Calls the download_ota function to download the OTA if not found
  download_ota
  # Calls the create_ota function to create the OTA
  create_ota
}

function create_ota() {
  # Generate output file names
  generate_ota_info
  # Setup environment variables and paths
  env_setup
  # Patch OTA with avbroot and afsr by leveraging my-avbroot-setup
  patch_ota
}

# Remove the work directory and drop the decoded keys, when CLEANUP is true
function cleanup() {
  if [[ "${CLEANUP:-false}" != 'true' ]]; then
    log "Cleanup is disabled. Exiting...\n"
    return
  fi

  log "Cleaning up..."
  rm -rf "${WORKDIR}"
  # Emptied rather than unset, which would drop the associative attribute
  KEYS=()
  log "Cleanup complete."
}

# Generate the AVB and OTA signing keys.
# Has to be called manually.
function generate_keys() {
  # Generate the AVB and OTA signing keys
  avbroot key generate-key -o "${KEYS[AVB]}"
  avbroot key generate-key -o "${KEYS[OTA]}"

  # Convert the public key portion of the AVB signing key to the AVB public key metadata format
  # This is the format that the bootloader requires when setting the custom root of trust
  # Flash it with: fastboot flash avb_custom_key <file>
  avbroot key encode-avb -k "${KEYS[AVB]}" -o "${KEYS[PKMD]}"

  # Generate a self-signed certificate for the OTA signing key
  # This is used by recovery to verify OTA updates when sideloading
  avbroot key generate-cert -k "${KEYS[OTA]}" -o "${KEYS[CERT_OTA]}"

  # Convert the keys to base64 which can be used in CI/CD pipeline environment
  base64_encode
}

# Function to patch the OTA with the AVB and OTA keys
# Leverages `my-avbroot-setup` to patch the OTA
# This function does a lot of things before patching the OTA
function patch_ota() {
  if [[ "${INTERACTIVE_MODE}" != 'true' ]]; then
    base64_decode
  fi

  # Set the paths
  local ota_zip="${WORKDIR}/${GRAPHENEOS[OTA_TARGET]}"
  # Extracted per device: the official keys differ between them, and a shared
  # path would leave one device verified against another's
  local extracted="${WORKDIR}/extracted/${DEVICE_NAME}"
  local grapheneos_pkmd="${extracted}/avb_pkmd.bin"
  local grapheneos_otacert="${extracted}/otacert"
  local magisk_path="${WORKDIR}/modules/magisk.apk"
  local my_avbroot_setup="${WORKDIR}/tools/my-avbroot-setup"

  # Activate the virtual environment
  if [ -z "${VIRTUAL_ENV}" ]; then
    enable_venv
  fi

  # Size, not existence: an empty key would otherwise be reused for every
  # later build of this device
  if [[ ! -s "${grapheneos_pkmd}" || ! -s "${grapheneos_otacert}" ]]; then
    log "Extracting official keys..."
    extract_official_keys "${extracted}"
  fi

  if [[ -f "${OUTPUTS[PATCHED_OTA]}" ]]; then
    log "File ${OUTPUTS[PATCHED_OTA]} already exists in local. Patch skipped."
  else
    log "Patching OTA..."
    local args=()

    # OTA input and output
    args+=("--input" "${ota_zip}.zip")
    args+=("--output" "${OUTPUTS[PATCHED_OTA]}")

    # GrapheneOS public key metadata and certificate
    args+=("--verify-public-key-avb" "${grapheneos_pkmd}")
    args+=("--verify-cert-ota" "${grapheneos_otacert}")

    # PixeneOS decoded keys and certificates
    args+=("--sign-key-avb" "${KEYS[AVB]}")
    args+=("--sign-key-ota" "${KEYS[OTA]}")
    args+=("--sign-cert-ota" "${KEYS[CERT_OTA]}")

    # Passphrases for AVB and OTA keys
    args+=("--pass-avb-env-var" "PASSPHRASE_AVB")
    args+=("--pass-ota-env-var" "PASSPHRASE_OTA")

    # Modules and their signatures
    # Disabled modules are left out, `patch.py` skips modules without arguments
    local module
    for module in custota msd bcr oemunlockonboot alterinstaller; do
      if [[ "$(flag_check "${module}")" == 'true' ]]; then
        args+=("--module-${module}" "${WORKDIR}/modules/${module}.zip")
        args+=("--module-${module}-sig" "${WORKDIR}/signatures/${module}.zip.sig")
      else
        log "Module \`${module}\` is disabled. Skipping..."
      fi
    done

    # Add support for Magisk if root config is enabled
    if [[ "${ADDITIONALS[ROOT]}" == 'true' ]]; then
      log "Magisk is enabled. Modifying the setup script...\n"
      args+=("--patch-arg=--magisk" "--patch-arg" "${magisk_path}")
      args+=("--patch-arg=--magisk-preinit-device" "--patch-arg" "${MAGISK[PREINIT]}")
    else
      log "Magisk is not enabled. Skipping...\n"
    fi

    # Python command to run the patch script
    python ${my_avbroot_setup}/patch.py "${args[@]}"
  fi

  # Deactivate the virtual environment after patching the OTA
  deactivate
}

# Function to setup the environment for the my-avbroot-setup script
function my_avbroot_setup() {
  # Paths
  local setup_script="${WORKDIR}/tools/my-avbroot-setup/patch.py"
  local magisk_path="${WORKDIR}/modules/magisk.apk"
  local location_path="${DOMAIN}/${GITHUB_USER}/${GITHUB_REPO}/releases/download/${VERSION[GRAPHENEOS]}/${OUTPUTS[PATCHED_OTA]}"

  # Add support to pass env-vars to the setup script for passphrase in the CI/CD pipeline
  log "Running script modifications..."

  # Update location path to use GitHub releases
  # Matches an already injected URL too, so a second device does not keep the
  # first one's
  sed -i -e "s|generate_update_info(update_info, [^)]*)|generate_update_info(update_info, '${location_path}')|" "${setup_script}"
}

# Function to setup the environment variables and paths for patching the OTA
function env_setup() {
  # Set up `my-avbroot-setup` environment
  my_avbroot_setup

  # Paths
  local avbroot="${WORKDIR}/tools/avbroot"
  local afsr="${WORKDIR}/tools/afsr"
  local custota_tool="${WORKDIR}/tools/custota-tool"
  local my_avbroot_setup="${WORKDIR}/tools/my-avbroot-setup"
  local pyproject_file="${my_avbroot_setup}/pyproject.toml"

  # Add the paths to the PATH environment variable just so that the script can find them
  if ! command -v avbroot &>/dev/null && ! command -v afsr &>/dev/null && ! command -v custota-tool &>/dev/null; then
    local tool_paths
    tool_paths="$(realpath "${afsr}"):$(realpath "${avbroot}"):$(realpath "${custota_tool}")"
    export PATH="${tool_paths}:${PATH}"
  fi

  # Enabled python virtual environment
  enable_venv

  # Install required Python packages
  if [[ -f "${pyproject_file}" ]]; then
    if ! command -v uv &>/dev/null; then
      warn "uv not found. Installing..."
      python3 -m pip install uv
    fi

    log "Installing required Python packages from pyproject.toml..."
    uv pip install -r "${pyproject_file}"
  else
    warn "pyproject.toml not found at ${my_avbroot_setup}"
  fi
}

# Function to enable the python virtual environment
function enable_venv() {
  local dir_path='' # Default value is empty string
  local venv_path=''
  local base_path
  base_path=$(basename "$(pwd)")

  # Check presence of venv
  # Create a virtual environment if not found
  if [[ "${base_path}" == "my-avbroot-setup" ]]; then
    if [ ! -d "venv" ]; then
      log "Virtual environment not found. Creating..."
      python3 -m venv venv
    fi
  else
    log "The script is not run from the \`my-avbroot-setup\` directory.\nSearching for the directory..."
    dir_path=$(find . -type d -name "my-avbroot-setup" -print -quit)
    if [ ! -d "${dir_path}/venv" ]; then
      log "Virtual environment not found in path \`${dir_path}\`. Creating..."
      python3 -m venv "${dir_path}/venv"
    fi
  fi

  # Set the virtual environment path
  if [ -n "${dir_path}" ]; then
    venv_path="${dir_path}/venv/bin/activate"
  else
    venv_path="venv/bin/activate"
  fi

  # Ensure venv_path is set correctly and activate the virtual environment
  if [ -f "${venv_path}" ]; then
    # shellcheck source=/dev/null
    source "${venv_path}"
  else
    warn "Virtual environment activation script not found at \`${venv_path}\`."
  fi
}

# Construct download URLs for a tool or module
# Sets URL and SIGNATURE_URL without downloading anything
function construct_url() {
  local repository="${1}"
  local user='chenxiaolong'
  local repository_upper_case
  repository_upper_case=$(echo "${repository}" | tr '[:lower:]' '[:upper:]')

  # `my-avbroot-setup` is git repository
  if [[ "${repository}" == "my-avbroot-setup" ]]; then
    URL="${DOMAIN}/${user}/${repository}"
    SIGNATURE_URL=""
  else
    # Afsr, avbroot, and custota-tool are binaries and are platform dependent. Modules are zipped files.
    if [[ "${repository}" == "afsr" || "${repository}" == "avbroot" || "${repository}" == "custota-tool" ]]; then
      local suffix="${ARCH}"
    else
      local suffix="release"
    fi

    # Custota is a special case
    # Custota is a module and Custota-Tool is a binary
    # Both reside in same repository
    if [[ "${repository}" == "custota-tool" ]]; then
      local download_page="${DOMAIN}/${user}/Custota/releases/download"
      local version="v${VERSION[CUSTOTA]}"
      local application="${repository}-${VERSION[CUSTOTA]}-${suffix}.zip"
    else
      local download_page="${DOMAIN}/${user}/${repository}/releases/download"
      local version="v${VERSION[${repository_upper_case}]}"
      local application="${repository}-${VERSION[${repository_upper_case}]}-${suffix}.zip"
    fi

    URL="${download_page}/${version}/${application}"
    SIGNATURE_URL="${download_page}/${version}/${application}.sig"
  fi
}

# Construct URL for the tools and download them
# This function is called by download_dependencies function when running in non-interactive mode
function url_constructor() {
  local repository="${1}"
  local INTERACTIVE_MODE="${2:-true}"

  log "Constructing URL for \`${repository}\` as \`${repository}\` is non-existent at \`${WORKDIR}\`..."
  construct_url "${repository}"
  log "URL for \`${repository}\`: ${URL}"

  # If the script is running in interactive mode, prompt the user to overwrite the existing files
  if [[ "${INTERACTIVE_MODE}" == 'true' ]]; then
    if [[ -e "${WORKDIR}/tools/${repository}" || -e "${WORKDIR}/modules/${repository}.zip" || -e "${WORKDIR}/signatures/${repository}.zip.sig" ]]; then
      echo -n "Warning: \`${repository}\` already exists in \`${WORKDIR}\`\nOverwrite? (y/n) [default: yes]: "
      read -r confirm
      confirm=${confirm:-"yes"}
      if [[ $confirm =~ ^[yY](es|ES)?$ ]]; then
        log "Removing existing files..."
        rm -rf "${WORKDIR}/tools/${repository}" "${WORKDIR}/modules/${repository}.zip" "${WORKDIR}/signatures/${repository}.zip.sig"
      else
        error "Aborted."
        exit 1
      fi
    fi
  fi

  # Make the get call to download the tools and modules
  get "${repository}" "${URL}" "${SIGNATURE_URL}"
}

# Function to download the dependencies
# This calls the constructor that constructs the URL for the tools and modules
function download_dependencies() {
  local tool="${1}"
  # Local: downloading is non-interactive, but the caller's mode decides how the
  # keys are read later
  local INTERACTIVE_MODE='false'

  if type url_constructor &>/dev/null; then
    url_constructor "${tool}" "${INTERACTIVE_MODE}"
  else
    error "\`url_constructor\` function is not defined."
    exit 1
  fi
}

# Function to extract the official GrapheneOS keys from the OTA
function extract_official_keys() {
  # avbroot reads the certificate out of the OTA's own signature and the key out
  # of the vbmeta image, so `--none` keeps it from unpacking the payload.
  # To confirm the key is official, compare its sha256 against the base16
  # verified boot key fingerprints at
  # https://grapheneos.org/articles/attestation-compatibility-guide
  local extracted="${1:?a per device extraction directory is required}"

  mkdir -p "${extracted}"

  avbroot ota extract \
    --input "${WORKDIR}/${GRAPHENEOS[OTA_TARGET]}.zip" \
    --directory "${extracted}" \
    --none \
    --cert-ota "${extracted}/otacert" \
    --public-key-avb "${extracted}/avb_pkmd.bin"
}

function dirty_suffix() {
  if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    echo "-dirty"
  else
    echo ""
  fi
}

# Function to make directories
function make_directories() {
  mkdir -p \
    "${WORKDIR}" \
    "${WORKDIR}/.keys" \
    "${WORKDIR}/modules" \
    "${WORKDIR}/signatures" \
    "${WORKDIR}/tools"
}

function generate_ota_info() {
  # Detect build flavor
  local flavor
  flavor=$([[ ${ADDITIONALS[ROOT]} == 'true' ]] && echo "magisk-${VERSION[MAGISK]}" || echo "rootless")
  # e.g. bluejay-2024082200-rootless-abc12345-dirty.zip
  OUTPUTS[PATCHED_OTA]="${DEVICE_NAME}-${VERSION[GRAPHENEOS]}-${flavor}-$(git rev-parse --short HEAD)$(dirty_suffix).zip"
}

# Strip leading and trailing whitespace. `xargs` would do it but also applies
# shell quoting, so a value with a quote in it fails or comes back changed
function trim() {
  local value="${1}"
  value="${value#"${value%%[![:space:]]*}"}"
  printf '%s' "${value%"${value##*[![:space:]]}"}"
}

# Expand the configured device list into one normalised `device:preinit:root`
# entry per line, so a CI matrix and a local build agree on what a list means.
# Input entries are `device:preinit:root` with the last two optional; an entry
# that omits root takes ${1}, or `ROOT` from env.toml when that is empty. An
# empty list falls back to the single device DEVICE_NAME describes.
# The output always carries all three fields, so a colon separated read keeps
# them aligned; a tab would not, since bash collapses runs of whitespace
# delimiters.
# Returns 1 on a malformed entry rather than guessing what it meant.
# Usage: parse_devices [root_override] [device_list]
function parse_devices() {
  local default_root="${1:-${ADDITIONALS[ROOT]}}"
  local list="${2:-${DEVICES:-}}"
  local entry device preinit root
  local -a entries=() fields=() parsed=() seen=()

  # A single device setup configures DEVICE_NAME rather than DEVICES
  if [[ -z "${list}" && -n "${DEVICE_NAME}" ]]; then
    list="${DEVICE_NAME}:${MAGISK[PREINIT]}:${default_root}"
  fi

  if [[ -z "${list}" ]]; then
    error "No devices configured. Set \`DEVICES\` or \`DEVICE_NAME\` in \`env.toml\`."
    return 1
  fi

  # `read` stops at the first newline, so a list wrapped across lines would be
  # silently cut short rather than rejected
  list="${list//$'\n'/,}"

  IFS=',' read -ra entries <<<"${list}"
  for entry in "${entries[@]}"; do
    entry=$(trim "${entry}")
    if [[ -z "${entry}" ]]; then
      continue
    fi

    # Fields are trimmed too, so `bluejay:sda8: true` is not silently rootless
    IFS=':' read -ra fields <<<"${entry}"
    if [[ "${#fields[@]}" -gt 3 ]]; then
      error "Entry \`${entry}\` has more than the three \`device:preinit:root\` fields."
      return 1
    fi

    device=$(trim "${fields[0]}")
    preinit=$(trim "${fields[1]:-}")
    root=$(trim "${fields[2]:-}")
    root="${root:-${default_root}}"

    if [[ -z "${device}" ]]; then
      error "Entry without a device name in \`${list}\`."
      return 1
    fi

    # A device name reaches a URL and a path on disk, so keep it to characters
    # that mean nothing to either
    if [[ ! "${device}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
      error "Invalid device name \`${device}\` in \`${list}\`, expected letters, digits, \`_\` or \`-\`."
      return 1
    fi

    # Anything but true or false would quietly pick a flavor for the user
    case "${root}" in
      true | false) ;;
      *)
        error "Invalid root \`${root}\` for \`${device}\`, expected \`true\` or \`false\`."
        return 1
        ;;
    esac

    # Rooted without a preinit patches with an empty `--magisk-preinit-device`.
    # release.yml catches it for its own leg; catching it here covers a local
    # build too
    if [[ "${root}" == 'true' && -z "${preinit}" ]]; then
      error "\`${device}\` is rooted but has no preinit, see the Magisk Preinit section of the README."
      return 1
    fi

    # The output file name is device, version and flavor, so a repeat of the
    # same pair would build once and publish the first entry's preinit twice
    if [[ " ${seen[*]:-} " == *" ${device}:${root} "* ]]; then
      error "\`${device}\` appears twice with root \`${root}\` in \`${list}\`."
      return 1
    fi
    seen+=("${device}:${root}")

    parsed+=("$(printf '%s:%s:%s' "${device}" "${preinit}" "${root}")")
  done

  if [[ ${#parsed[@]} -eq 0 ]]; then
    error "No devices found in \`${list}\`."
    return 1
  fi

  # The preinit partition can only be determined on a real device
  if [[ -n "${MAGISK[PREINIT]}" ]] &&
    [[ $(printf '%s\n' "${parsed[@]}" | cut -d: -f1 | sort -u | wc -l) -gt 1 ]]; then
    warn "\`MAGISK_PREINIT\` is not applied to a multi device list. Give each rooted entry its own preinit, for example \`bluejay:sda8\`."
  fi

  printf '%s\n' "${parsed[@]}"
}

function check_toml_env() {
  declare -A config_vars
  toml_file="env.toml"

  if [ -f "$toml_file" ]; then
    while IFS='=' read -r key value; do
      key=$(echo "$key" | xargs)                                  # Trim whitespace
      value=$(echo "$value" | xargs | sed -E 's/^"([^"]*)"$/\1/') # Trim whitespace and quotes
      if [[ -n "$key" && -n "$value" ]]; then
        config_vars["$key"]="$value"
      fi
    done < <(grep -v '^#' "$toml_file") # Ignore comments

    if [[ ${#config_vars[@]} -gt 0 ]]; then
      log "Found variables in \`${toml_file}\` and will take precedence over other values.\n"
      for key in "${!config_vars[@]}"; do
        echo -e "${key}: ${config_vars[$key]}"
        # printf -v keeps values with spaces or commas intact, eval would split them
        printf -v "${key}" '%s' "${config_vars[$key]}"
      done

      # `ROOT` and `MAGISK_PREINIT` are friendly aliases for the internal variables
      if [[ -n "${config_vars[ROOT]:-}" ]]; then
        ADDITIONALS[ROOT]="${config_vars[ROOT]}"
      fi
      if [[ -n "${config_vars[MAGISK_PREINIT]:-}" ]]; then
        MAGISK[PREINIT]="${config_vars[MAGISK_PREINIT]}"
      fi
    else
      error "Failed to find the required variables in \`${toml_file}\`.\n"
      exit 1
    fi
  fi
}

function supported_tools() {
  local arg="${1:-}"
  local tools=("avbroot" "afsr" "alterinstaller" "custota" "custota-tool" "msd" "bcr" "oemunlockonboot" "my-avbroot-setup")

  if [[ "${arg}" == "cdd" ]]; then
    echo "${tools[@]}"
    return
  fi

  echo -e "Supported tools:"
  for tool in "${tools[@]}"; do
    echo -e "- ${tool}"
  done
  echo -e "- magisk"
}

function help() {
  cat <<EOF
Usage: source src/<file>.sh [functions] [arguments]
functions:
  - url_constructor        Run the URL Constructor function
    - arguments            Supported tool name.
                           Check 'supported_tools' for more info
  - generate_keys          Generate keys
  - help                   Show this help message
  - check_toml_env         Check TOML environment
  - supported_tools        List supported tools
EOF
}
