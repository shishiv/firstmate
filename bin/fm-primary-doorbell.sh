#!/usr/bin/env bash
# fm-primary-doorbell.sh - the watcher arm owner for a doorbell primary.
#
# A Kiro V3 primary has no hook that can hold or continue a turn, so nothing
# inside the harness can own watcher continuity the way the Claude Stop hook,
# the Cursor stop park, or the Pi, omp, and OpenCode extensions do
# (docs/watcher-continuity.md "Ownership"). This script is that owner for the
# primary published in state/.primary-endpoint: one detached process per home
# that keeps exactly one bin/fm-watch-arm.sh cycle running, starts the handling
# successor BEFORE it announces a close, and is the only component that types
# the primary doorbell. The model never arms a watcher on this path.
#
# Per actionable close, in order (the Option B ordering of watcher-continuity):
#   1. start the successor arm with FM_WATCH_PREDECESSOR_ARM_PID=<closed arm>,
#      so the next cycle is a handling successor and never re-announces the
#      downtime the close would otherwise leave behind;
#   2. wait for its status line, and confirm the handling handoff with
#      `bin/fm-watch-arm.sh --handling-delivered <generation> --watcher-pid <pid>`
#      when it names a recovery generation, retrying once; a handoff that
#      still fails while the successor's watcher is gone counts as a failed
#      start (below), and one refused against a live successor still rings;
#   3. ring the doorbell once. Every poll also wants one ring for a newest
#      queued row that no ring covered yet, because a row can be queued without
#      a close of its own. A ring refused because the pane is busy or its
#      composer holds text is retried on every poll for as long as main has
#      something left to present - a queued main row or an unacknowledged
#      recovery episode - and dropped as soon as it has none (the primary
#      handled it inside its own turn). Every ring reloads the endpoint
#      record, so a republished pane is followed.
# A cycle that fails to start never withholds a pending ring, and is retried
# with bounded exponential backoff; when the first failure has been followed by
# FM_PRIMARY_DOORBELL_RETRY_LIMIT failed retries, the owner records
# state/.primary-doorbell-failed, rings one continuity-failure line, and exits.
# `ensure` refuses to restart within FM_PRIMARY_DOORBELL_FAILURE_COOLDOWN
# seconds of that record, so a persistent failure rings at most once per
# cooldown instead of looping; the next verified cycle removes the record.
#
# The owner serves exactly the session the endpoint record names and exits when
# the fleet lock moves to another pid, that pid dies or changes identity, the
# away flag state/.afk appears (the away daemon owns supervision then), or the
# home no longer needs supervision after a close. On every exit it stops its own
# arm child (TERM, then KILL after five seconds), so the next owner or the away
# daemon starts from a published downtime rather than a second live owner.
#
# Usage:
#   fm-primary-doorbell.sh ensure   idempotently start the owner; prints one line:
#     doorbell-owner: started pid=<N>        exit 0
#     doorbell-owner: running pid=<N>        exit 0
#     doorbell-owner: starting - ...         exit 0 (a Kiro Crew primary: the
#                                            doorbell service starts the owner)
#     doorbell-owner: not needed             exit 0 (no supervision need)
#     doorbell-owner: away mode              exit 0 (state/.afk exists)
#     doorbell-owner: unavailable - <why>    exit 3 (no loadable endpoint)
#     doorbell-owner: cooling down - <why>   exit 4 (recent continuity failure)
#     doorbell-owner: unavailable - <why>    exit 5 (a Kiro Crew primary with no
#                                            doorbell service)
#     doorbell-owner: FAILED - <why>         exit 1
#   fm-primary-doorbell.sh run      the owner loop (started by ensure, detached)
#   fm-primary-doorbell.sh serve    the doorbell service of a Kiro Crew primary
#   fm-primary-doorbell.sh unit     print the systemd user unit that runs serve
#
# DOORBELL SERVICE (Kiro Crew). A Kiro primary in a Kiro Crew chat runs its
# hooks inside Crew's sandbox, which keeps them off the user's service manager
# on purpose, and a gateway restart kills the gateway pid the owner serves. So
# `ensure` never forks an owner for a `kirocrew` endpoint. The home's systemd
# user unit (`unit`, installed by bin/fm-kirocrew-setup.sh --primary) runs
# `serve` instead: one process per home (state/.primary-doorbell-service.lock)
# that runs `run` whenever state/.primary-endpoint names a Crew chat that needs
# supervision. Crew gives every gateway process a new generation, also when a
# dashboard restart re-executes the gateway in place under the same pid, so
# the owner exits when the generation changes, and the service then waits for
# Crew to restore the chat and sends the restart line, once per restart
# (state/.primary-doorbell-crew-gen and state/.primary-doorbell-recovery). A
# ring that finds the chat gone under the same gateway process retires the
# record and stops the owner, because the captain closed that chat; a chat
# Crew does not let the firstmate app message records a continuity failure.
#
# SUPERVISION HOST. When the home runs the host (fm_supervision_host_enabled:
# config/supervision-host and no config/supervision-host-off, read at every
# cycle), each cycle runs `bin/fm-supervision-host.sh park` in the arm's
# place, with FM_SUPERVISION_HOST_PRIMARY=kiro-cli and the served pid as
# FM_SUPERVISION_HOST_SERVED_PID, because this owner runs outside the primary's
# process tree and the host proves ownership through the endpoint record
# instead (docs/supervision-host.md). The host prints the arm's status line at
# once and exits only when main is needed. A host close that carries a
# "supervision-host:" line always rings, and every line of that close except
# the status line is appended to state/.primary-doorbell-note, which the
# primary's UserPromptSubmit hook attaches to the doorbell turn and then
# clears; "supervision-host stood down: ..." or a close with nothing actionable
# counts as a failed start. A running host owns delivery, so the row-only ring
# (step 3) is off while it runs; a host that dies (a status above 128, or no
# output) is a failed start whose queued main rows are rung, the failure
# direction the host design gives every wake it cannot finish.
#
# Called by bin/fm-kiro-turnend-hook.sh on SessionStart and on every primary
# UserPromptSubmit and Stop, and by the model only as the one repair command
# the protocol names.
#
# Records (state/): .primary-doorbell.lock (singleton, pid + pid-identity),
# .primary-doorbell-failed (continuity-failure episode: epoch and reason),
# .primary-doorbell-note (supervision-host lines for the next doorbell turn;
# the hook that attaches it prints only its newest 8 KB),
# .primary-doorbell-service.lock (the doorbell service's singleton),
# .primary-doorbell-crew-gen (the Crew chat and the gateway generation it was
# last served under), and .primary-doorbell-recovery (the last restart
# recovery: its generation, outcome, and epoch).
#
# Tunables: FM_PRIMARY_DOORBELL_POLL (seconds between polls, default 1; a
# fraction such as 0.2 is accepted),
# FM_PRIMARY_DOORBELL_READY_TIMEOUT (seconds to wait for an arm's status line,
# default 20), FM_PRIMARY_DOORBELL_RETRY_LIMIT (default 5),
# FM_PRIMARY_DOORBELL_FAILURE_COOLDOWN (default 300), FM_GUARD_GRACE (300),
# FM_PRIMARY_DOORBELL_SERVE_POLL (the service's poll, default 2, fractions
# accepted), FM_PRIMARY_DOORBELL_RECOVER_TIMEOUT (seconds one restart recovery
# may take, default 600), FM_PRIMARY_DOORBELL_RESTORE_GRACE (seconds a recovery
# waits for Crew to restore the chat, default 60), FM_PRIMARY_DOORBELL_CREW_CHECK
# (seconds between two reads of the Crew gateway generation, default 15).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
ARM="$SCRIPT_DIR/fm-watch-arm.sh"
HOST="$SCRIPT_DIR/fm-supervision-host.sh"
NOTE="$STATE/.primary-doorbell-note"
HOST_LINE_RE='^supervision-host:'
OWNER_LOCK="$STATE/.primary-doorbell.lock"
FAILURE_RECORD="$STATE/.primary-doorbell-failed"
SERVICE_LOCK="$STATE/.primary-doorbell-service.lock"
RECOVERY_RECORD="$STATE/.primary-doorbell-recovery"
GEN_RECORD="$STATE/.primary-doorbell-crew-gen"
WAKE_RE='^(signal:|stale:|check:|heartbeat($|:))'

