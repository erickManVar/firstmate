#!/usr/bin/env bash
# Focused behavior tests for registry-driven project containers, colocated
# secondmate homes, legacy project compatibility, sync, and route lookup.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT_LOGICAL=$(mktemp -d "${TMPDIR:-/tmp}/fm-projects-root.XXXXXX")
TMP_ROOT=$(cd "$TMP_ROOT_LOGICAL" && pwd -P)
trap 'rm -rf "$TMP_ROOT_LOGICAL"' EXIT
fm_git_identity

resolver_call() {
  local home=$1 expression=$2
  shift 2
  env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$@" bash -c \
    '. "$1/bin/fm-projects-lib.sh"; eval "$2"' bash "$ROOT" "$expression"
}

make_repo() {
  local path=$1 remote=$2
  fm_git_init_commit "$path"
  fm_git_add_origin "$path" "$remote"
}

test_resolver_precedence_and_fail_closed_config() {
  local home base override out err
  home="$TMP_ROOT/resolver-home"
  base="$TMP_ROOT/orca-base"
  override="$TMP_ROOT/override-base"
  err="$TMP_ROOT/resolver.err"
  mkdir -p "$home/config" "$home/data" "$home/projects" "$base" "$override"

  out=$(resolver_call "$home" 'fm_projects_root') || fail "legacy root resolution failed"
  [ "$out" = "$home/projects" ] || fail "legacy root was not FM_HOME/projects"
  out=$(resolver_call "$home" 'fm_projects_mode')
  [ "$out" = legacy-local ] || fail "absent config did not preserve legacy mode"

  printf '%s\n' "$base" > "$home/config/projects-root"
  out=$(resolver_call "$home" 'fm_projects_root') || fail "configured base resolution failed"
  [ "$out" = "$base" ] || fail "config/projects-root did not win"
  out=$(resolver_call "$home" 'fm_projects_mode')
  [ "$out" = shared-external ] || fail "configured base did not select shared container mode"

  printf '%s\n' "$home/projects" > "$home/config/projects-root"
  out=$(resolver_call "$home" 'fm_projects_mode') \
    || fail "configured legacy-path mode resolution failed"
  [ "$out" = shared-external ] \
    || fail "config/projects-root presence did not explicitly select shared-external mode"

  out=$(resolver_call "$home" 'fm_projects_root' FM_PROJECTS_OVERRIDE="$override") \
    || fail "override base resolution failed"
  [ "$out" = "$override" ] || fail "FM_PROJECTS_OVERRIDE did not have highest precedence"
  out=$(resolver_call "$home" 'fm_projects_mode' FM_PROJECTS_OVERRIDE="$home/projects") \
    || fail "legacy-path override mode resolution failed"
  [ "$out" = shared-external ] \
    || fail "FM_PROJECTS_OVERRIDE did not explicitly select shared-external mode"

  rm "$home/config/projects-root"
  out=$(resolver_call "$home" 'fm_projects_mode') || fail "absent config mode resolution failed"
  [ "$out" = legacy-local ] || fail "genuinely absent config was not classified legacy-local"

  printf '%s\n' 'relative/catalog' > "$home/config/projects-root"
  if resolver_call "$home" 'fm_projects_root' > /dev/null 2>"$err"; then
    fail "relative config/projects-root was accepted"
  fi
  assert_grep 'must contain an absolute path' "$err" "relative-root refusal was not explained"

  rm -f "$home/config/projects-root"
  ln -s "$home/config/missing-root" "$home/config/projects-root"
  if resolver_call "$home" 'fm_projects_root' > /dev/null 2>"$err"; then
    fail "dangling projects-root symlink fell back to legacy projects"
  fi
  assert_grep 'must not be a symlink' "$err" "dangling config did not fail closed"

  rm -f "$home/config/projects-root"
  mkdir "$home/config/projects-root"
  if resolver_call "$home" 'fm_projects_root' > /dev/null 2>"$err"; then
    fail "non-file config/projects-root fell back to the legacy root"
  fi
  assert_grep 'readable regular file' "$err" "non-file root refusal was not explained"

  rm -rf "$home/config/projects-root"
  printf '%s\n' "$base" > "$home/config/projects-root"
  if resolver_call "$home" 'awk() { return 1; }; fm_projects_root' > /dev/null 2>"$err"; then
    fail "config/projects-root read failure fell back to the legacy root"
  fi
  assert_grep 'failed to read configured projects root' "$err" \
    "configured-root read failure was not explained"

  if resolver_call "$home" 'pwd() { return 1; }; fm_projects_root' > /dev/null 2>"$err"; then
    fail "config/projects-root normalization failure fell back to the legacy root"
  fi
  assert_grep 'failed to normalize configured projects root' "$err" \
    "configured-root normalization failure was not explained"

  printf '%s\n' "$base" > "$home/config/projects-root"
  mkdir -p "$base/alpha" "$base/firstmate" "$base/.secondmates"
  printf '%s\n' '- alpha [direct-PR] - alpha (repos: repo; added 2026-07-13)' > "$home/data/projects.md"
  out=$(resolver_call "$home" 'fm_project_registry_names')
  [ "$out" = alpha ] || fail "registry enumeration included an unregistered shared-root directory"
  if resolver_call "$home" 'fm_project_path ../alpha' >/dev/null 2>"$err"; then
    fail "unsafe project name was accepted"
  fi
  pass "project resolver preserves provenance, fails closed, and enumerates the registry only"
}

