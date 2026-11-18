#!/usr/bin/env bash
# tests/fm-worker-memory-scope.test.sh - bin/fm-worker-memory-scope.sh puts one
# command in its own systemd user scope with MemoryMax, no swap, one CPU and
# OOMPolicy=continue, under `choom -n 500` when choom is on PATH, in place (same
# PID), and launches it uncapped exactly once wherever no systemd user scope
# starts.
#
# A fake systemd-run records its argv, answers the `-- true` probes as each case
# chooses, and otherwise execs the command after `--`, as the real one does; a
# fake choom checks its arguments and execs the same way. The last case runs the
# real systemd-run and choom when the host has a user manager.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/bin/fm-worker-memory-scope.sh"
BASH_BIN=$(command -v bash)
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
cat > "$FAKEBIN/choom" <<'SH'
#!/usr/bin/env bash
if [ "$#" -lt 4 ] || [ "$1" != -n ] || [ "$3" != -- ]; then echo "fake choom: bad usage: $*" >&2; exit 64; fi
shift 3
exec "$@"
SH
cat > "$FAKEBIN/node" <<'SH'
#!/usr/bin/env bash
echo 4192
SH
chmod +x "$FAKEBIN/systemd-run" "$FAKEBIN/choom" "$FAKEBIN/node"

# NOCHOOM holds only the tools the cases need plus the fake systemd-run, so the
# host's own choom cannot be found.
NOCHOOM="$TMP_ROOT/nochoom"
mkdir -p "$NOCHOOM"
for tool in bash sh cat id env; do ln -sf "$(command -v "$tool")" "$NOCHOOM/$tool"; done
ln -sf "$FAKEBIN/systemd-run" "$NOCHOOM/systemd-run"

UNIT=fm-worker-t1-s1.2.3.scope
SCOPE_FLAGS='--user --scope --quiet --collect --slice=firstmate.slice -p MemoryMax=2G -p MemorySwapMax=0 -p CPUQuota=100% -p OOMPolicy=continue'

# run_helper <path> <probe-user> <probe-machine> <command...>: runs the helper
# under a bash that prints its own PID first and then execs the helper, so the
# PID the command prints can be compared with the helper's.
run_helper() {
  local path=$1 user=$2 machine=$3
  shift 3
  : > "$ARGV_LOG"
  PATH="$path" FM_FAKE_SYSTEMD_ARGV_LOG="$ARGV_LOG" \
    FM_FAKE_SYSTEMD_PROBE_USER="$user" FM_FAKE_SYSTEMD_PROBE_MACHINE="$machine" \
    "$BASH_BIN" -c 'echo "outer=$$"; exec "$@"' _ "$HELPER" 2G "$UNIT" -- "$@"
}

test_user_scope_execs_in_place() {
  local out outer inner
  out=$(run_helper "$FAKEBIN:$PATH" 0 1 sh -c 'echo "inner=$$"' 2>&1)
  expect_code 0 "$?" "a reachable user scope should run the command: $out"
  outer=$(printf '%s\n' "$out" | sed -n 's/^outer=//p')
  inner=$(printf '%s\n' "$out" | sed -n 's/^inner=//p')
  [ -n "$inner" ] || fail "the command did not run: $out"
  assert_equals "$outer" "$inner" "the helper, systemd-run and choom must exec, so the worker keeps the launching PID"
  assert_equals "$SCOPE_FLAGS -- true
$SCOPE_FLAGS --unit=$UNIT -- choom -n 500 -- sh -c echo \"inner=\$\$\"" "$(cat "$ARGV_LOG")" \
    "the helper should probe once, then exec systemd-run with the scope limits, the unit and choom"
  pass "a reachable user scope runs the command under choom -n 500 in a capped firstmate.slice scope and keeps its PID"
}

