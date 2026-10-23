#!/usr/bin/env bash
# fm-kirocrew-setup.sh - one-time, idempotent setup that lets a firstmate home
# run kirocrew workers on the captain's Kiro Crew gateway.
#
# Usage: fm-kirocrew-setup.sh [--home <fm-home>] [--kiro-home <dir>]
#                             [--kirocrew-bin <path>] [--check]
#
# It does three things and changes nothing else:
#   1. writes the worker agent file <kiro-home>/agents/<agent>.json, the agent
#      every kirocrew chat runs (an empty prompt, every built-in tool, no MCP
#      servers; the launch brief carries the worker contract);
#   2. registers the self-managed app `firstmate` with the gateway, as the
#      dashboard owner, and adds it to Crew's trusted apps; Crew writes the app
#      secret that bin/fm-kirocrew.mjs trades for its app token;
#   3. prints the two steps only the captain can take: restart the gateway when
#      the agent file is new (Crew reads agent files when it starts), and give
#      the app chat control in the Crew dashboard. That consent grants the
#      app's `sessionApproval` permission, which lets firstmate put each worker
#      chat in Trust mode, and it lets the app control every chat of that Crew
#      instance. Only the dashboard owner may give it, so this script never
#      sends it. Crew 0.11.0 shows no Enable button for a self-managed app, so
#      the step is one request the captain runs in the browser console on the
#      app's dashboard page, the request that button would send.
#
# --check runs nothing but bin/fm-kirocrew.mjs probe: it opens and closes one
# empty chat and reports the agent and whether Trust is granted.
#
# The owner token comes from `kirocrew token` and is used for the two owner
# calls only. It is never printed, stored, or passed as a command argument, and
# the app secret in the registration answer is never printed either. Crew
# refuses to let its own agents mint a dashboard token, so this script refuses
# to run inside a Crew session too.
#
# --kiro-home must be the KIRO_HOME of the gateway (default $KIRO_HOME, then
# ~/.kiro, the same default Crew uses): Crew offers only the agent files it
# finds in <KIRO_HOME>/agents when its gateway starts.
#
# config/kirocrew in the firstmate home (optional) names the gateway url=,
# crew-home= and agent=; docs/configuration.md "Kiro Crew (config/kirocrew)".
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
HOME_DIR=${FM_HOME:-$FM_ROOT_DIR}
KIRO_HOME_DIR=${KIRO_HOME:-$HOME/.kiro}
KIROCREW_BIN=${KIROCREW_BIN:-}
CHECK=0
APP_VERSION=0.2.0
# The dashboard's own enable request with consent (website api.enableApp).
ENABLE_REQUEST="fetch('/api/apps/firstmate/enable', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Session-Key': 'dashboard:ui' }, body: JSON.stringify({ sessionApprovalConsent: true }) }).then((r) => r.json()).then(console.log)"

usage() {
  sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --home) [ $# -ge 2 ] || usage; HOME_DIR=$2; shift 2 ;;
    --kiro-home) [ $# -ge 2 ] || usage; KIRO_HOME_DIR=$2; shift 2 ;;
    --kirocrew-bin) [ $# -ge 2 ] || usage; KIROCREW_BIN=$2; shift 2 ;;
    --check) CHECK=1; shift ;;
    -h|--help) usage ;;
    *) echo "error: unknown argument: $1" >&2; usage ;;
  esac
done

if [ -n "${KIROCREW_SPAWNED:-}" ]; then
  echo "error: fm-kirocrew-setup.sh runs from the captain's own shell, not from inside a Kiro Crew session" >&2
  exit 1
fi
for tool in node jq curl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool is required" >&2; exit 1; }
done

WIRE="$SCRIPT_DIR/fm-kirocrew.mjs"
config_value() {  # <key>
  node "$WIRE" config --home "$HOME_DIR" | sed -n "s/^$1=//p"
}
URL=$(config_value url)
CREW_HOME=$(config_value crew-home)
AGENT=$(config_value agent)

if [ "$CHECK" = 1 ]; then
  # shellcheck source=bin/fm-backend-hometag-lib.sh
  label=$(. "$SCRIPT_DIR/fm-backend-hometag-lib.sh" && FM_HOME=$HOME_DIR FM_ROOT=$FM_ROOT_DIR fm_backend_hometag)
  exec node "$WIRE" probe --home "$HOME_DIR" --slot "fm-${label:-fm}-setup-probe"
fi

if [ -z "$KIROCREW_BIN" ]; then
  KIROCREW_BIN=$(command -v kirocrew 2>/dev/null || true)
  [ -n "$KIROCREW_BIN" ] || KIROCREW_BIN="$HOME/.kiro/crew-venv-current/bin/kirocrew"
fi
[ -x "$KIROCREW_BIN" ] || { echo "error: kirocrew executable not found (pass --kirocrew-bin)" >&2; exit 1; }

