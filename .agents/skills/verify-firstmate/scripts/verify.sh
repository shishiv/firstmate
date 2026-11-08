#!/usr/bin/env bash
# Prove a Firstmate change end to end in a disposable lab home.
# Usage: verify.sh [--keep] [--out <dir>] [-- <fm-test-run.sh selection...>]
#   Runs the hc lifecycle against a private herdr-core, with a stand-in agent:
#   spawn one scout, check its worker memory scope, see its status line reach
#   the wake queue, steer it once, tear it down. Then relaunches a second scout
#   on a private tmux server, in a new scope and once more with the scope off.
#   Then runs bin/fm-test-run.sh with the selection after --
#   (default --changed). Exits 0 only when every step passed. Evidence goes to
#   --out (default /tmp/fmvf-evidence.<pid>); the scratch root is removed on
#   exit unless --keep is given.
# Touches only: the lab home, a private hc core (own HC_SESSION and XDG dirs),
# a private tmux server (the lab home's TMUX_TMPDIR), the lab workers' own
# systemd user scopes, and a named Herdr lab session that guards the default
# session as a tripwire.
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
LAB_TMUX_DIR=
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
mkdir -p "$R/config" "$R/data" "$R/cache" "$R/pool" "$R/agents/claude" "$R/agents2/claude"

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
  if [ -n "$LAB_TMUX_DIR" ]; then
    TMUX_TMPDIR=$LAB_TMUX_DIR tmux kill-server >/dev/null 2>&1 || true
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
# The relaunch stand-in also leaves on /exit, as the real claude does, so
# bin/fm-control.sh relaunch can stop it and type the replacement launch.
cat > "$R/agents2/claude/claude" <<SH
#!/bin/bash
printf 'stand-in agent ready: %s\n' "\$*"
echo "working [at=\$(date +%s)]: stand-in up" >> '$LAB/state/vf2.status'
while IFS= read -r line; do
  printf 'got: %s\n' "\$line"
  [ "\$line" != /exit ] || exit 0
done
SH
chmod +x "$R/agents2/claude/claude"

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

# standin_pid <stand-in path>: the stand-in agent process itself (comm claude),
# never a shell whose command line merely names it.
standin_pid() {
  local p
  for p in $(pgrep -f "$1 --fake"); do
    [ "$(cat "/proc/$p/comm" 2>/dev/null)" = claude ] && { echo "$p"; return 0; }
  done
  return 1
}
spawn_gen() { sed -n 's/^spawn_gen=//p' "$LAB/state/$1.meta" | tail -1; }
# scope_proof <id> <stand-in path> <label>: the worker's own scope carries
# MemoryHigh=3G and holds the stand-in, whose harness ancestry still names
# claude. Sets UNIT and PID and appends the evidence to $OUT/scope.txt.
scope_proof() {
  local id=$1 standin=$2 label=$3 high cg verdict crew
  UNIT="fm-worker-$id-$(spawn_gen "$id").scope"
  PID=
  wait_for 20 standin_pid "$standin" >/dev/null && PID=$(standin_pid "$standin")
  high=$(host_env systemctl --user show "$UNIT" -p MemoryHigh --value 2>&1)
  cg=$(cat "/proc/$PID/cgroup" 2>/dev/null)
  verdict=$("$WT/bin/fm-harness.sh" ancestry "$PID" 2>&1)
  crew=$(FM_CREW_STATE_NO_FORGE=1 fm fm-crew-state.sh "$id" 2>&1)
  {
    echo "[$label] unit=$UNIT pid=$PID"
    echo "MemoryHigh=$high"
    echo "cgroup=$cg"
    echo "ancestry=$verdict"
    echo "crew-state=$crew"
  } >> "$OUT/scope.txt"
  if [ "$high" = 3221225472 ]; then check ok "$label: $UNIT reports MemoryHigh=3221225472"; else check bad "$label: $UNIT reports MemoryHigh=3221225472 (got $high)"; fi
  case "$cg" in
    */firstmate.slice/"$UNIT") check ok "$label: the stand-in (pid $PID) runs inside firstmate.slice/$UNIT" ;;
    *) check bad "$label: the stand-in (pid ${PID:-none}) runs inside firstmate.slice/$UNIT (cgroup $cg)" ;;
  esac
  case "$verdict" in
    *claude*) check ok "$label: the stand-in's harness ancestry still names claude ($verdict)" ;;
    *) check bad "$label: the stand-in's harness ancestry still names claude (got $verdict)" ;;
  esac
  case "$crew" in
    'state: working '*) check ok "$label: bin/fm-crew-state.sh reads the scoped worker as working" ;;
    *) check bad "$label: bin/fm-crew-state.sh reads the scoped worker as working (got $crew)" ;;
  esac
}

