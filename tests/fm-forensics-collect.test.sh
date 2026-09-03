#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck disable=SC2153
COLLECTOR="$ROOT/bin/fm-forensics-collect.sh"
TMP_ROOT=$(fm_test_tmproot fm-forensics-collect)
HOME_FIXTURE="$TMP_ROOT/home"
WORKTREE="$TMP_ROOT/worktree"
FAKEBIN="$TMP_ROOT/fakebin"
ID=case-one
SECRET='TOPSECRET-forensics-fixture-value'

mkdir -p "$HOME_FIXTURE/state/$ID.inbox/handled" \
  "$HOME_FIXTURE/state/procevent-inbox" "$HOME_FIXTURE/data" "$FAKEBIN"
fm_git_init_commit "$WORKTREE"
printf 'proof\n' > "$WORKTREE/proof.txt"
git -C "$WORKTREE" add proof.txt
git -C "$WORKTREE" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
  commit -qm "$SECRET commit subject"
cat > "$WORKTREE/.git/hooks/fsmonitor-forensics-test" <<EOF
#!/bin/sh
touch '$HOME_FIXTURE/fsmonitor-hook-ran'
printf '0\n'
EOF
chmod +x "$WORKTREE/.git/hooks/fsmonitor-forensics-test"
git -C "$WORKTREE" config core.fsmonitor "$WORKTREE/.git/hooks/fsmonitor-forensics-test"

cat > "$FAKEBIN/crew-state" <<'SH'
#!/usr/bin/env bash
: > "$FM_STATE_OVERRIDE/$1.probe"
if [ -f "$FM_STATE_OVERRIDE/$1.meta" ]; then
  printf 'state: working · source: pane · detail contains TOPSECRET-forensics-fixture-value\n'
else
  printf 'state: unknown · source: none · missing\n'
fi
SH
chmod +x "$FAKEBIN/crew-state"

cat > "$HOME_FIXTURE/state/$ID.meta" <<EOF
window=firstmate:fm-$ID
endpoint_task_id=$ID
worktree=$WORKTREE
project=$WORKTREE
harness=muse
kind=ship
mode=local-only
yolo=off
model=$SECRET
token=$SECRET
EOF

{
  awk 'BEGIN { for (i = 1; i <= 5000; i++) print "working: bounded event " i }'
  awk 'BEGIN {
    for (j = 1; j <= 2048; j++) payload = payload "x"
    for (i = 1; i <= 20; i++) print "working: " payload
  }'
  printf 'blocked [key=secret-key]: %s\n' "$SECRET"
  printf 'blocked [key=secret-key]: %s\n' "$SECRET"
} > "$HOME_FIXTURE/state/$ID.status"

cat > "$HOME_FIXTURE/data/backlog.md" <<EOF
## In flight
- [ ] $ID-extra - Mention $ID without sharing its identity (repo: fixture) (kind: ship)
- [ ] $ID - Investigate $SECRET (repo: fixture) (kind: ship)
- [ ] $ID - Investigate $SECRET (repo: fixture) (kind: ship)

## Queued

## Done
EOF

for record in "$HOME_FIXTURE/state/$ID.inbox/001.msg" \
  "$HOME_FIXTURE/state/$ID.inbox/handled/002.msg"; do
  cat > "$record" <<EOF
schema=fm-task-inbox.v1
at=2026-08-31T12:00:00Z
--
Repeat this instruction with $SECRET.
EOF
done

for seq in 1 2; do
  printf 'task=%s error=%s\n' "$ID" "$SECRET" \
    > "$HOME_FIXTURE/state/procevent-inbox/source-$seq.result"
  printf 'lavish\n' > "$HOME_FIXTURE/state/procevent-inbox/source-$seq.adapter"
done
touch "$HOME_FIXTURE/state/procevent-inbox/source-1.handled"

cat > "$HOME_FIXTURE/state/branch-outcomes.jsonl" <<EOF
{"seq":1,"epoch":100,"task":"$ID","wake":"retry $SECRET","verdict":"routine","summary":"same $SECRET","silent":false}
{"seq":2,"epoch":101,"task":"$ID","wake":"retry $SECRET","verdict":"routine","summary":"same $SECRET","silent":false}
{"seq":3,"epoch":102,"task":"other","wake":"ignore $SECRET","verdict":"captain","summary":"unrelated $SECRET","silent":false}
EOF

