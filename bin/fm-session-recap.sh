#!/usr/bin/env bash
# fm-session-recap.sh - SessionStart hook helper: source-aware fleet recap context.
#
# Registered additively in .claude/settings.json and .codex/hooks.json for
# SessionStart sources startup|resume|clear|compact. It reads the hook payload
# JSON on stdin (bounded), validates the event name and source, runs the
# bounded LOCAL-ONLY bearings snapshot (bin/fm-bearings-snapshot.sh, the single
# owner of cross-home fleet recap aggregation, including every registered
# secondmate home's durable records) from this repository root, and prints
# plain-text context for the next model request:
#
#   startup/clear  - instructs the next response to lead with a captain-facing
#                    greeting and recap built from the snapshot
#   resume/compact - refreshes fleet state without forcing a repeated greeting
#
# Plain stdout is the SessionStart additional-context channel on both
# harnesses, and that context is consumed by the NEXT model request; the hook
# does not itself force a model turn (docs/primary-entry.md owns the workflow
# and this limitation). The helper is read-only and never blocks a session
# start: on any problem (TTY stdin, empty stdin, no jq, bad JSON, wrong event,
# unknown source, snapshot failure) it FAILS OPEN with exit 0 and at most a
# one-line unavailable note. The hook registrations bound total runtime with
# their own timeout; the helper additionally caps the snapshot at
# FM_RECAP_TIMEOUT seconds (default 20) when a timeout tool is available.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

FM_RECAP_TIMEOUT=${FM_RECAP_TIMEOUT:-20}
case "$FM_RECAP_TIMEOUT" in ''|*[!0-9]*|0) FM_RECAP_TIMEOUT=20 ;; esac

# Hooks always pipe a payload; a TTY means a bare manual run, so explain
# instead of blocking on a read that will never complete.
if [ -t 0 ]; then
  echo "fm-session-recap.sh: SessionStart hook helper; pipe a hook payload JSON on stdin" >&2
  exit 0
fi

payload=$(head -c 65536 2>/dev/null || true)
[ -n "$payload" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

event=$(printf '%s' "$payload" | jq -r '.hook_event_name // "SessionStart"' 2>/dev/null) || exit 0
[ "$event" = SessionStart ] || exit 0
src=$(printf '%s' "$payload" | jq -r '.source // empty' 2>/dev/null) || exit 0
case "$src" in
  startup|clear|resume|compact) ;;
  *) exit 0 ;;
esac

cd "$FM_ROOT" 2>/dev/null || exit 0

run_bounded() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$FM_RECAP_TIMEOUT" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$FM_RECAP_TIMEOUT" "$@"
  else
    # No timeout tool: the hook registration's own timeout is the bound.
    "$@"
  fi
}

snapshot=$(run_bounded "$SCRIPT_DIR/fm-bearings-snapshot.sh" 2>/dev/null)
rc=$?
if [ "$rc" -ne 0 ] || [ -z "$snapshot" ]; then
  case "$src" in
    startup|clear)
      printf '[firstmate session recap - source: %s]\n' "$src"
      printf 'Fleet recap unavailable (bin/fm-bearings-snapshot.sh failed); run it manually before briefing the captain.\n'
      ;;
  esac
  exit 0
fi

printf '[firstmate session recap - source: %s]\n' "$src"
case "$src" in
  startup|clear)
    printf 'Fresh or cleared context. Lead the next response with a concise captain-facing greeting and recap built from the fleet state below, before anything else.\n'
    ;;
  resume|compact)
    printf 'Refreshed fleet state after %s. Use it to stay current; do not repeat a greeting or full recap unless something below needs the captain.\n' "$src"
    ;;
esac
printf '%s\n' "$snapshot"
exit 0
