#!/usr/bin/env bash
# One-command onboarding of a project container and its project secondmate.
#
# Usage: fm-project-init.sh <container-path-or-name> [--repo <name>]... [--mode <no-mistakes|direct-PR>] [--yolo] [--id <id>] [--description <text>] [--scope <text>] [--charter <text>|--charter-file <path>]
#   Runs only in shared-container mode with a durable config/projects-root and
#   config/home-role exactly "primary"; anything else fails closed before any
#   mutation, because container onboarding is canonical-state synchronization.
#   The container argument is a registered-name-style bare name (resolved as a
#   direct child of the configured projects root) or an absolute/relative path
#   that must normalize to a direct child of that root. A missing container
#   directory is created; an existing one must be a plain non-git directory.
#   Repositories are the explicit --repo names, or, when none are given, the
#   auto-detected direct children of the container that are git worktree roots;
#   at least one repository is required. Every repository is analyzed
#   READ-ONLY first (branch, dirty state, origin, docs presence) and the
#   analysis is printed as ANALYZE: lines, so the captain's product intent and
#   scope can be collected against real state. Dirty checkouts, branches,
#   worktrees, and existing operational homes are never touched.
#   The project registry line is written to data/projects.md as
#   "- <name> [<mode>] - <description> (repos: <r1>[, <r2>...]; added <date>)"
#   (with "+yolo" inside the brackets when --yolo is passed). When a line for
#   the project already exists it is validated instead: the same mode, yolo,
#   and repo set pass through idempotently, and any mismatch fails closed so a
#   drifted registry is reconciled by a human, never silently rewritten.
#   Delivery-mode initialization runs only for --mode no-mistakes (the mode
#   choice is the authorization): each repo missing the no-mistakes remote gets
#   "no-mistakes init && no-mistakes doctor" run inside it, the one sanctioned
#   client-repo mutation (AGENTS.md section 1/6). That gate setup is idempotent
#   and intentionally not rolled back on a later failure. direct-PR skips it.
#   The secondmate home is seeded at <container>/.secondmate through
#   bin/fm-home-seed.sh (which owns marker, charter copy, registry routing,
#   inherited config, and its own transactional rollback). The charter text
#   comes from --charter, --charter-file, or the FM_SECONDMATE_CHARTER
#   environment; --scope (or FM_SECONDMATE_SCOPE) overrides the routing scope.
#   Multi-repo containers get ONE secondmate across all registered sibling
#   repos; no per-repo clone is created in shared mode.
#   Failure rollback: a projects.md line added by this run is restored to the
#   pre-run registry, and a container directory created by this run is removed
#   only when empty. --mode local-only is refused: local-only work stays with
#   the main firstmate (AGENTS.md intake), so it gets no project secondmate.
#   On success prints the registry line, the seeded home, and the launch hint.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
REG="$DATA/projects.md"
# shellcheck source=bin/fm-projects-lib.sh
. "$SCRIPT_DIR/fm-projects-lib.sh"

usage() {
  sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'
}

CONTAINER_ARG=
MODE=no-mistakes
YOLO=0
ID=
DESC=
SCOPE=
CHARTER=
CHARTER_FILE=
REPOS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      repo) REPOS+=("$a") ;;
      mode) MODE=$a ;;
      id) ID=$a ;;
      description) DESC=$a ;;
      scope) SCOPE=$a ;;
      charter) CHARTER=$a ;;
      charter-file) CHARTER_FILE=$a ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    -h|--help) usage; exit 0 ;;
    --repo) want_value=repo ;;
    --repo=*) REPOS+=("${a#--repo=}") ;;
    --mode) want_value=mode ;;
    --mode=*) MODE=${a#--mode=} ;;
    --yolo) YOLO=1 ;;
    --id) want_value=id ;;
    --id=*) ID=${a#--id=} ;;
    --description) want_value=description ;;
    --description=*) DESC=${a#--description=} ;;
    --scope) want_value=scope ;;
    --scope=*) SCOPE=${a#--scope=} ;;
    --charter) want_value=charter ;;
    --charter=*) CHARTER=${a#--charter=} ;;
    --charter-file) want_value=charter-file ;;
    --charter-file=*) CHARTER_FILE=${a#--charter-file=} ;;
    --*) echo "error: unknown flag $a" >&2; usage; exit 1 ;;
    *)
      [ -z "$CONTAINER_ARG" ] || { echo "error: unexpected argument $a" >&2; usage; exit 1; }
      CONTAINER_ARG=$a
      ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
