#!/usr/bin/env bash
# fm-kiro-account-pool.sh - keeps this home's Kiro ships and scouts on an
# account of config/kiro-account-pool that still has credit.
#
# Usage: fm-kiro-account-pool.sh check [--dry-run]
#        fm-kiro-account-pool.sh mark <root>
#        fm-kiro-account-pool.sh status
#
#   check    Finds every ship or scout of this home that runs kiro-cli on a
#            pool account and whose own Kiro session ended on the monthly
#            usage limit: its latest UsageLimitReachedError, or error message
#            naming the "monthly usage limit", is newer than its latest
#            assistant reply. It marks each such account exhausted for the
#            current UTC month and relaunches each such task with
#            `bin/fm-control.sh <id> relaunch --note`, which moves it to the
#            next account the pool offers (bin/fm-worker-account-lib.sh owns
#            that choice). Workers that have not hit the limit are left alone,
#            so an idle or finished worker keeps its conversation until its
#            next turn fails. --dry-run reports what it would mark and
#            relaunch, and changes nothing.
#   mark     Marks one pool root exhausted for the current UTC month by hand.
#   status   Prints each pool root with `exhausted` or `open` for this month
#            and the ship and scout ids recorded on it, without asking Kiro.
#
# The ledger is state/kiro-accounts/exhausted-<YYYY-MM>, one root per line; a
# new month starts with an empty ledger. Delete a line to put an account back
# in use this month.
#
# Exit status: 0 when nothing hit the limit or every hit task was relaunched,
# 1 for a usage or configuration error or a relaunch that refused or failed,
# 2 when a task hit the limit and the pool has no account left (the tasks stay
# as they are; the next run tries again).
#
# Scheduling: run `check` every few minutes from the host's scheduler with
# FM_HOME set, and with a PATH that holds kiro-cli, jq, and the runtime
# backend's own tools (hc, herdr, or tmux). docs/configuration.md "Kiro
# account pool" owns the systemd user timer recipe. A secondmate home with its
# own pool needs its own timer.
#
# Environment: FM_HOME (required), FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

# shellcheck source=bin/fm-worker-account-lib.sh
. "$SCRIPT_DIR/fm-worker-account-lib.sh"
# shellcheck source=bin/fm-meta-lib.sh
. "$SCRIPT_DIR/fm-meta-lib.sh"

VERB=${1:-}
case "$VERB" in
-h | --help)
  usage
  exit 0
  ;;
check | mark | status) shift ;;
*)
  usage >&2
  exit 1
  ;;
esac

