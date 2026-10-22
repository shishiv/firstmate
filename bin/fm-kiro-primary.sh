#!/usr/bin/env bash
# fm-kiro-primary.sh - launch a Firstmate primary on Kiro CLI.
#
# Usage:
#   bin/fm-kiro-primary.sh [--v3] [kiro chat options...]
#   bin/fm-kiro-primary.sh --v2 [kiro chat options...]
#
# V3 is the default and runs on Kiro's own default agent (no --agent), with
# the tracked project-scoped .kiro/hooks/fm-firstmate.json; no Firstmate agent
# file is tracked or generated for it.
# V2 is an explicit compatibility fallback; it uses a distinct legacy agent
# generated inside the isolated home and retains --trust-all-tools.
# Both hook registrations carry their own primary marker and reach
# bin/fm-kiro-turnend-hook.sh without this launcher's environment, so a session
# resumed with plain kiro-cli keeps its lifecycle hooks
# (bin/fm-kiro-turnend-hook.sh header).
# Both engines launch trusted (`-a` for V3, `--trust-all-tools` for V2), because
# an agent's `allowedTools` grants no wildcard and a V3 session still stops on
# `fs_write`'s Replace in File with a human approval prompt without the flag.
#
# Both engines persist under state/.kiro-primary-home for the effective FM_HOME.
# The generated settings disable Kiro knowledge indexing, so Firstmate's data/
# is never copied into Kiro's global knowledge store or hardlinked from it, and
# the default agent then offers no knowledge tool (docs/verification/runtime-backends.md).
#
# This launcher owns the engine, agent, home, and trust flags.
# Model, effort, resume, and positional prompt options pass through unchanged.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-kiro-lib.sh
. "$SCRIPT_DIR/fm-kiro-lib.sh"

usage() {
  sed -n '2,/^set -eu$/p' "$0" | sed 's/^# \{0,1\}//; $d'
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

ENGINE=v3
case "${1:-}" in
  --v3) shift ;;
  --v2) ENGINE=v2; shift ;;
esac

for arg in "$@"; do
  case "$arg" in
    --v2|--v3|--agent|--agent=*|--agent-engine|--agent-engine=*|\
    --trust-all-tools|-a|--trust-tools|--trust-tools=*)
      echo "error: $arg is owned by fm-kiro-primary.sh; choose only the launcher's leading --v3 or --v2 engine selector" >&2
      exit 2
      ;;
  esac
done

KIRO_BIN=$(command -v kiro-cli 2>/dev/null || true)
[ -n "$KIRO_BIN" ] && [ -x "$KIRO_BIN" ] || {
  echo "error: kiro-cli executable not found on PATH; install the Kiro CLI (not the /usr/bin/kiro Electron IDE)" >&2
  exit 1
}
case "$("$KIRO_BIN" --version 2>/dev/null || true)" in
  'kiro-cli '*) ;;
  *)
    echo "error: resolved '$KIRO_BIN' is not the Kiro agent CLI" >&2
    exit 1
    ;;
esac

mkdir -p "$STATE"
KIRO_HOME_DIR=$(fm_kiro_primary_home "$STATE")
fm_kiro_write_settings "$KIRO_HOME_DIR" || {
  echo "error: could not prepare the isolated Kiro primary home at $KIRO_HOME_DIR" >&2
  exit 1
}

physical_root=$(cd -- "$FM_ROOT" 2>/dev/null && pwd -P) || physical_root=$FM_ROOT
fm_kiro_trust_workspace "$KIRO_HOME_DIR" "$FM_ROOT" "$physical_root" || {
  echo "error: could not pre-register workspace trust in $KIRO_HOME_DIR" >&2
  exit 1
}

AGENT_ARGS=()
TRUST_ARGS=(-a)
if [ "$ENGINE" = v2 ]; then
  AGENT_ARGS=(--agent firstmate-kiro-v2)
  fm_kiro_write_v2_agent "$KIRO_HOME_DIR" firstmate-kiro-v2 "$(fm_kiro_primary_hook_command)" || {
    echo "error: could not prepare the Kiro V2 compatibility agent in $KIRO_HOME_DIR" >&2
    exit 1
  }
  TRUST_ARGS=(--trust-all-tools)
else
  [ -f "$FM_ROOT/.kiro/hooks/fm-firstmate.json" ] || {
    echo "error: Kiro V3 project hook is missing under $FM_ROOT/.kiro" >&2
    exit 1
  }
fi

export FM_HOME
export KIRO_HOME="$KIRO_HOME_DIR"
export KIRO_DATA_DIR="$KIRO_HOME_DIR/data"
export KIRO_CHAT_LOG_FILE="$KIRO_HOME_DIR/chat.log"
unset KIRO_ACP_NATIVE KIRO_ACP_PERMISSION_MODE KIRO_CLI_ACP_CLIENT_NAME KIRO_SESSION_ID \
  KIRO_TUI_READY_FILE KIRO_TUI_READY_TOKEN 2>/dev/null || true

cd "$FM_ROOT"
exec "$KIRO_BIN" chat "--$ENGINE" "${TRUST_ARGS[@]+"${TRUST_ARGS[@]}"}" \
  "${AGENT_ARGS[@]+"${AGENT_ARGS[@]}"}" "$@"
