# shellcheck shell=bash
# Project-container and legacy project resolution.
#
# Source this library after FM_HOME, FM_DATA_OVERRIDE, and FM_CONFIG_OVERRIDE are
# resolved by the caller.
# The project-base precedence is:
#   1. non-empty FM_PROJECTS_OVERRIDE;
#   2. the single absolute path in config/projects-root;
#   3. the legacy $FM_HOME/projects directory.
#
# Without an override or config file, data/projects.md keeps the legacy contract:
# each registered project maps to one repo at $FM_HOME/projects/<project>.
# With an override or config file, the root is a container base. Every project
# registry line must declare `(repos: <repo>[, <repo>...]; added <date>)`; the
# project container is the same-named direct child of the root and every repo is
# an explicitly listed direct child of that non-git container. Shared/container
# mode never discovers projects or repos by globbing the root.
#
# Shared container repos are mutation-owned by the primary firstmate home. A
# secondmate home may resolve and dispatch work against them but must not
# fleet-sync those canonical checkouts.

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

fm_projects_validate_root_value() {
  local value=$1 source=$2
  case "$value" in
    /*) ;;
    *)
      fm_projects_error "$source must contain an absolute path"
      return 2
      ;;
  esac
  [ -d "$value" ] || {
    fm_projects_error "$source is not a directory: $value"
    return 2
  }
  fm_projects_normalize_path "$value"
}

# Status 1 means genuine absence only. Invalid, unreadable, or symlinked config
# is status 2 so callers never fail open to the legacy mutation root.
fm_projects_configured_root() {
  local file line count normalized
  file="$(fm_projects_config_dir)/projects-root"
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    return 1
  fi
  if [ -L "$file" ]; then
    fm_projects_error "$file must not be a symlink"
    return 2
  fi
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    fm_projects_error "$file must be a readable regular file"
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
  if ! normalized=$(fm_projects_validate_root_value "$line" "$file") || [ -z "$normalized" ]; then
    fm_projects_error "failed to normalize configured projects root: $line"
    return 2
  fi
  printf '%s\n' "$normalized"
}

fm_projects_root_source() {
  local file
  if [ -n "${FM_PROJECTS_OVERRIDE:-}" ]; then
    printf 'override\n'
    return
  fi
  file="$(fm_projects_config_dir)/projects-root"
  if [ -e "$file" ] || [ -L "$file" ]; then
    fm_projects_configured_root >/dev/null || return
    printf 'config\n'
    return
  fi
  printf 'legacy\n'
}

fm_projects_root() {
  local configured rc
  if [ -n "${FM_PROJECTS_OVERRIDE:-}" ]; then
    # Preserve the historical test/operator override contract byte-for-byte.
    # Durable config is validated strictly below; the one-shot override may
    # intentionally name a path that another guarded operation will create.
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
  local source
  source=$(fm_projects_root_source) || return
  if [ "$source" = legacy ]; then
    printf 'legacy-local\n'
  else
    printf 'shared-external\n'
  fi
}

fm_project_name_valid() {
  local name=$1
  case "$name" in
    ''|.|..|.*|*/*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

fm_project_container_name_valid() {
  local name=$1
  fm_project_name_valid "$name" || return 1
  case "$name" in
    firstmate|workspaces|projects|state|data|config) return 1 ;;
  esac
  return 0
}

fm_project_repo_name_valid() {
  fm_project_name_valid "$1"
}

fm_project_registry_line() {
  local name=$1 registry=${2:-$(fm_projects_data_dir)/projects.md} lines count
  [ -f "$registry" ] || return 1
  lines=$(awk -v n="$name" '$1 == "-" && $2 == n { print }' "$registry") || {
    fm_projects_error "cannot read project registry: $registry"
    return 2
  }
  count=$(printf '%s\n' "$lines" | awk 'NF { n++ } END { print n+0 }') || return 2
  case "$count" in
    0) return 1 ;;
    1) printf '%s\n' "$lines" ;;
    *)
      fm_projects_error "duplicate project name in $registry: $name"
      return 2
      ;;
  esac
}

fm_project_registry_names() {
  local registry=${1:-$(fm_projects_data_dir)/projects.md} names name root path seen
  if [ ! -e "$registry" ]; then
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
  if [ ! -f "$registry" ] || [ ! -r "$registry" ]; then
    fm_projects_error "project registry must be a readable regular file: $registry"
    return 1
  fi
  names=$(awk '$1 == "-" && $2 != "" { print $2 }' "$registry") || {
    fm_projects_error "cannot read project registry: $registry"
    return 1
  }
  seen=
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    fm_project_name_valid "$name" || {
      fm_projects_error "unsafe project name in $registry: $name"
      return 1
    }
    case "$seen" in
      *"|$name|"*)
        fm_projects_error "duplicate project name in $registry: $name"
        return 1
        ;;
    esac
    seen="${seen}|$name|"
    printf '%s\n' "$name"
  done <<EOF
$names
EOF
}

fm_project_is_registered() {
  local wanted=$1 names name
  names=$(fm_project_registry_names) || return
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ "$name" = "$wanted" ] && return 0
  done <<EOF
