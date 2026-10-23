#!/usr/bin/env bash
# Portable Kiro Crew (kirocrew) worker adapter regression. It drives
# bin/fm-kirocrew.mjs, bin/fm-kirocrew-run.mjs, bin/fm-kirocrew-setup.sh, the
# fm-spawn launch, and the chat close in bin/fm-task-resources-stop.sh against
# tests/fixtures/fm-kirocrew-fake-gateway.mjs, so it needs Node 22 and no Kiro
# Crew install; docs/verification/kirocrew.md records the live gateway facts the
# fake reproduces.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$ROOT/bin/fm-agent-process-lib.sh"

if ! command -v node >/dev/null 2>&1 || ! node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 22 ? 0 : 1)'; then
  printf 'skip: kirocrew needs Node 22 or newer\n'
  exit 0
fi
command -v jq >/dev/null 2>&1 || { printf 'skip: jq not found\n'; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-kirocrew-harness)
# A suite run from inside a Herdr pane must never reach that pane's server.
unset HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_BIN_PATH
WIRE="$ROOT/bin/fm-kirocrew.mjs"
RUN="$ROOT/bin/fm-kirocrew-run.mjs"
WRITER="$ROOT/bin/fm-busy-event.sh"
PIDS=()
kirocrew_stop_all() {
  local pid
  for pid in "${PIDS[@]:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; done
  # fm-spawn's task temp folders for this suite's spawn ids live outside TMP_ROOT.
  rm -rf /tmp/fm-kc-scout /tmp/fm-kc-scout+* 2>/dev/null
  return 0
}
trap 'kirocrew_stop_all; fm_test_cleanup' EXIT

GW_DIR="$TMP_ROOT/gateway"
mkdir -p "$GW_DIR/crew-home/apps/firstmate"
printf '%s\n' fake-secret > "$GW_DIR/crew-home/apps/firstmate/.app_secret"
FAKE_SECRET=fake-secret FAKE_CREW_HOME="$TMP_ROOT/setup-crew" node "$ROOT/tests/fixtures/fm-kirocrew-fake-gateway.mjs" "$GW_DIR/port" &
PIDS+=("$!")
for _ in $(seq 1 100); do [ -s "$GW_DIR/port" ] && break; sleep 0.05; done
[ -s "$GW_DIR/port" ] || fail 'fake gateway did not start'
GW="http://127.0.0.1:$(cat "$GW_DIR/port")"
gw_calls() { curl -s "$GW/__test/calls"; }
gw_post() { curl -s -X POST -H 'Content-Type: application/json' --data-binary "$2" "$GW$1" >/dev/null; }

wait_for() {  # <seconds> <command...>
  local limit=$1 i=0
  shift
  while ! "$@"; do
    i=$((i + 1))
    [ "$i" -le $((limit * 20)) ] || return 1
    sleep 0.05
  done
}

home="$TMP_ROOT/home"
mkdir -p "$home/config" "$home/state"
printf 'url=%s\ncrew-home=%s\n' "$GW" "$GW_DIR/crew-home" > "$home/config/kirocrew"

# ---- wire module -------------------------------------------------------------

