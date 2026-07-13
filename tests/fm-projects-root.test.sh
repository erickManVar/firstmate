#!/usr/bin/env bash
# Focused behavior tests for config/projects-root, shared secondmate seeding,
# registry-driven fleet sync, and read-only project-to-secondmate routing.
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

test_resolver_precedence_and_safety() {
  local home shared override out err
  home="$TMP_ROOT/resolver-home"
  shared="$TMP_ROOT/shared catalog"
  override="$TMP_ROOT/override catalog"
  err="$TMP_ROOT/resolver.err"
  mkdir -p "$home/config" "$home/data" "$home/projects" "$shared" "$override"

  out=$(resolver_call "$home" 'fm_projects_root') || fail "legacy root resolution failed"
  [ "$out" = "$home/projects" ] || fail "legacy root was not FM_HOME/projects"

  printf '%s\n' "$shared" > "$home/config/projects-root"
  out=$(resolver_call "$home" 'fm_projects_root') || fail "configured root resolution failed"
  [ "$out" = "$shared" ] || fail "config/projects-root did not win over the legacy root"
  out=$(resolver_call "$home" 'fm_projects_mode')
  [ "$out" = shared-external ] || fail "configured root was not classified shared-external"

  printf '%s\n' "$home/projects" > "$home/config/projects-root"
  out=$(resolver_call "$home" 'fm_projects_mode') \
    || fail "configured legacy-path mode resolution failed"
  [ "$out" = shared-external ] \
    || fail "config/projects-root presence did not explicitly select shared-external mode"

  out=$(resolver_call "$home" 'fm_projects_root' FM_PROJECTS_OVERRIDE="$override") \
    || fail "override root resolution failed"
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
  assert_grep 'must contain an absolute path' "$err" "relative root refusal was not explained"

  rm "$home/config/projects-root"
  ln -s "$home/config/missing-root" "$home/config/projects-root"
  if resolver_call "$home" 'fm_projects_root' > /dev/null 2>"$err"; then
    fail "dangling config/projects-root symlink fell back to the legacy root"
  fi
  assert_grep 'dangling symlink' "$err" "dangling root refusal was not explained"

  rm "$home/config/projects-root"
  mkdir "$home/config/projects-root"
  if resolver_call "$home" 'fm_projects_root' > /dev/null 2>"$err"; then
    fail "non-file config/projects-root fell back to the legacy root"
  fi
  assert_grep 'must be a regular file' "$err" "non-file root refusal was not explained"

  rm -rf "$home/config/projects-root"
  printf '%s\n' "$shared" > "$home/config/projects-root"
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

  printf '%s\n' "$shared" > "$home/config/projects-root"
  mkdir -p "$shared/alpha" "$shared/firstmate" "$shared/.secondmates"
  printf '%s\n' '- alpha [direct-PR] - alpha (added 2026-07-13)' > "$home/data/projects.md"
  out=$(resolver_call "$home" 'fm_project_registry_names')
  [ "$out" = alpha ] || fail "registry enumeration included an unregistered shared-root directory"
  if resolver_call "$home" 'fm_project_path ../alpha' >/dev/null 2>"$err"; then
    fail "unsafe project name was accepted"
  fi
  pass "project resolver preserves provenance, fails closed, and enumerates the registry only"
}

setup_shared_seed_world() {
  SHARED_HOME="$TMP_ROOT/shared-main"
  SHARED_ROOT="$TMP_ROOT/shared-root"
  SHARED_SUB="$TMP_ROOT/shared-secondmate"
  mkdir -p "$SHARED_HOME/config" "$SHARED_HOME/data" "$SHARED_HOME/state" "$SHARED_HOME/projects"
  mkdir -p "$SHARED_ROOT/firstmate" "$SHARED_ROOT/.secondmates"
  mkdir -p "$SHARED_SUB/bin"
  printf 'test firstmate home\n' > "$SHARED_SUB/AGENTS.md"
  printf 'config/projects-root\nprojects/\ndata/\nstate/\n.fm-secondmate-home\n' > "$SHARED_SUB/.gitignore"
  git -C "$SHARED_SUB" init -q
  git -C "$SHARED_SUB" add AGENTS.md .gitignore
  git -C "$SHARED_SUB" commit -qm initial
  fm_git_init_commit "$SHARED_ROOT/alpha"
  fm_git_add_origin "$SHARED_ROOT/alpha" "$TMP_ROOT/remotes/shared-alpha.git"
  fm_git_init_commit "$SHARED_ROOT/gamma"
  fm_git_add_origin "$SHARED_ROOT/gamma" "$TMP_ROOT/remotes/shared-gamma.git"
  git -C "$SHARED_ROOT/gamma" remote add no-mistakes "file://$TMP_ROOT/remotes/no-mistakes-gamma.git"
  cat > "$SHARED_HOME/data/projects.md" <<EOF
- alpha [direct-PR] - alpha project (added 2026-07-13)
- gamma [no-mistakes] - gamma project (added 2026-07-13)
EOF
  printf '%s\n' "$SHARED_ROOT" > "$SHARED_HOME/config/projects-root"
}

