#!/usr/bin/env bash
# Container-local attach-or-start launcher for a project's persistent secondmate.
#
# Usage: fm-secondmate.sh <claude|codex|opencode|pi|grok|auto> [<project-or-path>] [--backend <name>] [--no-attach]
#   Run from a registered project container, one of its registered repos, or a
#   repo subdirectory; the registered project is inferred from the current
#   directory exactly as bin/fm-project-route.sh does, and an explicit project
#   name or path argument overrides the inference.
#   The routing table (data/secondmates.md) maps the project to exactly one
#   registered secondmate; zero or multiple routes fail closed with the same
#   diagnostics fm-project-route.sh prints.
#   When the routed secondmate's recorded endpoint holds a confirmed-live agent,
#   the launcher attaches instead of launching: inside tmux it switches the
#   current client to the coordinator window, outside tmux it execs
#   tmux attach-session, and for a non-tmux backend it prints the live target
#   because focus is owned by that backend's own UI. It never launches a
#   duplicate coordinator for a live home.
#   When the endpoint is confidently dead (a bare shell left by an exited
#   agent), the dead endpoint is killed and the secondmate is respawned via
#   bin/fm-spawn.sh --secondmate from this explicit project-local invocation.
#   When liveness cannot be proven either way, the launcher fails closed and
#   asks for a manual inspection, so a momentary probe glitch can never
#   duplicate a live supervisor.
#   Harness selection: an explicit claude/codex/opencode/pi/grok wins for this
#   launch and is passed to fm-spawn as --harness; auto passes no harness so
#   fm-spawn resolves the documented secondmate chain
#   (config/secondmate-harness -> config/crew-harness -> own harness, plus the
#   file's optional model/effort tokens; bin/fm-harness.sh secondmate).
#   A claude coordinator with no pinned model/effort launches on the recommended
#   coordinator posture (docs/configuration.md "Coordinator posture").
#   Backend selection: an explicit --backend is forwarded verbatim. A dead
#   endpoint respawns on the backend its meta records (absent backend= means
#   tmux), so a coordinator never silently changes hosting on recovery.
#   Otherwise the launcher leaves resolution to fm-spawn's own chain
#   (FM_BACKEND, then config/backend, then runtime auto-detection, then tmux)
#   with one exception: when that resolution lands on cmux, which cannot host
#   a persistent coordinator, the launch bridges to tmux with a stderr note.
#   Orca hosts coordinators natively (docs/orca-backend.md "Secondmate
#   hosting"), so it is never bridged.
#   A per-secondmate launch lock under state/ serializes concurrent launcher
#   runs for the same id, so two racing invocations cannot both observe "not
#   live" and spawn twice. The lock records its owner pid; a lock whose owner
#   is provably dead is reclaimed once, and anything unprovable (no pid, a
#   live pid, a kill-probe error) stays fail-closed.
#   --no-attach reports the live or spawned target without touching the
#   caller's terminal (for scripts and tests).
# The primary firstmate home is $FM_HOME when set, else this repo root; the
# launcher only reads the primary's registry and state and writes nothing but
# the launch lock and whatever fm-spawn itself records.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SUB_HOME_MARKER=".fm-secondmate-home"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

usage() {
  echo "usage: fm-secondmate.sh <claude|codex|opencode|pi|grok|auto> [<project-or-path>] [--backend <name>] [--no-attach]" >&2
}

HARNESS=
PROJECT_ARG=
BACKEND_ARG=
NO_ATTACH=0
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    BACKEND_ARG=$a
    want_value=
    continue
  fi
  case "$a" in
    -h|--help) usage; exit 0 ;;
    --backend) want_value=backend ;;
    --backend=*) BACKEND_ARG=${a#--backend=} ;;
    --no-attach) NO_ATTACH=1 ;;
    --*) echo "error: unknown flag $a" >&2; usage; exit 1 ;;
    *)
      if [ -z "$HARNESS" ]; then
        HARNESS=$a
      elif [ -z "$PROJECT_ARG" ]; then
        PROJECT_ARG=$a
      else
        echo "error: unexpected argument $a" >&2
        usage
        exit 1
      fi
      ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
case "$HARNESS" in
  claude|codex|opencode|pi|grok|auto) ;;
  '') usage; exit 1 ;;
  *)
    echo "error: unknown harness '$HARNESS' (verified: claude codex opencode pi grok, or auto)" >&2
    exit 1
    ;;
esac

# Registry sanity before any routing decision: duplicate or overlapping homes
# mean the routing table itself cannot be trusted, so fail closed.
"$FM_ROOT/bin/fm-home-seed.sh" validate || {
  echo "error: secondmate registry failed validation; fix data/secondmates.md before launching" >&2
  exit 1
}

