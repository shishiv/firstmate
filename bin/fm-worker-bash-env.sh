# shellcheck shell=bash
# fm-worker-bash-env.sh - BASH_ENV file that gives a firstmate-launched ship or
# scout worker's bash tool `set -o pipefail` and puts each command first in line
# to be killed when the worker's memory scope fills. Sourced by bash, never
# executed.
#
# bin/fm-spawn.sh exports BASH_ENV=<this file> in front of the worker launch
# (header section "Worker shell pipefail"), so `cmd | tail` reports a failure of
# `cmd` instead of the exit code of `tail`.
#
# Scope: both settings apply only to a `bash -c` command string, which is how
# the Kiro and Pi bash tools run every worker command, and only to the
# outermost one. Bash scripts, and any `bash -c` those commands start in turn,
# keep plain bash behavior because FM_WORKER_PIPEFAIL_APPLIED travels to child
# processes.
#
# Kill order: when the command runs inside a worker memory scope, which is a
# /proc/self/cgroup path through firstmate.slice/fm-worker-*.scope as
# bin/fm-worker-memory-scope.sh creates, the command raises its own
# oom_score_adj to 1000, and its children inherit that. The agent that started
# the command runs lower, so the kernel kills the command before the agent;
# that helper's header owns the order and the numbers. Outside a worker scope,
# and where /proc/self/oom_score_adj is not writable, nothing changes.
#
# A captain-set BASH_ENV is not replaced: bin/fm-spawn.sh keeps it in
# FM_PRIOR_BASH_ENV and this file sources it first.

if [ -n "${FM_PRIOR_BASH_ENV:-}" ] &&
  [ "$FM_PRIOR_BASH_ENV" != "${BASH_SOURCE[0]}" ] &&
  [ -r "$FM_PRIOR_BASH_ENV" ]; then
  # shellcheck disable=SC1090  # the captain's own file, named at run time
  . "$FM_PRIOR_BASH_ENV"
fi

if [ -n "${BASH_EXECUTION_STRING+x}" ] && [ -z "${FM_WORKER_PIPEFAIL_APPLIED:-}" ]; then
  FM_WORKER_PIPEFAIL_APPLIED=1
  export FM_WORKER_PIPEFAIL_APPLIED
  set -o pipefail
  if [ -r /proc/self/cgroup ] && [ -w /proc/self/oom_score_adj ]; then
    while IFS= read -r _fm_cgroup_line; do
      case $_fm_cgroup_line in
        */firstmate.slice/fm-worker-*.scope*)
          { printf 1000 > /proc/self/oom_score_adj; } 2>/dev/null
          break
          ;;
      esac
    done < /proc/self/cgroup
    unset _fm_cgroup_line
  fi
fi
