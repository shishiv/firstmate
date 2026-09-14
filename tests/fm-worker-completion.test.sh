#!/usr/bin/env bash
# Exercise the spawned Pi worker extension without a model, using real files.
set -eu
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-worker-completion)
for harness in pi pi-signed; do
  home="$TMP_ROOT/$harness/home"
  proj="$TMP_ROOT/$harness/project"
  wt="$TMP_ROOT/$harness/wt"
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/$harness/fake" "$harness")
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" completion-test
  fm_test_spawn_brief "$home" completion 'Fix empty input and add its regression.'
  printf '\n# Definition of done\nCommit the fix and regression, pass tests and lint, open a PR and wait for passing CI.\n' >> "$home/data/completion/brief.md"
  spawn_out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" completion "$proj" --mode no-mistakes --yolo off) \
    || fail "$harness fixture spawn failed: $spawn_out"
  node "$ROOT/tests/fm-worker-completion.mjs" "$home" "$ROOT"
  pass "$harness worker completion recovery behavioral contract"
done