# Route the current (or explicit) project to its one registered secondmate.
# fm-project-route.sh owns the resolution and prints the diagnostics for the
# no-route and ambiguous-route failures; forward its exit code unchanged.
if [ -n "$PROJECT_ARG" ]; then
  route_out=$("$FM_ROOT/bin/fm-project-route.sh" "$PROJECT_ARG")
else
  route_out=$("$FM_ROOT/bin/fm-project-route.sh")
fi
ID=$(printf '%s\n' "$route_out" | sed -n 's/^route=//p')
HOME_PATH=$(printf '%s\n' "$route_out" | sed -n 's/^home=//p')
PROJECT=$(printf '%s\n' "$route_out" | sed -n 's/^project=//p')
[ -n "$ID" ] && [ -n "$HOME_PATH" ] || {
  echo "error: could not resolve a secondmate route for ${PROJECT:-the current directory}" >&2
  exit 2
}

# Identity checks on the routed home: a malformed or repurposed home fails
# closed instead of being launched into.
[ -d "$HOME_PATH" ] || { echo "error: routed secondmate home does not exist: $HOME_PATH" >&2; exit 1; }
marker_id=$(cat "$HOME_PATH/$SUB_HOME_MARKER" 2>/dev/null || true)
[ "$marker_id" = "$ID" ] || {
  echo "error: home $HOME_PATH is marked for '${marker_id:-nothing}', not routed secondmate '$ID'; refusing to launch" >&2
  exit 1
}
[ -f "$HOME_PATH/AGENTS.md" ] && [ -d "$HOME_PATH/bin" ] || {
  echo "error: $HOME_PATH is not a firstmate home (missing AGENTS.md or bin/)" >&2
  exit 1
}

# Serialize concurrent launcher runs per secondmate so two racing invocations
# cannot both classify the endpoint as not-live and spawn a duplicate. The
# lock dir records its owner pid. On contention a lock is reclaimed ONLY when
# that pid is provably dead (kill -0 reports no such process), and the reclaim
# itself is an atomic ownership transition: the contender renames the exact
# stale lock directory to a unique claimant path, so of any number of racing
# contenders authorized by the same dead owner exactly one wins the rename and
# may create the canonical lock - the losers' rename fails and they fail
# closed, never removing a path another contender now owns. If the rename
# turns out to have grabbed a lock whose recorded owner changed or revived, it
# is renamed back best-effort and the contender fails closed. Cleanup is
# ownership-guarded: a process only ever removes a lock whose recorded pid is
# its own.
mkdir -p "$STATE"
LOCK="$STATE/.secondmate-launch-$ID.lock"
acquire_launch_lock() {
  mkdir "$LOCK" 2>/dev/null || return 1
  printf '%s\n' "$$" > "$LOCK/pid"
  return 0
}
release_launch_lock() {
  [ "$(cat "$LOCK/pid" 2>/dev/null || true)" = "$$" ] || return 0
  rm -rf "$LOCK" 2>/dev/null || true
}
reclaim_stale_launch_lock() {
  local owner_pid claim claimed_pid
  owner_pid=$(cat "$LOCK/pid" 2>/dev/null || true)
  case "$owner_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$owner_pid" 2>/dev/null && return 1
  claim="$LOCK.claim.$$"
  mv "$LOCK" "$claim" 2>/dev/null || return 1
  claimed_pid=$(cat "$claim/pid" 2>/dev/null || true)
  if [ "$claimed_pid" != "$owner_pid" ] || kill -0 "$claimed_pid" 2>/dev/null; then
    mv "$claim" "$LOCK" 2>/dev/null || true
    return 1
  fi
  echo "note: reclaiming stale launch lock for $ID (owner pid $owner_pid is dead)" >&2
  rm -rf "$claim" 2>/dev/null || true
  return 0
}
if ! acquire_launch_lock; then
  if ! reclaim_stale_launch_lock || ! acquire_launch_lock; then
    echo "error: another launch for $ID is already in progress ($LOCK); retry in a moment" >&2
    exit 1
  fi
fi
trap 'release_launch_lock' EXIT

meta_value() {  # <meta-file> <key>
  sed -n "s/^$2=//p" "$1" | head -1
}

report_target() {  # <verb> <target> <backend>
  printf '%s %s (secondmate %s, project %s, backend %s, home %s)\n' \
    "$1" "$2" "$ID" "$PROJECT" "$3" "$HOME_PATH"
}