setup_container_world() {
  MAIN_HOME="$TMP_ROOT/main-home"
  ORCA_BASE="$TMP_ROOT/orca"
  ALPHA_CONTAINER="$ORCA_BASE/alpha"
  GAMMA_CONTAINER="$ORCA_BASE/gamma"
  ALPHA_API="$ALPHA_CONTAINER/api"
  ALPHA_WEB="$ALPHA_CONTAINER/web"
  GAMMA_REPO="$GAMMA_CONTAINER/service"
  ALPHA_HOME="$ALPHA_CONTAINER/.secondmate"
  mkdir -p "$MAIN_HOME/config" "$MAIN_HOME/data" "$MAIN_HOME/state" "$MAIN_HOME/projects"
  mkdir -p "$ORCA_BASE/workspaces" "$ORCA_BASE/firstmate" "$ALPHA_CONTAINER" "$GAMMA_CONTAINER"
  make_repo "$ALPHA_API" "$TMP_ROOT/remotes/alpha-api.git"
  make_repo "$ALPHA_WEB" "$TMP_ROOT/remotes/alpha-web.git"
  make_repo "$GAMMA_REPO" "$TMP_ROOT/remotes/gamma.git"
  git -C "$GAMMA_REPO" remote add no-mistakes "file://$TMP_ROOT/remotes/no-mistakes-gamma.git"
  cat > "$MAIN_HOME/data/projects.md" <<EOF
- alpha [direct-PR] - alpha product (repos: api, web; added 2026-07-13)
- gamma [no-mistakes] - gamma product (repos: service; added 2026-07-13)
EOF
  printf '%s\n' "$ORCA_BASE" > "$MAIN_HOME/config/projects-root"
}

