#!/usr/bin/env bash
# Behavior tests for bin/fm-project-init.sh, the project-container onboarding
# command.
#
# These run the REAL fm-project-init.sh -> fm-home-seed.sh -> fm-brief.sh stack
# against a temp shared-container fixture (durable projects-root, primary
# home-role, real git repos with file:// origins) and a fake no-mistakes that
# records init/doctor calls and registers the gate remote, so onboarding,
# idempotence, delivery init, preservation, and rollback are all observable.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INIT="$ROOT/bin/fm-project-init.sh"

TMP=$(fm_test_tmproot fm-project-init)
mkdir -p "$TMP"
# Compare paths in physical form: the scripts normalize with pwd -P, and macOS
# temp roots live behind the /var -> /private/var symlink.
TMP=$(cd "$TMP" && pwd -P)
HOME_DIR="$TMP/primary"
ORCA="$TMP/orca"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/config" "$ORCA"
printf '%s\n' "$ORCA" > "$HOME_DIR/config/projects-root"
printf 'primary\n' > "$HOME_DIR/config/home-role"

# Fake no-mistakes: records "<pwd> <verb>" and makes `init` register the gate
# remote that shared-mode seeding validates, without touching the working tree.
FAKEBIN=$(fm_fakebin "$TMP")
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s %s\n' "$PWD" "${1:-}" >> "$FM_FAKE_NM_LOG"
case "${1:-}" in
  init) git remote get-url no-mistakes >/dev/null 2>&1 || git remote add no-mistakes "$PWD/.git" ;;
  doctor) : ;;
  *) exit 2 ;;
esac
SH
chmod +x "$FAKEBIN/no-mistakes"

export PATH="$FAKEBIN:$PATH"
export FM_HOME="$HOME_DIR"
export FM_FAKE_NM_LOG="$TMP/nm.log"
: > "$FM_FAKE_NM_LOG"
fm_git_identity

make_repo() {  # <container> <repo>
  local path="$1/$2"
  fm_git_init_commit "$path"
  fm_git_add_origin "$path" "$TMP/remotes/$2.git"
}

test_happy_path_single_repo() {
  mkdir -p "$ORCA/glamora"
  make_repo "$ORCA/glamora" glamora-app
  out=$("$INIT" glamora --charter "Own the Glamora product line" --scope "glamora feature work" 2>&1) \
    || fail "onboarding failed: $out"
  assert_contains "$out" "ANALYZE: glamora-app: branch=" "repo analysis is printed"
  assert_contains "$out" "REGISTRY: added: - glamora [no-mistakes] -" "registry line is added with the mode"
  assert_contains "$out" "DELIVERY: glamora-app initialized for no-mistakes" "delivery gate is initialized"
  assert_contains "$out" "SEEDED: secondmate glamora at" "secondmate home is seeded"
  assert_grep "- glamora [no-mistakes] - Own the Glamora product line (repos: glamora-app; added" "$HOME_DIR/data/projects.md" "projects.md holds the container line"
  assert_grep "- glamora " "$HOME_DIR/data/secondmates.md" "secondmates.md routes the project"
  assert_present "$ORCA/glamora/.secondmate/.fm-secondmate-home" "home marker exists"
  [ "$(cat "$ORCA/glamora/.secondmate/.fm-secondmate-home")" = glamora ] || fail "marker names the secondmate id"
  assert_present "$ORCA/glamora/.secondmate/data/charter.md" "charter is copied into the home"
  git -C "$ORCA/glamora/glamora-app" remote get-url no-mistakes >/dev/null || fail "gate remote was registered"
  assert_grep "$ORCA/glamora/glamora-app init" "$FM_FAKE_NM_LOG" "no-mistakes init ran inside the repo"
  pass "single-repo onboarding registers, initializes, and seeds"
}

test_rerun_is_idempotent() {
  before=$(cat "$HOME_DIR/data/projects.md")
  out=$("$INIT" glamora --charter "Own the Glamora product line" --scope "glamora feature work" 2>&1) \
    || fail "idempotent re-run failed: $out"
  assert_contains "$out" "already registered and consistent" "existing consistent line passes through"
  assert_contains "$out" "already initialized for no-mistakes" "delivery init is idempotent"
  [ "$(cat "$HOME_DIR/data/projects.md")" = "$before" ] || fail "re-run must not rewrite the registry"
  [ "$(grep -c '^- glamora ' "$HOME_DIR/data/projects.md")" -eq 1 ] || fail "re-run must not duplicate the line"
  [ "$(grep -c '^- glamora ' "$HOME_DIR/data/secondmates.md")" -eq 1 ] || fail "re-run must not duplicate the route"
  pass "re-running onboarding is idempotent"
}

test_conflicting_rerun_fails_closed() {
  before=$(cat "$HOME_DIR/data/projects.md")
  out=$("$INIT" glamora --mode direct-PR --charter "Own the Glamora product line" 2>&1) \
    && fail "conflicting mode must fail closed"
  assert_contains "$out" "disagrees with this run" "conflict is named"
  [ "$(cat "$HOME_DIR/data/projects.md")" = "$before" ] || fail "conflict must leave the registry untouched"
  pass "a drifted registry line fails closed instead of being rewritten"
}

