#!/usr/bin/env bash
# tests/fm-backend-hc.test.sh - fake-hc-CLI unit tests for the herdr-core
# session-provider adapter (bin/backends/hc.sh) and its dispatcher arms in
# bin/fm-backend.sh. tests/fm-backend-hc-smoke.test.sh drives a real isolated
# hc core; this suite pins selection, identity, keys, liveness, and close
# behavior with a stub so it runs everywhere.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-hc-tests)

# The stub answers `get` from <dir>/<address>.json (exit from <address>.exit,
# 3 = not_found when no file exists), `ls` from <dir>/ls.json, `run` with
# <dir>/run.json, and removes <address>.json on `rm` unless <dir>/rm-sticks
# exists. Every call is logged with its HC_SESSION and HC_SOCKET.
make_hc_fakebin() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/hc" <<'SH'
#!/usr/bin/env bash
set -u
D="${FAKE_HC_DIR:?}"
{
  printf 'HC_SESSION=%s HC_SOCKET=%s' "${HC_SESSION:-}" "${HC_SOCKET:-}"
  printf '%s|%s|%s\n' "${HC_TERMINAL_ID-unset}" "${HC_TERMINAL_SOCKET-unset}" "${HC_SCOPE-unset}" >> "$D/ambient"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$D/log"
cmd=${1:-}
last=""
for a in "$@"; do last=$a; done
case "$cmd" in
  server) printf '{"live":0}\n' ;;
  ls) cat "$D/ls.json" 2>/dev/null || printf '{"terminals":[]}\n' ;;
  run) cat "$D/run.json" ;;
  get)
    [ -f "$D/$last.exit" ] && exit "$(cat "$D/$last.exit")"
    [ -f "$D/$last.json" ] || { printf '{"error":{"kind":"not_found"}}\n' >&2; exit 3; }
    cat "$D/$last.json"
    ;;
  rm) [ -e "$D/rm-sticks" ] || rm -f "$D/$last.json"; printf '{}\n' ;;
  read) if [ -f "$D/$last.screen" ]; then cat "$D/$last.screen"; else printf 'screen of %s\n' "$last"; fi ;;
  *) printf '{}\n' ;;
esac
SH
  chmod +x "$fb/hc"
  # The Herdr.app stub logs every call to <dir>/app.log. `ls` fails when
  # <dir>/app-down exists, answers no spaces for the first <dir>/app-late
  # calls, and otherwise answers <dir>/app-ls.json.
  cat > "$fb/herdr-app" <<'SH'
#!/usr/bin/env bash
set -u
D="${FAKE_HC_DIR:?}"
{ for a in "$@"; do printf '%s\x1f' "$a"; done; printf '\n'; } >> "$D/app.log"
case "${1:-}" in
  ls)
    [ ! -e "$D/app-down" ] || exit 1
    late=$(cat "$D/app-late" 2>/dev/null || echo 0)
    if [ "$late" -gt 0 ]; then echo $((late - 1)) > "$D/app-late"; printf '{"spaces":[]}\n'; exit 0; fi
    cat "$D/app-ls.json" 2>/dev/null || printf '{"spaces":[]}\n'
    ;;
  *) printf '{}\n' ;;
esac
SH
  chmod +x "$fb/herdr-app"
  printf '%s\n' "$fb"
}

# Each case runs in its own shell with a fresh stub directory and home.
setup_case() {  # <name> -> sets D, FB, HOMEDIR
  D="$TMP_ROOT/$1"
  mkdir -p "$D"
  FB=$(make_hc_fakebin "$D")
  HOMEDIR="$D/home"
  mkdir -p "$HOMEDIR"
}

# hc_shell <script>: run <script> in bash with the adapter sourced against the
# stub. HOMETAG is exported so the script can build matching labels.
hc_shell() {  # <script>
  FAKE_HC_DIR=$D PATH="$FB:$PATH" FM_HOME=$HOMEDIR FM_ROOT_OVERRIDE=$HOMEDIR \
    HC_SESSION=fmtest bash -c '
      . "'"$FM_TEST_ROOT"'/bin/fm-backend.sh"
      fm_backend_source hc || { echo "source failed" >&2; exit 90; }
      HOMETAG=$(fm_backend_hometag)
      '"$1"
}

# terminal_json <address> <state> <task-label> <home> <fg-name> <fg-argv0>
write_terminal() {
  jq -n --arg a "$2" --arg s "$3" --arg t "$4" --arg h "$5" --arg n "$6" --arg v "$7" '
    {address: $a, state: $s, labels: {"firstmate.task": $t, "firstmate.home": $h},
     cwd: "/start", foreground: (if $n == "" then null else {name: $n, argv: [$v], cwd: "/live", pid: 1} end)}' \
    > "$1/$2.json"
}

hometag_of() {
  FM_HOME=$HOMEDIR FM_ROOT_OVERRIDE=$HOMEDIR bash -c '. "'"$FM_TEST_ROOT"'/bin/fm-backend.sh"; fm_backend_source hc; fm_backend_hometag'
}