step "worker memory scope"
: > "$OUT/scope.txt"
scope_proof "$ID" "$R/agents/claude/claude" "$ID"
VF1_UNIT=$UNIT

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
unit_gone() { [ "$(host_env systemctl --user show "$1" -p LoadState --value 2>/dev/null)" = not-found ]; }
if wait_for 20 unit_gone "$VF1_UNIT"; then check ok "systemd collected $VF1_UNIT after teardown"; else check bad "systemd collected $VF1_UNIT after teardown"; fi

step "relaunch and off switch on a private tmux server"
# hc has no relaunch (fm_control_backend_relaunch_supported in
# bin/fm-control-lib.sh), so the relaunch proof runs a second scout on tmux.
LAB_TMUX_DIR=$("$LAB_HOME_HELPER" tmux-dir "$LAB")
export TMUX_TMPDIR=$LAB_TMUX_DIR
unset TMUX TMUX_PANE
S2="$R/agents2/claude/claude"
: > "$OUT/relaunch.txt"
fm fm-brief.sh vf2 demo --scout >/dev/null || check bad "vf2 brief scaffolded"
sed -i -e 's/{TASK}/Lab task: write the word ok to the report./' \
  -e 's/{FIRSTMATE_SPEC}/Write ok to the report and stop./' "$LAB/data/vf2/brief.md"
fm fm-spawn.sh vf2 "$LAB/projects/demo" --scout --backend tmux --harness "$S2 --fake" 2>&1 | tee "$OUT/spawn-vf2.txt" | tail -3
scope_proof vf2 "$S2" "vf2 spawn"
OLD_UNIT=$UNIT
OLD_PID=$PID
OLD_GEN=$(spawn_gen vf2)
# relaunch_vf2 <label>: the operator verb first; when it refuses the stand-in,
# stop the stand-in and use the documented path for a stopped task. A stop
# records what Firstmate reads for the stopped worker in STOPPED_READ.
pane_cmd() { tmux display-message -p -t "=firstmate:fm-vf2" '#{pane_current_command}' 2>/dev/null; }
STOPPED_READ=
relaunch_vf2() {
  local p crew
  if fm fm-control.sh vf2 relaunch --harness "$S2 --fake" >>"$OUT/relaunch.txt" 2>&1; then
    echo "[$1] path: bin/fm-control.sh vf2 relaunch" >> "$OUT/relaunch.txt"
  else
    echo "[$1] bin/fm-control.sh vf2 relaunch refused; stopping the stand-in" >> "$OUT/relaunch.txt"
    p=$(standin_pid "$S2") && kill "$p"
    sleep 1
    crew=$(FM_CREW_STATE_NO_FORGE=1 fm fm-crew-state.sh vf2 2>&1)
    echo "[$1] stand-in stopped: crew-state=$crew pane_current_command=$(pane_cmd)" >> "$OUT/relaunch.txt"
    STOPPED_READ="$crew / $(pane_cmd)"
    fm fm-spawn.sh vf2 --relaunch --harness "$S2 --fake" >>"$OUT/relaunch.txt" 2>&1
    echo "[$1] path: bin/fm-spawn.sh vf2 --relaunch (exit $?)" >> "$OUT/relaunch.txt"
  fi
}
new_standin() { local p; p=$(standin_pid "$S2") && [ "$p" != "$OLD_PID" ]; }
relaunch_vf2 "relaunch"
SCOPED_STOPPED_READ=$STOPPED_READ
wait_for 20 new_standin || true
NEW_GEN=$(spawn_gen vf2)
if [ -n "$NEW_GEN" ] && [ "$NEW_GEN" != "$OLD_GEN" ]; then check ok "relaunch recorded a new spawn_gen ($OLD_GEN -> $NEW_GEN)"; else check bad "relaunch recorded a new spawn_gen ($OLD_GEN -> $NEW_GEN)"; fi
scope_proof vf2 "$S2" "vf2 relaunch"
SCOPED_PANE_CMD=$(pane_cmd)
if wait_for 20 unit_gone "$OLD_UNIT"; then check ok "systemd collected the old scope $OLD_UNIT"; else check bad "systemd collected the old scope $OLD_UNIT"; fi
OLD_PID=$PID
printf 'off\n' > "$LAB/config/worker-memory-high"
relaunch_vf2 "relaunch with off"
wait_for 20 new_standin || true
PID=$(standin_pid "$S2")
OFF_GEN=$(spawn_gen vf2)
OFF_LAUNCH=$(ls /tmp/fm-vf2+*/"launch.$OFF_GEN.sh" 2>/dev/null | head -1)
{
  echo "[vf2 off] pid=$PID gen=$OFF_GEN"
  echo "cgroup=$(cat "/proc/$PID/cgroup" 2>/dev/null)"
  echo "launch file=${OFF_LAUNCH:-not found}"
} >> "$OUT/scope.txt"
if [ "$OFF_GEN" != "$NEW_GEN" ] && [ -n "$PID" ] && ! grep -q 'fm-worker-' "/proc/$PID/cgroup"; then
  check ok "with off the relaunched stand-in (pid $PID) runs in no worker scope"
