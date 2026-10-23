#!/usr/bin/env bash
# fm-primary-endpoint-lib.sh - identity-bound primary endpoint and Kiro doorbell.
#
# A Kiro V3 primary cannot be continued from its Stop hook, so the only way to
# start its next turn after a durable wake is to type into its pane. This
# library owns the record of that pane and the constant lines typed into it.
# It creates no second queue, acknowledgement, or control plane: the doorbell
# only tells the model to handle the existing durable wake queue.
#
# A Kiro primary that runs in a Kiro Crew chat has no pane. Its hooks name the
# chat (FM_KIROCREW_SESSION_KEY, set by bin/fm-kiro-turnend-hook.sh from the
# payload's session_key), so the record names that chat on the `kirocrew`
# backend, and a ring sends the same constant line as a Crew message through
# the firstmate app (bin/fm-kirocrew.mjs ring) while Crew reports the chat
# idle. Its fleet-lock pid is the Crew gateway's, the frame the chat's hooks and
# tool shells share (bin/fm-session-lock-lib.sh fm_kiro_cli_process_matches).
#
# Record: state/.primary-endpoint, exactly eight lines:
#   schema=fm-primary-endpoint.v1
#   harness=kiro-cli
#   backend=tmux|herdr|kirocrew
#   target=<backend target: a pane, or a Kiro Crew dashboard chat name>
#   pid=<outer Kiro session pid or Kiro Crew gateway pid, also the fleet-lock pid>
#   pid_identity=<fm_pid_identity output>
#   root=<absolute Firstmate code root>
#   home=<absolute effective Firstmate home>
#
# Publication happens only for the session that holds the fleet lock: once at
# SessionStart, then idempotently every turn through fm_primary_endpoint_ensure.
# A ring revalidates the home, root, exact lock pid, process identity, outer
# process (`kiro-cli`, or the Crew gateway for a Crew chat), backend target, and
# empty Kiro composer or idle Crew chat; any stale, malformed, moved, busy,
# pending, dead, or unsupported record is a quiet
# refusal. bin/fm-primary-doorbell.sh is the only caller that rings: it owns
# watcher continuity for this primary and retries a refused ring on its own
# poll, so the watcher itself never types into the pane. Away mode keeps its
# existing daemon injection owner.
#
# Requires no caller-prepared globals. Sourcing is side-effect-free apart from
# the existing fm-wake-lib state-directory behavior reached by its dependencies.

FM_PRIMARY_ENDPOINT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$FM_PRIMARY_ENDPOINT_LIB_DIR/fm-supervisor-target-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$FM_PRIMARY_ENDPOINT_LIB_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$FM_PRIMARY_ENDPOINT_LIB_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$FM_PRIMARY_ENDPOINT_LIB_DIR/fm-session-lock-lib.sh"

FM_PRIMARY_ENDPOINT_SCHEMA=fm-primary-endpoint.v1
FM_PRIMARY_ENDPOINT_BACKEND=
FM_PRIMARY_ENDPOINT_TARGET=
FM_PRIMARY_ENDPOINT_ROOT=
FM_PRIMARY_ENDPOINT_HOME=
FM_PRIMARY_ENDPOINT_PID=
FM_PRIMARY_ENDPOINT_ERROR=

fm_primary_endpoint_fail() {
  FM_PRIMARY_ENDPOINT_ERROR=$1
  return 1
}

fm_primary_endpoint_path() {  # <state-dir>
  printf '%s/.primary-endpoint' "${1%/}"
}

fm_primary_endpoint_abs_dir() {  # <directory>
  [ -d "$1" ] && [ ! -L "$1" ] || return 1
  (CDPATH='' cd -- "$1" 2>/dev/null && pwd -P)
}

# True when <pid> is the kind of process the fleet lock of a <backend> endpoint
# records: the outer `kiro-cli` frame of a pane primary, or the Kiro Crew
# gateway in either of its two process forms.
fm_primary_endpoint_session_frame() {  # <backend> <pid>
  local comm
  comm=$(ps -o comm= -p "$2" 2>/dev/null) || return 1
  case "$1" in
    kirocrew) fm_kirocrew_gateway_process_matches "$comm" "$(ps -o args= -p "$2" 2>/dev/null)" ;;
    *) [ "${comm##*/}" = kiro-cli ] ;;
  esac
}