test_shared_seed_is_reference_only_and_transactional() {
  local before_alpha before_gamma out bad_repo bad_home err rollback_home old_root symlink_home sentinel
  setup_shared_seed_world
  before_alpha=$(git -C "$SHARED_ROOT/alpha" status --porcelain=v1; git -C "$SHARED_ROOT/alpha" rev-parse HEAD)
  before_gamma=$(git -C "$SHARED_ROOT/gamma" status --porcelain=v1; git -C "$SHARED_ROOT/gamma" rev-parse HEAD)

  out=$(FM_HOME="$SHARED_HOME" FM_SECONDMATE_CHARTER='shared catalog domain' \
    FM_SECONDMATE_SCOPE='shared alpha and gamma work' \
    "$ROOT/bin/fm-home-seed.sh" shared "$SHARED_SUB" alpha gamma) \
    || fail "shared secondmate seed failed"
  assert_contains "$out" "home=$SHARED_SUB" "shared seed did not report the home"
  assert_present "$SHARED_SUB/projects" "shared seed did not keep the internal operational projects directory"
  [ -z "$(find "$SHARED_SUB/projects" -mindepth 1 -maxdepth 1 -print)" ] \
    || fail "shared seed cloned a project into the secondmate home"
  assert_grep "$SHARED_ROOT" "$SHARED_SUB/config/projects-root" "projects-root was not inherited at seed time"
  assert_grep 'alpha project' "$SHARED_SUB/data/projects.md" "shared seed did not copy the project registry entry"
  [ "$before_alpha" = "$(git -C "$SHARED_ROOT/alpha" status --porcelain=v1; git -C "$SHARED_ROOT/alpha" rev-parse HEAD)" ] \
    || fail "shared seed mutated alpha"
  [ "$before_gamma" = "$(git -C "$SHARED_ROOT/gamma" status --porcelain=v1; git -C "$SHARED_ROOT/gamma" rev-parse HEAD)" ] \
    || fail "shared seed mutated gamma"

  bad_repo="$SHARED_ROOT/unready"
  bad_home="$TMP_ROOT/unready-secondmate"
  err="$TMP_ROOT/unready.err"
  fm_git_init_commit "$bad_repo"
  fm_git_add_origin "$bad_repo" "$TMP_ROOT/remotes/unready.git"
  printf '%s\n' '- unready [no-mistakes] - unready project (added 2026-07-13)' >> "$SHARED_HOME/data/projects.md"
  if FM_HOME="$SHARED_HOME" FM_SECONDMATE_CHARTER='unready domain' \
      "$ROOT/bin/fm-home-seed.sh" unready "$bad_home" unready > /dev/null 2>"$err"; then
    fail "shared seed accepted an uninitialized no-mistakes checkout"
  fi
  assert_grep 'refusing to mutate the external checkout' "$err" "shared seed refusal was not explicit"
  assert_absent "$bad_home" "failed shared seed left a secondmate home behind"
  [ -z "$(git -C "$bad_repo" status --porcelain=v1)" ] || fail "failed shared seed mutated the external checkout"

  rollback_home="$TMP_ROOT/rollback-secondmate"
  old_root="$TMP_ROOT/old-root"
  mkdir -p "$rollback_home/bin" "$rollback_home/config" "$old_root" "$SHARED_HOME/data/rollback"
  printf 'test firstmate home\n' > "$rollback_home/AGENTS.md"
  printf 'config/projects-root\nprojects/\ndata/\nstate/\n.fm-secondmate-home\n' > "$rollback_home/.gitignore"
  git -C "$rollback_home" init -q
  git -C "$rollback_home" add AGENTS.md .gitignore
  git -C "$rollback_home" commit -qm initial
  printf '%s\n' "$old_root" > "$rollback_home/config/projects-root"
  cat > "$SHARED_HOME/data/rollback/brief.md" <<'EOF'
# Charter
{TASK}
# Routing scope
rollback fixture
# Project access
- alpha
EOF
  if FM_HOME="$SHARED_HOME" "$ROOT/bin/fm-home-seed.sh" rollback "$rollback_home" alpha \
      > /dev/null 2>"$TMP_ROOT/rollback.err"; then
    fail "shared seed accepted a placeholder charter"
  fi
  assert_grep "$old_root" "$rollback_home/config/projects-root" \
    "shared seed rollback did not restore the preexisting projects-root"
  [ -d "$SHARED_ROOT/alpha/.git" ] || fail "shared seed rollback removed the external checkout"

  symlink_home="$TMP_ROOT/symlink-secondmate"
  sentinel="$TMP_ROOT/projects-root-sentinel"
  mkdir -p "$symlink_home/bin" "$symlink_home/config"
  printf 'test firstmate home\n' > "$symlink_home/AGENTS.md"
  printf 'unchanged\n' > "$sentinel"
  ln -s "$sentinel" "$symlink_home/config/projects-root"
  if FM_HOME="$SHARED_HOME" FM_SECONDMATE_CHARTER='symlink fixture' \
      "$ROOT/bin/fm-home-seed.sh" symlink "$symlink_home" alpha > /dev/null 2>"$TMP_ROOT/symlink.err"; then
    fail "shared seed accepted a symlinked projects-root destination"
  fi
  assert_grep 'must not be a symlink' "$TMP_ROOT/symlink.err" "shared seed did not explain the symlink refusal"
  [ "$(cat "$sentinel")" = unchanged ] || fail "shared seed wrote through a projects-root symlink"
  pass "shared secondmate seeding references initialized external repos and rollback owns no external path"
}

