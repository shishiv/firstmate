#!/usr/bin/env bash
# Stop the chrome-devtools-axi browser bridges one task started.
#
# Usage: fm-task-browser-stop.sh <task-id>
#
# A chrome-devtools-axi bridge is a detached process group leader that owns its
# chrome-devtools-mcp server and the headless browser it drives, so it survives
# the worker that started it and keeps hundreds of megabytes alive after the
# task is gone. bin/fm-teardown.sh calls this once the task's endpoint is closed.
#
# Ownership is proved, never guessed from a name or a folder. Every ship and
# scout launch exports FM_TASK_INBOX=<physical state dir>/<task-id>.inbox
# (bin/fm-spawn.sh), a value unique to this home and this task, and the bridge
# inherits the environment of the worker that started it. A bridge is this
# task's only when it is a process of this user whose own command runs
# chrome-devtools-axi-bridge.js (or .ts), which leads its own process group, and
# whose environment carries that exact FM_TASK_INBOX line. A bridge the captain,
# the main session, another task, or another home started never carries it, even
# when it runs in the same folder, so the working directory is deliberately not
# evidence.
#
# Each proved bridge is stopped through the tool's own `chrome-devtools-axi stop`
# when the session's PID file (under the bridge's HOME and
# CHROME_DEVTOOLS_AXI_SESSION) names that exact pid, because stop acts on
# whatever bridge the PID file names. Otherwise, or when stop leaves it running,
# the bridge gets TERM, which runs its own shutdown, and then KILL on its group
# while the leader's identity still matches. The MCP server, its watchdog, and
# the browser run in process groups of their own and do not inherit
# FM_TASK_INBOX, so the bridge's descendants are recorded by parent link before
# the stop, and any that outlive it as the same process get TERM, then KILL.
#
# The scan needs a /proc with readable cmdline, stat, and environ files. Where
# there is none (macOS) it prints one warning and checks nothing. Prints one
# line per bridge stopped or left running and exits 0 either way, so cleanup
# never fails over a browser; exit 2 is a usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
TASK_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 2; }

[ "$#" -eq 1 ] || usage
case "$1" in -h|--help|help) usage ;; esac
ID=$1
fm_pr_task_id_valid "$ID" || { echo "error: task id is invalid: $ID" >&2; exit 2; }

PROC=${FM_PROC_ROOT_OVERRIDE:-/proc}
if [ ! -r "$PROC/$$/environ" ] || [ ! -r "$PROC/$$/cmdline" ]; then
  echo "warning: cannot read process environments here; browser bridges $ID may have started were not checked" >&2
  exit 0
fi
STATE_REAL=$(cd "$TASK_STATE" 2>/dev/null && pwd -P) || {
  echo "warning: cannot resolve $ID's state directory; browser bridges were not checked" >&2
  exit 0
}
MARKER="FM_TASK_INBOX=$STATE_REAL/$ID.inbox"

proc_env_value() {  # <pid> <name>
  tr '\0' '\n' < "$PROC/$1/environ" 2>/dev/null | sed -n "s/^$2=//p" | head -1
}

proc_has_marker() {  # <pid>
  tr '\0' '\n' < "$PROC/$1/environ" 2>/dev/null | grep -Fxq -- "$MARKER"
}

proc_pgid() {  # <pid>
  local stat
  local -a fields
  IFS= read -r stat < "$PROC/$1/stat" 2>/dev/null || return 1
  # After the final comm delimiter: state ppid pgrp ...
  read -r -a fields <<< "${stat##*)}"
  printf '%s\n' "${fields[2]-}"
}

proc_is_bridge() {  # <pid>
  local a0='' a1='' a2=''
  {
    IFS= read -r -d '' a0
    IFS= read -r -d '' a1
    IFS= read -r -d '' a2
  } < "$PROC/$1/cmdline" 2>/dev/null
  : "$a0"
  case "${a1##*/}" in chrome-devtools-axi-bridge.js|chrome-devtools-axi-bridge.ts) return 0 ;; esac
  case "${a2##*/}" in chrome-devtools-axi-bridge.js|chrome-devtools-axi-bridge.ts) return 0 ;; esac
  return 1
}

proc_alive_as() {  # <pid> <identity>
  [ -e "$PROC/$1" ] || return 1
  [ "$(fm_pid_identity "$1" 2>/dev/null || true)" = "$2" ]
}

wait_gone() {  # <pid> <identity> <tenths>
  local i=0
  while [ "$i" -lt "$3" ]; do
    proc_alive_as "$1" "$2" || return 0
    sleep 0.1
    i=$((i + 1))
  done
  ! proc_alive_as "$1" "$2"
}