# A Kiro Crew chat name the record may carry, in the name set Crew gives
# dashboard chats.
fm_primary_endpoint_crew_chat_valid() {  # <chat>
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#1}" -le 128 ]
}

fm_primary_endpoint_kiro_pid() {  # <backend>
  local pid
  pid=$(fm_session_lock_anchor_pid) || return 1
  fm_primary_endpoint_session_frame "$1" "$pid" || return 1
  printf '%s' "$pid"
}

# Resolve what the record should say for this session right now, or fail with
# FM_PRIMARY_ENDPOINT_ERROR. Sets the FM_PRIMARY_ENDPOINT_OBS_* globals. Local
# and cheap: environment, one backend target probe, and the ancestry walk.
FM_PRIMARY_ENDPOINT_OBS_STATE=
FM_PRIMARY_ENDPOINT_OBS_ROOT=
FM_PRIMARY_ENDPOINT_OBS_HOME=
FM_PRIMARY_ENDPOINT_OBS_BACKEND=
FM_PRIMARY_ENDPOINT_OBS_TARGET=
FM_PRIMARY_ENDPOINT_OBS_PID=
fm_primary_endpoint_observe() {  # <state-dir> <root> <home>
  local state root home backend target pid lock_pid
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  FM_PRIMARY_ENDPOINT_ERROR=
  state=$(fm_primary_endpoint_abs_dir "$1") || { fm_primary_endpoint_fail "state directory is absent, symlinked, or unresolved"; return 1; }
  root=$(fm_primary_endpoint_abs_dir "$2") || { fm_primary_endpoint_fail "Firstmate code root is absent, symlinked, or unresolved"; return 1; }
  home=$(fm_primary_endpoint_abs_dir "$3") || { fm_primary_endpoint_fail "effective Firstmate home is absent, symlinked, or unresolved"; return 1; }
  if [ -n "${FM_KIROCREW_SESSION_KEY:-}" ]; then
    backend=kirocrew
    target=${FM_KIROCREW_SESSION_KEY#dashboard:}
    if [ "$target" = "$FM_KIROCREW_SESSION_KEY" ] || ! fm_primary_endpoint_crew_chat_valid "$target"; then
      fm_primary_endpoint_fail "the Kiro Crew session is not a dashboard chat with a plain name, the only chat a doorbell message reaches"
      return 1
    fi
  else
    backend=$(discover_supervisor_backend) || { fm_primary_endpoint_fail "supervisor backend was not structurally discoverable"; return 1; }
    target=$(discover_supervisor_target) || { fm_primary_endpoint_fail "supervisor target was not structurally discoverable"; return 1; }
    case "$backend" in
      tmux|herdr) ;;
      *) fm_primary_endpoint_fail "supervisor backend '$backend' is not supported by the Kiro doorbell"; return 1 ;;
    esac
    case "$target" in
      ''|*$'\n'*|*$'\r'*|*[![:print:]]*)
        fm_primary_endpoint_fail "supervisor target is empty or contains unsafe bytes"
        return 1
        ;;
    esac
    fm_backend_target_exists "$backend" "$target" || { fm_primary_endpoint_fail "supervisor target '$target' is not readable on backend '$backend'"; return 1; }
  fi
  pid=$(fm_primary_endpoint_kiro_pid "$backend") || { fm_primary_endpoint_fail "outer Kiro session pid could not be resolved from hook ancestry"; return 1; }
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  if [ "$lock_pid" != "$pid" ]; then
    fm_primary_endpoint_fail "fleet lock pid '${lock_pid:-absent}' does not match outer Kiro pid '$pid'"
    return 1
  fi
  FM_PRIMARY_ENDPOINT_OBS_STATE=$state
  FM_PRIMARY_ENDPOINT_OBS_ROOT=$root
  FM_PRIMARY_ENDPOINT_OBS_HOME=$home
  FM_PRIMARY_ENDPOINT_OBS_BACKEND=$backend
  FM_PRIMARY_ENDPOINT_OBS_TARGET=$target
  FM_PRIMARY_ENDPOINT_OBS_PID=$pid
}

