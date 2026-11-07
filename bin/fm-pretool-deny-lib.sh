# shellcheck shell=bash
# fm-pretool-deny-lib.sh - the one renderer of a PreToolUse deny, shared by the
# seatbelt transports (bin/fm-arm-pretool-check.sh, bin/fm-cd-pretool-check.sh,
# bin/fm-subagent-pretool-check.sh, bin/fm-kiro-worker-background-pretool-check.sh).
# No side effects on source.
#
# fm_pretool_deny_exit <reason> <render> renders the deny for one harness and
# exits:
#   cursor - Cursor's decision object on stdout, exit 0 (Cursor reads the
#            object, not the exit status).
#   agy    - Antigravity's decision object on stdout, exit 0.
#   claude - a Claude-shaped deny object on stderr only, exit 2 (Claude
#            requires stdout to stay empty on deny; Codex, Kiro, OpenCode, and
#            Pi block on exit 2 and show stderr).
#   grok   - the Claude-shaped object on stderr plus a Grok decision object on
#            stdout, exit 2.

fm_pretool_json_escape() {  # <text>
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

# Map a transport's harness flags to one render word. Cursor wins over agy,
# and agy over claude, the order every transport has always checked them in.
fm_pretool_render() {  # <claude 0|1> <cursor 0|1> <agy 0|1>
  if [ "$2" -eq 1 ]; then
    printf 'cursor'
  elif [ "$3" -eq 1 ]; then
    printf 'agy'
  elif [ "$1" -eq 1 ]; then
    printf 'claude'
  else
    printf 'grok'
  fi
}

fm_pretool_deny_exit() {  # <reason> <render>
  local reason=$1 render=$2 escaped
  escaped=$(fm_pretool_json_escape "$reason")
  case "$render" in
    cursor)
      printf '{"permission":"deny","user_message":"%s"}\n' "$escaped"
      exit 0
      ;;
    agy)
      if command -v jq >/dev/null 2>&1; then
        jq -cn --arg r "$reason" '{decision:"deny",reason:$r}'
      else
        printf '{"decision":"deny","reason":"%s"}\n' "$escaped"
      fi
      exit 0
      ;;
  esac
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$escaped" >&2
  [ "$render" = claude ] || printf '{"decision":"deny","reason":"%s"}\n' "$escaped"
  exit 2
}