test_registry_drives_containers_and_repo_selection() {
  local out err names bad_home bad_base
  setup_container_world
  err="$TMP_ROOT/container.err"
  names=$(resolver_call "$MAIN_HOME" 'fm_project_registry_names') \
    || fail "container registry enumeration failed"
  [ "$names" = $'alpha\ngamma' ] || fail "registry names were not authoritative: $names"

  out=$(resolver_call "$MAIN_HOME" 'fm_project_container_path alpha') \
    || fail "alpha container did not resolve"
  [ "$out" = "$ALPHA_CONTAINER" ] || fail "alpha container resolved incorrectly: $out"
  out=$(resolver_call "$MAIN_HOME" 'fm_project_repo_paths alpha') \
    || fail "alpha repos did not resolve"
  [ "$out" = "$ALPHA_API"$'\n'"$ALPHA_WEB" ] || fail "alpha repos were not explicit and ordered: $out"
  out=$(resolver_call "$MAIN_HOME" 'fm_project_path alpha api') \
    || fail "alpha/api selector did not resolve"
  [ "$out" = "$ALPHA_API" ] || fail "alpha/api resolved incorrectly: $out"
  out=$(resolver_call "$MAIN_HOME" 'fm_project_resolve_arg alpha/web') \
    || fail "alpha/web caller selector did not resolve"
  [ "$out" = "$ALPHA_WEB" ] || fail "alpha/web resolved incorrectly: $out"
  out=$(resolver_call "$MAIN_HOME" "fm_project_resolve_arg '$ALPHA_WEB/src'") \
    || fail "registered repo subdirectory did not resolve"
  [ "$out" = "$ALPHA_WEB" ] || fail "registered repo subdirectory did not resolve to its repo: $out"
  if resolver_call "$MAIN_HOME" 'fm_project_path alpha' > /dev/null 2>"$err"; then
    fail "multi-repo project resolved without a repo selector"
  fi
  assert_grep 'select one as alpha/<repo>' "$err" "multi-repo ambiguity was not explained"

  mkdir -p "$ORCA_BASE/unregistered"
  make_repo "$ORCA_BASE/unregistered/repo" "$TMP_ROOT/remotes/unregistered.git"
  assert_not_contains "$names" unregistered "unregistered container was discovered"
  if resolver_call "$MAIN_HOME" "fm_project_resolve_arg '$ORCA_BASE/unregistered/repo'" \
      > /dev/null 2>"$err"; then
    fail "shared resolver accepted an unregistered checkout path"
  fi
  assert_grep 'not a registered project container or repo' "$err" \
    "shared resolver did not reject an unregistered checkout path"

  bad_home="$TMP_ROOT/reserved-home"
  bad_base="$TMP_ROOT/reserved-base"
  mkdir -p "$bad_home/config" "$bad_home/data" "$bad_home/projects" "$bad_base/workspaces/repo"
  printf '%s\n' "$bad_base" > "$bad_home/config/projects-root"
  printf '%s\n' '- workspaces [direct-PR] - reserved (repos: repo; added 2026-07-13)' > "$bad_home/data/projects.md"
  if resolver_call "$bad_home" 'fm_project_container_path workspaces' > /dev/null 2>"$err"; then
    fail "reserved Orca workspaces directory was accepted as a project container"
  fi
  assert_grep 'reserved or unsafe project container' "$err" "reserved container refusal was not explicit"

  rm -f "$bad_home/data/projects.md"
  mkdir "$bad_home/data/projects.md"
  if resolver_call "$bad_home" 'fm_project_registry_names' > /dev/null 2>"$err"; then
    fail "invalid registry type looked like an empty registry"
  fi
  assert_grep 'readable regular file' "$err" "registry read failure was swallowed"

  rmdir "$bad_home/data/projects.md"
  cat > "$bad_home/data/projects.md" <<EOF
- alpha [direct-PR] - first (repos: api; added 2026-07-13)
- beta [direct-PR] - middle (repos: api; added 2026-07-13)
- alpha [direct-PR] - duplicate (repos: web; added 2026-07-13)
EOF
  if resolver_call "$bad_home" 'fm_project_registry_names' > /dev/null 2>"$err"; then
    fail "non-adjacent duplicate project registry entries were accepted"
  fi
  assert_grep 'duplicate project name' "$err" "duplicate project refusal was not explicit"

  printf '%s\n' '- alpha [direct-PR] - duplicate repos (repos: api, web, api; added 2026-07-13)' \
    > "$bad_home/data/projects.md"
  if resolver_call "$bad_home" 'fm_project_registry_repo_names alpha' > /dev/null 2>"$err"; then
    fail "non-adjacent duplicate repo registry entries were accepted"
  fi
  assert_grep 'duplicate repo name' "$err" "duplicate repo refusal was not explicit"
  pass "registered containers resolve one or many sibling repos without root discovery"
}

test_legacy_single_repo_compatibility() {
  local home out
  home="$TMP_ROOT/legacy-home"
  mkdir -p "$home/config" "$home/data" "$home/projects"
  make_repo "$home/projects/legacy" "$TMP_ROOT/remotes/legacy.git"
  printf '%s\n' '- legacy [direct-PR] - legacy project (added 2026-07-13)' > "$home/data/projects.md"
  out=$(resolver_call "$home" 'fm_project_path legacy') || fail "legacy project did not resolve"
  [ "$out" = "$home/projects/legacy" ] || fail "legacy project path changed: $out"
  pass "absent projects-root preserves the one-repo FM_HOME/projects contract"
}

