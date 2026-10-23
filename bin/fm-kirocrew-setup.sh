#!/usr/bin/env bash
# fm-kirocrew-setup.sh - one-time, idempotent setup that lets a firstmate home
# run kirocrew workers on the captain's Kiro Crew gateway.
#
# Usage: fm-kirocrew-setup.sh [--home <fm-home>] [--kiro-home <dir>]
#                             [--kirocrew-bin <path>] [--primary] [--check]
#
# It does three things and changes nothing else:
#   1. writes the worker agent file <kiro-home>/agents/<agent>.json, the agent
#      every kirocrew chat runs (an empty prompt, every built-in tool, no MCP
#      servers; the launch brief carries the worker contract);
#   2. installs the Crew app `firstmate` (apps/firstmate/app.json in this
#      repository) as the dashboard owner, with the requests the dashboard's
#      Discover page sends: it keeps a Crew app registry named `firstmate` on
#      the configured repository and branch, grants the app execution trust
#      (Crew checks it before an install clones anything), and installs the app
#      when it is absent. Crew writes the app secret that bin/fm-kirocrew.mjs
#      trades for its app token. An installed app is left as it is, and later
#      versions arrive through Crew's own Update;
#   3. prints the steps only the captain can take: restart the gateway when the
#      agent file is new (Crew reads agent files when it starts), and click
#      "Enable and allow chat control" on the app's page in the Crew dashboard.
#      That consent grants the app's `sessionApproval` permission, which lets
#      firstmate put each worker chat in Trust mode, and it lets the app control
#      every chat of that Crew instance. Only the dashboard owner may give it,
#      so this script never sends it.
#
# --primary also prepares this home's primary to run in a Kiro Crew chat
# (bin/fm-kirocrew-primary.sh opens that chat):
#   - the primary agent file <kiro-home>/agents/firstmate-primary.json, whose
#     hooks run bin/fm-kiro-turnend-hook.sh from the chat's project folder, so
#     one agent file serves every home on the gateway;
#   - this home's doorbell service, the systemd user unit that
#     `bin/fm-primary-doorbell.sh unit` names, which runs
#     `bin/fm-primary-doorbell.sh serve` with this home as FM_HOME and the
#     PATH of the shell that ran this script. It is enabled and started, and
#     restarted when its unit file changes.
#
# --check runs nothing but bin/fm-kirocrew.mjs probe: it opens and closes one
# empty chat and reports the agent and whether Trust is granted.
#
# The owner calls go through bin/fm-kirocrew-owner-lib.sh, which keeps the
# owner token out of output, files, and argv; the app secret is never read or
# printed. Crew refuses to let its own agents mint a dashboard token, so this
# script refuses to run inside a Crew session too.
#
# --kiro-home must be the KIRO_HOME of the gateway (default $KIRO_HOME, then
# ~/.kiro, the same default Crew uses): Crew offers only the agent files it
# finds in <KIRO_HOME>/agents when its gateway starts.
#
# config/kirocrew in the firstmate home (optional) names the gateway url=,
# crew-home=, agent=, app-registry= and app-registry-branch=;
# docs/configuration.md "Kiro Crew (config/kirocrew)".
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
HOME_DIR=${FM_HOME:-$FM_ROOT_DIR}
KIRO_HOME_DIR=${KIRO_HOME:-$HOME/.kiro}
KIROCREW_BIN=${KIROCREW_BIN:-}
CHECK=0
PRIMARY=0
APP=firstmate
PRIMARY_AGENT=firstmate-primary

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
    --primary) PRIMARY=1; shift ;;
    -h|--help) usage ;;
    *) echo "error: unknown argument: $1" >&2; usage ;;
  esac
done

if [ -n "${KIROCREW_SPAWNED:-}" ]; then
  echo "error: fm-kirocrew-setup.sh runs from the captain's own shell, not from inside a Kiro Crew session" >&2
  exit 1
fi
# The primary agent's hooks run the firstmate of the chat's project folder, so a
# Crew primary's home is its own checkout.
if [ "$PRIMARY" = 1 ] && [ "$(cd "$HOME_DIR" 2>/dev/null && pwd -P)" != "$(cd "$FM_ROOT_DIR" && pwd -P)" ]; then
  echo "error: --primary needs the home to be this checkout; run $HOME_DIR/bin/fm-kirocrew-setup.sh --primary instead" >&2
  exit 1
fi
tools=(node jq curl)
[ "$PRIMARY" = 0 ] || tools+=(systemctl)
for tool in "${tools[@]}"; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool is required" >&2; exit 1; }
done

WIRE="$SCRIPT_DIR/fm-kirocrew.mjs"
config_value() {  # <key>
  node "$WIRE" config --home "$HOME_DIR" | sed -n "s/^$1=//p"
}
URL=$(config_value url)
AGENT=$(config_value agent)
REGISTRY_REPO=$(config_value app-registry)
REGISTRY_BRANCH=$(config_value app-registry-branch)

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

