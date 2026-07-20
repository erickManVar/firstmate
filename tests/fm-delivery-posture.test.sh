#!/usr/bin/env bash
# Behavior tests for the rapid-local / peer-ship delivery posture record
# (docs/configuration.md "Delivery posture"): fm-spawn.sh reading and
# persisting data/<id>/delivery into task meta with the effective-mode mapping,
# the fail-closed paths for unknown values and posture/mode conflicts, legacy
# behavior when no record exists, and fm-promote.sh's required posture.
#
# Spawns drive the real fm-spawn.sh through a fake tmux pane and a real
# isolated git worktree, the same pattern as tests/fm-spawn-dispatch-profile.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
TMP_ROOT=$(fm_test_tmproot fm-delivery-posture)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_delivery_case <name> <registered-mode> <id>: build a per-case legacy-mode
# home whose registry records the internal projects/project clone with the given
# mode, so fm-project-mode.sh resolves a real registered mode for the spawn.
make_delivery_case() {
  local name=$1 mode=$2 id=$3 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$home/projects/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  printf -- '- project [%s] - delivery posture fixture (added 2026-07-14)\n' "$mode" > "$home/data/projects.md"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_case_record() {
  IFS='|' read -r _ HOME_DIR _ WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

run_promote() {
  local home=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$PROMOTE" "$@" 2>&1
}

test_rapid_local_record_persists_and_maps_mode() {
  local rec id out status meta
  id=dlv-rapid-a1
  rec=$(make_delivery_case rapid-local no-mistakes "$id")
  read_case_record "$rec"
  printf 'rapid-local\n' > "$HOME_DIR/data/$id/delivery"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" project)
  status=$?
  expect_code 0 "$status" "rapid-local spawn should succeed"$'\n'"$out"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep "delivery=rapid-local" "$meta" "meta missing delivery=rapid-local"
  assert_grep "mode=local-only" "$meta" "rapid-local did not map the effective mode to local-only"
  assert_contains "$out" "mode=local-only" "spawn report did not carry the effective mode"
  pass "a rapid-local record persists as delivery= and forces mode=local-only over the registered mode"
}

test_peer_ship_record_keeps_registered_mode() {
  local rec id out status meta
  id=dlv-peer-a2
  rec=$(make_delivery_case peer-ship direct-PR "$id")
  read_case_record "$rec"
  printf 'peer-ship\n' > "$HOME_DIR/data/$id/delivery"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" project)
  status=$?
  expect_code 0 "$status" "peer-ship spawn should succeed"$'\n'"$out"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep "delivery=peer-ship" "$meta" "meta missing delivery=peer-ship"
  assert_grep "mode=direct-PR" "$meta" "peer-ship did not keep the registered mode"
  pass "a peer-ship record persists as delivery= and keeps the registered remote mode"
}

test_absent_record_keeps_legacy_meta() {
  local rec id out status meta
  id=dlv-legacy-a3
  rec=$(make_delivery_case legacy no-mistakes "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" project)
  status=$?
  expect_code 0 "$status" "legacy spawn without a record should succeed"$'\n'"$out"
  meta="$HOME_DIR/state/$id.meta"
  assert_no_grep "delivery=" "$meta" "legacy meta must not carry a delivery= line"
  assert_grep "mode=no-mistakes" "$meta" "legacy spawn lost the registered mode"
  pass "a ship task with no posture record keeps legacy project-mode meta unchanged"
}

test_invalid_record_fails_closed_before_meta() {
  local rec id out status
  id=dlv-bogus-a4
  rec=$(make_delivery_case bogus no-mistakes "$id")
  read_case_record "$rec"
  printf 'sideways\n' > "$HOME_DIR/data/$id/delivery"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" project)
  status=$?
  expect_code 1 "$status" "an unknown recorded posture must fail the spawn"
  assert_contains "$out" "unknown delivery posture" "refusal did not name the unknown posture"
  assert_absent "$HOME_DIR/state/$id.meta" "refusal must happen before meta is written"
  pass "an unknown recorded posture fails closed before any meta is written"
}

test_peer_ship_on_local_only_project_refused() {
  local rec id out status
  id=dlv-conflict-a5
  rec=$(make_delivery_case conflict local-only "$id")
  read_case_record "$rec"
  printf 'peer-ship\n' > "$HOME_DIR/data/$id/delivery"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" project)
  status=$?
  expect_code 1 "$status" "peer-ship on a local-only project must fail the spawn"
  assert_contains "$out" "remote-capable delivery mode" "refusal did not explain the posture/mode conflict"
  assert_absent "$HOME_DIR/state/$id.meta" "conflict refusal must happen before meta is written"
  pass "peer-ship on a local-only project fails closed before any meta is written"
}

test_scout_spawn_ignores_delivery_record() {
  local rec id out status meta
  id=dlv-scout-a6
  rec=$(make_delivery_case scout no-mistakes "$id")
  read_case_record "$rec"
  printf 'rapid-local\n' > "$HOME_DIR/data/$id/delivery"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" project --scout)
  status=$?
  expect_code 0 "$status" "scout spawn should ignore a stray delivery record"$'\n'"$out"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep "kind=scout" "$meta" "scout meta missing kind=scout"
  assert_no_grep "delivery=" "$meta" "scout meta must never carry a delivery= line"
  pass "scout spawns are posture-free even when a stray record exists"
}

# --- fm-promote.sh: promotion is new meaningful ship work -------------------

make_promote_home() {  # <name> <id> <mode>
  local name=$1 id=$2 mode=$3 home
  home="$TMP_ROOT/$name/home"
  mkdir -p "$home/data" "$home/state"
  touch "$home/state/.last-watcher-beat"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$TMP_ROOT/$name/wt" \
    "project=$TMP_ROOT/$name/project" \
    "harness=claude" \
    "kind=scout" \
    "mode=$mode" \
    "yolo=off"
  printf '%s\n' "$home"
}

test_promote_requires_delivery_posture() {
  local home out status
  home=$(make_promote_home promote-missing pr-miss-b1 no-mistakes)
  out=$(run_promote "$home" pr-miss-b1)
  status=$?
  expect_code 1 "$status" "promotion without --delivery must fail"
  assert_contains "$out" "needs an explicit delivery posture" "promotion refusal did not ask for the posture"
  assert_grep "kind=scout" "$home/state/pr-miss-b1.meta" "refused promotion must leave the meta untouched"

  out=$(run_promote "$home" pr-miss-b1 --delivery sideways)
  status=$?
  expect_code 1 "$status" "promotion with an unknown posture must fail"
  pass "fm-promote.sh fails closed without a valid delivery posture"
}

test_promote_rapid_local_rewrites_mode() {
  local home out status meta
  home=$(make_promote_home promote-rapid pr-rapid-b2 no-mistakes)
  out=$(run_promote "$home" pr-rapid-b2 --delivery rapid-local)
  status=$?
  expect_code 0 "$status" "rapid-local promotion should succeed"$'\n'"$out"
  meta="$home/state/pr-rapid-b2.meta"
  assert_grep "kind=ship" "$meta" "promotion did not flip kind to ship"
  assert_grep "mode=local-only" "$meta" "rapid-local promotion did not force mode=local-only"
  assert_grep "delivery=rapid-local" "$meta" "promotion did not record delivery=rapid-local"
  assert_present "$home/data/pr-rapid-b2/delivery" "promotion did not write the durable delivery record"
  [ "$(cat "$home/data/pr-rapid-b2/delivery")" = rapid-local ] || fail "promotion delivery record does not hold rapid-local"
  pass "rapid-local promotion records the posture and forces the local delivery mode"
}

test_promote_peer_ship_keeps_mode_and_refuses_local_only() {
  local home out status meta
  home=$(make_promote_home promote-peer pr-peer-b3 direct-PR)
  out=$(run_promote "$home" pr-peer-b3 --delivery peer-ship)
  status=$?
  expect_code 0 "$status" "peer-ship promotion should succeed"$'\n'"$out"
  meta="$home/state/pr-peer-b3.meta"
  assert_grep "kind=ship" "$meta" "promotion did not flip kind to ship"
  assert_grep "mode=direct-PR" "$meta" "peer-ship promotion did not keep the registered mode"
  assert_grep "delivery=peer-ship" "$meta" "promotion did not record delivery=peer-ship"

  home=$(make_promote_home promote-peer-local pr-peer-b4 local-only)
  out=$(run_promote "$home" pr-peer-b4 --delivery peer-ship)
  status=$?
  expect_code 1 "$status" "peer-ship promotion on a local-only project must fail"
  assert_grep "kind=scout" "$home/state/pr-peer-b4.meta" "refused promotion must leave the meta untouched"
  pass "peer-ship promotion keeps the registered mode and refuses local-only projects"
}

test_rapid_local_record_persists_and_maps_mode
test_peer_ship_record_keeps_registered_mode
test_absent_record_keeps_legacy_meta
test_invalid_record_fails_closed_before_meta
test_peer_ship_on_local_only_project_refused
test_scout_spawn_ignores_delivery_record
test_promote_requires_delivery_posture
test_promote_rapid_local_rewrites_mode
test_promote_peer_ship_keeps_mode_and_refuses_local_only

echo "# all fm-delivery-posture tests passed"
