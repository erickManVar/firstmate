#!/usr/bin/env bash
# Behavior tests for bin/fm-secondmate-fleet.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FLEET="$ROOT/bin/fm-secondmate-fleet.sh"
TMP=$(fm_test_tmproot fm-secondmate-fleet)
STUB="$TMP/stubroot"
HOME_DIR="$TMP/primary"
SM_HOME="$TMP/projects/alpha/.secondmate"
mkdir -p "$STUB/bin" "$HOME_DIR/state" "$SM_HOME"

cat > "$STUB/bin/fm-home-seed.sh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = routes ]; then
  printf 'alpha-sm\\t%s\\talpha\\n' "$SM_HOME"
  exit 0
fi
exit 2
SH
chmod +x "$STUB/bin/fm-home-seed.sh"

export FM_ROOT_OVERRIDE="$STUB"
export FM_HOME="$HOME_DIR"
export FM_STATE_OVERRIDE="$HOME_DIR/state"

{
  echo "window=firstmate:fm-alpha-sm"
  echo "kind=ship"
  echo "home=$SM_HOME"
} > "$HOME_DIR/state/alpha-sm.meta"

out=$("$FLEET" status 2>&1) || fail "status should report metadata mismatch without failing: $out"
assert_contains "$out" "alpha-sm: metadata mismatch" "fleet status must reject a non-secondmate metadata record"
pass "fleet status validates secondmate metadata identity"

echo "fm-secondmate-fleet: all tests passed"