positive_int() {  # <value> <default>
  case "$1" in ''|*[!0-9]*|0) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}
poll_seconds() {  # <value> <default>
  case "$1" in
    [1-9]|[1-9][0-9]|0.[0-9]|0.[0-9][0-9]|[1-9].[0-9]) printf '%s' "$1" ;;
    *) printf '%s' "$2" ;;
  esac
}
POLL=$(poll_seconds "${FM_PRIMARY_DOORBELL_POLL:-}" 1)
SERVE_POLL=$(poll_seconds "${FM_PRIMARY_DOORBELL_SERVE_POLL:-}" 2)
READY_TIMEOUT=$(positive_int "${FM_PRIMARY_DOORBELL_READY_TIMEOUT:-}" 20)
RECOVER_TIMEOUT=$(positive_int "${FM_PRIMARY_DOORBELL_RECOVER_TIMEOUT:-}" 600)
RESTORE_GRACE=$(positive_int "${FM_PRIMARY_DOORBELL_RESTORE_GRACE:-}" 60)
case "${FM_PRIMARY_DOORBELL_CREW_CHECK:-}" in
  ''|*[!0-9]*) CREW_CHECK=15 ;;
  *) CREW_CHECK=$FM_PRIMARY_DOORBELL_CREW_CHECK ;;
