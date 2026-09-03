#!/usr/bin/env bash
# fm-forensics-collect.sh - bounded, redacted, read-only task evidence packet.
#
# Usage:
#   FM_HOME=/path/to/home bin/fm-forensics-collect.sh <task-id>
#
# The packet is written to stdout only.
# It reports evidence and leads, never a cause or verdict.
# Source bodies that may contain captain-private data are represented by
# structural fields and bounded SHA-256 or cksum samples instead of raw text.
# Missing or malformed sources are recorded and do not stop the remaining read.
#
# Bounds may be lowered for constrained runs and tests:
#   FM_FORENSICS_MAX_BYTES          total stdout bytes (default 65536)
#   FM_FORENSICS_SOURCE_BYTES       bytes sampled from one source (default 16384)
#   FM_FORENSICS_SOURCE_LINES       records emitted per source (default 40)
#   FM_FORENSICS_SCAN_LINES         trailing JSONL records scanned (default 2000)
#   FM_FORENSICS_COMMAND_TIMEOUT    seconds per external probe (default 5)
#   FM_FORENSICS_CREW_STATE_BIN     current-state reader override for tests
#
# The current-state reader receives bounded copies in a private scratch state.
# This keeps pull-source caches and every other helper write outside FM_HOME.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
BACKLOG="$DATA/backlog.md"

MAX_BYTES=${FM_FORENSICS_MAX_BYTES:-65536}
SOURCE_BYTES=${FM_FORENSICS_SOURCE_BYTES:-16384}
SOURCE_LINES=${FM_FORENSICS_SOURCE_LINES:-40}
SCAN_LINES=${FM_FORENSICS_SCAN_LINES:-2000}
COMMAND_TIMEOUT=${FM_FORENSICS_COMMAND_TIMEOUT:-5}

usage() {
  local rc=${1:-2}
  if [ "$rc" -eq 0 ]; then
    cat <<'EOF'
usage: fm-forensics-collect.sh <task-id>

Print one bounded, redacted, read-only task evidence packet to stdout.
Set FM_HOME explicitly when inspecting a home other than this code root.
EOF
  else
    cat >&2 <<'EOF'
usage: fm-forensics-collect.sh <task-id>
EOF
  fi
  exit "$rc"
}

positive_integer() {
  case "$2" in
    ''|*[!0-9]*|0)
      printf 'fm-forensics-collect: %s must be a positive integer\n' "$1" >&2
      exit 2
      ;;
  esac
}

positive_integer FM_FORENSICS_MAX_BYTES "$MAX_BYTES"
positive_integer FM_FORENSICS_SOURCE_BYTES "$SOURCE_BYTES"
positive_integer FM_FORENSICS_SOURCE_LINES "$SOURCE_LINES"
positive_integer FM_FORENSICS_SCAN_LINES "$SCAN_LINES"
positive_integer FM_FORENSICS_COMMAND_TIMEOUT "$COMMAND_TIMEOUT"
[ "$MAX_BYTES" -ge 512 ] || {
  echo "fm-forensics-collect: FM_FORENSICS_MAX_BYTES must be at least 512" >&2
  exit 2
}
[ "$MAX_BYTES" -le 1048576 ] && [ "$SOURCE_BYTES" -le 262144 ] \
  && [ "$SOURCE_LINES" -le 1000 ] && [ "$SCAN_LINES" -le 10000 ] \
  && [ "$COMMAND_TIMEOUT" -le 60 ] || {
  echo "fm-forensics-collect: a requested bound exceeds the collector ceiling" >&2
  exit 2
}

[ "$#" -eq 1 ] || usage
case "$1" in -h|--help) usage 0 ;; esac
ID=$1
case "$ID" in
  ''|*[!A-Za-z0-9._-]*) usage ;;
esac
[ "${#ID}" -le 128 ] || usage

