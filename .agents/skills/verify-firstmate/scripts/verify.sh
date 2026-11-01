#!/usr/bin/env bash
# Prove a Firstmate change end to end in a disposable lab home.
# Usage: verify.sh [--keep] [--out <dir>] [-- <fm-test-run.sh selection...>]
#   Runs the hc lifecycle against a private herdr-core, with a stand-in agent:
#   spawn one scout, see its status line reach the wake queue, steer it once,
#   tear it down. Then runs bin/fm-test-run.sh with the selection after --
#   (default --changed). Exits 0 only when every step passed. Evidence goes to
#   --out (default /tmp/fmvf-evidence.<pid>); the scratch root is removed on
#   exit unless --keep is given.
# Touches only: the lab home, a private hc core (own HC_SESSION and XDG dirs),
# and a named Herdr lab session that guards the default session as a tripwire.
set -u

WT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)"
KEEP=0
OUT=
SUITE=(--changed)
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1 ;;
    --out) shift; OUT=${1:-} ;;
    --) shift; [ $# -eq 0 ] || SUITE=("$@"); break ;;
    *) echo "usage: verify.sh [--keep] [--out <dir>] [-- <fm-test-run.sh selection...>]" >&2; exit 2 ;;
  esac
  shift
done
OUT=${OUT:-/tmp/fmvf-evidence.$$}
mkdir -p "$OUT" || exit 2
OUT=$(cd "$OUT" && pwd -P)

for tool in hc jq git treehouse; do
  command -v "$tool" >/dev/null 2>&1 || { echo "verify-firstmate: $tool not found" >&2; exit 2; }
done

R=$(mktemp -d /tmp/fmvf.XXXXXX) || exit 2
LAB=$R/home
ID=vf1
LAB_HOME_HELPER=$WT/bin/fm-lab-home.sh
HERDR_LAB_HELPER=$WT/bin/fm-herdr-lab.sh
HERDR_LAB_SESSION=
HC_SESSION_NAME=fmvf$$
WATCH_PID=
FAILS=0

XDG_NAMES="XDG_STATE_HOME XDG_RUNTIME_DIR XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME"
for n in $XDG_NAMES; do
  if [ -n "${!n+x}" ]; then eval "ORIG_$n=\${$n}"; eval "HAD_$n=1"; fi
done
host_env() {
  (
    for n in $XDG_NAMES; do
      h="HAD_$n"; o="ORIG_$n"
      if [ -n "${!h:-}" ]; then export "$n=${!o}"; else unset "$n"; fi
    done
    unset HC_SESSION
    "$@"
  )
}
herdr_helper() { host_env "$HERDR_LAB_HELPER" "$@"; }

unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE HC_SOCKET HERDR_ENV
export HC_SESSION=$HC_SESSION_NAME XDG_STATE_HOME=$R XDG_RUNTIME_DIR=$R
export XDG_CONFIG_HOME=$R/config XDG_DATA_HOME=$R/data XDG_CACHE_HOME=$R/cache
mkdir -p "$R/config" "$R/data" "$R/cache" "$R/pool" "$R/agents/claude"

step() { printf '\n=== %s\n' "$*"; }
check() {
  if [ "$1" = ok ]; then echo "PASS: $2"; else echo "FAIL: $2"; FAILS=$((FAILS + 1)); fi
}
wait_for() {
  local tries=$(( $1 * 10 ))
  shift
  while [ "$tries" -gt 0 ]; do
    "$@" && return 0
    tries=$((tries - 1))
    sleep 0.1
  done
  return 1
}

cleanup() {
  [ -z "$WATCH_PID" ] || kill "$WATCH_PID" >/dev/null 2>&1 || true
  if [ "$HC_SESSION" = "$HC_SESSION_NAME" ] && [ "$XDG_STATE_HOME" = "$R" ]; then
    hc server stop --json >/dev/null 2>&1 || true
  fi
  "$LAB_HOME_HELPER" teardown "$LAB" >/dev/null 2>&1 || true
  if [ -n "$HERDR_LAB_SESSION" ]; then
    herdr_helper teardown "$HERDR_LAB_SESSION" || { echo "FAIL: herdr lab teardown tripwire"; FAILS=$((FAILS + 1)); }
  fi
  [ "$KEEP" = 1 ] || { sleep 0.5; chmod -R u+w "$R" 2>/dev/null; rm -rf "$R"; }
  if [ "$FAILS" -eq 0 ] && [ "${rc:-0}" -eq 0 ]; then echo "verify-firstmate: PASS (evidence $OUT)"; else echo "verify-firstmate: FAIL x$FAILS (evidence $OUT)"; fi
}
trap 'rc=$?; cleanup; [ "$rc" -ne 0 ] || [ "$FAILS" -eq 0 ] || rc=1; exit $rc' EXIT

step "doctor"
"$LAB_HOME_HELPER" create "$LAB" >/dev/null || exit 2
HERDR_LAB_SESSION=$(herdr_helper name fm-verify)
herdr_helper provision "$HERDR_LAB_SESSION" >/dev/null || { HERDR_LAB_SESSION=; exit 2; }
echo "worktree $WT @ $(git -C "$WT" rev-parse --short HEAD)"
echo "hc $(hc --version) private session $HC_SESSION_NAME, lab home $LAB, herdr lab $HERDR_LAB_SESSION"
if hc server status --json >/dev/null 2>&1; then check ok "private hc core started"; else check bad "private hc core started"; fi