esac
RETRY_LIMIT=$(positive_int "${FM_PRIMARY_DOORBELL_RETRY_LIMIT:-}" 5)
FAILURE_COOLDOWN=$(positive_int "${FM_PRIMARY_DOORBELL_FAILURE_COOLDOWN:-}" 300)

[ -d "$STATE" ] || [ "${1:-}" = unit ] || { echo "doorbell-owner: FAILED - state directory $STATE is absent"; exit 1; }

# shellcheck source=bin/fm-primary-endpoint-lib.sh
. "$SCRIPT_DIR/fm-primary-endpoint-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-supervision-engine-lib.sh
. "$SCRIPT_DIR/fm-supervision-engine-lib.sh"

# The live holder of lock dir <lock>, or fail. A lock whose recorded pid is
# dead or whose recorded identity no longer matches is not a live holder.
live_lock_pid() {  # <lock>
  local pid recorded current
  pid=$(cat "$1/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  recorded=$(cat "$1/pid-identity" 2>/dev/null || true)
  current=$(fm_pid_identity "$pid" 2>/dev/null || true)
  [ -n "$recorded" ] && [ "$recorded" = "$current" ] || return 1
  printf '%s' "$pid"
}
live_owner_pid() { live_lock_pid "$OWNER_LOCK"; }
live_service_pid() { live_lock_pid "$SERVICE_LOCK"; }

# fm_lock_try_acquire reclaims a lock whose pid is dead, but treats any live pid
# as the holder. A live pid whose identity no longer matches the recorded one is
# a reused pid, so the lock is removed under the same steal mutex acquire uses,
# after re-checking inside it.
lock_names_reused_pid() {  # <lock>
  local pid recorded current
  pid=$(cat "$1/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  recorded=$(cat "$1/pid-identity" 2>/dev/null || true)
  [ -n "$recorded" ] || return 1
  current=$(fm_pid_identity "$pid" 2>/dev/null || true)
  [ -n "$current" ] && [ "$current" != "$recorded" ]
}

reclaim_reused_lock() {  # <lock>
  lock_names_reused_pid "$1" || return 0
  fm_lock_try_acquire_steal_mutex "$1.steal" || return 0
  if lock_names_reused_pid "$1"; then
    fm_lock_remove_path "$1" || true
  fi
  fm_lock_release "$1.steal"
}

# The systemd user unit that runs `serve` for this home.
service_unit() {
  local tag
  # shellcheck source=bin/fm-backend-hometag-lib.sh
  tag=$(. "$SCRIPT_DIR/fm-backend-hometag-lib.sh" && fm_backend_hometag)
  printf 'fm-doorbell-%s.service' "$tag"
}

failure_cooling_down() {
  local at now
  [ -f "$FAILURE_RECORD" ] || return 1
  IFS= read -r at < "$FAILURE_RECORD" 2>/dev/null || return 1
  at=${at%%[!0-9]*}
  [ -n "$at" ] || return 1
  now=$(date +%s)
  [ $((now - at)) -lt "$FAILURE_COOLDOWN" ]
}

cmd_ensure() {
  local pid i
  if [ -e "$STATE/.afk" ]; then echo "doorbell-owner: away mode"; return 0; fi
  if ! fm_supervision_needed "$STATE" "$GRACE"; then echo "doorbell-owner: not needed"; return 0; fi
  if ! fm_primary_endpoint_load "$STATE" "$FM_ROOT" "$FM_HOME"; then
    echo "doorbell-owner: unavailable - state/.primary-endpoint does not name this home's live lock-owning primary"
    return 3
  fi
  if pid=$(live_owner_pid); then echo "doorbell-owner: running pid=$pid"; return 0; fi
  if failure_cooling_down; then
    echo "doorbell-owner: cooling down - a continuity failure is recorded in $FAILURE_RECORD"
    return 4
  fi
  # A Kiro Crew primary's hooks run inside Crew's sandbox, so its owner is
  # started by the home's doorbell service (`serve`), never forked from here.
  if [ "$FM_PRIMARY_ENDPOINT_BACKEND" = kirocrew ]; then
    if pid=$(live_service_pid); then echo "doorbell-owner: starting - the doorbell service pid=$pid starts the owner"; return 0; fi
    echo "doorbell-owner: unavailable - no doorbell service runs for this home; install it with bin/fm-kirocrew-setup.sh --primary, or start it with: systemctl --user start $(service_unit)"
    return 5
  fi
  command -v setsid >/dev/null 2>&1 || { echo "doorbell-owner: FAILED - setsid is unavailable"; return 1; }
  setsid --fork "$SCRIPT_DIR/fm-primary-doorbell.sh" run </dev/null >/dev/null 2>&1 \
    || { echo "doorbell-owner: FAILED - the owner could not be detached"; return 1; }
  i=0
  while [ "$i" -lt 50 ]; do
    if pid=$(live_owner_pid); then echo "doorbell-owner: started pid=$pid"; return 0; fi
    sleep 0.1
    i=$((i + 1))
  done
  echo "doorbell-owner: FAILED - the owner did not take its lock within 5s"
  return 1
}

# ---- owner loop --------------------------------------------------------------

SERVED_PID=
SERVED_IDENTITY=
CHILD=
CHILD_OUT=
PREDECESSOR=
HANDOFF_PENDING=0
RING_WANTED=0
RING_FORCED=0
CHILD_MODE=arm
RUNG_SEQ=0
RING_KIND=wake
STOP_AFTER_RING=0
FAILURES=0

# Stop the current arm child: TERM, a five-second bound, then KILL, so the lock
# is never released while this owner's arm still runs. A watcher the arm
# started keeps its own singleton lock and is attached to by the next arm.
stop_child() {
  local i=0
  if [ -n "$CHILD" ] && fm_pid_alive "$CHILD"; then
    kill -TERM "$CHILD" 2>/dev/null || true
    while [ "$i" -lt 50 ] && fm_pid_alive "$CHILD"; do sleep 0.1; i=$((i + 1)); done
    fm_pid_alive "$CHILD" && kill -KILL "$CHILD" 2>/dev/null
  fi
  [ -z "$CHILD" ] || wait "$CHILD" 2>/dev/null || true
  [ -z "$CHILD_OUT" ] || rm -f "$CHILD_OUT" 2>/dev/null || true
  CHILD=
  CHILD_OUT=
}

owner_cleanup() {
  trap - EXIT HUP INT TERM
  stop_child
  fm_lock_release "$OWNER_LOCK" 2>/dev/null || true
}

# Cheap every-poll check that the served session still owns the home.
still_serving() {
  [ "$(cat "$STATE/.lock" 2>/dev/null || true)" = "$SERVED_PID" ] || return 1
  [ "$(fm_pid_identity "$SERVED_PID" 2>/dev/null || true)" = "$SERVED_IDENTITY" ] || return 1
  [ ! -e "$STATE/.afk" ]
}

# Main still has something to present: a queued row main can claim, or a
# recovery episode nobody acknowledged. An unreadable marker counts as pending.
main_pending() {
  local count
  count=$(fm_wake_actor_pending_count main)
  [ "$count" -gt 0 ] && return 0
  fm_recovery_marker_snapshot "$STATE/.watcher-down" || return 0
  case "$FM_RECOVERY_MARKER_TOKEN" in pending:*|announced:*) return 0 ;; esac
  return 1
}

# The newest queued sequence, or nothing for an empty or unreadable queue.
newest_queue_seq() {
  local seq
  [ -s "$STATE/.wake-queue" ] || return 1
  seq=$(tail -n 1 -- "$STATE/.wake-queue" 2>/dev/null | cut -f2)
  case "$seq" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$seq"
}

# A row can reach the queue without its own close, for example a result a
# running watcher republishes after surfacing it once, so every poll also wants
# one ring for a newest row no ring or drop has covered yet. A row younger than
# two seconds, or one whose watcher already printed its close, is left to that
# close, so the successor still starts before the ring.
want_ring_for_new_rows() {
  local line at seq
  [ -s "$STATE/.wake-queue" ] || return 0
  line=$(tail -n 1 -- "$STATE/.wake-queue" 2>/dev/null) || return 0
  at=$(printf '%s' "$line" | cut -f1)
  seq=$(printf '%s' "$line" | cut -f2)
  case "$at:$seq" in *[!0-9:]*|:*|*:) return 0 ;; esac
  [ "$seq" -gt "$RUNG_SEQ" ] || return 0
  [ $(( $(date +%s) - at )) -ge 2 ] || return 0
  # A running host owns delivery: it may still be offering this row to its
  # engine, and it exits with the close whenever main is needed.
  if [ "$CHILD_MODE" = host ] && [ -n "$CHILD" ]; then return 0; fi
  if [ -n "$CHILD" ] && grep -qE "$WAKE_RE" "$CHILD_OUT" 2>/dev/null; then return 0; fi
  RING_WANTED=1
}

