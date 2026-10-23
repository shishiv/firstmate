#!/usr/bin/env bash
# fm-kirocrew-primary.sh - open this home's firstmate primary in a Kiro Crew chat.
#
# Usage: fm-kirocrew-primary.sh [--model <model>] [--effort <effort>]
#                               [--title <title>] [--message <first message>]
#                               [--kirocrew-bin <path>]
#
# The chat is the captain's own: the dashboard owner creates it
# (bin/fm-kirocrew-owner-lib.sh), so it sits in his chat list and he types in it
# from the dashboard or a phone. It runs the agent firstmate-primary
# (bin/fm-kirocrew-setup.sh --primary) with this checkout as its project, in
# Trust mode, so the primary's shell and file tools wait for no approval. Its
# name is fm-<home tag>-primary, one per home:
#   - a chat Crew lists is left as it is;
#   - a chat that a gateway restart dropped is resumed from its transcript;
#   - otherwise a new chat is created, configured, and sent the first message,
#     whose turn runs the startup digest through the agent's hooks.
# The home is the checkout this script lives in, because the agent's hooks run
# the firstmate of the chat's project folder. The home's doorbell service
# (bin/fm-primary-doorbell.sh serve) must be running, or nothing rings the
# primary for a wake, so this script refuses to open the chat without it.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd -P)
KIROCREW_BIN=${KIROCREW_BIN:-}
AGENT=firstmate-primary
MODEL=
EFFORT=
TITLE='firstmate · primary'
MESSAGE='Firstmate session open: take the helm of this home.'

usage() {
  sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --model) [ $# -ge 2 ] || usage; MODEL=$2; shift 2 ;;
    --effort) [ $# -ge 2 ] || usage; EFFORT=$2; shift 2 ;;
    --title) [ $# -ge 2 ] || usage; TITLE=$2; shift 2 ;;
    --message) [ $# -ge 2 ] || usage; MESSAGE=$2; shift 2 ;;
    --kirocrew-bin) [ $# -ge 2 ] || usage; KIROCREW_BIN=$2; shift 2 ;;
    -h|--help) usage ;;
    *) echo "error: unknown argument: $1" >&2; usage ;;
  esac
done

if [ -n "${KIROCREW_SPAWNED:-}" ]; then
  echo "error: fm-kirocrew-primary.sh runs from the captain's own shell, not from inside a Kiro Crew session" >&2
  exit 1
fi
if [ -n "${FM_HOME:-}" ] && [ "$(cd "$FM_HOME" 2>/dev/null && pwd -P)" != "$FM_ROOT_DIR" ]; then
  echo "error: a Kiro Crew primary runs the firstmate of its own checkout; run $FM_HOME/bin/fm-kirocrew-primary.sh instead" >&2
  exit 1
fi
for tool in node jq curl systemctl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool is required" >&2; exit 1; }
done

UNIT=$(FM_HOME="$FM_ROOT_DIR" "$SCRIPT_DIR/fm-primary-doorbell.sh" unit)
systemctl --user -q is-active "$UNIT" || {
  echo "error: the doorbell service $UNIT is not running; run $SCRIPT_DIR/fm-kirocrew-setup.sh --primary first" >&2
  exit 1
}

URL=$(node "$SCRIPT_DIR/fm-kirocrew.mjs" config --home "$FM_ROOT_DIR" | sed -n 's/^url=//p')
# shellcheck source=bin/fm-backend-hometag-lib.sh
TAG=$(. "$SCRIPT_DIR/fm-backend-hometag-lib.sh" && FM_HOME=$FM_ROOT_DIR FM_ROOT=$FM_ROOT_DIR fm_backend_hometag)
CHAT="fm-$TAG-primary"
if [ -z "$KIROCREW_BIN" ]; then
  KIROCREW_BIN=$(command -v kirocrew 2>/dev/null || true)
  [ -n "$KIROCREW_BIN" ] || KIROCREW_BIN="$HOME/.kiro/crew-venv-current/bin/kirocrew"
