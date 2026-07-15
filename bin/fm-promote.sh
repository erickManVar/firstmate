#!/usr/bin/env bash
# Promote a scout task to a ship task in place: the crewmate keeps its window,
# worktree, and loaded context; only the contract changes. Flips kind= to ship in
# state/<task-id>.meta so fm-teardown.sh applies the full ship-task teardown protection
# again. Promotion creates new meaningful ship work, so it requires an explicit
# delivery posture (docs/configuration.md "Delivery posture") and fails closed
# without one: rapid-local rewrites the task's effective mode to the guarded
# local-only path, while peer-ship keeps the registered mode already recorded in
# meta and refuses a local-only project. The chosen posture is written to
# data/<task-id>/delivery and recorded as delivery= in meta, so it survives
# restart and recovery exactly like a scaffolded ship task's posture.
# After promoting, send the crewmate its ship instructions via fm-send.sh
# (inventory scratch state, reset to a clean default-branch base, carry over only
# intended fix changes, create branch fm/<task-id>, implement, then report done
# according to the task's recorded delivery posture and mode).
# Usage: fm-promote.sh <task-id> --delivery <rapid-local|peer-ship>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
"$FM_ROOT/bin/fm-guard.sh" || true

ID=
DELIVERY=
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    DELIVERY=$a
    want_value=
    continue
  fi
  case "$a" in
    --delivery) want_value=delivery ;;
    --delivery=*) DELIVERY=${a#--delivery=} ;;
    --*) echo "error: unknown flag $a" >&2; exit 1 ;;
    *)
      [ -z "$ID" ] || { echo "error: unexpected argument $a" >&2; exit 1; }
      ID=$a
      ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
[ -n "$ID" ] || { echo "usage: fm-promote.sh <task-id> --delivery <rapid-local|peer-ship>" >&2; exit 1; }
case "$DELIVERY" in
  rapid-local|peer-ship) ;;
  '')
    echo "error: promotion creates meaningful ship work and needs an explicit delivery posture: pass --delivery rapid-local or --delivery peer-ship" >&2
    echo "when the captain has not supplied one, ask before promoting (AGENTS.md task lifecycle); do not guess" >&2
    exit 1
    ;;
  *) echo "error: --delivery must be rapid-local or peer-ship, got '$DELIVERY'" >&2; exit 1 ;;
esac

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
grep -qx 'kind=scout' "$META" || { echo "error: task $ID is not a scout task (kind=scout not in meta)" >&2; exit 1; }

# The scout's meta already records the registered project mode from spawn time.
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ -n "$MODE" ] || MODE=no-mistakes
if [ "$DELIVERY" = rapid-local ]; then
  NEW_MODE=local-only
else
  if [ "$MODE" = local-only ]; then
    echo "error: delivery posture peer-ship needs a remote-capable delivery mode, but task $ID is on a local-only project; use rapid-local or change the project mode" >&2
    exit 1
  fi
  NEW_MODE=$MODE
fi

mkdir -p "$DATA/$ID"
printf '%s\n' "$DELIVERY" > "$DATA/$ID/delivery"

TMP="$META.tmp"
grep -v -e '^kind=' -e '^mode=' -e '^delivery=' "$META" > "$TMP"
{
  echo "kind=ship"
  echo "mode=$NEW_MODE"
  echo "delivery=$DELIVERY"
} >> "$TMP"
mv "$TMP" "$META"

HOME_Q=$(printf '%q' "$FM_HOME")
echo "promoted $ID to ship (delivery=$DELIVERY, mode=$NEW_MODE; teardown protection restored)"
echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions: review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; create branch fm/$ID; implement; report done per the recorded delivery posture>'"
