#!/usr/bin/env bash
# Behavior tests for bin/fm-session-recap.sh, the SessionStart fleet-recap hook
# helper, plus the tracked hook wiring in .claude/settings.json and
# .codex/hooks.json.
#
# The helper resolves its repo root and the bearings snapshot from its own
# script location, so the suite copies it into a stub root next to a fake
# fm-bearings-snapshot.sh; no real snapshot, harness, or session is involved.
# Covers payload/source parsing, source-aware wording, root anchoring, bounded
# snapshot inclusion, fail-open behavior, and preservation of every
# pre-existing hook in both tracked hook files.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER_REL=bin/fm-session-recap.sh
TMP=$(fm_test_tmproot fm-session-recap)
mkdir -p "$TMP/stubroot/bin"
STUB=$(cd "$TMP/stubroot" && pwd)
cp "$ROOT/$HELPER_REL" "$STUB/bin/"
cat > "$STUB/bin/fm-bearings-snapshot.sh" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_SNAPSHOT_RC:-}" ] || exit "$FM_FAKE_SNAPSHOT_RC"
printf 'FAKE_SNAPSHOT pwd=%s\n' "$PWD"
SH
chmod +x "$STUB/bin/fm-bearings-snapshot.sh"

# run_recap <payload>: pipe a payload into the stub helper from a neutral cwd.
run_recap() {
  OUT=$(cd "$TMP" && printf '%s' "$1" | "$STUB/$HELPER_REL" 2>"$TMP/err")
  RC=$?
}

# --- source-aware context -----------------------------------------------------

run_recap '{"hook_event_name":"SessionStart","source":"startup"}'
expect_code 0 "$RC" "startup payload"
assert_contains "$OUT" "source: startup" "startup output names its source"
assert_contains "$OUT" "Lead the next response" "startup instructs a leading recap"
assert_contains "$OUT" "FAKE_SNAPSHOT" "startup includes the bearings snapshot"
assert_contains "$OUT" "pwd=$STUB" "snapshot runs from the helper's repo root"
pass "startup emits the lead-with-recap context from the repo root"

run_recap '{"hook_event_name":"SessionStart","source":"clear"}'
expect_code 0 "$RC" "clear payload"
assert_contains "$OUT" "Lead the next response" "clear instructs a leading recap"
assert_contains "$OUT" "FAKE_SNAPSHOT" "clear includes the bearings snapshot"
pass "clear gets the same fresh-context treatment as startup"

for src in resume compact; do
  run_recap "{\"hook_event_name\":\"SessionStart\",\"source\":\"$src\"}"
  expect_code 0 "$RC" "$src payload"
  assert_contains "$OUT" "Refreshed fleet state after $src" "$src output refreshes state"
  assert_not_contains "$OUT" "Lead the next response" "$src does not force a greeting"
  assert_contains "$OUT" "FAKE_SNAPSHOT" "$src includes the bearings snapshot"
done
pass "resume/compact refresh state without forcing a repeated greeting"

# --- fail-open parsing ---------------------------------------------------------

run_recap '{"hook_event_name":"SessionStart","source":"weird"}'
expect_code 0 "$RC" "unknown source"
[ -z "$OUT" ] || fail "unknown source emits nothing"
pass "an unknown source is silently ignored"

run_recap '{"hook_event_name":"SessionStart"}'
expect_code 0 "$RC" "missing source"
[ -z "$OUT" ] || fail "missing source emits nothing"
pass "a missing source is silently ignored"

run_recap '{"hook_event_name":"PreToolUse","source":"startup"}'
expect_code 0 "$RC" "wrong event"
[ -z "$OUT" ] || fail "a non-SessionStart event emits nothing"
pass "a non-SessionStart event is silently ignored"

run_recap 'this is not json'
expect_code 0 "$RC" "invalid JSON"
[ -z "$OUT" ] || fail "invalid JSON emits nothing"
pass "invalid payload JSON fails open"

OUT=$("$STUB/$HELPER_REL" </dev/null 2>"$TMP/err"); RC=$?
expect_code 0 "$RC" "empty stdin"
[ -z "$OUT" ] || fail "empty stdin emits nothing"
pass "empty stdin fails open"

