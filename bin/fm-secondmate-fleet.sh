#!/usr/bin/env bash
# Fleet-level status command for persistent secondmates.
#
# Usage:
#   fm-secondmate-fleet.sh status
# Project-local `secondmate <harness>` is the only normal start or resume path.
#
# Homes are always persistent and coordinators run only when useful.
# `status` is read-only and never starts, synchronizes, or nudges a coordinator.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

usage() {
  echo "usage: fm-secondmate-fleet.sh status" >&2
}

MODE=${1:-}
[ -n "$MODE" ] && shift || true
case "$MODE" in status) ;; *) usage; exit 1 ;; esac

[ "$#" -eq 0 ] || { echo "error: unknown argument $1" >&2; usage; exit 1; }

routes=$("$FM_ROOT/bin/fm-home-seed.sh" routes) || exit 1
[ -n "$routes" ] || { echo "no registered secondmate homes"; exit 0; }

trim() {
  local value=$1
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  printf '%s\n' "$value"
}

while IFS=$'\t' read -r id home projects; do
  [ -n "$id" ] || continue
  project=$(trim "${projects%%,*}")
  if [ -z "$project" ]; then
    echo "$id: no project route (persistent home: $home)"
    continue
  fi

  meta="$STATE/$id.meta"
  if [ ! -f "$meta" ]; then
    echo "$id: stopped (project: $project)"
    continue
  fi
  meta_kind=$(sed -n 's/^kind=//p' "$meta" | head -1)
  meta_home=$(sed -n 's/^home=//p' "$meta" | head -1)
  if [ "$meta_kind" != secondmate ] || [ "$meta_home" != "$home" ]; then
    echo "$id: metadata mismatch (project: $project; reconcile before recovery)"
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
    dead) echo "$id: stopped (recover from the project container with: secondmate <harness>)" ;;
    *) echo "$id: unknown (backend: $backend; inspect before recovery)" ;;
  esac

done <<EOF
$routes
EOF

exit 0
