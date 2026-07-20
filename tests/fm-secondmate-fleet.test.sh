#!/usr/bin/env bash
# Behavior tests for bin/fm-secondmate-fleet.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FLEET="$ROOT/bin/fm-secondmate-fleet.sh"
TMP=$(fm_test_tmproot fm-secondmate-fleet)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
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

FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message)
    for arg in "$@"; do
      case "$arg" in
        *pane_id*) printf '%s\n' "can't find window" >&2; exit 1 ;;
        *pane_current_command*) exit 99 ;;
      esac
    done
    ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/tmux"

{
  echo "window=firstmate:fm-alpha-sm"
  echo "kind=secondmate"
  echo "home=$SM_HOME"
} > "$HOME_DIR/state/alpha-sm.meta"

out=$(PATH="$FAKEBIN:$BASE_PATH" "$FLEET" status 2>&1) || fail "status should report a missing endpoint without failing: $out"
assert_contains "$out" "alpha-sm: stopped (recover from the project container with: secondmate <harness>)" \
  "fleet status must classify a missing endpoint as stopped"
pass "fleet status reports a missing endpoint as stopped"

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message)
    for arg in "$@"; do
      case "$arg" in
        *pane_id*) printf '%s\n' 'tmux server query failed' >&2; exit 1 ;;
        *pane_current_command*) exit 99 ;;
      esac
    done
    ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/tmux"

out=$(PATH="$FAKEBIN:$BASE_PATH" "$FLEET" status 2>&1) || fail "status should report an unproven endpoint without failing: $out"
assert_contains "$out" "alpha-sm: unknown (backend: tmux; inspect before recovery)" \
  "fleet status must classify a query failure as unknown"
pass "fleet status reports an endpoint query failure as unknown"

echo "fm-secondmate-fleet: all tests passed"
