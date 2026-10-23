#!/usr/bin/env bash
# fm-kiro-lib.sh - Kiro CLI home and project-scoped configuration owner.
#
# Kiro CLI V3 resolves custom agents and expanded hooks from the current
# project's .kiro/ tree.
# KIRO_HOME still owns Firstmate's settings, data, and logs, but KAS 0.66.4
# (kiro-cli 2.22.1) can also discover the operator's global ~/.kiro
# configuration even when KIRO_HOME is set, and it persists V3 conversations
# under the login HOME's ~/.kiro/sessions, so a plain `kiro-cli --resume-id`
# reopens a Firstmate session without any of its launcher environment.
# Firstmate therefore uses both boundaries together:
#   - an isolated KIRO_HOME with chat.enableKnowledge=false;
#   - Kiro's own default agent for every V3 session (ship, scout, secondmate,
#     and the primary launcher), as other harnesses run on their defaults; no
#     Firstmate agent file is generated or tracked for V3;
#   - task-specific project lifecycle hooks whose command names the tracked
#     adapter by the absolute path of this library's own bin directory and
#     passes the task's absolute KIRO_HOME, so a hook reaches its task from any
#     folder and without launcher environment (a session resumed with plain
#     kiro-cli carries neither).
#
# V2 remains an explicit compatibility fallback only.
# Its legacy embedded-hook agent receives a distinct name, so the retired V3
# per-task agent name (firstmate-kiro-<id>) can never shadow it.
#
# Generated project files are task-specific and idempotent by exact bytes.
# The Kiro workspace bridge is a regular copy of the isolated-home payload.
# An existing different file, symlink, symlinked configuration directory, or
# unsafe destination refuses rather than overwriting project-owned material.
# Callers add the generated paths to git's per-worktree exclude and retire them
# through fm_control_harness_wiring_paths.
#
# Sourced by fm-spawn.sh, fm-control-lib.sh, fm-teardown.sh, and the primary
# launcher.

FM_KIRO_V3_AGENT_PREFIX=firstmate-kiro
FM_KIRO_V2_AGENT_PREFIX=firstmate-kiro-v2
FM_KIRO_V3_HOOK_PREFIX=fm-firstmate
FM_KIRO_V3_ORACLE_PREFIX=firstmate-oracle

fm_kiro_slug_valid() {
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# The per-task V3 agent file (.kiro/agents/firstmate-kiro-<id>.json) is retired:
# every V3 session runs on Kiro's default agent. Its name stays only so a
# spawn, relaunch, or cleanup removes the copy an earlier launch left behind.
fm_kiro_v3_agent_name() {  # <task-id>
  fm_kiro_slug_valid "$1" || return 1
  printf '%s-%s' "$FM_KIRO_V3_AGENT_PREFIX" "$1"
}

fm_kiro_v2_agent_name() {  # <task-id>
  fm_kiro_slug_valid "$1" || return 1
  printf '%s-%s' "$FM_KIRO_V2_AGENT_PREFIX" "$1"
}

fm_kiro_v3_agent_relpath() {  # <task-id>
  printf '.kiro/agents/%s.json' "$(fm_kiro_v3_agent_name "$1")"
}

fm_kiro_v3_oracle_name() {  # <task-id>
  fm_kiro_slug_valid "$1" || return 1
  printf '%s-%s' "$FM_KIRO_V3_ORACLE_PREFIX" "$1"
}

fm_kiro_v3_oracle_relpath() {  # <task-id>
  printf '.kiro/agents/%s.json' "$(fm_kiro_v3_oracle_name "$1")"
}

fm_kiro_v3_hook_relpath() {  # <task-id>
  fm_kiro_slug_valid "$1" || return 1
  printf '.kiro/hooks/%s-%s.json' "$FM_KIRO_V3_HOOK_PREFIX" "$1"
}

fm_kiro_v3_agent_path() {  # <workspace> <task-id>
  printf '%s/%s' "${1%/}" "$(fm_kiro_v3_agent_relpath "$2")"
}

fm_kiro_v3_oracle_path() {  # <workspace> <task-id>
  printf '%s/%s' "${1%/}" "$(fm_kiro_v3_oracle_relpath "$2")"
}

fm_kiro_v3_hook_path() {  # <workspace> <task-id>
  printf '%s/%s' "${1%/}" "$(fm_kiro_v3_hook_relpath "$2")"
}

fm_kiro_v3_oracle_home_path() {  # <kiro-home> <task-id>
  printf '%s/project/.kiro/agents/%s.json' "${1%/}" "$(fm_kiro_v3_oracle_name "$2")"
}

fm_kiro_v3_hook_home_path() {  # <kiro-home> <task-id>
  printf '%s/project/.kiro/hooks/%s-%s.json' "${1%/}" "$FM_KIRO_V3_HOOK_PREFIX" "$2"
}

fm_kiro_safe_dir() {  # <dir>
  local dir=$1
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    [ -d "$dir" ] && [ ! -L "$dir" ]
    return
  fi
  mkdir "$dir" 2>/dev/null || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ]
}

