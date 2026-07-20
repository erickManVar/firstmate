#!/usr/bin/env bash
# tests/fm-secondmate-liveness.test.sh - the session-start secondmate LIVENESS
# guarantee: bin/fm-backend.sh's fm_backend_agent_alive probe (dispatching to
# fm_backend_tmux_agent_alive / fm_backend_herdr_agent_alive) and
# bin/fm-bootstrap.sh's report-only secondmate_liveness_sweep().
#
# The gap under test (AGENTS.md "Session start"; evidence 2026-07-07): a
# secondmate agent that has exited leaves its backend endpoint alive as a bare
# shell. fm_backend_target_exists only checks pane PRESENCE, so it reports
# that shell "alive"; the watcher deliberately exempts secondmates from
# stale-pane detection because an idle secondmate pane is healthy by design.
# A dead-shell secondmate was therefore invisible to every existing check.
#
# The guarantees under test:
#   - fm_backend_tmux_agent_alive classifies a verified-harness foreground
#     process as alive, a bare shell as dead, and anything ambiguous
#     (including a bare interpreter name) as unknown - never dead.
#   - fm_backend_herdr_agent_alive is a thin wrapper over the already-verified
#     fm_backend_herdr_pane_agent_state husk classifier: dead/no-agent -> dead,
#     live -> alive, unknown -> unknown.
#   - fm_backend_agent_alive routes to the right per-backend classifier and
#     reports unknown for a backend with no verified classifier (never errors).
#   - bin/fm-bootstrap.sh's secondmate_liveness_sweep reports a confidently
#     DEAD secondmate as stopped, leaves an ALIVE one quiet, and reports an
#     inconclusive (UNKNOWN) reading as unproven without acting on either.
#   - The report runs under FM_BOOTSTRAP_DETECT_ONLY=1 because it is read-only.
#   - The sweep is naturally scoped to the primary: with no kind=secondmate
#     meta present (a secondmate's own state/ never holds one, since
#     secondmates never spawn secondmates), it is a silent no-op.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-secondmate-liveness)

# --- unit level: fm_backend_tmux_agent_alive --------------------------------

# make_probe_tmux <dir> <pane_current_command>: a fake tmux whose
# #{pane_current_command} display-message query answers with the fixed value;
# every other subcommand is a silent no-op success.
make_probe_tmux() {
  local dir=$1 comm=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  display-message)
    for a in "\$@"; do case "\$a" in *pane_current_command*) printf '%s\n' '$comm'; exit 0 ;; esac; done
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

test_tmux_agent_alive_classifies() {
  local fb

  fb=$(make_probe_tmux "$TMP_ROOT/tmux-claude" claude)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = alive ] \
    || fail "a live claude foreground process should classify as alive"

  fb=$(make_probe_tmux "$TMP_ROOT/tmux-codex" codex)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = alive ] \
    || fail "a live codex foreground process should classify as alive"

  fb=$(make_probe_tmux "$TMP_ROOT/tmux-opencode" opencode)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = alive ] \
    || fail "a live opencode foreground process should classify as alive"

  fb=$(make_probe_tmux "$TMP_ROOT/tmux-grok" grok)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = alive ] \
    || fail "a live grok foreground process should classify as alive"

  fb=$(make_probe_tmux "$TMP_ROOT/tmux-zsh" zsh)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = dead ] \
    || fail "a bare zsh foreground process should classify as dead"

  fb=$(make_probe_tmux "$TMP_ROOT/tmux-bash" bash)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = dead ] \
    || fail "a bare bash foreground process should classify as dead"

  # Defensive: this adapter strips a leading login-shell dash even though real
  # tmux 3.6a was observed to already normalize #{pane_current_command} itself
  # (docs/tmux-backend.md "Agent liveness probe").
  fb=$(make_probe_tmux "$TMP_ROOT/tmux-dashzsh" -zsh)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = dead ] \
    || fail "a defensively-stripped login-shell name should still classify as dead"

  # A bare interpreter name is ambiguous (pi's own launcher execs into a
  # generic "node" process - docs/tmux-backend.md "Known gap") - must be
  # unknown, never dead, so the sweep can never respawn on a false-dead read.
  fb=$(make_probe_tmux "$TMP_ROOT/tmux-node" node)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = unknown ] \
    || fail "an ambiguous bare-interpreter (node) foreground process should classify as unknown, never dead"

  fb=$(make_probe_tmux "$TMP_ROOT/tmux-vim" vim)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = unknown ] \
    || fail "an unrecognized foreground process should classify as unknown"

  # Observed live 2026-07-14 (Base Commerce acceptance): Claude 2.1.208 renames
  # its own foreground process to its version string, so the pane reports the
  # version, not "claude". A bare dotted-numeric version token must classify as
  # alive so a second launch reuses the live coordinator instead of refusing
  # (docs/tmux-backend.md "Version-named foreground process").
  fb=$(make_probe_tmux "$TMP_ROOT/tmux-ver" 2.1.208)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = alive ] \
    || fail "a version-named foreground process (2.1.208) should classify as alive"

  fb=$(make_probe_tmux "$TMP_ROOT/tmux-ver2" 0.45.0)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = alive ] \
    || fail "another version-named foreground process (0.45.0, e.g. a version-renamed codex) should classify as alive"

  # Guard the boundary: an interpreter-with-version name is NOT a bare version
  # token (leading letter), so it must stay unknown, never a false alive.
  fb=$(make_probe_tmux "$TMP_ROOT/tmux-py311" python3.11)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = unknown ] \
    || fail "an interpreter-with-version name (python3.11) must stay unknown, not a false alive"

  pass "fm_backend_tmux_agent_alive: alive/dead/unknown classification incl. version-named process"
}

