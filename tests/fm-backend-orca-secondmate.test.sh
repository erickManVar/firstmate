#!/usr/bin/env bash
# tests/fm-backend-orca-secondmate.test.sh - native Orca hosting for persistent
# secondmate coordinators: home adoption (never creation), titled-terminal
# reuse and duplicate prevention, the lsof cwd-based agent-liveness classifier,
# fm-spawn.sh's --secondmate --backend orca path, and the session-start
# report-only startup liveness for an Orca secondmate without mutating it.
#
# Uses a subcommand-keyed fake `orca` (unlike tests/fm-backend-orca.test.sh's
# sequence-keyed fake) because the secondmate spawn path's call count varies by
# scenario, plus a fake `lsof` answering the cwd-scoped process probe.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-backend-orca-secondmate)
# Physical form: the adoption helper canonicalizes paths (macOS /var -> /private/var),
# so every path the tests compare against must already be physical.
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

# make_orca_sm_fakebin <dir>: a fake `orca` whose answers are keyed by
# subcommand and driven by knob files in $FM_ORCA_CFG:
#   repo-registered           registered repo paths, one per line (repo show/add)
#   worktree-path-override    worktree show returns this path instead of the selector's
#   terminal-list             "title<TAB>handle" lines for terminal list
#   terminal-create-fail      presence makes terminal create fail
#   terminal-show-fail        presence makes terminal show fail
#   termpath                  worktreePath answered by terminal show
# plus a fake `lsof` answering the cwd probe from $FM_FAKE_LSOF_COMMS
# (space-separated comm names; empty/unset means no process holds the cwd).
make_orca_sm_fakebin() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/orca" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_ORCA_LOG:?}"
CFG="${FM_ORCA_CFG:?}"
{
  printf 'orca'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
argval() {
  local f=$1; shift
  while [ $# -gt 0 ]; do
    if [ "$1" = "$f" ]; then printf '%s' "${2:-}"; return 0; fi
    shift
  done
  return 1
}
case "${1:-} ${2:-}" in
  'status --json')
    printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n' ;;
  'repo show')
    p=$(argval --repo "$@"); p=${p#path:}
    if [ -f "$CFG/repo-registered" ] && grep -qxF "$p" "$CFG/repo-registered"; then
      printf '{"ok":true,"result":{"repo":{"id":"repo::%s"}}}\n' "$p"
    else
      printf '{"ok":false,"error":{"code":"repo_not_found","message":"repo not found"}}\n'
      exit 1
    fi ;;
  'repo add')
    p=$(argval --path "$@")
    printf '%s\n' "$p" >> "$CFG/repo-registered"
    printf '{"ok":true,"result":{"repo":{"id":"repo::%s"}}}\n' "$p" ;;
  'worktree show')
    sel=$(argval --worktree "$@"); p=${sel#path:}
    if [ -f "$CFG/worktree-path-override" ]; then
      p2=$(cat "$CFG/worktree-path-override")
    else
      p2=$p
    fi
    printf '{"ok":true,"result":{"worktree":{"id":"wt::%s","path":"%s"}}}\n' "$p" "$p2" ;;
  'terminal list')
    printf '{"ok":true,"result":{"terminals":['
    if [ -f "$CFG/terminal-list" ]; then
      first=1
      while IFS=$'\t' read -r ti ha; do
        [ -n "$ti" ] || continue
        [ "$first" = 1 ] || printf ','
        first=0
        printf '{"handle":"%s","title":"%s"}' "$ha" "$ti"
      done < "$CFG/terminal-list"
    fi
    printf ']}}\n' ;;
  'terminal create')
    if [ -f "$CFG/terminal-create-fail" ]; then
      printf '{"ok":false,"error":{"code":"terminal_create_failed","message":"terminal create failed"}}\n'
      exit 1
    fi
    ti=$(argval --title "$@")
    n=$(( $(cat "$CFG/term-count" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$CFG/term-count"
    printf '{"ok":true,"result":{"terminal":{"handle":"term-%s-%s"}}}\n' "$ti" "$n" ;;
  'terminal show')
    if [ -f "$CFG/terminal-show-fail" ]; then
      printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n'
      exit 1
    fi
    h=$(argval --terminal "$@")
    printf '{"ok":true,"result":{"terminal":{"handle":"%s","worktreePath":"%s"}}}\n' \
      "$h" "$(cat "$CFG/termpath" 2>/dev/null || true)" ;;
  'terminal read')
    printf '{"ok":true,"result":{"terminal":{"tail":["idle"]}}}\n' ;;
  'terminal send'|'terminal close')
    printf '{"ok":true,"result":{}}\n' ;;
  'worktree create')
    printf '{"ok":true,"result":{"worktree":{"id":"wt-unexpected","path":"/nonexistent"}}}\n' ;;
  'worktree rm')
    printf '{"ok":true,"result":{}}\n' ;;
  *)
    printf '{"ok":true,"result":{}}\n' ;;
