#!/usr/bin/env bash
# Behavior tests for bin/firstmate + bin/fm-primary-entry.sh, the captain's
# primary entry command.
#
# The launcher anchors to its own script's repo root, so the suite copies both
# scripts into a stub root and shadows claude/codex with fake recorders on
# PATH; no real harness session is ever launched or spent. Covers root
# anchoring, default resume command construction, fresh-mode prompt
# construction, verbatim option forwarding with the `--` escape, invalid
# input, and no-prior-session diagnostics.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-primary-entry)
mkdir -p "$TMP/stubroot/bin"
STUB=$(cd "$TMP/stubroot" && pwd)
cp "$ROOT/bin/firstmate" "$ROOT/bin/fm-primary-entry.sh" "$STUB/bin/"

FAKEBIN=$(fm_fakebin "$TMP")
for harness in claude codex; do
  cat > "$FAKEBIN/$harness" <<'SH'
#!/usr/bin/env bash
{
  printf 'pwd=%s\n' "$PWD"
  for a in "$@"; do printf 'arg=%s\n' "$a"; done
} > "$FM_FAKE_LOG"
exit "${FM_FAKE_HARNESS_RC:-0}"
SH
  chmod +x "$FAKEBIN/$harness"
done
export FM_FAKE_LOG="$TMP/harness.log"

# run_entry <expected-rc> <label> [args...]: run the stub launcher from a
# neutral cwd with the fakes shadowing real harnesses; fills OUT/ERR.
run_entry() {
  local expected=$1 label=$2 rc
  shift 2
  : > "$FM_FAKE_LOG"
  OUT=$(cd "$TMP" && PATH="$FAKEBIN:$PATH" "$STUB/bin/firstmate" "$@" 2>"$TMP/err")
  rc=$?
  ERR=$(cat "$TMP/err")
  expect_code "$expected" "$rc" "$label"
}

# --- invalid input ----------------------------------------------------------

run_entry 2 "no arguments exits 2"
assert_contains "$ERR" "usage: firstmate" "no arguments prints usage on stderr"
pass "no arguments fails with usage"

run_entry 0 "--help exits 0" --help
assert_contains "$OUT" "--new" "--help documents --new"
assert_contains "$OUT" "usage: firstmate" "--help prints usage"
pass "--help prints usage and exits 0"

run_entry 2 "unknown harness exits 2" grok
assert_contains "$ERR" "unknown harness 'grok'" "unknown harness is named"
assert_contains "$ERR" "claude, codex" "supported harnesses are listed"
pass "unknown harness fails clearly"

run_entry 2 "flag before harness exits 2" --new claude
assert_contains "$ERR" "expected a harness name first" "flag-first misuse is explained"
pass "firstmate flag before the harness fails clearly"

# A PATH with no claude anywhere (not even the real one) proves the launcher
# fails before any launch attempt.
NOCLAUDE=$(fm_fakebin "$TMP/noclaude")
cp "$FAKEBIN/codex" "$NOCLAUDE/"
OUT=$(cd "$TMP" && PATH="$NOCLAUDE:/usr/bin:/bin" "$STUB/bin/firstmate" claude 2>"$TMP/err"); rc=$?
ERR=$(cat "$TMP/err")
expect_code 127 "$rc" "missing harness binary exits 127"
assert_contains "$ERR" "not found on PATH" "missing harness binary is diagnosed"
pass "missing harness binary fails before any launch"

# --- root anchoring and default resume construction --------------------------

run_entry 0 "claude default mode" claude
assert_grep "pwd=$STUB" "$FM_FAKE_LOG" "claude launches from the stub repo root, not the caller cwd"
[ "$(sed -n 's/^arg=//p' "$FM_FAKE_LOG" | tr '\n' ' ')" = "--continue --model claude-fable-5 --effort medium " ] \
  || fail "claude resume is exactly '--continue' plus the recommended coordinator posture pair"
pass "claude default mode anchors to the repo root, resumes natively, and defaults to the Fable 5 medium posture"

run_entry 0 "codex default mode" codex
assert_grep "pwd=$STUB" "$FM_FAKE_LOG" "codex launches from the stub repo root"
[ "$(sed -n 's/^arg=//p' "$FM_FAKE_LOG" | tr '\n' ' ')" = "resume --last --yolo " ] \
  || fail "codex resume command is exactly 'resume --last --yolo'"