# 1. Worker agent file, replaced only when its bytes differ.
AGENTS_DIR="$KIRO_HOME_DIR/agents"
AGENT_FILE="$AGENTS_DIR/$AGENT.json"
mkdir -p "$AGENTS_DIR"
agent_json=$(jq -n --arg name "$AGENT" '{
  name: $name,
  description: "firstmate worker: runs one firstmate task in its worktree; firstmate supervises it",
  prompt: "",
  tools: ["*"],
  allowedTools: [],
  includeMcpJson: false,
  mcpServers: {}
}')
AGENT_NEW=0
if [ ! -f "$AGENT_FILE" ] || [ "$(cat "$AGENT_FILE")" != "$agent_json" ]; then
  tmp=$(mktemp "$AGENTS_DIR/.$AGENT.json.XXXXXX")
  printf '%s\n' "$agent_json" >"$tmp"
  chmod 644 "$tmp"
  mv -f "$tmp" "$AGENT_FILE"
  AGENT_NEW=1
  echo "wrote $AGENT_FILE"
else
  echo "agent file is current: $AGENT_FILE"
fi

# 2. App registration and trust, as the dashboard owner.
owner_url=$("$KIROCREW_BIN" token 2>/dev/null | grep -o 'https\{0,1\}://[^ ]*token=[^ &#]*' | head -1 || true)
OWNER_TOKEN=${owner_url##*token=}
[ -n "$owner_url" ] && [ -n "$OWNER_TOKEN" ] || { echo "error: \`kirocrew token\` printed no dashboard token; is the gateway at $URL running?" >&2; exit 1; }
PORT=$(node -e 'const u=new URL(process.argv[1]); process.stdout.write(u.port || (u.protocol === "https:" ? "443" : "80"))' "$URL")
# The owner cookie reaches curl through a config on stdin, never through its
# argv, which every local user can read in the process list.
owner_call() {  # <method> <path> [json]
  local args=(-sS -K - -X "$1" -w '\n%{http_code}') token=${OWNER_TOKEN//\\/\\\\}
  [ $# -lt 3 ] || args+=(-H 'Content-Type: application/json' --data-binary "$3")
  printf 'header = "Cookie: mc_token_%s=%s"\n' "$PORT" "${token//\"/\\\"}" | curl "${args[@]}" "$URL$2"
}

manifest=$(jq -n --arg v "$APP_VERSION" '{
  name: "firstmate",
  version: $v,
  displayName: "firstmate",
  description: "Shows firstmate workers as Kiro Crew chats. firstmate creates, supervises and closes them; talk to firstmate, not to the workers.",
  minKiroCrewVersion: "0.11.0",
  lifecycle: "app",
  resources: "app",
  permissions: { api: ["/api/chat"], events: ["slots:own"], sessionApproval: true }
}')
installed="$CREW_HOME/apps/firstmate/installed.json"
if [ -f "$installed" ] && [ "$(jq -r .version "$installed" 2>/dev/null)" = "$APP_VERSION" ] && [ -s "$CREW_HOME/apps/firstmate/.app_secret" ]; then
  echo "app firstmate $APP_VERSION is already registered"
else
  body=$(jq -n --argjson m "$manifest" '{name: "firstmate", version: $m.version, displayName: $m.displayName, manifest: $m, resources: "app", lifecycle: "app"}')
  out=$(owner_call POST /api/apps/register "$body")
  code=${out##*$'\n'}
  out=${out%$'\n'*}
  case "$code" in
    200|201) printf 'registered app firstmate: %s\n' "$(printf '%s' "$out" | jq -r '.message // "ok"')" ;;
    *) echo "error: app registration failed (HTTP $code): $(printf '%s' "$out" | jq -r '.error // empty' 2>/dev/null)" >&2; exit 1 ;;
  esac
fi
out=$(owner_call POST /api/security/trusted-apps/firstmate '{}')
code=${out##*$'\n'}
case "$code" in
  200|201) echo "app firstmate is on Crew's trusted apps list" ;;
  *) echo "error: could not trust app firstmate (HTTP $code)" >&2; exit 1 ;;
esac
unset OWNER_TOKEN

# 3. The captain's steps.
enabled=$(jq -r '.enabled' "$installed" 2>/dev/null || echo false)
pending=$(jq -r '.sessionApprovalConsentPending' "$installed" 2>/dev/null || echo true)
echo
echo "Captain steps:"
n=0
if [ "$AGENT_NEW" = 1 ]; then
  n=$((n + 1))
  echo "  $n. Restart the Kiro Crew gateway (kirocrew restart). Crew reads agent files only when it starts."
fi
if [ "$enabled" != true ] || [ "$pending" = true ]; then
  n=$((n + 1))
  echo "  $n. Give the app chat control. In the Crew dashboard, open the page"
  echo "     /apps/detail/firstmate and read the permission there. Kiro Crew 0.11.0 shows"
  echo "     no Enable button for a self-managed app, so run this line in the browser"
  echo "     console on that page; it sends the request the missing button would send:"
  echo "       $ENABLE_REQUEST"
  echo "     The consent lets firstmate put each worker chat in Trust mode, and it lets"
  echo "     the app control every chat of this Crew instance. Until then, every shell"
  echo "     or file tool of a worker waits for an approval in the dashboard."
fi
[ "$n" -gt 0 ] || echo "  none"
echo "Then run: $0 --home $HOME_DIR --check"
