#!/usr/bin/env bash
# Behavior tests for bin/fm-secondmate.sh, the container-local attach-or-start
# launcher.
#
# Routing, seeding, and spawning each have their own suites; this one isolates
# the launcher's decision layer with a stub FM_ROOT (fm-project-route.sh,
# fm-home-seed.sh, and fm-spawn.sh stubs recording their calls) plus a fake
# tmux answering the backend presence and agent-liveness probes, so every
# attach/respawn/fail-closed branch is exercised deterministically.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LAUNCHER="$ROOT/bin/fm-secondmate.sh"

TMP=$(fm_test_tmproot fm-secondmate-launcher)
STUB="$TMP/stubroot"
HOME_DIR="$TMP/primary"
SM_HOME="$TMP/orca/alpha/.secondmate"
mkdir -p "$STUB/bin" "$HOME_DIR/state" "$HOME_DIR/data"

# The launcher sources the REAL bin/fm-backend.sh from its own script dir, so
# backend probes hit the fake tmux; every sibling-script call goes through
# FM_ROOT_OVERRIDE to these stubs.
cat > "$STUB/bin/fm-home-seed.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = validate ] || exit 2
if [ -n "${FM_FAKE_VALIDATE_FAIL:-}" ]; then
  echo "error: duplicate secondmate home assignment" >&2
  exit 1
fi
exit 0
SH
cat > "$STUB/bin/fm-project-route.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "route-arg:$*" >> "$FM_FAKE_ROUTE_LOG"
if [ -n "${FM_FAKE_ROUTE_STDERR:-}" ]; then
  printf '%s\n' "$FM_FAKE_ROUTE_STDERR" >&2
fi
printf '%s\n' "$FM_FAKE_ROUTE_OUT"
exit "${FM_FAKE_ROUTE_RC:-0}"
SH
cat > "$STUB/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "spawn:$*" >> "$FM_FAKE_SPAWN_LOG"
[ -z "${FM_FAKE_SPAWN_FAIL:-}" ] || { echo "error: backend refused" >&2; exit 1; }
id=$1
{
  echo "window=firstmate:fm-$id"
  echo "worktree=$FM_FAKE_SPAWN_HOME"
  echo "harness=${FM_FAKE_SPAWN_HARNESS:-claude}"
  echo "kind=secondmate"
  echo "home=$FM_FAKE_SPAWN_HOME"
} > "$FM_FAKE_SPAWN_META"
echo "spawned $id"
SH
chmod +x "$STUB/bin/"*.sh

# Fake tmux: display-message answers the pane-presence probe ('#{pane_id}') per
# FM_FAKE_TMUX_TARGET_EXISTS and the liveness probe ('#{pane_current_command}')
# with FM_FAKE_TMUX_CURRENT_COMMAND; window ops are recorded.
FAKEBIN=$(fm_fakebin "$TMP")
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
last=${*: -1}
case "${1:-}" in
  display-message)
    case "$last" in
      '#{pane_id}')
        [ "${FM_FAKE_TMUX_TARGET_EXISTS:-0}" = 1 ] || exit 1
        echo '%1'
        ;;
      '#{pane_current_command}')
        [ "${FM_FAKE_TMUX_TARGET_EXISTS:-0}" = 1 ] || exit 1
        printf '%s\n' "${FM_FAKE_TMUX_CURRENT_COMMAND:-zsh}"
        ;;
    esac
    exit 0
    ;;
  kill-window|select-window|switch-client|attach-session)
    printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
    exit 0
    ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/tmux"