ring_if_pending() {
  local seq
  seq=$(newest_queue_seq) || seq=$RUNG_SEQ
  if [ "$STOP_AFTER_RING" -eq 0 ] && [ "$RING_FORCED" -eq 0 ] && ! main_pending; then
    RING_WANTED=0
    RUNG_SEQ=$seq
    return 0
  fi
  if ! fm_primary_endpoint_ring_kiro "$STATE" "$FM_ROOT" "$FM_HOME" "$RING_KIND"; then
    case "$FM_PRIMARY_ENDPOINT_RING_RESULT" in
      absent) crew_chat_gone ;;
      forbidden) crew_chat_forbidden ;;
    esac
    return 1
  fi
  RING_WANTED=0
  RING_FORCED=0
  RUNG_SEQ=$seq
}

# ---- Kiro Crew gateway restarts ----------------------------------------------

# The Kiro Crew gateway generation the home's chat was last served under
# (state/.primary-doorbell-crew-gen: <chat> TAB <gen>). Crew gives every gateway
# process a new generation, also when a dashboard restart re-executes the
# gateway in place under the same pid, so a changed generation is the restart
# signal.
recorded_gen() {  # <chat>
  local chat gen
  [ -f "$GEN_RECORD" ] || return 1
  IFS=$'\t' read -r chat gen < "$GEN_RECORD" 2>/dev/null || return 1
  [ "$chat" = "$1" ] && [ -n "$gen" ] || return 1
  printf '%s' "$gen"
}