out=$(node "$WIRE" ping --home "$home") || fail "ping failed: $out"
assert_contains "$out" 'gateway=ok app=firstmate' 'ping output'
assert_present "$home/state/.kirocrew-token" 'app token not cached'
[ "$(stat -c %a "$home/state/.kirocrew-token")" = 600 ] || fail 'app token cache is not private'
nosecret="$TMP_ROOT/nosecret"
mkdir -p "$nosecret/config"
printf 'url=%s\ncrew-home=%s\n' "$GW" "$TMP_ROOT/absent" > "$nosecret/config/kirocrew"
node "$WIRE" ping --home "$nosecret" >/dev/null 2>&1
[ "$?" = 4 ] || fail 'a missing app secret must exit 4 (auth)'
down="$TMP_ROOT/down"
mkdir -p "$down/config"
printf 'url=http://127.0.0.1:9\ncrew-home=%s\n' "$GW_DIR/crew-home" > "$down/config/kirocrew"
node "$WIRE" ping --home "$down" >/dev/null 2>&1
[ "$?" = 3 ] || fail 'an unreachable gateway must exit 3'
printf 'stale-token\n' > "$home/state/.kirocrew-token"
node "$WIRE" ping --home "$home" >/dev/null || fail 'a rejected cached token must be re-exchanged once'
rc=0
out=$(node "$WIRE" probe --home "$home" --slot fm-lab-noagent --agent no-such-agent 2>&1) || rc=$?
[ "$rc" = 6 ] || fail "an agent Crew does not offer must exit 6 (refused), got $rc: $out"
assert_contains "$out" 'does not offer the agent no-such-agent' 'the refusal must name the missing agent'
assert_contains "$out" 'KIRO_HOME' 'the refusal must say where Crew reads agent files'
gw_post /__test/hang '{"on":true}'
started=$(date +%s)
rc=0
out=$(FM_KIROCREW_TIMEOUT_MS=300 node "$WIRE" ping --home "$home" 2>&1) || rc=$?
gw_post /__test/hang '{"on":false}'
[ "$rc" = 3 ] || fail "a gateway that never answers must exit 3 (unreachable), got $rc: $out"
assert_contains "$out" 'no answer within 300 ms' 'the timeout must say why'
[ $(( $(date +%s) - started )) -le 3 ] || fail 'the request timeout did not bound the call'
pass "wire: app token exchange and cache, auth and reachability exit codes, token refresh, missing agent, request timeout"

# ---- harness client ----------------------------------------------------------

state="$home/state"
cwd="$TMP_ROOT/worktree"
mkdir -p "$cwd"
CLIENT_PID=
CLIENT_FD=
client_start() {  # <task> <gen> [extra args...]
  local task=$1 gen=$2
  shift 2
  rm -f "$TMP_ROOT/$task.in"
  mkfifo "$TMP_ROOT/$task.in"
  FM_KIROCREW_POLL_MS=50 node "$RUN" --home "$home" --task "$task" --state "$state" --cwd "$cwd" --label lab \
    --busy-writer "$WRITER" --busy-gen "$gen" "$@" < "$TMP_ROOT/$task.in" > "$TMP_ROOT/$task.out" 2>&1 &
  CLIENT_PID=$!
  PIDS+=("$CLIENT_PID")
  exec {CLIENT_FD}>"$TMP_ROOT/$task.in"
}
client_say() { printf '%s\n' "$1" >&"$CLIENT_FD"; }
client_end() {  # close stdin and wait for the exit
  exec {CLIENT_FD}>&-
  wait "$CLIENT_PID" 2>/dev/null
}
busy_is() {  # <task> <expected classification>
  [ "$(fm_busy_classify tmux fake:w kirocrew "$1" "$state")" = "$2" ]
}
slot_of() { tr -d '[:space:]' < "$state/$1.kirocrew-slot"; }
calls_for() {  # <jq filter over one call>
  gw_calls | jq -c "[.[] | select($1)]"
}

gen=$("$WRITER" arm "$state" kc1)
busy_is kc1 'busy fm-spawn' || fail 'arm did not seed busy'
client_start kc1 "$gen" --model claude-sonnet-5.5 --effort high -- 'FIRSTMATE_OP: v1 launch-brief: hello'
wait_for 10 test -e "$state/kc1.turn-ended" || fail "the brief's turn end raised no wake: $(cat "$TMP_ROOT/kc1.out")"
wait_for 5 busy_is kc1 'idle kirocrew-client' || fail 'the brief turn did not settle idle'
slot=$(slot_of kc1)
case "$slot" in fm-lab-kc1-*) ;; *) fail "unexpected chat name: $slot" ;; esac
created=$(calls_for '.method == "POST" and .path == "/api/chat/slots"')
assert_contains "$created" '"agent":"firstmate-worker"' 'chat not created on the worker agent'
assert_contains "$created" '"memory_mode":"temporary"' 'chat memory mode'
assert_contains "$created" '"title":"firstmate · kc1"' 'chat title'
assert_contains "$(calls_for ".path == \"/api/chat/slots/$slot/project\"")" "\"project\":\"$cwd\"" 'project is not the worktree'
assert_contains "$(calls_for ".path == \"/api/chat/slots/$slot/model\"")" 'claude-sonnet-5.5' 'model not set'
assert_contains "$(calls_for ".path == \"/api/chat/slots/$slot/reasoning-effort\"")" '"reasoning_effort":"high"' 'effort not set'
assert_contains "$(calls_for '.path == "/api/chat/mode"')" "\"slot\":\"$slot\"" 'Trust was not requested'
assert_contains "$(calls_for '.path == "/api/chat?ws=1"')" 'FIRSTMATE_OP: v1 launch-brief: hello' 'brief not sent'
assert_contains "$(cat "$TMP_ROOT/kc1.out")" 'waits for approval in the Crew dashboard' 'missing Trust notice'
assert_contains "$(cat "$TMP_ROOT/kc1.out")" 'echo: FIRSTMATE_OP' 'transcript not mirrored'
if [ -r "/proc/$CLIENT_PID/comm" ]; then
  comm=$(cat "/proc/$CLIENT_PID/comm")
  [ "$comm" = fm-kirocrew ] || fail "the running client's kernel process name is $comm, not fm-kirocrew"
  [ "$(fm_agent_process_classify_name "$comm")" = agent ] || fail 'liveness does not read the running client as the agent'
