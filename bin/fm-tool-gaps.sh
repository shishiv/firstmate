#!/usr/bin/env bash
# fm-tool-gaps.sh - report the tools this machine is missing for the registered
# projects, and the fleet's own CLIs that have a newer release. Report only.
#
# Usage:
#   fm-tool-gaps.sh project-needs   local reads only; one TOOL_NEED line per gap
#   fm-tool-gaps.sh cli-updates     read-only release lookups; one TOOL_UPDATE line per update
#   fm-tool-gaps.sh --help
#
# Both subcommands print nothing when there is nothing to report, so
# bin/fm-bootstrap.sh can relay their lines straight into the session-start
# digest: project-needs runs on its local pass and cli-updates on its deferred
# network pass (bin/fm-startup-network.sh), whose non-informational lines raise
# the `check: startup-network` notification.
#
# What this script never does: it installs, updates, uninstalls, or configures
# nothing, never edits PATH or a shell profile, and never writes into a project.
# Each printed line carries the command a human would run to clear the gap.
#
# project-needs
#   A registered project declares a tool it needs with a version pin file,
#   tools/<tool>.version in its clone under projects/, holding the pinned
#   version on its first line. <tool> must be a plain executable name
#   (A-Za-z0-9._+-, not starting with "-") and the pin a plain version token
#   starting with a digit or "v<digit>", or the file is ignored. The tool is looked up on PATH first and then in the
#   per-user install directories ~/.luarocks/bin, ~/.local/bin, ~/.cargo/bin,
#   and ~/go/bin, which is how a per-user package manager install such as
#   `luarocks install --local` is found when it is not on PATH. The copy found
#   is asked for `<tool> --version` (bounded by FM_TOOL_GAPS_PROBE_SECS, default
#   5) and matches when that output carries the pinned version as a whole token.
#   Lines:
#     TOOL_NEED: <project> needs <tool> <pin> (tools/<tool>.version): not installed (fix: install <tool> <pin> and put it on PATH)
#     TOOL_NEED: <project> needs <tool> <pin> (tools/<tool>.version): <path> is not on PATH, so a bare `<tool>` call fails (fix: export PATH="<dir>:$PATH" in the login shell profile)
#     TOOL_NEED: <project> needs <tool> <pin> (tools/<tool>.version): <path> reports <found> (fix: install <tool> <pin>)
#     TOOL_NEED: <project> needs <tool> <pin> (tools/<tool>.version): <path> --version failed (fix: reinstall <tool> <pin>)
#   A copy off PATH that also reports the wrong version, or fails, prints the
#   version or failure line, with the PATH fix appended.
#
# cli-updates
#   For each of the fleet's own CLIs that is installed, compares its own
#   reported version with the newest release its publisher lists, and prints
#     TOOL_UPDATE: <tool> <installed> -> <latest> available (update: <command>)
#   only when the published one is newer. The sources are fixed below:
#     treehouse   GitHub releases/latest of kunchenguid/treehouse  (update: treehouse update)
#     gh-axi      npm registry gh-axi                              (update: gh-axi update)
#     tasks-axi   npm registry tasks-axi                           (update: npm install -g tasks-axi)
#     lavish-axi  npm registry lavish-axi                          (update: lavish-axi update)
#     kiro-cli    Kiro CLI stable manifest                         (update: kiro-cli update --non-interactive)
#     pi          npm registry @earendil-works/pi-coding-agent     (update: pi update)
#   An absent CLI is skipped (bin/fm-bootstrap.sh reports the ones it requires
#   as MISSING). A lookup that cannot answer - offline, rate limited, or an
#   unreadable reply - prints nothing for that CLI rather than a guess, so an
#   offline session start stays quiet. Lookups run concurrently, each bounded
#   by FM_TOOL_GAPS_FETCH_SECS (default 5), and need curl and jq.
#   This is the session-start snapshot of the fleet's own CLIs; the optional,
#   configurable watcher check for any tool is bin/fm-tool-update-check.sh.
#   Under Firstmate's own suite (FM_TEST_SEAM=1) no lookup leaves the machine;
#   fetch_json below owns that seam.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  sed -n '2,/^set -u$/{ /^set -u$/d; s/^# \{0,1\}//; p; }' "${BASH_SOURCE[0]}"
}