# 1b. With --primary: the primary agent file. Crew runs each hook with /bin/sh -c
# in the chat's project folder; bin/fm-kiro-turnend-hook.sh then acts only when
# that folder is its own firstmate home. The startup digest may take up to its
# own 120 s bound (bin/fm-session-start.sh), so the two hooks that run it get
# more than Crew's 30 s default.
if [ "$PRIMARY" = 1 ]; then
  PRIMARY_FILE="$AGENTS_DIR/$PRIMARY_AGENT.json"
  # shellcheck disable=SC2016 # Crew's shell expands $PWD when the hook runs.
  hook='[ -x bin/fm-kiro-turnend-hook.sh ] || exit 0; FM_KIRO_PRIMARY_HOOK=1 exec "$PWD/bin/fm-kiro-turnend-hook.sh"'
  primary_json=$(jq -n --arg name "$PRIMARY_AGENT" --arg hook "$hook" '{
    name: $name,
    description: "firstmate primary: supervises the firstmate home that is its chat project",
    prompt: "",
    tools: ["*"],
    allowedTools: [],
    includeMcpJson: false,
    mcpServers: {},
    hooks: {
      agentSpawn: [{command: $hook, timeout_ms: 150000}],
      userPromptSubmit: [{command: $hook, timeout_ms: 150000}],
      preToolUse: [{matcher: "execute_bash", command: $hook}],
      stop: [{command: $hook, timeout_ms: 60000}]
    }
  }')
  if [ ! -f "$PRIMARY_FILE" ] || [ "$(cat "$PRIMARY_FILE")" != "$primary_json" ]; then
    tmp=$(mktemp "$AGENTS_DIR/.$PRIMARY_AGENT.json.XXXXXX")
    printf '%s\n' "$primary_json" >"$tmp"
    chmod 644 "$tmp"
    mv -f "$tmp" "$PRIMARY_FILE"
    AGENT_NEW=1
    echo "wrote $PRIMARY_FILE"
  else
    echo "agent file is current: $PRIMARY_FILE"
  fi
fi

# 2. The Crew app, as the dashboard owner.
# shellcheck source=bin/fm-kirocrew-owner-lib.sh
. "$SCRIPT_DIR/fm-kirocrew-owner-lib.sh"
fm_kirocrew_owner_begin "$KIROCREW_BIN" "$URL" || exit 1
# One owner request; sets CODE and BODY.
owner_call() {  # <method> <path> [json]
  fm_kirocrew_owner_call "$@"
  CODE=$FM_KIROCREW_OWNER_CODE
  BODY=$FM_KIROCREW_OWNER_BODY
}
fail_call() {  # <what>
  echo "error: $1 failed (HTTP $CODE): $(printf '%s' "$BODY" | jq -r '.error // empty' 2>/dev/null)" >&2
  exit 1
}

owner_call GET "/api/apps/$APP"
case "$CODE" in
  200) INSTALLED=1 ;;
  404) INSTALLED=0 ;;
  *) fail_call "reading the Crew app $APP" ;;
esac
if [ "$INSTALLED" = 1 ] && [ "$(printf '%s' "$BODY" | jq -r '.resources // empty')" = app ]; then
  echo "error: the Crew app $APP is the self-managed app an older setup registered; uninstall it on /apps/detail/$APP in the Crew dashboard, then run this script again" >&2
  exit 1
fi

# The registry row named after the app is this script's; every other operator
# row goes back exactly as the dashboard's registry editor sends it.
owner_call GET /api/apps/registries
[ "$CODE" = 200 ] || fail_call "reading Crew's app registries"
want=$(jq -cn --arg r "$REGISTRY_REPO" --arg b "$REGISTRY_BRANCH" '{repo: $r, branch: $b}')
have=$(printf '%s' "$BODY" | jq -c --arg n "$APP" '[.registries[]? | select(.name == $n) | {repo, branch}][0] // {}')
REGISTRY_CHANGED=0
if [ "$have" != "$want" ]; then
  rows=$(printf '%s' "$BODY" | jq -c --arg n "$APP" --argjson w "$want" \
    '{registries: ([.registries[]? | select(.name != $n) | {name, repo, branch}] + [{name: $n} + $w])}')
  owner_call PUT /api/apps/registries "$rows"
  [ "$CODE" = 200 ] || fail_call "saving the Crew app registry $APP"
  REGISTRY_CHANGED=1
  echo "Crew app registry $APP: $REGISTRY_REPO ($REGISTRY_BRANCH)"
fi
if [ "$REGISTRY_CHANGED" = 1 ] || [ "$INSTALLED" = 0 ]; then
  owner_call POST /api/apps/registries/refresh "$(jq -cn --arg r "$REGISTRY_REPO" '{repo: $r}')"
  [ "$CODE" = 200 ] || fail_call "reading the app registry $REGISTRY_REPO"