fi
[ -x "$KIROCREW_BIN" ] || { echo "error: kirocrew executable not found (pass --kirocrew-bin)" >&2; exit 1; }

# shellcheck source=bin/fm-kirocrew-owner-lib.sh
. "$SCRIPT_DIR/fm-kirocrew-owner-lib.sh"
fm_kirocrew_owner_begin "$KIROCREW_BIN" "$URL" || exit 1
trap fm_kirocrew_owner_end EXIT
call() {  # <what> <method> <path> [json]; fails on any status but 200 and 201
  local what=$1
  shift
  fm_kirocrew_owner_call "$@"
  case "$FM_KIROCREW_OWNER_CODE" in
    200|201) ;;
    *)
      echo "error: $what failed (HTTP $FM_KIROCREW_OWNER_CODE): $(printf '%s' "$FM_KIROCREW_OWNER_BODY" | jq -r '[.code, .error] | map(select(.)) | join(": ")' 2>/dev/null)" >&2
      exit 1
      ;;
  esac
}
chat_path="/api/chat/slots/$CHAT"

call 'listing the Crew chats' GET /api/chat/slots
if printf '%s' "$FM_KIROCREW_OWNER_BODY" | jq -e --arg k "$CHAT" 'any(.[]; .key == $k)' >/dev/null; then
  echo "chat $CHAT is open; nothing changed"
  exit 0
fi

fm_kirocrew_owner_call POST "$chat_path/resume" "$(jq -cn --arg k "dashboard_$CHAT" '{key: $k}')"
case "$FM_KIROCREW_OWNER_CODE" in
  200|201) HOW=resumed ;;
  404) HOW=created ;;
  *) echo "error: resuming the chat $CHAT failed (HTTP $FM_KIROCREW_OWNER_CODE)" >&2; exit 1 ;;
esac
if [ "$HOW" = created ]; then
  fm_kirocrew_owner_call POST /api/chat/slots "$(jq -cn --arg n "$CHAT" --arg a "$AGENT" --arg t "$TITLE" \
    '{name: $n, agent: $a, agent_kind: "template", memory_mode: "temporary", title: $t}')"
  case "$FM_KIROCREW_OWNER_CODE:$(printf '%s' "$FM_KIROCREW_OWNER_BODY" | jq -r '.code // empty' 2>/dev/null)" in
    200:*|201:*) ;;
    *:agent_choice_unavailable)
      echo "error: Kiro Crew does not offer the agent $AGENT yet; Crew reads agent files only when its gateway starts, so restart it after bin/fm-kirocrew-setup.sh --primary" >&2
      exit 1
      ;;
    *) echo "error: creating the chat $CHAT failed (HTTP $FM_KIROCREW_OWNER_CODE)" >&2; exit 1 ;;
  esac
fi
call 'setting the project' POST "$chat_path/project" "$(jq -cn --arg p "$FM_ROOT_DIR" '{project: $p}')"
[ -z "$MODEL" ] || call 'setting the model' POST "$chat_path/model" "$(jq -cn --arg m "$MODEL" '{model: $m}')"
[ -z "$EFFORT" ] || call 'setting the effort' POST "$chat_path/reasoning-effort" "$(jq -cn --arg e "$EFFORT" '{reasoning_effort: $e}')"
call 'setting the turn timeout' POST "$chat_path/turn-timeout" '{"secs":86400}'
call 'turning on Trust' POST /api/chat/mode "$(jq -cn --arg s "$CHAT" '{mode: "trust", slot: $s}')"
[ "$HOW" = resumed ] || call 'sending the first message' POST '/api/chat?ws=1' "$(jq -cn --arg s "$CHAT" --arg m "$MESSAGE" '{slot: $s, message: $m}')"
echo "chat $CHAT is $HOW, in Trust, with project $FM_ROOT_DIR; open \"$TITLE\" in the Crew dashboard at $URL"