export PATH="$FAKEBIN:$PATH"
export FM_ROOT_OVERRIDE="$STUB"
export FM_HOME="$HOME_DIR"
export FM_STATE_OVERRIDE="$HOME_DIR/state"
export FM_FAKE_ROUTE_LOG="$TMP/route.log"
export FM_FAKE_SPAWN_LOG="$TMP/spawn.log"
export FM_FAKE_TMUX_LOG="$TMP/tmux.log"
export FM_FAKE_SPAWN_HOME="$SM_HOME"
export FM_FAKE_SPAWN_META="$HOME_DIR/state/alpha-sm.meta"
export FM_FAKE_ROUTE_OUT="project=alpha
route=alpha-sm
home=$SM_HOME
scope=alpha work"
unset TMUX
# Pin the launcher's own implicit backend resolution (the real fm_backend_name
# reads FM_BACKEND, then $FM_HOME/config/backend, then auto-detection) so the
# suite is hermetic on any dev machine; the bridge tests override per case.
export FM_BACKEND=tmux

# A genuine-looking seeded secondmate home for the identity checks.
mkdir -p "$SM_HOME/bin" "$SM_HOME/data"
printf '# Firstmate\n' > "$SM_HOME/AGENTS.md"
printf 'alpha-sm\n' > "$SM_HOME/.fm-secondmate-home"

reset_state() {
  rm -f "$HOME_DIR/state"/alpha-sm.meta "$FM_FAKE_ROUTE_LOG" "$FM_FAKE_SPAWN_LOG" "$FM_FAKE_TMUX_LOG"
  rm -rf "$HOME_DIR/state/.secondmate-launch-alpha-sm.lock"
  rm -f "$HOME_DIR/config/backend"
  export FM_BACKEND=tmux
  : > "$FM_FAKE_ROUTE_LOG"
  : > "$FM_FAKE_SPAWN_LOG"
  : > "$FM_FAKE_TMUX_LOG"
  export FM_FAKE_TMUX_TARGET_EXISTS=0
  export FM_FAKE_TMUX_CURRENT_COMMAND=zsh
  unset FM_FAKE_VALIDATE_FAIL FM_FAKE_ROUTE_RC FM_FAKE_ROUTE_STDERR FM_FAKE_SPAWN_FAIL 2>/dev/null || true
}

test_unknown_harness_refused() {
  reset_state
  out=$("$LAUNCHER" gemini --no-attach 2>&1) && fail "unknown harness must be refused"
  assert_contains "$out" "unknown harness" "unknown harness names the failure"
  assert_no_grep "spawn:" "$FM_FAKE_SPAWN_LOG" "unknown harness must not spawn"
  pass "unknown harness fails closed"
}

test_route_failure_propagates() {
  reset_state
  export FM_FAKE_ROUTE_RC=2 FM_FAKE_ROUTE_OUT="project=alpha
route=none" FM_FAKE_ROUTE_STDERR="no secondmate route for alpha"
  out=$("$LAUNCHER" codex --no-attach 2>&1)
  rc=$?
  expect_code 2 "$rc" "no-route exit code is forwarded"
  assert_contains "$out" "no secondmate route" "route diagnostics are forwarded"
  assert_no_grep "spawn:" "$FM_FAKE_SPAWN_LOG" "no-route must not spawn"
  export FM_FAKE_ROUTE_OUT="project=alpha
route=alpha-sm
home=$SM_HOME
scope=alpha work"
  pass "route failure fails closed with forwarded diagnostics"
}

test_registry_validation_fails_closed() {
  reset_state
  export FM_FAKE_VALIDATE_FAIL=1
  out=$("$LAUNCHER" codex --no-attach 2>&1) && fail "registry validation failure must refuse launch"
  assert_contains "$out" "registry failed validation" "validation failure is named"
  assert_no_grep "spawn:" "$FM_FAKE_SPAWN_LOG" "invalid registry must not spawn"
  pass "duplicate/overlapping registry fails closed"
}