bounded_secs() {  # <value> <default> -> whole seconds 1..30
  case "$1" in
    ''|*[!0-9]*|0) printf '%s' "$2" ;;
    *) if [ "$1" -gt 30 ]; then printf '30'; else printf '%s' "$1"; fi ;;
  esac
}
PROBE_SECS=$(bounded_secs "${FM_TOOL_GAPS_PROBE_SECS:-}" 5)
FETCH_SECS=$(bounded_secs "${FM_TOOL_GAPS_FETCH_SECS:-}" 5)

# 0 when <a> is a newer dotted version than <b>. A leading "v" is ignored, and
# only the leading numeric dotted part counts, so suffixes never decide it.
version_newer() {  # <a> <b>
  awk -v a="${1#v}" -v b="${2#v}" 'BEGIN {
    sub(/[^0-9.].*$/, "", a); sub(/[^0-9.].*$/, "", b)
    na = split(a, x, "."); nb = split(b, y, ".")
    if (na == 0 || nb == 0) exit 1
    n = na > nb ? na : nb
    for (i = 1; i <= n; i++) {
      if ((x[i] + 0) > (y[i] + 0)) exit 0
      if ((x[i] + 0) < (y[i] + 0)) exit 1
    }
    exit 1
  }'
}

# First dotted version token in <text>, or nothing.
first_version() {  # <text>
  printf '%s\n' "$1" | grep -oE '[0-9]+(\.[0-9]+)+' | head -1
}

# 0 when <text> carries <version> as a whole token (not inside a longer one).
carries_version() {  # <text> <version>
  local pattern
  pattern=$(printf '%s' "$2" | sed 's/[.[\*^$+?(){}|]/\\&/g')
  printf '%s\n' "$1" | grep -qE "(^|[^0-9A-Za-z.])v?${pattern}([^0-9A-Za-z.]|\$)"
}

# --- project-needs ----------------------------------------------------------

USER_BIN_DIRS=".luarocks/bin .local/bin .cargo/bin go/bin"

