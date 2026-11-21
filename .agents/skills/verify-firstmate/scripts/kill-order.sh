#!/usr/bin/env bash
# Prove which process the kernel kills first when a worker's memory scope fills.
# Usage: kill-order.sh [--out <dir>]
#   Runs an "agent" that holds memory and one "command" that grows without bound,
#   in a real systemd user scope named like a worker's (firstmate.slice/
#   fm-worker-*.scope) whose cap is 200M, and reads which of the two the kernel
#   killed. Two launches, both through the same cap:
#     before  the launch as it was before the kill order: `choom -n 500` for the
#             agent and a plain `bash -c` command, both at oom_score_adj 500;
#     now     the real bin/fm-worker-memory-scope.sh and a command run through
#             bin/fm-worker-bash-env.sh, as the Kiro shell tool runs it.
#   Prints one PASS or FAIL line per claim and exits 1 on any FAIL, 2 when this
#   host has no systemd user scope or choom. Touches only its own scopes and a
#   scratch directory under /tmp.
set -u

WT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)"
OUT=
while [ $# -gt 0 ]; do
  case "$1" in
    --out) shift; OUT=${1:-} ;;
    *) echo "usage: kill-order.sh [--out <dir>]" >&2; exit 2 ;;
  esac
  shift
done
[ -z "$OUT" ] || mkdir -p "$OUT" || exit 2

for tool in systemd-run systemctl choom; do
  command -v "$tool" >/dev/null 2>&1 || { echo "kill-order: $tool not found; skipping" >&2; exit 2; }
done
systemd-run --user --scope --quiet --collect -- true >/dev/null 2>&1 \
  || { echo "kill-order: no systemd user scope on this host; skipping" >&2; exit 2; }

CAP=200M
CAP_BYTES=209715200
AGENT_MB=100
R=$(mktemp -d /tmp/fmkillorder.XXXXXX) || exit 2
FAILS=0
trap 'rm -rf "$R"' EXIT

check() {
  if [ "$1" = ok ]; then echo "PASS: $2"; else echo "FAIL: $2"; FAILS=$((FAILS + 1)); fi
}

# The agent waits for its scope to be capped, holds AGENT_MB, then runs one
# command that grows 10 MB at a time and reports what became of it. `$1` is the
# BASH_ENV to give the command ("" for none).
cat > "$R/agent.sh" <<'SH'
#!/usr/bin/env bash
result=$1 bash_env=$2 agent_mb=$3
while [ ! -e "$result.go" ]; do sleep 0.1; done
chunk=$(printf '%*s' 10000000 '')
hold=''
for ((i = 0; i < agent_mb / 10; i++)); do hold+=$chunk; done
echo "agent_adj=$(cat /proc/self/oom_score_adj)" >> "$result"
env_args=(-u BASH_ENV -u FM_WORKER_PIPEFAIL_APPLIED -u FM_PRIOR_BASH_ENV)
[ -z "$bash_env" ] || env_args+=("BASH_ENV=$bash_env")
env "${env_args[@]}" bash -c '
  echo "command_adj=$(cat /proc/self/oom_score_adj)" >> "'"$result"'"
  chunk=$(printf "%*s" 10000000 "")
  acc=""
  while :; do acc+=$chunk; done
' 2>/dev/null
echo "command_rc=$?" >> "$result"
sleep 1
echo "agent_survived=yes" >> "$result"
SH
chmod +x "$R/agent.sh"

