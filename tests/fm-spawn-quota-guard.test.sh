#!/usr/bin/env bash
# Behavior tests for bin/fm-spawn.sh's launch quota guard and post-launch
# provider watch (the header sections "Launch quota guard" and "Post-launch
# provider watch" own the contract).
#
# The guard runs against a fake quota-axi that prints a fixture snapshot, so
# every case pins the exact quota evidence it decides on. The watch runs
# against a fake tmux whose capture-pane prints a fixture pane tail, and the
# Pi cases settle the task's busy record exactly as the Pi extension does after
# a provider error (verified live, docs/verification/runtime-backends.md
# "Provider-limit launch failure").
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-quota-guard)
unset LAVISH_AXI_HOST
# tests/lib.sh turns both features off for every other suite.
unset FM_SPAWN_QUOTA_GUARD FM_SPAWN_PROVIDER_WATCH_SECS
GO_ERROR='Error: 429: {"type":"GoUsageLimitError","message":"Go usage limit exceeded"}'

make_case_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_test_make_spawn_fakebin "$dir")
  mv "$fakebin/tmux" "$fakebin/tmux-base"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = capture-pane ]; then
  # Settle the busy record the way the Pi extension's agent_settled does,
  # once, before the first pane read that shows the provider error.
  if [ -n "${FM_FAKE_SETTLE_ID:-}" ] && [ ! -e "$FM_FAKE_SETTLE_STATE/.fake-settled" ]; then
    gen=$(cat "$FM_FAKE_SETTLE_STATE/$FM_FAKE_SETTLE_ID.busy-gen")
    "$FM_FAKE_ROOT/bin/fm-busy-event.sh" apply "$FM_FAKE_SETTLE_STATE" "$FM_FAKE_SETTLE_ID" idle \
      --gen "$gen" --source pi-ext --event agent-settled >/dev/null 2>&1
    : > "$FM_FAKE_SETTLE_STATE/.fake-settled"
  fi
  [ -z "${FM_FAKE_PANE_TAIL:-}" ] || cat "$FM_FAKE_PANE_TAIL"
  exit 0
fi
exec "$(dirname "$0")/tmux-base" "$@"
SH
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_QUOTA_LOG:-/dev/null}"
[ "${FM_FAKE_QUOTA_STATUS:-0}" -eq 0 ] || exit "$FM_FAKE_QUOTA_STATUS"
cat "$FM_FAKE_QUOTA_JSON"
SH
  cat > "$fakebin/pi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --help ] || printf '%s\n' 'Pi 1.3.0' 'Options: --help --tui-mode <mode> --approve'
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/quota-axi" "$fakebin/pi"
  printf '%s\n' "$fakebin"
}

# new_case <name> <id> [brief-intent]: sets CASE HOME_DIR PROJ WT FAKEBIN.
new_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  PROJ="$CASE/project"
  WT="$CASE/wt"
  FAKEBIN=$(make_case_fakebin "$CASE/fake")
  fm_test_spawn_home "$HOME_DIR" claude
  fm_git_worktree "$PROJ" "$WT" "wt-$1"
  fm_test_spawn_brief "$HOME_DIR" "$2" "${3:-brief for $2}"
  : > "$CASE/launch.log"
  : > "$CASE/quota.log"
  printf '%s\n' '{"schemaVersion":5,"providers":[]}' > "$CASE/quota.json"
}

# snapshot <provider> <scope-status> <percent> <runway> [accountKey]: one
# provider row in the shape quota-axi --json prints.
quota_row() {
  local provider=$1 status=$2 pct=$3 runway=$4 account=${5:-}
  jq -cn --arg p "$provider" --arg s "$status" --argjson pct "$pct" --arg r "$runway" --arg a "$account" '
    {provider: $p,
     windows: [{id: "monthly", resetsAt: "2026-11-01T07:20:20.000Z"}],
     quotaSemantics: {status: $s, effectiveAvailability: [
       if $s == "unknown" then {scope: "all_models", status: "unknown", runway: {status: "unknown"}}
       else {scope: "all_models", status: "known", effectivePercentRemaining: $pct,
             limitingWindowIds: ["monthly"], runway: {status: $r, limitingWindowId: "monthly"}}
       end]}}
    + (if $a == "" then {} else {accountKey: $a} end)'
}

