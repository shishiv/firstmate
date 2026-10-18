#!/usr/bin/env bash
# Tests for bin/fm-tool-gaps.sh, the session-start report of tools the
# registered projects pin and the fleet's own CLIs that have a newer release.
#
# The project-needs case that matters most is the 2026-10 one: lloegrys-live
# pins luacheck in tools/luacheck.version, the pinned copy lives in
# ~/.luarocks/bin (a `luarocks install --local`), and that directory is on no
# one's PATH, so the project's own ./check finds it while every bare `luacheck`
# call a worker makes fails. test_pinned_copy_off_path_is_reported reproduces
# that shape. Every fixture uses a synthetic tool name, a private HOME, and a
# PATH built without the real fleet CLIs, so no case touches a tool installed on
# this host, and the release lookups read canned replies through the
# FM_TEST_SEAM seam instead of the network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GAPS="$ROOT/bin/fm-tool-gaps.sh"
TMP_ROOT=$(fm_test_tmproot fm-tool-gaps)
TOOL=luacheck-fixture
SANS=$(fm_test_base_path_sans "${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" \
  "$TOOL" treehouse gh-axi tasks-axi lavish-axi kiro-cli pi)

# make_case <name>: a home with one registered project pinning $TOOL 1.2.0.
make_case() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/projects/proj/tools" "$dir/userhome" "$dir/fakebin" "$dir/releases"
  printf '1.2.0\n' > "$dir/home/projects/proj/tools/$TOOL.version"
  printf '%s\n' "$dir"
}

# make_tool <dir> <name> <version-output> [exit-code]
make_tool() {
  mkdir -p "$1"
  cat > "$1/$2" <<SH
#!/usr/bin/env bash
printf '%s\n' '$3'
exit ${4:-0}
SH
  chmod +x "$1/$2"
}

run_gaps() {  # <case-dir> <subcommand>
  PATH="$1/fakebin:$SANS" HOME="$1/userhome" FM_HOME="$1/home" \
    FM_TEST_TOOL_GAPS_RELEASES="$1/releases" bash "$GAPS" "$2"
}

test_pinned_copy_off_path_is_reported() {
  local dir out
  dir=$(make_case off-path)
  make_tool "$dir/userhome/.luarocks/bin" "$TOOL" 'Luacheck: 1.2.0'
  out=$(run_gaps "$dir" project-needs) || fail "project-needs exited non-zero"
  assert_contains "$out" "TOOL_NEED: proj needs $TOOL 1.2.0 (tools/$TOOL.version): $dir/userhome/.luarocks/bin/$TOOL is not on PATH, so a bare \`$TOOL\` call fails" \
    "a pinned copy found only off PATH was not reported"
  assert_contains "$out" "export PATH=\"$dir/userhome/.luarocks/bin:\$PATH\"" \
    "the off-PATH report did not carry the PATH fix"
  [ "$(printf '%s\n' "$out" | grep -c .)" -eq 1 ] || fail "expected exactly one line, got: $out"
  pass "a pinned tool found only in a per-user install directory is reported as off PATH with the fix"
}

test_pinned_copy_on_path_is_silent() {
  local dir out
  dir=$(make_case on-path)
  make_tool "$dir/fakebin" "$TOOL" 'Luacheck: 1.2.0'
  out=$(run_gaps "$dir" project-needs) || fail "project-needs exited non-zero"
  [ -z "$out" ] || fail "a pinned copy on PATH at the pinned version was reported: $out"
  pass "a pinned tool on PATH at the pinned version prints nothing"
}

test_wrong_version_is_reported() {
  local dir out
  dir=$(make_case wrong-version)
  make_tool "$dir/fakebin" "$TOOL" 'Luacheck: 1.2.01'
  out=$(run_gaps "$dir" project-needs) || fail "project-needs exited non-zero"
  assert_contains "$out" "$dir/fakebin/$TOOL reports 1.2.01 (fix: install $TOOL 1.2.0)" \
    "a copy at a version that merely starts with the pin was accepted"
  pass "a copy at another version than the pin is reported with the version it reports"
}

test_missing_tool_is_reported() {
  local dir out
  dir=$(make_case missing)
  out=$(run_gaps "$dir" project-needs) || fail "project-needs exited non-zero"
  assert_contains "$out" "TOOL_NEED: proj needs $TOOL 1.2.0 (tools/$TOOL.version): not installed (fix: install $TOOL 1.2.0 and put it on PATH)" \
    "a pinned tool found nowhere was not reported as not installed"
  pass "a pinned tool found nowhere is reported as not installed"
}