umask 077
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-forensics.XXXXXX") || {
  echo "fm-forensics-collect: could not create private scratch space" >&2
  exit 1
}
cleanup() { rm -rf -- "$TMP_ROOT"; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

PACKET="$TMP_ROOT/packet"
SHADOW_STATE="$TMP_ROOT/state"
mkdir -p "$SHADOW_STATE"
: > "$PACKET"

if command -v sha256sum >/dev/null 2>&1; then
  HASH_ALGORITHM=sha256
  digest_stream() { sha256sum | awk '{ print $1 }'; }
elif command -v shasum >/dev/null 2>&1; then
  HASH_ALGORITHM=sha256
  digest_stream() { shasum -a 256 | awk '{ print $1 }'; }
else
  HASH_ALGORITHM='cksum'
  digest_stream() { cksum | awk '{ print $1 ":" $2 }'; }
fi

emit() { printf '%s\n' "$*" >> "$PACKET"; }

safe_atom() {
  printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._:+/@=-' '?' | LC_ALL=C cut -c1-96
}

file_bytes() {
  stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null || printf 'unknown\n'
}

sample_digest() {
  LC_ALL=C head -c "$SOURCE_BYTES" "$1" 2>/dev/null | digest_stream
}

text_digest() { printf '%s' "$1" | digest_stream; }

bounded_tail() {
  LC_ALL=C tail -n "$SOURCE_LINES" "$1" 2>/dev/null | LC_ALL=C head -c "$SOURCE_BYTES"
}

meta_value() {
  LC_ALL=C awk -F= -v key="$1" '
    $1 == key { count++; sub(/^[^=]*=/, ""); value=$0 }
    END { if (count == 1 && value != "") print value; else exit 1 }
  ' "$2"
}

meta_count() {
  LC_ALL=C awk -F= -v key="$1" '$1 == key { count++ } END { print count + 0 }' "$2"
}

append_duplicate_lead() {
  local label=$1 hashes=$2 duplicates
  duplicates=$(LC_ALL=C sort "$hashes" 2>/dev/null | uniq -d | wc -l | tr -d ' ')
  case "$duplicates" in ''|*[!0-9]*) duplicates=0 ;; esac
  [ "$duplicates" -eq 0 ] || emit "- [lead] repeated $label: duplicate_digests=$duplicates"
}

emit "schema: fm-forensics-packet.v1"
emit "task: $ID"
emit "classification: evidence leads only; no causal conclusion"
emit "redaction: private bodies and path values excluded; samples represented by $HASH_ALGORITHM digests"
emit "bounds: total_bytes=$MAX_BYTES source_bytes=$SOURCE_BYTES source_records=$SOURCE_LINES scan_lines=$SCAN_LINES command_timeout_seconds=$COMMAND_TIMEOUT"

META="$STATE/$ID.meta"
META_SAMPLE="$TMP_ROOT/meta"
STATUS="$STATE/$ID.status"
KIND=
HARNESS=
HARNESS_FAMILY=unknown
WORKTREE=