write_snapshot() {  # <schema> <row-json>...
  local schema=$1
  shift
  printf '%s\n' "$@" | jq -s --argjson v "$schema" '{schemaVersion: $v, providers: .}' > "$CASE/quota.json"
}

run_case_spawn() {
  FM_FAKE_LAUNCH_LOG="$CASE/launch.log" FM_FAKE_QUOTA_LOG="$CASE/quota.log" \
    FM_FAKE_QUOTA_JSON="$CASE/quota.json" FM_FAKE_ROOT="$ROOT" \
    FM_SPAWN_PROVIDER_WATCH_SECS="${WATCH_SECS:-0}" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$@"
}

ship() {  # <id> [extra args...]
  local id=$1
  shift
  run_case_spawn "$id" "$PROJ" --mode direct-PR --yolo off "$@"
}

test_exhausted_single_provider_refuses_before_anything_exists() {
  local id=quota-exhausted-q1 out rc
  new_case exhausted "$id"
  write_snapshot 5 "$(quota_row claude known 0 exhausted_now)"
  out=$(ship "$id" --harness claude)
  rc=$?
  expect_code 1 "$rc" "an exhausted provider must refuse the spawn: $out"
  assert_contains "$out" "provider=claude scope=all_models reason=exhausted_now resets=2026-11-01T07:20:20.000Z" \
    "the refusal must name the provider, scope, and reset"
  assert_contains "$out" "--allow-exhausted-quota" "the refusal must name the override"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must not leave a task record"
  [ ! -s "$CASE/launch.log" ] || fail "a refused spawn must not launch anything: $(cat "$CASE/launch.log")"
  grep -qx -- '--json --provider claude' "$CASE/quota.log" || fail "the guard must read one provider: $(cat "$CASE/quota.log")"
  pass "an exhausted single-provider row refuses before any endpoint, record, or launch"
}

test_zero_percent_remaining_refuses() {
  local id=quota-zero-q1 out rc
  new_case zero "$id"
  write_snapshot 5 "$(quota_row claude known 0 through_reset)"
  out=$(ship "$id" --harness claude)
  rc=$?
  expect_code 1 "$rc" "0 percent remaining must refuse the spawn: $out"
  assert_contains "$out" "reason=0% remaining" "the refusal must say 0 percent remains"
  pass "a known 0 percent row refuses even when its runway reads through_reset"
}

test_override_launches_with_warning() {
  local id=quota-override-q1 out rc
  new_case override "$id"
  write_snapshot 5 "$(quota_row claude known 0 exhausted_now)"
  out=$(ship "$id" --harness claude --allow-exhausted-quota)
  rc=$?
  expect_code 0 "$rc" "the override must launch: $out"
  assert_contains "$out" "spawned $id harness=claude" "the override must report the spawn"
  assert_contains "$out" "because --allow-exhausted-quota was passed" "the override must warn"
  pass "--allow-exhausted-quota launches on an exhausted provider with a warning"
}

test_override_is_refused_on_secondmate_and_relaunch() {
  local out rc
  new_case override-scope quota-override-scope-q1
  out=$(run_case_spawn quota-override-scope-q1 --secondmate --allow-exhausted-quota)
  rc=$?
  [ "$rc" -ne 0 ] || fail "--allow-exhausted-quota must be refused on a secondmate spawn"
  assert_contains "$out" "applies only to a fresh ship or scout spawn" "secondmate refusal must explain the scope"
  out=$(run_case_spawn quota-override-scope-q1 --relaunch --allow-exhausted-quota)
  rc=$?
  [ "$rc" -ne 0 ] || fail "--allow-exhausted-quota must be refused on a relaunch"
  assert_contains "$out" "applies only to a fresh ship or scout spawn" "relaunch refusal must explain the scope"
  pass "--allow-exhausted-quota is refused where no launch quota check runs"
}