test_multi_repo_autodetect_and_dirty_preserved() {
  mkdir -p "$ORCA/basecom"
  make_repo "$ORCA/basecom" store-web
  make_repo "$ORCA/basecom" store-api
  printf 'wip\n' > "$ORCA/basecom/store-web/wip.txt"
  git -C "$ORCA/basecom/store-api" checkout -q -b feature/x
  out=$("$INIT" "$ORCA/basecom" --mode direct-PR --charter "Own Base Commerce" 2>&1) \
    || fail "multi-repo onboarding failed: $out"
  assert_contains "$out" "ANALYZE: store-web: branch=" "first repo analyzed"
  assert_contains "$out" "dirty=yes" "dirty checkout is reported, not blocked"
  assert_grep "- basecom [direct-PR] - Own Base Commerce (repos: store-api, store-web; added" "$HOME_DIR/data/projects.md" "both auto-detected repos are registered"
  assert_present "$ORCA/basecom/store-web/wip.txt" "dirty file is preserved"
  [ "$(git -C "$ORCA/basecom/store-api" symbolic-ref --short HEAD)" = feature/x ] || fail "checked-out branch is preserved"
  assert_no_grep "$ORCA/basecom/store-web init" "$FM_FAKE_NM_LOG" "direct-PR skips delivery-gate init"
  assert_present "$ORCA/basecom/.secondmate/.fm-secondmate-home" "one secondmate covers the multi-repo container"
  pass "multi-repo container gets one secondmate and stays untouched"
}

test_seed_failure_rolls_back_registry() {
  mkdir -p "$ORCA/failcase/.secondmate"
  printf 'someone-else\n' > "$ORCA/failcase/.secondmate/.fm-secondmate-home"
  make_repo "$ORCA/failcase" fail-app
  before=$(cat "$HOME_DIR/data/projects.md")
  out=$("$INIT" failcase --charter "Should roll back" 2>&1) \
    && fail "marked foreign home must fail seeding"
  assert_contains "$out" "rolled back" "rollback is reported"
  [ "$(cat "$HOME_DIR/data/projects.md")" = "$before" ] || fail "registry line must be rolled back on seed failure"
  assert_present "$ORCA/failcase/.secondmate/.fm-secondmate-home" "foreign home is preserved"
  [ "$(cat "$ORCA/failcase/.secondmate/.fm-secondmate-home")" = someone-else ] || fail "foreign marker is untouched"
  pass "seed failure rolls back the registry and preserves the existing home"
}

test_local_only_refused() {
  out=$("$INIT" whatever --mode local-only --charter x 2>&1) && fail "local-only must be refused"
  assert_contains "$out" "local-only projects keep their work with the main firstmate" "refusal explains the rule"
  pass "local-only mode is refused for project secondmates"
}

test_non_primary_role_fails_closed() {
  printf 'secondmate\n' > "$HOME_DIR/config/home-role"
  out=$("$INIT" glamora --charter x 2>&1) && fail "non-primary role must be refused"
  assert_contains "$out" "requires config/home-role to be primary" "role refusal is named"
  printf 'primary\n' > "$HOME_DIR/config/home-role"
  pass "onboarding requires the primary home role"
}

test_missing_charter_fails_before_mutation() {
  mkdir -p "$ORCA/nochart"
  make_repo "$ORCA/nochart" nochart-app
  before=$(cat "$HOME_DIR/data/projects.md")
  out=$("$INIT" nochart 2>&1) && fail "missing charter must be refused"
  assert_contains "$out" "no charter" "missing charter is named"
  [ "$(cat "$HOME_DIR/data/projects.md")" = "$before" ] || fail "missing charter must not touch the registry"
  assert_absent "$ORCA/nochart/.secondmate" "missing charter must not seed a home"
  pass "missing charter fails before any mutation"
}

test_unsafe_secondmate_id_fails_before_mutation() {
  before=$(cat "$HOME_DIR/data/projects.md")
  out=$("$INIT" glamora --id ../../escaped --charter "Own the Glamora product line" 2>&1) && fail "unsafe secondmate id must be refused"
  assert_contains "$out" "unsafe secondmate id" "unsafe id is named"
  [ "$(cat "$HOME_DIR/data/projects.md")" = "$before" ] || fail "unsafe id must not rewrite the registry"
  assert_absent "$TMP/escaped" "unsafe id must not escape the data directory"
  pass "unsafe secondmate id fails before path construction"
}

test_happy_path_single_repo
test_rerun_is_idempotent
test_conflicting_rerun_fails_closed
test_multi_repo_autodetect_and_dirty_preserved
test_seed_failure_rolls_back_registry
test_local_only_refused
test_non_primary_role_fails_closed
test_missing_charter_fails_before_mutation
test_unsafe_secondmate_id_fails_before_mutation

echo "fm-project-init: all tests passed"