attach() {  # <target> <backend>
  local target=$1 backend=$2 session
  if [ "$NO_ATTACH" -eq 1 ]; then
    report_target "target" "$target" "$backend"
    return 0
  fi
  if [ "$backend" != tmux ]; then
    report_target "live at" "$target" "$backend"
    echo "focus it in the $backend UI; attaching from a shell is tmux-only" >&2
    return 0
  fi
  session=${target%%:*}
  tmux select-window -t "$target" 2>/dev/null || true
  release_launch_lock
  trap - EXIT
  if [ -n "${TMUX:-}" ]; then
    exec tmux switch-client -t "$target"
  fi
  exec tmux attach-session -t "$session"
}

META="$STATE/$ID.meta"
ACTION=spawn
TARGET=
BACKEND=tmux
if [ -f "$META" ]; then
  BACKEND=$(fm_backend_of_meta "$META")
  # The backend target, not the window alias: for Orca the recorded terminal
  # handle is what capture/liveness/kill operate on (fm_backend_target_of_meta).
  TARGET=$(fm_backend_target_of_meta "$META")
  meta_kind=$(meta_value "$META" kind)
  meta_home=$(meta_value "$META" home)
  if [ "$meta_kind" != secondmate ] || [ "$meta_home" != "$HOME_PATH" ]; then
    echo "error: state/$ID.meta is not the routed secondmate record for $HOME_PATH; reconcile before launching" >&2
    exit 1
  fi
  if [ -n "$TARGET" ]; then
    endpoint_state=$(fm_backend_target_state "$BACKEND" "$TARGET" "fm-$ID")
    if [ "$endpoint_state" = exists ]; then
      verdict=$(fm_backend_agent_alive "$BACKEND" "$TARGET")
      case "$verdict" in
        alive)
          ACTION=attach
          ;;
        dead)
          fm_backend_kill "$BACKEND" "$TARGET" 2>/dev/null || true
          ACTION=spawn
          ;;
        *)
          echo "error: endpoint $TARGET exists but its agent liveness is unproven (backend=$BACKEND); refusing to launch a possible duplicate" >&2
          echo "inspect it (bin/fm-peek.sh or the $BACKEND UI) and retry, or tear it down explicitly" >&2
          exit 1
          ;;
      esac
    elif [ "$endpoint_state" != missing ]; then
      echo "error: could not verify recorded $BACKEND endpoint $TARGET; refusing to launch a possible duplicate" >&2
      echo "inspect it (bin/fm-peek.sh or the $BACKEND UI) and retry, or tear it down explicitly" >&2
      exit 1
    fi
  fi
fi

if [ "$ACTION" = attach ]; then
  live_harness=$(meta_value "$META" harness)
  if [ "$HARNESS" != auto ] && [ -n "$live_harness" ] && [ "$live_harness" != "$HARNESS" ]; then
    echo "note: coordinator is already live on $live_harness; attaching to it instead of launching $HARNESS" >&2
  fi
  attach "$TARGET" "$BACKEND"
  exit 0
fi

spawn_args=("$ID" --secondmate)
[ "$HARNESS" = auto ] || spawn_args+=(--harness "$HARNESS")
if [ -n "$BACKEND_ARG" ]; then
  spawn_args+=(--backend "$BACKEND_ARG")
elif [ -f "$META" ]; then
  # A dead-endpoint respawn stays on the RECORDED backend (absent backend=
  # means tmux), so recovery never silently migrates a coordinator to
  # whatever this session's ambient resolution happens to be.
  spawn_args+=(--backend "$BACKEND")
else
  # Implicit-resolution bridge, cmux only: cmux cannot host a persistent
  # coordinator (fm-spawn refuses --secondmate on it), so when the primary's
  # normal resolution lands there the coordinator launches on tmux instead of
  # refusing. Orca hosts coordinators natively and is never bridged.
  # Explicit --backend requests above stay forwarded verbatim so fm-spawn's
  # own diagnostics are preserved. Resolution stderr (the auto-detect notices)
  # is suppressed here; fm-spawn re-resolves and prints them itself.
  RESOLVED_BACKEND=$(fm_backend_name 2>/dev/null)
  case "$RESOLVED_BACKEND" in
    cmux)
      echo "note: backend '$RESOLVED_BACKEND' cannot host a secondmate coordinator; launching it on tmux instead (pass --backend $RESOLVED_BACKEND to see the refusal)" >&2
      spawn_args+=(--backend tmux)
      ;;
  esac
fi
"$FM_ROOT/bin/fm-spawn.sh" "${spawn_args[@]}" || exit 1

[ -f "$META" ] || { echo "error: spawn reported success but no meta at $META" >&2; exit 1; }
BACKEND=$(fm_backend_of_meta "$META")
TARGET=$(fm_backend_target_of_meta "$META")
report_target "started" "$TARGET" "$BACKEND"
attach "$TARGET" "$BACKEND"