[ -n "$CONTAINER_ARG" ] || { usage; exit 1; }
case "$MODE" in
  no-mistakes|direct-PR) ;;
  local-only)
    echo "error: local-only projects keep their work with the main firstmate and get no project secondmate; register the project by hand instead" >&2
    exit 1
    ;;
  *) echo "error: --mode must be no-mistakes or direct-PR" >&2; exit 1 ;;
esac

# Shared-container preconditions: durable projects root and primary role.
[ "$(fm_projects_mode)" = shared-external ] || {
  echo "error: project onboarding requires shared-container mode (a configured config/projects-root); legacy single-repo projects are added per AGENTS.md project management" >&2
  exit 1
}
[ -f "$CONFIG/projects-root" ] || {
  echo "error: project onboarding requires a durable config/projects-root; FM_PROJECTS_OVERRIDE alone is not inherited into the secondmate home" >&2
  exit 1
}
role=$(fm_projects_home_role) || exit 1
[ "$role" = primary ] || {
  echo "error: project onboarding requires config/home-role to be primary; this home is '$role'" >&2
  exit 1
}
ROOT_DIR=$(fm_projects_root) || exit 1
ROOT_DIR=$(fm_projects_normalize_path "$ROOT_DIR") || exit 1

# Resolve the container: a bare valid name means <root>/<name>; a path must
# normalize to a direct child of the configured root.
case "$CONTAINER_ARG" in
  */*|.|..) CONTAINER=$(fm_projects_normalize_path "$CONTAINER_ARG") ;;
  *)
    if fm_project_name_valid "$CONTAINER_ARG"; then
      CONTAINER="$ROOT_DIR/$CONTAINER_ARG"
    else
      CONTAINER=$(fm_projects_normalize_path "$CONTAINER_ARG")
    fi
    ;;
esac
NAME=${CONTAINER##*/}
[ "${CONTAINER%/*}" = "$ROOT_DIR" ] || {
  echo "error: container must be a direct child of the configured projects root $ROOT_DIR: $CONTAINER" >&2
  exit 1
}
fm_project_container_name_valid "$NAME" || {
  echo "error: reserved or unsafe project container name: $NAME" >&2
  exit 1
}
if [ -L "$CONTAINER" ]; then
  echo "error: project container must not be a symlink: $CONTAINER" >&2
  exit 1
fi
CONTAINER_EXISTS=0
if [ -e "$CONTAINER" ]; then
  [ -d "$CONTAINER" ] || { echo "error: $CONTAINER exists and is not a directory" >&2; exit 1; }
  top=$(git -C "$CONTAINER" rev-parse --show-toplevel 2>/dev/null || true)
  [ -z "$top" ] || {
    echo "error: project container must not be a git checkout or live inside one: $CONTAINER" >&2
    exit 1
  }
  CONTAINER_EXISTS=1
fi

# Resolve the repo list: explicit --repo names, else auto-detected direct-child
# git worktree roots of an existing container.
if [ "${#REPOS[@]}" -eq 0 ] && [ "$CONTAINER_EXISTS" -eq 1 ]; then
  for candidate in "$CONTAINER"/*; do
    [ -d "$candidate" ] || continue
    [ ! -L "$candidate" ] || continue
    base=${candidate##*/}
    [ "$base" != ".secondmate" ] || continue
    top=$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null || true)
    [ -n "$top" ] || continue
    [ "$(fm_projects_normalize_path "$top")" = "$(fm_projects_normalize_path "$candidate")" ] || continue
    REPOS+=("$base")
  done
