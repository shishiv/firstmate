#!/usr/bin/env bash
# Opt-in real Pi-family completion recovery, serial and credentialed. Exercises
# installed pi and pi-signed, names absent identities, and refuses a vacuous pass.
# FM_PI_COMPLETION_MODEL optionally pins a model; otherwise Pi's default is used.
# FM_PI_COMPLETION_EVIDENCE_DIR retains transcripts/receipts outside the temp lab.
set -eu
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_live_gate opt-in FM_PI_COMPLETION_LIVE node timeout
TMP_ROOT=$(fm_test_tmproot fm-worker-completion-live)
checked=0
for harness in pi pi-signed; do
  if ! command -v "$harness" >/dev/null 2>&1; then
    printf 'absent - %s (completion live guard)\n' "$harness"
    continue
  fi
  executable=$(command -v "$harness")
  version=$("$executable" --version)
  printf 'testing - %s %s\n' "$harness" "$version"
  for outcome in complete incomplete; do
    lab="$TMP_ROOT/$harness-$outcome"
    home="$lab/home"
    proj="$lab/project"
    wt="$lab/wt"
    fakebin=$(make_spawn_fakebin "$lab/fake" "$harness")
    fm_test_spawn_home "$home" "$harness"
    fm_git_worktree "$proj" "$wt" "completion-$harness-$outcome"
    fm_test_spawn_brief "$home" completion 'Read measurements.csv and write report.md with row count, total and arithmetic mean. State the figures and the report path in the final answer.'
    printf '\n# Definition of done\nThe report must exist and correctly record count=3, total=42, mean=14. No commit or PR is required.\n' >> "$home/data/completion/brief.md"
    if [ "$outcome" = incomplete ]; then
      printf '\nAdditional delivery requirement: a reviewed and published PR with passing CI is mandatory. This fixture cannot publish; report that missing requirement in your final answer rather than trying to publish.\n' >> "$home/data/completion/brief.md"
    fi
    printf '\n# Diagnostic fixture\nDo not append any status events; this fixture exercises a missing explicit terminal event. Do not alter the brief.\n' >> "$home/data/completion/brief.md"
    spawn_out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" completion "$proj" --scout) \
      || fail "$harness $version fixture spawn failed: $spawn_out"
    printf 'value\n10\n14\n18\n' > "$wt/measurements.csv"
    printf 'working: analyzing measurements\n' > "$home/state/completion.status"
    model_args=()
    if [ -n "${FM_PI_COMPLETION_MODEL:-}" ]; then model_args=(--model "$FM_PI_COMPLETION_MODEL"); fi
    # The production-generated hook is loaded unchanged. Only the terminal
    # provider is a fixture; all model requests and Pi callbacks here are real.
    run_status=0
    (cd "$wt" && timeout 180 "$executable" --print --mode json --approve \
      --no-extensions --no-context-files --no-skills --no-prompt-templates \
      --session-dir "$lab/sessions" --tools read,write --thinking low \
      -e "$home/state/completion.pi-ext.ts" "${model_args[@]}" \
      "Read $home/data/completion/brief.md and carry out its task. Keep your final answer concise.") > "$lab/transcript.jsonl" 2> "$lab/stderr.log" || run_status=$?
    if [ -n "${FM_PI_COMPLETION_EVIDENCE_DIR:-}" ]; then
      evidence="$FM_PI_COMPLETION_EVIDENCE_DIR/$harness-$outcome"
      mkdir -p "$evidence"
      cp "$lab/transcript.jsonl" "$lab/stderr.log" "$evidence/"
      for artifact in "$lab/sessions" "$home/data/completion/completion" "$home/state/completion.status" "$wt/report.md"; do
        if [ -e "$artifact" ]; then cp -R "$artifact" "$evidence/"; fi
      done
    fi
    [ "$run_status" -eq 0 ] || fail "$harness $version completion run exited $run_status"
    node "$ROOT/tests/fm-worker-completion-live.mjs" "$lab" "$outcome" \
      || fail "$harness $version completion assertions failed"
    printf 'ok - %s %s %s: same-session assessment, normal status, no recursion\n' "$harness" "$version" "$outcome"
  done
  checked=$((checked + 1))
done
[ "$checked" -gt 0 ] || fail 'neither pi nor pi-signed is installed; no completion callback was tested'
