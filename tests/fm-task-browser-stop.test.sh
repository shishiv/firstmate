#!/usr/bin/env bash
# Behavior tests for bin/fm-task-browser-stop.sh.
#
# Fake bridges are real processes whose command runs a script named
# chrome-devtools-axi-bridge.js, each leading its own process group and leaving
# a detached "browser" child in a group of its own, the shape the real bridge,
# MCP server, and browser have. A fake `chrome-devtools-axi stop` records the
# session it was asked to stop and stops whatever that session's PID file names,
# as the real one does.
#
# Matrix:
#   (a) this task's bridge, PID file names it   -> stopped through the tool, browser gone
#   (b) this task's bridge, PID file names another bridge -> signalled, tool never run
#   (c) another task's bridge                   -> left running
#   (d) captain's bridge in the same folder     -> left running
#   (e) a non-bridge process of this task       -> left running
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STOP="$ROOT/bin/fm-task-browser-stop.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-browser-stop-tests)

if [ ! -r "/proc/$$/environ" ]; then
  printf 'skip: no readable /proc on this host; the stop is a documented no-op here\n'
  out=$("$STOP" some-task 2>&1) || fail "the stop failed where it cannot scan"
  assert_contains "$out" "were not checked" "the stop did not say it checked nothing"
  pass "without /proc the stop warns and signals nothing"
  exit 0
fi

FIXTURE_PIDS=()
cleanup_fixtures() {
  local pid
  for pid in "${FIXTURE_PIDS[@]+"${FIXTURE_PIDS[@]}"}"; do
    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  done
  [ -f "$TMP_ROOT/children" ] && while read -r pid; do kill -KILL "$pid" 2>/dev/null || true; done < "$TMP_ROOT/children"
  fm_test_cleanup
}
trap cleanup_fixtures EXIT

HOME_DIR="$TMP_ROOT/home"
STATE="$TMP_ROOT/fmhome/state"
WORKDIR="$TMP_ROOT/data/task-a/mocks"
mkdir -p "$HOME_DIR" "$STATE" "$WORKDIR" "$TMP_ROOT/lib" "$TMP_ROOT/bin"
STATE_REAL=$(cd "$STATE" && pwd -P)

# The fake bridge records its PID file, starts a detached "browser" that does
# not die with it, and exits on TERM without closing that browser.
cat > "$TMP_ROOT/lib/chrome-devtools-axi-bridge.js" <<'PL'
use strict;
use POSIX ();
POSIX::setpgid(0, 0);
my $session = $ENV{CHROME_DEVTOOLS_AXI_SESSION} || "default";
my $dir = "$ENV{HOME}/.chrome-devtools-axi" . ($session eq "default" ? "" : "/sessions/$session");
system("mkdir", "-p", $dir);
if (!$ENV{FAKE_SKIP_PIDFILE}) {
  open my $f, ">", "$dir/bridge.pid" or die;
  print $f "{\"pid\":$$,\"port\":9300}";
  close $f;
}
my $child = fork();
if ($child == 0) {
  POSIX::setpgid(0, 0);
  exec "sleep", "300";
}
open my $c, ">>", $ENV{FAKE_CHILDREN} or die;
print $c "$child\n";
close $c;
open my $r, ">", $ENV{FAKE_READY} or die;
print $r "$child\n";
close $r;
$SIG{TERM} = sub { exit 0 };
sleep 300;
PL

cat > "$TMP_ROOT/bin/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
[ "${1-}" = stop ] || exit 2
session=${CHROME_DEVTOOLS_AXI_SESSION:-default}
printf 'stop session=%s home=%s\n' "$session" "$HOME" >> "$FAKE_STOP_LOG"
dir="$HOME/.chrome-devtools-axi"
[ "$session" = default ] || dir="$dir/sessions/$session"
pid=$(sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "$dir/bridge.pid")
kill -TERM "$pid"
SH
chmod +x "$TMP_ROOT/bin/chrome-devtools-axi"
export FAKE_STOP_LOG="$TMP_ROOT/stop.log" FAKE_CHILDREN="$TMP_ROOT/children"
: > "$FAKE_STOP_LOG"