test_marker_mismatch_fails_closed() {
  reset_state
  printf 'other-sm\n' > "$SM_HOME/.fm-secondmate-home"
  out=$("$LAUNCHER" codex --no-attach 2>&1) && fail "marker mismatch must refuse launch"
  assert_contains "$out" "marked for 'other-sm'" "marker mismatch names both ids"
  assert_no_grep "spawn:" "$FM_FAKE_SPAWN_LOG" "marker mismatch must not spawn"
  printf 'alpha-sm\n' > "$SM_HOME/.fm-secondmate-home"
  pass "malformed home identity fails closed"
}

test_fresh_start_spawns_with_explicit_harness() {
  reset_state
  out=$("$LAUNCHER" codex --no-attach 2>&1) || fail "fresh start should spawn: $out"
  assert_grep "spawn:alpha-sm --secondmate --harness codex" "$FM_FAKE_SPAWN_LOG" "explicit harness is forwarded to fm-spawn"
  assert_contains "$out" "started firstmate:fm-alpha-sm" "start is reported with the target"
  assert_present "$HOME_DIR/state/alpha-sm.meta" "spawn recorded meta"
  pass "no live endpoint spawns with the explicit harness"
}

test_auto_omits_harness_and_backend_forwards() {
  reset_state
  out=$("$LAUNCHER" auto --no-attach --backend tmux 2>&1) || fail "auto start should spawn: $out"
  assert_grep "spawn:alpha-sm --secondmate --backend tmux" "$FM_FAKE_SPAWN_LOG" "auto passes no --harness and forwards --backend"
  assert_no_grep "--harness" "$FM_FAKE_SPAWN_LOG" "auto must let fm-spawn resolve the secondmate chain"
  pass "auto defers harness resolution and forwards backend"
}

test_explicit_project_arg_is_routed() {
  reset_state
  "$LAUNCHER" codex alpha --no-attach >/dev/null 2>&1 || fail "explicit project launch failed"
  assert_grep "route-arg:alpha" "$FM_FAKE_ROUTE_LOG" "explicit project argument reaches the router"
  pass "explicit project argument overrides cwd inference"
}

test_live_agent_attaches_without_duplicate() {
  reset_state
  "$LAUNCHER" codex --no-attach >/dev/null 2>&1 || fail "seed spawn failed"
  : > "$FM_FAKE_SPAWN_LOG"
  export FM_FAKE_TMUX_TARGET_EXISTS=1 FM_FAKE_TMUX_CURRENT_COMMAND=claude
  out=$("$LAUNCHER" codex --no-attach 2>&1) || fail "live attach failed: $out"
  assert_contains "$out" "target firstmate:fm-alpha-sm" "attach reports the live target"
  assert_contains "$out" "already live on claude" "harness mismatch is noted, not relaunched"
  assert_no_grep "spawn:" "$FM_FAKE_SPAWN_LOG" "live agent must never be duplicated"
  pass "second run attaches to the live coordinator instead of duplicating"
}

test_version_named_live_agent_attaches() {
  # The exact Base Commerce acceptance defect (2026-07-14): a live, idle Claude
  # 2.1.208 coordinator whose pane reports pane_current_command=2.1.208 (its
  # version, not "claude") was misclassified unknown, so a second launch refused
  # to attach. It must now prove the live process and reuse it, never duplicate.
  reset_state
  "$LAUNCHER" claude --no-attach >/dev/null 2>&1 || fail "seed spawn failed"
  : > "$FM_FAKE_SPAWN_LOG"
  export FM_FAKE_TMUX_TARGET_EXISTS=1 FM_FAKE_TMUX_CURRENT_COMMAND=2.1.208
  out=$("$LAUNCHER" claude --no-attach 2>&1) || fail "version-named live attach failed: $out"
  assert_contains "$out" "target firstmate:fm-alpha-sm" "attach reports the live target"
  assert_no_grep "spawn:" "$FM_FAKE_SPAWN_LOG" "version-named live agent must never be duplicated"
  assert_no_grep "kill-window" "$FM_FAKE_TMUX_LOG" "a version-named live agent must not be killed"
  pass "a version-named live coordinator (2.1.208) is proven live and attached, not duplicated"
}

