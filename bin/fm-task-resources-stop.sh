#!/usr/bin/env bash
# Release the machine resources one finished task still holds.
#
# Usage: fm-task-resources-stop.sh <task-id>
#
# bin/fm-teardown.sh calls this once the task's work is proved landed and its
# endpoint is closed. Four things outlive a worker that is gone, each released
# here by exact ownership and never by a name pattern:
#
#   1. Processes the task started (dev servers, watchers, anything backgrounded).
#      Every launch exports FM_TASK_INBOX=<physical state dir>/<task-id>.inbox
#      (bin/fm-spawn.sh) and every descendant inherits it, so a process of this
#      user whose own environment carries that exact line is this task's of this
#      home. Another task, another home, the main session, and the captain never
#      carry it. Those processes get TERM, then KILL once the grace period ends
#      while the same process (pid and start time) still stands. This process,
#      its ancestors, and pid 1 are never signalled. Where /proc is unreadable
#      (macOS) one warning is printed and nothing is checked.
#   2. The Docker Compose project named fm-<task-id> (lowercased, only
#      [a-z0-9_-] kept, as Compose names it). It is brought down with
#      `docker compose -p <project> down`: containers and networks go, named
#      volumes and images stay, because the command never carries -v or --rmi.
#      Only containers labelled with exactly that project are looked at.
#   3. The task's big folders, from config/task-cleanup-dirs. One template per
#      line, blank lines and `#` comments ignored. A template is an absolute
#      path or one starting with `~/`, and `{id}` must appear in its last path
#      component only; the folder removed is that template with the task id
#      filled in, by its exact path and never by a glob. A folder that does not
#      exist is not an error, and a symlink is refused rather than followed. A
#      home without the file removes nothing. Example:
#        /var/tmp/fm-{id}
#        ~/.cache/fm-lloegrys-{id}
#      Shared build caches are never removed, whatever a template expands to:
#      a folder that is, contains, or lies inside /var/tmp/fm-cliente-base or
#      ~/.cache/lloegrys is refused. Docker volumes are never touched here.
#   4. The Kiro Crew chat of a kirocrew worker, named in
#      state/<id>.kirocrew-slot. bin/fm-kirocrew-run.mjs closes it when it
#      exits, but a killed program or a pane that was already gone leaves it
#      open in the captain's Crew. It is closed through bin/fm-kirocrew.mjs,
#      which treats a chat Crew no longer has as closed. Crew keeps the
#      transcript of a closed chat.
#
# Best effort: it prints one line per thing released or left, exits 0 either
# way so cleanup never fails over a leak, and exits 2 on a usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
TASK_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

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

# --- 1. processes the task started -------------------------------------------

proc_has_marker() {  # <pid> <marker>
  tr '\0' '\n' 2>/dev/null < "$PROC/$1/environ" | grep -Fxq -- "$2"
}

proc_ppid() {  # <pid>
  local stat
  local -a fields
  IFS= read -r stat 2>/dev/null < "$PROC/$1/stat" || return 1
  read -r -a fields <<< "${stat##*)}"
  printf '%s\n' "${fields[1]-}"
}

# This process and every ancestor, so a cleanup run from inside the task's own
# process tree can never signal the shell that is running it.
protected_pids() {
  local pid=$$ hops=0
  while [ -n "$pid" ] && [ "$pid" != 0 ] && [ "$hops" -lt 64 ]; do
    printf '%s\n' "$pid"
    pid=$(proc_ppid "$pid") || break
    hops=$((hops + 1))
  done
}

proc_alive_as() {  # <pid> <identity>
  [ -e "$PROC/$1" ] || return 1
  [ "$(fm_pid_identity "$1" 2>/dev/null || true)" = "$2" ]
}

stop_marked_processes() {
  local state_real marker dir pid identity entry protected stopped=0 survivors=0 i
  local -a found=()
  if [ ! -r "$PROC/$$/environ" ]; then
    echo "warning: cannot read process environments here; processes $ID started were not checked" >&2
    return 0
  fi
  state_real=$(cd "$TASK_STATE" 2>/dev/null && pwd -P) || {
    echo "warning: cannot resolve $ID's state directory; processes it started were not checked" >&2
    return 0
  }
  marker="FM_TASK_INBOX=$state_real/$ID.inbox"
  protected=$(protected_pids)
  for dir in "$PROC"/[0-9]*; do
    pid=${dir##*/}
    [ "$pid" != 1 ] || continue
    [ -O "$dir/environ" ] || continue
    case $'\n'"$protected"$'\n' in *$'\n'"$pid"$'\n'*) continue ;; esac
    proc_has_marker "$pid" "$marker" || continue
    identity=$(fm_pid_identity "$pid" 2>/dev/null) || continue
    found+=("$pid"$'\t'"$identity")
  done
  [ "${#found[@]}" -gt 0 ] || return 0
  for entry in "${found[@]}"; do
    pid=${entry%%$'\t'*}
    kill -TERM "$pid" 2>/dev/null || true
  done
  for i in $(seq 1 30); do
    survivors=0
    for entry in "${found[@]}"; do
      proc_alive_as "${entry%%$'\t'*}" "${entry#*$'\t'}" && survivors=$((survivors + 1))
    done
    [ "$survivors" -eq 0 ] && break
    sleep 0.1
  done
  for entry in "${found[@]}"; do
    pid=${entry%%$'\t'*}
    if proc_alive_as "$pid" "${entry#*$'\t'}"; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done
  sleep 0.1
  for entry in "${found[@]}"; do
    if proc_alive_as "${entry%%$'\t'*}" "${entry#*$'\t'}"; then
      echo "warning: process ${entry%%$'\t'*} that $ID started is still running" >&2
    else
      stopped=$((stopped + 1))
    fi
  done
  [ "$stopped" -eq 0 ] || echo "teardown: stopped $stopped process(es) that $ID started" >&2
}