emit ""
emit "## Task identity"
if [ -f "$META" ] && [ ! -L "$META" ]; then
  LC_ALL=C head -c "$SOURCE_BYTES" "$META" > "$META_SAMPLE" 2>/dev/null || :
  emit "- meta: present bytes=$(file_bytes "$META") sample_${HASH_ALGORITHM}=$(sample_digest "$META")"
  for key in endpoint_task_id harness kind mode yolo backend model effort spawn_gen busy_gen terminal; do
    count=$(meta_count "$key" "$META_SAMPLE")
    if [ "$count" -gt 1 ]; then
      emit "- [lead] ambiguous metadata field: key=$key count=$count"
    elif value=$(meta_value "$key" "$META_SAMPLE" 2>/dev/null); then
      case "$key" in
        endpoint_task_id)
          emit "- endpoint_task_id_matches: $([ "$value" = "$ID" ] && printf true || printf false)"
          ;;
        harness)
          HARNESS=$value
          case "$value" in
            claude*) HARNESS_FAMILY=claude ;;
            codex*) HARNESS_FAMILY=codex ;;
            opencode*) HARNESS_FAMILY=opencode ;;
            pi|pi-signed) HARNESS_FAMILY=$value ;;
            grok*) HARNESS_FAMILY=grok ;;
            kimi*) HARNESS_FAMILY=kimi ;;
            cursor*) HARNESS_FAMILY=cursor ;;
            muse*) HARNESS_FAMILY=muse ;;
            echo) HARNESS_FAMILY='echo' ;;
            *) HARNESS_FAMILY=unknown ;;
          esac
          emit "- harness: $HARNESS_FAMILY"
          [ "$HARNESS_FAMILY" != unknown ] || emit "- harness_value_${HASH_ALGORITHM}: $(text_digest "$value")"
          ;;
        kind)
          KIND=$value
          case "$value" in ship|scout|secondmate) emit "- kind: $value" ;; *) emit "- kind: unknown" ;; esac
          ;;
        mode)
          case "$value" in no-mistakes|direct-PR|local-only|secondmate) emit "- mode: $value" ;; *) emit "- mode: unknown" ;; esac
          ;;
        yolo)
          case "$value" in on|off) emit "- yolo: $value" ;; *) emit "- yolo: unknown" ;; esac
          ;;
        backend)
          case "$value" in tmux|herdr|zellij|orca|cmux) emit "- backend: $value" ;; *) emit "- backend: unknown" ;; esac
          ;;
        effort)
          case "$value" in low|medium|high|xhigh|max) emit "- effort: $value" ;; *) emit "- effort: unknown" ;; esac
          ;;
        terminal)
          case "$value" in 0|1|true|false) emit "- terminal: $value" ;; *) emit "- terminal: unknown" ;; esac
          ;;
        model|spawn_gen|busy_gen)
          emit "- $key: value_${HASH_ALGORITHM}=$(text_digest "$value")"
          ;;
      esac
    fi
  done
  if WORKTREE=$(meta_value worktree "$META_SAMPLE" 2>/dev/null); then
    emit "- worktree: recorded path_${HASH_ALGORITHM}=$(text_digest "$WORKTREE") present=$([ -d "$WORKTREE" ] && printf true || printf false)"
  else
    emit "- [lead] worktree identity missing or ambiguous"
  fi
  if value=$(meta_value project "$META_SAMPLE" 2>/dev/null); then
    emit "- project: recorded path_${HASH_ALGORITHM}=$(text_digest "$value") present=$([ -d "$value" ] && printf true || printf false)"
  else
    emit "- [lead] project identity missing or ambiguous"
  fi
else
  emit "- [lead] task metadata missing, unreadable, or symbolic-link backed"
fi

# Run the canonical current-state reader against bounded scratch copies.
# Any pull-source cache or mistaken helper write therefore lands in scratch.
for path in "$STATE/$ID".*; do
  [ -f "$path" ] && [ ! -L "$path" ] || continue
  case "$path" in
    "$STATUS") bounded_tail "$path" > "$SHADOW_STATE/${path##*/}" ;;
    *) LC_ALL=C head -c "$SOURCE_BYTES" "$path" > "$SHADOW_STATE/${path##*/}" 2>/dev/null || : ;;
  esac
done

emit ""
emit "## Current state"
CREW_STATE_BIN=${FM_FORENSICS_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}
CURRENT_OUT="$TMP_ROOT/current-state"
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"
if fm_run_timed "$COMMAND_TIMEOUT" env \
    FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$SHADOW_STATE" \
    FM_DATA_OVERRIDE="$DATA" FM_CREW_STATE_NM_TIMEOUT="$COMMAND_TIMEOUT" \
    "$CREW_STATE_BIN" "$ID" > "$CURRENT_OUT" 2>&1; then
  current=$(LC_ALL=C head -c "$SOURCE_BYTES" "$CURRENT_OUT")
  parsed=$(printf '%s\n' "$current" | LC_ALL=C awk -F ' · ' '
    /^state: / {
      sub(/^state: /, "", $1)
      sub(/^source: /, "", $2)
      print $1 "\t" $2
      exit
    }
  ')
  if [ -n "$parsed" ]; then
    current_state=${parsed%%$'\t'*}
    current_source=${parsed#*$'\t'}
    case "$current_state" in working|parked|done|blocked|paused|failed|unknown) : ;; *) current_state=unknown ;; esac
    case "$current_source" in run-step|pane|status-log|remote-endpoint|none) : ;; *) current_source=unknown ;; esac
    emit "- state: $current_state"
    emit "- source: $current_source"
  else
    emit "- [lead] current-state output was unparseable; output_${HASH_ALGORITHM}=$(text_digest "$current")"
  fi
else
  rc=$?
  emit "- [lead] current-state read failed or timed out: exit=$rc output_${HASH_ALGORITHM}=$(sample_digest "$CURRENT_OUT")"