SESSION_ROOT="$TMP_ROOT/sessions"
SESSION_DIR="$SESSION_ROOT/2000/01/01/session-one"
mkdir -p "$SESSION_DIR"
cat > "$SESSION_DIR/session.jsonl" <<EOF
{"payload":{"record":{"workspace_root":"$WORKTREE"}}}
{"type":"toolResult","name":"exec","isError":true,"content":"$SECRET"}
{"type":"toolResult","name":"exec","isError":true,"content":"$SECRET"}
EOF
cat > "$HOME_FIXTURE/state/$ID.muse-session" <<EOF
sessions_root=$SESSION_ROOT
workspace_root=$WORKTREE
binding_id=fixture-binding
EOF
cat > "$HOME_FIXTURE/state/$ID.muse-session-current" <<EOF
binding_id=fixture-binding
session_log=$SESSION_DIR/session.jsonl
namespace_day=$SESSION_ROOT/2000/01/01
namespace_signature=historical
EOF

snapshot_tree() {
  local root=$1
  (
    cd "$root"
    find . \( -type f -o -type l \) -print | LC_ALL=C sort | while IFS= read -r path; do
      if [ -L "$path" ]; then
        printf 'link %s %s\n' "$path" "$(readlink "$path")"
      else
        printf 'file %s ' "$path"
        cksum "$path"
      fi
    done
  )
}

BEFORE="$TMP_ROOT/before"
AFTER="$TMP_ROOT/after"
OUT1="$TMP_ROOT/out1"
OUT2="$TMP_ROOT/out2"
snapshot_tree "$HOME_FIXTURE" > "$BEFORE.home"
snapshot_tree "$WORKTREE" > "$BEFORE.worktree"

FM_HOME="$HOME_FIXTURE" FM_ROOT_OVERRIDE="$ROOT" \
  FM_FORENSICS_CREW_STATE_BIN="$FAKEBIN/crew-state" \
  "$COLLECTOR" "$ID" > "$OUT1"

snapshot_tree "$HOME_FIXTURE" > "$AFTER.home"
snapshot_tree "$WORKTREE" > "$AFTER.worktree"
cmp -s "$BEFORE.home" "$AFTER.home" \
  || fail "collector changed the Firstmate home"
cmp -s "$BEFORE.worktree" "$AFTER.worktree" \
  || fail "collector changed the isolated copy"
[ ! -e "$HOME_FIXTURE/fsmonitor-hook-ran" ] \
  || fail "collector allowed Git status to execute the isolated copy's fsmonitor hook"

OUT1_TEXT=$(cat "$OUT1")
assert_contains "$OUT1_TEXT" 'schema: fm-forensics-packet.v1' "packet schema missing"
assert_contains "$OUT1_TEXT" 'classification: evidence leads only; no causal conclusion' "lead-only boundary missing"
assert_contains "$OUT1_TEXT" '## Task identity' "task identity section missing"
assert_contains "$OUT1_TEXT" '## Current state' "current state section missing"
assert_contains "$OUT1_TEXT" '## Event history' "event history section missing"
assert_contains "$OUT1_TEXT" '## Backlog' "backlog section missing"
assert_contains "$OUT1_TEXT" '## Instruction acknowledgements' "instruction section missing"
assert_contains "$OUT1_TEXT" '## Process-event results' "process-event section missing"
assert_contains "$OUT1_TEXT" '## Supervision branch outcomes' "branch outcome section missing"
assert_contains "$OUT1_TEXT" '## Isolated-copy Git facts' "Git section missing"
assert_contains "$OUT1_TEXT" '## Ordinary direct-report session errors' "session error section missing"
assert_contains "$OUT1_TEXT" 'state: working' "canonical current state was not collected"
assert_contains "$OUT1_TEXT" 'metadata binding: valid' "valid endpoint identity was not recorded"
assert_contains "$OUT1_TEXT" '[lead] repeated status evidence' "repeated status evidence was not flagged"
assert_contains "$OUT1_TEXT" '[lead] repeated instruction body' "repeated instruction was not flagged"
assert_contains "$OUT1_TEXT" '[lead] repeated process-event result' "repeated process-event result was not flagged"
assert_contains "$OUT1_TEXT" '[lead] repeated supervision outcome payload' "repeated supervision outcome was not flagged"
assert_contains "$OUT1_TEXT" '[lead] repeated session error record' "repeated session error was not flagged"
assert_contains "$OUT1_TEXT" 'errors_in_bounded_tail=2' "session errors were not counted"
assert_contains "$OUT1_TEXT" 'task_matches=2' "backlog matching accepted a partial task id"
if grep -Fq "$SECRET" "$OUT1"; then
  fail "packet exposed captain-private or secret content"