esac
SH
  chmod +x "$fb/orca"
  cat > "$fb/lsof" <<'SH'
#!/usr/bin/env bash
set -u
comms="${FM_FAKE_LSOF_COMMS:-}"
[ -n "$comms" ] || exit 1
i=100
for c in $comms; do
  printf 'p%s\nc%s\n' "$i" "$c"
  i=$((i + 1))
done
SH
  chmod +x "$fb/lsof"
  printf '%s\n' "$fb"
}

orca_sm_case() {  # <name> -> sets CASE_DIR LOG CFG FB
  CASE_DIR="$TMP_ROOT/$1"
  mkdir -p "$CASE_DIR/cfg"
  LOG="$CASE_DIR/log"
  CFG="$CASE_DIR/cfg"
  : > "$LOG"
  FB=$(make_orca_sm_fakebin "$CASE_DIR")
}

# make_sm_home <dir> <id>: a seeded-looking secondmate home that passes
# fm-spawn.sh's validate_firstmate_home_for_spawn plus a charter brief.
make_sm_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'charter\n' > "$home/data/charter.md"
}

# make_primary_home <dir>: a primary firstmate home for FM_HOME.
make_primary_home() {
  local home=$1
  mkdir -p "$home/state" "$home/data" "$home/config"
  touch "$home/state/.last-watcher-beat"
}

run_sm_spawn() {  # <primary-home> <id> <sm-home> [extra spawn args...]
  local primary=$1 id=$2 smhome=$3; shift 3
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_CFG="$CFG" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$primary" \
    FM_STATE_OVERRIDE="$primary/state" FM_DATA_OVERRIDE="$primary/data" \
    FM_CONFIG_OVERRIDE="$primary/config" FM_PROJECTS_OVERRIDE="$primary/projects" \
    FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$smhome" claude --backend orca --secondmate "$@" 2>&1
}

# --- unit level: fm_backend_orca_worktree_adopt ------------------------------