record_gen() {  # <chat> <gen>
  [ -n "$2" ] || return 0
  if printf '%s\t%s\n' "$1" "$2" > "$GEN_RECORD.$$" 2>/dev/null; then
    mv -f -- "$GEN_RECORD.$$" "$GEN_RECORD" 2>/dev/null || rm -f -- "$GEN_RECORD.$$"
  fi
}

# True when the gateway restarted since the home last served Kiro Crew chat
# <chat>: Crew reports another generation, or, when Crew lists no chat to read
# a generation from, the recorded gateway pid died or changed identity. A first
# sight records the generation. Reads the last fm_primary_endpoint_crew_observe.
crew_restarted() {  # <chat> <gateway-pid> <gateway-identity>
  local was
  if [ -n "$FM_PRIMARY_ENDPOINT_CREW_GEN" ]; then
    if was=$(recorded_gen "$1"); then
      [ "$was" != "$FM_PRIMARY_ENDPOINT_CREW_GEN" ]
      return
    fi
    record_gen "$1" "$FM_PRIMARY_ENDPOINT_CREW_GEN"
    return 1
  fi
  [ "$(fm_pid_identity "$2" 2>/dev/null || true)" != "$3" ]
}

# False when the gateway restarted under the served Kiro Crew chat, checked at
# most every CREW_CHECK seconds; the owner then exits and the doorbell service
# recovers the chat. A gateway that does not answer gives no verdict.
SERVED_CHAT=
CREW_CHECKED_AT=0
crew_still_same() {
  local now
  [ -n "$SERVED_CHAT" ] || return 0
  now=$(date +%s)
  [ $((now - CREW_CHECKED_AT)) -ge "$CREW_CHECK" ] || return 0
  CREW_CHECKED_AT=$now
  fm_primary_endpoint_crew_observe "$STATE" "$FM_HOME" "$SERVED_CHAT" || return 0
  ! crew_restarted "$SERVED_CHAT" "$SERVED_PID" "$SERVED_IDENTITY"
}

# Kiro Crew stopped listing the served chat. Under the same gateway process
# that means the captain closed it, so this owner retires the record and exits;
# a restarted gateway leaves the record to the doorbell service's recovery.
crew_chat_gone() {
  sleep 2
  still_serving || exit 0
  fm_primary_endpoint_crew_observe "$STATE" "$FM_HOME" "$SERVED_CHAT" || return 0
  [ "$FM_PRIMARY_ENDPOINT_CREW_STATE" = absent ] || return 0
  ! crew_restarted "$SERVED_CHAT" "$SERVED_PID" "$SERVED_IDENTITY" || exit 0
  fm_primary_endpoint_retire_crew "$STATE" "$SERVED_CHAT" "$SERVED_PID"
  exit 0
}