# The 2026-10-20 incident shape: pi on an opencode-go model whose profile
# declares the quota-axi provider.
test_declared_pi_provider_refuses_exhausted_opencode_go() {
  local id=quota-pi-declared-q1 out rc
  new_case pi-declared "$id"
  printf '%s\n' '{"rules":[],"default":[{"harness":"pi","model":"opencode-go/deepseek-v4.1-flash","provider":"opencode-go"}]}' \
    > "$HOME_DIR/config/crew-dispatch.json"
  write_snapshot 5 "$(quota_row opencode-go known 0 exhausted_now)"
  out=$(ship "$id" --harness pi --model opencode-go/deepseek-v4.1-flash)
  rc=$?
  expect_code 1 "$rc" "an exhausted declared provider must refuse a pi spawn: $out"
  assert_contains "$out" "provider=opencode-go scope=all_models" "the refusal must name opencode-go"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused pi spawn must not leave a task record"
  pass "a pi profile that declares its provider refuses on that provider's exhausted row"
}

test_undeclared_pi_provider_stays_eligible() {
  local id=quota-pi-undeclared-q1 out rc
  new_case pi-undeclared "$id"
  printf '%s\n' '{"rules":[],"default":[{"harness":"pi","model":"opencode-go/deepseek-v4.1-flash"}]}' \
    > "$HOME_DIR/config/crew-dispatch.json"
  write_snapshot 5 "$(quota_row opencode-go known 0 exhausted_now)"
  out=$(ship "$id" --harness pi --model opencode-go/deepseek-v4.1-flash)
  rc=$?
  expect_code 0 "$rc" "an unbound pi candidate must launch: $out"
  [ ! -s "$CASE/quota.log" ] || fail "an unbound candidate must not read quota: $(cat "$CASE/quota.log")"
  pass "a pi candidate with no declared provider is unbound, never inferred from its model name"
}

test_schema6_pi_lane_binds_its_own_account() {
  local id=quota-lane-q1 out rc
  new_case lane "$id"
  printf '%s\n' '{"rules":[],"default":[{"harness":"pi","model":"openai-codex-work/gpt-5.6","provider":"codex"},{"harness":"pi","model":"openai-codex/gpt-5.6","provider":"codex"}]}' \
    > "$HOME_DIR/config/crew-dispatch.json"
  write_snapshot 6 "$(quota_row codex known 0 exhausted_now openai-codex-work)" "$(quota_row codex known 80 through_reset default)"
  out=$(ship "$id" --harness pi --model openai-codex-work/gpt-5.6)
  rc=$?
  expect_code 1 "$rc" "the exhausted work account must refuse its own lane: $out"
  fm_test_spawn_brief "$HOME_DIR" quota-lane-q2
  out=$(ship quota-lane-q2 --harness pi --model openai-codex/gpt-5.6)
  rc=$?
  expect_code 0 "$rc" "another lane must bind the healthy default row: $out"
  pass "a schema 6 snapshot binds each Pi lane to its own account row"
}

test_unknown_row_launches() {
  local id=quota-unknown-q1 out rc
  new_case unknown "$id"
  write_snapshot 5 "$(quota_row claude unknown 0 unknown)"
  out=$(ship "$id" --harness claude)
  rc=$?
  expect_code 0 "$rc" "an unknown row must launch: $out"
  assert_not_contains "$out" "quota-axi" "an unknown row is disclosed uncertainty, not a quota warning"
  pass "an unknown quota row stays eligible"
}

test_failed_quota_axi_warns_and_launches() {
  local id=quota-fails-q1 out rc
  new_case fails "$id"
  out=$(FM_FAKE_QUOTA_STATUS=1 ship "$id" --harness claude)
  rc=$?
  expect_code 0 "$rc" "a failing quota-axi must not block: $out"
  assert_contains "$out" "no usable quota snapshot" "a failing quota-axi must warn"
  pass "a failing quota-axi warns and launches"
}