# --- unit level: fm_backend_herdr_agent_alive -------------------------------
# Reuses the already-verified fm_backend_herdr_pane_agent_state husk
# classifier (docs/herdr-backend.md "Respawn idempotency" /
# "Agent liveness probe reuses the husk classifier"); this wrapper's own
# mapping logic is tested in isolation by overriding that classifier, exactly
# as tests/fm-backend-herdr.test.sh already overrides `sleep` in a bash -c
# string for the same kind of isolated-unit assertion.

test_herdr_agent_alive_maps_pane_agent_state() {
  local out

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_agent_state() { printf "dead"; }; fm_backend_herdr_agent_alive "sess:p1"' "$ROOT")
  [ "$out" = dead ] || fail "herdr pane_agent_state=dead should map to dead, got '$out'"

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_agent_state() { printf "no-agent"; }; fm_backend_herdr_agent_alive "sess:p1"' "$ROOT")
  [ "$out" = dead ] || fail "herdr pane_agent_state=no-agent (restored bare shell) should map to dead, got '$out'"

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_agent_state() { printf "live"; }; fm_backend_herdr_agent_alive "sess:p1"' "$ROOT")
  [ "$out" = alive ] || fail "herdr pane_agent_state=live should map to alive, got '$out'"

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_agent_state() { printf "unknown"; }; fm_backend_herdr_agent_alive "sess:p1"' "$ROOT")
  [ "$out" = unknown ] || fail "herdr pane_agent_state=unknown should stay unknown, got '$out'"

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_agent_alive "no-colon-target"' "$ROOT")
  [ "$out" = unknown ] || fail "an unparseable target should classify as unknown, got '$out'"

  pass "fm_backend_herdr_agent_alive: dead/no-agent->dead, live->alive, unknown->unknown"
}

# --- unit level: the generic fm_backend_agent_alive dispatcher --------------