# Write the observed record atomically.
fm_primary_endpoint_write_observed() {
  local state=$FM_PRIMARY_ENDPOINT_OBS_STATE pid=$FM_PRIMARY_ENDPOINT_OBS_PID identity path tmp
  identity=$(fm_pid_identity "$pid") || { fm_primary_endpoint_fail "outer Kiro pid identity could not be read"; return 1; }
  case "$identity" in
    ''|*$'\n'*|*$'\r'*)
      fm_primary_endpoint_fail "outer Kiro pid identity is empty or multiline"
      return 1
      ;;
  esac
  path=$(fm_primary_endpoint_path "$state")
  tmp=$(umask 077; mktemp "$state/.primary-endpoint.XXXXXXXXXXXX") || { fm_primary_endpoint_fail "endpoint record temporary file could not be created"; return 1; }
  if ! {
    printf 'schema=%s\n' "$FM_PRIMARY_ENDPOINT_SCHEMA"
    printf 'harness=kiro-cli\n'
    printf 'backend=%s\n' "$FM_PRIMARY_ENDPOINT_OBS_BACKEND"
    printf 'target=%s\n' "$FM_PRIMARY_ENDPOINT_OBS_TARGET"
    printf 'pid=%s\n' "$pid"
    printf 'pid_identity=%s\n' "$identity"
    printf 'root=%s\n' "$FM_PRIMARY_ENDPOINT_OBS_ROOT"
    printf 'home=%s\n' "$FM_PRIMARY_ENDPOINT_OBS_HOME"
  } > "$tmp" || ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp" 2>/dev/null || true
    fm_primary_endpoint_fail "endpoint record could not be published atomically"
    return 1
  fi
  return 0
}

fm_primary_endpoint_publish() {  # <state-dir> <root> <home>
  fm_primary_endpoint_observe "$1" "$2" "$3" || return 1
  fm_primary_endpoint_write_observed
}

# fm_primary_endpoint_ensure: the per-turn owner. Kiro fires SessionStart only
# for a conversation's first prompt, so a primary whose hooks arrived later, whose
# pane moved, or whose outer pid changed would otherwise keep a missing or stale
# doorbell for the rest of the session. The primary's UserPromptSubmit and Stop
# hooks call this every turn. It converges on the record this session would
# publish: a record that already loads and names this session's backend, target,
# and pid is left untouched; anything else is republished. It refuses exactly
# where publication refuses - above all when the fleet lock is not this
# session's, so another session's record is never overwritten.
# Sets FM_PRIMARY_ENDPOINT_ENSURED=current|published on success.
FM_PRIMARY_ENDPOINT_ENSURED=
fm_primary_endpoint_ensure() {  # <state-dir> <root> <home>
  FM_PRIMARY_ENDPOINT_ENSURED=
  fm_primary_endpoint_observe "$1" "$2" "$3" || return 1
  if fm_primary_endpoint_load "$FM_PRIMARY_ENDPOINT_OBS_STATE" "$FM_PRIMARY_ENDPOINT_OBS_ROOT" "$FM_PRIMARY_ENDPOINT_OBS_HOME" \
    && [ "$FM_PRIMARY_ENDPOINT_BACKEND" = "$FM_PRIMARY_ENDPOINT_OBS_BACKEND" ] \
    && [ "$FM_PRIMARY_ENDPOINT_TARGET" = "$FM_PRIMARY_ENDPOINT_OBS_TARGET" ] \
    && [ "$FM_PRIMARY_ENDPOINT_PID" = "$FM_PRIMARY_ENDPOINT_OBS_PID" ]; then
    # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
    FM_PRIMARY_ENDPOINT_ENSURED=current
    return 0
  fi
  fm_primary_endpoint_write_observed || return 1
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  FM_PRIMARY_ENDPOINT_ENSURED=published
}