# start_bridge <name> <inbox-marker-or-empty> <session> [skip-pidfile]
start_bridge() {
  local name=$1 marker=$2 session=$3 skip=${4-} ready="$TMP_ROOT/$1.ready" i
  (
    cd "$WORKDIR" || exit 1
    if [ -n "$marker" ]; then
      exec env -i PATH="$PATH" HOME="$HOME_DIR" FAKE_CHILDREN="$FAKE_CHILDREN" FAKE_READY="$ready" \
        FAKE_SKIP_PIDFILE="$skip" CHROME_DEVTOOLS_AXI_SESSION="$session" CHROME_DEVTOOLS_AXI_PORT=9300 \
        FM_TASK_INBOX="$marker" perl "$TMP_ROOT/lib/chrome-devtools-axi-bridge.js"
    fi
    exec env -i PATH="$PATH" HOME="$HOME_DIR" FAKE_CHILDREN="$FAKE_CHILDREN" FAKE_READY="$ready" \
      FAKE_SKIP_PIDFILE="$skip" CHROME_DEVTOOLS_AXI_SESSION="$session" CHROME_DEVTOOLS_AXI_PORT=9300 \
      perl "$TMP_ROOT/lib/chrome-devtools-axi-bridge.js"
  ) </dev/null >/dev/null 2>&1 &
  FIXTURE_PIDS+=("$!")
  for i in $(seq 1 100); do [ -s "$ready" ] && break; sleep 0.05; done
  [ -s "$ready" ] || fail "fixture invalid: bridge $name never started"
  eval "${name}_PID=\$!"
  eval "${name}_CHILD=\$(cat \"\$ready\")"
}

alive() { kill -0 "$1" 2>/dev/null; }
both_alive() { alive "$1" && alive "$2"; }

run_stop() {  # <task-id>
  PATH="$TMP_ROOT/bin:$PATH" FM_HOME="$TMP_ROOT/fmhome" FM_STATE_OVERRIDE="$STATE" "$STOP" "$1"
}

# (a), (c), (d), (e) in one scan.
start_bridge OWN "$STATE_REAL/task-a.inbox" own-session
start_bridge OTHER "$STATE_REAL/task-b.inbox" other-session
start_bridge CAPTAIN "" captain-session
( cd "$WORKDIR" && exec env -i PATH="$PATH" FM_TASK_INBOX="$STATE_REAL/task-a.inbox" sleep 300 ) &
WORKER_SHELL=$!
FIXTURE_PIDS+=("$WORKER_SHELL")
alive "$OWN_CHILD" || fail "fixture invalid: the task's browser is not running"

out=$(run_stop task-a 2>&1) || fail "the stop exited nonzero: $out"
assert_contains "$out" "stopped browser bridge $OWN_PID that task-a started (via stop)" \
  "the stop did not report stopping the task's bridge through the tool"
assert_grep "stop session=own-session home=$HOME_DIR" "$FAKE_STOP_LOG" \
  "the tool's stop was not run for the bridge's own session and HOME"
[ "$(grep -c . "$FAKE_STOP_LOG")" = 1 ] || fail "the tool's stop ran for a bridge this task does not own: $(cat "$FAKE_STOP_LOG")"
sleep 0.2
! alive "$OWN_PID" || fail "the task's bridge is still running"
! alive "$OWN_CHILD" || fail "the browser the task's bridge started outlived it"
pass "a bridge this task started is stopped through the tool, and its browser with it"

both_alive "$OTHER_PID" "$OTHER_CHILD" || fail "the stop touched another task's bridge"
pass "another task's bridge is left running"
both_alive "$CAPTAIN_PID" "$CAPTAIN_CHILD" || fail "the stop touched a bridge the captain started in the same folder"
pass "a bridge without this task's marker is left running even in the task's folder"
alive "$WORKER_SHELL" || fail "the stop touched a process of this task that is not a bridge"
pass "only bridge processes are stopped"

# (b) The session's PID file names the captain's bridge, so the tool's stop
# would hit the wrong process: the task's bridge is signalled instead.
: > "$FAKE_STOP_LOG"
start_bridge DEFAULT_CAPTAIN "" default
start_bridge DEFAULT_OWN "$STATE_REAL/task-a.inbox" default skip-pidfile
out=$(run_stop task-a 2>&1) || fail "the stop exited nonzero: $out"
assert_contains "$out" "stopped browser bridge $DEFAULT_OWN_PID that task-a started (via signal)" \
  "the stop did not signal the task's bridge directly"
[ ! -s "$FAKE_STOP_LOG" ] || fail "the tool's stop ran although its PID file names another bridge"
sleep 0.2
! alive "$DEFAULT_OWN_PID" || fail "the task's bridge is still running"
! alive "$DEFAULT_OWN_CHILD" || fail "the browser of the signalled bridge outlived it"
both_alive "$DEFAULT_CAPTAIN_PID" "$DEFAULT_CAPTAIN_CHILD" \
  || fail "the stop hit the bridge the session's PID file names"
pass "a bridge the PID file does not name is signalled, never stopped through the file"

out=$(run_stop task-a 2>&1) || fail "a second stop exited nonzero"
[ -z "$out" ] || fail "a second stop found something to do: $out"
pass "a stop with nothing left is silent"

expect_code 2 "$("$STOP" >/dev/null 2>&1; echo $?)" "a missing task id is not a usage error"
expect_code 2 "$("$STOP" ../x >/dev/null 2>&1; echo $?)" "an unsafe task id is not refused"
pass "usage errors exit 2"

printf '\nall task browser stop tests passed\n'