fi

emit ""
emit "## Endpoint identity"
ENDPOINT_OUT="$TMP_ROOT/endpoint"
if [ -f "$META" ] && [ ! -L "$META" ]; then
  # shellcheck disable=SC2016
  if fm_run_timed "$COMMAND_TIMEOUT" env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      FM_ROOT_OVERRIDE="$FM_ROOT" bash -c \
      '. "$1"; fm_backend_validate_task_endpoint "$2" "$3"' \
      _ "$SCRIPT_DIR/fm-backend.sh" "$SHADOW_STATE/$ID.meta" "$ID" > "$ENDPOINT_OUT" 2>&1; then
    emit "- metadata binding: valid"
  else
    rc=$?
    if grep -Fq 'belongs to task' "$ENDPOINT_OUT" 2>/dev/null; then
      emit "- [lead] stale endpoint identity: recorded binding belongs to another task"
    else
      emit "- [lead] endpoint identity invalid or incomplete: exit=$rc diagnostic_${HASH_ALGORITHM}=$(sample_digest "$ENDPOINT_OUT")"
    fi
  fi
else
  emit "- unavailable: task metadata is absent"
fi

emit ""
emit "## Event history"
STATUS_HASHES="$TMP_ROOT/status-hashes"
: > "$STATUS_HASHES"
if [ -f "$STATUS" ] && [ ! -L "$STATUS" ]; then
  STATUS_SAMPLE="$TMP_ROOT/status-sample"
  bounded_tail "$STATUS" > "$STATUS_SAMPLE"
  emit "- status: present bytes=$(file_bytes "$STATUS") sample=${SOURCE_LINES}_line_tail"
  index=0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    index=$((index + 1))
    digest=$(text_digest "$line")
    printf '%s\n' "$digest" >> "$STATUS_HASHES"
    verb=${line%%:*}
    verb=${verb%% *}
    key=$(printf '%s\n' "$line" | LC_ALL=C sed -n 's/.*\[key=\([^]]*\)\].*/\1/p' | head -1)
    extra=
    [ -z "$key" ] || extra=" key_${HASH_ALGORITHM}=$(text_digest "$key")"
    case "$verb" in working|needs-decision|blocked|paused|done|failed|resolved|note) : ;; *) verb=other ;; esac
    emit "- event sample_index=$index verb=$verb${extra} record_${HASH_ALGORITHM}=$digest"
  done < "$STATUS_SAMPLE"
  [ "$index" -gt 0 ] || emit "- status: empty"
  append_duplicate_lead "status evidence" "$STATUS_HASHES"
else
  emit "- [lead] status history missing, unreadable, or symbolic-link backed"
fi

emit ""
emit "## Backlog"
if [ -f "$BACKLOG" ] && [ ! -L "$BACKLOG" ]; then
  BACKLOG_MATCHES="$TMP_ROOT/backlog-matches"
  BACKLOG_COUNT="$TMP_ROOT/backlog-count"
  LC_ALL=C head -c "$((SOURCE_BYTES * 8))" "$BACKLOG" 2>/dev/null | LC_ALL=C awk \
    -v id="$ID" -v cap="$SOURCE_LINES" -v count_file="$BACKLOG_COUNT" '
      /^## In flight/ { section="in-flight" }
      /^## Queued/ { section="queued" }
      /^## Done/ { section="done" }
      index($0, id) {
        count++
        if (shown < cap) {
          mark="other"
          if ($0 ~ /^- \[ \]/) mark="open"
          else if ($0 ~ /^- \[x\]/) mark="done"
          print NR "\t" section "\t" mark "\t" substr($0, 1, 2048)
          shown++
        }
      }
      END { print count + 0 > count_file }
    ' > "$BACKLOG_MATCHES"
  backlog_count=$(cat "$BACKLOG_COUNT" 2>/dev/null || printf 0)
  emit "- backlog: present bytes=$(file_bytes "$BACKLOG") task_matches_in_bounded_scan=$backlog_count"
  BACKLOG_HASHES="$TMP_ROOT/backlog-hashes"
  : > "$BACKLOG_HASHES"
  while IFS=$'\t' read -r line_no section mark body; do
    [ -n "$line_no" ] || continue
    digest=$(text_digest "$body")
    printf '%s\n' "$digest" >> "$BACKLOG_HASHES"
    emit "- row sample_line=$line_no section=$(safe_atom "${section:-unknown}") marker=$(safe_atom "$mark") record_${HASH_ALGORITHM}=$digest"
  done < "$BACKLOG_MATCHES"
  [ "$backlog_count" -gt 0 ] || emit "- [lead] task has no backlog row in the bounded scan"
  [ "$backlog_count" -le 1 ] || emit "- [lead] repeated backlog identity: matching_rows=$backlog_count"
