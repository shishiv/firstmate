# shellcheck shell=bash
# fm-sha256-lib.sh - the one SHA-256 file digest helper. No side effects on
# source. bin/fm-remote-entrypoint.sh keeps its own PATH-free copy on purpose:
# it runs before any library is trusted on a remote host.

# Print the lowercase hex SHA-256 of <path>. Return 1, printing nothing, when
# the file cannot be read or neither shasum nor sha256sum is installed.
fm_sha256_file() {  # <path>
  local digest
  if command -v shasum >/dev/null 2>&1; then
    read -r digest _ < <(shasum -a 256 "$1" 2>/dev/null) || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    read -r digest _ < <(sha256sum "$1" 2>/dev/null) || return 1
  else
    return 1
  fi
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$digest"
}