test_container_seed_is_reference_only_and_colocated() {
  local before_api before_web out bad_home bad_repo_home unregistered_repo_home reserved_home err
  before_api=$(git -C "$ALPHA_API" status --porcelain=v1; git -C "$ALPHA_API" rev-parse HEAD)
  before_web=$(git -C "$ALPHA_WEB" status --porcelain=v1; git -C "$ALPHA_WEB" rev-parse HEAD)

  bad_repo_home="$ALPHA_API/.secondmate"
  err="$TMP_ROOT/inside-repo.err"
  if FM_HOME="$MAIN_HOME" FM_SECONDMATE_CHARTER='alpha api domain' \
      "$ROOT/bin/fm-home-seed.sh" alpha-api-sm "$bad_repo_home" alpha > /dev/null 2>"$err"; then
    fail "shared seed accepted a secondmate home inside a registered canonical repo"
  fi
  assert_grep 'secondmate home cannot be inside registered canonical repo' "$err" \
    "shared seed did not explain canonical repo home refusal"
  assert_absent "$bad_repo_home" "shared seed created a secondmate home inside alpha/api"

  reserved_home="$ORCA_BASE/workspaces/.secondmate"
  err="$TMP_ROOT/reserved-workspaces-home.err"
  if FM_HOME="$MAIN_HOME" FM_SECONDMATE_CHARTER='reserved workspace domain' \
      "$ROOT/bin/fm-home-seed.sh" workspace-sm "$reserved_home" alpha > /dev/null 2>"$err"; then
    fail "shared seed accepted a secondmate home inside reserved workspaces"
  fi
  assert_grep 'secondmate home cannot be inside reserved Orca workspaces subtree' "$err" \
    "shared seed did not explain reserved workspace home refusal"
  assert_absent "$reserved_home" "shared seed created a secondmate home inside reserved workspaces"

  unregistered_repo_home="$ORCA_BASE/base-commerce/.secondmate"
  make_repo "$ORCA_BASE/base-commerce" "$TMP_ROOT/remotes/base-commerce.git"
  err="$TMP_ROOT/unregistered-repo-home.err"
  if FM_HOME="$MAIN_HOME" FM_SECONDMATE_CHARTER='unregistered checkout domain' \
      "$ROOT/bin/fm-home-seed.sh" base-commerce-sm "$unregistered_repo_home" alpha > /dev/null 2>"$err"; then
    fail "shared seed accepted a secondmate home inside an unregistered checkout"
  fi
  assert_grep 'secondmate home cannot be inside existing git worktree' "$err" \
    "shared seed did not explain unregistered checkout home refusal"
  assert_absent "$unregistered_repo_home" "shared seed created a secondmate home inside base-commerce"

  out=$(FM_HOME="$MAIN_HOME" FM_SECONDMATE_CHARTER='alpha container domain' \
    FM_SECONDMATE_SCOPE='alpha product work' \
    "$ROOT/bin/fm-home-seed.sh" alpha-sm "$ALPHA_HOME" alpha) \
    || fail "colocated container secondmate seed failed"
  assert_contains "$out" "home=$ALPHA_HOME" "seed did not report the colocated home"
  assert_present "$ALPHA_HOME/.fm-secondmate-home" "seed did not mark the secondmate home"
  [ ! -L "$ALPHA_HOME" ] || fail "colocated secondmate home is a symlink"
  assert_present "$ALPHA_HOME/projects" "seed did not retain the internal legacy projects directory"
  [ -z "$(find "$ALPHA_HOME/projects" -mindepth 1 -maxdepth 1 -print)" ] \
    || fail "container seed cloned repos into the secondmate home"
  assert_grep "$ORCA_BASE" "$ALPHA_HOME/config/projects-root" "project base was not inherited"
  assert_grep 'repos: api, web' "$ALPHA_HOME/data/projects.md" "explicit repo registry was not inherited"
  [ "$before_api" = "$(git -C "$ALPHA_API" status --porcelain=v1; git -C "$ALPHA_API" rev-parse HEAD)" ] \
    || fail "seed mutated alpha/api"
  [ "$before_web" = "$(git -C "$ALPHA_WEB" status --porcelain=v1; git -C "$ALPHA_WEB" rev-parse HEAD)" ] \
    || fail "seed mutated alpha/web"

  FM_HOME="$MAIN_HOME" FM_SECONDMATE_CHARTER='alpha container domain' \
    FM_SECONDMATE_SCOPE='alpha product work' \
    "$ROOT/bin/fm-home-seed.sh" alpha-sm "$ALPHA_HOME" alpha > /dev/null \
    || fail "shared seed rejected its registered marker-matching secondmate home"

  git -C "$GAMMA_REPO" remote remove no-mistakes
  bad_home="$GAMMA_CONTAINER/.secondmate"
  err="$TMP_ROOT/unready.err"
  if FM_HOME="$MAIN_HOME" FM_SECONDMATE_CHARTER='gamma domain' \
      "$ROOT/bin/fm-home-seed.sh" gamma-sm "$bad_home" gamma > /dev/null 2>"$err"; then
    fail "shared seed accepted an uninitialized no-mistakes repo"
  fi
  assert_grep 'refusing to mutate the external checkout' "$err" "unready repo refusal was not explicit"
  assert_absent "$bad_home" "failed shared seed left a secondmate home behind"
  pass "container seeding creates a real sibling .secondmate and owns no canonical repo"
}

