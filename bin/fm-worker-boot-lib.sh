#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034 # Probe output globals are read by sourcing callers.
# fm-worker-boot-lib.sh - bring back the ships and scouts a restart left
# without their agent. Source only; the caller defines STATE, FM_HOME, and
# SCRIPT_DIR. bin/fm-bootstrap.sh owns the session-start sweep that drives it,
# next to the secondmate liveness sweep.
#
# After a machine restart every terminal comes back holding only a shell. A
# secondmate is relaunched by its own liveness sweep; a ship or scout was left
# for the captain's supervisor to find and relaunch by hand. This library is
# the decision and the guarded relaunch for those workers.
#
# A worker is relaunched only when all of these hold, so a wrong "dead" reading
# can never open a second agent beside a live one or wake work that is waiting
# on someone else:
#   - it is a local ship or scout whose local copy still exists;
#   - its recorded endpoint reads exactly `dead` (an agent-free shell). The
#     states `ambiguous`, `unreadable`, `missing`, and `unverified` never count;
#   - its current state is work or a declared machine wait: a working verdict
#     from bin/fm-crew-state.sh (a running pipeline step or a busy pane), a
#     paused verdict, or, when the dead terminal leaves crew-state with no
#     source, a status log whose current line is `working:` or `paused:`.
#     Done, blocked, failed, a parked gate, a ready PR, and a decision held for
#     the captain all stay as they are;
#   - this boot has not already tried it. The durable record is
#     `$STATE/.worker-boot-relaunch-<id>`, one tab-separated `<epoch> <row>` line
#     per `attempt`, then `relaunched` or `failed`, the same ledger shape as
#     `.secondmate-relaunch-<id>`. An attempt at or after the boot epoch means
#     tried; where the kernel gives no boot epoch the window is
#     FM_WORKER_BOOT_WINDOW_SECS (default 21600).
# The relaunch itself is `bin/fm-control.sh <id> relaunch --note`, the control
# plane's transactional path, so its checkpoint, journal, and rollback apply.
# bin/fm-teardown.sh removes the ledger with the worker's other records.

FM_WORKER_BOOT_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# shellcheck source=bin/fm-backend.sh
. "$FM_WORKER_BOOT_LIB_DIR/fm-backend.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$FM_WORKER_BOOT_LIB_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$FM_WORKER_BOOT_LIB_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-meta-lib.sh
. "$FM_WORKER_BOOT_LIB_DIR/fm-meta-lib.sh"

FM_WORKER_BOOT_NOTE='The machine restarted and your terminal came back holding only a shell, so this is a replacement agent in the same local copy. Your instructions, the copy with every uncommitted change, and your status log are exactly as you left them. Read the last lines of your status log and run git status, then carry on from where you stopped. Do not start the task over.'

fm_worker_boot_ledger_path() {  # <id>
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  printf '%s/.worker-boot-relaunch-%s\n' "$STATE" "$1"
}

fm_worker_boot_ledger_add() {  # <id> <attempt|relaunched|failed>
  local ledger
  ledger=$(fm_worker_boot_ledger_path "$1") || return 1
  printf '%s\t%s\n' "$(date +%s)" "$2" >> "$ledger" 2>/dev/null
}

# Wall-clock epoch of the current boot from the kernel; nonzero when unknown.
fm_worker_boot_epoch() {
  local boot
  if [ -r /proc/stat ]; then
    boot=$(awk '$1 == "btime" { print $2; exit }' /proc/stat 2>/dev/null)
  elif [ "$(uname -s)" = Darwin ]; then
    boot=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/^{ sec = \([0-9][0-9]*\),.*/\1/p')
  fi
  case "${boot-}" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$boot"
}

# 0 when the ledger holds an attempt row from this boot.
fm_worker_boot_tried_this_boot() {  # <id>
  local ledger since window
  ledger=$(fm_worker_boot_ledger_path "$1") || return 0
  [ -e "$ledger" ] || [ -L "$ledger" ] || return 1
  [ -f "$ledger" ] && [ ! -L "$ledger" ] || return 0
  if ! since=$(fm_worker_boot_epoch); then
    window=${FM_WORKER_BOOT_WINDOW_SECS:-21600}
    case "$window" in ''|*[!0-9]*) window=21600 ;; esac
    since=$(( $(date +%s) - window ))
  fi
  awk -F '\t' -v since="$since" '$1 ~ /^[0-9]+$/ && $1 >= since && $2 == "attempt" { found = 1 } END { exit found ? 0 : 1 }' "$ledger"
}

