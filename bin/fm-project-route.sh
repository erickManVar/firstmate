#!/usr/bin/env bash
# Read-only lookup from a project name, container, or repo path to secondmates.
#
# Usage: fm-project-route.sh [<project-name-or-path>]
# With no argument, infer the registered project from the current Git top-level
# or from a non-git project-container cwd.
# One exact projects: match prints the supported fm-send command.
# Multiple exact matches are reported without choosing one because secondmate
# project access is deliberately non-exclusive.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/secondmates.md"
# shellcheck source=bin/fm-projects-lib.sh
. "$SCRIPT_DIR/fm-projects-lib.sh"

usage() {
  echo "usage: fm-project-route.sh [<project-name-or-path>]" >&2
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
[ $# -le 1 ] || { usage; exit 1; }

if [ $# -eq 1 ]; then
  input=${1%/}
else
  input=$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)
fi
project=$(fm_project_name_from_arg "$input") || {
  echo "no registered project context for $input" >&2
  exit 2
}
[ -f "$REG" ] || {
  echo "no secondmate route for $project: $REG is absent" >&2
  exit 2
}

ids=()
homes=()
scopes=()
while IFS= read -r line; do
  case "$line" in
    '- '*) ;;
    *) continue ;;
  esac
  id=${line#- }
  id=${id%% *}
  projects=$(printf '%s\n' "$line" | sed -n 's/.*; projects: \([^;)]*\); added .*/\1/p')
  [ -n "$projects" ] || continue
  matched=0
  old_ifs=$IFS
  IFS=,
  for candidate in $projects; do
    candidate=$(printf '%s' "$candidate" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ "$candidate" = "$project" ] && matched=1
  done
  IFS=$old_ifs
  [ "$matched" -eq 1 ] || continue
  home=$(printf '%s\n' "$line" | sed -n 's/.*(home: \([^;)]*\); scope: .*/\1/p')
  scope=$(printf '%s\n' "$line" | sed -n 's/.*; scope: \([^;)]*\); projects: .*/\1/p')
  ids+=("$id")
  homes+=("$home")
  scopes+=("$scope")
done < "$REG"

printf 'project=%s\n' "$project"
if [ "${#ids[@]}" -eq 0 ]; then
  printf 'route=none\n'
  echo "no secondmate route for $project" >&2
  exit 2
fi

if [ "${#ids[@]}" -gt 1 ]; then
  printf 'route=ambiguous\n'
  idx=0
  while [ "$idx" -lt "${#ids[@]}" ]; do
    printf 'candidate=%s\thome=%s\tscope=%s\n' "${ids[$idx]}" "${homes[$idx]}" "${scopes[$idx]}"
    idx=$((idx + 1))
  done
  echo "multiple secondmates list $project; refusing to guess without choosing by scope" >&2
  exit 3
fi

printf 'route=%s\n' "${ids[0]}"
printf 'home=%s\n' "${homes[0]}"
printf 'scope=%s\n' "${scopes[0]}"
printf 'send=FM_HOME=%s %s %s '\
  "$(shell_quote "$FM_HOME")" "$(shell_quote "$FM_ROOT/bin/fm-send.sh")" "$(shell_quote "${ids[0]}")"
printf "'<request>'\n"
