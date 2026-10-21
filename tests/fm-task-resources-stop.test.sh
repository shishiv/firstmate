#!/usr/bin/env bash
# Behavior tests for bin/fm-task-resources-stop.sh.
#
# Matrix:
#   processes  this task's server (and its detached child) stopped; another task's,
#              another home's same-id, and the captain's left running
#   compose    project fm-<id> brought down with no -v and no --rmi; another
#              project, and a project with nothing left, never touched
#   folders    the task's configured folders removed by exact path, an absent one
#              is not an error, another task's folder and every shared build
#              cache stay, a symlink is not followed, a bad template is ignored
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STOP="$ROOT/bin/fm-task-resources-stop.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-resources-stop-tests)

if [ ! -r "/proc/$$/environ" ]; then
  printf 'skip: no readable /proc on this host; the process stop is a documented no-op here\n'
  exit 0
fi

FIXTURE_PIDS=()
cleanup_fixtures() {
  local pid
  for pid in "${FIXTURE_PIDS[@]+"${FIXTURE_PIDS[@]}"}"; do
    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  done
  [ -z "${MADE_SHARED_CACHE:-}" ] || rmdir /var/tmp/fm-cliente-base 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup_fixtures EXIT

FAKE_HOME="$TMP_ROOT/home"
STATE="$TMP_ROOT/fmhome/state"
OTHER_STATE="$TMP_ROOT/otherhome/state"
CONFIG="$TMP_ROOT/fmhome/config"
BIN="$TMP_ROOT/bin"
mkdir -p "$FAKE_HOME" "$STATE" "$OTHER_STATE" "$CONFIG" "$BIN"
STATE_REAL=$(cd "$STATE" && pwd -P)
OTHER_STATE_REAL=$(cd "$OTHER_STATE" && pwd -P)

alive() { kill -0 "$1" 2>/dev/null; }

# A "dev server": a group leader that starts a detached child, both carrying the
# given marker the way a worker's descendants carry FM_TASK_INBOX.
start_server() {  # <name> <marker-or-empty>
  local name=$1 marker=$2 ready="$TMP_ROOT/$1.ready" i
  (
    cd "$TMP_ROOT" || exit 1
    if [ -n "$marker" ]; then
      exec env -i PATH="$PATH" FM_TASK_INBOX="$marker" READY="$ready" \
        setsid bash -c "sleep 300 & echo \$! > \"\$READY\"; wait"
    fi
    exec env -i PATH="$PATH" READY="$ready" setsid bash -c "sleep 300 & echo \$! > \"\$READY\"; wait"
  ) </dev/null >/dev/null 2>&1 &
  FIXTURE_PIDS+=("$!")
  for i in $(seq 1 100); do [ -s "$ready" ] && break; sleep 0.05; done
  [ -s "$ready" ] || fail "fixture invalid: server $name never started"
  eval "${name}_PID=\$!"
  eval "${name}_CHILD=\$(cat \"\$ready\")"
  FIXTURE_PIDS+=("$(cat "$ready")")
}

# Records every call; `ps` lists container ids only for projects marked up.
cat > "$BIN/docker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DOCKER_LOG"
case "$1" in
  ps)
    for arg in "$@"; do
      case "$arg" in
        label=com.docker.compose.project=*)
          project=${arg#label=com.docker.compose.project=}
          [ -e "$FAKE_DOCKER_UP/$project" ] && echo "c0ffee-$project"
          ;;
      esac
    done
    exit 0
    ;;
  compose)
    [ "$2" = -p ] || exit 2
    rm -f "$FAKE_DOCKER_UP/$3"
    exit 0
    ;;
esac
exit 3
SH
chmod +x "$BIN/docker"
export FAKE_DOCKER_LOG="$TMP_ROOT/docker.log" FAKE_DOCKER_UP="$TMP_ROOT/docker-up"
mkdir -p "$FAKE_DOCKER_UP"
: > "$FAKE_DOCKER_LOG"

