#!/usr/bin/env bash
# tests/fm-worker-memory-scope.test.sh - bin/fm-worker-memory-scope.sh puts one
# command in its own systemd user scope with MemoryHigh, in place (same PID), and
# launches it uncapped exactly once wherever no systemd user scope is reachable.
#
# A fake systemd-run records its argv, answers the `-- true` probes as each case
# chooses, and otherwise execs the command after `--`, as the real one does. The
# last case runs the real systemd-run when the host has a user manager.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/bin/fm-worker-memory-scope.sh"
TMP_ROOT=$(fm_test_tmproot fm-worker-memory-scope)
FAKEBIN="$TMP_ROOT/fakebin"
ARGV_LOG="$TMP_ROOT/systemd-run.argv"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/systemd-run" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_SYSTEMD_ARGV_LOG"
machine=0
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
  case "$1" in --machine=*) machine=1 ;; esac
  shift
done
shift
if [ "$#" -eq 1 ] && [ "$1" = true ]; then
  if [ "$machine" = 1 ]; then exit "${FM_FAKE_SYSTEMD_PROBE_MACHINE:-1}"; fi
  exit "${FM_FAKE_SYSTEMD_PROBE_USER:-0}"
fi
exec "$@"
SH
chmod +x "$FAKEBIN/systemd-run"

UNIT=fm-worker-t1-s1.2.3.scope
SCOPE_FLAGS='--user --scope --quiet --collect --slice=firstmate.slice -p MemoryHigh=3G'

# run_helper <probe-user> <probe-machine> <command...>: runs the helper under a
# bash that prints its own PID first and then execs the helper, so the PID the
# command prints can be compared with the helper's.
run_helper() {
  local user=$1 machine=$2
  shift 2
  : > "$ARGV_LOG"
  PATH="$FAKEBIN:$PATH" FM_FAKE_SYSTEMD_ARGV_LOG="$ARGV_LOG" \
    FM_FAKE_SYSTEMD_PROBE_USER="$user" FM_FAKE_SYSTEMD_PROBE_MACHINE="$machine" \
    bash -c 'echo "outer=$$"; exec "$@"' _ "$HELPER" 3G "$UNIT" -- "$@"
}

test_user_scope_execs_in_place() {
  local out outer inner
  out=$(run_helper 0 1 sh -c 'echo "inner=$$"' 2>&1)
  expect_code 0 "$?" "a reachable user scope should run the command: $out"
  outer=$(printf '%s\n' "$out" | sed -n 's/^outer=//p')
  inner=$(printf '%s\n' "$out" | sed -n 's/^inner=//p')
  [ -n "$inner" ] || fail "the command did not run: $out"
  assert_equals "$outer" "$inner" "the helper and systemd-run must exec, so the worker keeps the launching PID"
  assert_equals "$SCOPE_FLAGS -- true
$SCOPE_FLAGS --unit=$UNIT -- sh -c echo \"inner=\$\$\"" "$(cat "$ARGV_LOG")" \
    "the helper should probe once, then exec systemd-run with the scope flags and the unit"
  pass "a reachable user scope wraps the command in firstmate.slice with MemoryHigh and keeps its PID"
}

test_machine_transport_fallback() {
  local out machine
  machine="--machine=$(id -un)@.host"
  out=$(run_helper 1 0 sh -c 'echo ran' 2>&1)
  expect_code 0 "$?" "a reachable machine transport should run the command: $out"
  assert_equals 1 "$(printf '%s\n' "$out" | grep -cx ran)" "the command should run once"
  assert_equals "$SCOPE_FLAGS -- true
$machine $SCOPE_FLAGS -- true
$machine $SCOPE_FLAGS --unit=$UNIT -- sh -c echo ran" "$(cat "$ARGV_LOG")" \
    "a failed local probe should fall back to the machine transport"
  pass "a pane that cannot reach the user manager locally uses the machine transport"
}

test_no_scope_runs_once_uncapped() {
  local out err status
  err="$TMP_ROOT/noscope.err"
  out=$(run_helper 1 1 sh -c 'echo ran; exit 7' 2>"$err")
  status=$?
  expect_code 7 "$status" "the worker's own exit status must be the helper's"
  assert_equals 1 "$(printf '%s\n' "$out" | grep -cx ran)" "the command should run exactly once"
  assert_equals 'fm-worker-memory-scope: no systemd user scope is reachable here; launching without the MemoryHigh=3G cap' \
    "$(cat "$err")" "an unreachable scope should leave one note"
  assert_not_contains "$(cat "$ARGV_LOG")" "--unit=" "no scope launch should be attempted after both probes fail"
  pass "with no reachable scope the command runs once, uncapped, with its own status and one note"
}

test_no_systemd_run_is_silent() {
  local bare out err status tool
  bare="$TMP_ROOT/bare"
  mkdir -p "$bare"
  for tool in bash sh cat id env; do
    ln -sf "$(command -v "$tool")" "$bare/$tool"
  done
  err="$TMP_ROOT/bare.err"
  out=$(PATH="$bare" "$bare/bash" "$HELPER" 3G "$UNIT" -- sh -c 'echo ran; exit 3' 2>"$err")
  status=$?
  expect_code 3 "$status" "without systemd-run the command's status passes through"
  assert_equals ran "$out" "without systemd-run the command runs once"
  assert_equals '' "$(cat "$err")" "without systemd-run the launch is silent"
  pass "a host without systemd-run (macOS) runs the command uncapped and silent"
}

test_bad_usage_refuses() {
  local marker args status
  marker="$TMP_ROOT/ran"
  for args in '3X fm-worker-a.scope --' '0 fm-worker-a.scope --' '3G fm-worker-a.scope ++' '3G fm-worker-a --' '3G fm/worker.scope --'; do
    rm -f "$marker"
    # shellcheck disable=SC2086
    PATH="$FAKEBIN:$PATH" FM_FAKE_SYSTEMD_ARGV_LOG="$ARGV_LOG" \
      "$HELPER" $args touch "$marker" 2>/dev/null
    status=$?
    expect_code 2 "$status" "usage '$args' should be refused"
    assert_absent "$marker" "usage '$args' must not run the command"
  done
  "$HELPER" 3G fm-worker-a.scope -- 2>/dev/null
  expect_code 2 "$?" "a missing command should be refused"
  pass "bad usage exits 2 without running the command"
}

test_real_systemd_scope() {
  local unit out
  if ! command -v systemd-run >/dev/null 2>&1 ||
    ! systemd-run --user --scope --quiet --collect -p MemoryHigh=3G -- true >/dev/null 2>&1; then
    pass "skip: no systemd user scope on this host"
    return 0
  fi
  unit="fm-worker-test-$$-$RANDOM.scope"
  # shellcheck disable=SC2016
  out=$("$HELPER" 3G "$unit" -- sh -c 'cat /proc/self/cgroup; systemctl --user show "$0" -p MemoryHigh' "$unit" 2>&1)
  expect_code 0 "$?" "the real scope launch should succeed: $out"
  assert_contains "$out" "/firstmate.slice/$unit" "the command should run inside its own scope in firstmate.slice"
  assert_contains "$out" "MemoryHigh=3221225472" "the scope should carry MemoryHigh=3G"
  pass "the real systemd user manager runs the command in firstmate.slice/$unit with MemoryHigh=3221225472"
}

fm_test_run \
  test_user_scope_execs_in_place \
  test_machine_transport_fallback \
  test_no_scope_runs_once_uncapped \
  test_no_systemd_run_is_silent \
  test_bad_usage_refuses \
  test_real_systemd_scope
