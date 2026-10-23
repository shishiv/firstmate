#!/usr/bin/env bash
# Portable regression for a firstmate primary that runs in a Kiro Crew chat:
# the app token's renewal after Crew expires it, bin/fm-kirocrew-setup.sh
# --primary, the Kiro hook in Crew's process shape (AgentSpawn, session_key, the
# gateway lock anchor), the kirocrew doorbell ring, the doorbell service's
# restart recovery and closed-chat retirement, and bin/fm-kirocrew-primary.sh.
# Crew is tests/fixtures/fm-kirocrew-fake-gateway.mjs. The gateway frame is a
# bash named kirocrew whose argv says `kirocrew gateway`, and the sandbox
# launcher frame a bash named python3.12, the shapes
# docs/verification/kirocrew.md records. Needs Node 22 and jq.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! command -v node >/dev/null 2>&1 || ! node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 22 ? 0 : 1)'; then
  printf 'skip: kirocrew needs Node 22 or newer\n'
  exit 0
fi
command -v jq >/dev/null 2>&1 || { printf 'skip: jq not found\n'; exit 0; }
command -v setsid >/dev/null 2>&1 || { printf 'skip: setsid not found\n'; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-kirocrew-primary)
unset HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_BIN_PATH TMUX TMUX_PANE
BASE_PATH=${FM_TEST_BASE_PATH:-$(dirname "$(command -v node)"):/usr/bin:/bin:/usr/sbin:/sbin}
PIDS=()
stop_all() {
  local pid
  for pid in "${PIDS[@]:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; done
  cat "$TMP_ROOT"/*.arm-pids 2>/dev/null | while IFS= read -r pid; do kill "$pid" 2>/dev/null; done
  return 0
}
trap 'stop_all; fm_test_cleanup' EXIT

has_line() {  # <exact line> <file> <message>
  grep -qxF -- "$1" "$2" 2>/dev/null || fail "$3"
}
armed() { grep -qx arm "$1" 2>/dev/null; }

wait_for() {  # <seconds> <command...>
  local limit=$1 i=0
  shift
  while ! "$@"; do
    i=$((i + 1))
    [ "$i" -le $((limit * 20)) ] || return 1
    sleep 0.05
  done
}

GW_DIR="$TMP_ROOT/gateway"
mkdir -p "$GW_DIR/crew-home/apps/firstmate"
printf '%s\n' fake-secret > "$GW_DIR/crew-home/apps/firstmate/.app_secret"
FAKE_SECRET=fake-secret FAKE_AGENT=firstmate-worker,firstmate-primary FAKE_TURN_MS=200 \
  FAKE_CREW_HOME="$GW_DIR/crew-home" node "$ROOT/tests/fixtures/fm-kirocrew-fake-gateway.mjs" "$GW_DIR/port" &
PIDS+=("$!")
for _ in $(seq 1 100); do [ -s "$GW_DIR/port" ] && break; sleep 0.05; done
[ -s "$GW_DIR/port" ] || fail 'fake gateway did not start'
GW="http://127.0.0.1:$(cat "$GW_DIR/port")"
WIRE="$ROOT/bin/fm-kirocrew.mjs"
gw_post() { curl -s -X POST -H 'Content-Type: application/json' --data-binary "$2" "$GW$1" >/dev/null; }
calls_for() { curl -s "$GW/__test/calls" | jq -c "[.[] | select($1)]"; }
owner() {  # <method> <path> [json]
  curl -s -X "$1" -H "Cookie: mc_token_${GW##*:}=owner-token" -H 'Content-Type: application/json' ${3:+--data-binary "$3"} "$GW$2"
}
chat_state() { node "$WIRE" state --home "$1" --slot "$2" 2>/dev/null; }
sent_to() {  # <chat> -> every message sent to it, one per line
  calls_for ".method == \"POST\" and .path == \"/api/chat?ws=1\" and .body.slot == \"$1\"" | jq -r '.[].body.message'
}

# ---- wire: the app token after Crew expires it ----------------------------------

wire_home="$TMP_ROOT/wire-home"
mkdir -p "$wire_home/config" "$wire_home/state"
printf 'url=%s\ncrew-home=%s\n' "$GW" "$GW_DIR/crew-home" > "$wire_home/config/kirocrew"
node "$WIRE" ping --home "$wire_home" >/dev/null || fail 'ping failed before the token expired'
gw_post /__test/expire-token '{}'
out=$(node "$WIRE" ping --home "$wire_home" 2>&1) || fail "an expired cached app token (Crew answers 403 forbidden) was not renewed: $out"
[ "$(cat "$wire_home/state/.kirocrew-token")" = fake-app-token-2 ] || fail 'the renewed app token was not cached'
pass "wire: a cached app token that Crew expired is renewed once"

# ---- a firstmate home whose digest, drain, and arm are recorders ----------------

CREW_BIN=$(fm_fakebin "$TMP_ROOT/crew-bin")
ln -s "$(command -v bash)" "$CREW_BIN/kirocrew"
ln -s "$(command -v bash)" "$CREW_BIN/python3.12"
make_home() {  # <dir> -> the home root, which is its own checkout
  local root=$1/firstmate log=$1/calls.log
  mkdir -p "$root/bin" "$root/state" "$root/config"
  git -C "$root" init -q
  : > "$root/AGENTS.md"
  for f in "$ROOT"/bin/*; do ln -s "$f" "$root/bin/${f##*/}"; done
  # Node resolves a symlinked main module to its target, so the wire module's
  # run-as-a-command check needs real copies.
  rm -f "$root/bin/fm-kirocrew.mjs" "$root/bin/fm-kirocrew-run.mjs"
  cp "$ROOT/bin/fm-kirocrew.mjs" "$ROOT/bin/fm-kirocrew-run.mjs" "$root/bin/"
  rm -f "$root/bin/fm-sessionstart-run.sh" "$root/bin/fm-watch-arm.sh" "$root/bin/fm-wake-drain.sh"
  cat > "$root/bin/fm-sessionstart-run.sh" <<SH