else
  emit "- [lead] backlog missing, unreadable, or symbolic-link backed"
fi

emit ""
emit "## Instruction acknowledgements"
INBOX="$STATE/$ID.inbox"
INBOX_LIST="$TMP_ROOT/inbox-list"
INBOX_HASHES="$TMP_ROOT/inbox-hashes"
: > "$INBOX_HASHES"
if [ -d "$INBOX" ] && [ ! -L "$INBOX" ]; then
  find "$INBOX" -maxdepth 2 -type f -name '*.msg' -print 2>/dev/null \
    | LC_ALL=C sort | tail -n "$SOURCE_LINES" > "$INBOX_LIST"
  inbox_count=0
  while IFS= read -r record; do
    [ -f "$record" ] && [ ! -L "$record" ] || continue
    inbox_count=$((inbox_count + 1))
    case "$record" in "$INBOX/handled/"*) disposition=handled ;; *) disposition=pending ;; esac
    base=${record##*/}
    header=$(LC_ALL=C head -n 8 "$record" 2>/dev/null)
    at=$(printf '%s\n' "$header" | sed -n 's/^at=//p' | head -1)
    delivery=$(printf '%s\n' "$header" | sed -n 's/^delivery=//p' | head -1)
    body_sample="$TMP_ROOT/inbox-body-$inbox_count"
    LC_ALL=C awk 'body { print } /^--$/ { body=1; next }' "$record" 2>/dev/null \
      | LC_ALL=C head -c "$SOURCE_BYTES" > "$body_sample"
    digest=$(sample_digest "$body_sample")
    printf '%s\n' "$digest" >> "$INBOX_HASHES"
    case "$base" in [0-9][0-9][0-9].msg) : ;; *) base="record_${HASH_ALGORITHM}=$(text_digest "$base")" ;; esac
    case "$at" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) : ;; *) at=unknown ;; esac
    case "$delivery" in '' ) delivery=ordinary ;; fire-and-forget) : ;; *) delivery=unknown ;; esac
    emit "- record=$base disposition=$disposition at=$at delivery=$delivery body_${HASH_ALGORITHM}=$digest"
  done < "$INBOX_LIST"
  emit "- sampled_records=$inbox_count"
  append_duplicate_lead "instruction body" "$INBOX_HASHES"
else
  emit "- availability: no instruction inbox"
fi

emit ""
emit "## Process-event results"
PROCEVENT_DIR="$STATE/procevent-inbox"
PROCEVENT_LIST="$TMP_ROOT/procevent-list"
PROCEVENT_HASHES="$TMP_ROOT/procevent-hashes"
: > "$PROCEVENT_HASHES"
if [ -d "$PROCEVENT_DIR" ] && [ ! -L "$PROCEVENT_DIR" ]; then
  find "$PROCEVENT_DIR" -maxdepth 1 -type f -name '*.result' -print 2>/dev/null \
    | LC_ALL=C sort | tail -n "$SCAN_LINES" > "$PROCEVENT_LIST"
  scanned=0
  relevant=0
  while IFS= read -r result; do
    [ -f "$result" ] && [ ! -L "$result" ] || continue
    scanned=$((scanned + 1))
    sample="$TMP_ROOT/procevent-sample-$scanned"
    LC_ALL=C head -c "$SOURCE_BYTES" "$result" > "$sample" 2>/dev/null || :
    base=${result##*/}
    case "$base" in *"$ID"*) related=1 ;; *) related=0 ;; esac
    [ "$related" -eq 1 ] || ! grep -Fq -- "$ID" "$sample" 2>/dev/null || related=1
    [ "$related" -eq 1 ] || continue
    [ "$relevant" -lt "$SOURCE_LINES" ] || continue
    relevant=$((relevant + 1))
    stem=${result%.result}
    adapter=$(head -n 1 "$stem.adapter" 2>/dev/null || true)
    case "$adapter" in
      lavish|quota|remote-reply) : ;;
      '') adapter=unknown ;;
      *) adapter="value_${HASH_ALGORITHM}=$(text_digest "$adapter")" ;;
    esac
    digest=$(sample_digest "$sample")
    printf '%s\n' "$digest" >> "$PROCEVENT_HASHES"
    emit "- result_index=$relevant source_id_${HASH_ALGORITHM}=$(text_digest "$base") adapter=$(safe_atom "${adapter:-unknown}") handled=$([ -f "$stem.handled" ] && printf true || printf false) bytes=$(file_bytes "$result") sample_${HASH_ALGORITHM}=$digest"
  done < "$PROCEVENT_LIST"
  emit "- scanned_recent_results=$scanned related_results=$relevant"
  append_duplicate_lead "process-event result" "$PROCEVENT_HASHES"