fi

FM_HOME="$HOME_FIXTURE" FM_ROOT_OVERRIDE="$ROOT" \
  FM_FORENSICS_CREW_STATE_BIN="$FAKEBIN/crew-state" \
  "$COLLECTOR" "$ID" > "$OUT2"
cmp -s "$OUT1" "$OUT2" || fail "repeated collection changed the packet or durable records"
pass "forensics collector is repeatable, redacted, and side-effect free"

cp "$HOME_FIXTURE/state/$ID.meta" "$TMP_ROOT/original-meta"
{
  cat "$TMP_ROOT/original-meta"
  awk 'BEGIN { for (i = 1; i <= 20000; i++) printf "x"; print "" }'
} > "$HOME_FIXTURE/state/$ID.meta"
OVERSIZED_OUT="$TMP_ROOT/oversized-out"
FM_HOME="$HOME_FIXTURE" FM_ROOT_OVERRIDE="$ROOT" \
  FM_FORENSICS_CREW_STATE_BIN="$FAKEBIN/crew-state" FM_FORENSICS_SOURCE_BYTES=1024 \
  "$COLLECTOR" "$ID" > "$OVERSIZED_OUT"
OVERSIZED_TEXT=$(cat "$OVERSIZED_OUT")
assert_contains "$OVERSIZED_TEXT" '[lead] task metadata exceeds the trusted parse bound' \
  "oversized metadata was trusted"
assert_not_contains "$OVERSIZED_TEXT" 'metadata binding: valid' \
  "truncated metadata produced a valid endpoint verdict"
cp "$TMP_ROOT/original-meta" "$HOME_FIXTURE/state/$ID.meta"
pass "forensics collector refuses identity claims from truncated metadata"

sed 's/^kind=ship$/kind=secondmate/' "$TMP_ROOT/original-meta" \
  > "$HOME_FIXTURE/state/$ID.meta"
SECONDMATE_OUT="$TMP_ROOT/secondmate-out"
FM_HOME="$HOME_FIXTURE" FM_ROOT_OVERRIDE="$ROOT" \
  FM_FORENSICS_CREW_STATE_BIN="$FAKEBIN/crew-state" \
  "$COLLECTOR" "$ID" > "$SECONDMATE_OUT"
SECONDMATE_TEXT=$(cat "$SECONDMATE_OUT")
assert_contains "$SECONDMATE_TEXT" 'second-mate conversations are outside this collector' \
  "second-mate session boundary was not reported"
assert_not_contains "$SECONDMATE_TEXT" 'errors_in_bounded_tail=' \
  "collector read a second-mate session log"
cp "$TMP_ROOT/original-meta" "$HOME_FIXTURE/state/$ID.meta"
pass "forensics collector excludes second-mate conversations"

sed "s|^workspace_root=.*|workspace_root=$TMP_ROOT/unrelated-workspace|" \
  "$HOME_FIXTURE/state/$ID.muse-session" > "$TMP_ROOT/unrelated-session-binding"
mv "$TMP_ROOT/unrelated-session-binding" "$HOME_FIXTURE/state/$ID.muse-session"
UNRELATED_SESSION_OUT="$TMP_ROOT/unrelated-session-out"
FM_HOME="$HOME_FIXTURE" FM_ROOT_OVERRIDE="$ROOT" \
  FM_FORENSICS_CREW_STATE_BIN="$FAKEBIN/crew-state" \
  "$COLLECTOR" "$ID" > "$UNRELATED_SESSION_OUT"