#!/usr/bin/env bash
printf 'session-open %s\n' "\$*" >> '$log'
"\$(dirname "\$0")/fm-lock.sh" >/dev/null 2>&1 || printf 'lock refused\n' >> '$log'
printf 'DIGEST: fake session start\n'
SH
  cat > "$root/bin/fm-watch-arm.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$\$" >> '$1.arm-pids'
printf 'arm\n' >> '$log'
printf 'watcher: started pid=%s\n' "\$\$"
exec sleep 300
SH
  cat > "$root/bin/fm-wake-drain.sh" <<SH
#!/usr/bin/env bash
printf 'drain\n' >> '$log'
SH
  chmod +x "$root/bin/fm-sessionstart-run.sh" "$root/bin/fm-watch-arm.sh" "$root/bin/fm-wake-drain.sh"
  printf 'url=%s\ncrew-home=%s\n' "$GW" "$GW_DIR/crew-home" > "$root/config/kirocrew"
  : > "$log"
  printf '%s\n' "$root"
}

# ---- setup --primary ----------------------------------------------------------------

case_dir="$TMP_ROOT/crew"
mkdir -p "$case_dir"
home=$(make_home "$case_dir")
kiro_home="$TMP_ROOT/kiro-home"
fakecrew="$TMP_ROOT/fake-kirocrew"
# shellcheck disable=SC2016 # $1 belongs to the generated script.
printf '#!/bin/sh\n[ "$1" = token ] && printf "Dashboard: %s/?token=owner-token\\n"\n' "$GW" > "$fakecrew"
SYSTEMD=$(fm_fakebin "$TMP_ROOT/systemd")
cat > "$SYSTEMD/systemctl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$TMP_ROOT/systemctl.log'
case "\$*" in
  *is-active*) [ -e '$TMP_ROOT/service.active' ] || { echo inactive; exit 3; }; echo active ;;
  *'enable --now'*) : > '$TMP_ROOT/service.active' ;;
esac
SH
chmod +x "$fakecrew" "$SYSTEMD/systemctl"
run_setup() {
  env -u KIROCREW_SPAWNED -u FM_HOME XDG_CONFIG_HOME="$TMP_ROOT/xdg" PATH="$SYSTEMD:$PATH" "$home/bin/fm-kirocrew-setup.sh" \
    --home "$home" --kiro-home "$kiro_home" --kirocrew-bin "$fakecrew" --primary 2>&1
}
out=$(run_setup) || fail "setup --primary failed: $out"
agent="$kiro_home/agents/firstmate-primary.json"
jq -e '.name == "firstmate-primary" and .tools == ["*"] and .hooks.preToolUse[0].matcher == "execute_bash"
  and .hooks.agentSpawn[0].timeout_ms > 120000 and .hooks.userPromptSubmit[0].timeout_ms > 120000
  and (.hooks | keys) == ["agentSpawn", "preToolUse", "stop", "userPromptSubmit"]' "$agent" >/dev/null \
  || fail "setup --primary wrote a wrong primary agent file: $(cat "$agent")"