cat > "$R/agents/claude/claude" <<SH
#!/bin/bash
printf 'stand-in agent ready: %s\n' "\$*"
echo "working [at=\$(date +%s)]: stand-in up" >> '$LAB/state/$ID.status'
while IFS= read -r line; do
  printf 'got: %s\n' "\$line"
  printf '%s\n' "\$line" >> '$R/agents/claude/received'
done
SH
chmod +x "$R/agents/claude/claude"

git init -q --bare -b main "$R/demo-origin.git"
git init -q -b main "$LAB/projects/demo"
printf 'root = "%s"\n' "$R/pool" > "$LAB/projects/demo/treehouse.toml"
printf 'demo\n' > "$LAB/projects/demo/README.md"
git -C "$LAB/projects/demo" add -A
git -C "$LAB/projects/demo" -c user.name=lab -c user.email=lab@example.invalid commit -qm init
git -C "$LAB/projects/demo" remote add origin "$R/demo-origin.git"
git -C "$LAB/projects/demo" push -q -u origin main
git -C "$LAB/projects/demo" remote set-head origin main

fm() { local s=$1; shift; FM_HOME=$LAB FM_SPAWN_NO_GUARD=1 SHELL=/bin/sh "$WT/bin/$s" "$@"; }

step "spawn one scout on hc"
fm fm-brief.sh "$ID" demo --scout >/dev/null || check bad "brief scaffolded"
python3 - "$LAB/data/$ID/brief.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("{TASK}", "Lab task: write the word ok to the report.").replace("{FIRSTMATE_SPEC}", "Write ok to the report and stop.")
open(p, "w").write(s)
PY
fm fm-spawn.sh "$ID" "$LAB/projects/demo" --scout --backend hc --harness "$R/agents/claude/claude --fake" 2>&1 | tee "$OUT/spawn.txt" | tail -3
if grep -q '^backend=hc' "$LAB/state/$ID.meta"; then check ok "meta records backend=hc"; else check bad "meta records backend=hc"; fi
WINDOW=$(sed -n 's/^spawned .* window=\([^ ]*\) .*/\1/p' "$OUT/spawn.txt")
ADDR=${WINDOW#*:}
if hc get --json "$ADDR" | jq -e '.state != "finished"' >/dev/null 2>&1; then check ok "terminal $WINDOW is live in the private core"; else check bad "terminal $WINDOW is live in the private core"; fi
agent_up() { [ -s "$LAB/state/$ID.status" ]; }
if wait_for 20 agent_up; then check ok "stand-in agent started and wrote its first status line"; else check bad "stand-in agent started and wrote its first status line"; fi
hc get --json "$ADDR" | jq -c 'del(.screen)' | tee "$OUT/terminal.json"

step "notification reaches the wake queue"
(cd "$LAB" && FM_HOME=$LAB FM_POLL=1 "$WT/bin/fm-watch.sh" >"$R/watch.out" 2>&1) &
WATCH_PID=$!
sleep 2
echo "done [at=$(date +%s)]: lab scout finished" >> "$LAB/state/$ID.status"
woke() { grep -q "signal:.*$ID.status" "$R/watch.out" 2>/dev/null; }
if wait_for 60 woke; then check ok "watcher surfaced a signal wake for $ID.status"; else check bad "watcher surfaced a signal wake for $ID.status"; fi
cp "$R/watch.out" "$OUT/watch.out" 2>/dev/null
cat "$R/watch.out"
FM_HOME=$LAB "$WT/bin/fm-wake-drain.sh" 2>&1 | tee "$OUT/drain.txt" | head -20
if grep -q "$ID done .*lab scout finished" "$OUT/drain.txt"; then check ok "the drain presents the done line of $ID"; else check bad "the drain presents the done line of $ID"; fi

step "steer once"
if fm fm-send.sh "$ID" 'Please also report the second line.'; then check ok "fm-send exited 0"; else check bad "fm-send exited 0"; fi
if ls "$LAB/state/$ID.inbox/"*.msg >/dev/null 2>&1; then check ok "steer is a durable inbox record"; else check bad "steer is a durable inbox record"; fi
rung() { [ -s "$R/agents/claude/received" ]; }
if wait_for 20 rung; then check ok "the stand-in received the doorbell line"; else check bad "the stand-in received the doorbell line"; fi
cp "$R/agents/claude/received" "$OUT/received.txt" 2>/dev/null
fm fm-peek.sh "$ID" | tee "$OUT/peek.txt" | tail -4

step "cleanup through teardown"
printf 'ok\n' > "$LAB/data/$ID/report.md"
fm fm-captain-hold.sh complete "$ID" --none >/dev/null 2>&1 || true
fm fm-teardown.sh "$ID" 2>&1 | tee "$OUT/teardown.txt" | tail -2
gone() { [ "$(hc ls --json --all | jq '.terminals | length')" = 0 ]; }
if wait_for 20 gone; then check ok "no terminal left in the private core"; else check bad "no terminal left in the private core"; fi

step "tests: bin/fm-test-run.sh ${SUITE[*]}"
if host_env "$WT/bin/fm-test-run.sh" "${SUITE[@]}" >"$OUT/suite.txt" 2>&1; then
  check ok "bin/fm-test-run.sh ${SUITE[*]} exited 0"
else
  check bad "bin/fm-test-run.sh ${SUITE[*]} exited 0"
fi
grep -E '^(fm-test-run: |FM_TEST_SUMMARY |FM_TEST_END .* exit=[1-9])' "$OUT/suite.txt" || true
