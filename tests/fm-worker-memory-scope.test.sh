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

FAKENODE="$TMP_ROOT/fakenode"
mkdir -p "$FAKENODE"
cat > "$FAKENODE/node" <<'SH'
#!/usr/bin/env bash
if [ -n "${NODE_OPTIONS:-}" ]; then echo "fake node measured under NODE_OPTIONS=$NODE_OPTIONS" >&2; exit 9; fi
echo 4192
SH
chmod +x "$FAKENODE/node"

# shellcheck disable=SC2016
PRINT_NODE_OPTIONS='echo "NODE_OPTIONS=${NODE_OPTIONS-unset}"'

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

# run_node_env <node-options|unset> <probe-user> <probe-machine>: prints the
# NODE_OPTIONS the launched command sees, with the fake node on PATH.
run_node_env() {
  local opts=$1 user=$2 machine=$3
  : > "$ARGV_LOG"
  if [ "$opts" = unset ]; then unset NODE_OPTIONS; else export NODE_OPTIONS="$opts"; fi
  PATH="$FAKEBIN:$FAKENODE:$PATH" FM_FAKE_SYSTEMD_ARGV_LOG="$ARGV_LOG" \
    FM_FAKE_SYSTEMD_PROBE_USER="$user" FM_FAKE_SYSTEMD_PROBE_MACHINE="$machine" \
    "$HELPER" 3G "$UNIT" -- sh -c "$PRINT_NODE_OPTIONS"
}

test_node_heap_size_is_appended() {
  local out
  out=$(run_node_env unset 0 1 2>&1)
  assert_equals 'NODE_OPTIONS=--max-old-space-size=4192' "$out" "a scoped launch should hand Node its unscoped heap size"
  out=$(run_node_env --trace-warnings 0 1 2>&1)
  assert_equals 'NODE_OPTIONS=--trace-warnings --max-old-space-size=4192' "$out" "existing NODE_OPTIONS should be kept and extended"
  out=$(run_node_env unset 1 0 2>&1)
  assert_equals 'NODE_OPTIONS=--max-old-space-size=4192' "$out" "the machine transport branch should hand Node its heap size too"
  out=$(run_node_env unset 1 1 2>/dev/null)
  assert_equals 'NODE_OPTIONS=unset' "$out" "an uncapped launch should leave NODE_OPTIONS alone"
  pass "a capped launch appends Node's unscoped heap size to NODE_OPTIONS, an uncapped one does not"
}

test_node_options_with_size_are_intact() {
  local out opts
  for opts in '--max-old-space-size=1024' '--trace-warnings --max-old-space-size-percentage=50'; do
    out=$(run_node_env "$opts" 0 1 2>&1)
    assert_equals "NODE_OPTIONS=$opts" "$out" "NODE_OPTIONS that already sets a heap size must stay intact"
  done
  pass "NODE_OPTIONS that already carries a heap size is left as it is"
}

test_no_node_leaves_environment() {
  local bare out tool
  bare="$TMP_ROOT/nonode"
  mkdir -p "$bare"
  for tool in bash sh cat id env; do ln -sf "$(command -v "$tool")" "$bare/$tool"; done
  ln -sf "$FAKEBIN/systemd-run" "$bare/systemd-run"
  out=$(unset NODE_OPTIONS; PATH="$bare" FM_FAKE_SYSTEMD_ARGV_LOG="$ARGV_LOG" \
    "$bare/bash" "$HELPER" 3G "$UNIT" -- sh -c "$PRINT_NODE_OPTIONS" 2>&1)
  assert_equals 'NODE_OPTIONS=unset' "$out" "without node on PATH the environment stays as it was"
  pass "a pane with no node gets no NODE_OPTIONS"
}

test_real_node_heap_under_cap() {
  local out
  if ! command -v node >/dev/null 2>&1 || ! command -v systemd-run >/dev/null 2>&1 ||
    ! systemd-run --user --scope --quiet --collect -p MemoryHigh=3G -- true >/dev/null 2>&1; then
    pass "skip: no node or no systemd user scope on this host"
    return 0
  fi
  unset NODE_OPTIONS
  out=$(env -u NODE_OPTIONS node -p 'Math.floor(require("v8").getHeapStatistics().heap_size_limit/2**20)')
  if [ "$out" -lt 4096 ]; then
    pass "skip: this host's unscoped Node heap is only ${out} MB"
    return 0
  fi
  out=$("$HELPER" 3G "fm-worker-test-$$-$RANDOM.scope" -- node -p 'Math.floor(require("v8").getHeapStatistics().heap_size_limit/2**20)' 2>&1)
  expect_code 0 "$?" "the real scoped node should run: $out"
  [ "$out" -ge 4096 ] || fail "a 3G scope left Node a ${out} MB heap, below 4096 MB"
  pass "under a real 3G scope Node keeps a ${out} MB heap"
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
  test_node_heap_size_is_appended \
  test_node_options_with_size_are_intact \
  test_no_node_leaves_environment \
  test_real_node_heap_under_cap \
  test_real_systemd_scope