BROKEN=$(fm_fakebin "$TMP/brokenjq")
cat > "$BROKEN/jq" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$BROKEN/jq"
OUT=$(printf '%s' '{"hook_event_name":"SessionStart","source":"startup"}' \
  | PATH="$BROKEN:$PATH" "$STUB/$HELPER_REL" 2>"$TMP/err"); RC=$?
expect_code 0 "$RC" "unusable jq"
[ -z "$OUT" ] || fail "an unusable jq emits nothing"
pass "an unusable jq fails open"

# --- snapshot failure ----------------------------------------------------------

FM_FAKE_SNAPSHOT_RC=1 run_recap '{"hook_event_name":"SessionStart","source":"startup"}'
expect_code 0 "$RC" "snapshot failure on startup"
assert_contains "$OUT" "Fleet recap unavailable" "startup reports the failed snapshot"
assert_not_contains "$OUT" "FAKE_SNAPSHOT" "no snapshot content on failure"
pass "a failed snapshot degrades to a one-line note on startup"

FM_FAKE_SNAPSHOT_RC=1 run_recap '{"hook_event_name":"SessionStart","source":"resume"}'
expect_code 0 "$RC" "snapshot failure on resume"
[ -z "$OUT" ] || fail "a failed snapshot on resume emits nothing"
pass "a failed snapshot stays silent on resume"

# --- tracked hook wiring and preservation ---------------------------------------

CLAUDE_HOOKS="$ROOT/.claude/settings.json"
CODEX_HOOKS="$ROOT/.codex/hooks.json"
jq -e . "$CLAUDE_HOOKS" >/dev/null || fail ".claude/settings.json parses as JSON"
jq -e . "$CODEX_HOOKS" >/dev/null || fail ".codex/hooks.json parses as JSON"

for needle in fm-arm-pretool-check.sh fm-cd-pretool-check.sh; do
  jq -e --arg n "$needle" \
    'any(.hooks.PreToolUse[]?.hooks[]?.command?; type == "string" and contains($n))' \
    "$CLAUDE_HOOKS" >/dev/null || fail "claude PreToolUse still wires $needle"
  jq -e --arg n "$needle" \
    'any(.hooks.PreToolUse[]?.hooks[]?.command?; type == "string" and contains($n))' \
    "$CODEX_HOOKS" >/dev/null || fail "codex PreToolUse still wires $needle"
done
jq -e 'any(.hooks.Stop[]?.hooks[]?.command?; type == "string" and contains("fm-turnend-guard.sh"))' \
  "$CLAUDE_HOOKS" >/dev/null || fail "claude Stop still wires fm-turnend-guard.sh"
jq -e 'any(.hooks.Stop[]?.hooks[]?.command?; type == "string" and contains("fm-turnend-guard.sh"))' \
  "$CODEX_HOOKS" >/dev/null || fail "codex Stop still wires fm-turnend-guard.sh"
pass "every pre-existing PreToolUse and Stop hook is preserved in both files"

jq -e '.hooks.SessionStart[0].matcher == "startup|resume|clear|compact"' \
  "$CLAUDE_HOOKS" >/dev/null || fail "claude SessionStart matcher covers the four sources"
jq -e 'any(.hooks.SessionStart[]?.hooks[]?.command?; type == "string" and contains("fm-session-recap.sh"))' \
  "$CLAUDE_HOOKS" >/dev/null || fail "claude SessionStart wires fm-session-recap.sh"
codex_ss=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$CODEX_HOOKS")
assert_contains "$codex_ss" "fm-session-recap.sh" "codex SessionStart wires the helper"
assert_contains "$codex_ss" 'any(.hooks.SessionStart' "codex SessionStart keeps the trust/anchoring self-check"
assert_contains "$codex_ss" 'pwd -P' "codex SessionStart anchors to the hook process root"
pass "SessionStart wiring is additive and follows the tracked codex wrapper pattern"

for f in bin/firstmate bin/fm-primary-entry.sh bin/fm-session-recap.sh; do
  [ -x "$ROOT/$f" ] || fail "$f is executable"
done
pass "entry command and helper are executable"

echo "all fm-session-recap tests passed"