test_adopt_resolves_registered_home_without_creating() {
  local home out wt_id wt_path
  orca_sm_case adopt-registered
  home="$CASE_DIR/home"; mkdir -p "$home"
  printf '%s\n' "$home" > "$CFG/repo-registered"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_CFG="$CFG" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_adopt "$1"' "$ROOT" "$home" )
  expect_code 0 $? "adopt should succeed for a registered home"
  wt_id=${out%%$'\t'*}
  wt_path=${out#*$'\t'}
  [ "$wt_id" = "wt::$home" ] || fail "adopt should print the resolved Orca worktree id, got '$wt_id'"
  [ "$wt_path" = "$home" ] || fail "adopt should print the physical home path, got '$wt_path'"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''show'$'\x1f''--worktree'$'\x1f'"path:$home" \
    "adopt should resolve the home by path through worktree show"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''create' \
    "adopt must never create an Orca worktree"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''repo'$'\x1f''add' \
    "adopt should not re-register an already-registered repo"
  pass "fm_backend_orca_worktree_adopt: resolves a registered home by path, never creates"
}

test_adopt_registers_missing_repo_once() {
  local home out
  orca_sm_case adopt-unregistered
  home="$CASE_DIR/home"; mkdir -p "$home"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_CFG="$CFG" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_adopt "$1"' "$ROOT" "$home" )
  expect_code 0 $? "adopt should register a missing repo and resolve it"
  assert_contains "$(cat "$LOG")" $'orca\x1f''repo'$'\x1f''add'$'\x1f''--path'$'\x1f'"$home" \
    "adopt should register the home as an Orca repo when missing"
  pass "fm_backend_orca_worktree_adopt: registers an unregistered home once, then resolves it"
}

test_adopt_refuses_path_mismatch() {
  local home out status
  orca_sm_case adopt-mismatch
  home="$CASE_DIR/home"; mkdir -p "$home"
  printf '%s\n' "$home" > "$CFG/repo-registered"
  printf '/somewhere/else\n' > "$CFG/worktree-path-override"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_CFG="$CFG" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_adopt "$1"' "$ROOT" "$home" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "adopt must fail closed when Orca resolves a different path"
  assert_contains "$out" "does not match" "adopt should explain the worktree/home path mismatch"
  pass "fm_backend_orca_worktree_adopt: fails closed on an ambiguous/mismatched Orca worktree"
}

test_adopt_refuses_missing_home() {
  local out status
  orca_sm_case adopt-missing-home
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_CFG="$CFG" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_adopt /nonexistent-home-xyz' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "adopt must fail closed for an unknown home path"
  [ ! -s "$LOG" ] || fail "adopt must not call Orca for a nonexistent home: $(cat "$LOG")"
  pass "fm_backend_orca_worktree_adopt: fails closed on an unknown home before any Orca call"
}

# --- unit level: fm_backend_orca_terminal_find -------------------------------

test_terminal_find_none_one_ambiguous() {
  local out status
  orca_sm_case term-find
  # none
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_CFG="$CFG" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_terminal_find /w fm-x' "$ROOT" )
  status=$?
  [ "$status" -eq 1 ] && [ -z "$out" ] || fail "no titled terminal should be rc=1 with no output, got rc=$status '$out'"
  # exactly one
  printf 'fm-x\tterm-one\nother\tterm-two\n' > "$CFG/terminal-list"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_CFG="$CFG" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_terminal_find /w fm-x' "$ROOT" )
  status=$?
  [ "$status" -eq 0 ] && [ "$out" = term-one ] || fail "exactly one titled terminal should print its handle, got rc=$status '$out'"
  # ambiguous
  printf 'fm-x\tterm-one\nfm-x\tterm-dup\n' > "$CFG/terminal-list"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_CFG="$CFG" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_terminal_find /w fm-x' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -eq 2 ] || fail "duplicate titled terminals must be rc=2 (ambiguous), got rc=$status '$out'"
  pass "fm_backend_orca_terminal_find: none->1, one->0+handle, duplicates->2 (fail closed)"
}

# --- unit level: fm_backend_orca_agent_alive ---------------------------------

orca_alive_probe() {  # <comms> [termpath]
  local comms=$1 termpath=${2-$CASE_DIR/home}
  printf '%s\n' "$termpath" > "$CFG/termpath"
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_CFG="$CFG" FM_FAKE_LSOF_COMMS="$comms" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_agent_alive term-probe' "$ROOT"
}

test_orca_agent_alive_classifies() {
  local out
  orca_sm_case agent-alive
  mkdir -p "$CASE_DIR/home"

  out=$(orca_alive_probe "zsh claude node")
  [ "$out" = alive ] || fail "a claude process rooted in the home should classify alive, got '$out'"

  out=$(orca_alive_probe "zsh 2.1.208")
  [ "$out" = alive ] || fail "a version-named harness process (2.1.208) should classify alive, got '$out'"

  out=$(orca_alive_probe "zsh")
  [ "$out" = dead ] || fail "only shells rooted in the home should classify dead, got '$out'"

  out=$(orca_alive_probe "zsh bash")
  [ "$out" = dead ] || fail "multiple bare shells should still classify dead, got '$out'"

  out=$(orca_alive_probe "zsh node")
  [ "$out" = unknown ] || fail "an ambiguous interpreter (node, e.g. pi) must classify unknown, never dead, got '$out'"

  out=$(orca_alive_probe "python3.11")
  [ "$out" = unknown ] || fail "an interpreter-with-version name must stay unknown, got '$out'"

  out=$(orca_alive_probe "")
  [ "$out" = unknown ] || fail "no process rooted in the home is not provably dead; must be unknown, got '$out'"

  out=$(orca_alive_probe "claude" "")
  [ "$out" = unknown ] || fail "a terminal with no worktreePath must classify unknown, got '$out'"

  touch "$CFG/terminal-show-fail"
  out=$(orca_alive_probe "claude")
  [ "$out" = unknown ] || fail "an unreadable terminal must classify unknown, got '$out'"
  rm -f "$CFG/terminal-show-fail"

  pass "fm_backend_orca_agent_alive: alive/dead/unknown classification incl. version token and fail-closed ambiguity"
}

test_agent_alive_dispatcher_routes_orca() {
  local out
  orca_sm_case agent-alive-dispatch
  mkdir -p "$CASE_DIR/home"
  printf '%s\n' "$CASE_DIR/home" > "$CFG/termpath"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_CFG="$CFG" FM_FAKE_LSOF_COMMS="claude" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_alive orca term-probe' "$ROOT" )
  [ "$out" = alive ] || fail "fm_backend_agent_alive should route orca to the Orca classifier, got '$out'"
  pass "fm_backend_agent_alive: routes orca to fm_backend_orca_agent_alive"
}

# --- spawn level: fm-spawn.sh --secondmate --backend orca --------------------

test_spawn_secondmate_orca_adopts_home_and_launches() {
  local id primary smhome out
  id="orcasmnativea1"
  orca_sm_case spawn-native
  primary="$CASE_DIR/primary"; make_primary_home "$primary"
  smhome="$CASE_DIR/orca-proj/.secondmate"; make_sm_home "$smhome" "$id"
  out=$(run_sm_spawn "$primary" "$id" "$smhome")
  expect_code 0 $? "fm-spawn.sh --secondmate --backend orca should succeed"$'\n'"$out"
  assert_grep "backend=orca" "$primary/state/$id.meta" "meta missing backend=orca"
  assert_grep "kind=secondmate" "$primary/state/$id.meta" "meta missing kind=secondmate"
  assert_grep "window=fm-$id" "$primary/state/$id.meta" "meta missing stable window alias"
  assert_grep "terminal=term-fm-$id-1" "$primary/state/$id.meta" "meta missing the created terminal handle"
  assert_grep "orca_worktree_id=wt::" "$primary/state/$id.meta" "meta missing the adopted Orca worktree id"
  assert_grep "home=$smhome" "$primary/state/$id.meta" "meta missing home="
  assert_grep "worktree=$smhome" "$primary/state/$id.meta" "meta worktree must be the persistent home itself"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''create' \
    "a secondmate spawn must adopt the home, never create an Orca worktree"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "a secondmate spawn must never remove an Orca worktree"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''create'$'\x1f''--worktree'$'\x1f'"id:wt::" \
    "spawn should create the coordinator terminal in the adopted worktree"
  assert_contains "$(cat "$LOG")" "FM_HOME='$smhome'" \
    "the launch must scope the secondmate agent to its own FM_HOME"
  assert_contains "$(cat "$LOG")" "claude --dangerously-skip-permissions" \
    "spawn should launch the selected harness through the Orca terminal"
  # No repository pollution: the home gained no unexpected entries.
  assert_absent "$smhome/.claude/settings.local.json" \
    "secondmate spawn must not install crewmate turn-end hooks in the home"
  rm -rf "/tmp/fm-$id"
  pass "fm-spawn.sh --secondmate --backend orca: adopts the home, creates one titled terminal, launches with FM_HOME"
}

test_spawn_secondmate_orca_two_homes_distinct_identities() {
  local id1 id2 primary sm1 sm2 out t1 t2 w1 w2
  id1="orcasmggb2"; id2="orcasmayjb3"
  orca_sm_case spawn-two-homes
  primary="$CASE_DIR/primary"; make_primary_home "$primary"
  sm1="$CASE_DIR/ggstore/.secondmate"; make_sm_home "$sm1" "$id1"
  sm2="$CASE_DIR/ayjestudios/.secondmate"; make_sm_home "$sm2" "$id2"
  out=$(run_sm_spawn "$primary" "$id1" "$sm1")
  expect_code 0 $? "first home spawn should succeed"$'\n'"$out"
  out=$(run_sm_spawn "$primary" "$id2" "$sm2")
  expect_code 0 $? "second home spawn should succeed"$'\n'"$out"
  t1=$(sed -n 's/^terminal=//p' "$primary/state/$id1.meta")
  t2=$(sed -n 's/^terminal=//p' "$primary/state/$id2.meta")
  w1=$(sed -n 's/^orca_worktree_id=//p' "$primary/state/$id1.meta")
  w2=$(sed -n 's/^orca_worktree_id=//p' "$primary/state/$id2.meta")
  [ -n "$t1" ] && [ -n "$t2" ] && [ "$t1" != "$t2" ] || fail "concurrent homes must have distinct terminals, got '$t1' vs '$t2'"
  [ -n "$w1" ] && [ -n "$w2" ] && [ "$w1" != "$w2" ] || fail "concurrent homes must have distinct Orca worktree ids, got '$w1' vs '$w2'"
  [ "$w1" = "wt::$sm1" ] || fail "first home's worktree id must be its own home, got '$w1'"
  [ "$w2" = "wt::$sm2" ] || fail "second home's worktree id must be its own home, got '$w2'"
  rm -rf "/tmp/fm-$id1" "/tmp/fm-$id2"
  pass "fm-spawn.sh --secondmate --backend orca: two concurrent homes keep independent worktree and terminal identities"
}

test_spawn_secondmate_orca_refuses_live_duplicate() {
  local id primary smhome out status
  id="orcasmdupc4"
  orca_sm_case spawn-dup-live
  primary="$CASE_DIR/primary"; make_primary_home "$primary"
  smhome="$CASE_DIR/proj/.secondmate"; make_sm_home "$smhome" "$id"
  printf 'fm-%s\tterm-live\n' "$id" > "$CFG/terminal-list"
  printf '%s\n' "$smhome" > "$CFG/termpath"
  out=$(FM_FAKE_LSOF_COMMS="claude" run_sm_spawn "$primary" "$id" "$smhome")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn must refuse when a live coordinator terminal already exists: $out"
  assert_contains "$out" "live coordinator" "the duplicate refusal should name the live coordinator"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''create' \
    "a live duplicate must never trigger a second terminal"
  assert_absent "$primary/state/$id.meta" "a refused duplicate spawn must not record meta"
  pass "fm-spawn.sh --secondmate --backend orca: refuses a duplicate launch over a live coordinator"
}

test_spawn_secondmate_orca_replaces_dead_terminal() {
  local id primary smhome out
  id="orcasmdeadd5"
  orca_sm_case spawn-dup-dead
  primary="$CASE_DIR/primary"; make_primary_home "$primary"
  smhome="$CASE_DIR/proj/.secondmate"; make_sm_home "$smhome" "$id"
  printf 'fm-%s\tterm-stale\n' "$id" > "$CFG/terminal-list"
  printf '%s\n' "$smhome" > "$CFG/termpath"
  out=$(FM_FAKE_LSOF_COMMS="zsh" run_sm_spawn "$primary" "$id" "$smhome")
  expect_code 0 $? "spawn should replace a confidently dead coordinator terminal"$'\n'"$out"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-stale' \
    "the dead titled terminal should be closed before relaunch"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''create' \
    "a fresh coordinator terminal should be created after clearing the dead one"
  assert_grep "terminal=term-fm-$id-1" "$primary/state/$id.meta" "meta should record the fresh terminal"
  rm -rf "/tmp/fm-$id"
  pass "fm-spawn.sh --secondmate --backend orca: clears a confidently dead titled terminal and relaunches"
}

test_spawn_secondmate_orca_fails_closed_on_unproven_liveness() {
  local id primary smhome out status
  id="orcasmunke6"
  orca_sm_case spawn-dup-unknown
  primary="$CASE_DIR/primary"; make_primary_home "$primary"
  smhome="$CASE_DIR/proj/.secondmate"; make_sm_home "$smhome" "$id"
  printf 'fm-%s\tterm-mystery\n' "$id" > "$CFG/terminal-list"
  printf '%s\n' "$smhome" > "$CFG/termpath"
  out=$(FM_FAKE_LSOF_COMMS="node" run_sm_spawn "$primary" "$id" "$smhome")
  status=$?
  [ "$status" -ne 0 ] || fail "unproven liveness must fail closed, not spawn a possible duplicate: $out"
  assert_contains "$out" "unproven" "the refusal should name the unproven liveness"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "an unproven terminal must never be killed"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''create' \
    "an unproven terminal must never be doubled"
  pass "fm-spawn.sh --secondmate --backend orca: unproven liveness of an existing terminal fails closed"
}

test_spawn_secondmate_orca_refuses_ambiguous_terminals() {
  local id primary smhome out status
  id="orcasmambf7"
  orca_sm_case spawn-ambiguous
  primary="$CASE_DIR/primary"; make_primary_home "$primary"
  smhome="$CASE_DIR/proj/.secondmate"; make_sm_home "$smhome" "$id"
  printf 'fm-%s\tterm-a\nfm-%s\tterm-b\n' "$id" "$id" > "$CFG/terminal-list"
  out=$(run_sm_spawn "$primary" "$id" "$smhome")
  status=$?
  [ "$status" -ne 0 ] || fail "ambiguous titled terminals must fail closed: $out"
  assert_contains "$out" "ambiguous" "the refusal should name the ambiguity"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''create' \
    "ambiguity must never be resolved by creating yet another terminal"
  pass "fm-spawn.sh --secondmate --backend orca: ambiguous titled terminals fail closed"
}

test_spawn_secondmate_orca_abort_preserves_home() {
  local id primary smhome out status
  id="orcasmabortg8"
  orca_sm_case spawn-abort
  primary="$CASE_DIR/primary"; make_primary_home "$primary"
  smhome="$CASE_DIR/proj/.secondmate"; make_sm_home "$smhome" "$id"
  touch "$CFG/terminal-create-fail"
  out=$(run_sm_spawn "$primary" "$id" "$smhome")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should fail when the coordinator terminal cannot be created: $out"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "abort cleanup must never remove the persistent home worktree"
  assert_present "$smhome/.fm-secondmate-home" "the home must survive an aborted spawn"
  assert_absent "$primary/state/$id.meta" "an aborted spawn must not record meta"
  pass "fm-spawn.sh --secondmate --backend orca: aborts preserve the persistent home worktree"
}

# --- teardown level: explicit retirement of an Orca-hosted secondmate --------

test_teardown_retires_orca_secondmate_closing_only_terminal() {
  local id primary smhome out
  id="orcasmretirei1"
  orca_sm_case teardown-retire
  primary="$CASE_DIR/primary"; make_primary_home "$primary"
  smhome="$CASE_DIR/proj/.secondmate"; make_sm_home "$smhome" "$id"
  fm_write_meta "$primary/state/$id.meta" \
    "window=fm-$id" "terminal=term-live" "worktree=$smhome" "project=$smhome" \
    "harness=claude" "kind=secondmate" "mode=secondmate" "backend=orca" \
    "orca_worktree_id=wt::$smhome" "home=$smhome"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_CFG="$CFG" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$primary" \
    FM_STATE_OVERRIDE="$primary/state" FM_DATA_OVERRIDE="$primary/data" \
    FM_CONFIG_OVERRIDE="$primary/config" FM_PROJECTS_OVERRIDE="$primary/projects" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  expect_code 0 $? "retiring an Orca-hosted secondmate should succeed"$'\n'"$out"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-live' \
    "retirement should close the recorded coordinator terminal"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "retirement must never run orca worktree rm against the home"
  assert_absent "$primary/state/$id.meta" "retirement should clear the meta"
  assert_absent "$smhome" "retirement should remove the retired home through the guarded path"
  pass "fm-teardown.sh: an Orca-hosted secondmate retires by closing its terminal, never orca worktree rm"
}

test_adopt_resolves_registered_home_without_creating
test_adopt_registers_missing_repo_once
test_adopt_refuses_path_mismatch
test_adopt_refuses_missing_home
test_terminal_find_none_one_ambiguous
test_orca_agent_alive_classifies
test_agent_alive_dispatcher_routes_orca
test_spawn_secondmate_orca_adopts_home_and_launches
test_spawn_secondmate_orca_two_homes_distinct_identities
test_spawn_secondmate_orca_refuses_live_duplicate
test_spawn_secondmate_orca_replaces_dead_terminal
test_spawn_secondmate_orca_fails_closed_on_unproven_liveness
test_spawn_secondmate_orca_refuses_ambiguous_terminals
test_spawn_secondmate_orca_abort_preserves_home
test_teardown_retires_orca_secondmate_closing_only_terminal

echo "# all fm-backend-orca-secondmate tests passed"
