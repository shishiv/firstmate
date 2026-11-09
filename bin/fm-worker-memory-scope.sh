#!/usr/bin/env bash
# fm-worker-memory-scope.sh - run one worker launch inside its own systemd user
# scope with a MemoryHigh soft cap, so one runaway worker is throttled by the
# kernel (memory reclaim, not a kill) before it pushes the desktop into swap.
# The kernel throttles; a Node process in the scope can still die, so the helper
# also gives Node its normal heap size (see "Node heap size" below).
#
# Usage: fm-worker-memory-scope.sh <memory-high> <unit> -- <command> [args...]
#   <memory-high>  a positive whole number with an optional K, M, G or T suffix
#                  (systemd MemoryHigh syntax), for example 3G.
#   <unit>         the scope unit name, [A-Za-z0-9._-]+ ending in .scope.
#                  bin/fm-spawn.sh passes fm-worker-<id>-<spawn_gen>.scope.
# Bad usage prints this usage to stderr and exits 2 without running <command>.
#
# bin/fm-spawn.sh (header section "Worker memory scope") owns when the launch is
# wrapped; config/worker-memory-high selects the value or `off`. This helper
# owns the decision at launch time, in the pane, on the host where the worker
# runs:
#   1. No systemd-run on PATH (macOS, hosts without systemd): exec <command>
#      silently, uncapped.
#   2. A probe `systemd-run --user --scope ... -- true` succeeds: exec the
#      command through systemd-run with the same flags and --unit=<unit>.
#   3. Else the same probe with --machine=<user>@.host succeeds: exec with that
#      flag. A pane whose XDG_RUNTIME_DIR is private (a lab home's hc core)
#      cannot reach the user manager over the local transport, but can over the
#      machine transport, which still keeps the caller's environment and PID.
#   4. Else print one note to stderr and exec <command> uncapped.
# The probe exists because `systemd-run ... -- cmd || cmd` would run the worker
# twice when the worker itself exits non-zero.
#
# Node heap size: Node reads the cgroup's memory.high (libuv
# uv_get_constrained_memory) and sizes its heap limit from it, so a 3G scope
# gave Node a 1632 MB heap instead of the 4192 MB it gets outside a scope, and
# typechecks died with "JavaScript heap out of memory" instead of slowing down.
# In branches 2 and 3, when NODE_OPTIONS holds neither --max-old-space-size nor
# --max-old-space-size-percentage, the helper measures the heap limit Node has
# in this pane, outside the scope, and appends --max-old-space-size=<that MB> to
# NODE_OPTIONS. That is the megabyte flag, which every Node version accepts.
# Node then ends up within about 100 MB of its unscoped limit (the flag sets
# old space, and the limit adds the young generation on top). A NODE_OPTIONS
# that already sets a size is left alone, and so is a pane with no node.
#
# Scopes go in firstmate.slice, directly under the user manager and outside
# app.slice: systemd-oomd watches app.slice for memory pressure and kills inside
# it, and a worker held at MemoryHigh creates exactly that pressure, so app.slice
# would turn "throttled" into "killed".
#
# Exec in place: systemd-run --scope registers the scope and then execs the
# command, and this helper execs too, so the worker keeps the pane shell's
# PID, PGID and session. Neither this helper nor systemd-run appears in the
# pane's process tree, which keeps the harness ancestry, busy and teardown
# checks reading the same tree as an uncapped launch.
set -u

usage() {
  echo 'usage: fm-worker-memory-scope.sh <memory-high> <unit> -- <command> [args...]' >&2
  echo '  <memory-high> is a positive whole number with an optional K, M, G or T suffix (for example 3G); <unit> matches [A-Za-z0-9._-]+.scope' >&2
  exit 2
}

[ "$#" -ge 4 ] || usage
[ "$3" = -- ] || usage
[[ "$1" =~ ^[1-9][0-9]*[KMGT]?$ ]] || usage
[[ "$2" =~ ^[A-Za-z0-9._-]+\.scope$ ]] || usage
memory_high=$1
unit=$2
shift 3

if ! command -v systemd-run >/dev/null 2>&1; then
  exec "$@"
fi

# node_heap_env: see "Node heap size" in the header. Runs before the exec, so
# the measurement sees the pane's own cgroup, not the capped scope.
node_heap_env() {
  local mb
  case "${NODE_OPTIONS:-}" in *--max-old-space-size*) return 0 ;; esac
  command -v node >/dev/null 2>&1 || return 0
  mb=$(env -u NODE_OPTIONS node -p 'Math.floor(require("v8").getHeapStatistics().heap_size_limit/2**20)' 2>/dev/null) || return 0
  [[ "$mb" =~ ^[1-9][0-9]*$ ]] || return 0
  export NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--max-old-space-size=$mb"
}

scope_args=(--user --scope --quiet --collect --slice=firstmate.slice -p "MemoryHigh=$memory_high")
if systemd-run "${scope_args[@]}" -- true >/dev/null 2>&1; then
  node_heap_env
  exec systemd-run "${scope_args[@]}" --unit="$unit" -- "$@"
fi
machine_arg="--machine=$(id -un)@.host"
if systemd-run "$machine_arg" "${scope_args[@]}" -- true >/dev/null 2>&1; then
  node_heap_env
  exec systemd-run "$machine_arg" "${scope_args[@]}" --unit="$unit" -- "$@"
fi
echo "fm-worker-memory-scope: no systemd user scope is reachable here; launching without the MemoryHigh=$memory_high cap" >&2
exec "$@"