fi
pass "launch: chat on the worker agent in the worktree, model and effort, brief turn ends idle with a wake"

rm -f "$state/kc1.turn-ended"
client_say 'second message'
wait_for 10 test -e "$state/kc1.turn-ended" || fail 'a typed message raised no turn-end wake'
busy_is kc1 'idle kirocrew-client' || fail 'typed turn did not settle'
assert_contains "$(calls_for '.path == "/api/chat?ws=1"')" 'second message' 'typed line not sent'
pass "a typed line becomes a message, and its turn ends idle with a wake"

gw_post /__test/turn-ms '{"ms":20000}'
rm -f "$state/kc1.turn-ended"
client_say 'long work'
wait_for 5 busy_is kc1 'busy kirocrew-client' || fail 'a long turn did not open busy'
client_say 'queued follow-up'
wait_for 5 grep -q 'queued for the next turn' "$TMP_ROOT/kc1.out" || fail 'a send to a busy chat was not queued'
client_say $'\033'
wait_for 5 grep -q '(interrupted)' "$TMP_ROOT/kc1.out" || fail 'Escape did not interrupt'
assert_contains "$(calls_for ".path == \"/api/chat/slots/$slot/stop\"")" stop 'Escape did not stop the turn'
pass "busy turn: a send queues, Escape interrupts"

gw_post /__test/turn-ms '{"ms":20000}'
wait_for 5 busy_is kc1 'busy kirocrew-client' || fail 'the queued follow-up did not start a turn'
rm -f "$state/kc1.turn-ended"
gw_post /__test/drop '{}'
wait_for 10 test -e "$state/kc1.turn-ended" || fail "a dropped chat raised no wake: $(tail -5 "$TMP_ROOT/kc1.out")"
busy_is kc1 'idle kirocrew-client' || fail 'the lost turn did not settle idle'
assert_contains "$(calls_for ".path == \"/api/chat/slots/$slot/resume\"")" "dashboard_$slot" 'dropped chat not resumed'
[ "$(calls_for '.method == "POST" and .path == "/api/chat/slots" and (.body.name | startswith("fm-lab-kc1-"))' | jq length)" = 1 ] \
  || fail 'a dropped chat was replaced by a new chat'
wait_for 5 sh -c "curl -s '$GW/api/chat/slots' -H 'Cookie: mc_token_${GW##*:}=fake-app-token' | jq -e '.[] | select(.project == \"$cwd\")' >/dev/null" \
  || fail 'the resumed chat did not get its worktree back'
pass "gateway restart: the client resumes the chat from its transcript, and the lost turn ends with a wake"