else
  emit "- availability: no process-event result directory"
fi

emit ""
emit "## Supervision branch outcomes"
BRANCH_STORE="$STATE/branch-outcomes.jsonl"
BRANCH_HASHES="$TMP_ROOT/branch-hashes"
: > "$BRANCH_HASHES"
if [ -f "$BRANCH_STORE" ] && [ ! -L "$BRANCH_STORE" ]; then
  BRANCH_SAMPLE="$TMP_ROOT/branch-sample"
  LC_ALL=C tail -n "$SCAN_LINES" "$BRANCH_STORE" 2>/dev/null \
    | LC_ALL=C head -c "$((SOURCE_BYTES * 4))" > "$BRANCH_SAMPLE"
  matched=0
  while IFS= read -r row || [ -n "$row" ]; do
    [ "$matched" -lt "$SOURCE_LINES" ] || continue
    if command -v jq >/dev/null 2>&1; then
      row_task=$(printf '%s\n' "$row" | jq -r 'if type == "object" then (.task // "") else "" end' 2>/dev/null || true)
      [ "$row_task" = "$ID" ] || continue
      seq=$(printf '%s\n' "$row" | jq -r '.seq // "unknown"' 2>/dev/null || printf unknown)
      epoch=$(printf '%s\n' "$row" | jq -r '.epoch // "unknown"' 2>/dev/null || printf unknown)
      verdict=$(printf '%s\n' "$row" | jq -r '.verdict // "unknown"' 2>/dev/null || printf unknown)
      silent=$(printf '%s\n' "$row" | jq -r '.silent // false' 2>/dev/null || printf false)
      payload=$(printf '%s\n' "$row" | jq -c '{task,wake,verdict,summary,silent}' 2>/dev/null || printf '%s' "$row")
    else
      printf '%s\n' "$row" | grep -Fq -- "\"task\":\"$ID\"" || continue
      seq=unknown epoch=unknown verdict=unknown silent=unknown payload=$row
    fi
    case "$seq" in ''|*[!0-9]*) seq=unknown ;; esac
    case "$epoch" in ''|*[!0-9]*) epoch=unknown ;; esac
    case "$verdict" in routine|captain) : ;; *) verdict=unknown ;; esac
    case "$silent" in true|false) : ;; *) silent=unknown ;; esac
    matched=$((matched + 1))
    digest=$(text_digest "$payload")
    printf '%s\n' "$digest" >> "$BRANCH_HASHES"
    emit "- outcome_index=$matched seq=$(safe_atom "$seq") epoch=$(safe_atom "$epoch") verdict=$(safe_atom "$verdict") silent=$(safe_atom "$silent") payload_${HASH_ALGORITHM}=$digest"
  done < "$BRANCH_SAMPLE"
  emit "- matching_outcomes=$matched scanned_tail_lines=$SCAN_LINES"
  append_duplicate_lead "supervision outcome payload" "$BRANCH_HASHES"
else
  emit "- availability: no supervision branch outcome store"
fi

