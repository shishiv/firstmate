#!/usr/bin/env bash
# tests/fm-worker-boot.test.sh - the session-start relaunch of the ships and
# scouts a machine restart left with only a shell (bin/fm-worker-boot-lib.sh
# decides, bin/fm-bootstrap.sh's worker_boot_relaunch_sweep acts).
#
# After a restart every terminal holds a bare shell. A worker is brought back
# only when its terminal reads exactly dead, its current state is work or a
# machine wait, and this boot has not tried it yet. Everything else stays as it
# is: a live agent, an unclear or missing terminal, a finished, blocked, failed,
# parked, ready-for-review, or captain-held worker, a remote or secondmate task,
# and a task whose local copy is gone. The sweep runs through the network-only
# bootstrap phase, with a stub control plane that records its calls.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
fm_git_identity fmtest fmtest@example.com
TMP_ROOT=$(fm_test_tmproot fm-worker-boot)
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH

# A tmux whose foreground command is FM_TEST_PANE_CMD: a shell name reads dead,
# an agent name reads alive, `node` is ambiguous, `missing` omits the window
# from a readable inventory, and `unreadable` fails every read.
make_tmux() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
mode=${FM_TEST_PANE_CMD:-zsh}
case "${1:-}" in
  display-message)
    for a in "$@"; do
      case "$a" in
        *pane_current_command*)
          case "$mode" in
            missing) printf '%s\n' node; exit 0 ;;
            unreadable) exit 1 ;;
            *) printf '%s\n' "$mode"; exit 0 ;;
          esac ;;
      esac
    done
    exit 0 ;;
  list-windows)
    case "$mode" in
      missing) printf '%s\n' main; exit 0 ;;
      unreadable) exit 1 ;;
      *) for w in fm-w1 fm-w2 fm-w3 fm-w4 fm-w5 fm-w6 fm-w7 fm-w8; do printf '%s\n' "$w"; done; exit 0 ;;
    esac ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# A crew-state whose verdict line is FM_TEST_CREW_STATE (default: the dead,
# runless reading the real script gives a terminal that only holds a shell).
make_crew_state() {  # <dir>
  local bin="$1/crew-state"
  cat > "$bin" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_TEST_CREW_STATE:-state: unknown · source: none · backend target gone: t (agent gone, pane shell remains)}"
SH
  chmod +x "$bin"
  printf '%s\n' "$bin"
}

# A control plane that records "<id> <verb> <note-flag>" and exits FM_TEST_CONTROL_RC.
make_control() {  # <dir>
  local bin="$1/control"
  cat > "$bin" <<'SH'
#!/usr/bin/env bash
printf '%s %s %s\n' "${1:-}" "${2:-}" "${3:-}" >> "${FM_TEST_CONTROL_LOG:?}"
[ "${FM_TEST_CONTROL_RC:-0}" -eq 0 ] || echo "error: the replacement agent did not come up" >&2
exit "${FM_TEST_CONTROL_RC:-0}"
SH
  chmod +x "$bin"
  printf '%s\n' "$bin"
}

# new_world <name>: a home with a stub toolchain and no task yet.
new_world() {
  local w="$TMP_ROOT/$1"
  mkdir -p "$w/home/state" "$w/home/config" "$w/home/data"
  touch "$w/home/state/.last-watcher-beat"
  make_tmux "$w" >/dev/null
  make_crew_state "$w" >/dev/null
  make_control "$w" >/dev/null
  : > "$w/control.log"
  printf '%s\n' "$w"
}

# add_worker <w> <id> <kind> <status-line> [harness]: a local task record with a
# real local copy and a status log ending in <status-line>.
add_worker() {
  local w=$1 id=$2 kind=$3 status=$4 harness=${5:-claude}
  mkdir -p "$w/wt-$id"
  {
    printf 'window=firstmate:fm-%s\n' "$id"
    printf 'kind=%s\n' "$kind"
    printf 'harness=%s\n' "$harness"
    printf 'worktree=%s\n' "$w/wt-$id"
    printf 'project=%s\n' "$w/proj"
    printf 'mode=direct-PR\n'
    printf 'yolo=off\n'
  } > "$w/home/state/$id.meta"
  [ -z "$status" ] || printf '%s\n' "$status" > "$w/home/state/$id.status"
}

