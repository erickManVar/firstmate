#!/usr/bin/env bash
# Fleet-level status and idempotent ensure command for persistent secondmates.
#
# Usage:
#   fm-secondmate-fleet.sh status
#   fm-secondmate-fleet.sh ensure [--backend <tmux|herdr|zellij|orca>]
#
# Homes are always persistent. `status` is read-only; `ensure` routes every
# project-bearing registered home through fm-secondmate.sh, which safely
# attaches to a confirmed-live coordinator, respawns a confirmed-dead one, and
# refuses to duplicate an inconclusive endpoint. This command never creates a
# worker worktree and never edits a project.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

usage() {
  echo "usage: fm-secondmate-fleet.sh <status|ensure> [--backend <tmux|herdr|zellij|orca>]" >&2
}

MODE=${1:-}
[ -n "$MODE" ] && shift || true
case "$MODE" in status|ensure) ;; *) usage; exit 1 ;; esac

BACKEND=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --backend)
      [ "$#" -ge 2 ] || { echo "error: --backend requires a value" >&2; exit 1; }
      BACKEND=$2
      shift 2
      ;;
    --backend=*) BACKEND=${1#--backend=}; shift ;;
    *) echo "error: unknown argument $1" >&2; usage; exit 1 ;;
  esac
done
case "$BACKEND" in ''|tmux|herdr|zellij|orca) ;; *) echo "error: unsupported secondmate backend '$BACKEND'" >&2; exit 1 ;; esac

routes=$("$FM_ROOT/bin/fm-home-seed.sh" routes) || exit 1
[ -n "$routes" ] || { echo "no registered secondmate homes"; exit 0; }

trim() {
  local value=$1
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  printf '%s\n' "$value"
}

failures=0
while IFS=$'\t' read -r id home projects; do
  [ -n "$id" ] || continue
  project=$(trim "${projects%%,*}")
  if [ -z "$project" ]; then
    echo "$id: no project route (persistent home: $home)"
    continue
  fi

  if [ "$MODE" = status ]; then
    meta="$STATE/$id.meta"
    if [ ! -f "$meta" ]; then
      echo "$id: stopped (project: $project)"
      continue
    fi
    backend=$(sed -n 's/^backend=//p' "$meta" | head -1)
    [ -n "$backend" ] || backend=tmux
    target=$(fm_backend_target_of_meta "$meta" 2>/dev/null || true)
    if [ -z "$target" ]; then
      echo "$id: metadata incomplete (project: $project)"
      continue
    fi
    verdict=$(fm_backend_agent_alive "$backend" "$target" 2>/dev/null || true)
    case "$verdict" in
      alive) echo "$id: live (backend: $backend; project: $project)" ;;
      dead) echo "$id: stopped (recover with: fm-secondmate-fleet.sh ensure)" ;;
      *) echo "$id: unknown (backend: $backend; inspect before recovery)" ;;
    esac
    continue
  fi

  args=(auto "$project" --no-attach)
  [ -z "$BACKEND" ] || args+=(--backend "$BACKEND")
  if output=$("$FM_ROOT/bin/fm-secondmate.sh" "${args[@]}" 2>&1); then
    echo "$id: $output"
  else
    echo "$id: failed: $output" >&2
    failures=1
  fi
done <<EOF
$routes
EOF

exit "$failures"
