#!/usr/bin/env bash
# tests/fm-control-herdr-smoke.test.sh - real-herdr smoke test for the agent
# lifecycle control plane (bin/fm-control.sh).
#
# tmux is the control plane's reference backend and is covered hermetically in
# tests/fm-control.test.sh. herdr is the OTHER backend whose recovery-grade
# agent-state classifier the control plane is allowed to trust, so its
# behavior is pinned here against the REAL binary rather than a stub: whether
# an agent is running, and therefore whether a lifecycle verb may act at all,
# comes from the exact pane's process tree, not its semantic status registry.
#
# A real Pi is launched without a prompt when installed. A retained registry
# entry over a shell is a separate negative control, not a fake live agent.
#
# Always runs on a private, named, throwaway lab session, never the default
# one (tests/herdr-test-safety.sh; the 2026-07-02 incident). Skips cleanly
# when herdr or jq is missing.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

HERDR_LAB_HELPER=${FM_HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=$("$HERDR_LAB_HELPER" name control-smoke)
export HERDR_SESSION="$SESSION"
REAL_PATH=$PATH
SCRATCH=
CLEANED=0
cleanup_all() {
  [ "$CLEANED" = 0 ] || return 0
  PATH="$REAL_PATH" "$HERDR_LAB_HELPER" teardown "$SESSION" || return 1
  CLEANED=1
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
}
trap cleanup_all EXIT
"$HERDR_LAB_HELPER" provision "$SESSION" || fail "could not provision isolated Herdr lab session"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-control-herdr.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)
HOME_DIR="$SCRATCH/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/hsmoke"
# Even backend-owned CLI calls pass through the guarded helper. Its own CLI
# uses the original PATH, so this adapter never recurses or targets default.
mkdir -p "$SCRATCH/guarded-bin"
export FM_LAB_TEST_PATH="$REAL_PATH" FM_LAB_TEST_SESSION="$SESSION" FM_HERDR_LAB_HELPER="$HERDR_LAB_HELPER"
cat > "$SCRATCH/guarded-bin/herdr" <<'SH'
#!/usr/bin/env bash
args=(); session=$FM_LAB_TEST_SESSION
while [ "$#" -gt 0 ]; do
  case "$1" in --session) session=$2; shift 2 ;; *) args+=("$1"); shift ;; esac
done
case "$session" in "$FM_LAB_TEST_SESSION"|fm-lab-never-started-*) ;; *) exit 97 ;; esac
PATH="$FM_LAB_TEST_PATH" exec "$FM_HERDR_LAB_HELPER" run "$session" "${args[@]}"
SH
chmod +x "$SCRATCH/guarded-bin/herdr"
PATH="$SCRATCH/guarded-bin:$PATH"
export PATH
cat > "$HOME_DIR/data/hsmoke/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise Herdr lifecycle control safely.

## Firstmate spec
Keep the isolated endpoint and worktree intact.
EOF

# A real git worktree so the control plane's checkpoint has a real local copy.
PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b hsmoke "$WT"
PROJ_REAL=$(cd "$PROJ" && pwd -P)
WT_REAL=$(cd "$WT" && pwd -P)

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-hsmoke" "$WT" "$SEEDED_TAB_ID") \
  || fail "create_task failed"
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
[ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] || fail "create_task did not return tab/pane ids"

{
  echo "window=$SESSION:$PANE_ID"
  echo "endpoint_task_id=hsmoke"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
} > "$HOME_DIR/state/hsmoke.meta"

run_control() {
  env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=2 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

# --- no registered agent: the endpoint exists but hosts no agent ------------

OUT=$(run_control hsmoke exit) || fail "exit against an agent-free herdr pane should be idempotent success: $OUT"
case "$OUT" in
  "already-stopped hsmoke"*) : ;;
  *) fail "an agent-free herdr pane should report already-stopped, got: $OUT" ;;
esac
pass "real herdr: exit on a pane with no registered agent is idempotent success"

# --- the recovery-grade read, against the real binary ------------------------
#
# The classification that decides whether a task can be recovered at all is read
# out of what herdr actually answers, so a stub can only confirm the assumption
# already written into the stub. Its logic is pinned portably in
# tests/fm-backend-herdr.test.sh; this is the check that notices when the real
# client stops answering the way that logic expects, and it names the version so
# a release change is attributed rather than mysterious.
HERDR_VERSION=$(herdr status --json --session "$SESSION" | jq -r '.client.version')
version_fail() {  # <message>
  fail "$1 [herdr $HERDR_VERSION]"
}

STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = dead ] \
  || version_fail "a real, present, agent-free pane reads '$STATE' rather than 'dead'; every relaunch would be refused"

# `status --json` is the second signal, and the only one that answers for a
# session whose operational calls cannot be reached at all. A release that drops
# or renames `.server.running` would silently make every gone endpoint
# unrecoverable again, so it is asserted by name on both a live and an absent
# session.
[ "$(fm_backend_herdr_server_running_state "$SESSION")" = running ] \
  || version_fail "this run's own live lab session does not report .server.running=true through status --json"
[ "$(fm_backend_herdr_server_running_state "fm-lab-never-started-$$")" = stopped ] \
  || version_fail "a session with no server does not report .server.running=false, so authoritative absence can no longer be told from an unreadable read"

# Issue #4091's exact stranding shape: an endpoint recorded in a session whose
# server is not running used to read `unreadable` and block recovery.
[ "$(fm_backend_agent_state herdr "fm-lab-never-started-$$:w1:p2")" = missing ] \
  || version_fail "an endpoint in a session with no running server is not classified as recoverable"

