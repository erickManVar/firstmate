# shellcheck shell=bash
# Project catalog resolution.
#
# Source this library after FM_HOME, FM_DATA_OVERRIDE, and FM_CONFIG_OVERRIDE are
# resolved by the caller.
# The catalog root precedence is:
#   1. non-empty FM_PROJECTS_OVERRIDE;
#   2. the single absolute path in config/projects-root;
#   3. the legacy $FM_HOME/projects directory.
#
# data/projects.md remains the authoritative project-name registry.
# A registered name maps only to a direct, non-symlink child of the resolved
# catalog root.
# Shared roots are mutation-owned by the primary firstmate home.
# A secondmate home, identified by .fm-secondmate-home, may resolve and dispatch
# work against a shared root but must not fleet-sync that canonical checkout.

fm_projects_error() {
  printf 'fm-projects: error: %s\n' "$*" >&2
}

fm_projects_home() {
  printf '%s\n' "${FM_HOME:?FM_HOME must be set before sourcing fm-projects-lib.sh}"
}

fm_projects_config_dir() {
  printf '%s\n' "${FM_CONFIG_OVERRIDE:-$(fm_projects_home)/config}"
}

fm_projects_data_dir() {
  printf '%s\n' "${FM_DATA_OVERRIDE:-$(fm_projects_home)/data}"
}

fm_projects_normalize_path() {
  local path=$1 parent base
  case "$path" in
    /*) ;;
    *) path="$(pwd -P)/$path" ;;
  esac
  if [ -d "$path" ]; then
    (cd "$path" && pwd -P)
    return
  fi
  parent=${path%/*}
  base=${path##*/}
  [ -n "$parent" ] || parent=/
  if [ -d "$parent" ]; then
    printf '%s/%s\n' "$(cd "$parent" && pwd -P | sed 's#/$##')" "$base"
    return
  fi
  printf '%s\n' "${path%/}"
}

fm_projects_legacy_root() {
  printf '%s/projects\n' "${FM_HOME%/}"
}

fm_projects_configured_root() {
  local file line count normalized
  file="$(fm_projects_config_dir)/projects-root"
  if [ ! -e "$file" ]; then
    if [ -L "$file" ]; then
      fm_projects_error "configured projects root file is a dangling symlink: $file"
      return 2
    fi
    return 1
  fi
  if [ ! -f "$file" ]; then
    fm_projects_error "configured projects root must be a regular file: $file"
    return 2
  fi
  if [ ! -r "$file" ]; then
    fm_projects_error "configured projects root is unreadable: $file"
    return 2
  fi
  if ! line=$(awk '
    /^[[:space:]]*($|#)/ { next }
    { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print }
  ' "$file"); then
    fm_projects_error "failed to read configured projects root: $file"
    return 2
  fi
  if ! count=$(printf '%s\n' "$line" | awk 'NF { n++ } END { print n+0 }'); then
    fm_projects_error "failed to parse configured projects root: $file"
    return 2
  fi
  if [ "$count" -ne 1 ]; then
    fm_projects_error "$file must contain exactly one non-empty, non-comment path"
    return 2
  fi
  case "$line" in
    /*) ;;
    *)
      fm_projects_error "$file must contain an absolute path"
      return 2
      ;;
  esac
  [ -d "$line" ] || {
    fm_projects_error "configured projects root is not a directory: $line"
    return 2
  }
  if ! normalized=$(fm_projects_normalize_path "$line") || [ -z "$normalized" ]; then
    fm_projects_error "failed to normalize configured projects root: $line"
    return 2
  fi
  printf '%s\n' "$normalized"
}

fm_projects_root() {
  local configured rc
  if [ -n "${FM_PROJECTS_OVERRIDE:-}" ]; then
    printf '%s\n' "$FM_PROJECTS_OVERRIDE"
    return
  fi
  if configured=$(fm_projects_configured_root); then
    rc=0
  else
    rc=$?
  fi
  case "$rc" in
    0) printf '%s\n' "$configured" ;;
    1) fm_projects_legacy_root ;;
    *) return "$rc" ;;
  esac
}

fm_projects_mode() {
  local rc
  if [ -n "${FM_PROJECTS_OVERRIDE:-}" ]; then
    printf 'shared-external\n'
    return
  fi
  if fm_projects_configured_root >/dev/null; then
    printf 'shared-external\n'
    return
  else
    rc=$?
  fi
  [ "$rc" -eq 1 ] || return "$rc"
  printf 'legacy-local\n'
}

fm_project_name_valid() {
  local name=$1
  case "$name" in
    ''|.|..|.*|*/*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

fm_project_path() {
  local name=$1 root candidate physical
  fm_project_name_valid "$name" || {
    fm_projects_error "unsafe project name: $name"
    return 1
  }
  root=$(fm_projects_root) || return
  root=$(fm_projects_normalize_path "$root") || return
  candidate="$root/$name"
  if [ -L "$candidate" ]; then
    fm_projects_error "project path must not be a symlink: $candidate"
    return 1
  fi
  if [ -d "$candidate" ]; then
    physical=$(cd "$candidate" && pwd -P) || return 1
    [ "${physical%/*}" = "$root" ] && [ "${physical##*/}" = "$name" ] || {
      fm_projects_error "project path must remain a direct child of $root: $candidate"
      return 1
    }
    printf '%s\n' "$physical"
    return
  fi
  printf '%s\n' "$candidate"
}

fm_project_registry_names() {
  local registry=${1:-$(fm_projects_data_dir)/projects.md} name root path
  if [ ! -f "$registry" ]; then
    [ "$(fm_projects_mode)" = legacy-local ] || return 0
    root=$(fm_projects_root) || return
    [ -d "$root" ] || return 0
    for path in "$root"/*; do
      [ -d "$path" ] || continue
      [ ! -L "$path" ] || continue
      name=${path##*/}
      fm_project_name_valid "$name" || continue
      printf '%s\n' "$name"
    done
    return 0
  fi
  while IFS= read -r name; do
    fm_project_name_valid "$name" || {
      fm_projects_error "unsafe project name in $registry: $name"
      return 1
    }
    printf '%s\n' "$name"
  done < <(awk '$1 == "-" && $2 != "" && !seen[$2]++ { print $2 }' "$registry")
}

fm_project_is_registered() {
  local wanted=$1 name
  while IFS= read -r name; do
    [ "$name" = "$wanted" ] && return 0
  done < <(fm_project_registry_names)
  return 1
}

fm_projects_mutation_allowed() {
  [ "$(fm_projects_mode)" = legacy-local ] && return 0
  [ ! -f "$(fm_projects_home)/.fm-secondmate-home" ]
}
