#!/usr/bin/env bash

FM_CUSTOM_CHECK_HASH=
FM_CUSTOM_CHECK_SNAPSHOT=

fm_custom_check_sha256() {
  local file=$1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

fm_custom_check_trust_read() {
  local state=$1 id=$2 trust state_device version hash
  FM_CUSTOM_CHECK_HASH=
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  trust="$state/$id.check-trust"
  fm_pr_private_file_valid "$trust" 600 "$state_device" || return 1
  exec 9< "$trust" || return 1
  IFS= read -r version <&9 || { exec 9<&-; return 1; }
  IFS= read -r hash <&9 || { exec 9<&-; return 1; }
  if IFS= read -r _extra <&9; then
    exec 9<&-
    return 1
  fi
  exec 9<&-
  [ "$version" = fm-custom-check-v1 ] || return 1
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  FM_CUSTOM_CHECK_HASH=$hash
}

fm_custom_check_registered() {
  local state=$1 id=$2 check hash state_device
  check="$state/$id.check.sh"
  fm_custom_check_trust_read "$state" "$id" || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  fm_pr_private_file_valid "$check" 700 "$state_device" || return 1
  hash=$(fm_custom_check_sha256 "$check") || return 1
  [ "$hash" = "$FM_CUSTOM_CHECK_HASH" ]
}

fm_custom_check_snapshot_prepare() {
  local state=$1 id=$2 check hash state_device
  fm_custom_check_snapshot_cleanup
  check="$state/$id.check.sh"
  fm_custom_check_trust_read "$state" "$id" || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  fm_pr_private_file_valid "$check" 700 "$state_device" || return 1
  FM_CUSTOM_CHECK_SNAPSHOT=$(mktemp "$state/.fm-custom-check.XXXXXX") || return 1
  cp "$check" "$FM_CUSTOM_CHECK_SNAPSHOT" || { fm_custom_check_snapshot_cleanup; return 1; }
  chmod 0600 "$FM_CUSTOM_CHECK_SNAPSHOT" || { fm_custom_check_snapshot_cleanup; return 1; }
  [ -f "$FM_CUSTOM_CHECK_SNAPSHOT" ] && [ ! -L "$FM_CUSTOM_CHECK_SNAPSHOT" ] \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  [ "$(fm_pr_file_mode "$FM_CUSTOM_CHECK_SNAPSHOT")" = 600 ] \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  [ "$(fm_pr_file_device "$FM_CUSTOM_CHECK_SNAPSHOT")" = "$state_device" ] \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  [ "$(fm_pr_file_link_count "$FM_CUSTOM_CHECK_SNAPSHOT")" = 1 ] \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  hash=$(fm_custom_check_sha256 "$FM_CUSTOM_CHECK_SNAPSHOT") \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  [ "$hash" = "$FM_CUSTOM_CHECK_HASH" ] || { fm_custom_check_snapshot_cleanup; return 1; }
}

fm_custom_check_snapshot_cleanup() {
  [ -z "$FM_CUSTOM_CHECK_SNAPSHOT" ] || rm -f -- "$FM_CUSTOM_CHECK_SNAPSHOT"
  FM_CUSTOM_CHECK_SNAPSHOT=
}

# --- trusted poll-check shim arming ------------------------------------------
# One owner for the arm path every self-arming checker shares
# (bin/fm-mail-check.sh, bin/fm-tool-update-check.sh, bin/fm-usage-warner.sh,
# bin/fm-startup-growth-check.sh). A caller sets STATE, CHECK_ID, CHECK_SHIM,
# and REGISTER_BIN, then calls fm_check_shim_arm.
#
# The shim embeds the home already resolved, because the watcher runs it from
# its own working directory and a relative spelling would send the check to a
# different home, or to none at all.
FM_CHECK_SHIM_TMP=
FM_CHECK_SHIM_BACKUP=

fm_check_shim_content() {  # <resolved-home> <check-script> [comment line...]
  local home=$1 script=$2
  shift 2
  printf '%s\n' '#!/usr/bin/env bash' "$@" \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$script") check"
}

# The guards run before anything is written, so a symlink at the shim path is
# refused instead of followed, and the bytes arrive by rename so the watcher
# never reads a half-written shim and rejects it as unauthenticated.
# shellcheck disable=SC2153  # STATE is the caller's documented global
fm_check_shim_write() {  # <wanted-bytes> <tmp-prefix>
  local want=$1 prefix=$2 device
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  FM_CHECK_SHIM_TMP=$(umask 077; mktemp "$STATE/$prefix.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$want" > "$FM_CHECK_SHIM_TMP" \
    || ! chmod 0700 "$FM_CHECK_SHIM_TMP" \
    || ! fm_pr_private_file_valid "$FM_CHECK_SHIM_TMP" 700 "$device" \
    || ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$FM_CHECK_SHIM_TMP" "$CHECK_SHIM"; then
    rm -f -- "$FM_CHECK_SHIM_TMP"
    FM_CHECK_SHIM_TMP=
    return 1
  fi
  FM_CHECK_SHIM_TMP=
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

# Keep a byte copy of a shim that is already in place, so a failed arm can put
# back the shim a working home was already using rather than an equivalent
# rewrite.
fm_check_shim_backup() {  # <tmp-prefix>
  local prefix=$1 device tmp
  FM_CHECK_SHIM_BACKUP=
  [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ] || return 0
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/$prefix.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  FM_CHECK_SHIM_BACKUP=$tmp
}

# An unregistered shim is not inert: the watcher rejects it on every cycle and
# wakes firstmate about unauthenticated state checks. So a failed or
# interrupted arm never leaves the home holding a shim without a matching trust
# binding: an already-bound shim is put back, otherwise the shim goes, so the
# home is plainly not armed. The trust record belongs to bin/fm-check-register.sh
# and disarm, so rollback never touches it.
fm_check_shim_rollback() {
  [ -z "$FM_CHECK_SHIM_TMP" ] || rm -f -- "$FM_CHECK_SHIM_TMP"
  FM_CHECK_SHIM_TMP=
  if [ -n "$FM_CHECK_SHIM_BACKUP" ]; then
    mv -f -- "$FM_CHECK_SHIM_BACKUP" "$CHECK_SHIM" 2>/dev/null || rm -f -- "$FM_CHECK_SHIM_BACKUP"
    FM_CHECK_SHIM_BACKUP=
    if fm_custom_check_registered "$STATE" "$CHECK_ID"; then
      return 0
    fi
  fi
  rm -f -- "$CHECK_SHIM"
}

# shellcheck disable=SC2329  # Registered by fm_check_shim_arm's signal trap.
fm_check_shim_interrupted() {  # <program-name>
  fm_check_shim_rollback
  printf '%s: arming was interrupted, so state/%s.check.sh is not armed\n' "$1" "$CHECK_ID" >&2
  exit 1
}

# Back up, write, and register the shim, then print the armed line. On
# failure it rolls back, names the failed step on stderr, and returns 1. An
# interrupt rolls back and exits 1.

fm_check_shim_arm() {  # <program-name> <resolved-home> <wanted-bytes> <tmp-prefix>
  local name=$1 home=$2 want=$3 prefix=$4 failed=
  if ! fm_check_shim_backup "$prefix"; then
    printf '%s: could not save the existing %s\n' "$name" "$CHECK_SHIM" >&2
    return 1
  fi
  # The shim exists unbound from the rename until the register returns, so a
  # signal in that window rolls back the same way a failure does.
  # shellcheck disable=SC2064  # bind the program name now
  trap "fm_check_shim_interrupted $(printf '%q' "$name")" HUP INT TERM
  if ! fm_check_shim_write "$want" "$prefix"; then
    failed='write'
  elif ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    failed='register'
  fi
  trap - HUP INT TERM
  if [ -n "$failed" ]; then
    fm_check_shim_rollback
    printf '%s: could not %s %s\n' "$name" "$failed" "$CHECK_SHIM" >&2
    return 1
  fi
  [ -z "$FM_CHECK_SHIM_BACKUP" ] || rm -f -- "$FM_CHECK_SHIM_BACKUP"
  FM_CHECK_SHIM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}