fi

# Crew asks for the repository the trust is for, so a grant can never follow
# the name to code from another source.
owner_call POST "/api/security/trusted-apps/$APP" "$(jq -cn --arg r "$REGISTRY_REPO" '{repository: $r}')"
case "$CODE" in
  200|201) echo "app $APP is on Crew's trusted apps list" ;;
  *) fail_call "trusting the Crew app $APP" ;;
esac
if [ "$INSTALLED" = 0 ]; then
  owner_call POST /api/apps/registry/install "$(jq -cn --arg n "$APP" '{name: $n}')"
  case "$CODE" in
    200|201) [ "$(printf '%s' "$BODY" | jq -r '.ok')" = true ] || fail_call "installing the Crew app $APP" ;;
    *) fail_call "installing the Crew app $APP" ;;
  esac
  echo "installed the Crew app $APP from $REGISTRY_REPO ($REGISTRY_BRANCH)"
fi
owner_call GET "/api/apps/$APP"
[ "$CODE" = 200 ] || fail_call "reading the Crew app $APP"
enabled=$(printf '%s' "$BODY" | jq -r '.enabled')
pending=$(printf '%s' "$BODY" | jq -r '.sessionApprovalConsentPending')
[ "$INSTALLED" = 0 ] || echo "the Crew app $APP $(printf '%s' "$BODY" | jq -r '.version') is installed"
fm_kirocrew_owner_end

# 2b. With --primary: this home's doorbell service. Its unit file is rewritten
# only when its bytes differ, and a running service is restarted then, so the
# owner it runs always comes from this checkout.
if [ "$PRIMARY" = 1 ]; then
  # systemd expands % specifiers in both settings and $ variables in ExecStart,
  # and reads backslashes and quotes inside a quoted word.
  unit_quote() {  # <text> -> "<text>" for a unit file
    local v=${1//\\/\\\\}
    v=${v//\"/\\\"}
    v=${v//%/%%}
    printf '"%s"' "${v//\$/\$\$}"
  }
  UNIT=$(FM_HOME="$HOME_DIR" "$SCRIPT_DIR/fm-primary-doorbell.sh" unit)
  UNIT_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
  unit_text="# Written by bin/fm-kirocrew-setup.sh --primary for the firstmate home $HOME_DIR.
[Unit]
Description=firstmate doorbell service for the Kiro Crew primary of $HOME_DIR

[Service]
Type=simple
Environment=$(unit_quote "FM_HOME=$HOME_DIR")
Environment=$(unit_quote "PATH=$PATH")
ExecStart=$(unit_quote "$SCRIPT_DIR/fm-primary-doorbell.sh") serve
Restart=always
RestartSec=5

[Install]
WantedBy=default.target"
  mkdir -p "$UNIT_DIR"
  UNIT_CHANGED=0
  if [ ! -f "$UNIT_DIR/$UNIT" ] || [ "$(cat "$UNIT_DIR/$UNIT")" != "$unit_text" ]; then
    tmp=$(mktemp "$UNIT_DIR/.$UNIT.XXXXXX")
    printf '%s\n' "$unit_text" >"$tmp"
    chmod 644 "$tmp"
    mv -f "$tmp" "$UNIT_DIR/$UNIT"
    UNIT_CHANGED=1
    echo "wrote $UNIT_DIR/$UNIT"
  fi
  systemctl --user daemon-reload
  if [ "$UNIT_CHANGED" = 1 ] && systemctl --user -q is-active "$UNIT"; then
    systemctl --user restart "$UNIT"
  fi
  systemctl --user enable --now "$UNIT" >/dev/null 2>&1 || { echo "error: systemctl --user could not start $UNIT" >&2; exit 1; }
  echo "doorbell service $UNIT is $(systemctl --user is-active "$UNIT")"
fi
# 3. The captain's steps.
echo
echo "Captain steps:"
n=0
if [ "$AGENT_NEW" = 1 ]; then
  n=$((n + 1))
  echo "  $n. Restart the Kiro Crew gateway (kirocrew restart). Crew reads agent files only when it starts."
fi
if [ "$enabled" != true ] || [ "$pending" = true ]; then
  n=$((n + 1))
  echo "  $n. Open /apps/detail/$APP in the Crew dashboard, read the permission, and click"
  echo "     \"Enable and allow chat control\", then confirm. The consent lets firstmate put"
  echo "     each worker chat in Trust mode, and it lets the app control every chat of this"
  echo "     Crew instance. Until then, every shell or file tool of a worker waits for an"
  echo "     approval in the dashboard."
fi
[ "$n" -gt 0 ] || echo "  none"
echo "Then run: $0 --home $HOME_DIR --check"
[ "$PRIMARY" = 0 ] || echo "Then open the primary's chat: $SCRIPT_DIR/fm-kirocrew-primary.sh --home $HOME_DIR"
