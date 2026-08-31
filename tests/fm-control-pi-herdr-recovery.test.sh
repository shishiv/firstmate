#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTROL="$ROOT/bin/fm-control.sh"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

for tool in herdr jq pi; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done

SESSION=$("$LAB_HELPER" name pi-shell-recovery)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-control-pi-herdr-recovery.XXXXXX")
HOME_DIR="$TMP/home"
PROJECT="$TMP/project"
WT="$TMP/wt"
FAKEBIN="$TMP/fakebin"
ORIGINAL_PATH=$PATH
STALE_PANE_FILE="$TMP/stale-pane"
PANE=

cleanup() {
  local rc=$?
  trap - EXIT
  "$LAB_HELPER" teardown "$SESSION" >/dev/null 2>&1 || rc=1
  rm -rf "$TMP"
  exit "$rc"
}
trap cleanup EXIT

"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr session"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/pirecovery" "$PROJECT" "$FAKEBIN" "$TMP/pi-agent"
printf '# probe\n' > "$PROJECT/README.md"
git -C "$PROJECT" init -q || fail "could not initialize the probe repository"
git -C "$PROJECT" add README.md || fail "could not stage the probe repository"
git -C "$PROJECT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial || fail "could not commit the probe repository"
git -C "$PROJECT" worktree add --quiet -b pirecovery "$WT" || fail "could not create the isolated task worktree"
cat > "$TMP/trust.ts" <<'EOF'
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
export default function (pi: ExtensionAPI) {
  pi.on("project_trust", () => ({ trusted: "yes", remember: false }));
}
EOF
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -euo pipefail
helper='$LAB_HELPER'
session='$SESSION'
real_path='$ORIGINAL_PATH'
stale_pane_file='$TMP/stale-pane'
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "\$session" ] || exit 97
  args=("\${args[@]:0:\$((n-2))}")
else
  [ "\${HERDR_SESSION:-}" = "\$session" ] || exit 98
fi
if [ "\${FM_STALE_PI_STATE:-}" = 1 ] && [ "\${args[0]:-} \${args[1]:-}" = 'agent get' ] && [ -f "\$stale_pane_file" ] && [ "\${args[2]:-}" = "\$(cat "\$stale_pane_file")" ]; then
  printf '%s\n' '{"result":{"agent":{"agent":"pi","agent_status":"idle"}}}'
  exit 0
fi
PATH="\$real_path" exec "\$helper" run "\$session" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

workspace=$("$LAB_HELPER" run "$SESSION" workspace create --cwd "$WT" --label pi-recovery --no-focus | jq -r '.result.workspace.workspace_id')
tab_result=$("$LAB_HELPER" run "$SESSION" tab create --workspace "$workspace" --cwd "$WT" --label fm-pirecovery --no-focus)
TAB=$(printf '%s' "$tab_result" | jq -r '.result.tab.tab_id')
PANE=$(printf '%s' "$tab_result" | jq -r '.result.root_pane.pane_id')
[ -n "$PANE" ] && [ "$PANE" != null ] || fail "could not create the Pi probe pane"

{
  echo "window=$SESSION:$PANE"
  echo "endpoint_task_id=pirecovery"
  echo "worktree=$WT"
  echo "project=$PROJECT"
  echo 'harness=pi'
  echo 'kind=ship'
  echo 'mode=no-mistakes'
  echo 'yolo=off'
  echo 'model=default'
  echo 'effort=default'
  echo 'backend=herdr'
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$workspace"
  echo "herdr_tab_id=$TAB"
  echo "herdr_pane_id=$PANE"
} > "$HOME_DIR/state/pirecovery.meta"
printf '# brief\n\nContinue safely.\n' > "$HOME_DIR/data/pirecovery/brief.md"

PI_CMD=$(printf 'env PI_CODING_AGENT_DIR=%q pi -e %q --no-context-files --no-session' "$TMP/pi-agent" "$TMP/trust.ts")
"$LAB_HELPER" run "$SESSION" pane run "$PANE" "$PI_CMD" >/dev/null || fail "could not start the isolated Pi probe"

live_state=
for _ in $(seq 1 100); do
  live_state=$("$LAB_HELPER" run "$SESSION" agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty' 2>/dev/null || true)
  case "$live_state" in idle|done|blocked) break ;; esac
  sleep 0.1
done
case "$live_state" in idle|done|blocked) ;; *) fail "the live Pi probe never registered" ;; esac
printf '%s\n' "$PANE" > "$STALE_PANE_FILE"
live_verdict=$(FM_STALE_PI_STATE=1 PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state herdr "$1"' "$ROOT" "$SESSION:$PANE")
[ "$live_verdict" = alive ] || fail "a live Pi process with a stale idle record must stay protected, got $live_verdict"

"$LAB_HELPER" run "$SESSION" pane send-text "$PANE" /quit >/dev/null || fail "could not send Pi quit text"
"$LAB_HELPER" run "$SESSION" pane send-keys "$PANE" enter >/dev/null || fail "could not submit Pi quit text"
for _ in $(seq 1 100); do
  gone_state=$("$LAB_HELPER" run "$SESSION" agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty' 2>/dev/null || true)
  [ -z "$gone_state" ] && break
  sleep 0.1
done
[ -z "$gone_state" ] || fail "the Pi probe did not exit into its shell"

stopped_verdict=$(FM_STALE_PI_STATE=1 PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state herdr "$1"' "$ROOT" "$SESSION:$PANE")
[ "$stopped_verdict" = dead ] || fail "a stale idle Pi record over an ordinary shell must be dead, got $stopped_verdict"


out=$(FM_STALE_PI_STATE=1 PATH="$FAKEBIN:$ORIGINAL_PATH" FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
  FM_CONTROL_POLL=0.1 FM_CONTROL_EXIT_WAIT=1 FM_CONTROL_LAUNCH_WAIT=10 \
  "$CONTROL" pirecovery relaunch --note 'replace the exited Pi session' 2>&1) || fail "relaunch should replace the exited Pi session: $out"
case "$out" in *"relaunched pirecovery harness=pi from=pi"*) ;; *) fail "relaunch did not report the Pi replacement: $out" ;; esac
[ "$(grep '^window=' "$HOME_DIR/state/pirecovery.meta")" = "window=$SESSION:$PANE" ] || fail "relaunch changed the recorded Herdr endpoint"
[ "$(grep '^worktree=' "$HOME_DIR/state/pirecovery.meta")" = "worktree=$WT" ] || fail "relaunch changed the recorded worktree"

replacement_state=
for _ in $(seq 1 100); do
  replacement_state=$("$LAB_HELPER" run "$SESSION" agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty' 2>/dev/null || true)
  case "$replacement_state" in idle|done|blocked|working) break ;; esac
  sleep 0.1
done
case "$replacement_state" in idle|done|blocked|working) ;; *) fail "relaunch did not start one replacement Pi agent" ;; esac
pass "fm-control relaunch: an exited Pi shell with a stale idle record is replaced in the same Herdr pane and worktree"