# Kiro Crew refuses the firstmate app every message to the served chat, which
# is not the app's own chat or the captain's own (bin/fm-kirocrew.mjs ring).
# No retry changes that, so the owner records a continuity failure, which
# `ensure` and the service respect for the cooldown, and exits.
crew_chat_forbidden() {
  printf '%s\t%s\n' "$(date +%s)" "Kiro Crew does not let the firstmate app message the chat $SERVED_CHAT; open the primary with bin/fm-kirocrew-primary.sh" \
    > "$FAILURE_RECORD" 2>/dev/null || true
  exit 1
}

start_arm() {  # <predecessor-arm-pid>
  CHILD_OUT=$(mktemp "$STATE/.primary-doorbell-arm.XXXXXX") || return 1
  CHILD_MODE=arm
  ! fm_supervision_host_enabled "$CONFIG" kiro-cli || CHILD_MODE=host
  (
    # shellcheck source=/dev/null # Operator-local Relay settings.
    [ ! -f "$CONFIG/x-mode.env" ] || . "$CONFIG/x-mode.env"
    export FM_WATCH_PREDECESSOR_ARM_PID=$1
    if [ "$CHILD_MODE" = host ]; then
      FM_SUPERVISION_HOST_PRIMARY=kiro-cli FM_SUPERVISION_HOST_SERVED_PID=$SERVED_PID exec "$HOST" park
    fi
    exec "$ARM"
  ) </dev/null >"$CHILD_OUT" 2>&1 &
  CHILD=$!
}

# Append a host close to the note the next doorbell turn attaches. The owner
# only ever appends, so a note the hook is taking by rename is never rewritten;
# the hook bounds what it prints.
append_host_note() {
  grep -vE '^watcher: (started|attached) pid=' "$CHILD_OUT" >> "$NOTE" 2>/dev/null || true
}

# Wait for the current arm's first status line. Prints started, attached,
# wake, or failed.
await_ready() {
  local deadline timeout=$READY_TIMEOUT
  # The host verifies its own first cycle before printing the arm's line.
  [ "$CHILD_MODE" != host ] || [ "$timeout" -ge 30 ] || timeout=30
  deadline=$(( $(date +%s) + timeout ))
  while :; do
    if grep -qE "$WAKE_RE|$HOST_LINE_RE" "$CHILD_OUT" 2>/dev/null; then printf 'wake'; return 0; fi
    if grep -q '^watcher: started pid=' "$CHILD_OUT" 2>/dev/null; then printf 'started'; return 0; fi
    if grep -q '^watcher: attached pid=' "$CHILD_OUT" 2>/dev/null; then printf 'attached'; return 0; fi
    if grep -q '^watcher: FAILED' "$CHILD_OUT" 2>/dev/null || ! fm_pid_alive "$CHILD"; then
      printf 'failed'
      return 0
    fi
    [ "$(date +%s)" -lt "$deadline" ] || { printf 'failed'; return 0; }
    sleep 0.1
  done
}