test_agent_alive_dispatcher_routes_and_falls_back() {
  local fb out

  fb=$(make_probe_tmux "$TMP_ROOT/dispatch-tmux" claude)
  out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_alive tmux sess:win' "$ROOT")
  [ "$out" = alive ] || fail "dispatcher should route tmux to fm_backend_tmux_agent_alive, got '$out'"

  out=$(bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source herdr; fm_backend_herdr_pane_agent_state() { printf "live"; }; fm_backend_agent_alive herdr sess:p1' "$ROOT")
  [ "$out" = alive ] || fail "dispatcher should route herdr to fm_backend_herdr_agent_alive, got '$out'"

  out=$(bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_alive zellij sess:win' "$ROOT")
  [ "$out" = unknown ] || fail "dispatcher should report unknown for a backend with no verified classifier, got '$out'"

  pass "fm_backend_agent_alive: routes tmux/herdr correctly, unknown for an unverified backend"
}

test_target_state_recognizes_herdr_pane_not_found() {
  local out
  out=$(bash -c '. "$0/bin/fm-backend.sh"; fm_backend_target_probe() { printf "{\\\"error\\\":{\\\"code\\\":\\\"pane_not_found\\\"}}\\n" >&2; return 1; }; fm_backend_target_state herdr default:w1:p2' "$ROOT")
  [ "$out" = missing ] || fail "a Herdr pane_not_found response should classify as missing, got '$out'"
  pass "fm_backend_target_state: recognizes Herdr pane_not_found as confirmed absence"
}

test_target_state_recognizes_orca_stale_terminal() {
  local out
  out=$(bash -c '. "$0/bin/fm-backend.sh"; fm_backend_target_probe() { printf "{\\\"error\\\":{\\\"code\\\":\\\"terminal_handle_stale\\\"}}\\n" >&2; return 1; }; fm_backend_target_state orca term-gone' "$ROOT")
  [ "$out" = missing ] || fail "an Orca terminal_handle_stale response should classify as missing, got '$out'"
  pass "fm_backend_target_state: recognizes Orca terminal_handle_stale as confirmed absence"
}

test_target_state_leaves_backend_failures_unproven() {
  local out
  out=$(bash -c '. "$0/bin/fm-backend.sh"; fm_backend_target_probe() { printf "tmux: command not found\\n" >&2; return 1; }; fm_backend_target_state tmux sess:win' "$ROOT")
  [ "$out" = unknown ] || fail "a missing tmux command should stay unknown, got '$out'"
  pass "fm_backend_target_state: leaves backend failures unproven"
}

# Cold tmux boot: all tmux endpoint state lives in the server process, so both
# documented server-absent client signatures (docs/tmux-backend.md "Cold-boot
# endpoint absence") are confirmed absence, while any other connection error
# stays unknown and fails closed.
test_target_state_recognizes_tmux_cold_boot_as_absence() {
  local out
  out=$(bash -c '. "$0/bin/fm-backend.sh"; fm_backend_target_probe() { printf "no server running on /private/tmp/tmux-501/default\\n" >&2; return 1; }; fm_backend_target_state tmux sess:win' "$ROOT")
  [ "$out" = missing ] || fail "a no-server-running tmux probe should classify as missing, got '$out'"

  out=$(bash -c '. "$0/bin/fm-backend.sh"; fm_backend_target_probe() { printf "error connecting to /private/tmp/tmux-501/default (No such file or directory)\\n" >&2; return 1; }; fm_backend_target_state tmux sess:win' "$ROOT")
  [ "$out" = missing ] || fail "a gone-socket tmux connection error should classify as missing, got '$out'"

  pass "fm_backend_target_state: recognizes both tmux server-absent signatures as confirmed absence"
}

test_target_state_leaves_other_tmux_connection_errors_unproven() {
  local out
  out=$(bash -c '. "$0/bin/fm-backend.sh"; fm_backend_target_probe() { printf "error connecting to /private/tmp/tmux-501/default (Permission denied)\\n" >&2; return 1; }; fm_backend_target_state tmux sess:win' "$ROOT")
  [ "$out" = unknown ] || fail "a permission-denied tmux connection error must stay unknown, got '$out'"
  pass "fm_backend_target_state: a non-absence tmux connection error still fails closed"
}

# --- sweep level: bin/fm-bootstrap.sh's secondmate_liveness_sweep -----------

# make_toolchain <dir>: the fixed set of stubs bin/fm-bootstrap.sh's read-only
# diagnostics need to stay quiet (mirrors tests/fm-secondmate-sync.test.sh's
# make_fake_toolchain), MINUS tmux - callers add their own controllable tmux.
make_toolchain() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" node gh-axi chrome-devtools-axi lavish-axi
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease]'
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.31.2 (fake)'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s\n' "$fakebin"
}

# make_liveness_tmux <dir>: a tmux stub whose #{pane_current_command} answer is
# read fresh from $FM_TEST_PANE_CMD on every query (so a test can flip it
# between bootstrap runs), and which logs every new-window/kill-window call
# (the only two operations a respawn performs) to $FM_TMUX_CALL_LOG.
make_liveness_tmux() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    for a in "$@"; do
      case "$a" in
        *pane_id*)
          if [ "${FM_TEST_TARGET_EXISTS:-1}" != 1 ]; then
            case "${FM_TEST_TARGET_PROBE:-missing}" in
              missing) printf '%s\n' "can't find window" >&2 ;;
              failure) printf '%s\n' 'tmux server query failed' >&2 ;;
            esac
            exit 1
          fi
          printf '%s\n' '$$'
          exit 0
          ;;
        *pane_current_command*) printf '%s\n' "${FM_TEST_PANE_CMD:-zsh}"; exit 0 ;;
      esac
    done
    exit 0 ;;
  new-window|kill-window)
    printf '%s\n' "$*" >> "${FM_TMUX_CALL_LOG:?}"
    exit 0 ;;
  list-windows|has-session) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# new_world <name>: a scratch firstmate HOME (state/, watcher beacon, pinned
