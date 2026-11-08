#!/usr/bin/env bash
# tests/fm-spawn-worker-memory-scope.test.sh - every pane launch bin/fm-spawn.sh
# builds runs through bin/fm-worker-memory-scope.sh with the MemoryHigh value
# config/worker-memory-high selects (absent: 3G), and `off` restores today's
# launch text.
#
# The cases drive the real spawn against the fake pane from tests/fixtures.sh,
# then EXECUTE the launch command the pane received with a fake systemd-run that
# execs its command, so they check what the agent starts with and which process
# tree it starts in, not only the command text. tests/lib.sh turns the wrapper
# off for every other suite through FM_SPAWN_WORKER_MEMORY_SCOPE; this suite
# unsets that seam.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
unset FM_SPAWN_WORKER_MEMORY_SCOPE

CONTROL="$ROOT/bin/fm-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worker-memory-scope)

install_fake_systemd_run() {  # <fakebin>
  cat > "$1/systemd-run" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do shift; done
shift
exec "$@"
SH
  chmod +x "$1/systemd-run"
}

# make_case <name> <harness> <id>...
# Echoes "<case-dir>|<home>|<project>|<worktree>|<fakebin>|<launch-log>|<pane-log>".
make_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog panelog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  panelog="$case_dir/pane.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  install_fake_systemd_run "$fakebin"
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  for id in "$@"; do
    fm_test_spawn_brief "$home" "$id"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog|$panelog"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG PANE_LOG <<EOF
$1
EOF
}