# Returns 1 only when the handoff was refused twice and the successor's watcher
# is gone, which is a failed start rather than a live cycle.
confirm_handoff() {
  local line generation watcher
  line=$(grep -m1 '^watcher: started pid=' "$CHILD_OUT" 2>/dev/null || true)
  case "$line" in *' recovery-generation='*) ;; *) return 0 ;; esac
  generation=${line##* recovery-generation=}
  watcher=${line#watcher: started pid=}
  watcher=${watcher%% *}
  "$ARM" --handling-delivered "$generation" --watcher-pid "$watcher" >/dev/null 2>&1 && return 0
  "$ARM" --handling-delivered "$generation" --watcher-pid "$watcher" >/dev/null 2>&1 && return 0
  fm_pid_alive "$watcher"
}

arm_failed() {  # <reason>
  local delay
  FAILURES=$((FAILURES + 1))
  # A successor that never verifies never withholds a close already seen.
  [ "$RING_WANTED" -eq 0 ] || ring_if_pending || true
  if [ "$FAILURES" -gt "$RETRY_LIMIT" ]; then
    printf '%s\t%s\n' "$(date +%s)" "$1" > "$FAILURE_RECORD" 2>/dev/null || true
    RING_KIND=failure
    RING_WANTED=1
    STOP_AFTER_RING=1
    return 0
  fi
  delay=$((1 << (FAILURES - 1)))
  [ "$delay" -le 4 ] || delay=4
  sleep "$delay"
}

owner_close() {
  local rc=0 reason failed seq
  wait "$CHILD" 2>/dev/null || rc=$?
  if [ "$CHILD_MODE" = host ] && [ "$rc" -le 128 ] \
    && grep -qE "$HOST_LINE_RE" "$CHILD_OUT" 2>/dev/null; then
    append_host_note
    PREDECESSOR=$CHILD
    HANDOFF_PENDING=1
    RING_WANTED=1
    RING_FORCED=1
    rm -f "$CHILD_OUT" 2>/dev/null || true
    CHILD=
    CHILD_OUT=
    return 0
  fi
  reason=$(grep -m1 -E "$WAKE_RE" "$CHILD_OUT" 2>/dev/null || true)
  if [ "$CHILD_MODE" = host ] && { [ "$rc" -gt 128 ] || [ ! -s "$CHILD_OUT" ]; }; then
    reason=
    RING_WANTED=1
  fi
  if [ -n "$reason" ]; then
    PREDECESSOR=$CHILD
    HANDOFF_PENDING=1
    # A close whose rows a ring already covered needs no second ring; a close
    # with no row at all (a recovery episode) is judged by main_pending.
    seq=$(newest_queue_seq) || seq=
    if [ -z "$seq" ] || [ "$seq" -gt "$RUNG_SEQ" ]; then
      RING_WANTED=1
    fi
    rm -f "$CHILD_OUT" 2>/dev/null || true
    CHILD=
    CHILD_OUT=
    return 0
  fi
  failed=$(grep -m1 -E '^(watcher: FAILED|supervision-host stood down:)' "$CHILD_OUT" 2>/dev/null || true)
  rm -f "$CHILD_OUT" 2>/dev/null || true
  CHILD=
  CHILD_OUT=
  arm_failed "${failed:-watcher arm exited $rc without an actionable reason}"
}

cmd_run() {
  local ready
  reclaim_reused_lock "$OWNER_LOCK"
  fm_lock_try_acquire "$OWNER_LOCK" || exit 0
  trap owner_cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  fm_pid_identity "${BASHPID:-$$}" > "$OWNER_LOCK/pid-identity" 2>/dev/null || exit 1
  fm_primary_endpoint_load "$STATE" "$FM_ROOT" "$FM_HOME" || exit 0
  SERVED_PID=$FM_PRIMARY_ENDPOINT_PID
  SERVED_IDENTITY=$(fm_pid_identity "$SERVED_PID" 2>/dev/null || true)
  [ -n "$SERVED_IDENTITY" ] || exit 0
  [ "$FM_PRIMARY_ENDPOINT_BACKEND" != kirocrew ] || SERVED_CHAT=$FM_PRIMARY_ENDPOINT_TARGET
  crew_still_same || exit 0

  while :; do
    still_serving || exit 0
    crew_still_same || exit 0
    if [ -z "$CHILD" ] && [ "$STOP_AFTER_RING" -eq 0 ]; then
      if fm_supervision_needed "$STATE" "$GRACE"; then
        start_arm "$PREDECESSOR" || { arm_failed "could not create the arm output file"; continue; }
        PREDECESSOR=
        ready=$(await_ready)
        case "$ready" in
          started|attached|wake)
            if [ "$HANDOFF_PENDING" -eq 1 ] && ! confirm_handoff; then
              HANDOFF_PENDING=0
              stop_child
              arm_failed "the handling handoff to the successor was refused and its watcher is gone"
              continue
            fi
            HANDOFF_PENDING=0
            FAILURES=0
            rm -f "$FAILURE_RECORD" 2>/dev/null || true
            ;;
          *)
            HANDOFF_PENDING=0
            stop_child
            arm_failed "no watcher cycle confirmed within ${READY_TIMEOUT}s"
            continue
            ;;
        esac
      elif [ "$RING_WANTED" -eq 0 ]; then
        exit 0
      fi
    fi
    if [ -n "$CHILD" ] && ! fm_pid_alive "$CHILD"; then
      owner_close
      continue
    fi
    [ "$STOP_AFTER_RING" -eq 1 ] || want_ring_for_new_rows
    if [ "$RING_WANTED" -eq 1 ] && ring_if_pending && [ "$STOP_AFTER_RING" -eq 1 ]; then
      exit 1
    fi
    sleep "$POLL"
  done
}

# ---- doorbell service (Kiro Crew) --------------------------------------------

