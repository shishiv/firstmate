#!/usr/bin/env bash
# shellcheck shell=bash
# fm-primary-launch-lib.sh - the durable record of how this home's primary was
# launched, for whatever restarts the primary after the machine reboots.
# Source only; it has no source-time side effects.
#
# After a restart nothing remembers which harness the primary ran in, which
# terminal it occupied, or what command started it: bin/fm-primary-endpoint-lib.sh
# keeps a record for the Kiro doorbell only, and only a Kiro primary writes it.
# This record is written by bin/fm-session-start.sh for every harness, by the
# one session that holds the fleet lock, and read by whatever relaunches the
# primary (a boot script types `command` into `target`).
#
# Record: state/.primary-launch, exactly these lines:
#   schema=fm-primary-launch.v1
#   harness=<the primary's harness, from bin/fm-harness.sh>
#   backend=<tmux|herdr|hc|rex|t3code>
#   target=<the backend target of the terminal the primary runs in>
#   pid=<the fleet-lock pid, the primary's own process>
#   command=<that process's argv as one shell line, every word single-quoted>
#   root=<absolute Firstmate code root>
#   home=<absolute effective Firstmate home>
#   written=<epoch>
#
# The backend and target come from the same structural discovery the supervision
# daemon uses (bin/fm-supervisor-target-lib.sh); a session that cannot be placed
# in a terminal that way writes nothing and leaves any earlier record alone, so
# a stray session can never overwrite the record of the real primary. `command`
# is the process's own argv, so a flag the captain launched with is kept. The
# record is replaced atomically and holds no secret: the environment is never
# read.

FM_PRIMARY_LAUNCH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$FM_PRIMARY_LAUNCH_LIB_DIR/fm-supervisor-target-lib.sh"
# shellcheck source=bin/fm-shell-quote-lib.sh
. "$FM_PRIMARY_LAUNCH_LIB_DIR/fm-shell-quote-lib.sh"

fm_primary_launch_path() {  # <state-dir>
  printf '%s/.primary-launch' "${1%/}"
}

# The argv of <pid> as one shell line, every word single-quoted. Linux reads the
# NUL-separated /proc record; elsewhere `ps` gives the line unquoted, which is
# the best a platform without it can offer.
fm_primary_launch_command() {  # <pid>
  local pid=$1 word line='' sep=''
  if [ -r "/proc/$pid/cmdline" ]; then
    while IFS= read -r -d '' word; do
      line="$line$sep$(fm_shell_quote "$word")"
      sep=' '
    done < "/proc/$pid/cmdline"
    [ -n "$line" ] || return 1
    printf '%s' "$line"
    return 0
  fi
  line=$(ps -o args= -p "$pid" 2>/dev/null) || return 1
  [ -n "$line" ] || return 1
  printf '%s' "$line"
}

# fm_primary_launch_publish <state-dir> <root> <home> <harness>
#
# Writes the record for the process that holds this home's fleet lock. Returns 1
# without touching the record when the lock pid is not a live process, the
# terminal cannot be discovered structurally, or any field would be unsafe.
fm_primary_launch_publish() {
  local state=$1 root=$2 home=$3 harness=$4 pid backend target command tmp path
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  case "$harness" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  pid=$(cat "$state/.lock" 2>/dev/null) || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  backend=$(discover_supervisor_backend) || return 1
  target=$(discover_supervisor_target) || return 1
  case "$backend$target" in ''|*$'\n'*|*$'\r'*|*[![:print:]]*) return 1 ;; esac
  command=$(fm_primary_launch_command "$pid") || return 1
  case "$command" in *$'\n'*|*$'\r'*) return 1 ;; esac
  path=$(fm_primary_launch_path "$state")
  tmp=$(mktemp "$state/.primary-launch.XXXXXX") || return 1
  {
    printf 'schema=fm-primary-launch.v1\n'
    printf 'harness=%s\n' "$harness"
    printf 'backend=%s\n' "$backend"
    printf 'target=%s\n' "$target"
    printf 'pid=%s\n' "$pid"
    printf 'command=%s\n' "$command"
    printf 'root=%s\n' "$root"
    printf 'home=%s\n' "$home"
    printf 'written=%s\n' "$(date +%s)"
  } > "$tmp"
  if ! mv -f "$tmp" "$path"; then
    rm -f "$tmp"
    return 1
  fi
}