gw_post /__test/turn-ms '{"ms":300}'
client_end
wait_for 5 busy_is kc1 'idle kirocrew-client' || fail 'exit did not settle idle'
gen=$("$WRITER" arm "$state" kc1)
client_start kc1 "$gen" --resume
wait_for 5 grep -q "chat $slot (adopted)" "$TMP_ROOT/kc1.out" || fail "a relaunch did not adopt the recorded chat: $(cat "$TMP_ROOT/kc1.out")"
client_say '/quit'
wait "$CLIENT_PID" || fail '/quit did not exit 0'
assert_contains "$(calls_for ".method == \"DELETE\" and .path == \"/api/chat/slots/$slot\"")" DELETE '/quit did not close the chat'
gen=$("$WRITER" arm "$state" kc1)
client_start kc1 "$gen" --resume
wait_for 5 grep -q "chat $slot (resumed)" "$TMP_ROOT/kc1.out" || fail "a relaunch did not resume the closed chat: $(cat "$TMP_ROOT/kc1.out")"
client_end
gen=$("$WRITER" arm "$state" kc1)
client_start kc1 "$gen" -- 'fresh brief'
wait_for 5 grep -q '(created)' "$TMP_ROOT/kc1.out" || fail 'a fresh launch did not create a chat'
client_end
[ "$(slot_of kc1)" != "$slot" ] || fail 'a fresh launch continued the old chat'
assert_contains "$(calls_for ".method == \"DELETE\" and .path == \"/api/chat/slots/$slot\"" | jq length)" 2 'a fresh launch left the old live chat open'
pass "relaunch adopts or resumes the recorded chat; /quit closes it; a fresh launch starts a new chat"

fakeherdr="$TMP_ROOT/fake-herdr"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n' "$TMP_ROOT/herdr.log" > "$fakeherdr"
chmod +x "$fakeherdr"
gen=$("$WRITER" arm "$state" kc2)
HERDR_BIN_PATH="$fakeherdr" HERDR_ENV=1 HERDR_PANE_ID=w0:p0 client_start kc2 "$gen" -- 'no pane given'
wait_for 10 test -e "$state/kc2.turn-ended" || fail 'kc2 brief turn did not end'
client_end
assert_absent "$TMP_ROOT/herdr.log" 'the client reported to Herdr from inherited variables'
gen=$("$WRITER" arm "$state" kc2)
rm -f "$state/kc2.turn-ended"
HERDR_BIN_PATH="$fakeherdr" client_start kc2 "$gen" --herdr-pane w9:p9 --herdr-session fm-lab-x -- 'with a pane'
wait_for 10 test -e "$state/kc2.turn-ended" || fail 'kc2 second brief turn did not end'
wait_for 5 grep -q -- '--state idle' "$TMP_ROOT/herdr.log" || fail "no idle report: $(cat "$TMP_ROOT/herdr.log" 2>/dev/null)"
client_end
grep -Eq -- '^pane report-agent --source fm-kirocrew --agent kirocrew --state working --seq [0-9]+ w9:p9 --session fm-lab-x$' "$TMP_ROOT/herdr.log" \
  || fail "no working report for the given pane: $(cat "$TMP_ROOT/herdr.log")"
grep -Fxq -- 'pane release-agent --source fm-kirocrew --agent kirocrew w9:p9 --session fm-lab-x' "$TMP_ROOT/herdr.log" || fail 'no release on exit'
pass "Herdr registration uses only the pane fm-spawn passed, and is released on exit"

gen=$("$WRITER" arm "$state" kc3)
FM_KIROCREW_TIMEOUT_MS=200 client_start kc3 "$gen" -- 'outage brief'
wait_for 10 test -e "$state/kc3.turn-ended" || fail "kc3 brief turn did not end: $(cat "$TMP_ROOT/kc3.out")"
wait_for 5 busy_is kc3 'idle kirocrew-client' || fail 'kc3 did not settle idle'
gw_post /__test/hang '{"on":true}'
wait_for 10 busy_is kc3 'unknown kirocrew-client' \
  || fail "a gateway that stopped answering did not turn the record unknown: $(fm_busy_classify tmux fake:w kirocrew kc3 "$state")"
gw_post /__test/hang '{"on":false}'
wait_for 10 busy_is kc3 'idle kirocrew-client' || fail 'the record stayed unknown after the gateway answered again'
client_end
pass "outage: a gateway that stops answering turns the record unknown, and its next answer restores the chat's state"