$names
EOF
  return 1
}

fm_project_registry_repo_names() {
  local name=$1 line text rest repo seen
  line=$(fm_project_registry_line "$name") || return
  text=$(printf '%s\n' "$line" | sed -n 's/.*(repos: \([^;)]*\); added [^)]*)$/\1/p') || return 1
  [ -n "$text" ] || {
    fm_projects_error "shared project $name must declare (repos: <repo>[, <repo>...]; added <date>)"
    return 1
  }
  rest=$text
  seen=
  while :; do
    case "$rest" in
      *,*) repo=${rest%%,*}; rest=${rest#*,} ;;
      *) repo=$rest; rest= ;;
    esac
    repo=$(printf '%s' "$repo" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    fm_project_repo_name_valid "$repo" || {
      fm_projects_error "unsafe repo name for project $name: ${repo:-<empty>}"
      return 1
    }
    case "$seen" in
      *"|$repo|"*)
        fm_projects_error "duplicate repo name for project $name: $repo"
        return 1
        ;;
    esac
    seen="${seen}|$repo|"
    printf '%s\n' "$repo"
    [ -n "$rest" ] || break
  done
}

fm_project_legacy_path() {
  local name=$1 root candidate physical
  fm_project_name_valid "$name" || {
    fm_projects_error "unsafe project name: $name"
    return 1
  }
  root=$(fm_projects_normalize_path "$(fm_projects_legacy_root)") || return
  candidate="$root/$name"
  if [ -L "$candidate" ]; then
    fm_projects_error "legacy project path must not be a symlink: $candidate"
    return 1
  fi
  if [ -d "$candidate" ]; then
    physical=$(cd "$candidate" && pwd -P) || return 1
    [ "${physical%/*}" = "$root" ] && [ "${physical##*/}" = "$name" ] || {
      fm_projects_error "legacy project path must remain a direct child of $root: $candidate"
      return 1
    }
    printf '%s\n' "$physical"
    return
  fi
  printf '%s\n' "$candidate"
}

fm_project_container_path() {
  local name=$1 root candidate physical top
  fm_project_container_name_valid "$name" || {
    fm_projects_error "reserved or unsafe project container name: $name"
    return 1
  }
  fm_project_is_registered "$name" || {
    fm_projects_error "project is not registered: $name"
    return 1
  }
  root=$(fm_projects_root) || return
  root=$(fm_projects_normalize_path "$root") || return
  candidate="$root/$name"
  [ ! -L "$candidate" ] || {
    fm_projects_error "project container must not be a symlink: $candidate"
    return 1
  }
  [ -d "$candidate" ] || {
    fm_projects_error "project container is not a directory: $candidate"
    return 1
  }
  physical=$(cd "$candidate" && pwd -P) || return 1
  [ "${physical%/*}" = "$root" ] && [ "${physical##*/}" = "$name" ] || {
    fm_projects_error "project container must remain a direct child of $root: $candidate"
    return 1
  }
  top=$(git -C "$physical" rev-parse --show-toplevel 2>/dev/null || true)
  [ -z "$top" ] || {
    fm_projects_error "project container must not be a git checkout or live inside one: $physical"
    return 1
  }
  printf '%s\n' "$physical"
}

fm_project_repo_paths() {
  local name=$1 mode container repos repo candidate physical top
  fm_project_name_valid "$name" || {
    fm_projects_error "unsafe project name: $name"
    return 1
  }
  mode=$(fm_projects_mode) || return
  if [ "$mode" = legacy-local ]; then
    fm_project_legacy_path "$name"
    return
  fi
  fm_project_is_registered "$name" || {
    fm_projects_error "project is not registered: $name"
    return 1
  }
  container=$(fm_project_container_path "$name") || return
  repos=$(fm_project_registry_repo_names "$name") || return
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    candidate="$container/$repo"
    [ ! -L "$candidate" ] || {
      fm_projects_error "project repo must not be a symlink: $candidate"
      return 1
    }
    [ -d "$candidate" ] || {
      fm_projects_error "registered project repo is not a directory: $candidate"
      return 1
    }
    physical=$(cd "$candidate" && pwd -P) || return 1
    [ "${physical%/*}" = "$container" ] && [ "${physical##*/}" = "$repo" ] || {
      fm_projects_error "project repo must remain a direct child of $container: $candidate"
      return 1
    }
    top=$(git -C "$physical" rev-parse --show-toplevel 2>/dev/null || true)
    if [ -z "$top" ] || [ "$(fm_projects_normalize_path "$top")" != "$physical" ]; then
      fm_projects_error "registered project repo must be a git worktree root: $physical"
      return 1
    fi
    printf '%s\n' "$physical"
  done <<EOF
$repos
EOF
}