else
  check bad "with off the relaunched stand-in (pid ${PID:-none}, gen $OFF_GEN) runs in no worker scope"
fi
if [ -n "$OFF_LAUNCH" ] && ! grep -q 'fm-worker-memory-scope.sh' "$OFF_LAUNCH"; then
  check ok "with off the launch file $OFF_LAUNCH carries no wrapper"
else
  check bad "with off the launch file ${OFF_LAUNCH:-not found} carries no wrapper"
fi
# What Firstmate reads for a worker must not depend on the scope: the running
# and the stopped readings of the scoped stand-in equal the uncapped one's.
OFF_CREW=$(FM_CREW_STATE_NO_FORGE=1 fm fm-crew-state.sh vf2 2>&1)
OFF_PANE_CMD=$(pane_cmd)
[ -z "$PID" ] || kill "$PID"
sleep 1
OFF_STOPPED_READ="$(FM_CREW_STATE_NO_FORGE=1 fm fm-crew-state.sh vf2 2>&1) / $(pane_cmd)"
{
  echo "[vf2 off] crew-state=$OFF_CREW pane_current_command=$OFF_PANE_CMD"
  echo "[compare] running: scoped pane_current_command=$SCOPED_PANE_CMD, uncapped=$OFF_PANE_CMD"
  echo "[compare] stopped: scoped=$SCOPED_STOPPED_READ"
  echo "[compare] stopped: uncapped=$OFF_STOPPED_READ"
} >> "$OUT/scope.txt"
case "$OFF_CREW" in
  'state: working '*) check ok "with off bin/fm-crew-state.sh reads the uncapped worker as working, as it read the scoped one" ;;
  *) check bad "with off bin/fm-crew-state.sh reads the uncapped worker as working, as it read the scoped one (got $OFF_CREW)" ;;
esac
if [ -n "$SCOPED_PANE_CMD" ] && [ "$SCOPED_PANE_CMD" = "$OFF_PANE_CMD" ]; then
  check ok "tmux names the same foreground command for the scoped and the uncapped worker ($SCOPED_PANE_CMD)"
else
  check bad "tmux names the same foreground command for the scoped and the uncapped worker (scoped $SCOPED_PANE_CMD, uncapped $OFF_PANE_CMD)"
fi
if [ -n "$SCOPED_STOPPED_READ" ] && [ "$SCOPED_STOPPED_READ" = "$OFF_STOPPED_READ" ]; then
  check ok "Firstmate reads a stopped scoped worker exactly as a stopped uncapped one ($OFF_STOPPED_READ)"
else
  check bad "Firstmate reads a stopped scoped worker exactly as a stopped uncapped one (scoped $SCOPED_STOPPED_READ, uncapped $OFF_STOPPED_READ)"
fi
printf 'ok\n' > "$LAB/data/vf2/report.md"
fm fm-captain-hold.sh complete vf2 --none >/dev/null 2>&1 || true
fm fm-teardown.sh vf2 2>&1 | tee "$OUT/teardown-vf2.txt" | tail -2
vf2_gone() { ! standin_pid "$S2" >/dev/null; }
if wait_for 20 vf2_gone; then check ok "teardown retired vf2's stand-in"; else check bad "teardown retired vf2's stand-in"; fi
unset TMUX_TMPDIR

step "tests: bin/fm-test-run.sh ${SUITE[*]}"
if host_env "$WT/bin/fm-test-run.sh" "${SUITE[@]}" >"$OUT/suite.txt" 2>&1; then
  check ok "bin/fm-test-run.sh ${SUITE[*]} exited 0"
else
  check bad "bin/fm-test-run.sh ${SUITE[*]} exited 0"
fi
grep -E '^(fm-test-run: |FM_TEST_SUMMARY |FM_TEST_END .* exit=[1-9])' "$OUT/suite.txt" || true