gen=$("$WRITER" arm "$state" kc4)
client_start kc4 "$gen" -- 'signal brief'
wait_for 10 test -e "$state/kc4.turn-ended" || fail 'kc4 brief turn did not end'
wait_for 5 busy_is kc4 'idle kirocrew-client' || fail 'kc4 did not settle idle'
kc4_slot=$(slot_of kc4)
gw_post /__test/hang '{"on":true}'
sleep 0.3
started=$(date +%s)
kill -TERM "$CLIENT_PID"
wait "$CLIENT_PID" 2>/dev/null
elapsed=$(( $(date +%s) - started ))
exec {CLIENT_FD}>&-
gw_post /__test/hang '{"on":false}'
[ "$elapsed" -le 6 ] || fail "SIGTERM waited ${elapsed}s behind a request the gateway never answered"
busy_is kc4 'idle kirocrew-client' || fail 'SIGTERM did not leave the record idle'
assert_contains "$(cat "$TMP_ROOT/kc4.out")" 'did not confirm the close' 'the bounded close must say it gave up'
pass "SIGTERM ends the client at once while a request hangs, and leaves the record idle"

fakedocker=$(fm_fakebin "$TMP_ROOT/teardown-bin")
fm_fake_exit0 "$fakedocker" docker
resources_stop() {  # <task>
  PATH="$fakedocker:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-task-resources-stop.sh" "$1" 2>&1
}
live_chats() { curl -s "$GW/api/chat/slots" -H "Cookie: mc_token_${GW##*:}=fake-app-token"; }
live_chats | jq -e --arg k "$kc4_slot" 'any(.[]; .key == $k)' >/dev/null || fail 'the hung close should have left the kc4 chat open'
out=$(resources_stop kc4) || fail "resources stop failed: $out"
assert_contains "$out" "Kiro Crew chat $kc4_slot of kc4 is closed" "teardown did not close the chat: $out"
live_chats | jq -e --arg k "$kc4_slot" 'any(.[]; .key == $k) | not' >/dev/null || fail 'the kc4 chat is still live after teardown'
out=$(resources_stop kc4) || fail "a second resources stop failed: $out"
assert_contains "$out" "Kiro Crew chat $kc4_slot of kc4 is closed" 'closing an already closed chat must succeed'
pass "teardown closes the recorded chat a client left open, and a repeat is a no-op"

# ---- firstmate adapter tables --------------------------------------------------

mkdir -p "$TMP_ROOT/names"
ln -s /bin/bash "$TMP_ROOT/names/fm-kirocrew"
ln -s /bin/bash "$TMP_ROOT/names/fm-kirocrew-helper"
# shellcheck disable=SC2016
out=$("$TMP_ROOT/names/fm-kirocrew" -c '"$1"; :' _ "$ROOT/bin/fm-harness.sh")
[ "$out" = kirocrew ] || fail "the client process name must identify kirocrew: $out"
[ "$(fm_agent_process_classify_name /usr/bin/fm-kirocrew)" = agent ] || fail 'liveness lost the kirocrew client'
[ "$(fm_agent_process_classify_name fm-kirocrew-helper)" = other ] || fail 'liveness claims an unrelated executable'
[ "$(fm_control_interrupt_key kirocrew)" = Escape ] || fail 'wrong interrupt key'
[ "$(fm_control_interrupt_repeat kirocrew)" = 1 ] || fail 'one Escape interrupts'
[ "$(fm_control_exit_command kirocrew)" = /quit ] || fail 'wrong exit command'
[ "$(fm_control_harness_family kirocrew)" = kirocrew ] || fail 'recorded family lost'
fm_control_harness_supports_kind kirocrew ship || fail 'ship refused'
fm_control_harness_supports_kind kirocrew scout || fail 'scout refused'
! fm_control_harness_supports_kind kirocrew secondmate || fail 'secondmate accepted'
fm_busy_source_trusted kirocrew kirocrew-client || fail 'kirocrew must trust its client'
! fm_busy_source_trusted kirocrew kiro-hook || fail 'kirocrew trusted another writer'
for signal in 'Kiro Crew is working · esc to cancel' '(sent)' '(queued for the next turn)'; do
  printf '%s\n' "$signal" | fm_busy_lines_match kirocrew || fail "delivery signal lost: $signal"
done
! printf 'Kiro Crew · idle\n› \n' | fm_busy_lines_match kirocrew || fail 'the idle rows read busy'
pass "identity, liveness, control verbs, busy source, and delivery signals"

# ---- fm-spawn launch ------------------------------------------------------------

