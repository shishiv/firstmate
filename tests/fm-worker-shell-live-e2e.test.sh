#!/usr/bin/env bash
# Opt-in live guard for the worker shell contract (live-harness-optin family):
# the bash tool of a freshly spawned Kiro or Pi worker runs its commands with
# `set -o pipefail`. Per .agents/skills/firstmate-coding-guidelines
# "Harness-dependent checks", this is harness-dependent: it holds only while the
# vendor's bash tool keeps running `bash -c <command>` with the launch
# environment, so a stub cannot prove it.
#
# For each of kiro-cli and pi, this runs the REAL fm-spawn to build the worker's
# launch (per-task homes, agent files, brief, exports) with a fake pane and a
# no-op treehouse, then starts that exact launch command, with the real binary,
# in a real tmux pane inside an isolated lab worktree. Only the pane and the
# worktree pool are stubbed, so the guard never administers a shared pool.
# It asks the worker to run one fixed command with its own shell tool and reads
# the file that command wrote:
#   false | true; echo "PIPEFAIL_RC=$?" > <result>
# The file must say PIPEFAIL_RC=1. Plain bash prints 0 here, so a launch that
# lost BASH_ENV, or a vendor tool that stopped reading it, fails this guard.
# It submits prompts, so it spends credits and is opt-in. Run it explicitly with
# FM_WORKER_SHELL_LIVE=1 and refresh docs/verification/runtime-backends.md
# ("Worker shell pipefail") from its output after any kiro-cli or pi upgrade.
# FM_WORKER_SHELL_LIVE_KIRO_MODEL and FM_WORKER_SHELL_LIVE_PI_MODEL select a
# concrete model when a provider's default routing is saturated.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate opt-in FM_WORKER_SHELL_LIVE tmux kiro-cli pi

REAL_TMUX=$(command -v tmux) || fail "tmux not found"
LAB=$(fm_test_tmproot fm-worker-shell-live)
SOCK="$LAB/tmux.sock"
TIMEOUT=${FM_WORKER_SHELL_LIVE_TIMEOUT:-240}

env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$SOCK" new-session -d -s worker-shell-live -x 200 -y 50 'sleep 3600' \
  || fail "could not start the dedicated tmux session"
trap 'env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null || true' EXIT

check_worker() {  # <harness> [model]
  local harness=$1 model=${2:-} id case_dir home proj wt fakebin result i content out
  id="shell-live-${harness//[^a-z]/}-$$"
  case_dir="$LAB/$harness"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  result="$case_dir/result.txt"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  mv "$fakebin/tmux" "$fakebin/tmux-spawn-stub"
  cat > "$fakebin/tmux" <<'SH'
#!/bin/sh
case "${1:-}" in
  capture-pane) printf 'Trust All Tools active, confirmations are off\nask a question or describe a task\n'; exit 0 ;;
esac
exec "$(dirname "$0")/tmux-spawn-stub" "$@"
SH
  chmod +x "$fakebin/tmux"
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$id"
  fm_test_spawn_brief "$home" "$id" "Run this exact command once with your own shell tool, unchanged, then reply with the single word DONE and stop. Do not edit the command and do not run anything else.

false | true; echo \"PIPEFAIL_RC=\$?\" > '$result'"

  : > "$case_dir/launch.log"
  : > "$case_dir/pane.log"
  out=$(FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" FM_FAKE_PANE_LOG="$case_dir/pane.log" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --harness "$harness" \
    --mode no-mistakes --yolo off --effort low ${model:+--model "$model"}) \
    || { printf '%s\n' "$out" >&2; fail "$harness: fm-spawn could not build the worker launch"; }

  { grep '^export ' "$case_dir/pane.log"; cat "$case_dir/launch.log"; } > "$case_dir/run.sh"
  env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$SOCK" new-session -d -s "worker-$harness" -c "$wt" \
    -x 200 -y 50 "bash '$case_dir/run.sh'" \
    || fail "$harness: could not start the worker launch in a real pane"

  i=0
  while [ "$i" -lt "$TIMEOUT" ] && [ ! -s "$result" ]; do
    sleep 1
    i=$((i + 1))
  done
  if [ ! -s "$result" ]; then
    env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$SOCK" capture-pane -p -S -80 -t "worker-$harness" >&2 2>/dev/null || true
    fail "$harness: the worker never ran the command within ${TIMEOUT}s (provider capacity or login can cause this; nothing about the shell was exercised)"
  fi
  content=$(cat "$result")
  assert_equals "PIPEFAIL_RC=1" "$content" \
    "$harness: the worker's own bash tool must run with pipefail (false | true must exit 1)"
  pass "live: the $harness worker's bash tool ran 'false | true' with pipefail on"
}

check_worker kiro-cli "${FM_WORKER_SHELL_LIVE_KIRO_MODEL:-}"
check_worker pi "${FM_WORKER_SHELL_LIVE_PI_MODEL:-}"
echo "ok - worker shell pipefail live guard passed for kiro-cli and pi"