# Parse the record in state dir <state> and check what needs no live process:
# the exact eight keys, the schema, harness, backend, target and pid shapes,
# and the expected root and home. Sets the FM_PRIMARY_ENDPOINT_REC_* globals.
# bin/fm-primary-doorbell.sh serve reads a record whose gateway died this way.
FM_PRIMARY_ENDPOINT_REC_BACKEND=
FM_PRIMARY_ENDPOINT_REC_TARGET=
FM_PRIMARY_ENDPOINT_REC_PID=
FM_PRIMARY_ENDPOINT_REC_IDENTITY=
FM_PRIMARY_ENDPOINT_REC_ROOT=
FM_PRIMARY_ENDPOINT_REC_HOME=
fm_primary_endpoint_read() {  # <state-dir> <expected-root> <expected-home>
  local state=$1 expected_root expected_home path line key value
  local schema='' harness='' backend='' target='' pid='' identity='' root='' home=''
  FM_PRIMARY_ENDPOINT_REC_BACKEND=
  FM_PRIMARY_ENDPOINT_REC_TARGET=
  FM_PRIMARY_ENDPOINT_REC_PID=
  FM_PRIMARY_ENDPOINT_REC_IDENTITY=
  FM_PRIMARY_ENDPOINT_REC_ROOT=
  FM_PRIMARY_ENDPOINT_REC_HOME=
  state=$(fm_primary_endpoint_abs_dir "$state") || return 1
  expected_root=$(fm_primary_endpoint_abs_dir "$2") || return 1
  expected_home=$(fm_primary_endpoint_abs_dir "$3") || return 1
  path=$(fm_primary_endpoint_path "$state")
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *=*) key=${line%%=*}; value=${line#*=} ;;
      *) return 1 ;;
    esac
    case "$key" in
      schema) [ -z "$schema" ] || return 1; schema=$value ;;
      harness) [ -z "$harness" ] || return 1; harness=$value ;;
      backend) [ -z "$backend" ] || return 1; backend=$value ;;
      target) [ -z "$target" ] || return 1; target=$value ;;
      pid) [ -z "$pid" ] || return 1; pid=$value ;;
      pid_identity) [ -z "$identity" ] || return 1; identity=$value ;;
      root) [ -z "$root" ] || return 1; root=$value ;;
      home) [ -z "$home" ] || return 1; home=$value ;;
      *) return 1 ;;
    esac
  done < "$path"
  [ "$schema" = "$FM_PRIMARY_ENDPOINT_SCHEMA" ] || return 1
  [ "$harness" = kiro-cli ] || return 1
  case "$backend" in tmux|herdr|kirocrew) ;; *) return 1 ;; esac
  case "$target" in ''|*$'\n'*|*$'\r'*|*[![:print:]]*) return 1 ;; esac
  case "$pid" in ''|*[!0-9]*|0) return 1 ;; esac
  [ -n "$identity" ] || return 1
  [ "$root" = "$expected_root" ] || return 1
  [ "$home" = "$expected_home" ] || return 1
  # A Crew chat is checked by name only, with no request to the gateway; the
  # ring finds out whether Crew still lists it.
  [ "$backend" != kirocrew ] || fm_primary_endpoint_crew_chat_valid "$target" || return 1
  FM_PRIMARY_ENDPOINT_REC_BACKEND=$backend
  FM_PRIMARY_ENDPOINT_REC_TARGET=$target
  FM_PRIMARY_ENDPOINT_REC_PID=$pid
  FM_PRIMARY_ENDPOINT_REC_IDENTITY=$identity
  FM_PRIMARY_ENDPOINT_REC_ROOT=$root
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  FM_PRIMARY_ENDPOINT_REC_HOME=$home
}

fm_primary_endpoint_load() {  # <state-dir> <expected-root> <expected-home>
  local state=$1 backend pid lock_pid='' current=''
  FM_PRIMARY_ENDPOINT_BACKEND=
  FM_PRIMARY_ENDPOINT_TARGET=
  FM_PRIMARY_ENDPOINT_ROOT=
  FM_PRIMARY_ENDPOINT_HOME=
  FM_PRIMARY_ENDPOINT_PID=
  fm_primary_endpoint_read "$state" "$2" "$3" || return 1
  backend=$FM_PRIMARY_ENDPOINT_REC_BACKEND
  pid=$FM_PRIMARY_ENDPOINT_REC_PID
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  [ "$lock_pid" = "$pid" ] || return 1
  current=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ "$current" = "$FM_PRIMARY_ENDPOINT_REC_IDENTITY" ] || return 1
  fm_primary_endpoint_session_frame "$backend" "$pid" || return 1
  [ "$backend" = kirocrew ] || fm_backend_target_exists "$backend" "$FM_PRIMARY_ENDPOINT_REC_TARGET" || return 1
  FM_PRIMARY_ENDPOINT_BACKEND=$backend
  FM_PRIMARY_ENDPOINT_TARGET=$FM_PRIMARY_ENDPOINT_REC_TARGET
  FM_PRIMARY_ENDPOINT_ROOT=$FM_PRIMARY_ENDPOINT_REC_ROOT
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  FM_PRIMARY_ENDPOINT_HOME=$FM_PRIMARY_ENDPOINT_REC_HOME
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  FM_PRIMARY_ENDPOINT_PID=$pid
  return 0
}

