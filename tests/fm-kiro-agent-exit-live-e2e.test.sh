#!/usr/bin/env bash
# Live guard (live-harness-optin family) for the dead-agent reading in
# bin/fm-busy-lib.sh (fm_busy_kiro_agent_exited). Per
# .agents/skills/firstmate-coding-guidelines "Harness-dependent checks", that
# check holds only while the installed kiro-cli still throws the two messages
# its terminal program shows once the KAS agent process is gone:
#   KAS agent process exited unexpectedly (code N)   the turn in flight fails
#   Kiro not initialized                             every later send fails
# The guard reads the TUI bundle the installed kiro-cli extracts and fails,
# naming kiro-cli and its version, when either message is gone. It spends no
# model tokens, so it runs by default wherever kiro-cli is installed.
# Run it after every kiro-cli upgrade and refresh docs/verification/runtime-backends.md
# ("Kiro dead-agent messages") from its output.
# FM_KIRO_AGENT_EXIT_LIVE_BUNDLE names the bundle when it lives elsewhere.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_KIRO_AGENT_EXIT_LIVE kiro-cli

KIRO_VERSION=$(kiro-cli --version 2>/dev/null | head -n 1)
[ -n "$KIRO_VERSION" ] || fail "kiro-cli --version printed nothing"

BUNDLE=${FM_KIRO_AGENT_EXIT_LIVE_BUNDLE:-}
if [ -z "$BUNDLE" ]; then
  for candidate in "${KIRO_DATA_DIR:-/nonexistent}/tui.js" "${XDG_DATA_HOME:-/nonexistent}/kiro-cli/tui.js" \
    "$HOME/.local/share/kiro-cli/tui.js" "$HOME/Library/Application Support/kiro-cli/tui.js"; do
    [ -f "$candidate" ] && { BUNDLE=$candidate; break; }
  done
fi
if [ -z "$BUNDLE" ] || [ ! -f "$BUNDLE" ]; then
  if [ "${FM_KIRO_AGENT_EXIT_LIVE:-}" = 1 ] || [ "${FM_LIVE:-}" = 1 ]; then
    fail "$KIRO_VERSION: no extracted TUI bundle found; start kiro-cli once or set FM_KIRO_AGENT_EXIT_LIVE_BUNDLE"
  fi
  echo "skip: live: $KIRO_VERSION has no extracted TUI bundle here"
  exit 0
fi

test_the_dead_agent_messages_are_still_in_the_installed_tui() {
  local text
  for text in 'KAS agent process exited unexpectedly' 'Kiro not initialized'; do
    grep -aqF -- "$text" "$BUNDLE" \
      || fail "$KIRO_VERSION no longer carries '$text' in $BUNDLE; update fm_busy_kiro_agent_exited in bin/fm-busy-lib.sh and its tests"
  done
  pass "$KIRO_VERSION still throws both dead-agent messages fm_busy_kiro_agent_exited reads ($BUNDLE)"
}

fm_test_run test_the_dead_agent_messages_are_still_in_the_installed_tui