test_machine_transport_fallback() {
  local out machine
  machine="--machine=$(id -un)@.host"
  out=$(run_helper "$FAKEBIN:$PATH" 1 0 sh -c 'echo ran' 2>&1)
  expect_code 0 "$?" "a reachable machine transport should run the command: $out"
  assert_equals 1 "$(printf '%s\n' "$out" | grep -cx ran)" "the command should run once"
  assert_equals "$SCOPE_FLAGS -- true
$machine $SCOPE_FLAGS -- true
$machine $SCOPE_FLAGS --unit=$UNIT -- choom -n 500 -- sh -c echo ran" "$(cat "$ARGV_LOG")" \
    "a failed local probe should fall back to the machine transport"
  pass "a pane that cannot reach the user manager locally uses the machine transport"
}

test_no_choom_runs_command_directly() {
  local out
  out=$(run_helper "$NOCHOOM" 0 1 sh -c 'echo ran; exit 5' 2>&1)
  expect_code 5 "$?" "the worker's own exit status must be the helper's"
  assert_equals 1 "$(printf '%s\n' "$out" | grep -cx ran)" "the command should run once"
  assert_equals "$SCOPE_FLAGS -- true
$SCOPE_FLAGS --unit=$UNIT -- sh -c echo ran; exit 5" "$(cat "$ARGV_LOG")" \
    "without choom the scope should run the command itself"
  pass "a host without choom runs the command directly inside the capped scope"
}

test_no_scope_runs_once_uncapped() {
  local out err status
  err="$TMP_ROOT/noscope.err"
  out=$(run_helper "$FAKEBIN:$PATH" 1 1 sh -c 'echo ran; exit 7' 2>"$err")
  status=$?
  expect_code 7 "$status" "the worker's own exit status must be the helper's"
  assert_equals 1 "$(printf '%s\n' "$out" | grep -cx ran)" "the command should run exactly once"
  assert_equals 'fm-worker-memory-scope: systemd-run could not start a user scope here; launching without the MemoryMax=2G cap' \
    "$(cat "$err")" "a scope that does not start should leave one note"
  assert_not_contains "$(cat "$ARGV_LOG")" "--unit=" "no scope launch should be attempted after both probes fail"
  pass "with no scope that starts the command runs once, uncapped, with its own status and one note"
}

test_no_systemd_run_is_silent() {
  local bare out err status tool
  bare="$TMP_ROOT/bare"
  mkdir -p "$bare"
  for tool in bash sh cat id env; do
    ln -sf "$(command -v "$tool")" "$bare/$tool"
  done
  err="$TMP_ROOT/bare.err"
  out=$(PATH="$bare" "$bare/bash" "$HELPER" 2G "$UNIT" -- sh -c 'echo ran; exit 3' 2>"$err")
  status=$?
  expect_code 3 "$status" "without systemd-run the command's status passes through"
  assert_equals ran "$out" "without systemd-run the command runs once"
  assert_equals '' "$(cat "$err")" "without systemd-run the launch is silent"
  pass "a host without systemd-run (macOS) runs the command uncapped and silent"
}

test_bad_usage_refuses() {
  local marker args status
  marker="$TMP_ROOT/ran"
  for args in '3X fm-worker-a.scope --' '0 fm-worker-a.scope --' '2G fm-worker-a.scope ++' '2G fm-worker-a --' '2G fm/worker.scope --'; do
    rm -f "$marker"
    # shellcheck disable=SC2086
    PATH="$FAKEBIN:$PATH" FM_FAKE_SYSTEMD_ARGV_LOG="$ARGV_LOG" \
      "$HELPER" $args touch "$marker" 2>/dev/null
    status=$?
    expect_code 2 "$status" "usage '$args' should be refused"
    assert_absent "$marker" "usage '$args' must not run the command"
  done
  "$HELPER" 2G fm-worker-a.scope -- 2>/dev/null
  expect_code 2 "$?" "a missing command should be refused"
  pass "bad usage exits 2 without running the command"
}

