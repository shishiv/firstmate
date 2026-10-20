#!/usr/bin/env bash
# Live guard for bin/fm-busy-lib.sh's provider-limit launch-failure verdict
# (fm_busy_launch_provider_limited, live-harness-optin family). Per
# .agents/skills/firstmate-coding-guidelines "Harness-dependent checks", a
# verdict built on vendor-rendered error text must be proven against the REAL
# installed harness and a REAL provider refusal, because a stub can only
# confirm the error string already written into it.
#
# A provider limit cannot be produced on demand, so the operator names a Pi
# model whose provider is at its limit right now in FM_PROVIDER_LIMIT_PI_MODEL
# (for example opencode-go/deepseek-v4.1-flash while quota-axi reports
# opencode-go exhausted_now). The guard launches the real `pi` with that model
# and a one-word prompt in an isolated tmux server, loads a Pi extension that
# applies the same agent_start/agent_settled busy events the fm-spawn Pi
# extension writes, captures the pane with the production shape
# (`tmux capture-pane -p -S -40`), and requires fm_busy_launch_provider_limited
# to report the rendered error line. A provider that answers spends a few
# tokens and fails the guard, which is why the guard is opt-in. Without the
# model variable an explicit FM_PROVIDER_LIMIT_LIVE=1 run fails naming it, and
# a broad FM_LIVE=1 run skips because no provider is known to be at its limit.
#
# Run with FM_PROVIDER_LIMIT_LIVE=1 FM_PROVIDER_LIMIT_PI_MODEL=<provider>/<id>.
# Refresh docs/verification/runtime-backends.md ("Provider-limit launch
# failure") from this guard's output after a pi upgrade.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REAL_TMUX=$(command -v tmux 2>/dev/null || true)
SOCKET="fm-provider-limit-$$"
LAB=

note() { printf '# %s\n' "$1"; }

cleanup_all() {
  [ -z "${REAL_TMUX:-}" ] || "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -z "$LAB" ] || rm -rf -- "$LAB"
}
trap cleanup_all EXIT

fm_live_gate opt-in FM_PROVIDER_LIMIT_LIVE tmux pi

MODEL=${FM_PROVIDER_LIMIT_PI_MODEL:-}
if [ -z "$MODEL" ]; then
  # A broad FM_LIVE=1 run cannot know which provider is at its limit today.
  [ "${FM_PROVIDER_LIMIT_LIVE:-}" = 1 ] \
    || { printf 'skip: live: FM_PROVIDER_LIMIT_PI_MODEL unset; no provider known to be at its limit\n'; exit 0; }
  fail "FM_PROVIDER_LIMIT_PI_MODEL is unset: name a Pi <provider>/<id> model whose provider quota-axi reports exhausted now"
fi

# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
EV="$ROOT/bin/fm-busy-event.sh"

PI_BIN=$(command -v pi)
note "live pi version: $("$PI_BIN" --version 2>&1)"
note "model: $MODEL"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-provider-limit.XXXXXX") || fail "could not create the isolated lab"
mkdir -p "$LAB/wt" "$LAB/state"
git -C "$LAB/wt" init -q || fail "could not initialize the scratch worktree"
"$EV" arm "$LAB/state" t1 >/dev/null || fail "could not arm the scratch busy-state record"
GEN=$(cat "$LAB/state/t1.busy-gen")
cat > "$LAB/ext.ts" <<EOF
import { execFile } from "node:child_process";
const busyEvent = (state: string, event: string) =>
  new Promise<void>((resolve) => {
    execFile("$EV", ["apply", "$LAB/state", "t1", state, "--gen", "$GEN", "--source", "pi-ext", "--event", event], () => resolve());
  });
export default function (pi: any) {
  pi.on("agent_start", () => busyEvent("busy", "agent-start"));
  pi.on("agent_settled", (_event: any, ctx: any) => {
    if (ctx && typeof ctx.isIdle === "function" && !ctx.isIdle()) return;
    return busyEvent("idle", "agent-settled");
  });
}
EOF

"$REAL_TMUX" -L "$SOCKET" new-session -d -s live -n w -x 160 -y 45 -c "$LAB/wt" -- \
  "$PI_BIN" --model "$MODEL" -e "$LAB/ext.ts" 'Reply with the single word ok.' \
  || fail "could not launch the real pi"

line=
tail=
for _ in $(seq 1 60); do
  sleep 0.5
  tail=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t live:w -S -40 2>/dev/null) || continue
  if line=$(fm_busy_launch_provider_limited tmux live:w pi t1 "$LAB/state" "$tail"); then
    break
  fi
  line=
done
[ -n "$line" ] || fail "pi on $MODEL never showed a provider-limit failure the verdict accepts within 30s (busy record: $(cat "$LAB/state/t1.busy-state" 2>/dev/null)) - captured tail:
$tail"
note "matched: $line"
pass "pi: a real provider limit on $MODEL is reported as a failed launch"