UNRELATED_SESSION_TEXT=$(cat "$UNRELATED_SESSION_OUT")
assert_contains "$UNRELATED_SESSION_TEXT" 'task-bound session log could not be resolved without guessing' \
  "collector accepted a session log bound to another workspace"
assert_not_contains "$UNRELATED_SESSION_TEXT" 'errors_in_bounded_tail=' \
  "collector read a session log bound to another workspace"
sed "s|^workspace_root=.*|workspace_root=$WORKTREE|" \
  "$HOME_FIXTURE/state/$ID.muse-session" > "$TMP_ROOT/restored-session-binding"
mv "$TMP_ROOT/restored-session-binding" "$HOME_FIXTURE/state/$ID.muse-session"
pass "forensics collector rejects unrelated session logs"

sed "s/^endpoint_task_id=.*/endpoint_task_id=another-task/" \
  "$HOME_FIXTURE/state/$ID.meta" > "$TMP_ROOT/stale-meta"
mv "$TMP_ROOT/stale-meta" "$HOME_FIXTURE/state/$ID.meta"
STALE_OUT="$TMP_ROOT/stale-out"
FM_HOME="$HOME_FIXTURE" FM_ROOT_OVERRIDE="$ROOT" \
  FM_FORENSICS_CREW_STATE_BIN="$FAKEBIN/crew-state" \
  "$COLLECTOR" "$ID" > "$STALE_OUT"
assert_contains "$(cat "$STALE_OUT")" '[lead] stale endpoint identity' "stale endpoint identity was not detected"
pass "forensics collector flags stale endpoint identity without assigning a cause"

MISSING_HOME="$TMP_ROOT/missing-home"
mkdir -p "$MISSING_HOME/state" "$MISSING_HOME/data"
MISSING_OUT="$TMP_ROOT/missing-out"
FM_HOME="$MISSING_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  FM_FORENSICS_CREW_STATE_BIN="$FAKEBIN/crew-state" \
  "$COLLECTOR" missing-task > "$MISSING_OUT"
MISSING_TEXT=$(cat "$MISSING_OUT")
assert_contains "$MISSING_TEXT" '[lead] task metadata missing' "missing metadata was not recorded"
assert_contains "$MISSING_TEXT" '[lead] status history missing' "missing status was not recorded"
assert_contains "$MISSING_TEXT" '[lead] backlog missing' "missing backlog was not recorded"
assert_contains "$MISSING_TEXT" '[lead] recorded isolated copy is missing' "missing isolated copy was not recorded"
pass "forensics collector tolerates missing artifacts"

BOUNDED_OUT="$TMP_ROOT/bounded-out"
FM_HOME="$HOME_FIXTURE" FM_ROOT_OVERRIDE="$ROOT" \
  FM_FORENSICS_CREW_STATE_BIN="$FAKEBIN/crew-state" \
  FM_FORENSICS_MAX_BYTES=1024 FM_FORENSICS_SOURCE_BYTES=1024 \
  FM_FORENSICS_SOURCE_LINES=10 FM_FORENSICS_SCAN_LINES=20 \
  "$COLLECTOR" "$ID" > "$BOUNDED_OUT"
bounded_bytes=$(wc -c < "$BOUNDED_OUT" | tr -d ' ')
[ "$bounded_bytes" -le 1024 ] || fail "packet exceeded its total byte bound: $bounded_bytes"
assert_contains "$(cat "$BOUNDED_OUT")" '[packet truncated at 1024 bytes' "bounded packet did not disclose truncation"
if grep -Fq "$SECRET" "$BOUNDED_OUT"; then
  fail "bounded packet exposed captain-private or secret content"
fi
pass "forensics collector bounds large inputs and total output"

rc=0
FM_HOME="$HOME_FIXTURE" FM_ROOT_OVERRIDE="$ROOT" \
  "$COLLECTOR" ../outside >/dev/null 2>&1 || rc=$?
expect_code 2 "$rc" "collector rejects a path-traversing task id"
pass "forensics collector rejects task ids outside Firstmate's path-safe contract"