# And the safety direction: an uninterpretable read must never license recovery.
[ "$(fm_backend_agent_state herdr "no-separator-here")" = unreadable ] \
  || version_fail "a malformed endpoint target does not stay unreadable"
pass "real herdr $HERDR_VERSION: a gone session reads recoverable while a live pane and a malformed target do not"

FAKEBIN="$SCRATCH/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/codex" <<EOF
#!/usr/bin/env bash
: > "$SCRATCH/codex-launched"
EOF
chmod +x "$FAKEBIN/codex"
printf -v FAKEBIN_Q '%q' "$FAKEBIN"
printf -v PROJ_Q '%q' "$PROJ"
fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" "export PATH=$FAKEBIN_Q:\$PATH" \
  || fail "could not put the inert test harness on the pane PATH"
fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" "cd -- $PROJ_Q" \
  || fail "could not move the agent-free pane out of its recorded worktree"
for _ in $(seq 1 20); do
  [ "$(fm_backend_herdr_current_path "$SESSION:$PANE_ID" 2>/dev/null || true)" != "$PROJ_REAL" ] || break
  sleep 0.1
done
[ "$(fm_backend_herdr_current_path "$SESSION:$PANE_ID" 2>/dev/null || true)" = "$PROJ_REAL" ] \
  || fail "the real Herdr pane did not drift out of its recorded worktree"

OUT=$(env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" hsmoke --relaunch --harness codex) \
  || fail "a drifted, agent-free Herdr pane should be re-homed and relaunched: $OUT"
for _ in $(seq 1 20); do
  [ ! -e "$SCRATCH/codex-launched" ] || break
  sleep 0.1
done
[ -e "$SCRATCH/codex-launched" ] || fail "the replacement harness was not launched"
[ "$(fm_backend_herdr_current_path "$SESSION:$PANE_ID" 2>/dev/null || true)" = "$WT_REAL" ] \
  || fail "the relaunched Herdr shell did not end up in its recorded worktree"
[ "$(sed -n 's/^window=//p' "$HOME_DIR/state/hsmoke.meta" | tail -1)" = "$SESSION:$PANE_ID" ] \
  || fail "the Herdr relaunch replaced its endpoint instead of reusing it"
herdr pane get "$PANE_ID" --session "$SESSION" >/dev/null 2>&1 \
  || fail "the Herdr relaunch removed the endpoint it was required to reuse"
awk -F= '$1 == "harness" {$0="harness=claude"} {print}' "$HOME_DIR/state/hsmoke.meta" \
  > "$HOME_DIR/state/hsmoke.meta.tmp"
mv "$HOME_DIR/state/hsmoke.meta.tmp" "$HOME_DIR/state/hsmoke.meta"
pass "real herdr: a drifted agent-free shell returns to its worktree and reuses the same endpoint"

if OUT=$(run_control hsmoke interrupt 2>&1); then
  fail "interrupt should refuse when herdr reports no agent on the pane: $OUT"
fi
case "$OUT" in
  *"nothing to interrupt"*) : ;;
  *) fail "the interrupt refusal should say there is no agent, got: $OUT" ;;
esac
pass "real herdr: interrupt refuses when the pane processes prove no agent remains"

# A retained registration must not turn a shell into a live process.
herdr pane report-agent "$PANE_ID" --source fm-control-smoke --agent pi --state idle --session "$SESSION" >/dev/null
[ "$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")" = dead ] || fail 'residual registration disguised a shell'
pass 'real herdr: residual semantic registration does not prove agent presence'

if command -v pi >/dev/null 2>&1; then
  # Launch the actual runtime without submitting a model prompt. The installed
  # reporter is read-only; this test never installs or modifies an integration.
  printf 'harness=pi\n' >> "$HOME_DIR/state/hsmoke.meta"
  PI_BIN=$(command -v pi)
  printf -v PI_COMMAND '%q --approve --no-session --no-context-files --no-extensions' "$PI_BIN"
  if [ -f "${HOME}/.pi/agent/extensions/herdr-agent-state.ts" ]; then
    printf -v REPORTER_ARG ' -e %q' "${HOME}/.pi/agent/extensions/herdr-agent-state.ts"
    PI_COMMAND="$PI_COMMAND$REPORTER_ARG"
  fi
  fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" 'bash --noprofile --norc -i' || fail 'nested shell launch failed'
  fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" "$PI_COMMAND" || fail 'Pi launch failed'
  STATE=
  for _ in $(seq 1 100); do
    STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
    [ "$STATE" != alive ] || break
    sleep 0.1
  done
  [ "$STATE" = alive ] || fail "real Pi never classified alive: $STATE"
  pass 'real herdr: idle Pi in a nested shell classifies alive'
  OUT=$(run_control hsmoke interrupt) || fail "real Pi interrupt failed: $OUT"
  [ "$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")" = alive ] || fail 'interrupt lost the live agent'
  OUT=$(run_control hsmoke exit) || fail "real Pi exit did not confirm: $OUT"
  [ "$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")" = dead ] || fail 'exited Pi still classified alive'
  herdr pane get "$PANE_ID" --session "$SESSION" >/dev/null || fail 'exit removed the pane'
  [ -d "$WT" ] || fail 'exit removed the task copy'
  pass 'real herdr: Pi exit is confirmed with nested shell and pane/copy preserved'
else
  echo 'skip: Pi not installed; actual harness exit not verified'
fi