if [ -z "${FM_HOME:-}" ] || [ ! -d "$FM_HOME" ]; then
  echo "error: FM_HOME must name this firstmate home; fm-kiro-account-pool refuses to guess one" >&2
  exit 1
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
POOL="$CONFIG/kiro-account-pool"
[ -e "$POOL" ] || {
  echo "error: this home has no config/kiro-account-pool: $POOL" >&2
  exit 1
}
ROOTS=$(fm_worker_account_kiro_pool_roots "$POOL") || exit 1
LEDGER=$(fm_worker_account_kiro_ledger "$STATE")
MONTH=${LEDGER##*/exhausted-}

in_pool() { printf '%s\n' "$ROOTS" | grep -qxF -- "$1"; }
exhausted() { [ -f "$LEDGER" ] && grep -qxF -- "$1" "$LEDGER"; }

mark_exhausted() {  # <root>
  exhausted "$1" && return 0
  mkdir -p "${LEDGER%/*}" && printf '%s\n' "$1" >> "$LEDGER"
}

# pool_tasks: "<id><TAB><root>" for each ship or scout of this home recorded
# on kiro-cli and on a pool root.
pool_tasks() {
  local meta id root kind
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    [ "$(fm_meta_get "$meta" harness)" = kiro-cli ] || continue
    kind=$(fm_meta_get "$meta" kind)
    [ "$kind" = ship ] || [ "$kind" = scout ] || continue
    root=$(fm_meta_get "$meta" account)
    [ -n "$root" ] || continue
    in_pool "$root" || continue
    id=${meta##*/}
    printf '%s\t%s\n' "${id%.meta}" "$root"
  done
}

# limit_hit <id>: the task's own Kiro sessions, newest event of the two kinds
# that matter, is a usage-limit error. Reads only each history's last 512 KiB.
limit_hit() {
  local f last
  last=$(
    for f in "$STATE/$1.kiro-home"/sessions/*/sess_*/messages.jsonl; do
      [ -f "$f" ] || continue
      tail -c 524288 "$f" | jq -Rr '
        fromjson? | objects | select((.timestamp | type) == "string") |
        .timestamp as $t | (.payload // {} | objects) as $p |
        if $p.type == "session_metadata" and $p.key == "displayError" and
          (($p.value // {} | objects) as $v |
            ($v.errorType // "") == "UsageLimitReachedError" or
            (($v.message // "") | tostring | ascii_downcase | contains("monthly usage limit")))
        then "\($t)\terror"
        elif $p.type == "assistant" then "\($t)\treply"
        else empty end' 2>/dev/null
    done | LC_ALL=C sort | tail -1
  )
  [ "${last##*$'\t'}" = error ]
}

do_mark() {
  local root=${1:-}
  [ $# -eq 1 ] && [ -n "$root" ] || {
    echo "usage: fm-kiro-account-pool.sh mark <root>" >&2
    exit 1
  }
  in_pool "$root" || {
    echo "error: $root is not listed in $POOL" >&2
    exit 1
  }
  mark_exhausted "$root" || exit 1
  echo "marked $root exhausted for $MONTH"
}

do_status() {
  local root tasks line ids r
  [ $# -eq 0 ] || {
    echo "usage: fm-kiro-account-pool.sh status" >&2
    exit 1
  }
  tasks=$(pool_tasks)
  echo "month=$MONTH ledger=$LEDGER"
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    ids=
    while IFS=$'\t' read -r line r; do
      [ "$r" = "$root" ] && ids="$ids${ids:+ }$line"
    done <<< "$tasks"
    if exhausted "$root"; then
      printf '%s\texhausted\t%s\n' "$root" "$ids"
    else
      printf '%s\topen\t%s\n' "$root" "$ids"
    fi
  done <<< "$ROOTS"
}

do_check() {
  local dry=0 id root kiro_bin failed=0 note
  local -a hit=()
  case "${1:-}" in
  '') ;;
  --dry-run) dry=1 ;;
  *)
    echo "usage: fm-kiro-account-pool.sh check [--dry-run]" >&2
    exit 1
    ;;
  esac
  while IFS=$'\t' read -r id root; do
    [ -n "$id" ] || continue
    limit_hit "$id" || continue
    hit+=("$id")
    if [ "$dry" = 1 ]; then
      echo "would mark $root exhausted for $MONTH and relaunch $id"
    else
      mark_exhausted "$root" || {
        echo "error: cannot record $root in $LEDGER" >&2
        exit 1
      }
      echo "$id hit the monthly usage limit on $root; marked it exhausted for $MONTH"
    fi
  done <<< "$(pool_tasks)"
  [ "${#hit[@]}" -gt 0 ] || return 0
  [ "$dry" = 0 ] || return 0
  kiro_bin=$(command -v kiro-cli) || {
    echo "error: kiro-cli is not on PATH, so no next account can be checked; ${hit[*]} wait on the usage limit" >&2
    exit 1
  }
  if ! fm_worker_account_kiro_pool_pick "$CONFIG" "$STATE" "$kiro_bin" >/dev/null; then
    echo "error: no account left in $POOL for $MONTH; ${hit[*]} wait on the usage limit" >&2
    exit 2
  fi
  for id in "${hit[@]}"; do
    note="The Kiro account this task ran on reached its monthly usage limit, so Firstmate relaunched it on the next account in config/kiro-account-pool. The last turn may have ended with a usage-limit error; continue from the local copy."
    if FM_HOME=$FM_HOME "$SCRIPT_DIR/fm-control.sh" "$id" relaunch --note "$note"; then
      echo "relaunched $id on account=$(fm_meta_get "$STATE/$id.meta" account)"
    else
      echo "error: relaunch of $id refused or failed; the next check tries again" >&2
      failed=1
    fi
  done
  return "$failed"
}

case "$VERB" in
check) do_check "$@" ;;
mark) do_mark "$@" ;;
status) do_status "$@" ;;
esac