# The doorbell service's recovery after a Kiro Crew gateway restart
# (crew_restarted). Crew dropped the turn in flight and restores the captain's
# open chats a moment after it starts, so the service waits up to
# RESTORE_GRACE seconds for the chat to be listed. Then, when the home needs
# supervision or main has something pending, it sends the restart line, whose
# turn makes the Kiro hook take the helm again. It records the new generation,
# so each restart is recovered once. A chat Crew does not restore stays down:
# the firstmate app may resume only its own chats, so the captain reopens the
# primary with bin/fm-kirocrew-primary.sh. A gateway that does not answer
# within RECOVER_TIMEOUT is waited for again on a later check. A chat missing
# under the same gateway process was closed by the captain, and the owner
# retires its record (crew_chat_gone); a lock that moved to another pid belongs
# to another session, so its record is not recovered either.
SERVE_CHECKED_AT=0
serve_recover() {  # [<force>]
  local pid identity chat episode deadline restore_until line outcome now
  [ ! -e "$STATE/.afk" ] || return 0
  fm_primary_endpoint_read "$STATE" "$FM_ROOT" "$FM_HOME" || return 0
  [ "$FM_PRIMARY_ENDPOINT_REC_BACKEND" = kirocrew ] || return 0
  pid=$FM_PRIMARY_ENDPOINT_REC_PID
  identity=$FM_PRIMARY_ENDPOINT_REC_IDENTITY
  chat=$FM_PRIMARY_ENDPOINT_REC_TARGET
  [ "$(cat "$STATE/.lock" 2>/dev/null || true)" = "$pid" ] || return 0
  now=$(date +%s)
  [ "${1:-0}" = 1 ] || [ $((now - SERVE_CHECKED_AT)) -ge "$CREW_CHECK" ] || return 0
  SERVE_CHECKED_AT=$now
  fm_primary_endpoint_crew_observe "$STATE" "$FM_HOME" "$chat" || return 0
  crew_restarted "$chat" "$pid" "$identity" || return 0
  # With no generation to record, the dead pid's identity marks the restart.
  episode=${FM_PRIMARY_ENDPOINT_CREW_GEN:-pid:$pid:$(printf '%s' "$identity" | cksum | cut -d' ' -f1)}
  [ "$(cut -f1 "$RECOVERY_RECORD" 2>/dev/null | head -n 1)" != "$episode" ] || return 0
  line=$(fm_primary_endpoint_restart_line "$FM_ROOT") || return 0
  deadline=$(( now + RECOVER_TIMEOUT ))
  restore_until=$(( now + RESTORE_GRACE ))
  outcome=
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ "$FM_PRIMARY_ENDPOINT_CREW_STATE" = absent ]; then
      if [ "$(date +%s)" -ge "$restore_until" ]; then
        outcome="Kiro Crew did not restore the chat $chat; reopen it with bin/fm-kirocrew-primary.sh"
        break
      fi
    elif ! fm_supervision_needed "$STATE" "$GRACE" && ! main_pending; then
      outcome='restored; nothing to supervise, so no restart line'
      break
    elif fm_primary_endpoint_ring_crew "$STATE" "$FM_HOME" "$chat" "$line"; then
      outcome=rung
      break
    elif [ "$FM_PRIMARY_ENDPOINT_RING_RESULT" = forbidden ]; then
      outcome="Kiro Crew does not let the firstmate app message the chat $chat"
      break
    fi
    sleep "$SERVE_POLL"
    fm_primary_endpoint_crew_observe "$STATE" "$FM_HOME" "$chat" || sleep 5
  done
  [ -n "$outcome" ] || return 0
  record_gen "$chat" "$FM_PRIMARY_ENDPOINT_CREW_GEN"
  printf '%s\t%s\t%s\n' "$episode" "$outcome" "$(date +%s)" > "$RECOVERY_RECORD" 2>/dev/null || true
}

cmd_serve() {
  local force=0
  reclaim_reused_lock "$SERVICE_LOCK"
  fm_lock_try_acquire "$SERVICE_LOCK" || { echo "doorbell-service: another doorbell service runs for this home"; exit 0; }
  trap 'trap - EXIT; fm_lock_release "$SERVICE_LOCK" 2>/dev/null || true' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  fm_pid_identity "${BASHPID:-$$}" > "$SERVICE_LOCK/pid-identity" 2>/dev/null || exit 1
  while :; do
    # An owner that just exited may have seen a restart, so check at once.
    serve_recover "$force"
    force=0
    if [ ! -e "$STATE/.afk" ] && ! failure_cooling_down \
      && fm_primary_endpoint_load "$STATE" "$FM_ROOT" "$FM_HOME" \
      && [ "$FM_PRIMARY_ENDPOINT_BACKEND" = kirocrew ] \
      && fm_supervision_needed "$STATE" "$GRACE"; then
      "$SCRIPT_DIR/fm-primary-doorbell.sh" run </dev/null >/dev/null 2>&1 || true
      force=1
    fi
    sleep "$SERVE_POLL"
  done
}

case "${1:-}" in
  ensure) cmd_ensure ;;
  run) cmd_run ;;
  serve) cmd_serve ;;
  unit) service_unit; echo ;;
  -h|--help) sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//; $d' ;;
  *) echo "usage: fm-primary-doorbell.sh ensure|run|serve|unit" >&2; exit 2 ;;
esac