project_needs() {
  local proj project pinfile tool pin onpath bin dir out rc found fix where
  [ -d "$PROJECTS" ] || return 0
  for proj in "$PROJECTS"/*/; do
    proj=${proj%/}
    [ -d "$proj/tools" ] && [ ! -L "$proj" ] || continue
    project=${proj##*/}
    for pinfile in "$proj"/tools/*.version; do
      [ -f "$pinfile" ] && [ ! -L "$pinfile" ] && [ -r "$pinfile" ] || continue
      tool=${pinfile##*/}
      tool=${tool%.version}
      case "$tool" in ''|-*|*[!A-Za-z0-9._+-]*) continue ;; esac
      IFS= read -r pin < "$pinfile" || [ -n "$pin" ] || continue
      pin=${pin#"${pin%%[![:space:]]*}"}
      pin=${pin%"${pin##*[![:space:]]}"}
      case "$pin" in ''|*[!A-Za-z0-9._+-]*) continue ;; esac
      case "$pin" in [0-9]*|v[0-9]*) ;; *) continue ;; esac
      where="$project needs $tool $pin (tools/$tool.version)"

      onpath=1
      bin=$(command -v -- "$tool" 2>/dev/null) || bin=
      case "$bin" in /*) ;; *) bin= ;; esac
      if [ -z "$bin" ]; then
        onpath=0
        for dir in $USER_BIN_DIRS; do
          if [ -n "${HOME:-}" ] && [ -f "$HOME/$dir/$tool" ] && [ -x "$HOME/$dir/$tool" ]; then
            bin="$HOME/$dir/$tool"
            break
          fi
        done
      fi
      if [ -z "$bin" ]; then
        printf 'TOOL_NEED: %s: not installed (fix: install %s %s and put it on PATH)\n' "$where" "$tool" "$pin"
        continue
      fi
      fix=
      if [ "$onpath" -eq 0 ]; then
        # shellcheck disable=SC2016 # The fix names $PATH literally for the profile line.
        fix="export PATH=\"${bin%/*}:\$PATH\" in the login shell profile"
      fi

      out=$(fm_run_timed "$PROBE_SECS" "$bin" --version 2>&1 </dev/null); rc=$?
      if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
        printf 'TOOL_NEED: %s: %s --version failed (fix: reinstall %s %s%s)\n' \
          "$where" "$bin" "$tool" "$pin" "${fix:+, then $fix}"
        continue
      fi
      if ! carries_version "$out" "$pin"; then
        found=$(first_version "$out")
        printf 'TOOL_NEED: %s: %s reports %s (fix: install %s %s%s)\n' \
          "$where" "$bin" "${found:-no readable version}" "$tool" "$pin" "${fix:+, then $fix}"
        continue
      fi
      if [ "$onpath" -eq 0 ]; then
        printf 'TOOL_NEED: %s: %s is not on PATH, so a bare `%s` call fails (fix: %s)\n' \
          "$where" "$bin" "$tool" "$fix"
      fi
    done
  done
}

# --- cli-updates ------------------------------------------------------------

# <tool> <source kind> <source> <update command>, one CLI per line.
FLEET_CLIS='treehouse	github	kunchenguid/treehouse	treehouse update
gh-axi	npm	gh-axi	gh-axi update
tasks-axi	npm	tasks-axi	npm install -g tasks-axi
lavish-axi	npm	lavish-axi	lavish-axi update
kiro-cli	kiro	stable	kiro-cli update --non-interactive
pi	npm	@earendil-works/pi-coding-agent	pi update'

# Firstmate's own suite (tests/lib.sh arms FM_TEST_SEAM=1) must never reach a
# real registry: there every lookup reads a canned reply from
# FM_TEST_TOOL_GAPS_RELEASES/<url with "/" and ":" turned into "_">, and finds
# nothing when that is unset.
fetch_json() {  # <url>
  local canned
  if [ "${FM_TEST_SEAM:-}" = 1 ]; then
    [ -n "${FM_TEST_TOOL_GAPS_RELEASES:-}" ] || return 1
    canned=${1//\//_}
    canned="$FM_TEST_TOOL_GAPS_RELEASES/${canned//:/_}"
    [ -f "$canned" ] && cat "$canned"
    return
  fi
  curl -fsSL --max-time "$FETCH_SECS" -H 'Accept: application/json' "$1" 2>/dev/null
}

latest_version() {  # <kind> <source>
  local json
  case "$1" in
    npm) json=$(fetch_json "https://registry.npmjs.org/$2/latest") || return 1
      printf '%s' "$json" | jq -r '.version // empty' 2>/dev/null ;;
    github) json=$(fetch_json "https://api.github.com/repos/$2/releases/latest") || return 1
      printf '%s' "$json" | jq -r '.tag_name // empty' 2>/dev/null ;;
    kiro) json=$(fetch_json "https://prod.download.cli.kiro.dev/$2/latest/manifest.json") || return 1
      printf '%s' "$json" | jq -r '.version // empty' 2>/dev/null ;;
    *) return 1 ;;
  esac
}

cli_update_line() {  # <tool> <kind> <source> <update>
  local tool=$1 kind=$2 source=$3 update=$4 out installed latest
  # The release is looked up first, so a lookup that cannot answer never runs
  # the installed CLI at all.
  latest=$(latest_version "$kind" "$source") || return 0
  latest=$(first_version "$latest")
  [ -n "$latest" ] || return 0
  out=$(fm_run_timed "$PROBE_SECS" "$tool" --version 2>/dev/null </dev/null) || return 0
  installed=$(first_version "$out")
  [ -n "$installed" ] || return 0
  version_newer "$latest" "$installed" || return 0
  printf 'TOOL_UPDATE: %s %s -> %s available (update: %s)\n' "$tool" "$installed" "$latest" "$update"
}

cli_updates() {
  local dir tool kind source update i=0 n pids='' pid
  command -v jq >/dev/null 2>&1 || return 0
  [ "${FM_TEST_SEAM:-}" = 1 ] || command -v curl >/dev/null 2>&1 || return 0
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-tool-gaps.XXXXXX") || return 0
  while IFS=$(printf '\t') read -r tool kind source update; do
    [ -n "$tool" ] || continue
    i=$((i + 1))
    command -v -- "$tool" >/dev/null 2>&1 || continue
    cli_update_line "$tool" "$kind" "$source" "$update" > "$dir/$i" &
    pids="$pids $!"
  done <<EOF
$FLEET_CLIS
EOF
  for pid in $pids; do wait "$pid" 2>/dev/null || true; done
  # Replay in table order so the report reads the same on every run.
  n=1
  while [ "$n" -le "$i" ]; do
    [ ! -s "$dir/$n" ] || cat "$dir/$n"
    n=$((n + 1))
  done
  rm -rf "$dir"
}

case "${1:-}" in
  project-needs) project_needs ;;
  cli-updates) cli_updates ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
exit 0
