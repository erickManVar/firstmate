#!/usr/bin/env bash
# fm-primary-entry.sh - captain entry command for the PRIMARY firstmate session.
#
# Usage: firstmate <claude|codex> [--new] [--] [harness args...]
#
#   Anchors the process cwd to this script's repository root regardless of the
#   caller's cwd, so the harness loads this repo's project hooks and resumes
#   the conversation history recorded for this repository.
#
#   Default mode resumes the most recent conversation for this repository via
#   the harness's documented native resume command:
#     claude  ->  claude --continue
#     codex   ->  codex resume --last --yolo
#
#   --new starts a fresh interactive session instead, with a short positional
#   initial prompt requesting the mandatory Firstmate session start (recovery)
#   and a concise captain greeting/recap. Never print/headless mode.
#
#   Autonomy posture: codex launches carry --yolo (the codex alias for
#   --dangerously-bypass-approvals-and-sandbox), the standing captain-approved
#   posture for the local primary entry; it parses on both `codex` and
#   `codex resume` (verified against codex-cli 0.144.4, docs/primary-entry.md).
#   Claude launches intentionally carry NO bypass-permissions flag.
#
#   Coordinator posture (docs/configuration.md "Coordinator posture"): a claude
#   launch with neither --model nor --effort among the forwarded arguments
#   appends the recommended coordinator pair, --model claude-fable-5 --effort
#   medium. Supplying either axis disables the whole injection, so an explicit
#   override never gains a surprise companion flag. Codex launches are never
#   touched by this default.
#
#   Argument forwarding is unambiguous: after the harness name, firstmate
#   consumes only its own flags (--new, -h/--help); `--` stops that scan; every
#   other argument is forwarded to the harness verbatim, in order, so
#   documented harness flags like --model/--effort just work. In --new mode
#   the initial prompt is appended as the final positional argument.
#
#   No-prior-session behavior: resume mode runs the harness in the foreground
#   and, when it exits non-zero (both harnesses fail fast when there is
#   nothing to resume), prints a diagnostic pointing at `firstmate <harness>
#   --new` and propagates the exit code. No undocumented transcript format is
#   ever inspected.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat <<'EOF'
usage: firstmate <claude|codex> [--new] [--] [harness args...]

Launch the captain's primary firstmate session from anywhere, anchored to the
firstmate repository root.

  (default)   resume the most recent conversation for this repository
              (claude --continue / codex resume --last)
  --new       start a fresh interactive session whose initial prompt requests
              the mandatory Firstmate session start and a concise captain recap
  -h, --help  this help

Everything else after the harness name is forwarded to the harness verbatim
(e.g. --model, --effort); use `--` to forward an argument firstmate would
otherwise consume itself. Codex launches carry the standing captain-approved
--yolo posture; claude launches add no permission flags. A claude launch with
neither --model nor --effort defaults to the recommended coordinator posture
(--model claude-fable-5 --effort medium); passing either axis disables it.
EOF
}

HARNESS=${1:-}
case "$HARNESS" in
  -h|--help) usage; exit 0 ;;
  '') usage >&2; exit 2 ;;
  claude|codex) shift ;;
  -*)
    echo "error: invalid firstmate usage: expected a harness name first, got '$HARNESS'" >&2
    usage >&2
    exit 2
    ;;
  *)
    echo "error: unknown harness '$HARNESS' (supported: claude, codex)" >&2
    exit 2
    ;;
esac

MODE=resume
FWD=()
while [ $# -gt 0 ]; do
  case "$1" in
    --new) MODE=new ;;
    -h|--help) usage; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do FWD+=("$1"); shift; done; break ;;
    *) FWD+=("$1") ;;
  esac
  shift
done

FRESH_PROMPT='Mandatory Firstmate session start: run bin/fm-session-start.sh and complete recovery per AGENTS.md sections 3 and 5. Then greet the captain with a concise recap of current fleet state: in-flight work, anything ready for review, and any decision or blocker that needs them.'

command -v "$HARNESS" >/dev/null 2>&1 || {
  echo "error: '$HARNESS' not found on PATH" >&2
  exit 127
}
cd "$FM_ROOT" || { echo "error: cannot cd to repository root $FM_ROOT" >&2; exit 1; }

CMD=()
case "$HARNESS/$MODE" in
  claude/resume) CMD=(claude --continue) ;;
  claude/new) CMD=(claude) ;;
  codex/resume) CMD=(codex resume --last --yolo) ;;
  codex/new) CMD=(codex --yolo) ;;
esac
if [ "${#FWD[@]}" -gt 0 ]; then
  CMD+=("${FWD[@]}")
fi

# Recommended coordinator posture, claude only (see header): inject the pair
# only when the caller supplied neither axis, and always before the fresh-mode
# prompt so that prompt stays the final positional argument.
if [ "$HARNESS" = claude ]; then
  has_model=0
  has_effort=0
  if [ "${#FWD[@]}" -gt 0 ]; then
    for a in "${FWD[@]}"; do
      case "$a" in
        --model|--model=*) has_model=1 ;;
        --effort|--effort=*) has_effort=1 ;;
      esac
    done
  fi
  if [ "$has_model" -eq 0 ] && [ "$has_effort" -eq 0 ]; then
    CMD+=(--model claude-fable-5 --effort medium)
  fi
fi
[ "$MODE" = new ] && CMD+=("$FRESH_PROMPT")

"${CMD[@]}"
rc=$?
if [ "$rc" -ne 0 ] && [ "$MODE" = resume ]; then
  echo "firstmate: $HARNESS exited with status $rc." >&2
  echo "If there was no prior conversation to resume in $FM_ROOT, start a fresh one with: firstmate $HARNESS --new" >&2
fi
exit "$rc"