# sweep <w> [env...]: the network-only bootstrap phase against the world.
# FM_BOOTSTRAP_NETWORK=only runs the deferred sweeps and nothing else.
sweep() {
  local w=$1; shift
  PATH="$w/fakebin:$BASE_PATH" TMUX='' FM_BACKEND=tmux FM_HOME="$w/home" \
    FM_BOOTSTRAP_NETWORK=only FM_CONTROL_BIN="$w/control" FM_CREW_STATE_BIN="$w/crew-state" \
    FM_TEST_CONTROL_LOG="$w/control.log" \
    env "$@" "$ROOT/bin/fm-bootstrap.sh" 2>&1
}

calls() { cat "$1/control.log"; }

test_a_working_worker_with_a_dead_terminal_is_relaunched_once() {
  local w out
  w=$(new_world dead-working)
  add_worker "$w" w1 ship 'working [at=1]: coding'
  out=$(sweep "$w")
  assert_contains "$out" "BOOTSTRAP_INFO: worker w1 relaunched after the restart" \
    "a relaunch the digest could not have seen must be reported"
  [ "$(calls "$w")" = "w1 relaunch --note" ] || fail "expected one relaunch with a note, got: $(calls "$w")"
  assert_grep 'attempt' "$w/home/state/.worker-boot-relaunch-w1" "the attempt must be ledgered before the relaunch"
  assert_grep 'relaunched' "$w/home/state/.worker-boot-relaunch-w1" "the outcome must be ledgered"
  : > "$w/control.log"
  out=$(sweep "$w")
  [ -z "$(calls "$w")" ] || fail "a second sweep in the same boot must not relaunch again: $(calls "$w")"
  assert_not_contains "$out" "worker w1" "a worker already tried this boot stays quiet"
  pass "boot sweep: a working worker whose terminal is a bare shell is relaunched once per boot"
}

test_a_scout_and_a_machine_wait_are_relaunched_too() {
  local w
  w=$(new_world scout-and-wait)
  add_worker "$w" w1 scout 'working [at=1]: reading'
  add_worker "$w" w2 ship 'paused [at=1]: waiting on CI until 2099-01-01T00:00Z'
  sweep "$w" >/dev/null
  assert_contains "$(calls "$w" | sort)" "w1 relaunch --note" "a scout mid-work comes back"
  assert_contains "$(calls "$w" | sort)" "w2 relaunch --note" "a declared machine wait comes back"
  pass "boot sweep: scouts and declared machine waits are relaunched like ships"
}

test_work_waiting_on_someone_else_is_left_alone() {
  local w id out
  w=$(new_world waiting)
  add_worker "$w" w1 ship 'done [at=1]: PR https://example.com/o/r/pull/1'
  add_worker "$w" w2 ship 'needs-decision [at=1] [key=k]: which option'
  add_worker "$w" w3 ship 'blocked [at=1]: waiting for a merge https://example.com/o/r/pull/3'
  add_worker "$w" w4 ship 'failed [at=1]: gave up'
  add_worker "$w" w5 ship 'captain-held [at=1]: held for the captain'
  add_worker "$w" w6 ship ''
  out=$(sweep "$w")
  [ -z "$(calls "$w")" ] || fail "no worker waiting on someone else may be relaunched: $(calls "$w")"
  for id in w1 w2 w3 w4 w5 w6; do
    [ ! -e "$w/home/state/.worker-boot-relaunch-$id" ] || fail "$id must leave no ledger row"
  done
  assert_not_contains "$out" "worker w" "skipped workers are silent"
  pass "boot sweep: done, decision, blocked, failed, held, and never-reported workers stay as they are"
}

test_the_pipeline_verdict_outranks_a_stale_status_log() {
  local w
  w=$(new_world run-step)
  add_worker "$w" w1 ship 'done [at=1]: PR https://example.com/o/r/pull/1'
  add_worker "$w" w2 ship 'working [at=1]: coding'
  sweep "$w" FM_TEST_CREW_STATE='state: working · source: run-step · validating (ci) · run: abc' >/dev/null
  assert_contains "$(calls "$w" | sort)" "w1 relaunch --note" \
    "a pipeline that is still running is work, whatever the log says"
  : > "$w/control.log"; rm -f "$w"/home/state/.worker-boot-relaunch-*
  sweep "$w" FM_TEST_CREW_STATE='state: parked · source: run-step · awaiting_approval' >/dev/null
  [ -z "$(calls "$w")" ] || fail "a parked gate must not be relaunched even when the log says working: $(calls "$w")"
  pass "boot sweep: crew-state's run verdict decides, and the log only answers when crew-state has no source"
}

