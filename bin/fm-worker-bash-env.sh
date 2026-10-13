# shellcheck shell=bash
# fm-worker-bash-env.sh - BASH_ENV file that gives a firstmate-launched ship or
# scout worker's bash tool `set -o pipefail`. Sourced by bash, never executed.
#
# bin/fm-spawn.sh exports BASH_ENV=<this file> in front of the worker launch
# (header section "Worker shell pipefail"), so `cmd | tail` reports a failure of
# `cmd` instead of the exit code of `tail`.
#
# Scope: pipefail is set only for a `bash -c` command string, which is how the
# Kiro and Pi bash tools run every worker command, and only for the outermost
# one. Bash scripts, and any `bash -c` those commands start in turn, keep plain
# bash behavior because FM_WORKER_PIPEFAIL_APPLIED travels to child processes.
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
fi