# --- 2. the task's Compose project -------------------------------------------

stop_compose_project() {
  local project containers
  command -v docker >/dev/null 2>&1 || return 0
  project=$(printf 'fm-%s' "$ID" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -cd 'a-z0-9_-')
  containers=$(docker ps -a -q --filter "label=com.docker.compose.project=$project" 2>/dev/null) || {
    echo "warning: cannot ask docker for Compose project $project; it was not checked" >&2
    return 0
  }
  [ -n "$containers" ] || return 0
  if command -v timeout >/dev/null 2>&1; then
    timeout 180 docker compose -p "$project" down --timeout 20 >/dev/null 2>&1
  else
    docker compose -p "$project" down --timeout 20 >/dev/null 2>&1
  fi
  if [ -n "$(docker ps -a -q --filter "label=com.docker.compose.project=$project" 2>/dev/null)" ]; then
    echo "warning: Compose project $project of $ID is still up" >&2
  else
    echo "teardown: brought down Compose project $project (volumes kept)" >&2
  fi
}

# --- 3. the task's big folders -----------------------------------------------

# Shared build caches no task cleanup may remove or empty.
protected_paths() {
  printf '%s\n' /var/tmp/fm-cliente-base "${HOME:-/nonexistent}/.cache/lloegrys"
}

physical_path() {  # <path>; the path with every existing symlink resolved
  local dir base
  if [ -d "$1" ]; then
    (cd "$1" 2>/dev/null && pwd -P)
    return
  fi
  dir=$(dirname -- "$1")
  base=$(basename -- "$1")
  dir=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "${dir%/}" "$base"
}

# True when <path> is, contains, or lies inside a protected cache.
touches_protected() {  # <physical-path>
  local path=$1 kept
  while IFS= read -r kept; do
    [ -n "$kept" ] || continue
    for kept in "$kept" "$(physical_path "$kept" 2>/dev/null || true)"; do
      [ -n "$kept" ] || continue
      case "$path/" in "${kept%/}/"*) return 0 ;; esac
      case "${kept%/}/" in "$path/"*) return 0 ;; esac
    done
  done < <(protected_paths)
  return 1
}

# A template is usable only when it can name nothing but one folder per task.
expand_template() {  # <template>; prints the path or returns 1
  local tpl=$1 path parent last
  case "$tpl" in
    \~/*) [ -n "${HOME:-}" ] || return 1; tpl="$HOME/${tpl#\~/}" ;;
    /*) ;;
    *) return 1 ;;
  esac
  case "$tpl" in *'{id}'*) ;; *) return 1 ;; esac
  last=${tpl##*/}
  parent=${tpl%/*}
  case "$last" in *'{id}'*) ;; *) return 1 ;; esac
  case "$parent" in *'{id}'*|*'*'*|*'?'*|*'['*|*'..'*) return 1 ;; esac
  case "$last" in *'*'*|*'?'*|*'['*) return 1 ;; esac
  [ -n "$parent" ] || return 1
  path="$parent/${last//\{id\}/$ID}"
  case "$path" in *'{'*|*'}'*|*$'\n'*) return 1 ;; esac
  printf '%s\n' "$path"
}

remove_task_dir() {  # <path>
  local path=$1 real
  if [ -L "$path" ]; then
    echo "warning: $path is a symlink; $ID's folder there was left alone" >&2
    return 0
  fi
  [ -e "$path" ] || return 0
  if [ ! -d "$path" ] || [ ! -O "$path" ]; then
    echo "warning: $path is not a folder of this user; it was left alone" >&2
    return 0
  fi
  real=$(physical_path "$path") || return 0
  case "$real" in /|"${HOME:-/nonexistent}"|"${HOME:-/nonexistent}/") return 0 ;; esac
  if touches_protected "$real" || touches_protected "$path"; then
    echo "warning: $path is or holds a shared build cache; it was left alone" >&2
    return 0
  fi
  chmod -R u+w -- "$path" 2>/dev/null || true
  if rm -rf -- "$path" && [ ! -e "$path" ]; then
    echo "teardown: removed $path" >&2
  else
    echo "warning: could not remove $path" >&2
  fi
}

remove_task_dirs() {
  local file="$CONFIG/task-cleanup-dirs" line path
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$line" ] || continue
    if ! path=$(expand_template "$line"); then
      echo "warning: ignored task-cleanup-dirs entry '$line': it must be an absolute path or ~/ path with {id} in its last component only" >&2
      continue
    fi
    remove_task_dir "$path"
  done < "$file"
}

# --- 4. the task's Kiro Crew chat --------------------------------------------

close_kirocrew_chat() {
  local file="$TASK_STATE/$ID.kirocrew-slot" chat out
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  chat=$(tr -d '[:space:]' < "$file")
  [ -n "$chat" ] || return 0
  if ! command -v node >/dev/null 2>&1; then
    echo "warning: node is not on PATH; Kiro Crew chat $chat of $ID was not closed" >&2
    return 0
  fi
  if out=$(node "$SCRIPT_DIR/fm-kirocrew.mjs" close --home "$FM_HOME" --config-dir "$CONFIG" \
      --state-dir "$TASK_STATE" --slot "$chat" 2>&1); then
    echo "teardown: Kiro Crew chat $chat of $ID is closed (Crew keeps its transcript)" >&2
  else
    echo "warning: Kiro Crew chat $chat of $ID may still be open: ${out#fm-kirocrew: }" >&2
  fi
}

stop_marked_processes
stop_compose_project
remove_task_dirs
close_kirocrew_chat
exit 0