fm_primary_endpoint_shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

fm_primary_endpoint_doorbell_line() {  # <root>
  local root=$1 drain
  drain=$(fm_primary_endpoint_shell_quote "$root/bin/fm-wake-drain.sh") || return 1
  printf ': Firstmate wake waiting: handle the durable wake context attached by the Kiro UserPromptSubmit hook; if none was attached, run %s now, then run the exact WAKE_ACK_REQUIRED command after handling.' "$drain"
}

fm_primary_endpoint_failure_line() {  # <root>
  local root=$1 drain owner
  drain=$(fm_primary_endpoint_shell_quote "$root/bin/fm-wake-drain.sh") || return 1
  owner=$(fm_primary_endpoint_shell_quote "$root/bin/fm-primary-doorbell.sh") || return 1
  printf ': Firstmate watcher continuity FAILED: the doorbell owner stopped after repeated failed watcher starts; run %s and handle it, read state/.primary-doorbell-failed and state/.watch-cycle-exits.log, then run %s ensure once.' "$drain" "$owner"
}

# The line the doorbell service sends a Kiro Crew chat it restored after a
# gateway restart (bin/fm-primary-doorbell.sh serve). Its prompt finds the
# fleet lock on the dead gateway pid, so the Kiro hook attaches a new session
# digest, which takes the lock on the new gateway and republishes the record.
fm_primary_endpoint_restart_line() {  # <root>
  local start
  start=$(fm_primary_endpoint_shell_quote "$1/bin/fm-session-start.sh") || return 1
  printf ': Firstmate: the Kiro Crew gateway restarted, so this chat was restored from its transcript and any turn that was running was lost. Take the helm again from the session digest the Kiro hook attached; if none was attached, run %s now.' "$start"
}

# Why the last ring returned: sent; refused (no loadable record, away mode, a
# busy pane or chat, or a composer holding text); absent (Kiro Crew no longer
# lists the chat); or failed (the gateway or the message failed).
FM_PRIMARY_ENDPOINT_RING_RESULT=

# Run one bin/fm-kirocrew.mjs verb for home <home>, with the app token cached in
# state dir <state>.
fm_primary_endpoint_crew_cli() {  # <state-dir> <home> <verb> [args...]
  local state=$1 home=$2 verb=$3
  shift 3
  node "$FM_PRIMARY_ENDPOINT_LIB_DIR/fm-kirocrew.mjs" "$verb" --home "$home" --state-dir "$state" \
    --config-dir "${FM_CONFIG_OVERRIDE:-$home/config}" "$@"
}

# Read what Kiro Crew reports for chat <chat>: FM_PRIMARY_ENDPOINT_CREW_STATE
# (idle, working, approval, queued, or absent) and FM_PRIMARY_ENDPOINT_CREW_GEN
# (the gateway process generation, empty when Crew lists no chat). Fails when
# the gateway does not answer.
FM_PRIMARY_ENDPOINT_CREW_STATE=
FM_PRIMARY_ENDPOINT_CREW_GEN=
fm_primary_endpoint_crew_observe() {  # <state-dir> <home> <chat>
  local out
  FM_PRIMARY_ENDPOINT_CREW_STATE=
  FM_PRIMARY_ENDPOINT_CREW_GEN=
  out=$(fm_primary_endpoint_crew_cli "$1" "$2" state --slot "$3" 2>/dev/null) || return 1
  case "$out" in
    'state='?*' gen='*) ;;
    *) return 1 ;;
  esac
  FM_PRIMARY_ENDPOINT_CREW_STATE=${out%% gen=*}
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  FM_PRIMARY_ENDPOINT_CREW_STATE=${FM_PRIMARY_ENDPOINT_CREW_STATE#state=}
  FM_PRIMARY_ENDPOINT_CREW_GEN=${out##* gen=}
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  case "$FM_PRIMARY_ENDPOINT_CREW_GEN" in
    *[!A-Za-z0-9._-]*) FM_PRIMARY_ENDPOINT_CREW_GEN= ;;
  esac
  return 0
}