test_registry_sync_and_secondmate_delegation() {
  local extra out
  extra="$SHARED_ROOT/unregistered"
  fm_git_init_commit "$extra"
  fm_git_add_origin "$extra" "$TMP_ROOT/remotes/unregistered.git"

  out=$(FM_HOME="$SHARED_HOME" FM_FLEET_PRUNE=0 "$ROOT/bin/fm-fleet-sync.sh" 2>/dev/null)
  assert_not_contains "$out" 'unregistered:' "whole-fleet sync enumerated an unregistered shared-root repo"

  out=$(FM_HOME="$SHARED_SUB" FM_FLEET_PRUNE=0 "$ROOT/bin/fm-fleet-sync.sh" 2>/dev/null)
  assert_contains "$out" 'shared project synchronization delegated to primary firstmate' \
    "shared secondmate did not delegate canonical checkout sync"
  pass "fleet sync is registry-driven and shared secondmates never mutate the primary-owned catalog"
}

test_projects_root_inheritance_and_route_lookup() {
  local inherited out rc
  inherited="$TMP_ROOT/inherited-config"
  mkdir -p "$inherited"
  FM_INHERITABLE_CONFIG=projects-root FM_HOME="$SHARED_HOME" bash -c \
    '. "$1/bin/fm-config-inherit-lib.sh"; propagate_inheritable_config "$2/config" "$3"' \
    bash "$ROOT" "$SHARED_HOME" "$inherited" || fail "projects-root inheritance failed"
  assert_grep "$SHARED_ROOT" "$inherited/projects-root" "projects-root was not inherited"

  out=$(FM_HOME="$SHARED_HOME" "$ROOT/bin/fm-project-route.sh" alpha) || fail "single route lookup failed"
  assert_contains "$out" 'route=shared' "single route did not identify the secondmate"
  assert_contains "$out" "home=$SHARED_SUB" "single route omitted the secondmate home"
  assert_contains "$out" 'fm-send.sh' "single route omitted the supported send command"

  printf '%s\n' "- other - other scope (home: $TMP_ROOT/other-home; scope: alternate alpha work; projects: alpha; added 2026-07-13)" \
    >> "$SHARED_HOME/data/secondmates.md"
  set +e
  out=$(FM_HOME="$SHARED_HOME" "$ROOT/bin/fm-project-route.sh" alpha 2>"$TMP_ROOT/route.err")
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "ambiguous route did not return exit 3"
  assert_contains "$out" 'route=ambiguous' "ambiguous route was not labeled"
  assert_contains "$out" 'candidate=shared' "ambiguous route omitted the first candidate"
  assert_contains "$out" 'candidate=other' "ambiguous route omitted the second candidate"
  assert_grep 'without choosing' "$TMP_ROOT/route.err" "ambiguous route did not refuse to guess"
  pass "projects-root inherits and direct project sessions get an explicit, ambiguity-safe route"
}

test_resolver_precedence_and_safety
test_shared_seed_is_reference_only_and_transactional
test_registry_sync_and_secondmate_delegation
test_projects_root_inheritance_and_route_lookup