run_stop() {  # <task-id>
  HOME="$FAKE_HOME" PATH="$BIN:$PATH" FM_HOME="$TMP_ROOT/fmhome" FM_STATE_OVERRIDE="$STATE" \
    FM_CONFIG_OVERRIDE="$CONFIG" "$STOP" "$1"
}

# --- processes ---------------------------------------------------------------

start_server OWN "$STATE_REAL/task-a.inbox"
start_server SIBLING "$STATE_REAL/task-b.inbox"
start_server SAMEID_OTHER_HOME "$OTHER_STATE_REAL/task-a.inbox"
start_server PREFIX "$STATE_REAL/task-a-b.inbox"
start_server CAPTAIN ""
alive "$OWN_CHILD" || fail "fixture invalid: the task's server child is not running"

out=$(run_stop task-a 2>&1) || fail "the stop exited nonzero: $out"
assert_contains "$out" "stopped 2 process(es) that task-a started" \
  "the stop did not report the server and its child"
sleep 0.2
! alive "$OWN_PID" || fail "the task's server is still running"
! alive "$OWN_CHILD" || fail "the server's detached child outlived its cleanup"
pass "a server the task started is stopped with the child it detached"

alive "$SIBLING_PID" || fail "the stop touched another task's server"
alive "$SIBLING_CHILD" || fail "the stop touched another task's server child"
pass "another task's server is left running"
alive "$SAMEID_OTHER_HOME_PID" || fail "the stop touched the same task id in another home"
alive "$SAMEID_OTHER_HOME_CHILD" || fail "the stop touched a child of the same task id in another home"
pass "the same task id in another home is left running"
alive "$PREFIX_PID" || fail "the stop touched a task whose id only starts with this task's id"
pass "a task whose id extends this one is left running"
alive "$CAPTAIN_PID" || fail "the stop touched a process without any task marker"
alive "$CAPTAIN_CHILD" || fail "the stop touched a child of a process without any task marker"
pass "a process with no task marker is left running"

# A process that ignores TERM is killed once the grace period ends.
(
  cd "$TMP_ROOT" || exit 1
  exec env -i PATH="$PATH" FM_TASK_INBOX="$STATE_REAL/task-a.inbox" \
    bash -c 'trap "" TERM; while :; do sleep 1; done'
) </dev/null >/dev/null 2>&1 &
STUBBORN=$!
disown "$STUBBORN"
FIXTURE_PIDS+=("$STUBBORN")
sleep 0.3
alive "$STUBBORN" || fail "fixture invalid: the stubborn server did not start"
run_stop task-a >/dev/null 2>&1 || fail "the stop exited nonzero for a server that ignores TERM"
sleep 0.2
! alive "$STUBBORN" || fail "a server that ignores TERM survived its cleanup"
pass "a server that ignores TERM is killed"