# run_case <label> <launcher> <bash-env>: starts the agent through <launcher>
# (before|now) in a fresh scope, caps it, lets it run, and leaves
# "$R/<label>.result" and "$R/<label>.agent_rc". The scope's own cap is set
# again at runtime because a host drop-in for fm-worker-.scope can pin another.
run_case() {
  local label=$1 launcher=$2 bash_env=$3 unit pid tries
  unit="fm-worker-killorder-$label-$$.scope"
  : > "$R/$label.result"
  case "$launcher" in
    before)
      systemd-run --user --scope --quiet --collect --slice=firstmate.slice --unit="$unit" \
        -p "MemoryMax=$CAP" -p MemorySwapMax=0 -p OOMPolicy=continue -- \
        choom -n 500 -- "$R/agent.sh" "$R/$label.result" "$bash_env" "$AGENT_MB" 2> "$R/$label.agent.err" &
      ;;
    now)
      "$WT/bin/fm-worker-memory-scope.sh" "$CAP" "$unit" -- \
        "$R/agent.sh" "$R/$label.result" "$bash_env" "$AGENT_MB" 2> "$R/$label.agent.err" &
      ;;
  esac
  pid=$!
  tries=50
  while [ "$tries" -gt 0 ] && [ "$(systemctl --user show "$unit" -p ActiveState --value 2>/dev/null)" != active ]; do
    sleep 0.1
    tries=$((tries - 1))
  done
  systemctl --user set-property --runtime "$unit" MemoryMax="$CAP" >/dev/null 2>&1
  {
    echo "[$label] unit=$unit"
    systemctl --user show "$unit" -p MemoryMax -p MemorySwapMax -p OOMPolicy
    echo "cgroup=$(cat "/proc/$pid/cgroup" 2>/dev/null)"
  } >> "$R/$label.scope"
  : > "$R/$label.result.go"
  tries=60
  while [ "$tries" -gt 0 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.5
    tries=$((tries - 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo "TIMEOUT: $label agent still running after 30s" >> "$R/$label.result"
    kill "$pid" 2>/dev/null
  fi
  wait "$pid" 2>/dev/null
  echo "$?" > "$R/$label.agent_rc"
  # A killed agent leaves its command running until the scope kills that too.
  tries=100
  while [ "$tries" -gt 0 ] && [ "$(systemctl --user show "$unit" -p ActiveState --value 2>/dev/null)" = active ]; do
    sleep 0.1
    tries=$((tries - 1))
  done
}

field() { sed -n "s/^$2=//p" "$R/$1.result" | head -1; }

echo "== before: choom -n 500 for the agent, a plain bash -c command"
run_case before before ""
cat "$R/before.scope" "$R/before.result"
echo "agent_rc=$(cat "$R/before.agent_rc") (137 = killed by the kernel)"

echo "== now: bin/fm-worker-memory-scope.sh and a command through bin/fm-worker-bash-env.sh"
run_case now now "$WT/bin/fm-worker-bash-env.sh"
cat "$R/now.scope" "$R/now.result"
echo "agent_rc=$(cat "$R/now.agent_rc") (137 = killed by the kernel)"

if [ -n "$OUT" ]; then
  { cat "$R/before.scope" "$R/before.result"; echo "agent_rc=$(cat "$R/before.agent_rc")"
    cat "$R/now.scope" "$R/now.result"; echo "agent_rc=$(cat "$R/now.agent_rc")"; } > "$OUT/kill-order.txt"
fi

for label in before now; do
  if grep -q "^MemoryMax=$CAP_BYTES\$" "$R/$label.scope" && grep -q 'MemorySwapMax=0' "$R/$label.scope" \
    && grep -q '/firstmate.slice/fm-worker-killorder-' "$R/$label.scope"; then
    check ok "$label: the run is in a worker-named scope capped at $CAP with no swap"
  else
    check bad "$label: the run is in a worker-named scope capped at $CAP with no swap"
  fi
done

if [ "$(field before agent_adj)" = 500 ] && [ "$(field before command_adj)" = 500 ] \
  && [ "$(cat "$R/before.agent_rc")" = 137 ] && [ -z "$(field before agent_survived)" ]; then
  check ok "before: agent and command both at 500, and the kernel kills the agent, the larger of the two"
else
  check bad "before: agent and command both at 500, and the kernel kills the agent, the larger of the two"
fi

if [ "$(field now agent_adj)" = 400 ] && [ "$(field now command_adj)" = 1000 ] \
  && [ "$(field now command_rc)" = 137 ] && [ "$(field now agent_survived)" = yes ] \
  && [ "$(cat "$R/now.agent_rc")" = 0 ]; then
  check ok "now: the agent at 400 and the command at 1000, the kernel kills the command, and the agent finishes"
else
  check bad "now: the agent at 400 and the command at 1000, the kernel kills the command, and the agent finishes"
fi

[ "$FAILS" -eq 0 ]