case_dir="$TMP_ROOT/spawn"
fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
shome="$case_dir/home"
proj="$case_dir/project"
wt="$case_dir/wt"
fm_test_spawn_home "$shome" kirocrew
printf 'url=%s\ncrew-home=%s\n' "$GW" "$GW_DIR/crew-home" > "$shome/config/kirocrew"
fm_git_worktree "$proj" "$wt" kirocrew-test
fm_test_spawn_brief "$shome" kc-scout
out=$(FM_FAKE_LAUNCH_LOG="$case_dir/kc-scout.launch" fm_test_run_spawn "$shome" "$wt" "$fakebin" kc-scout "$proj" \
  --scout --harness kirocrew --model claude-opus-5.5 --effort xhigh) || fail "spawn failed: $out"
launch=$(cat "$case_dir/kc-scout.launch")
gen=$(cat "$shome/state/kc-scout.busy-gen")
assert_contains "$launch" "'$ROOT/bin/fm-kirocrew-run.mjs' --home '$shome' --config-dir '$shome/config' --task 'kc-scout' --state '$shome/state'" 'client arguments'
assert_contains "$launch" "--cwd '$wt'" 'the worktree is not the chat project'
assert_contains "$launch" "--busy-writer '$ROOT/bin/fm-busy-event.sh' --busy-gen '$gen' " 'busy wiring lost'
assert_contains "$launch" "--model 'claude-opus-5.5' --effort 'xhigh' " 'model or effort lost'
# shellcheck disable=SC2016 # the literal command substitution in the template
assert_contains "$launch" '-- "$(' 'typed launch envelope must follow --'
assert_contains "$launch" 'encode launch-brief' 'typed launch envelope lost'
case "$launch" in *--resume*) fail 'a fresh spawn asked to resume' ;; esac
case "$launch" in *--herdr-pane*) fail 'a tmux spawn named a Herdr pane' ;; esac
[ "$(fm_busy_classify tmux fake:w kirocrew kc-scout "$shome/state")" = 'busy fm-spawn' ] || fail 'launch not armed'
if out=$(fm_test_run_spawn "$shome" "$wt" "$fakebin" kc-sm "$proj" --secondmate --harness kirocrew 2>&1)
then fail 'kirocrew secondmate launch accepted'; fi
assert_contains "$out" 'crewmate/scout adapter only' 'wrong secondmate refusal'
printf 'url=http://127.0.0.1:9\ncrew-home=%s\n' "$GW_DIR/crew-home" > "$shome/config/kirocrew"
fm_test_spawn_brief "$shome" kc-down
if out=$(FM_FAKE_LAUNCH_LOG="$case_dir/kc-down.launch" fm_test_run_spawn "$shome" "$wt" "$fakebin" kc-down "$proj" --scout --harness kirocrew 2>&1)
then fail 'a spawn with an unreachable gateway was accepted'; fi
assert_contains "$out" 'Kiro Crew is not usable for this home' "wrong unreachable refusal: $out"
assert_contains "$out" 'fm-kirocrew-setup.sh' 'the refusal must name the setup step'
assert_absent "$case_dir/kc-down.launch" 'launched with an unreachable gateway'
assert_absent "$shome/state/kc-down.meta" 'the refused spawn left a task record'
for backend in zellij cmux; do
  fm_test_spawn_brief "$shome" "kc-$backend"
  if out=$(FM_FAKE_LAUNCH_LOG="$case_dir/kc-$backend.launch" fm_test_run_spawn "$shome" "$wt" "$fakebin" "kc-$backend" "$proj" \
    --scout --harness kirocrew --backend "$backend" 2>&1)
  then fail "kirocrew launch accepted on backend=$backend"; fi
  assert_contains "$out" "kirocrew is verified on the tmux and herdr backends only; backend=$backend" "wrong refusal on $backend: $out"
  assert_absent "$shome/state/kc-$backend.meta" "the refused $backend spawn left a task record"
done
ext="$case_dir/ext-home"
fm_test_spawn_home "$ext" kirocrew
printf 'url=%s\ncrew-home=%s\n' "$GW" "$GW_DIR/crew-home" > "$ext/config/kirocrew"
# shellcheck disable=SC2016 # Backticks are literal adapter text.
printf '%s\n' 'Run `review-tool upload --draft`.' > "$ext/config/external-review.md"
printf -- '- project [direct-PR forge=external] - fixture (added 2026-01-01)\n' > "$ext/data/projects.md"
mkdir -p "$ext/data/kc-ext"
cat > "$ext/data/kc-ext/brief.md" <<'EOF'
# Task
## Captain's intent
Ship a change through the review tool.