# Resolve one repo for a project. Multi-repo projects require an explicit repo
# selector, normally `<project>/<repo>` at a caller-facing command boundary.
fm_project_path() {
  local name=$1 wanted=${2:-} paths path found count
  paths=$(fm_project_repo_paths "$name") || return
  found=
  count=0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if [ -n "$wanted" ]; then
      [ "${path##*/}" = "$wanted" ] || continue
      found=$path
      count=$((count + 1))
    else
      found=$path
      count=$((count + 1))
    fi
  done <<EOF
$paths
EOF
  if [ "$count" -eq 1 ]; then
    printf '%s\n' "$found"
    return
  fi
  if [ -n "$wanted" ]; then
    fm_projects_error "project $name has no registered repo named $wanted"
  else
    fm_projects_error "project $name has $count repos; select one as $name/<repo>"
  fi
  return 1
}

fm_project_resolve_arg() {
  local arg=$1 selector project repo path normalized container repos names
  selector=$arg
  case "$selector" in
    projects/*) selector=${selector#projects/} ;;
  esac
  project=${selector%%/*}
  if fm_project_name_valid "$project" && { fm_project_is_registered "$project" || [ "$(fm_projects_mode)" = legacy-local ]; }; then
    if [ "$selector" = "$project" ]; then
      fm_project_path "$project"
      return
    fi
    repo=${selector#*/}
    case "$repo" in
      */*) ;;
      *)
        fm_project_path "$project" "$repo"
        return
        ;;
    esac
  fi
  if [ "$(fm_projects_mode)" = shared-external ]; then
    normalized=$(fm_projects_normalize_path "$arg") || return
    names=$(fm_project_registry_names) || return
    while IFS= read -r project; do
      [ -n "$project" ] || continue
      container=$(fm_project_container_path "$project") || return
      if [ "$normalized" = "$container" ]; then
        fm_project_path "$project"
        return
      fi
      repos=$(fm_project_repo_paths "$project") || return
      while IFS= read -r path; do
        [ -n "$path" ] || continue
        case "$normalized" in
          "$path"|"$path"/*)
            printf '%s\n' "$path"
            return
            ;;
        esac
      done <<EOF
$repos
EOF
    done <<EOF
$names
EOF
    fm_projects_error "path or selector is not a registered project container or repo: $arg"
    return 1
  fi
  printf '%s\n' "$arg"
}

fm_project_name_from_arg() {
  local arg=$1 selector project repo
  selector=$arg
  case "$selector" in
    projects/*) selector=${selector#projects/} ;;
  esac
  project=${selector%%/*}
  if fm_project_name_valid "$project" && fm_project_is_registered "$project"; then
    if [ "$selector" = "$project" ]; then
      printf '%s\n' "$project"
      return
    fi
    repo=${selector#*/}
    case "$repo" in
      */*) ;;
      *)
        if fm_project_path "$project" "$repo" >/dev/null; then
          printf '%s\n' "$project"
          return
        fi
        ;;
    esac
  fi
  fm_project_name_for_path "$arg"
}

fm_project_name_for_path() {
  local input=$1 normalized names name container repos repo matches match
  if fm_project_name_valid "$input" && fm_project_is_registered "$input"; then
    printf '%s\n' "$input"
    return
  fi
  normalized=$(fm_projects_normalize_path "$input") || return
  names=$(fm_project_registry_names) || return
  matches=0
  match=
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ "$(fm_projects_mode)" = shared-external ]; then
      container=$(fm_project_container_path "$name") || return
      if [ "$normalized" = "$container" ]; then
        match=$name
        matches=$((matches + 1))
        continue
      fi
    fi
    repos=$(fm_project_repo_paths "$name") || return
    while IFS= read -r repo; do
      [ -n "$repo" ] || continue
      case "$normalized" in
        "$repo"|"$repo"/*)
          match=$name
          matches=$((matches + 1))
          break
          ;;
      esac
    done <<EOF
$repos
EOF
  done <<EOF
$names
EOF
  case "$matches" in
    1) printf '%s\n' "$match" ;;
    0)
      fm_projects_error "path is not inside a registered project container or repo: $input"
      return 1
      ;;
    *)
      fm_projects_error "path matches multiple registered projects: $input"
      return 1
      ;;
  esac
}

fm_projects_home_role() {
  local file role lines
  file="$(fm_projects_config_dir)/home-role"
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    fm_projects_error "shared project synchronization requires $file containing exactly primary or secondmate"
    return 1
  fi
  if [ -L "$file" ] || [ ! -f "$file" ] || [ ! -r "$file" ]; then
    fm_projects_error "$file must be a readable regular file containing exactly primary or secondmate"
    return 1
  fi
  role=$(cat "$file" 2>/dev/null) || {
    fm_projects_error "cannot read shared home role: $file"
    return 1
  }
  lines=$(grep -c '^' "$file" 2>/dev/null) || {
    fm_projects_error "cannot validate shared home role: $file"
    return 1
  }
  case "$role:$lines" in
    primary:1|secondmate:1) printf '%s\n' "$role" ;;
    *)
      fm_projects_error "$file must contain exactly primary or secondmate"
      return 1
      ;;
  esac
}

fm_projects_mutation_allowed() {
  [ "$(fm_projects_mode)" = legacy-local ] && return 0
  [ "$(fm_projects_home_role)" = primary ]
}