# The fake node stays on PATH: a scoped launch must not change NODE_OPTIONS
# even where node exists.
test_node_options_pass_through() {
  local opts out
  for opts in unset --trace-warnings; do
    # shellcheck disable=SC2016
    out=$(if [ "$opts" = unset ]; then unset NODE_OPTIONS; else export NODE_OPTIONS="$opts"; fi
      run_helper "$FAKEBIN:$PATH" 0 1 sh -c 'echo "NODE_OPTIONS=${NODE_OPTIONS-unset}"' 2>&1 |
        sed -n '/^NODE_OPTIONS=/p')
    assert_equals "NODE_OPTIONS=$opts" "$out" "a scoped launch must hand NODE_OPTIONS ($opts) to the command unchanged"
  done
  pass "a scoped launch leaves NODE_OPTIONS as the caller set it, with node on PATH"
}

test_real_systemd_scope() {
  local unit report out outer inner adj
  if ! command -v systemd-run >/dev/null 2>&1 ||
    ! systemd-run --user --scope --quiet --collect -p MemoryMax=1536M -p MemorySwapMax=0 \
      -p CPUQuota=100% -p OOMPolicy=continue -- true >/dev/null 2>&1; then
    pass "skip: no systemd user scope with these properties on this host"
    return 0
  fi
  # Outside the fm-worker- prefix, so a host drop-in for fm-worker-.scope
  # cannot supply the properties this case checks the helper sets.
  unit="fmtest-worker-memory-scope-$$-$RANDOM.scope"
  # A script file, because systemd-run expands $ in the command's arguments.
  report="$TMP_ROOT/report.sh"
  cat > "$report" <<'SH'
#!/bin/sh
echo "inner=$$"
echo "adj=$(cat /proc/self/oom_score_adj)"
cat /proc/self/cgroup
systemctl --user show "$1" -p MemoryMax -p MemorySwapMax -p CPUQuotaPerSecUSec -p OOMPolicy
SH
  chmod +x "$report"
  # shellcheck disable=SC2016
  out=$("$BASH_BIN" -c 'echo "outer=$$"; exec "$@"' _ "$HELPER" 1536M "$unit" -- "$report" "$unit" 2>&1)
  expect_code 0 "$?" "the real scope launch should succeed: $out"
  assert_contains "$out" "/firstmate.slice/$unit" "the command should run inside its own scope in firstmate.slice"
  assert_contains "$out" "MemoryMax=1610612736" "the scope should carry MemoryMax=1536M"
  assert_contains "$out" "MemorySwapMax=0" "the scope should allow no swap"
  assert_contains "$out" "CPUQuotaPerSecUSec=1s" "the scope should carry CPUQuota=100%"
  assert_contains "$out" "OOMPolicy=continue" "the scope should keep running after an OOM kill"
  outer=$(printf '%s\n' "$out" | sed -n 's/^outer=//p')
  inner=$(printf '%s\n' "$out" | sed -n 's/^inner=//p')
  assert_equals "$outer" "$inner" "the real systemd-run and choom must exec, so the worker keeps the launching PID"
  adj=$(printf '%s\n' "$out" | sed -n 's/^adj=//p')
  if command -v choom >/dev/null 2>&1; then
    assert_equals 500 "$adj" "with choom on PATH the command should run with oom_score_adj 500"
    pass "the real systemd user manager runs the command in firstmate.slice/$unit with MemoryMax, no swap, one CPU, OOMPolicy=continue and oom_score_adj 500"
  else
    pass "the real systemd user manager runs the command in firstmate.slice/$unit with MemoryMax, no swap, one CPU and OOMPolicy=continue (no choom on this host)"
  fi
}

fm_test_run \
  test_user_scope_execs_in_place \
  test_machine_transport_fallback \
  test_no_choom_runs_command_directly \
  test_no_scope_runs_once_uncapped \
  test_no_systemd_run_is_silent \
  test_bad_usage_refuses \
  test_node_options_pass_through \
  test_real_systemd_scope
