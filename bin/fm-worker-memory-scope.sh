#!/usr/bin/env bash
# fm-worker-memory-scope.sh - run one worker launch inside its own systemd user
# scope with a hard memory cap, no swap and one CPU, so one runaway process
# dies at the cap instead of pushing the desktop into swap. OOMPolicy=continue
# keeps the rest of the worker running when the kernel kills that process.
#
# Usage: fm-worker-memory-scope.sh <memory-max> <unit> -- <command> [args...]
#   <memory-max>   a positive whole number with an optional K, M, G or T suffix
#                  (systemd MemoryMax syntax), for example 2G.
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
# Scope properties: MemoryMax=<memory-max>, MemorySwapMax=0, CPUQuota=100% and
# OOMPolicy=continue. Node sizes its heap limit from the cap (about half of it),
# and the helper leaves NODE_OPTIONS as the caller set it, so Node's heap stays
# under the cap.
#
# Kill order. The kernel kills the process with the highest score: its resident
# size plus oom_score_adj/1000 of the limit being enforced (the cap inside the
# scope, the machine's memory and swap in a system-wide kill). A systemd scope
# takes no OOMScoreAdjust=, so the two scores come from two places:
#   1. The agent (the harness TUI and what it starts, such as Kiro's KAS agent)
#      runs under `choom -n 400 -- <command>` in branches 2 and 3, so it starts
#      at oom_score_adj 400.
#   2. bin/fm-worker-bash-env.sh raises every command the agent runs through its
#      shell tool (the outermost `bash -c` of Kiro and Pi) to 1000 while that
#      command runs inside a worker scope. Any process may raise its own score.
# In a full scope the command (tsc, a test run) dies before the agent, which dies
# first only when it is larger than the command by more than 60% of the cap (the
# 1000 - 400 gap). A dead command is an error the agent reads and recovers from.
# A dead agent leaves its terminal open with nothing behind it, and the worker
# stays stopped until relaunched. Equal scores would leave the choice to size
# alone, and the agent is often the largest process in the scope.
# A system-wide kill picks commands first, then workers, then the desktop:
# Chromium runs at 300, so the agent stays above it, which is why it is 400 and
# not lower.
# Without choom the agent keeps the score it inherited and the commands are
# still raised.
#
# Scopes go in firstmate.slice, directly under the user manager and outside
# app.slice: systemd-oomd watches app.slice for memory pressure and kills inside
# it, and a worker near its cap creates exactly that pressure.
#
# Exec in place: systemd-run --scope registers the scope and then execs the
# command, choom execs it too, and so does this helper, so the worker keeps the
# pane shell's PID, PGID and session. None of the three appears in the pane's
# process tree, which keeps the harness ancestry, busy and teardown checks
# reading the same tree as an uncapped launch.
set -u

usage() {
  echo 'usage: fm-worker-memory-scope.sh <memory-max> <unit> -- <command> [args...]' >&2
  echo '  <memory-max> is a positive whole number with an optional K, M, G or T suffix (for example 2G); <unit> matches [A-Za-z0-9._-]+.scope' >&2
  exit 2
}

[ "$#" -ge 4 ] || usage
[ "$3" = -- ] || usage
[[ "$1" =~ ^[1-9][0-9]*[KMGT]?$ ]] || usage
[[ "$2" =~ ^[A-Za-z0-9._-]+\.scope$ ]] || usage
memory_max=$1
unit=$2
shift 3

if ! command -v systemd-run >/dev/null 2>&1; then
  exec "$@"
fi

scope_args=(--user --scope --quiet --collect --slice=firstmate.slice
  -p "MemoryMax=$memory_max" -p MemorySwapMax=0 -p CPUQuota=100% -p OOMPolicy=continue)
if command -v choom >/dev/null 2>&1; then
  scoped_command=(choom -n 400 -- "$@")
else
  scoped_command=("$@")
fi
if systemd-run "${scope_args[@]}" -- true >/dev/null 2>&1; then
  exec systemd-run "${scope_args[@]}" --unit="$unit" -- "${scoped_command[@]}"
fi
machine_arg="--machine=$(id -un)@.host"
if systemd-run "$machine_arg" "${scope_args[@]}" -- true >/dev/null 2>&1; then
  exec systemd-run "$machine_arg" "${scope_args[@]}" --unit="$unit" -- "${scoped_command[@]}"
fi
echo "fm-worker-memory-scope: systemd-run could not start a user scope here; launching without the MemoryMax=$memory_max cap" >&2
exec "$@"