fi
[ "${#REPOS[@]}" -gt 0 ] || {
  echo "error: no repositories: pass --repo <name> (repeatable) or point at a container that already holds git repos" >&2
  exit 1
}

# Read-only analysis of every repository; onboarding never mutates a checkout.
for repo in "${REPOS[@]}"; do
  fm_project_repo_name_valid "$repo" || { echo "error: unsafe repo name: $repo" >&2; exit 1; }
  path="$CONTAINER/$repo"
  [ -d "$path" ] || { echo "error: repo $repo not found at $path" >&2; exit 1; }
  top=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null || true)
  [ -n "$top" ] && [ "$(fm_projects_normalize_path "$top")" = "$(fm_projects_normalize_path "$path")" ] || {
    echo "error: repo $repo at $path is not a git worktree root" >&2
    exit 1
  }
  branch=$(git -C "$path" symbolic-ref --short -q HEAD || echo detached)
  if [ -n "$(git -C "$path" status --porcelain 2>/dev/null | head -1)" ]; then
    dirty=yes
  else
    dirty=no
  fi
  origin=$(git -C "$path" remote get-url origin 2>/dev/null || echo none)
  [ "$origin" != none ] || {
    echo "error: repo $repo has no origin remote; $MODE projects push to origin" >&2
    exit 1
  }
  agents=no
  [ -f "$path/AGENTS.md" ] && agents=yes
  readme=no
  [ -f "$path/README.md" ] && readme=yes
  echo "ANALYZE: $repo: branch=$branch dirty=$dirty origin=$origin agents-md=$agents readme=$readme"
done

# Charter and description inputs.
if [ -n "$CHARTER_FILE" ]; then
  [ -f "$CHARTER_FILE" ] || { echo "error: charter file not found: $CHARTER_FILE" >&2; exit 1; }
  CHARTER=$(cat "$CHARTER_FILE")
fi
[ -n "$CHARTER" ] || CHARTER=${FM_SECONDMATE_CHARTER:-}
[ -n "$SCOPE" ] || SCOPE=${FM_SECONDMATE_SCOPE:-}
[ -n "$ID" ] || ID=$NAME
case "$ID" in
  ''|.*|*[!A-Za-z0-9._-]*) echo "error: unsafe secondmate id: $ID" >&2; exit 1 ;;
esac
BRIEF="$DATA/$ID/brief.md"
if [ -z "$CHARTER" ] && [ ! -f "$BRIEF" ]; then
  echo "error: no charter: pass --charter/--charter-file (the captain's product intent and secondmate scope) or pre-fill $BRIEF" >&2
  exit 1
fi
one_line() {
  tr '\n' ' ' | tr -d '();' | sed 's/[[:space:]]\{1,\}/ /g; s/^ //; s/ $//'
}
[ -n "$DESC" ] || DESC=$(printf '%s\n' "${CHARTER:-$NAME project}" | one_line)
DESC=$(printf '%s\n' "$DESC" | one_line)
[ -n "$DESC" ] || { echo "error: empty project description" >&2; exit 1; }

mode_token="[$MODE]"
[ "$YOLO" -eq 0 ] || mode_token="[$MODE +yolo]"
repos_csv=
for repo in "${REPOS[@]}"; do
  repos_csv="${repos_csv}${repos_csv:+, }$repo"
done
today=$(date +%F)
REG_LINE="- $NAME $mode_token - $DESC (repos: $repos_csv; added $today)"

# Registry: add the line, or validate an existing one idempotently.
REG_EXISTED=0
REG_BACKUP=
INIT_COMMITTED=0
CONTAINER_CREATED=0
rollback() {
  [ "$INIT_COMMITTED" -eq 1 ] && return 0
  if [ -n "$REG_BACKUP" ]; then
    if [ "$REG_EXISTED" -eq 1 ]; then
      cp "$REG_BACKUP" "$REG" 2>/dev/null || true
    else
      rm -f "$REG" 2>/dev/null || true
    fi
    rm -f "$REG_BACKUP" 2>/dev/null || true
  fi
  if [ "$CONTAINER_CREATED" -eq 1 ]; then
    rmdir "$CONTAINER" 2>/dev/null || true
  fi
}
trap rollback EXIT