run_case_spawn() {
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

# The harness binary becomes a probe that prints the environment facts the
# wrapper must carry through.
install_env_probe() {  # <fakebin> <harness>
  cat > "$1/$2" <<'SH'
#!/bin/sh
printf 'COMPACT_ADVISER_DISABLE=%s\n' "${COMPACT_ADVISER_DISABLE-unset}"
printf 'FM_TASK_INBOX=%s\n' "${FM_TASK_INBOX-unset}"
printf 'BASH_ENV=%s\n' "${BASH_ENV-unset}"
SH
  chmod +x "$1/$2"
}

# Run the emitted launch in a synthetic pane shell after the pane exports.
emitted_launch_run() {  # <fakebin> <launch-log> <pane-log>
  local launch preamble
  launch=$(cat "$2")
  preamble=$(grep '^export ' "$3")
  env -i HOME="$TMP_ROOT/pane-home" PATH="$1:$PATH" TERM=xterm TMUX=synthetic-pane \
    /bin/sh -c "$preamble
$launch"
}

spawn_gen_of() {  # <home> <id>
  sed -n 's/^spawn_gen=//p' "$1/state/$2.meta" | tail -1
}

test_default_ship_wraps_3g() {
  local id=mem-ship-a1 rec out gen launch seen
  rec=$(make_case ship-default codex "$id")
  read_case "$rec"
  out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  expect_code 0 "$?" "a ship spawn with no config/worker-memory-high should succeed: $out"
  gen=$(spawn_gen_of "$HOME_DIR" "$id")
  [ -n "$gen" ] || fail "the task record carries no spawn_gen"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "fm-worker-memory-scope.sh' '3G' 'fm-worker-$id-$gen.scope' -- /bin/sh -c " \
    "the default launch should run under a 3G scope named for this spawn"
  install_env_probe "$FAKEBIN_DIR" codex
  seen=$(emitted_launch_run "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG") \
    || fail "the wrapped launch failed to run: $seen"
  assert_contains "$seen" "COMPACT_ADVISER_DISABLE=1" "the wrapped agent must keep the compact-adviser switch"
  assert_contains "$seen" "FM_TASK_INBOX=$(cd "$HOME_DIR/state" && pwd -P)/$id.inbox" \
    "the wrapped agent must keep its steering inbox"
  assert_contains "$seen" "BASH_ENV=$ROOT/bin/fm-worker-bash-env.sh" "the wrapped agent must keep the pipefail BASH_ENV"
  pass "an absent config/worker-memory-high wraps the ship launch in a 3G scope and keeps the agent's environment"
}

# The busy and ownership checks read the harness from the pane's process tree.
# The probe harness asks bin/fm-harness.sh for its own ancestry verdict from
# inside the launched agent, with the scope on and with it off.
test_process_tree_verdict_unchanged() {
  local setting rec id out verdict_on verdict_off
  for setting in on off; do
    id="mem-tree-$setting-a1"
    rec=$(make_case "tree-$setting" claude "$id")
    read_case "$rec"
    [ "$setting" = on ] || printf 'off\n' > "$HOME_DIR/config/worker-memory-high"
    out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
    expect_code 0 "$?" "a claude spawn with the scope $setting should succeed: $out"
    cat > "$FAKEBIN_DIR/claude" <<SH
#!/bin/sh
"$ROOT/bin/fm-harness.sh" ancestry
SH
    chmod +x "$FAKEBIN_DIR/claude"
    out=$(emitted_launch_run "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" 2>&1) \
      || fail "the scope-$setting launch failed to run: $out"
    if [ "$setting" = on ]; then verdict_on=$out; else verdict_off=$out; fi
  done
  assert_contains "$verdict_on" claude "the wrapped launch's ancestry should still name claude"
  assert_equals "$verdict_off" "$verdict_on" "the scope must not change the harness ancestry verdict"
  pass "the harness ancestry verdict from inside the agent is the same with and without the scope"
}

# normalize_launch <launch-log> <case-dir> <gen>: replace the per-case paths,
# the per-home launch directory hash and the per-spawn token so two spawns in
# different fixtures compare byte for byte.
normalize_launch() {
  sed -e "s|$2|CASE|g" -e "s|$3|GEN|g" -e 's|+[0-9a-f]\{64\}/|+HASH/|g' "$1"
}

test_off_restores_todays_launch() {
  local id=mem-off-a1 rec out off_launch seam_launch
  rec=$(make_case off-config codex "$id")
  read_case "$rec"
  printf 'off\n' > "$HOME_DIR/config/worker-memory-high"
  out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  expect_code 0 "$?" "a spawn with config off should succeed: $out"
  assert_not_contains "$(cat "$LAUNCH_LOG")" "fm-worker-memory-scope.sh" "off must not wrap the launch"
  assert_not_contains "$(cat "$LAUNCH_LOG")" "/bin/sh -c" "off must not add a /bin/sh -c frame"
  off_launch=$(normalize_launch "$LAUNCH_LOG" "$CASE_DIR" "$(spawn_gen_of "$HOME_DIR" "$id")")

  rec=$(make_case off-seam codex "$id")
  read_case "$rec"
  out=$(FM_SPAWN_WORKER_MEMORY_SCOPE=off run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  expect_code 0 "$?" "a spawn under the test seam should succeed: $out"
  seam_launch=$(normalize_launch "$LAUNCH_LOG" "$CASE_DIR" "$(spawn_gen_of "$HOME_DIR" "$id")")
  assert_equals "$seam_launch" "$off_launch" "off must give the same launch text the other suites pin"
  pass "config/worker-memory-high=off gives today's uncapped launch text"
}

test_custom_size_and_whitespace() {
  local value rec id out n=0
  for value in 2G ' 2G '; do
    n=$((n + 1))
    id="mem-size-$n-a1"
    rec=$(make_case "size-$n" codex "$id")
    read_case "$rec"
    printf '%s\n' "$value" > "$HOME_DIR/config/worker-memory-high"
    out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
    expect_code 0 "$?" "a spawn with '$value' should succeed: $out"
    assert_contains "$(cat "$LAUNCH_LOG")" "fm-worker-memory-scope.sh' '2G' " "'$value' should select 2G"
  done
  pass "config/worker-memory-high selects another size and ignores surrounding whitespace"
}

test_invalid_values_refuse_before_mutation() {
  local value rec id out status n=0
  for value in 3X 0 -1G 1.5G infinity; do
    n=$((n + 1))
    id="mem-bad-$n-a1"
    rec=$(make_case "bad-$n" codex "$id")
    read_case "$rec"
    printf '%s\n' "$value" > "$HOME_DIR/config/worker-memory-high"
    out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
    status=$?
    [ "$status" -ne 0 ] || fail "'$value' should refuse the spawn: $out"
    assert_contains "$out" "config/worker-memory-high holds '$value'" "'$value' should name the bad value"
    assert_absent "$HOME_DIR/state/$id.meta" "'$value' must refuse before the task record exists"
    assert_equals '' "$(cat "$PANE_LOG")" "'$value' must refuse before a pane exists"
  done
  pass "an invalid config/worker-memory-high refuses the spawn before any record or pane"
}

test_allowlist_launch_is_prefixed_directly() {
  local id=mem-allow-a1 rec out launch seen
  rec=$(make_case allowlist codex "$id")
  read_case "$rec"
  : > "$HOME_DIR/config/launch-env-allowlist"
  out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  expect_code 0 "$?" "an allowlist spawn should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" ".scope' -- /usr/bin/env -i " "the wrapper should sit directly before the cleared environment"
  assert_equals 1 "$(printf '%s' "$launch" | grep -o '/bin/sh -c' | wc -l | tr -d ' ')" \
    "the allowlist launch should keep exactly one /bin/sh -c"
  install_env_probe "$FAKEBIN_DIR" codex
  seen=$(emitted_launch_run "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG") \
    || fail "the wrapped allowlist launch failed to run: $seen"
  assert_contains "$seen" "COMPACT_ADVISER_DISABLE=1" "the wrapped allowlist agent must keep the compact-adviser switch"
  pass "an allowlist launch is wrapped without a second shell and keeps the compact-adviser switch"
}

test_secondmate_is_wrapped() {
  local id=mem-sm-a1 rec sm out
  rec=$(make_case secondmate codex "$id")
  read_case "$rec"
  sm="$CASE_DIR/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$sm/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$sm/.gitignore"
  git -C "$sm" init -q -b main
  out=$(run_case_spawn "$id" "$sm" --secondmate)
  expect_code 0 "$?" "a secondmate spawn should succeed: $out"
  assert_contains "$(cat "$LAUNCH_LOG")" "fm-worker-memory-scope.sh' '3G' 'fm-worker-$id-" \
    "a secondmate launch should run under the 3G scope"
  pass "a secondmate launch runs under the worker memory scope"
}

# Relaunch through the operator verb; the stub models the pane lifecycle the
# same way tests/fm-spawn-compact-adviser-disable.test.sh does.
make_relaunch_stub() {  # <case-dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'")
          staged=${payload#". '"}
          staged=${staged%"'"}
          [ ! -f "$staged" ] || payload=$(cat "$staged")
          ;;
      esac
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit) printf 'zsh' > "$D/command" ;;
        *'encode launch-brief'*) printf 'codex' > "$D/command" ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
}

relaunch_once() {  # <dir> <home> <id>
  env PATH="$1/fakebin:$PATH" FM_HOME="$2" FM_FAKE_DIR="$1/fake" \
    HOME="$1/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$CONTROL" "$3" relaunch --note 'replacement continues the same task' 2>&1
}

test_relaunch_gets_new_scope_and_honours_off() {
  local id=mem-relaunch-a1 dir home proj wt out gen launch
  dir="$TMP_ROOT/relaunch"
  home="$dir/home"
  proj="$dir/proj"
  wt="$dir/wt"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$dir/fake" "$dir/user-home"
  touch "$home/state/.last-watcher-beat"
  make_relaunch_stub "$dir"
  fm_git_worktree "$proj" "$wt" "wt-relaunch"
  fm_test_spawn_brief "$home" "$id"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'codex' > "$dir/fake/command"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$wt" > "$dir/fake/cwd"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=codex"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=$dir/tasktmp"
    echo "model=default"
    echo "effort=default"
    echo "spawn_gen=s1.1.1"
  } > "$home/state/$id.meta"

  out=$(relaunch_once "$dir" "$home" "$id")
  expect_code 0 "$?" "relaunch should succeed: $out"
  gen=$(spawn_gen_of "$home" "$id")
  [ -n "$gen" ] && [ "$gen" != s1.1.1 ] || fail "relaunch should record a new spawn_gen, got '$gen'"
  launch=$(grep 'encode launch-brief' "$dir/fake/literal" | tail -1)
  assert_contains "$launch" "fm-worker-memory-scope.sh' '3G' 'fm-worker-$id-$gen.scope' -- " \
    "the relaunch should run under a new scope named for the new spawn_gen"

  printf 'codex' > "$dir/fake/command"
  printf 'off\n' > "$home/config/worker-memory-high"
  out=$(relaunch_once "$dir" "$home" "$id")
  expect_code 0 "$?" "relaunch with off should succeed: $out"
  launch=$(grep 'encode launch-brief' "$dir/fake/literal" | tail -1)
  assert_not_contains "$launch" "fm-worker-memory-scope.sh" "a relaunch after off must not wrap the launch"
  pass "relaunch runs the replacement in a new scope, and reads off on the next relaunch"
}

fm_test_run \
  test_default_ship_wraps_3g \
  test_process_tree_verdict_unchanged \
  test_off_restores_todays_launch \
  test_custom_size_and_whitespace \
  test_invalid_values_refuse_before_mutation \
  test_allowlist_launch_is_prefixed_directly \
  test_secondmate_is_wrapped \
  test_relaunch_gets_new_scope_and_honours_off