HOOK_CMD=$(jq -r '.hooks.agentSpawn[0].command' "$agent")
for event in userPromptSubmit preToolUse stop; do
  [ "$(jq -r ".hooks.${event}[0].command" "$agent")" = "$HOOK_CMD" ] || fail "the $event hook runs another command"
done
UNIT=$(FM_HOME="$home" "$home/bin/fm-primary-doorbell.sh" unit)
case "$UNIT" in fm-doorbell-firstmate-*.service) ;; *) fail "unexpected doorbell unit name: $UNIT" ;; esac
unit_file="$TMP_ROOT/xdg/systemd/user/$UNIT"
assert_present "$unit_file" 'setup --primary wrote no doorbell unit'
has_line "Environment=\"FM_HOME=$home\"" "$unit_file" 'the unit does not name the home'
has_line "ExecStart=\"$home/bin/fm-primary-doorbell.sh\" serve" "$unit_file" 'the unit does not run serve'
has_line 'Restart=always' "$unit_file" 'the unit does not restart the service'
has_line "--user enable --now $UNIT" "$TMP_ROOT/systemctl.log" 'the service was not enabled and started'
assert_contains "$out" 'Restart the Kiro Crew gateway' 'a new primary agent file needs the gateway restart step'
: > "$TMP_ROOT/systemctl.log"
out=$(run_setup) || fail "a second setup --primary failed: $out"
assert_contains "$out" "agent file is current: $agent" 'a second run rewrote the primary agent file'
assert_no_grep 'restart' "$TMP_ROOT/systemctl.log" 'an unchanged unit was restarted'
pass "setup --primary writes the primary agent file and this home's doorbell service, and a second run changes nothing"

# ---- the Kiro hook in Crew's process shape ----------------------------------------

CHAT=fm-test-primary
owner POST /api/chat/slots "{\"name\":\"$CHAT\",\"agent\":\"firstmate-primary\",\"agent_kind\":\"template\",\"memory_mode\":\"temporary\"}" >/dev/null
[ "$(chat_state "$home" "$CHAT")" = "state=idle gen=gen-1" ] || fail "the test chat was not created, or Crew reports no generation: $(chat_state "$home" "$CHAT")"
state="$home/state"
: > "$state/task.meta"
# One gateway process fires hooks the way Crew does: the sandbox launcher frame
# runs the agent file's command with /bin/sh -c in the chat's project folder,
# under Crew's environment allowlist, with the payload on stdin. The gateway
# then stays alive until the test removes its keep file, because the lock and
# the record name its pid. Its argv is the venv entry script's, or, as after a
# dashboard restart, `python -m kiro_crew gateway`.
cat > "$case_dir/gateway.sh" <<'SH'
printf '%s\n' "$$" > "$FM_TEST_DIR/gateway.pid"
for event in $FM_TEST_EVENTS; do
  printf '{"hook_event_name": "%s", "cwd": "%s", "session_key": "%s"}' "$event" "$FM_TEST_ROOT" "$FM_TEST_KEY" \
    | (cd "$FM_TEST_ROOT" && env -i HOME="$HOME" PATH="$PATH" KIROCREW_SPAWNED=1 KIROCREW_HOOK_EVENT="$event" \
      "$FM_TEST_CREW_BIN/python3.12" -c '/bin/sh -c "$1"; exit $?' launcher "$FM_TEST_HOOK") >> "$FM_TEST_DIR/$event.out"