test_dead_endpoint_is_killed_and_respawned() {
  reset_state
  "$LAUNCHER" codex --no-attach >/dev/null 2>&1 || fail "seed spawn failed"
  : > "$FM_FAKE_SPAWN_LOG"
  export FM_FAKE_TMUX_TARGET_EXISTS=1 FM_FAKE_TMUX_CURRENT_COMMAND=zsh
  out=$("$LAUNCHER" claude --no-attach 2>&1) || fail "dead-endpoint respawn failed: $out"
  assert_grep "kill-window -t firstmate:fm-alpha-sm" "$FM_FAKE_TMUX_LOG" "dead bare-shell endpoint is cleared first"
  assert_grep "spawn:alpha-sm --secondmate --harness claude" "$FM_FAKE_SPAWN_LOG" "dead endpoint is respawned"
  pass "confirmed-dead endpoint is cleared and respawned"
}

test_unproven_liveness_fails_closed() {
  reset_state
  "$LAUNCHER" codex --no-attach >/dev/null 2>&1 || fail "seed spawn failed"
  : > "$FM_FAKE_SPAWN_LOG"
  : > "$FM_FAKE_TMUX_LOG"
  export FM_FAKE_TMUX_TARGET_EXISTS=1 FM_FAKE_TMUX_CURRENT_COMMAND=node
  out=$("$LAUNCHER" codex --no-attach 2>&1) && fail "unproven liveness must refuse launch"
  assert_contains "$out" "liveness is unproven" "unproven identity is named"
  assert_no_grep "spawn:" "$FM_FAKE_SPAWN_LOG" "unproven liveness must not spawn a possible duplicate"
  assert_no_grep "kill-window" "$FM_FAKE_TMUX_LOG" "unproven liveness must not kill a possibly-live agent"
  pass "unprovable endpoint identity fails closed"
}

test_meta_home_disagreement_fails_closed() {
  reset_state
  fm_write_secondmate_meta "$HOME_DIR/state/alpha-sm.meta" "$TMP/elsewhere" "firstmate:fm-alpha-sm"
  out=$("$LAUNCHER" codex --no-attach 2>&1) && fail "meta/registry home disagreement must refuse launch"
  assert_contains "$out" "reconcile before launching" "home disagreement asks for reconciliation"
  assert_no_grep "spawn:" "$FM_FAKE_SPAWN_LOG" "home disagreement must not spawn"
  pass "meta home disagreeing with the routed home fails closed"
}

test_launch_lock_serializes() {
  reset_state
  mkdir -p "$HOME_DIR/state/.secondmate-launch-alpha-sm.lock"
  out=$("$LAUNCHER" codex --no-attach 2>&1) && fail "held launch lock must refuse a second launcher"
  assert_contains "$out" "already in progress" "held lock is reported"
  assert_no_grep "spawn:" "$FM_FAKE_SPAWN_LOG" "held lock must not spawn"
  rmdir "$HOME_DIR/state/.secondmate-launch-alpha-sm.lock"
  out=$("$LAUNCHER" codex --no-attach 2>&1) || fail "launch after lock release failed: $out"
  assert_absent "$HOME_DIR/state/.secondmate-launch-alpha-sm.lock" "lock is released after a run"
  pass "per-secondmate launch lock serializes racing invocations"
}

