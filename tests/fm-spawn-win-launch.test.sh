#!/usr/bin/env bash
# tests/fm-spawn-win-launch.test.sh - regression tests for the PowerShell-pane
# launch script fm-spawn generates on Windows (MSYS). Two live-hit defects are
# pinned here (2026-08-03): bash invoked directly from PowerShell skips the
# MSYS PATH setup so /usr/bin tools vanish, and `exec VAR=value cmd` treats the
# assignment as the command name.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-win-launch-tests)

SPAWN="$ROOT/bin/fm-spawn.sh"

# --- source-shape assertions: the generator must keep both fixes ------------

test_generator_exports_usr_bin_path() {
  grep -qF 'export PATH="/usr/bin:/bin:$PATH"' "$SPAWN" \
    || fail "launch.sh generator must export /usr/bin into PATH (direct bash from PowerShell skips MSYS PATH setup)"
  pass "generator writes the /usr/bin PATH export into launch.sh"
}

test_generator_execs_through_env() {
  grep -qF "printf 'exec env %s\\n'" "$SPAWN" \
    || fail "launch.sh generator must exec through env (exec cannot take VAR=value prefixes)"
  pass "generator routes exec through env"
}

# --- behavioral contract: a script of the generated shape must run ----------
#
# Reproduces the failure environment: bash launched with a Windows-only PATH
# (what PowerShell hands over) must still resolve cat/env and apply the
# VAR=value prefixes fm-spawn composes into LAUNCH, including empty ones.

test_generated_shape_runs_under_stripped_path() {
  local dir script launch out
  dir="$TMP_ROOT/shape"
  mkdir -p "$dir"
  script="$dir/launch.sh"
  printf 'hello-brief' > "$dir/brief.md"
  launch="FM_TEST_FLAG=false FM_TEST_EMPTY= sh -c 'printf \"%s %s [%s]\" \"\$(cat $dir/brief.md)\" \"\$FM_TEST_FLAG\" \"\$FM_TEST_EMPTY\"'"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'export PATH="/usr/bin:/bin:$PATH"\n'
    printf 'export GOTMPDIR=%s\n' "'$dir/gotmp'"
    printf 'exec env %s\n' "$launch"
  } > "$script"
  chmod +x "$script"
  out=$(env -i PATH='/nonexistent' "$(command -v bash)" "$script" 2>&1) \
    || fail "generated-shape script failed under stripped PATH: $out"
  assert_contains "$out" "hello-brief false []" "brief expansion + env assignments under stripped PATH"
  pass "generated launch.sh shape runs with Windows-only PATH and applies env prefixes"
}

test_generator_exports_usr_bin_path
test_generator_execs_through_env
test_generated_shape_runs_under_stripped_path