pass "codex default mode resumes natively with the --yolo posture"

# --- option forwarding --------------------------------------------------------

run_entry 0 "claude forwarding" claude --model opus --effort high
[ "$(sed -n 's/^arg=//p' "$FM_FAKE_LOG" | tr '\n' ' ')" = "--continue --model opus --effort high " ] \
  || fail "claude forwards model/effort arguments verbatim after --continue"
pass "documented harness arguments forward verbatim in order"

# Coordinator posture injection is all-or-nothing: supplying either axis
# disables the pair, so an explicit override never gains a companion flag.
run_entry 0 "claude model-only override" claude --model opus
[ "$(sed -n 's/^arg=//p' "$FM_FAKE_LOG" | tr '\n' ' ')" = "--continue --model opus " ] \
  || fail "an explicit --model must disable the whole posture injection"
pass "an explicit --model disables the default posture pair"

run_entry 0 "claude effort-only override (equals form)" claude --effort=high
[ "$(sed -n 's/^arg=//p' "$FM_FAKE_LOG" | tr '\n' ' ')" = "--continue --effort=high " ] \
  || fail "an explicit --effort=<v> must disable the whole posture injection"
pass "an explicit --effort disables the default posture pair"

run_entry 0 "-- escape" claude -- --new
[ "$(sed -n 's/^arg=//p' "$FM_FAKE_LOG" | tr '\n' ' ')" = "--continue --new --model claude-fable-5 --effort medium " ] \
  || fail "-- forwards a would-be firstmate flag to the harness (posture pair still appended)"
pass "-- stops firstmate's own flag scan"

run_entry 0 "quoted forwarding" claude -- "space value"
grep -qx 'arg=space value' "$FM_FAKE_LOG" || fail "a quoted forwarded argument must remain one argument"
[ "$(grep -c '^arg=space$\|^arg=value$' "$FM_FAKE_LOG")" -eq 0 ] || fail "a quoted forwarded argument must not split"
pass "quoted harness arguments forward as one element"

# --- fresh mode ---------------------------------------------------------------

run_entry 0 "claude --new" claude --new
assert_no_grep "arg=--continue" "$FM_FAKE_LOG" "fresh mode does not resume"
assert_no_grep "dangerously-skip-permissions" "$FM_FAKE_LOG" "no hardcoded claude bypass permissions"
assert_grep "arg=--model" "$FM_FAKE_LOG" "fresh mode still defaults to the coordinator posture"
assert_grep "fm-session-start.sh" "$FM_FAKE_LOG" "fresh prompt requests the mandatory session start"
assert_grep "recap" "$FM_FAKE_LOG" "fresh prompt requests a captain recap"
sed -n 's/^arg=//p' "$FM_FAKE_LOG" | tail -1 | grep -q "fm-session-start.sh" \
  || fail "claude fresh prompt must stay the final positional argument after the posture pair"
pass "claude --new starts fresh with the recovery/recap prompt, the posture pair, and no bypass flag"

run_entry 0 "codex --new with forwarding" codex --new -m gpt-5.5
args=$(sed -n 's/^arg=//p' "$FM_FAKE_LOG")
printf '%s\n' "$args" | head -3 | tr '\n' ' ' | grep -q '^--yolo -m gpt-5.5 ' \
  || fail "codex fresh mode leads with --yolo then forwarded args"
assert_no_grep "arg=resume" "$FM_FAKE_LOG" "codex fresh mode does not resume"
printf '%s\n' "$args" | tail -1 | grep -q "fm-session-start.sh" \
  || fail "codex fresh prompt is the final positional argument"
pass "codex --new forwards arguments and appends the prompt last"

# --- no-prior-session behavior -------------------------------------------------

FM_FAKE_HARNESS_RC=3 run_entry 3 "resume failure propagates" claude
assert_contains "$ERR" "exited with status 3" "resume failure reports the harness exit"
assert_contains "$ERR" "firstmate claude --new" "resume failure points at --new"
pass "no-session resume failure prints the fresh-start diagnostic and propagates"

FM_FAKE_HARNESS_RC=3 run_entry 3 "fresh failure propagates" claude --new
assert_not_contains "$ERR" "firstmate claude --new" "fresh-mode failure gets no resume hint"
pass "fresh-mode failure propagates without the resume diagnostic"

echo "all fm-primary-entry tests passed"