test_concurrent_homes_are_independent() {
  reset_state
  beta_home="$TMP/orca/beta/.secondmate"
  mkdir -p "$beta_home/bin" "$beta_home/data"
  printf '# Firstmate\n' > "$beta_home/AGENTS.md"
  printf 'beta-sm\n' > "$beta_home/.fm-secondmate-home"
  "$LAUNCHER" codex --no-attach >/dev/null 2>&1 || fail "alpha launch failed"
  FM_FAKE_SPAWN_META="$HOME_DIR/state/beta-sm.meta" \
    FM_FAKE_SPAWN_HOME="$beta_home" \
    FM_FAKE_ROUTE_OUT="project=beta
route=beta-sm
home=$beta_home
scope=beta work" \
    "$LAUNCHER" codex beta --no-attach >/dev/null 2>&1 || fail "beta launch failed"
  assert_present "$HOME_DIR/state/alpha-sm.meta" "alpha home has its own meta"
  assert_present "$HOME_DIR/state/beta-sm.meta" "beta home has its own meta"
  [ "$(grep -c '^spawn:' "$FM_FAKE_SPAWN_LOG")" -eq 2 ] || fail "both projects must spawn independently"
  pass "two project secondmates launch concurrently with independent state"
}

test_spawn_refusal_surfaces() {
  reset_state
  export FM_FAKE_SPAWN_FAIL=1
  out=$("$LAUNCHER" codex --no-attach 2>&1) && fail "spawn refusal must fail the launcher"
  assert_contains "$out" "backend refused" "backend refusal is surfaced, never retried elsewhere"
  pass "a backend spawn refusal surfaces as the blocker"
}

test_implicit_orca_backend_bridges_to_tmux() {
  reset_state
  mkdir -p "$HOME_DIR/config"
  printf 'orca\n' > "$HOME_DIR/config/backend"
  out=$(FM_BACKEND='' "$LAUNCHER" claude --no-attach 2>&1) || fail "config/backend=orca must bridge, not refuse: $out"
  assert_grep "spawn:alpha-sm --secondmate --harness claude --backend tmux" "$FM_FAKE_SPAWN_LOG" "implicit orca resolution is bridged to a tmux coordinator"
  assert_contains "$out" "cannot host a secondmate coordinator" "the bridge is announced with its reason"
  pass "config/backend=orca bridges the coordinator launch to tmux"
}

test_implicit_cmux_backend_bridges_to_tmux() {
  reset_state
  mkdir -p "$HOME_DIR/config"
  printf 'cmux\n' > "$HOME_DIR/config/backend"
  out=$(FM_BACKEND='' "$LAUNCHER" claude --no-attach 2>&1) || fail "config/backend=cmux must bridge, not refuse: $out"
  assert_grep "spawn:alpha-sm --secondmate --harness claude --backend tmux" "$FM_FAKE_SPAWN_LOG" "implicit cmux resolution is bridged to a tmux coordinator"
  pass "config/backend=cmux bridges the coordinator launch to tmux"
}

test_explicit_orca_backend_still_refuses() {
  reset_state
  export FM_FAKE_SPAWN_FAIL=1
  out=$("$LAUNCHER" claude --no-attach --backend orca 2>&1) && fail "explicit --backend orca must stay a fail-closed refusal"
  assert_grep "spawn:alpha-sm --secondmate --harness claude --backend orca" "$FM_FAKE_SPAWN_LOG" "explicit orca is forwarded verbatim, never bridged"
  assert_contains "$out" "backend refused" "fm-spawn's refusal surfaces as the blocker"
  pass "explicit --backend orca preserves the fail-closed refusal"
}

test_unknown_harness_refused
test_route_failure_propagates
test_registry_validation_fails_closed
test_marker_mismatch_fails_closed
test_fresh_start_spawns_with_explicit_harness
test_auto_omits_harness_and_backend_forwards
test_explicit_project_arg_is_routed
test_live_agent_attaches_without_duplicate
test_version_named_live_agent_attaches
test_dead_endpoint_is_killed_and_respawned
test_unproven_liveness_fails_closed
test_meta_home_disagreement_fails_closed
test_launch_lock_serializes
test_concurrent_homes_are_independent
test_spawn_refusal_surfaces
test_implicit_orca_backend_bridges_to_tmux
test_implicit_cmux_backend_bridges_to_tmux
test_explicit_orca_backend_still_refuses

echo "fm-secondmate-launcher: all tests passed"