emit ""
emit "## Isolated-copy Git facts"
if [ -n "$WORKTREE" ] && [ -d "$WORKTREE" ]; then
  GIT_TOP="$TMP_ROOT/git-top"
  if fm_run_timed "$COMMAND_TIMEOUT" env GIT_OPTIONAL_LOCKS=0 git -C "$WORKTREE" rev-parse --show-toplevel > "$GIT_TOP" 2>/dev/null; then
    top=$(head -n 1 "$GIT_TOP")
    emit "- repository: present top_path_${HASH_ALGORITHM}=$(text_digest "$top")"
    if head_oid=$(fm_run_timed "$COMMAND_TIMEOUT" env GIT_OPTIONAL_LOCKS=0 git -C "$WORKTREE" rev-parse --verify HEAD 2>/dev/null); then
      emit "- head: $(safe_atom "$head_oid")"
    else
      emit "- [lead] Git HEAD is unavailable"
    fi
    if branch=$(fm_run_timed "$COMMAND_TIMEOUT" env GIT_OPTIONAL_LOCKS=0 git -C "$WORKTREE" symbolic-ref --short -q HEAD 2>/dev/null); then
      emit "- branch_${HASH_ALGORITHM}: $(text_digest "$branch")"
    else
      emit "- branch: detached-or-unavailable"
    fi
    GIT_STATUS="$TMP_ROOT/git-status"
    GIT_COUNTS="$TMP_ROOT/git-counts"
    if fm_run_timed "$COMMAND_TIMEOUT" env GIT_OPTIONAL_LOCKS=0 git -C "$WORKTREE" \
        status --porcelain=v1 --untracked-files=normal > "$GIT_STATUS" 2>/dev/null; then
      LC_ALL=C awk '
        /^\?\?/ { untracked++; next }
        { tracked++ }
        END { print "tracked=" tracked + 0 " untracked=" untracked + 0 }
      ' "$GIT_STATUS" > "$GIT_COUNTS"
      emit "- working_copy: $(cat "$GIT_COUNTS")"
    else
      emit "- [lead] Git working-copy status failed or timed out"
    fi
    GIT_LOG="$TMP_ROOT/git-log"
    if fm_run_timed "$COMMAND_TIMEOUT" env GIT_OPTIONAL_LOCKS=0 git -C "$WORKTREE" \
        log -n "$SOURCE_LINES" --format='%H %ct' > "$GIT_LOG" 2>/dev/null; then
      while IFS= read -r commit_row; do
        [ -n "$commit_row" ] && emit "- commit: $(safe_atom "$commit_row")"
      done < "$GIT_LOG"
    fi
  else
    emit "- [lead] recorded isolated copy is not a readable Git repository"
  fi
else
  emit "- [lead] recorded isolated copy is missing"
fi

emit ""
emit "## Ordinary direct-report session errors"
SESSION_PATH=
if [ "$KIND" = secondmate ]; then
  emit "- excluded: second-mate conversations are outside this collector's authority"
elif [ "$KIND" != ship ] && [ "$KIND" != scout ]; then
  emit "- excluded: ordinary direct-report identity is not proven by task metadata"