test_unusable_tool_is_reported() {
  local dir out
  dir=$(make_case unusable)
  make_tool "$dir/fakebin" "$TOOL" 'lua: module not found' 1
  out=$(run_gaps "$dir" project-needs) || fail "project-needs exited non-zero"
  assert_contains "$out" "$dir/fakebin/$TOOL --version failed (fix: reinstall $TOOL 1.2.0)" \
    "a copy whose --version fails was not reported as unusable"
  pass "a copy whose --version fails is reported as unusable"
}

test_malformed_pin_files_are_ignored() {
  local dir out
  dir=$(make_case malformed)
  rm -f "$dir/home/projects/proj/tools/$TOOL.version"
  printf '1.0\n' > "$dir/home/projects/proj/tools/-rf.version"
  printf 'not a version\n' > "$dir/home/projects/proj/tools/$TOOL.version"
  out=$(run_gaps "$dir" project-needs) || fail "project-needs exited non-zero"
  [ -z "$out" ] || fail "a malformed tool name or pin produced a report: $out"
  pass "pin files with an unsafe tool name or an unreadable pin are ignored"
}

# Canned release replies keyed the way fm-tool-gaps.sh's test seam reads them.
canned() {  # <case-dir> <url> <json>
  local name=${2//\//_}
  printf '%s\n' "$3" > "$1/releases/${name//:/_}"
}

test_newer_fleet_cli_releases_are_reported_in_table_order() {
  local dir out
  dir=$(make_case cli-updates)
  make_tool "$dir/fakebin" treehouse 'v3.1.3'
  make_tool "$dir/fakebin" gh-axi '0.1.42'
  make_tool "$dir/fakebin" lavish-axi '0.1.80'
  make_tool "$dir/fakebin" kiro-cli 'kiro-cli 2.32.0'
  make_tool "$dir/fakebin" pi '1.2.0'
  canned "$dir" https://api.github.com/repos/kunchenguid/treehouse/releases/latest '{"tag_name":"v3.1.4"}'
  canned "$dir" https://registry.npmjs.org/gh-axi/latest '{"version":"0.1.42"}'
  canned "$dir" https://registry.npmjs.org/lavish-axi/latest '{"version":"0.1.9"}'
  canned "$dir" https://prod.download.cli.kiro.dev/stable/latest/manifest.json '{"version":"2.33.0"}'
  canned "$dir" https://registry.npmjs.org/@earendil-works/pi-coding-agent/latest 'not json'
  out=$(run_gaps "$dir" cli-updates) || fail "cli-updates exited non-zero"
  assert_equals "TOOL_UPDATE: treehouse 3.1.3 -> 3.1.4 available (update: treehouse update)
TOOL_UPDATE: kiro-cli 2.32.0 -> 2.33.0 available (update: kiro-cli update --non-interactive)" "$out" \
    "cli-updates did not report exactly the CLIs with a newer release, in table order"
  pass "only fleet CLIs whose published release is newer are reported; current, older, absent, and unreadable ones stay quiet"
}

test_cli_updates_without_any_reply_are_silent() {
  local dir out
  dir=$(make_case cli-offline)
  make_tool "$dir/fakebin" gh-axi '0.1.35'
  out=$(PATH="$dir/fakebin:$SANS" HOME="$dir/userhome" FM_HOME="$dir/home" bash "$GAPS" cli-updates) \
    || fail "cli-updates exited non-zero"
  [ -z "$out" ] || fail "a lookup with no reply produced a report: $out"
  pass "a release lookup that cannot answer prints nothing"
}

test_bootstrap_relays_project_needs_on_the_local_pass() {
  local dir out
  dir=$(make_case bootstrap)
  make_tool "$dir/userhome/.luarocks/bin" "$TOOL" 'Luacheck: 1.2.0'
  out=$(PATH="$dir/fakebin:$SANS" HOME="$dir/userhome" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/home" \
    FM_BOOTSTRAP_NETWORK=skip FM_BOOTSTRAP_DETECT_ONLY=1 bash "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "TOOL_NEED: proj needs $TOOL 1.2.0 (tools/$TOOL.version): $dir/userhome/.luarocks/bin/$TOOL is not on PATH" \
    "bootstrap's local pass did not relay the project tool gap"
  pass "bootstrap's local pass relays TOOL_NEED lines"
}

test_pinned_copy_off_path_is_reported
test_pinned_copy_on_path_is_silent
test_wrong_version_is_reported
test_missing_tool_is_reported
test_unusable_tool_is_reported
test_malformed_pin_files_are_ignored
test_newer_fleet_cli_releases_are_reported_in_table_order
test_cli_updates_without_any_reply_are_silent
test_bootstrap_relays_project_needs_on_the_local_pass