# The stop never signals the shell that runs it, even when that shell carries the marker.
( FM_TASK_INBOX="$STATE_REAL/task-a.inbox" HOME="$FAKE_HOME" PATH="$BIN:$PATH" FM_HOME="$TMP_ROOT/fmhome" \
  FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG" "$STOP" task-a >/dev/null 2>&1; echo survived ) \
  | grep -q survived || fail "the stop killed the process tree that ran it"
pass "the stop never signals its own process tree"

# --- compose -----------------------------------------------------------------

: > "$FAKE_DOCKER_LOG"
: > "$FAKE_DOCKER_UP/fm-task-a"
: > "$FAKE_DOCKER_UP/fm-task-b"
out=$(run_stop task-a 2>&1) || fail "the stop exited nonzero: $out"
assert_contains "$out" "brought down Compose project fm-task-a (volumes kept)" \
  "the stop did not report bringing the Compose project down"
assert_grep "compose -p fm-task-a down" "$FAKE_DOCKER_LOG" "the Compose project of the task was not brought down"
assert_no_grep "fm-task-b down" "$FAKE_DOCKER_LOG" "another task's Compose project was brought down"
[ -e "$FAKE_DOCKER_UP/fm-task-b" ] || fail "another task's Compose project is gone"
if grep -E -- ' -v( |$)|--volumes|--rmi|volume |system prune' "$FAKE_DOCKER_LOG" >/dev/null; then
  fail "docker was asked to remove volumes or images: $(cat "$FAKE_DOCKER_LOG")"
fi
pass "the task's Compose project comes down, with volumes and images kept, and another task's stays up"

: > "$FAKE_DOCKER_LOG"
run_stop task-a >/dev/null 2>&1 || fail "the stop exited nonzero with no project left"
assert_no_grep "compose -p" "$FAKE_DOCKER_LOG" "docker compose ran for a project with no containers"
pass "a project with nothing left is not touched"

: > "$FAKE_DOCKER_UP/fm-taskuc"
run_stop Task.UC >/dev/null 2>&1 || fail "the stop exited nonzero for a mixed-case task id"
assert_grep "compose -p fm-taskuc down" "$FAKE_DOCKER_LOG" "the lowercase Compose name of a mixed-case id was not used"
pass "a task id is mapped to the project name Compose gives it"

NO_DOCKER_PATH=$(mktemp -d "$TMP_ROOT/nodocker.XXXXXX")
for tool in bash env grep sed tr awk cat rm sleep seq dirname basename chmod timeout od head sort; do
  p=$(command -v "$tool" 2>/dev/null) && ln -s "$p" "$NO_DOCKER_PATH/$tool"
done
out=$(HOME="$FAKE_HOME" PATH="$NO_DOCKER_PATH" FM_HOME="$TMP_ROOT/fmhome" FM_STATE_OVERRIDE="$STATE" \
  FM_CONFIG_OVERRIDE="$CONFIG" "$(command -v bash)" "$STOP" task-a 2>&1) || fail "the stop failed without docker: $out"
pass "a host without docker is not an error"

# --- folders -----------------------------------------------------------------

mkdir -p "$FAKE_HOME/.cache/lloegrys/ccache" "$FAKE_HOME/.cache/fm-lloegrys-task-a/deep" \
  "$FAKE_HOME/.cache/fm-lloegrys-task-b" "$TMP_ROOT/big/fm-task-a/ro/sub" "$TMP_ROOT/big/fm-task-b" \
  "$TMP_ROOT/big/fm-task-a-keep"
printf x > "$FAKE_HOME/.cache/lloegrys/ccache/object"
printf x > "$TMP_ROOT/big/fm-task-a/ro/sub/file"
chmod -R a-w "$TMP_ROOT/big/fm-task-a/ro"
cat > "$CONFIG/task-cleanup-dirs" <<EOF
# the task's big folder and its tool cache
$TMP_ROOT/big/fm-{id}

~/.cache/fm-lloegrys-{id}
$TMP_ROOT/big/never-created-{id}
EOF

out=$(run_stop task-a 2>&1) || fail "the stop exited nonzero: $out"
assert_absent "$TMP_ROOT/big/fm-task-a" "the task's big folder survived its cleanup"
assert_absent "$FAKE_HOME/.cache/fm-lloegrys-task-a" "the task's cache folder under the home survived its cleanup"
assert_contains "$out" "removed $TMP_ROOT/big/fm-task-a" "the stop did not report removing the folder"
assert_present "$TMP_ROOT/big/fm-task-b" "another task's folder was removed"
assert_present "$FAKE_HOME/.cache/fm-lloegrys-task-b" "another task's cache folder was removed"
assert_present "$TMP_ROOT/big/fm-task-a-keep" "a folder whose name only starts with the task's was removed"
assert_present "$FAKE_HOME/.cache/lloegrys/ccache/object" "the shared build cache was touched"
assert_not_contains "$out" "warning" "a folder that was never created was reported as a problem"
pass "the task's folders go by exact path, read-only trees included, and nothing else"

out=$(run_stop task-a 2>&1) || fail "a second stop exited nonzero"
[ -z "$out" ] || fail "a second stop found something to do: $out"
pass "a second stop is silent"

# A symlink is not followed.
mkdir -p "$TMP_ROOT/elsewhere/precious"
ln -s "$TMP_ROOT/elsewhere" "$TMP_ROOT/big/fm-task-ln"
out=$(run_stop task-ln 2>&1) || fail "the stop exited nonzero for a symlink"
assert_present "$TMP_ROOT/elsewhere/precious" "the stop followed a symlink and removed its target"
assert_contains "$out" "is a symlink" "the stop did not say it left the symlink alone"
pass "a symlink is left alone and never followed"

# Shared build caches survive whatever a template expands to.
cat > "$CONFIG/task-cleanup-dirs" <<EOF
~/.cache/{id}
$FAKE_HOME/.cache/{id}/ccache
$FAKE_HOME/.cache/fm-{id}
EOF
out=$(run_stop lloegrys 2>&1) || fail "the stop exited nonzero: $out"
assert_present "$FAKE_HOME/.cache/lloegrys/ccache/object" "a template expanding to ~/.cache/lloegrys removed the shared cache"
assert_contains "$out" "shared build cache" "the stop did not say it protected the shared cache"
pass "a template that expands to the shared ~/.cache/lloegrys cache removes nothing"

mkdir -p "$FAKE_HOME/.cache/fm-lloegrys"
cat > "$CONFIG/task-cleanup-dirs" <<EOF
$FAKE_HOME/.cache/fm-{id}
EOF
run_stop lloegrys >/dev/null 2>&1 || fail "the stop exited nonzero"
assert_absent "$FAKE_HOME/.cache/fm-lloegrys" "the task's own folder next to the shared cache was kept"
assert_present "$FAKE_HOME/.cache/lloegrys/ccache/object" "removing a sibling folder touched the shared cache"
pass "a folder beside the shared cache is removed without touching it"

if [ -e /var/tmp/fm-cliente-base ]; then
  printf 'skip: /var/tmp/fm-cliente-base exists on this host; its protection is not exercised against a real cache\n'
else
  mkdir /var/tmp/fm-cliente-base && MADE_SHARED_CACHE=1
  printf x > /var/tmp/fm-cliente-base/object
  printf '%s\n' '/var/tmp/fm-{id}' > "$CONFIG/task-cleanup-dirs"
  out=$(run_stop cliente-base 2>&1) || fail "the stop exited nonzero: $out"
  assert_present /var/tmp/fm-cliente-base/object "a template expanding to /var/tmp/fm-cliente-base removed the shared cache"
  rm -f /var/tmp/fm-cliente-base/object
  pass "a template that expands to /var/tmp/fm-cliente-base removes nothing"
fi

# Templates that could name more than one task's folder are ignored.
mkdir -p "$TMP_ROOT/risky/a-task-z" "$TMP_ROOT/risky/b-task-z"
cat > "$CONFIG/task-cleanup-dirs" <<EOF
$TMP_ROOT/risky/*-{id}
$TMP_ROOT/{id}/risky
relative/{id}
$TMP_ROOT/risky/../risky/a-{id}
$TMP_ROOT/risky/nothing-in-it
/{id}
EOF
out=$(run_stop task-z 2>&1) || fail "the stop exited nonzero: $out"
assert_present "$TMP_ROOT/risky/a-task-z" "a glob template removed a folder"
assert_present "$TMP_ROOT/risky/b-task-z" "a glob template removed a folder"
assert_contains "$out" "ignored task-cleanup-dirs entry" "the stop did not say it ignored the unusable templates"
pass "globs, relative paths, a task id outside the last component, and templates without one are ignored"

rm -f "$CONFIG/task-cleanup-dirs"
mkdir -p "$TMP_ROOT/big/fm-task-n"
run_stop task-n >/dev/null 2>&1 || fail "the stop exited nonzero without a config file"
assert_present "$TMP_ROOT/big/fm-task-n" "a home without config removed a folder"
pass "a home without config/task-cleanup-dirs removes no folder"

expect_code 2 "$("$STOP" >/dev/null 2>&1; echo $?)" "a missing task id is not a usage error"
expect_code 2 "$("$STOP" ../x >/dev/null 2>&1; echo $?)" "an unsafe task id is not refused"
pass "usage errors exit 2"

printf '\nall task resources stop tests passed\n'