else
  SESSION_OUT="$TMP_ROOT/session-path"
  case "$HARNESS" in
    muse*) resolver=fm_busy_muse_session_log ;;
    cursor*) resolver=fm_busy_cursor_transcript ;;
    *) resolver= ;;
  esac
  # A valid cached Muse binding may point at an older day that the live-state
  # resolver deliberately no longer scans.
  # shellcheck disable=SC2016
  MUSE_CACHE_COMMAND='
    . "$1"
    root=$(fm_busy_muse_binding_field "$2" "$3" sessions_root) || exit 1
    binding=$(fm_busy_muse_binding_field "$2" "$3" binding_id) || exit 1
    cache_binding=$(fm_busy_muse_cache_field "$2" "$3" binding_id) || exit 1
    log=$(fm_busy_muse_cache_field "$2" "$3" session_log) || exit 1
    [ "$binding" = "$cache_binding" ] || exit 1
    fm_busy_muse_main_log_path_valid "$root" "$log" || exit 1
    printf "%s\n" "$log"
  '
  # shellcheck disable=SC2016
  SESSION_RESOLVE_COMMAND='. "$1"; "$2" "$3" "$4"'
  if [ "$resolver" = fm_busy_muse_session_log ] && fm_run_timed "$COMMAND_TIMEOUT" \
      env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$SHADOW_STATE" bash -c \
      "$MUSE_CACHE_COMMAND" _ "$SCRIPT_DIR/fm-busy-lib.sh" "$SHADOW_STATE" "$ID" \
      > "$SESSION_OUT" 2>/dev/null; then
    SESSION_PATH=$(head -n 1 "$SESSION_OUT")
  elif [ -n "$resolver" ] && fm_run_timed "$COMMAND_TIMEOUT" env FM_HOME="$FM_HOME" \
      FM_STATE_OVERRIDE="$SHADOW_STATE" bash -c \
      "$SESSION_RESOLVE_COMMAND" \
      _ "$SCRIPT_DIR/fm-busy-lib.sh" "$resolver" "$SHADOW_STATE" "$ID" \
      > "$SESSION_OUT" 2>/dev/null; then
    SESSION_PATH=$(head -n 1 "$SESSION_OUT")
  fi
  if [ -n "$SESSION_PATH" ] && [ -f "$SESSION_PATH" ] && [ ! -L "$SESSION_PATH" ]; then
    SESSION_SAMPLE="$TMP_ROOT/session-sample"
    LC_ALL=C tail -n "$SCAN_LINES" "$SESSION_PATH" 2>/dev/null \
      | LC_ALL=C head -c "$((SOURCE_BYTES * 4))" > "$SESSION_SAMPLE"
    SESSION_HASHES="$TMP_ROOT/session-hashes"
    : > "$SESSION_HASHES"
    errors=0
    sample_line=0
    while IFS= read -r row || [ -n "$row" ]; do
      sample_line=$((sample_line + 1))
      printf '%s\n' "$row" | LC_ALL=C grep -Eq \
        '"(isError|is_error)"[[:space:]]*:[[:space:]]*true|"(type|status|kind)"[[:space:]]*:[[:space:]]*"error"' \
        || continue
      errors=$((errors + 1))
      [ "$errors" -le "$SOURCE_LINES" ] || continue
      digest=$(text_digest "$row")
      printf '%s\n' "$digest" >> "$SESSION_HASHES"
      if command -v jq >/dev/null 2>&1; then
        record_type=$(printf '%s\n' "$row" | jq -r '.type // .role // .payload.kind // "unknown"' 2>/dev/null || printf unknown)
        tool_name=$(printf '%s\n' "$row" | jq -r '.name // .toolName // .tool_name // "unknown"' 2>/dev/null || printf unknown)
      else
        record_type=unknown tool_name=unknown
      fi
      case "$record_type" in toolResult|tool_result|error|assistant|user|tool) : ;; *) record_type=unknown ;; esac
      emit "- error sample_line=$sample_line type=$record_type tool_${HASH_ALGORITHM}=$(text_digest "$tool_name") record_${HASH_ALGORITHM}=$digest"
    done < "$SESSION_SAMPLE"
    emit "- session: bound path_${HASH_ALGORITHM}=$(text_digest "$SESSION_PATH") bytes=$(file_bytes "$SESSION_PATH") errors_in_bounded_tail=$errors"
    append_duplicate_lead "session error record" "$SESSION_HASHES"
  elif [ -n "$resolver" ]; then
    emit "- [lead] task-bound session log could not be resolved without guessing"
  else
    emit "- availability: no durable task-bound session-error source for harness=$HARNESS_FAMILY"
  fi
fi

emit ""
emit "## Reading rule"
emit "- Every [lead] above requires verification against its owning source before a cause is stated."

packet_bytes=$(file_bytes "$PACKET")
case "$packet_bytes" in ''|*[!0-9]*) packet_bytes=$((MAX_BYTES + 1)) ;; esac
if [ "$packet_bytes" -le "$MAX_BYTES" ]; then
  cat "$PACKET"
else
  marker="[packet truncated at ${MAX_BYTES} bytes; lower-level sources remain unchanged]"
  marker_bytes=$(printf '\n%s\n' "$marker" | wc -c | tr -d ' ')
  keep=$((MAX_BYTES - marker_bytes))
  [ "$keep" -gt 0 ] || keep=0
  LC_ALL=C head -c "$keep" "$PACKET"
  printf '\n%s\n' "$marker"
fi
