#!/usr/bin/env bash
# shellcheck shell=bash
# fm-secondmate-parked-lib.sh - the parked state of a persistent secondmate.
# Source only; the caller defines STATE.
#
# A secondmate is parked when it was stopped on purpose: `bin/fm-control.sh
# <id> exit` writes the marker before it stops the agent, so no liveness tick
# can see the stopped agent first. A parked mate keeps its endpoint, home, and
# registry entry; only its agent is down, and nothing relaunches it until work
# arrives.
#
# The marker is `$STATE/.secondmate-parked-<id>` and holds the epoch it was
# written. Its three readers and writers:
#   - bin/fm-control.sh exit parks, and removes the marker again when the exit
#     fails, so an agent that may still be running is never reported parked.
#   - bin/fm-secondmate-liveness-lib.sh reads it: a dead or missing endpoint of
#     a parked mate is `parked` (never relaunched, by the session-start sweep or
#     the watcher tick alike), and a live agent clears it, so a mate someone
#     started by hand rejoins the liveness guarantee.
#   - bin/fm-send.sh unparks when it delivers work to the mate, then asks the
#     watcher for an immediate liveness tick, which relaunches it through the
#     same guarded path as any dead mate. A re-read nudge is not work and keeps
#     the mate parked (FM_SEND_KEEP_PARKED=1).
# bin/fm-teardown.sh removes the marker with the mate's other records.
#
# This is distinct from `.secondmate-relaunch-bound-<id>`, which means the mate
# keeps dying and needs attention.

fm_secondmate_parked_marker() {  # <id>
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  printf '%s/.secondmate-parked-%s\n' "$STATE" "$1"
}

fm_secondmate_is_parked() {  # <id>
  local marker
  marker=$(fm_secondmate_parked_marker "$1") || return 1
  [ -f "$marker" ] && [ ! -L "$marker" ]
}

fm_secondmate_park() {  # <id>
  local marker
  marker=$(fm_secondmate_parked_marker "$1") || return 1
  date +%s > "$marker"
}

fm_secondmate_unpark() {  # <id>
  local marker
  marker=$(fm_secondmate_parked_marker "$1") || return 1
  rm -f -- "$marker"
}

# Ask the watcher for a liveness tick at its next poll instead of after the
# cadence interval: the tick's cadence is the age of this marker, and a missing
# marker is due immediately.
fm_secondmate_liveness_tick_now() {
  rm -f -- "$STATE/.secondmate-liveness-tick"
}