test_only_a_dead_terminal_counts() {
  local w mode
  for mode in claude node missing unreadable; do
    w=$(new_world "terminal-$mode")
    add_worker "$w" w1 ship 'working [at=1]: coding'
    sweep "$w" FM_TEST_PANE_CMD="$mode" >/dev/null
    [ -z "$(calls "$w")" ] || fail "a terminal reading '$mode' must not be relaunched: $(calls "$w")"
  done
  pass "boot sweep: a live, ambiguous, missing, or unreadable terminal is never relaunched"
}

test_other_task_shapes_are_left_alone() {
  local w verdict
  w=$(new_world shapes)
  add_worker "$w" w1 ship 'working [at=1]: coding'
  rm -rf "$w/wt-w1"
  add_worker "$w" w2 ship 'working [at=1]: coding'
  printf 'remote_host=lab-host\n' >> "$w/home/state/w2.meta"
  add_worker "$w" w4 ship 'working [at=1]: coding' echo
  sweep "$w" >/dev/null
  [ -z "$(calls "$w")" ] || fail "a missing copy, a remote task, and an unverified harness stay as they are: $(calls "$w")"
  # A secondmate has its own liveness sweep; the worker decision never picks one.
  add_worker "$w" w3 secondmate 'working [at=1]: idle'
  verdict=$(PATH="$w/fakebin:$BASE_PATH" STATE="$w/home/state" FM_HOME="$w/home" FM_CREW_STATE_BIN="$w/crew-state" \
    bash -c '. "$0/bin/fm-worker-boot-lib.sh"; fm_worker_boot_probe "$1" w3; printf "%s|%s" "$FM_WB_VERDICT" "$FM_WB_REASON"' \
    "$ROOT" "$w/home/state/w3.meta")
  [ "$verdict" = 'skip|a secondmate is not a worker' ] || fail "a secondmate must never be a worker candidate, got: $verdict"
  pass "boot sweep: no copy, remote, secondmate, or unverified-harness task is relaunched"
}

test_a_failed_relaunch_is_reported_and_not_retried_this_boot() {
  local w out
  w=$(new_world failure)
  add_worker "$w" w1 ship 'working [at=1]: coding'
  out=$(sweep "$w" FM_TEST_CONTROL_RC=1)
  assert_contains "$out" "WORKER_BOOT: worker w1: relaunch failed: error: the replacement agent did not come up" \
    "a failed relaunch must say why"
  assert_grep 'failed' "$w/home/state/.worker-boot-relaunch-w1" "the failure must be ledgered"
  : > "$w/control.log"
  sweep "$w" >/dev/null
  [ -z "$(calls "$w")" ] || fail "a failed relaunch is not retried within the boot: $(calls "$w")"
  pass "boot sweep: a failed relaunch is reported once and left to the supervisor"
}

test_an_attempt_from_an_earlier_boot_does_not_count() {
  local w
  w=$(new_world earlier-boot)
  add_worker "$w" w1 ship 'working [at=1]: coding'
  printf '1000\tattempt\n1001\trelaunched\n' > "$w/home/state/.worker-boot-relaunch-w1"
  sweep "$w" >/dev/null
  [ "$(calls "$w")" = "w1 relaunch --note" ] || fail "an attempt older than the boot must not block this boot: $(calls "$w")"
  pass "boot sweep: only an attempt made since this boot started counts as tried"
}

test_the_sweep_is_skipped_in_detect_only_mode() {
  local w
  w=$(new_world detect-only)
  add_worker "$w" w1 ship 'working [at=1]: coding'
  sweep "$w" FM_BOOTSTRAP_DETECT_ONLY=1 >/dev/null
  [ -z "$(calls "$w")" ] || fail "a read-only session must never relaunch a worker: $(calls "$w")"
  pass "boot sweep: skipped under FM_BOOTSTRAP_DETECT_ONLY=1"
}

test_a_working_worker_with_a_dead_terminal_is_relaunched_once
test_a_scout_and_a_machine_wait_are_relaunched_too
test_work_waiting_on_someone_else_is_left_alone
test_the_pipeline_verdict_outranks_a_stale_status_log
test_only_a_dead_terminal_counts
test_other_task_shapes_are_left_alone
test_a_failed_relaunch_is_reported_and_not_retried_this_boot
test_an_attempt_from_an_earlier_boot_does_not_count
test_the_sweep_is_skipped_in_detect_only_mode
echo "# all fm-worker-boot tests passed"