test_legacy_seed_keeps_existing_home_placement_behavior() {
  local home repo secondmate
  home="$TMP_ROOT/legacy-seed-home"
  repo="$home/projects/legacy"
  secondmate="$TMP_ROOT/legacy-secondmate"
  mkdir -p "$home/config" "$home/data" "$home/state" "$home/projects"
  make_repo "$repo" "$TMP_ROOT/remotes/legacy-seed.git"
  printf '%s\n' '- legacy [direct-PR] - legacy project (added 2026-07-13)' > "$home/data/projects.md"
  FM_HOME="$home" FM_SECONDMATE_CHARTER='legacy domain' \
    "$ROOT/bin/fm-home-seed.sh" legacy-sm "$secondmate" legacy > /dev/null \
    || fail "legacy seed changed its existing secondmate home placement behavior"
  assert_present "$secondmate/.fm-secondmate-home" "legacy seed did not create the requested home"
  pass "legacy mode retains its existing home placement behavior"
}

test_registry_sync_and_route_from_container_context() {
  local out rc err
  out=$(FM_HOME="$MAIN_HOME" FM_FLEET_PRUNE=0 "$ROOT/bin/fm-fleet-sync.sh" 2>/dev/null)
  assert_not_contains "$out" 'unregistered:' "fleet sync discovered an unregistered container"

  out=$(FM_HOME="$ALPHA_HOME" FM_FLEET_PRUNE=0 "$ROOT/bin/fm-fleet-sync.sh" 2>/dev/null)
  assert_contains "$out" 'shared project synchronization delegated to primary firstmate' \
    "container secondmate did not delegate canonical repo sync"

  out=$(cd "$ALPHA_CONTAINER" && FM_HOME="$MAIN_HOME" "$ROOT/bin/fm-project-route.sh") \
    || fail "route lookup from non-git project container failed"
  assert_contains "$out" 'project=alpha' "container route did not identify alpha"
  assert_contains "$out" 'route=alpha-sm' "container route did not identify the secondmate"
  assert_contains "$out" "home=$ALPHA_HOME" "container route omitted the colocated home"

  out=$(cd "$ALPHA_API" && FM_HOME="$MAIN_HOME" "$ROOT/bin/fm-project-route.sh") \
    || fail "route lookup from a registered repo failed"
  assert_contains "$out" 'project=alpha' "repo route did not map back to its container project"

  err="$TMP_ROOT/unregistered-fleet-sync.err"
  set +e
  FM_HOME="$MAIN_HOME" FM_FLEET_PRUNE=0 "$ROOT/bin/fm-fleet-sync.sh" "$ORCA_BASE/unregistered/repo" \
    > /dev/null 2>"$err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "fleet sync accepted an unregistered shared checkout path"
  assert_grep 'not a registered project container or repo' "$err" \
    "fleet sync did not reject an unregistered shared checkout path"

  err="$TMP_ROOT/unregistered-project-mode.err"
  if FM_HOME="$MAIN_HOME" "$ROOT/bin/fm-project-mode.sh" "$ORCA_BASE/unregistered/repo" \
      > /dev/null 2>"$err"; then
    fail "project mode accepted an unregistered shared checkout path"
  fi
  assert_grep 'project selector is not registered in shared mode' "$err" \
    "project mode did not reject an unregistered shared checkout path"

  set +e
  out=$(FM_HOME="$MAIN_HOME" "$ROOT/bin/fm-project-route.sh" alpha/missing 2>"$TMP_ROOT/missing.err")
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "unregistered repo selector returned $rc instead of 2: $out"
  assert_grep 'no registered project context' "$TMP_ROOT/missing.err" \
    "unregistered repo selector was routed by project-name prefix"

  set +e
  out=$(cd "$ORCA_BASE/workspaces" && FM_HOME="$MAIN_HOME" "$ROOT/bin/fm-project-route.sh" 2>"$TMP_ROOT/workspaces.err")
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "reserved workspaces context returned $rc instead of 2: $out"
  assert_grep 'no registered project context' "$TMP_ROOT/workspaces.err" "workspaces refusal was not explicit"
  pass "sync and routing follow the registry from container or repo context"
}

test_resolver_precedence_and_fail_closed_config
test_registry_drives_containers_and_repo_selection
test_legacy_single_repo_compatibility
test_container_seed_is_reference_only_and_colocated
test_legacy_seed_keeps_existing_home_placement_behavior
test_registry_sync_and_route_from_container_context
