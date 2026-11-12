#!/usr/bin/env bash
# fm-oomd-slice-lib.sh - the single owner of which cgroup placement counts as
# exposed to systemd-oomd. Sourced by bin/backends/herdr.sh and
# bin/backends/hc.sh for their read-only startup diagnostics; no side effects
# on source.
#
# A background process lands in the cgroup of whatever started it. Under
# app.slice a memory-pressure kill of that cgroup by systemd-oomd takes the
# process and everything it keeps alive with it: the Herdr server and its
# panes, or the herdr-core holder and every terminal's program.

# fm_oomd_app_slice_cgroup: print <pid>'s cgroup and return 0 when it sits
# under app.slice; return 1 for any other placement or an unreadable pid.
# <proc-root> is /proc, or a fixture of it.
fm_oomd_app_slice_cgroup() {  # <proc-root> <pid>
  local cgroup
  cgroup=$(sed -n 's/^0:://p' "$1/$2/cgroup" 2>/dev/null | head -1)
  case "$cgroup" in
    */app.slice/*) printf '%s' "$cgroup" ;;
    *) return 1 ;;
  esac
}