# harness) with no kind=secondmate meta yet. FM_ROOT is left to resolve
# naturally to the real checkout under test ($ROOT), exactly as production
# always has it - this sweep's own fm-spawn.sh invocation resolves the
# secondmate harness through $FM_ROOT/bin/fm-harness.sh, which only exists in
# the real tree. The harness is pinned because ambient own-harness detection is
# environment-dependent: interactive harness sessions expose markers or parent
# process names, while a plain pipeline shell can fall through to "unknown",
# which has no fm-spawn.sh launch template.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/config"
  touch "$w/home/state/.last-watcher-beat"
  printf 'codex\n' > "$w/home/config/crew-harness"
  printf '%s\n' "$w"
}

# add_sm_home <w> <id> <window>: a plain (non-git) secondmate home - the
# probe/respawn machinery under test never requires the home to be a real
# worktree; a non-git home just makes the unrelated fast-forward sweep log a
# harmless "not a git repo" skip.
add_sm_home() {
  local w=$1 id=$2 window=$3 harness=${4:-claude}
  local home="$w/$id"
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'charter\n' > "$home/data/charter.md"
  {
    printf 'window=%s\n' "$window"
    printf 'kind=secondmate\n'
    printf 'harness=%s\n' "$harness"
    printf 'home=%s\n' "$home"
  } > "$w/home/state/$id.meta"
}

run_bootstrap() {  # <fakebin> <home> <pane-cmd> <call-log> [extra env...] -> stdout
  local fb=$1 home=$2 cmd=$3 log=$4; shift 4
  PATH="$fb:$BASE_PATH" TMUX='' FM_BACKEND=tmux FM_HOME="$home" \
    FM_TEST_PANE_CMD="$cmd" FM_TMUX_CALL_LOG="$log" \
    env "$@" "$ROOT/bin/fm-bootstrap.sh" 2>&1
}

test_sweep_reports_confirmed_dead_secondmate_without_mutation() {
  local w fb tmuxfb log out
  w=$(new_world sweep-dead)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: stopped" \
    "a bare-shell (dead) secondmate should be reported as stopped"
  [ ! -s "$log" ] || fail "startup must not kill or relaunch a stopped coordinator: $(cat "$log")"
  pass "sweep: a confirmed-dead coordinator is reported without mutation"
}

test_sweep_reports_secondmate_without_window_as_stopped() {
  local w fb tmuxfb log out
  w=$(new_world sweep-no-window)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  grep -v '^window=' "$w/home/state/sm1.meta" > "$w/home/state/sm1.meta.next"
  mv "$w/home/state/sm1.meta.next" "$w/home/state/sm1.meta"
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: stopped" \
    "a secondmate without endpoint metadata should be reported as stopped"
  [ ! -s "$log" ] || fail "missing endpoint metadata must not mutate a coordinator: $(cat "$log")"
  pass "sweep: a secondmate without endpoint metadata is reported as stopped"
}

test_sweep_reports_missing_endpoint_as_stopped() {
  local w fb tmuxfb log out
  w=$(new_world sweep-missing-endpoint)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" claude "$log" FM_TEST_TARGET_EXISTS=0)

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: stopped" \
    "a missing endpoint should be reported as stopped"
  [ ! -s "$log" ] || fail "a missing endpoint must not mutate a coordinator: $(cat "$log")"
  pass "sweep: a missing endpoint is reported as stopped"
}

test_sweep_reports_endpoint_query_failure_as_unproven() {
  local w fb tmuxfb log out
  w=$(new_world sweep-endpoint-query-failure)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" claude "$log" FM_TEST_TARGET_EXISTS=0 FM_TEST_TARGET_PROBE=failure)

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: liveness unproven" \
    "an endpoint query failure must not be misclassified as stopped"
  [ ! -s "$log" ] || fail "an endpoint query failure must not mutate a coordinator: $(cat "$log")"
  pass "sweep: endpoint query failures are unproven and report-only"
}

test_sweep_leaves_alive_secondmate_untouched() {
  local w fb tmuxfb log out
  w=$(new_world sweep-alive)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" claude "$log")

  assert_not_contains "$out" "SECONDMATE_LIVENESS:" \
    "a live coordinator should stay quiet in the startup report"
  [ ! -s "$log" ] || fail "an already-live secondmate must never be touched: $(cat "$log")"
  pass "sweep: an already-live secondmate is left untouched and quiet"
}