test_missing_quota_axi_warns_and_launches() {
  local id=quota-missing-q1 out rc base
  new_case missing "$id"
  rm -f "$FAKEBIN/quota-axi"
  base=$(fm_test_base_path_sans "$PATH" quota-axi) || fail "could not build a PATH without quota-axi"
  out=$(PATH="$base" ship "$id" --harness claude)
  rc=$?
  expect_code 0 "$rc" "a missing quota-axi must not block: $out"
  assert_contains "$out" "quota-axi is not installed" "a missing quota-axi must warn"
  pass "a missing quota-axi warns and launches"
}

# --- post-launch provider watch ----------------------------------------------

test_pi_provider_error_after_launch_reports_failed_start() {
  local id=watch-pi-q1 out rc
  new_case watch-pi "$id"
  printf '%s\n' ' Ponytail loaded: full' ' Read the brief.' " $GO_ERROR" \
    ' If this looks like a pi bug, /bug sends a report to the developers.' '────' '(opencode-go) deepseek-v4.1-flash' \
    > "$CASE/pane.txt"
  out=$(WATCH_SECS=5 FM_FAKE_PANE_TAIL="$CASE/pane.txt" FM_FAKE_SETTLE_ID="$id" \
    FM_FAKE_SETTLE_STATE="$HOME_DIR/state" ship "$id" --harness pi --model opencode-go/deepseek-v4.1-flash)
  rc=$?
  expect_code 3 "$rc" "a provider error after launch must exit 3: $out"
  assert_contains "$out" "worker failed to start" "the spawn must report a failed start"
  assert_contains "$out" "$GO_ERROR" "the report must carry the pane evidence"
  assert_contains "$out" "bin/fm-control.sh $id relaunch --harness" "the report must name the recovery"
  assert_not_contains "$out" "spawned $id" "a failed start must not print the success line"
  assert_present "$HOME_DIR/state/$id.meta" "the task record must be kept for relaunch"
  [ -d "$WT" ] || fail "the local copy must be kept"
  grep -q "^failed \[at=[0-9]*\]: worker failed to start: .*GoUsageLimitError" "$HOME_DIR/state/$id.status" \
    || fail "the status file must record the failed start: $(cat "$HOME_DIR/state/$id.status" 2>/dev/null)"
  pass "a Pi worker whose turn settles on a provider limit is reported as a failed start, record kept"
}

# A worker still busy - here a brief that quotes the error, rendered while the
# turn runs - never matches, however its pane looks.
test_busy_worker_quoting_the_error_is_not_a_failed_start() {
  local id=watch-busy-q1 out rc
  new_case watch-busy "$id"
  printf '%s\n' ' Read the brief.' " $GO_ERROR" ' Working...' > "$CASE/pane.txt"
  out=$(WATCH_SECS=1 FM_FAKE_PANE_TAIL="$CASE/pane.txt" ship "$id" --harness pi --model opencode-go/deepseek-v4.1-flash)
  rc=$?
  expect_code 0 "$rc" "a busy worker must not read as a failed start: $out"
  assert_contains "$out" "spawned $id harness=pi" "the spawn must succeed"
  pass "a busy Pi worker whose pane shows the error text is still a successful spawn"
}