fm_kiro_prepare_home() {  # <kiro-home>
  local home=$1
  [ -n "$home" ] || return 1
  fm_kiro_safe_dir "$home" || return 1
  fm_kiro_safe_dir "$home/settings" || return 1
  fm_kiro_safe_dir "$home/agents" || return 1
  fm_kiro_safe_dir "$home/data" || return 1
}

fm_kiro_publish_owned() {  # <destination>, content on stdin
  local dest=$1 parent tmp
  parent=${dest%/*}
  fm_kiro_safe_dir "$parent" || return 1
  tmp=$(mktemp "$parent/.fm-kiro.XXXXXXXXXXXX") || return 1
  if ! cat > "$tmp" || ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp" 2>/dev/null || true
    return 1
  fi
  [ -f "$dest" ] && [ ! -L "$dest" ]
}

fm_kiro_publish_project_copy() {  # <destination> <source>
  local dest=$1 source=$2 parent tmp
  parent=${dest%/*}
  fm_kiro_safe_dir "$parent" || return 1
  [ -f "$source" ] && [ ! -L "$source" ] || return 1
  [ ! -L "$dest" ] || return 1
  if [ -e "$dest" ]; then
    [ -f "$dest" ] && cmp -s "$dest" "$source" || return 1
  fi
  tmp=$(mktemp "$parent/.fm-kiro.XXXXXXXXXXXX") || return 1
  if ! cp -- "$source" "$tmp" || ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp" 2>/dev/null || true
    return 1
  fi
  [ -f "$dest" ] && [ ! -L "$dest" ]
}

# The tracked lifecycle-hook adapter, resolved once from this library's own
# directory. Every generated hook command names it by this absolute path.
FM_KIRO_TURNEND_HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-kiro-turnend-hook.sh"

fm_kiro_shell_quote() {  # <value>
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# Print <value> as a JSON string body. Control characters refuse rather than
# producing a hook document Kiro would reject or misread.
fm_kiro_json_string() {  # <value>
  case "$1" in *[[:cntrl:]]*) return 1 ;; esac
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Print the hook command for one task's generated V3 hook file or V2 agent.
# The per-task KIRO_HOME is the only binding a resumed session needs: it holds
# the turn-end pointer, the registry, and the session record from which
# bin/fm-kiro-turnend-hook.sh recovers the busy generation.
fm_kiro_task_hook_command() {  # <kiro-home>
  case "$1" in /*) ;; *) return 1 ;; esac
  printf '%s --kiro-home %s' "$(fm_kiro_shell_quote "$FM_KIRO_TURNEND_HOOK")" "$(fm_kiro_shell_quote "${1%/}")"
}

# Print the hook command for the explicit V2 primary agent, which lives in the
# per-home isolated KIRO_HOME rather than in the tracked project hooks.
fm_kiro_primary_hook_command() {
  printf 'FM_KIRO_PRIMARY_HOOK=1 %s' "$(fm_kiro_shell_quote "$FM_KIRO_TURNEND_HOOK")"
}

# kiro-cli reads user skills from <KIRO_HOME>/skills, and the isolated KIRO_HOME
# would otherwise hide the captain's ~/.kiro/skills. Link (never copy) it so a
# new user skill shows up without a respawn; the real directory is only read
# through the link, so ~/.kiro is never written. An absent user directory
# leaves no entry (and drops a stale link from an earlier build).
fm_kiro_link_user_skills() {  # <kiro-home>
  local home=$1 src
  [ -n "$home" ] || return 1
  if [ -L "$home/skills" ]; then
    rm -f -- "$home/skills" || return 1
  elif [ -e "$home/skills" ]; then
    return 0
  fi
  [ -n "${HOME:-}" ] && [ -d "$HOME/.kiro/skills" ] || return 0
  src=$(cd -- "$HOME/.kiro/skills" 2>/dev/null && pwd -P) || return 0
  ln -s -- "$src" "$home/skills"
}

fm_kiro_write_settings() {  # <kiro-home>
  local home=$1
  fm_kiro_prepare_home "$home" || return 1
  fm_kiro_publish_owned "$home/settings/cli.json" <<'EOF'
{
  "chat.disableTrustAllConfirmation": true,
  "chat.allowAnimations": false,
  "chat.enableKnowledge": false
}
EOF
  fm_kiro_link_user_skills "$home"
}

# kiro-cli 2.33.1 opens a "Trust this workspace?" dialog for a folder it has
# not seen and persists the answer at
# <KIRO_HOME>/workspace-roots/<hash>/permissions.yaml, where <hash> is the first
# 16 hex characters of the sha256 of the workspace path string (no trailing
# slash). Pre-registering that file in Firstmate's own KIRO_HOME removes the
# dialog; the captain's global ~/.kiro is never written.
fm_kiro_workspace_hash() {  # <workspace-path>
  local path=$1
  while [ "${#path}" -gt 1 ] && [ "${path%/}" != "$path" ]; do path=${path%/}; done
  printf '%s' "$path" | sha256sum | cut -c1-16
}

fm_kiro_trust_workspace() {  # <kiro-home> <workspace> [<workspace>...]
  local home=$1 workspace hash dir
  shift
  [ -n "$home" ] && [ "$#" -gt 0 ] || return 1
  fm_kiro_prepare_home "$home" || return 1
  for workspace in "$@"; do
    [ -n "$workspace" ] || continue
    hash=$(fm_kiro_workspace_hash "$workspace") || return 1
    dir="$home/workspace-roots/$hash"
    mkdir -p "$dir" || return 1
    fm_kiro_publish_owned "$dir/permissions.yaml" <<'EOF2'
rules: []
workspaceTrusted: true
EOF2
  done
}

fm_kiro_write_v2_agent() {  # <kiro-home> <agent-name> <hook-command>
  local home=$1 agent=$2 command
  fm_kiro_slug_valid "$agent" || return 1
  command=$(fm_kiro_json_string "$3") || return 1
  fm_kiro_prepare_home "$home" || return 1
  fm_kiro_publish_owned "$home/agents/$agent.json" <<EOF
{
  "name": "$agent",
  "description": "Firstmate-owned Kiro CLI V2 compatibility agent.",
  "tools": ["*"],
  "allowedTools": ["*"],
  "hooks": {
    "userPromptSubmit": [
      { "command": "$command" }
    ],
    "preToolUse": [
      { "command": "$command" }
    ],
    "postToolUse": [
      { "command": "$command" }
    ],
    "stop": [
      { "command": "$command" }
    ]
  }
}
EOF
}

# No V3 Firstmate session lists its own tools any more: every V3 kind runs on
# Kiro's default agent, whose tool set the worker tool check below enforces.
# A generated or tracked agent list had to name exact V3 tool ids, because V3
# matches an entry only to a tool id or a tool tag, and the CLI aliases
# `fs_read`, `grep`, `glob`, `web_search`, `introspect`, `session`, `report`,
# and `tool_search` had resolved to nothing: a worker listing them got only
# shell, fs_write, code, web_fetch, and invoke_sub_agent (kiro-cli 2.32.0,
# docs/verification/runtime-backends.md). The oracle below is the one agent
# file left, and it names V3 ids.

# The Opus oracle: a read-only advisor a ship or scout worker reaches through
# Kiro's V3 sub-agent tool, `invoke_sub_agent`, whose `name` argument selects a
# workspace agent by its agent-file name (verified live on kiro-cli 2.29.0 and,
# from the default agent, on 2.32.0). A secondmate and the primary get no
# oracle; on the default agent they keep Kiro's own sub-agent tool.
# The oracle gets only read-only V3 ids. Its
# permission rules deny shell, write, and sub-agent capabilities on top of the
# tool list, so a later widened list still cannot write or delegate.
FM_KIRO_V3_ORACLE_TOOLS_JSON='["read_file", "list_directory", "file_search", "grep_search", "code", "web_fetch", "remote_web_search"]'
FM_KIRO_V3_ORACLE_MODEL=claude-opus-5.5

# Only a ship or scout worker consults the oracle, and only in a home whose
# config/kiro-oracle does not say `off`. The setting is home-local and is not in
# the inherited-config list, so each home chooses for itself.
fm_kiro_oracle_enabled() {  # [<config-dir>]
  local setting=
  [ -n "${1:-}" ] && [ -f "$1/kiro-oracle" ] && IFS= read -r setting <"$1/kiro-oracle" || true
  [ "$setting" != off ]
}

fm_kiro_kind_consults_oracle() {  # <kind> [<config-dir>]
  case "${1:-}" in ship|scout) fm_kiro_oracle_enabled "${2:-}"; return ;; esac
  return 1
}

# Every kind fm-spawn launches (ship, scout, secondmate) gets the session tool
# check: on kiro-cli 2.32.0 the default agent gave each of them every file,
# image, search, write, shell, code, web, and sub-agent tool on a fresh spawn
# and after a relaunch (docs/verification/runtime-backends.md), and the check
# stops a session that was not given one. A library caller naming no kind gets
# hooks only.
fm_kiro_kind_checks_tools() {  # <kind>
  case "${1:-}" in ship|scout|secondmate) return 0 ;; esac
  return 1
}

# The tools a session of <kind> cannot do its job without. The session tool
# check in bin/fm-kiro-turnend-hook.sh stops a session that was not given one.
fm_kiro_worker_required_tools() {  # <kind> [<config-dir>]
  fm_kiro_kind_checks_tools "${1:-}" || return 0
  printf '%s\n' read_file list_directory file_search grep_search fs_write execute_bash
  if fm_kiro_kind_consults_oracle "$1" "${2:-}"; then
    printf '%s\n' invoke_sub_agent
  fi
}

# Where Kiro records each model request for this task (KIRO_DUMP_REQUESTS_DIR),
# the one place that names the tools Kiro actually sent the model, and the file
# listing the tools the worker tool check requires.
fm_kiro_request_record_dir() {  # <kiro-home>
  printf '%s/requests' "${1%/}"
}

fm_kiro_required_tools_path() {  # <kiro-home>
  printf '%s/.fm-kiro-required-tools' "${1%/}"
}

# The worker rule, carried in a ship or scout worker's launch brief: the one
# Kiro-specific worker guidance surface.
fm_kiro_oracle_rule() {  # <oracle-agent-name>
  printf 'Consult the oracle only for a hard architecture question (module or owner boundaries, cross-subsystem design, concurrency or migration shape), never for routine coding. Call invoke_sub_agent with name %s and a self-contained question. The oracle only advises: you keep the decision and the work.' "$1"
}

# The launch-brief section a Kiro ship or scout worker receives after its role
# contract. It prints nothing when the worker has no oracle.
fm_kiro_worker_brief_section() {  # <task-id> <kind> [<config-dir>]
  local oracle
  fm_kiro_kind_consults_oracle "${2:-}" "${3:-}" || return 0
  oracle=$(fm_kiro_v3_oracle_name "$1") || return 1
  printf '# Kiro oracle\n%s\n' "$(fm_kiro_oracle_rule "$oracle")"
}

fm_kiro_install_v3_project_config() {  # <workspace> <task-id> <kiro-home> [<kind> [<config-dir>]]
  local workspace=$1 id=$2 home=$3 kind=${4:-} config=${5:-} agent_path hook_path hook_home command
  local oracle oracle_path oracle_home required
  [ -d "$workspace" ] && [ ! -L "$workspace" ] || return 1
  [ -d "$home" ] && [ ! -L "$home" ] || return 1
  fm_kiro_slug_valid "$id" || return 1
  command=$(fm_kiro_task_hook_command "$home") || return 1
  command=$(fm_kiro_json_string "$command") || return 1
  fm_kiro_safe_dir "$workspace/.kiro" || return 1
  fm_kiro_safe_dir "$workspace/.kiro/agents" || return 1
  fm_kiro_safe_dir "$workspace/.kiro/hooks" || return 1
  fm_kiro_safe_dir "$home/project" || return 1
  fm_kiro_safe_dir "$home/project/.kiro" || return 1
  fm_kiro_safe_dir "$home/project/.kiro/agents" || return 1
  fm_kiro_safe_dir "$home/project/.kiro/hooks" || return 1
  agent_path=$(fm_kiro_v3_agent_path "$workspace" "$id") || return 1
  hook_path=$(fm_kiro_v3_hook_path "$workspace" "$id") || return 1
  hook_home=$(fm_kiro_v3_hook_home_path "$home" "$id") || return 1
  # A session launched before every kind moved to Kiro's default agent left its
  # generated agent here; drop it so the relaunched session cannot select it.
  rm -f -- "$agent_path" || return 1
  if fm_kiro_kind_consults_oracle "$kind" "$config"; then
    oracle=$(fm_kiro_v3_oracle_name "$id") || return 1
    oracle_path=$(fm_kiro_v3_oracle_path "$workspace" "$id") || return 1
    oracle_home=$(fm_kiro_v3_oracle_home_path "$home" "$id") || return 1
    fm_kiro_publish_owned "$oracle_home" <<EOF || return 1
{
  "name": "$oracle",
  "description": "Read-only Opus advisor for one hard architecture question. Reads and searches files, code, and the web; cannot write files, run shell commands, or call another agent.",
  "prompt": "You are a read-only architecture advisor consulted by a Firstmate worker. Answer the one self-contained question you are given: name the trade-offs, give one recommendation with its reason, and cite the files you read. You cannot write files, run shell commands, or call another agent. The worker keeps the decision and the work.",
  "model": "$FM_KIRO_V3_ORACLE_MODEL",
  "effortLevel": "high",
  "tools": $FM_KIRO_V3_ORACLE_TOOLS_JSON,
  "allowedTools": $FM_KIRO_V3_ORACLE_TOOLS_JSON,
  "excludedTools": ["knowledge", "execute_bash", "fs_write", "invoke_sub_agent"],
  "includeMcpJson": false,
  "includePowers": false,
  "permissions": {
    "rules": [
      { "capability": "shell", "effect": "deny" },
      { "capability": "fs_write", "effect": "deny" },
      { "capability": "subagent", "effect": "deny" }
    ]
  }
}
EOF
  fi
  if fm_kiro_kind_checks_tools "$kind"; then
    required=$(fm_kiro_worker_required_tools "$kind" "$config") || return 1
    printf '%s\n' "$required" | fm_kiro_publish_owned "$(fm_kiro_required_tools_path "$home")" || return 1
  fi
  case "$kind" in
    ship|scout)
      # In-turn steering delivery (bin/fm-kiro-turnend-hook.sh header).
      printf 'on\n' | fm_kiro_publish_owned "$home/.fm-kiro-steer-inject" || return 1
      ;;
  esac
  fm_kiro_publish_owned "$hook_home" <<EOF || return 1
{
  "version": "v1",
  "hooks": [
    {
      "name": "firstmate-prompt-submit",
      "trigger": "UserPromptSubmit",
      "action": {
        "type": "command",
        "command": "$command"
      }
    },
    {
      "name": "firstmate-pre-tool",
      "trigger": "PreToolUse",
      "action": {
        "type": "command",
        "command": "$command"
      }
    },
    {
      "name": "firstmate-post-tool",
      "trigger": "PostToolUse",
      "action": {
        "type": "command",
        "command": "$command"
      }
    },
    {
      "name": "firstmate-stop",
      "trigger": "Stop",
      "action": {
        "type": "command",
        "command": "$command"
      }
    }
  ]
}
EOF
  fm_kiro_publish_project_copy "$hook_path" "$hook_home" || return 1
  if [ -n "${oracle:-}" ]; then
    fm_kiro_publish_project_copy "$oracle_path" "$oracle_home" || return 1
  fi
}

fm_kiro_remove_v3_project_config() {  # <workspace> <task-id>
  local workspace=$1 id=$2 agent_path hook_path oracle_path
  agent_path=$(fm_kiro_v3_agent_path "$workspace" "$id") || return 1
  hook_path=$(fm_kiro_v3_hook_path "$workspace" "$id") || return 1
  oracle_path=$(fm_kiro_v3_oracle_path "$workspace" "$id") || return 1
  rm -f -- "$agent_path" "$hook_path" "$oracle_path" || return 1
  rmdir "$workspace/.kiro/agents" "$workspace/.kiro/hooks" "$workspace/.kiro" 2>/dev/null || true
}

# Build the firstmate-owned isolated KIRO_HOME for ONE task and print the
# turn-end token it registered:
#   settings/cli.json          - chat.disableTrustAllConfirmation=true (suppress
#                                the --trust-all-tools startup dialog, VERIFIED
#                                LIVE to otherwise render with its default on
#                                "No, exit" and block the launch) and
#                                chat.allowAnimations=false (freeze the spinner
#                                to one static frame for a stable screen-scrape
#                                baseline);
#   agents/<v2-agent>.json     - the explicit V2 fallback's embedded-hook agent,
#                                only when a V2 agent name is given;
#   agents/fm-turn-end.d/<tok> - this task's registry entry naming
#                                state/<id>.turn-ended;
#   workspace-roots/<hash>/permissions.yaml - pre-registered workspace trust
#                                (see fm_kiro_trust_workspace), when a workspace
#                                is given;
#   .fm-kiro-turnend           - the pointer carrying <tok>. The shared hook
#                                touches the registered file only when both
#                                agree, so a stray kiro-cli session under this
#                                KIRO_HOME that is not this task changes nothing
#                                (the grok/kimi guard shape).
# The directory is rewritten fresh on every spawn, which also drops the session
# record bin/fm-kiro-turnend-hook.sh keeps there, and bin/fm-teardown.sh retires
# it with `rm -rf`, so no separate registry cleanup is needed
# (bin/fm-control-lib.sh's auth path is empty for kiro-cli).
fm_kiro_build_task_home() {  # <kiro-home> <v2-agent-name-or-empty> <turn-end-path> [<workspace>]
  local home=$1 v2_agent=$2 turnend=$3 workspace=${4:-} physical auth_dir auth_file old_umask hook_command token
  [ -x "$FM_KIRO_TURNEND_HOOK" ] || {
    echo "error: kiro-cli turn-end hook missing or not executable at $FM_KIRO_TURNEND_HOOK" >&2
    return 1
  }
  hook_command=$(fm_kiro_task_hook_command "$home") || return 1
  rm -rf "$home" || return 1
  fm_kiro_write_settings "$home" || return 1
  if [ -n "$workspace" ]; then
    physical=$(cd -- "$workspace" 2>/dev/null && pwd -P) || physical=$workspace
    fm_kiro_trust_workspace "$home" "$workspace" "$physical" || return 1
  fi
  if [ -n "$v2_agent" ]; then
    fm_kiro_write_v2_agent "$home" "$v2_agent" "$hook_command" || return 1
  fi
  auth_dir="$home/agents/fm-turn-end.d"
  mkdir -p "$auth_dir" || return 1
  old_umask=$(umask)
  umask 077
  auth_file=$(mktemp "$auth_dir/fm.XXXXXXXXXXXX") || {
    umask "$old_umask"
    return 1
  }
  umask "$old_umask"
  printf '%s\n' "$turnend" > "$auth_file" || return 1
  token=${auth_file##*/}
  printf 'token=%s\n' "$token" > "$home/.fm-kiro-turnend" || return 1
  printf '%s\n' "$token"
}

fm_kiro_primary_home() {  # <state-dir>
  printf '%s/.kiro-primary-home' "${1%/}"
}