# The worker's current state, as one word: working, paused, or other.
# crew-state is authoritative whenever it names a source. With a dead terminal
# and no pipeline run it reports `unknown` ("agent gone, pane shell remains"),
# and only then does the status log's current line stand in for it.
fm_worker_boot_state_word() {  # <id> <kind>
  local id=$1 kind=$2 line state src log_line verb
  line=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_CREW_STATE_NO_FORGE=1 \
    "${FM_CREW_STATE_BIN:-$FM_WORKER_BOOT_LIB_DIR/fm-crew-state.sh}" "$id" 2>/dev/null) || true
  case "$line" in state:*) ;; *) printf 'other'; return 0 ;; esac
  state=${line#state: }; state=${state%% *}
  src=${line#*source: }; src=${src%% *}
  case "$state" in
    working)
      case "$src" in run-step|pane) printf 'working'; return 0 ;; esac
      printf 'other'
      ;;
    paused) printf 'paused' ;;
    unknown)
      log_line=$(status_current_line "$STATE/$id.status" "$kind")
      verb=$(status_line_verb "$log_line")
      if status_is_paused "$log_line"; then
        printf 'paused'
      elif [ "$verb" = working ]; then
        printf 'working'
      else
        printf 'other'
      fi
      ;;
    *) printf 'other' ;;
  esac
}

# fm_worker_boot_probe <meta> <id>
#
# Read-only decision for one task record. Sets FM_WB_VERDICT (relaunch | skip)
# and FM_WB_REASON, the one-line cause of a skip.
fm_worker_boot_probe() {
  local meta=$1 id=$2 kind wt backend target state family harness word
  FM_WB_VERDICT=skip FM_WB_REASON=''
  kind=$(fm_meta_get "$meta" kind)
  [ -n "$kind" ] || kind=ship
  case "$kind" in
    ship|scout) ;;
    *) FM_WB_REASON="a $kind is not a worker"; return 0 ;;
  esac
  if [ -n "$(fm_meta_get "$meta" remote_host)" ]; then
    FM_WB_REASON='its agent runs on another host'
    return 0
  fi
  wt=$(fm_meta_get "$meta" worktree)
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    FM_WB_REASON='its local copy is gone'
    return 0
  fi
  if ! fm_backend_validate_task_endpoint "$meta" "$id" >/dev/null 2>&1; then
    FM_WB_REASON='its endpoint record does not validate'
    return 0
  fi
  backend=$FM_BACKEND_VALIDATED_BACKEND
  target=$FM_BACKEND_VALIDATED_TARGET
  state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null) || state=unreadable
  if [ "$state" != dead ]; then
    FM_WB_REASON="its endpoint reads $state, not dead"
    return 0
  fi
  harness=$(fm_meta_get "$meta" harness)
  if ! family=$(fm_control_harness_family "$harness") \
    || ! fm_control_harness_supports_kind "$family" "$kind" \
    || ! fm_control_backend_relaunch_supported "$backend"; then
    FM_WB_REASON="the control plane has no verified relaunch for harness '$harness' on $backend"
    return 0
  fi
  if fm_worker_boot_tried_this_boot "$id"; then
    FM_WB_REASON='this boot already tried it'
    return 0
  fi
  word=$(fm_worker_boot_state_word "$id" "$kind")
  case "$word" in
    working|paused) FM_WB_VERDICT=relaunch ;;
    *) FM_WB_REASON='it is not mid-work or on a machine wait' ;;
  esac
  return 0
}

# fm_worker_boot_relaunch <id>
#
# Acts on a `relaunch` verdict: ledger an attempt, run the control plane's
# relaunch, ledger the outcome. Prints the control plane's output; returns its
# status, or 1 when the attempt could not be recorded (nothing is relaunched
# without its ledger row). The caller owns reporting.
fm_worker_boot_relaunch() {
  local id=$1 rc=0
  fm_worker_boot_ledger_add "$id" attempt || return 1
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "${FM_CONTROL_BIN:-$FM_WORKER_BOOT_LIB_DIR/fm-control.sh}" "$id" relaunch --note "$FM_WORKER_BOOT_NOTE" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    fm_worker_boot_ledger_add "$id" relaunched || true
  else
    fm_worker_boot_ledger_add "$id" failed || true
  fi
  return "$rc"
}