# Codex has no verified semantic busy source, so the rendered error must also
# not be a verbatim line of the brief it was launched with.
test_no_semantic_source_needs_line_outside_the_brief() {
  local id=watch-codex-q1 out rc
  new_case watch-codex "$id"
  printf '%s\n' '› Do the task.' "■ stream error: exceeded retry limit, last status: 429 Too Many Requests" > "$CASE/pane.txt"
  out=$(WATCH_SECS=5 FM_FAKE_PANE_TAIL="$CASE/pane.txt" ship "$id" --harness codex)
  rc=$?
  expect_code 3 "$rc" "a codex provider error outside the brief must exit 3: $out"
  assert_contains "$out" "429 Too Many Requests" "the report must carry the codex evidence"

  fm_test_spawn_brief "$HOME_DIR" watch-codex-q2 "The last run printed $GO_ERROR before stopping."
  printf '%s\n' '› The last run printed' "$GO_ERROR before stopping." > "$CASE/pane.txt"
  out=$(WATCH_SECS=1 FM_FAKE_PANE_TAIL="$CASE/pane.txt" ship watch-codex-q2 --harness codex)
  rc=$?
  expect_code 0 "$rc" "a codex pane rendering its own brief's quote must not fail: $out"
  pass "without a semantic busy source, an error line quoted in the brief is not a failed start"
}

test_watch_disabled_and_clean_pane_succeed() {
  local id=watch-clean-q1 out rc
  new_case watch-clean "$id"
  printf '%s\n' ' Read the brief.' ' Reading files...' > "$CASE/pane.txt"
  out=$(WATCH_SECS=1 FM_FAKE_PANE_TAIL="$CASE/pane.txt" ship "$id" --harness pi --model opencode-go/deepseek-v4.1-flash)
  rc=$?
  expect_code 0 "$rc" "a clean pane must succeed: $out"
  printf '%s\n' " $GO_ERROR" > "$CASE/pane.txt"
  fm_test_spawn_brief "$HOME_DIR" watch-clean-q2
  out=$(WATCH_SECS=0 FM_FAKE_PANE_TAIL="$CASE/pane.txt" FM_FAKE_SETTLE_ID=watch-clean-q2 \
    FM_FAKE_SETTLE_STATE="$HOME_DIR/state" ship watch-clean-q2 --harness pi --model opencode-go/deepseek-v4.1-flash)
  rc=$?
  expect_code 0 "$rc" "FM_SPAWN_PROVIDER_WATCH_SECS=0 must skip the watch: $out"
  pass "a clean pane succeeds and a zero watch window skips the watch"
}

# --- the classifier on its own ----------------------------------------------

test_provider_limit_signatures() {
  local line
  # shellcheck source=bin/fm-busy-lib.sh
  . "$ROOT/bin/fm-busy-lib.sh"
  for line in "$GO_ERROR" \
    'Usage limit reached' \
    "You've reached your monthly usage limit. Please return next month to continue building." \
    '{"type":"error","error":{"type":"rate_limit_error","message":"..."}}' \
    'insufficient_quota: You exceeded your current quota'; do
    printf 'banner\n%s\nfooter\n' "$line" | fm_busy_provider_limit_line >/dev/null \
      || fail "the provider-limit table must match: $line"
  done
  for line in 'All 429 tests passed.' 'Updated the rate limiter docs.' 'usage: fm-spawn.sh <task-id>'; do
    if printf '%s\n' "$line" | fm_busy_provider_limit_line >/dev/null; then
      fail "ordinary output must not match the provider-limit table: $line"
    fi
  done
  pass "the provider-limit table matches the observed vendor errors and not ordinary prose"
}

test_exhausted_single_provider_refuses_before_anything_exists
test_zero_percent_remaining_refuses
test_override_launches_with_warning
test_override_is_refused_on_secondmate_and_relaunch
test_declared_pi_provider_refuses_exhausted_opencode_go
test_undeclared_pi_provider_stays_eligible
test_schema6_pi_lane_binds_its_own_account
test_unknown_row_launches
test_failed_quota_axi_warns_and_launches
test_missing_quota_axi_warns_and_launches
test_pi_provider_error_after_launch_reports_failed_start
test_busy_worker_quoting_the_error_is_not_a_failed_start
test_no_semantic_source_needs_line_outside_the_brief
test_watch_disabled_and_clean_pane_succeed
test_provider_limit_signatures

echo "# all fm-spawn-quota-guard tests passed"