reg_rc=0
existing_line=$(fm_project_registry_line "$NAME") || reg_rc=$?
if [ "$reg_rc" -ge 2 ]; then
  echo "error: project registry is unreadable or already holds duplicate lines for $NAME; fix data/projects.md before onboarding" >&2
  exit 1
fi
if [ -n "$existing_line" ]; then
  existing_repos=$(fm_project_registry_repo_names "$NAME" 2>/dev/null | sort | tr '\n' ',' || true)
  wanted_repos=$(printf '%s\n' "${REPOS[@]}" | sort | tr '\n' ',')
  read -r existing_mode existing_yolo <<EOF
$("$FM_ROOT/bin/fm-project-mode.sh" "$NAME" 2>/dev/null || echo "unknown unknown")
EOF
  wanted_yolo=off
  [ "$YOLO" -eq 0 ] || wanted_yolo=on
  if [ "$existing_repos" != "$wanted_repos" ] || [ "$existing_mode" != "$MODE" ] || [ "$existing_yolo" != "$wanted_yolo" ]; then
    echo "error: project $NAME is already registered and disagrees with this run (registered: $existing_line); reconcile data/projects.md by hand before re-running" >&2
    exit 1
  fi
  echo "REGISTRY: $NAME already registered and consistent; leaving the line unchanged"
else
  mkdir -p "$DATA"
  REG_BACKUP=$(mktemp "${TMPDIR:-/tmp}/fm-project-init-reg.XXXXXX")
  if [ -f "$REG" ]; then
    REG_EXISTED=1
    cp "$REG" "$REG_BACKUP"
  fi
  printf '%s\n' "$REG_LINE" >> "$REG"
  echo "REGISTRY: added: $REG_LINE"
fi

if [ "$CONTAINER_EXISTS" -eq 0 ]; then
  mkdir -p "$CONTAINER"
  CONTAINER_CREATED=1
fi

# Delivery-gate initialization, no-mistakes mode only. Idempotent per repo and
# intentionally not rolled back (see header).
if [ "$MODE" = no-mistakes ]; then
  command -v no-mistakes >/dev/null 2>&1 || {
    echo "error: no-mistakes command not found; install it or onboard with --mode direct-PR" >&2
    exit 1
  }
  for repo in "${REPOS[@]}"; do
    path="$CONTAINER/$repo"
    if git -C "$path" remote get-url no-mistakes >/dev/null 2>&1; then
      echo "DELIVERY: $repo already initialized for no-mistakes"
      continue
    fi
    ( cd "$path" && no-mistakes init && no-mistakes doctor ) || {
      echo "error: no-mistakes init failed for $repo at $path" >&2
      exit 1
    }
    echo "DELIVERY: $repo initialized for no-mistakes"
  done
fi

# Seed the secondmate home; fm-home-seed.sh owns its own transactional rollback.
export FM_SECONDMATE_CHARTER="$CHARTER"
if [ -n "$SCOPE" ]; then
  export FM_SECONDMATE_SCOPE="$SCOPE"
fi
seed_out=$("$FM_ROOT/bin/fm-home-seed.sh" "$ID" "$CONTAINER/.secondmate" "$NAME") || {
  echo "error: secondmate seeding failed; registry and created container were rolled back" >&2
  exit 1
}
HOME_PATH=$(printf '%s\n' "$seed_out" | sed -n 's/^home=//p')

INIT_COMMITTED=1
trap - EXIT
rm -f "$REG_BACKUP" 2>/dev/null || true
echo "SEEDED: secondmate $ID at ${HOME_PATH:-$CONTAINER/.secondmate}"
echo "NEXT: launch or attach it from the container with: bin/secondmate <claude|codex|auto>"