done
: > "$FM_TEST_DIR/fired"
while [ -e "$FM_TEST_DIR/keep" ]; do sleep 0.1; done
SH
start_gateway() {  # <events> [<session-key>] [script|python]
  local frame=$CREW_BIN/kirocrew argv0='/opt/crew/venv/bin/kirocrew gateway --no-open'
  if [ "${3:-script}" = python ]; then
    frame=$CREW_BIN/python3.12
    argv0='/opt/crew/venv/bin/python3.12 -s -P -m kiro_crew gateway --no-open'
  fi
  rm -f "$case_dir/fired" "$case_dir"/*.out
  : > "$case_dir/keep"
  # shellcheck disable=SC2016 # $0 and $@ belong to the bash that sets the gateway's argv.
  (cd "$case_dir" && env -i HOME="$case_dir" PATH="$BASE_PATH" FM_TEST_DIR="$case_dir" FM_TEST_ROOT="$home" \
    FM_TEST_EVENTS="$1" FM_TEST_KEY="${2:-dashboard:$CHAT}" FM_TEST_CREW_BIN="$CREW_BIN" FM_TEST_HOOK="$HOOK_CMD" \
    FM_TEST_ARGV0="$argv0" bash -c 'exec -a "$FM_TEST_ARGV0" "$0" "$@"' "$frame" "$case_dir/gateway.sh") &
  PIDS+=("$!")
  wait_for 60 test -e "$case_dir/fired" || fail "the gateway's hooks did not finish: $(cat "$case_dir/calls.log")"
  GATEWAY_PID=$(cat "$case_dir/gateway.pid")
}

start_gateway 'AgentSpawn UserPromptSubmit Stop'
log="$case_dir/calls.log"
[ "$(grep -c '^session-open --source startup$' "$log")" -eq 1 ] \
  || fail "AgentSpawn must open the session once, and the next prompt must find the lock owned: $(cat "$log")"
[ "$(head -n 1 "$state/.lock")" = "$GATEWAY_PID" ] || fail 'the session lock is not on the gateway pid'
record="$state/.primary-endpoint"
has_line 'backend=kirocrew' "$record" 'the record does not name the kirocrew backend'
has_line "target=$CHAT" "$record" 'the record does not name the chat from session_key'
has_line "pid=$GATEWAY_PID" "$record" 'the record does not name the gateway pid'
out=$(cat "$case_dir/AgentSpawn.out")
assert_contains "$out" 'DIGEST: fake session start' 'the AgentSpawn digest must reach the context'
assert_contains "$out" 'nothing rings it' 'a home with no doorbell service must hear that nothing rings its doorbell'
assert_contains "$(cat "$case_dir/UserPromptSubmit.out")" 'nothing rings it' 'every prompt must repeat that nothing rings the doorbell'
sleep 1
! armed "$log" || fail 'a Crew hook started a watcher arm inside the sandbox'
pass "Crew hook: AgentSpawn opens the session on the gateway lock, the record names the chat, and no hook arms a watcher"

# ---- the kirocrew ring ---------------------------------------------------------------

ring() {  # <kind> -> prints the ring result
  FM_STATE_OVERRIDE="$state" FM_HOME="$home" bash -c '
    . "$0/bin/fm-primary-endpoint-lib.sh"
    fm_primary_endpoint_ring_kiro "$FM_STATE_OVERRIDE" "$0" "$FM_HOME" "$1" || :
    printf "%s" "$FM_PRIMARY_ENDPOINT_RING_RESULT"' "$home" "$1"
}
[ "$(ring wake)" = sent ] || fail 'a ring to an idle chat was not sent'
assert_contains "$(sent_to "$CHAT")" ': Firstmate wake waiting:' 'the chat did not get the doorbell line'
assert_contains "$(sent_to "$CHAT")" "$home/bin/fm-wake-drain.sh" 'the doorbell line does not name the drain'
gw_post /__test/turn-ms '{"ms":20000}'
curl -s -X POST -H "Cookie: mc_token_${GW##*:}=$(cat "$state/.kirocrew-token")" -H 'Content-Type: application/json' \
  --data-binary "{\"slot\":\"$CHAT\",\"message\":\"captain typing\"}" "$GW/api/chat?ws=1" >/dev/null
before=$(sent_to "$CHAT" | wc -l)
[ "$(ring wake)" = refused ] || fail 'a ring to a busy chat was not refused'
[ "$(sent_to "$CHAT" | wc -l)" = "$before" ] || fail 'a ring sent a message to a busy chat'
curl -s -X POST -H "Cookie: mc_token_${GW##*:}=$(cat "$state/.kirocrew-token")" "$GW/api/chat/slots/$CHAT/stop" >/dev/null
gw_post /__test/turn-ms '{"ms":200}'
pass "kirocrew ring: an idle chat gets the doorbell line as a message, and a busy chat gets nothing"

# ---- the doorbell service --------------------------------------------------------------

doorbell() {
  FM_HOME="$home" FM_PRIMARY_DOORBELL_POLL=0.2 FM_PRIMARY_DOORBELL_SERVE_POLL=0.2 FM_PRIMARY_DOORBELL_CREW_CHECK=0 \
    "$home/bin/fm-primary-doorbell.sh" "$@"
}
rc=0
out=$(doorbell ensure) || rc=$?
[ "$rc" = 5 ] || fail "ensure for a Crew primary with no doorbell service must exit 5, got $rc: $out"
assert_contains "$out" "$UNIT" 'the refusal must name the doorbell unit'
doorbell serve >"$case_dir/serve.out" 2>&1 &
SERVE_PID=$!
PIDS+=("$SERVE_PID")
wait_for 10 armed "$log" || fail "the doorbell service did not start the owner's watcher arm: $(cat "$case_dir/serve.out")"
out=$(doorbell ensure) || fail "ensure failed while the doorbell service runs: $out"
assert_contains "$out" 'doorbell-owner: running' 'ensure did not see the owner the service started'
out=$(doorbell serve) || fail "a second serve failed: $out"
assert_contains "$out" 'another doorbell service runs' 'a second service did not stand down'
pass "doorbell service: ensure never forks a Crew owner, the service starts it, and one service runs per home"

# A service restart: the gateway pid dies and Crew drops the live chat but keeps
# its transcript. The service resumes the chat once and sends the restart line.
dead=$GATEWAY_PID
gw_post /__test/drop '{}'
rm -f "$case_dir/keep"
wait_for 10 sh -c "! kill -0 $dead 2>/dev/null" || fail 'the fake gateway did not stop'
wait_for 20 grep -qs "	rung	" "$state/.primary-doorbell-recovery" \
  || fail "the service did not recover the chat after the gateway restart: $(cat "$state/.primary-doorbell-recovery" 2>/dev/null)"
assert_contains "$(calls_for ".path == \"/api/chat/slots/$CHAT/resume\"")" "dashboard_$CHAT" 'the dropped chat was not resumed'
assert_contains "$(sent_to "$CHAT")" 'the Kiro Crew gateway restarted' 'the resumed chat did not get the restart line'
sleep 1
[ "$(sent_to "$CHAT" | grep -c 'gateway restarted')" = 1 ] || fail 'the restart line was sent more than once for one restart'
pass "doorbell service: after a gateway restart it resumes the dropped chat once and sends the restart line"

# The chat's next prompt takes the lock on the new gateway, here in the form a
# dashboard restart leaves, and republishes the record.
arms=$(grep -cx arm "$log")
start_gateway 'UserPromptSubmit' "dashboard:$CHAT" python
has_line "pid=$GATEWAY_PID" "$record" 'the prompt after the restart did not republish the record on the new gateway'
[ "$(grep -c '^session-open --source startup$' "$log")" -eq 2 ] || fail "the prompt after the restart did not retake the dead gateway's lock: $(cat "$log")"
wait_for 10 sh -c "[ \"\$(grep -cx arm '$log')\" -gt $arms ]" || fail 'the service did not serve the new gateway'
pass "doorbell service: the chat retakes the lock on the new gateway in its re-executed form, and the service serves it"

# A dashboard restart re-executes the gateway in place: the pid stays, Crew's
# generation changes, the turn in flight is lost, and the captain's own chat is
# restored. The owner sees the generation change, and the service sends the
# restart line once, with nothing to resume.
resumes=$(calls_for ".path == \"/api/chat/slots/$CHAT/resume\"" | jq length)
gw_post /__test/drop '{"keep_owner":true}'
wait_for 20 grep -qs "^gen-3	rung	" "$state/.primary-doorbell-recovery" \
  || fail "the service did not recover from an in-place restart: $(cat "$state/.primary-doorbell-recovery" 2>/dev/null)"
[ "$(sent_to "$CHAT" | grep -c 'gateway restarted')" = 2 ] || fail 'an in-place restart did not get exactly one restart line'
[ "$(calls_for ".path == \"/api/chat/slots/$CHAT/resume\"" | jq length)" = "$resumes" ] || fail 'a chat Crew restored was resumed'
has_line "pid=$GATEWAY_PID" "$record" 'an in-place restart moved the record off the gateway pid'
pass "doorbell service: an in-place gateway restart under the same pid gets one restart line and no resume"

# Then the captain closes the chat under that live gateway: the owner's next
# ring finds it gone, retires the record, and nothing resumes it.
owner DELETE "/api/chat/slots/$CHAT" >/dev/null
resumes=$(calls_for ".path == \"/api/chat/slots/$CHAT/resume\"" | jq length)
FM_STATE_OVERRIDE="$state" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" bash -c \
  '. "$0/bin/fm-wake-lib.sh"; fm_wake_append check primary-doorbell "check: primary doorbell"' "$home" \
  || fail 'could not queue a wake row'
wait_for 30 test ! -e "$record" || fail 'the owner did not retire the record of a chat the captain closed'
sleep 1
[ "$(calls_for ".path == \"/api/chat/slots/$CHAT/resume\"" | jq length)" = "$resumes" ] || fail 'a chat the captain closed was resumed'
kill -0 "$SERVE_PID" 2>/dev/null || fail 'the doorbell service exited with its owner'
pass "doorbell service: a chat the captain closes is retired, not resumed"
kill "$SERVE_PID" 2>/dev/null
wait "$SERVE_PID" 2>/dev/null
rm -f "$case_dir/keep"

# A Crew session key that is no dashboard chat publishes no doorbell, and its
# Stop still arms no watcher inside the sandbox.
wait_for 10 sh -c "! kill -0 $GATEWAY_PID 2>/dev/null" || fail 'the fake gateway did not stop'
: > "$log"
start_gateway 'AgentSpawn Stop' 'channel:slack-c1'
assert_contains "$(cat "$case_dir/AgentSpawn.out")" 'structural wake doorbell unavailable' 'a channel session must hear that no doorbell is published'
sleep 1
! armed "$log" || fail "a Crew hook with no loadable doorbell armed a watcher inside the sandbox"
rm -f "$case_dir/keep"
pass "Crew hook: a session that is no dashboard chat publishes no doorbell and arms no watcher"

# ---- the launcher --------------------------------------------------------------------

launch() { env -u KIROCREW_SPAWNED -u FM_HOME PATH="$SYSTEMD:$PATH" "$home/bin/fm-kirocrew-primary.sh" --kirocrew-bin "$fakecrew" "$@" 2>&1; }
TAG=$(. "$ROOT/bin/fm-backend-hometag-lib.sh" && FM_HOME=$home FM_ROOT=$home fm_backend_hometag)
PCHAT="fm-$TAG-primary"
rm -f "$TMP_ROOT/service.active"
out=$(launch) && fail "the launcher opened a chat while the doorbell service is down: $out"
assert_contains "$out" 'is not running' 'the launcher must say the doorbell service is down'
: > "$TMP_ROOT/service.active"
out=$(launch --model claude-opus-5.5 --effort high --title 'firstmate · principal' --message 'assuma') \
  || fail "the launcher failed: $out"
assert_contains "$out" "chat $PCHAT is created" "the launcher did not create the chat: $out"
row=$(owner GET /api/chat/slots | jq -c --arg k "$PCHAT" '.[] | select(.key == $k)')
[ "$(jq -r '[.agent, .origin, .project, .model, .reasoning_effort, .trust, .title] | join("|")' <<<"$row")" \
  = "firstmate-primary|user|$home|claude-opus-5.5|high|true|firstmate · principal" ] || fail "the primary chat is configured wrong: $row"
[ "$(sent_to "$PCHAT")" = assuma ] || fail "the first message was not sent once: $(sent_to "$PCHAT")"
out=$(launch) || fail "a second launch failed: $out"
assert_contains "$out" 'nothing changed' 'a second launch changed an open chat'
gw_post /__test/drop '{}'
out=$(launch) || fail "a launch after a restart failed: $out"
assert_contains "$out" "chat $PCHAT is resumed" 'a launch after a restart did not resume the chat'
[ "$(sent_to "$PCHAT")" = assuma ] || fail 'a resumed chat got the first message again'
[ "$(owner GET /api/chat/slots | jq -r --arg k "$PCHAT" '.[] | select(.key == $k) | .agent')" = firstmate-primary ] \
  || fail 'the resumed chat lost the primary agent'
owner POST "/api/chat/slots/$PCHAT/agent" '{"agent":"firstmate-worker"}' >/dev/null
out=$(launch) && fail "the launcher took over a conversation on another agent: $out"
assert_contains "$out" "holds a conversation on the agent 'firstmate-worker'" 'the refusal must name the other agent'
pass "launcher: refuses without the doorbell service, turns the empty chat Crew opens into the captain's own primary in Trust, resumes it after a restart, and refuses a chat on another agent"