tool_stop() {  # <pid>
  local pid=$1 home session port pidfile recorded
  home=$(proc_env_value "$pid" HOME)
  session=$(proc_env_value "$pid" CHROME_DEVTOOLS_AXI_SESSION)
  port=$(proc_env_value "$pid" CHROME_DEVTOOLS_AXI_PORT)
  [ -n "$session" ] || session=default
  case "$home" in /*) ;; *) return 1 ;; esac
  if [ "$session" = default ]; then
    pidfile="$home/.chrome-devtools-axi/bridge.pid"
  else
    case "$session" in *[!A-Za-z0-9._-]*|.|..) return 1 ;; esac
    pidfile="$home/.chrome-devtools-axi/sessions/$session/bridge.pid"
  fi
  recorded=$(perl -MJSON::PP -e '
    open my $f, "<", $ARGV[0] or exit 1; local $/;
    my $d = eval { decode_json(<$f>) } or exit 1;
    print $d->{pid} // "";
  ' "$pidfile" 2>/dev/null) || return 1
  [ "$recorded" = "$pid" ] || return 1
  command -v chrome-devtools-axi >/dev/null 2>&1 || return 1
  if command -v timeout >/dev/null 2>&1; then
    HOME=$home CHROME_DEVTOOLS_AXI_SESSION=$session CHROME_DEVTOOLS_AXI_PORT=$port \
      timeout 20 chrome-devtools-axi stop >/dev/null 2>&1
  else
    HOME=$home CHROME_DEVTOOLS_AXI_SESSION=$session CHROME_DEVTOOLS_AXI_PORT=$port \
      chrome-devtools-axi stop >/dev/null 2>&1
  fi
}

# Every descendant of <pid>, by parent links, as "pid identity" lines. The
# bridge's MCP server, its telemetry watchdog, and the browser each lead or join
# their own process groups and do not inherit FM_TASK_INBOX, so the parent
# chain from the proved bridge is the only evidence that ties them to it.
descendants_of() {  # <pid>
  local dir pid stat ppid queue current identity
  local -a fields
  local links=''
  for dir in "$PROC"/[0-9]*; do
    pid=${dir##*/}
    [ -O "$dir/stat" ] || continue
    IFS= read -r stat < "$dir/stat" 2>/dev/null || continue
    read -r -a fields <<< "${stat##*)}"
    ppid=${fields[1]-}
    links+="$ppid $pid"$'\n'
  done
  queue=$1
  while [ -n "$queue" ]; do
    current=${queue%% *}
    if [ "$current" = "$queue" ]; then queue=''; else queue=${queue#* }; fi
    while read -r ppid pid; do
      [ "$ppid" = "$current" ] || continue
      identity=$(fm_pid_identity "$pid" 2>/dev/null) || continue
      printf '%s %s\n' "$pid" "$identity"
      queue="${queue:+$queue }$pid"
    done <<< "$links"
  done
}

stop_bridge() {  # <pid>
  local pid=$1 identity how=stop children child child_identity i
  identity=$(fm_pid_identity "$pid" 2>/dev/null) || return 0
  children=$(descendants_of "$pid")
  tool_stop "$pid" || how=signal
  if ! wait_gone "$pid" "$identity" 50; then
    how=signal
    kill -TERM "$pid" 2>/dev/null || true
    if ! wait_gone "$pid" "$identity" 30; then
      proc_alive_as "$pid" "$identity" && kill -KILL -- "-$pid" 2>/dev/null
      wait_gone "$pid" "$identity" 20 || true
    fi
  fi
  # A graceful stop closes the browser itself; anything it left behind that is
  # still the same process gets TERM, then KILL.
  for i in TERM KILL; do
    while read -r child child_identity; do
      [ -n "$child" ] || continue
      proc_alive_as "$child" "$child_identity" && kill "-$i" "$child" 2>/dev/null
    done <<< "$children"
    [ "$i" = KILL ] || sleep 1
  done
  if proc_alive_as "$pid" "$identity"; then
    echo "warning: browser bridge $pid that $ID started is still running" >&2
  else
    echo "teardown: stopped browser bridge $pid that $ID started (via $how)" >&2
  fi
}

for dir in "$PROC"/[0-9]*; do
  pid=${dir##*/}
  [ "$pid" != "$$" ] || continue
  [ -O "$dir/environ" ] || continue
  proc_is_bridge "$pid" || continue
  [ "$(proc_pgid "$pid" 2>/dev/null)" = "$pid" ] || continue
  proc_has_marker "$pid" || continue
  stop_bridge "$pid"
done
exit 0
