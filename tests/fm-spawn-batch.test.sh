#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh batch dispatch (`id=repo` pairs).
#
# These exercise argument routing only: each spawn attempt fails fast at the
# missing-brief check, which is reached before any tmux/treehouse side effect, so
# the tests create no windows or worktrees. FM_SPAWN_NO_GUARD=1 keeps them off the
# live watcher guard / state. Parser and path-scoping cases are table-driven; the
# only behavior asserted on its own is "a multi-pair batch does not stop after the
# first failure".
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-batch)
export FM_BACKEND=tmux

# Clear ambient firstmate overrides so the behavior test owns its environment.
run_spawn() {
  FM_ROOT_OVERRIDE='' \
    FM_HOME='' \
    FM_STATE_OVERRIDE='' \
    FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' \
    FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$@" 2>&1
}

# Every pair in a batch is dispatched even though the first one fails; the loop
# must not stop early. This is the load-bearing batch guarantee, kept explicit.
test_batch_dispatches_every_pair() {
  local out status
  out=$(run_spawn nope-batch-a-z1=projects/none-a nope-batch-b-z2=projects/none-b)
  status=$?
  [ "$status" -ne 0 ] || fail "batch with missing briefs should exit non-zero"
  printf '%s\n' "$out" | grep -F 'batch: FAILED to spawn nope-batch-a-z1 (projects/none-a)' >/dev/null \
    || fail "first pair was not dispatched/reported"
  printf '%s\n' "$out" | grep -F 'batch: FAILED to spawn nope-batch-b-z2 (projects/none-b)' >/dev/null \
    || fail "second pair was not dispatched/reported (loop stopped early?)"
  pass "batch dispatch re-execs and reports every id=repo pair"
}

# Boundary cases for batch detection. Each row:
#   <label>|<batch yes/no>|<expect substring>|<args>
# batch=yes -> a 'batch:' line must appear; batch=no -> it must not.
test_batch_mode_boundaries() {
  local label batch expect args out status
  while IFS='|' read -r label batch expect args; do
    [ -n "$label" ] || continue
    # shellcheck disable=SC2086  # args is an intentional word-split arg list
    out=$(run_spawn $args)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected non-zero exit"
    if [ -n "$expect" ]; then
      printf '%s\n' "$out" | grep -F "$expect" >/dev/null || fail "$label: missing '$expect'"
    fi
    case "$batch" in
      yes) printf '%s\n' "$out" | grep -F 'batch:' >/dev/null || fail "$label: did not enter batch dispatch" ;;
      no)  printf '%s\n' "$out" | grep -F 'batch:' >/dev/null && fail "$label: wrongly entered batch dispatch" ;;
    esac
  done <<'ROWS'
single id=repo pair routes through batch|yes|batch: FAILED to spawn nope-batch-solo-z3 (projects/none-solo)|nope-batch-solo-z3=projects/none-solo
non-pair arg in batch is rejected|yes|batch dispatch expects every argument as id=repo; got 'bogus-no-equals'|nope-batch-mix-z5=projects/none-mix bogus-no-equals
plain '<id> <repo>' is single-task|no||nope-single-z4 projects/none-single
id part containing '/' is not a pair|no||weird/id-z6=projects/none projects/none
ROWS
  pass "batch detection: single pair batches, non-pair rejected, single-task and slash-id stay single"
}

# A projects/ path is resolved through the firstmate home, never the caller cwd,
# before the missing-brief check. One row per home-scoping override.
test_projects_path_scoping() {
  local label source arg id home projects out status expected
  while IFS='|' read -r label source arg id; do
    [ -n "$label" ] || continue
    home="$TMP_ROOT/$id home"
    projects="$TMP_ROOT/$id projects"
    mkdir -p "$home/data" "$home/config" "$projects/alpha"
    printf '%s\n' '- alpha [direct-PR] - alpha fixture (added 2026-07-13)' > "$home/data/projects.md"
    if [ "$source" = override ]; then
      out=$(FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
        FM_HOME="$home" FM_PROJECTS_OVERRIDE="$projects" FM_SPAWN_NO_GUARD=1 \
        "$SPAWN" "$id" "$arg" codex 2>&1)
    elif [ "$source" = config ]; then
      printf '%s\n' "$projects" > "$home/config/projects-root"
      out=$(FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
        FM_HOME="$home" FM_SPAWN_NO_GUARD=1 \
        "$SPAWN" "$id" "$arg" codex 2>&1)
    else
      mkdir -p "$home/projects/alpha"
      out=$(FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
        FM_HOME="$home" FM_SPAWN_NO_GUARD=1 \
        "$SPAWN" "$id" "$arg" codex 2>&1)
    fi
    status=$?
    [ "$status" -ne 0 ] || fail "$label: spawn with missing brief should fail"
    expected="error: no brief at $home/data/$id/brief.md"
    printf '%s\n' "$out" | grep -F "$expected" >/dev/null \
      || fail "$label: projects/alpha was not resolved through the home before the brief check"
    printf '%s\n' "$out" | grep -F "cd: $arg" >/dev/null \
      && fail "$label: spawn resolved $arg from the caller cwd"
  done <<'ROWS'
FM_HOME scopes projects/|home|projects/alpha|nope-home-z7
FM_PROJECTS_OVERRIDE scopes projects/|override|projects/alpha|nope-override-z8
config/projects-root scopes projects/|config|projects/alpha|nope-config-z9
config/projects-root resolves a bare registered name|config|alpha|nope-config-bare-y1
ROWS
  pass "project paths resolve through legacy, override, and configured shared catalogs"
}

test_batch_dispatches_every_pair
test_batch_mode_boundaries
test_projects_path_scoping
