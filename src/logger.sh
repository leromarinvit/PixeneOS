#!/usr/bin/env bash

# ---
# LOGGING
# Provides simple, timestamped logging functions.
# Messages may contain escape sequences such as `\n`, `%b` renders them.
# ---

# Usage: log "Doing something..."
function log() {
  printf "[%s] [INFO] -- %b\n" "$(date +"%Y-%m-%d %T")" "${1}"
}

# Renders a message to stderr, as a workflow annotation under GitHub Actions so
# that it lands on the run and not only in the log. An annotation is one line,
# so newlines are encoded as `%0A`.
function _notify() {
  local level="${1}" label="${2}" message
  printf -v message '%b' "${3}"

  if [[ -z "${GITHUB_ACTIONS:-}" ]]; then
    printf "[%s] [%s] -- %s\n" "$(date +"%Y-%m-%d %T")" "${label}" "${message}" >&2
    return
  fi

  message="${message%"${message##*[![:space:]]}"}" # Annotations render trailing blanks

  # Actions decodes %25, %0D and %0A in annotation text, so encode them; the
  # percent has to go first or it would escape the ones added after it
  message="${message//%/%25}"
  message="${message//$'\r'/%0D}"
  printf "::%s::%s\n" "${level}" "${message//$'\n'/%0A}" >&2
}

# Prints a warning message to stderr.
# Usage: warn "Something looks off."
function warn() {
  _notify warning WARN "${1}"
}

# Prints an error message to stderr.
# Usage: error "Something went wrong."
function error() {
  _notify error ERROR "${1}"
}