## Firstmate spec
Exercise the kirocrew refusal on a forge=external project.

# Definition of done
Delivery contract: mode=direct-PR forge=external
Ship branch: fm/kc-ext
EOF
if out=$(FM_FAKE_LAUNCH_LOG="$case_dir/kc-ext.launch" fm_test_run_spawn "$ext" "$wt" "$fakebin" kc-ext "$proj" \
  --harness kirocrew --mode direct-PR --yolo off 2>&1)
then fail 'a kirocrew ship on a forge=external project was accepted'; fi
assert_contains "$out" 'kirocrew is refused for kc-ext' "wrong forge=external refusal: $out"
assert_contains "$out" 'pre-push guard' 'the refusal must name the guard it cannot carry'
assert_absent "$case_dir/kc-ext.launch" 'launched a forge=external kirocrew ship'
assert_absent "$ext/state/kc-ext.meta" 'the refused forge=external spawn left a task record'
pass "scout launch carries the client, worktree, busy wiring, model, effort and brief; refusals leave nothing behind"

# ---- setup ----------------------------------------------------------------------

setup_home="$TMP_ROOT/setup-home"
kiro_home="$TMP_ROOT/setup-kiro"
mkdir -p "$setup_home/config" "$setup_home/state"
printf 'url=%s\ncrew-home=%s\n' "$GW" "$TMP_ROOT/setup-crew" > "$setup_home/config/kirocrew"
fakecrew="$TMP_ROOT/fake-kirocrew"
# shellcheck disable=SC2016 # $1 belongs to the generated script.
printf '#!/bin/sh\n[ "$1" = token ] && printf "Dashboard: %s/?token=owner-token\\n"\n' "$GW" > "$fakecrew"
shim=$(fm_fakebin "$TMP_ROOT/curl-shim")
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nexec %s "$@"\n' "$TMP_ROOT/curl-argv.log" "$(command -v curl)" > "$shim/curl"
chmod +x "$fakecrew" "$shim/curl"
run_setup() {
  env -u KIROCREW_SPAWNED PATH="$shim:$PATH" "$ROOT/bin/fm-kirocrew-setup.sh" --home "$setup_home" \
    --kiro-home "$kiro_home" --kirocrew-bin "$fakecrew" "$@" 2>&1
}
out=$(run_setup) || fail "setup failed: $out"
jq -e '.name == "firstmate-worker" and .tools == ["*"] and .allowedTools == [] and .includeMcpJson == false' \
  "$kiro_home/agents/firstmate-worker.json" >/dev/null || fail 'setup did not write the worker agent file'
assert_contains "$out" 'registered app firstmate' 'setup did not register the app'
assert_contains "$out" "app firstmate is on Crew's trusted apps list" 'setup did not trust the app'
assert_contains "$out" 'Restart the Kiro Crew gateway' 'a new agent file needs the restart step'
assert_contains "$out" 'enable it' 'an app without consent needs the dashboard step'
assert_contains "$(calls_for '.path == "/api/apps/register"')" '"sessionApproval":true' 'the manifest must ask for sessionApproval'
assert_contains "$(calls_for '.path == "/api/security/trusted-apps/firstmate"')" POST 'the trusted-apps call is missing'
[ -s "$TMP_ROOT/curl-argv.log" ] || fail 'the curl shim saw no call'
assert_no_grep 'owner-token' "$TMP_ROOT/curl-argv.log" 'the owner token reached a curl argument'
out=$(run_setup) || fail "a second setup run failed: $out"
assert_contains "$out" 'agent file is current' 'a second run rewrote the agent file'
assert_contains "$out" 'is already registered' 'a second run registered the app again'
case "$out" in *'Restart the Kiro Crew gateway'*) fail 'an unchanged agent file asked for a restart' ;; esac
out=$(run_setup --check) || fail "setup --check failed: $out"
assert_contains "$out" 'agent=firstmate-worker' 'check did not report the agent'
assert_contains "$out" 'trust=not-granted' 'check did not report the missing Trust'
pass "setup writes the agent file, registers and trusts the app without the owner token in argv, is idempotent, and checks"