# Restore Kiro Crew chat <chat> from its transcript after a gateway restart
# dropped it, and ask for Trust again.
fm_primary_endpoint_crew_resume() {  # <state-dir> <home> <chat>
  fm_primary_endpoint_crew_cli "$1" "$2" resume --slot "$3" >/dev/null 2>&1
}

# Send <line> to Kiro Crew chat <chat> through the firstmate app, only while
# Crew reports the chat idle (bin/fm-kirocrew.mjs ring). Sets
# FM_PRIMARY_ENDPOINT_RING_RESULT.
fm_primary_endpoint_ring_crew() {  # <state-dir> <home> <chat> <line>
  local rc=0
  fm_primary_endpoint_crew_cli "$1" "$2" ring --slot "$3" --message "$4" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) FM_PRIMARY_ENDPOINT_RING_RESULT=sent; return 0 ;;
    5) FM_PRIMARY_ENDPOINT_RING_RESULT=absent ;;
    6) FM_PRIMARY_ENDPOINT_RING_RESULT=refused ;;
    *) FM_PRIMARY_ENDPOINT_RING_RESULT=failed ;;
  esac
  return 1
}

# Remove the record while it still names Kiro Crew chat <chat> on pid <pid>:
# the doorbell owner's answer to a chat that Crew stopped listing while that
# gateway still runs, which means the captain closed it. A record republished
# for another chat or another gateway stays.
fm_primary_endpoint_retire_crew() {  # <state-dir> <chat> <pid>
  local path
  path=$(fm_primary_endpoint_path "$1")
  [ -f "$path" ] && [ ! -L "$path" ] || return 0
  grep -qxF 'backend=kirocrew' "$path" && grep -qxF "target=$2" "$path" \
    && grep -qxF "pid=$3" "$path" || return 0
  rm -f -- "$path"
}

# fm_primary_endpoint_ring_kiro <state-dir> <root> <home> <wake|failure>
# Ring the published endpoint with one constant line, or return 1 without
# sending anything when the record does not load, away mode is active, or the
# composer is not provably empty (a Crew chat: not idle). A pane gets the line
# typed and submitted; a Kiro Crew chat gets it as a message.
fm_primary_endpoint_ring_kiro() {
  local state=$1 root=$2 home=$3 kind=$4 composer line verdict
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  FM_PRIMARY_ENDPOINT_RING_RESULT=refused
  [ ! -e "$state/.afk" ] || return 1
  fm_primary_endpoint_load "$state" "$root" "$home" || return 1
  case "$kind" in
    wake) line=$(fm_primary_endpoint_doorbell_line "$FM_PRIMARY_ENDPOINT_ROOT") || return 1 ;;
    failure) line=$(fm_primary_endpoint_failure_line "$FM_PRIMARY_ENDPOINT_ROOT") || return 1 ;;
    *) return 1 ;;
  esac
  if [ "$FM_PRIMARY_ENDPOINT_BACKEND" = kirocrew ]; then
    fm_primary_endpoint_ring_crew "$state" "$FM_PRIMARY_ENDPOINT_HOME" "$FM_PRIMARY_ENDPOINT_TARGET" "$line"
    return
  fi
  composer=$(fm_backend_composer_state "$FM_PRIMARY_ENDPOINT_BACKEND" \
    "$FM_PRIMARY_ENDPOINT_TARGET" '' kiro-cli 2>/dev/null) || return 1
  [ "$composer" = empty ] || return 1
  verdict=$(fm_backend_send_text_submit "$FM_PRIMARY_ENDPOINT_BACKEND" \
    "$FM_PRIMARY_ENDPOINT_TARGET" "$line" 1 0.4 0.3 2>/dev/null) || { FM_PRIMARY_ENDPOINT_RING_RESULT=failed; return 1; }
  [ "$verdict" != send-failed ] || { FM_PRIMARY_ENDPOINT_RING_RESULT=failed; return 1; }
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  FM_PRIMARY_ENDPOINT_RING_RESULT=sent
}