test_sweep_never_acts_on_inconclusive_reading() {
  local w fb tmuxfb log out
  w=$(new_world sweep-unknown)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  # "node" is the ambiguous bare-interpreter case (docs/tmux-backend.md
  # "Known gap") - ANY reading less than confident-dead must never respawn.
  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" node "$log")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: liveness unproven" \
    "an inconclusive probe reading should be reported as unproven"
  [ ! -s "$log" ] || fail "an inconclusive reading must never mutate an endpoint: $(cat "$log")"
  pass "sweep: a transient/unknown probe reading is reported but never acted on"
}

test_sweep_never_acts_on_unverified_harness_dead_reading() {
  local w fb tmuxfb log out
  w=$(new_world sweep-unverified-harness)
  add_sm_home "$w" sm1 firstmate:fm-sm1 custom-agent
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: stopped" \
    "a stopped endpoint is reported independently from its recorded harness"
  [ ! -s "$log" ] || fail "an unverified harness must never trigger endpoint mutation: $(cat "$log")"
  pass "sweep: stopped endpoints are report-only for every harness"
}

test_sweep_never_retouches_across_reports() {
  local w fb tmuxfb log out1 out2
  w=$(new_world sweep-idempotent)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  # Round 1: a stopped coordinator is reported, not restarted.
  out1=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")
  assert_contains "$out1" "SECONDMATE_LIVENESS: secondmate sm1: stopped" "round 1 should report the stopped coordinator"
  [ ! -s "$log" ] || fail "round 1 must not start or stop the coordinator"

  # Round 2: when the coordinator becomes live through an explicit local
  # resume, bootstrap remains quiet and still does not touch it.
  : > "$log"
  out2=$(run_bootstrap "$tmuxfb:$fb" "$w/home" claude "$log")
  assert_not_contains "$out2" "SECONDMATE_LIVENESS:" "round 2 should keep a live coordinator quiet"
  [ ! -s "$log" ] || fail "round 2 must not touch an already-live secondmate: $(cat "$log")"
  pass "sweep: startup reports but never re-touches coordinators"
}

test_sweep_reports_under_detect_only() {
  local w fb tmuxfb log out
  w=$(new_world sweep-detect-only)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  mkdir -p "$w/home/config"
  printf 'codex\n' > "$w/home/config/crew-harness"
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log" FM_BOOTSTRAP_DETECT_ONLY=1)

  assert_contains "$out" "CREW_HARNESS_OVERRIDE: codex" \
    "detect-only should still execute fm-bootstrap.sh's read-only diagnostics"
  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: stopped" \
    "detect-only should report stopped coordinators through the read-only liveness sweep"
  [ ! -s "$log" ] || fail "detect-only must never touch any endpoint: $(cat "$log")"
  pass "sweep: reports under FM_BOOTSTRAP_DETECT_ONLY=1 without endpoint mutation"
}

test_sweep_noop_with_no_secondmate_meta() {
  local w fb tmuxfb log out
  w=$(new_world sweep-no-secondmates)
  # No add_sm_home call: this state/ dir looks exactly like what a
  # secondmate's OWN home always has (secondmates never spawn secondmates),
  # proving the sweep's primary-only scoping falls out naturally.
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")

  assert_not_contains "$out" "SECONDMATE_LIVENESS:" \
    "with no kind=secondmate meta present, the sweep must print nothing"
  [ ! -s "$log" ] || fail "with no secondmate meta, no endpoint should ever be touched: $(cat "$log")"
  pass "sweep: a silent no-op with no kind=secondmate meta present (a secondmate home's own natural scoping)"
}

test_tmux_agent_alive_classifies
test_herdr_agent_alive_maps_pane_agent_state
test_agent_alive_dispatcher_routes_and_falls_back
test_target_state_recognizes_herdr_pane_not_found
test_target_state_recognizes_orca_stale_terminal
test_target_state_leaves_backend_failures_unproven
test_target_state_recognizes_tmux_cold_boot_as_absence
test_target_state_leaves_other_tmux_connection_errors_unproven
test_sweep_reports_confirmed_dead_secondmate_without_mutation
test_sweep_reports_secondmate_without_window_as_stopped
test_sweep_reports_missing_endpoint_as_stopped
test_sweep_reports_endpoint_query_failure_as_unproven
test_sweep_leaves_alive_secondmate_untouched
test_sweep_never_acts_on_inconclusive_reading
test_sweep_never_acts_on_unverified_harness_dead_reading
test_sweep_never_retouches_across_reports
test_sweep_reports_under_detect_only
test_sweep_noop_with_no_secondmate_meta

echo "# all fm-secondmate-liveness tests passed"