# expect_refused <cmd...>: the command must exit nonzero.
expect_refused() {
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "expected a refusal from: ${*: -1}"
}

FM_TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

test_hc_is_spawn_capable_and_its_marker_alone_never_selects_it() {
  local out
  out=$(bash -c '. "'"$FM_TEST_ROOT"'/bin/fm-backend.sh"
    fm_backend_validate_spawn hc && echo spawn-ok
    unset TMUX HERDR_ENV CMUX_WORKSPACE_ID TERM_PROGRAM REX_BLOCK __CFBundleIdentifier
    HC_TERMINAL_ID=t7 HC_SESSION=x fm_backend_detect >/dev/null && echo detected || echo not-detected
    fm_backend_required_tools hc' 2>&1)
  assert_contains "$out" spawn-ok "hc must be spawn-capable"
  assert_contains "$out" not-detected "an inherited HC_TERMINAL_ID alone must not select hc"
  assert_contains "$out" "hc jq treehouse" "hc needs hc, jq and treehouse"
  pass "hc: spawn-capable, with its tool set, and never selected by its marker alone"
}

test_create_task_is_independent_labeled_and_refuses_duplicates() {
  local out tag
  setup_case create
  printf '{"address":"t9"}\n' > "$D/run.json"
  out=$(hc_shell 'fm_backend_hc_create_task fmtest fm-a1 /proj')
  assert_equals "$out" t9 "create_task prints the new address"
  tag=$(hometag_of)
  out=$(grep $'\x1frun\x1f' "$D/log")
  for want in HC_SESSION=fmtest --keep --no-parent --outlive-parent --no-notify $'--cwd\x1f/proj' \
    "firstmate.task=fm-a1" "firstmate.home=$tag" "firstmate.home-path=$(cd "$HOMEDIR" && pwd -P)" "herdr.space=fm-$tag" "herdr.tab=$tag-fm-a1"; do
    assert_contains "$out" "$want" "hc run must carry $want"
  done
  [ ! -e "$D/app.log" ] || fail "a task on a session Herdr.app does not show must not call the app"
  printf '{"terminals":[{"address":"t9"}]}\n' > "$D/ls.json"
  : > "$D/log"
  expect_refused hc_shell 'fm_backend_hc_create_task fmtest fm-a1 /proj'
  assert_not_contains "$(cat "$D/log")" $'\x1frun\x1f' "a live duplicate must not start a second terminal"
  pass "hc: create_task starts an independent labeled terminal and refuses a duplicate"
}

# app_ls_with <space> <tab>...: the app shows <space> holding these tabs.
app_ls_with() {
  local space=$1
  shift
  jq -n --arg s "$space" '{spaces: [{id: $s, name: "folder", tabs: ($ARGS.positional | map({id: ., name: "1"}))}]}' \
    --args "$@" > "$D/app-ls.json"
}

# primary_endpoint <target>: this home's published primary terminal.
primary_endpoint() {
  mkdir -p "$HOMEDIR/state"
  printf 'schema=fm-primary-endpoint.v1\nharness=kiro-cli\nbackend=hc\ntarget=%s\n' "$1" > "$HOMEDIR/state/.primary-endpoint"
}

app_calls() { cut -d $'\x1f' -f1-3 "$D/app.log" 2>/dev/null | grep -v '^ls' || true; }

test_task_opens_as_a_named_tab_in_the_primarys_space() {
  local tag out
  setup_case primary-space
  tag=$(hometag_of)
  primary_endpoint default:t1
  jq -n '{address: "t1", state: "live", labels: {"herdr.space": "sp9ba4", "herdr.tab": "tbprimary"}}' > "$D/t1.json"
  printf '{"address":"t9"}\n' > "$D/run.json"
  app_ls_with sp9ba4 tbprimary "$tag-fm-a1"
  echo 2 > "$D/app-late"
  out=$(hc_shell 'fm_backend_hc_create_task default fm-a1 /proj' 2>&1)
  assert_equals "$out" t9 "create_task prints only the new address"
  assert_contains "$(grep $'\x1frun\x1f' "$D/log")" "herdr.space=sp9ba4" "the task must join the primary's own space"
  assert_equals "$(app_calls)" \
    "do"$'\x1f'"tab.rename"$'\x1f''{"id":"'"$tag"'-fm-a1","name":"a1"}'$'\n'"do"$'\x1f'"space.rename"$'\x1f''{"id":"sp9ba4","name":"home"}' \
    "once the app shows the tab, only the new tab and its space are renamed, after the task and the home"
  assert_not_contains "$(cat "$D/app.log")" tbprimary "the primary's own tab must never be touched"
  pass "hc: a task opens as a tab named after it in the primary's space, named after the home"
}

test_without_a_primary_space_the_home_space_is_named_again_on_every_spawn() {
  local tag
  setup_case home-space
  tag=$(hometag_of)
  primary_endpoint default:t1
  jq -n '{address: "t1", state: "live", labels: {}}' > "$D/t1.json"
  printf '{"address":"t9"}\n' > "$D/run.json"
  app_ls_with "fm-$tag" "$tag-fm-a1"
  hc_shell 'fm_backend_hc_create_task default fm-a1 /proj' >/dev/null 2>&1 || fail "create_task must succeed"
  assert_contains "$(grep $'\x1frun\x1f' "$D/log")" "herdr.space=fm-$tag" "an unlabeled primary falls back to the home's own space"
  # The last task ended and its space closed; the next one names it again.
  : > "$D/app.log"
  app_ls_with "fm-$tag" "$tag-fm-a2"
  hc_shell 'fm_backend_hc_create_task default fm-a2 /proj' >/dev/null 2>&1 || fail "create_task must succeed"
  assert_contains "$(app_calls)" "space.rename"$'\x1f''{"id":"fm-'"$tag"'","name":"home"}' "a reopened home space gets the home's name back"
  assert_contains "$(app_calls)" '{"id":"'"$tag"'-fm-a2","name":"a2"}' "the new task's tab is named after it"
  pass "hc: without a primary space the home's own space is named after the home on every spawn"
}

# A secondmate is a different home: its terminal opens that home's own space
# rather than the parent's, under the parent's identity labels, and the
# secondmate's own crew then land in the same space.
test_secondmate_opens_its_own_space_which_its_crew_join() {
  local tag mate mate_tag run
  setup_case secondmate-space
  tag=$(hometag_of)
  mate="$D/mate"
  mkdir -p "$mate/state"
  printf 'sm1\n' > "$mate/.fm-secondmate-home"
  mate_tag=$(HOMEDIR=$mate hometag_of)
  primary_endpoint default:t1
  jq -n '{address: "t1", state: "live", labels: {"herdr.space": "sp9ba4", "herdr.tab": "tbprimary"}}' > "$D/t1.json"
  printf '{"address":"t2"}\n' > "$D/run.json"
  app_ls_with "fm-$mate_tag" "$tag-fm-sm1"
  FM_HC_SPACE=elsewhere hc_shell 'fm_backend_hc_create_task default fm-sm1 "'"$mate"'" "'"$mate"'"' >/dev/null 2>&1 \
    || fail "secondmate create_task must succeed"
  run=$(grep $'\x1frun\x1f' "$D/log")
  for want in $'--cwd\x1f'"$mate" "firstmate.task=fm-sm1" "firstmate.home=$tag" "firstmate.home-path=$(cd "$HOMEDIR" && pwd -P)" \
    "herdr.space=fm-$mate_tag" "herdr.tab=$tag-fm-sm1"; do
    assert_contains "$run" "$want" "a secondmate's hc run must carry $want"
  done
  assert_not_contains "$run" "herdr.space=sp9ba4" "a secondmate must not join the parent's space"
  assert_not_contains "$run" "herdr.space=elsewhere" "the parent's FM_HC_SPACE must not move a secondmate"
  assert_equals "$(app_calls)" \
    "do"$'\x1f'"tab.rename"$'\x1f''{"id":"'"$tag"'-fm-sm1","name":"sm1"}'$'\n'"do"$'\x1f'"space.rename"$'\x1f''{"id":"fm-'"$mate_tag"'","name":"sm1"}' \
    "the secondmate's tab and its space are both named after the secondmate"
  : > "$D/log"
  : > "$D/app.log"
  jq -n --arg s "fm-$mate_tag" '{address: "t2", state: "live", labels: {"herdr.space": $s}}' > "$D/t2.json"
  printf 'schema=fm-primary-endpoint.v1\nharness=kiro-cli\nbackend=hc\ntarget=default:t2\n' > "$mate/state/.primary-endpoint"
  printf '{"address":"t3"}\n' > "$D/run.json"
  app_ls_with "fm-$mate_tag" "$mate_tag-fm-c1"
  HOMEDIR=$mate hc_shell 'fm_backend_hc_create_task default fm-c1 /proj' >/dev/null 2>&1 || fail "crew create_task must succeed"
  run=$(grep $'\x1frun\x1f' "$D/log")
  assert_contains "$run" "herdr.space=fm-$mate_tag" "the secondmate's crew must join its space"
  assert_contains "$run" "firstmate.home=$mate_tag" "the secondmate's crew carry the secondmate's own labels"
  assert_contains "$(app_calls)" "space.rename"$'\x1f''{"id":"fm-'"$mate_tag"'","name":"sm1"}' "the crew keep the secondmate's space name"
  pass "hc: a secondmate opens its own space under this home's labels, and its crew join that space"
}

# fm-spawn.sh end to end against the stub: a --secondmate spawn on hc is
# accepted, opens the secondmate home's space under this home's labels, and
# stages a launch that runs in the secondmate home.
test_secondmate_spawn_lands_in_its_home_on_hc() {
  local id="hcsm$$" mate mate_abs tag mate_tag out rc=0 run meta launch staged
  setup_case spawn-secondmate
  mate="$D/mate"
  mkdir -p "$mate/bin" "$mate/data" "$HOMEDIR/state" "$HOMEDIR/data" "$HOMEDIR/config"
  printf '# Firstmate\n' > "$mate/AGENTS.md"
  git -C "$mate" init -q
  git -C "$mate" add AGENTS.md
  git -C "$mate" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  printf 'Lab charter.\n' > "$mate/data/charter.md"
  printf '%s\n' "$id" > "$mate/.fm-secondmate-home"
  mate_abs=$(cd "$mate" && pwd -P)
  printf '#!/bin/sh\nexit 0\n' > "$FB/treehouse"
  chmod +x "$FB/treehouse"
  tag=$(FM_HOME=$HOMEDIR FM_ROOT_OVERRIDE=$FM_TEST_ROOT bash -c '. "'"$FM_TEST_ROOT"'/bin/fm-backend.sh"; fm_backend_source hc; fm_backend_hometag')
  mate_tag=$(HOMEDIR=$mate hometag_of)
  printf '{"address":"t9"}\n' > "$D/run.json"
  jq -n --arg t "fm-$id" --arg h "$tag" '{address: "t9", state: "live", labels: {"firstmate.task": $t, "firstmate.home": $h}, cwd: "/start"}' > "$D/t9.json"
  out=$(FAKE_HC_DIR=$D PATH="$FB:$PATH" FM_HOME=$HOMEDIR FM_ROOT_OVERRIDE=$FM_TEST_ROOT HC_SESSION=fmtest \
    FM_SPAWN_NO_GUARD=1 FM_SKIP_SECONDMATE_SYNC=1 FM_SKIP_SECONDMATE_INHERIT=1 \
    "$FM_TEST_ROOT/bin/fm-spawn.sh" "$id" "$mate" "sh -c 'sleep 60'" --secondmate --backend hc 2>&1) || rc=$?
  launch=$(grep $'\x1fsend\x1f' "$D/log" | sed -n "s/.*\. '\(\/tmp\/fm-$id+[^']*\)'.*/\1/p" | tail -1)
  staged=no
  [ -n "$launch" ] && grep -qF "FM_HOME='$mate_abs'" "$launch" && staged=yes
  rm -rf "/tmp/fm-$id" "/tmp/fm-$id+"*
  expect_code 0 "$rc" "a --secondmate spawn on hc must succeed"$'\n'"$out"
  assert_equals yes "$staged" "the staged launch must run in the secondmate home"
  run=$(grep $'\x1frun\x1f' "$D/log")
  for want in $'--cwd\x1f'"$mate_abs" "firstmate.task=fm-$id" "firstmate.home=$tag" "herdr.space=fm-$mate_tag"; do
    assert_contains "$run" "$want" "the secondmate's hc run must carry $want"
  done
  meta="$HOMEDIR/state/$id.meta"
  for want in kind=secondmate backend=hc hc_session=fmtest hc_terminal=t9 "home=$mate_abs"; do
    assert_contains "$(cat "$meta")" "$want" "the secondmate's record must carry $want"
  done
  pass "hc: fm-spawn --secondmate opens the secondmate home's space and launches it there"
}

test_naming_is_best_effort_and_never_blocks_the_task() {
  local out
  setup_case app-down
  printf '{"address":"t9"}\n' > "$D/run.json"
  touch "$D/app-down"
  out=$(hc_shell 'fm_backend_hc_create_task default fm-a1 /proj' 2>/dev/null) || fail "a closed app must not fail the task"
  assert_equals "$out" t9 "the task starts without the app"
  assert_equals "$(app_calls)" "" "no rename is sent to an app that does not answer"
  rm -f "$D/app-down"
  out=$(FM_HC_APP_WAIT_TRIES=3 hc_shell 'fm_backend_hc_create_task default fm-a2 /proj' 2>&1 >/dev/null)
  assert_contains "$out" "did not show tab" "a tab the app never shows is reported"
  assert_equals "$(app_calls)" "" "nothing is renamed before the app shows the tab"
  pass "hc: naming is best effort: no app, or no tab in time, still starts the task"
}

test_control_interrupt_delivers_the_harness_keys() {
  local tag out rc=0 id=hcint1
  setup_case interrupt
  tag=$(hometag_of)
  write_terminal "$D" t2 live "fm-$id" "$tag" 2.1.312 claude
  mkdir -p "$HOMEDIR/state" "$HOMEDIR/data"
  printf 'window=fmtest:t2\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nharness=claude\nkind=scout\nbackend=hc\nhc_session=fmtest\nhc_terminal=t2\n' \
    "$id" "$D" "$D" > "$HOMEDIR/state/$id.meta"
  out=$(FAKE_HC_DIR=$D PATH="$FB:$PATH" FM_HOME=$HOMEDIR FM_ROOT_OVERRIDE=$HOMEDIR \
    FM_STATE_OVERRIDE="$HOMEDIR/state" FM_DATA_OVERRIDE="$HOMEDIR/data" FM_CONTROL_POLL=0.05 \
    "$FM_TEST_ROOT/bin/fm-control.sh" "$id" interrupt 2>&1) || rc=$?
  expect_code 0 "$rc" "interrupt on an hc task should succeed"$'\n'"$out"
  assert_contains "$(grep $'\x1fkeys\x1f' "$D/log")" $'keys\x1f--json\x1ft2\x1fesc' "interrupt must press Escape on the recorded terminal"
  pass "hc: fm-control interrupt delivers the harness's interrupt key"
}

test_foreign_or_unlabeled_terminal_gets_no_input_and_no_close() {
  local tag
  setup_case foreign
  tag=$(hometag_of)
  write_terminal "$D" t3 live fm-other "$tag" zsh /bin/zsh
  write_terminal "$D" t4 live fm-a1 other-home zsh /bin/zsh
  write_terminal "$D" t5 live "" "" zsh /bin/zsh
  expect_refused hc_shell 'fm_backend_send_key hc fmtest:t3 Enter fm-a1'
  expect_refused hc_shell 'fm_backend_send_key hc fmtest:t4 Enter fm-a1'
  expect_refused hc_shell 'fm_backend_kill hc fmtest:t5'
  expect_refused hc_shell 'fm_backend_kill hc fmtest:t4'
  assert_not_contains "$(cat "$D/log")" $'\x1fkeys\x1f' "no key may reach a foreign terminal"
  assert_not_contains "$(cat "$D/log")" $'\x1fkill\x1f' "no foreign terminal may be closed"
  pass "hc: another task's, another home's, or an unlabeled terminal gets no input and no close"
}

test_invalid_session_never_reaches_hc() {
  setup_case session
  expect_refused hc_shell 'fm_backend_hc_cli "" ls'
  expect_refused hc_shell 'fm_backend_send_key hc :t2 Enter'
  assert_equals "$(cat "$D/log" 2>/dev/null)" "" "an empty or malformed session must not call hc"
  pass "hc: an empty session never falls through to the ambient core"
}

# hc 0.1.14 lets an exported HC_SOCKET win over HC_SESSION, so an inherited one
# would send every call to another core.
test_inherited_socket_never_overrides_the_session() {
  setup_case socket
  HC_SOCKET=/elsewhere/other.sock hc_shell 'fm_backend_hc_cli fmtest ls' >/dev/null
  assert_contains "$(cat "$D/log")" "HC_SESSION=fmtest HC_SOCKET="$'\x1f'"ls" "hc must run with HC_SOCKET unset"
  pass "hc: an inherited HC_SOCKET never overrides the session pin"
}

# hc 0.1.20 wraps `hc send` text in <hc from="tN"> when it sees the caller's
# terminal markers, which broke a relaunch run from inside an hc terminal.
test_ambient_terminal_markers_never_reach_hc() {
  setup_case markers
  HC_TERMINAL_ID=t7 HC_TERMINAL_SOCKET=/run/herdr-core/default.sock HC_SCOPE=scope7 \
    hc_shell 'fm_backend_hc_cli fmtest ls' >/dev/null
  assert_equals "unset|unset|unset" "$(cat "$D/ambient")" "hc must run without HC_TERMINAL_ID, HC_TERMINAL_SOCKET, HC_SCOPE"
  pass "hc: ambient terminal markers never reach hc"
}

test_agent_state_classifies_foreground_and_absence() {
  local tag out
  setup_case state
  tag=$(hometag_of)
  write_terminal "$D" t1 live fm-a1 "$tag" 2.1.312 claude
  write_terminal "$D" t2 live fm-a1 "$tag" zsh /bin/zsh
  write_terminal "$D" t3 finished fm-a1 "$tag" "" ""
  write_terminal "$D" t4 live fm-a1 "$tag" node node
  write_terminal "$D" t5 live fm-a1 "$tag" "" ""
  printf '1\n' > "$D/t6.exit"
  # shellcheck disable=SC2016 # the inner shell expands it
  out=$(hc_shell 'for a in t1 t2 t3 t4 t5 t6 t7; do printf "%s=%s " $a "$(fm_backend_agent_state hc fmtest:$a)"; done')
  assert_equals "$out" "t1=alive t2=dead t3=missing t4=ambiguous t5=unreadable t6=unreadable t7=missing " \
    "agent_state over claude, shell, finished, other, no foreground, core error, not found"
  pass "hc: agent_state maps foreground, finished, not_found and core errors onto the shared vocabulary"
}

test_agent_state_reads_a_shell_wrappers_group() {
  local tag out wrapper
  setup_case wrapper
  tag=$(hometag_of)
  # A shell wrapper in its own process group, waiting on a harness child.
  set -m
  bash -c '(exec -a claude sleep 30); :' &
  wrapper=$!
  set +m
  write_terminal "$D" t9 live fm-a1 "$tag" bash bash
  jq --argjson p "$wrapper" '.foreground.pid = $p' "$D/t9.json" > "$D/t9.tmp" && mv "$D/t9.tmp" "$D/t9.json"
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -g "$wrapper" -f '^claude' >/dev/null && break; sleep 0.1; done
  out=$(hc_shell 'fm_backend_agent_state hc fmtest:t9')
  kill -- "-$wrapper" 2>/dev/null || true
  wait "$wrapper" 2>/dev/null || true
  assert_equals "$out" alive "a shell wrapper running a harness child is alive"
  pass "hc: agent_state reads a shell wrapper's process group before calling it dead"
}

test_kill_proves_the_terminal_is_gone() {
  local tag
  setup_case kill
  tag=$(hometag_of)
  write_terminal "$D" t1 live fm-a1 "$tag" zsh /bin/zsh
  hc_shell 'fm_backend_kill hc fmtest:t1' || fail "closing a live own terminal must succeed"
  assert_contains "$(cat "$D/log")" $'\x1fkill\x1f--json\x1ft1' "kill must end the program"
  assert_contains "$(cat "$D/log")" $'\x1frm\x1f--json\x1ft1' "kill must remove the terminal"
  hc_shell 'fm_backend_kill hc fmtest:t1' || fail "an already-gone terminal is a silent success"
  write_terminal "$D" t2 live fm-a1 "$tag" zsh /bin/zsh
  touch "$D/rm-sticks"
  expect_refused hc_shell 'fm_backend_kill hc fmtest:t2'
  pass "hc: kill ends and removes the terminal and refuses when it survives"
}

test_kill_refuses_another_tasks_terminal() {
  local tag
  setup_case kill-label
  tag=$(hometag_of)
  write_terminal "$D" t1 live fm-other "$tag" zsh /bin/zsh
  write_terminal "$D" t2 live fm-a1 "$tag" zsh /bin/zsh
  expect_refused hc_shell 'fm_backend_kill hc fmtest:t1 "" fm-a1'
  [ -f "$D/t1.json" ] || fail "another task's terminal must stay alive"
  assert_not_contains "$(cat "$D/log")" $'\x1fkill\x1f' "another task's terminal must not be closed"
  hc_shell 'fm_backend_kill hc fmtest:t2 "" fm-a1' || fail "closing the task's own labeled terminal must succeed"
  [ ! -f "$D/t2.json" ] || fail "the task's own terminal must be removed"
  pass "hc: teardown's expected label refuses another task's terminal and closes the matching one"
}

# Forced retirement of an hc secondmate closes its own terminal as this home
# and each of its crew as the secondmate home whose labels they carry.
test_forced_secondmate_teardown_closes_its_crew_as_their_home() {
  local tag mate mate_tag out rc=0
  setup_case teardown-secondmate
  mate="$D/mate"
  mkdir -p "$mate/state" "$mate/data" "$mate/config" "$HOMEDIR/state" "$HOMEDIR/data" "$HOMEDIR/config"
  printf 'sm' > "$mate/.fm-secondmate-home"
  tag=$(hometag_of)
  mate_tag=$(HOMEDIR=$mate hometag_of)
  write_terminal "$D" t2 live fm-sm "$tag" zsh /bin/zsh
  write_terminal "$D" t3 live fm-crew "$mate_tag" zsh /bin/zsh
  printf 'window=fmtest:t2\nendpoint_task_id=sm\nworktree=%s\nproject=%s\nhome=%s\nmode=secondmate\nprojects=\nharness=claude\nyolo=off\nkind=secondmate\nbackend=hc\nhc_session=fmtest\nhc_terminal=t2\n' \
    "$mate" "$mate" "$mate" > "$HOMEDIR/state/sm.meta"
  printf 'window=fmtest:t3\nendpoint_task_id=crew\nworktree=%s\nproject=%s\nharness=claude\nkind=ship\nbackend=hc\nhc_session=fmtest\nhc_terminal=t3\n' \
    "$D/no-crew-copy" "$D/no-crew-copy" > "$mate/state/crew.meta"
  out=$(FAKE_HC_DIR=$D PATH="$FB:$PATH" FM_HOME=$HOMEDIR FM_ROOT_OVERRIDE=$HOMEDIR \
    "$FM_TEST_ROOT/bin/fm-teardown.sh" sm --force 2>&1) || rc=$?
  expect_code 0 "$rc" "forced teardown of an hc secondmate must succeed"$'\n'"$out"
  [ ! -f "$D/t3.json" ] || fail "the secondmate's crew terminal must be closed"
  [ ! -f "$D/t2.json" ] || fail "the secondmate's own terminal must be closed"
  pass "hc: forced secondmate teardown closes its crew as their own home and its own terminal as this one"
}

test_capture_and_current_path_read_the_recorded_terminal() {
  local tag out
  setup_case read
  tag=$(hometag_of)
  write_terminal "$D" t1 live fm-a1 "$tag" zsh /bin/zsh
  out=$(hc_shell 'fm_backend_capture hc fmtest:t1 40 fm-a1; fm_backend_visible_capture hc fmtest:t1 fm-a1; fm_backend_hc_current_path fmtest:t1 fm-a1')
  assert_contains "$out" "screen of t1" "capture reads the recorded terminal"
  assert_contains "$out" "/live" "current_path prefers the foreground cwd"
  assert_contains "$(cat "$D/log")" $'read\x1f--lines\x1f40\x1ft1' "capture asks for the requested history"
  assert_contains "$(cat "$D/log")" $'read\x1f--lines\x1f0\x1ft1' "visible capture reads the screen only"
  pass "hc: capture, visible capture, and current path read the recorded terminal"
}

test_endpoint_validation_binds_hc_meta() {
  local meta out
  setup_case meta
  meta="$D/a1.meta"
  printf 'window=fmtest:t4\nendpoint_task_id=a1\nworktree=/wt\nproject=/p\nbackend=hc\nhc_session=fmtest\nhc_terminal=t4\n' > "$meta"
  out=$(bash -c '. "'"$FM_TEST_ROOT"'/bin/fm-backend.sh"; fm_backend_validate_task_endpoint "'"$meta"'" a1 && echo "$FM_BACKEND_VALIDATED_BACKEND $FM_BACKEND_VALIDATED_TARGET"')
  assert_equals "$out" "hc fmtest:t4" "a consistent hc record validates to its target"
  printf 'window=fmtest:t5\nendpoint_task_id=a1\nworktree=/wt\nproject=/p\nbackend=hc\nhc_session=fmtest\nhc_terminal=t4\n' > "$meta"
  expect_refused bash -c '. "'"$FM_TEST_ROOT"'/bin/fm-backend.sh"; fm_backend_validate_task_endpoint "'"$meta"'" a1 2>/dev/null'
  pass "hc: endpoint validation requires window to equal hc_session:hc_terminal"
}

# make_hc_socket: a real unix socket where hc keeps <session>'s, under a
# private XDG_RUNTIME_DIR, so the launcher probe's socket check is genuine.
make_hc_socket() {  # <session> -> sets RUNDIR and SOCK
  RUNDIR="$D/run"
  SOCK="$RUNDIR/herdr-core/$1.sock"
  mkdir -p "${SOCK%/*}"
  python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$SOCK" \
    || fail "could not create a unix socket for the launcher probe"
}

# launcher_terminal <address> <pid>: the terminal Firstmate itself runs in. It
# carries no task labels, like the captain's own Herdr.app terminal.
launcher_terminal() {
  jq -n --arg a "$1" --argjson p "$2" '{address: $a, state: "live", pid: $p, labels: {}}' > "$D/$1.json"
}

# in_launcher <pid> <script>: run <script> as a process whose environment names
# terminal t1 on the private socket, plus the stale TMUX and Herdr 1 variables
# a herdr-core started from such a pane hands to every terminal.
in_launcher() {  # <pid> <script>
  launcher_terminal t1 "$1"
  FAKE_HC_DIR=$D PATH="$FB:$PATH" FM_HOME=$HOMEDIR FM_ROOT_OVERRIDE=$HOMEDIR \
    XDG_RUNTIME_DIR=$RUNDIR HC_TERMINAL_ID=t1 HC_TERMINAL_SOCKET=$SOCK \
    TMUX='/tmp/tmux-1/default,1,0' TMUX_PANE='%3' HERDR_ENV=1 HERDR_PANE_ID='w28G:p6E' \
    bash -c '
      unset HC_SESSION HC_SOCKET HERDR_SOCKET_PATH HERDR_SESSION
      . "'"$FM_TEST_ROOT"'/bin/fm-backend.sh"
      '"$2"
}

# The captain's case: a herdr-core started from a Herdr 1 pane hands that pane's
# variables to its terminals. Only the terminal whose own shell is an ancestor
# selects hc; the same markers on a process outside that terminal (a tmux or
# Herdr 1 pane started from it, whose server detached) keep their own backend.
test_detect_needs_the_terminal_shell_among_ancestors() {
  local out other
  setup_case detect
  make_hc_socket fmtest
  # shellcheck disable=SC2016 # the inner shell expands it
  out=$(in_launcher $$ 'fm_backend_detect; echo " $FM_BACKEND_DETECT_SIGNAL"; fm_backend_name')
  assert_equals "$out" "hc HC_TERMINAL_ID"$'\n'"hc" "a live hc terminal running this process selects hc over its inherited TMUX and HERDR_ENV"
  assert_contains "$(cat "$D/log")" "HC_SESSION= HC_SOCKET=$SOCK"$'\x1fget\x1f--json\x1ft1' "the probe must ask the terminal's own socket"
  sleep 30 &
  other=$!
  out=$(in_launcher "$other" 'fm_backend_detect')
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  assert_equals "$out" tmux "an hc terminal that is not this process's ancestor must not select hc"
  out=$(in_launcher $$ 'XDG_RUNTIME_DIR=/elsewhere fm_backend_detect')
  assert_equals "$out" tmux "a socket outside hc's own path for its session must not select hc"
  jq '.state = "finished"' "$D/t1.json" > "$D/t1.tmp"
  out=$(in_launcher $$ 'cp "'"$D"'/t1.tmp" "'"$D"'/t1.json"; fm_backend_detect')
  assert_equals "$out" tmux "a finished hc terminal must not select hc"
  rm -f "$SOCK"
  out=$(in_launcher $$ 'fm_backend_detect')
  assert_equals "$out" tmux "a missing socket must not select hc, and no core may be asked"
  pass "hc: runtime detection selects hc only when the named live terminal's shell is an ancestor"
}

# Herdr 1 must not take an inherited pane id for the launcher's own pane, which
# refused every spawn when that pane was gone. A real Herdr 1 pane has no hc
# ancestor, so its claimed identity is still checked exactly as before.
test_herdr_launcher_ignores_a_pane_inherited_by_an_hc_terminal() {
  local out other
  setup_case launcher
  make_hc_socket default
  out=$(in_launcher $$ 'fm_backend_source herdr; fm_backend_herdr_launcher_identity default 2>&1; echo "rc=$?"')
  assert_equals "$out" "rc=2" "an inherited Herdr pane inside a live hc terminal reads as no Herdr launcher"
  sleep 30 &
  other=$!
  out=$(in_launcher "$other" 'fm_backend_source herdr; fm_backend_herdr_launcher_identity default 2>&1; echo "rc=$?"')
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  assert_contains "$out" "rc=1" "outside an hc terminal a claimed Herdr pane is still verified and refused when it cannot be read"
  pass "hc: Herdr 1 placement ignores a pane id an hc terminal inherited and keeps checking real panes"
}

test_supervisor_target_names_the_hc_terminal() {
  local out other
  setup_case supervisor
  make_hc_socket default
  out=$(in_launcher $$ '. "'"$FM_TEST_ROOT"'/bin/fm-supervisor-target-lib.sh"; discover_supervisor_backend; echo; discover_supervisor_target')
  assert_equals "$out" "hc"$'\n'"default:t1" "the supervisor pane is the hc terminal, not the inherited tmux or Herdr pane"
  sleep 30 &
  other=$!
  out=$(in_launcher "$other" '. "'"$FM_TEST_ROOT"'/bin/fm-supervisor-target-lib.sh"; discover_supervisor_backend; echo; discover_supervisor_target')
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  assert_equals "$out" "tmux"$'\n''%3' "without the ancestry proof the tmux pane keeps the supervisor"
  pass "hc: supervisor discovery names the hc terminal Firstmate runs in"
}

# hc's screen read carries no styling, so Kiro's idle placeholder is only
# provably idle when the caller names the Kiro harness, as the doorbell does.
test_kiro_composer_reads_unstyled_idle_as_empty() {
  local out
  setup_case kiro-composer
  launcher_terminal t1 1
  printf 'transcript\n\n› ask a question or describe a task ↵\n' > "$D/t1.screen"
  out=$(hc_shell 'fm_backend_composer_state hc fmtest:t1 "" kiro-cli; echo; fm_backend_composer_state hc fmtest:t1')
  assert_equals "$out" "empty"$'\n'"unknown" "the Kiro idle row reads empty only with the kiro-cli harness"
  printf 'transcript\n\n› half typed command\n' > "$D/t1.screen"
  out=$(hc_shell 'fm_backend_composer_state hc fmtest:t1 "" kiro-cli')
  [ "$out" != empty ] || fail "a typed Kiro draft must never read empty"
  pass "hc: the Kiro composer reads idle as empty for the kiro-cli harness and never calls a draft empty"
}

test_control_can_prove_an_hc_agent_stopped() {
  bash -c '. "'"$FM_TEST_ROOT"'/bin/fm-control-lib.sh"; fm_control_backend_state_verified hc' \
    || fail "hc has a process-level agent-state classifier, so exit and relaunch may rely on it"
  bash -c '. "'"$FM_TEST_ROOT"'/bin/fm-control-lib.sh"; fm_control_backend_relaunch_supported hc' \
    || fail "an hc terminal's shell outlives its agent, so a replacement can be launched into it"
  pass "hc: the control plane accepts hc's agent state as proof for exit and relaunch"
}

test_hc_is_spawn_capable_and_its_marker_alone_never_selects_it
test_create_task_is_independent_labeled_and_refuses_duplicates
test_task_opens_as_a_named_tab_in_the_primarys_space
test_without_a_primary_space_the_home_space_is_named_again_on_every_spawn
test_secondmate_opens_its_own_space_which_its_crew_join
test_secondmate_spawn_lands_in_its_home_on_hc
test_naming_is_best_effort_and_never_blocks_the_task
test_control_interrupt_delivers_the_harness_keys
test_foreign_or_unlabeled_terminal_gets_no_input_and_no_close
test_invalid_session_never_reaches_hc
test_inherited_socket_never_overrides_the_session
test_ambient_terminal_markers_never_reach_hc
test_agent_state_classifies_foreground_and_absence
test_agent_state_reads_a_shell_wrappers_group
test_kill_proves_the_terminal_is_gone
test_kill_refuses_another_tasks_terminal
test_forced_secondmate_teardown_closes_its_crew_as_their_home
test_capture_and_current_path_read_the_recorded_terminal
test_endpoint_validation_binds_hc_meta
test_detect_needs_the_terminal_shell_among_ancestors
test_herdr_launcher_ignores_a_pane_inherited_by_an_hc_terminal
test_supervisor_target_names_the_hc_terminal
test_kiro_composer_reads_unstyled_idle_as_empty
test_control_can_prove_an_hc_agent_stopped
