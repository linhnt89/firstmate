#!/usr/bin/env bash
# Behavioral tests for fresh project-scoped alignment sessions.
#
# The suite exercises the public session commands with disposable parent,
# project, and ephemeral-home fixtures.  It proves that the captain-facing
# runtime is unregistered and isolated, reports are parent-archived before
# cleanup, inventory is metadata-only, retrieval is explicit, supersession
# preserves history, promotion creates an ordinary brief, and cleanup refuses
# to discard a completed result that was not retained.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SESSION="$ROOT/bin/fm-alignment-session.sh"
TMP_ROOT=$(fm_test_tmproot fm-alignment-session)
ROOT_REAL=$(cd "$ROOT" && pwd -P)

make_runtime() {
  local dir=$1 fakebin
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  get)
    printf '%s\n' "${FM_FAKE_TREEHOUSE_HOME:?}"
    ;;
  return)
    target=
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in --force) ;; *) target=$1 ;; esac
      shift
    done
    [ -z "${FM_FAKE_TREEHOUSE_RETURN_FAIL:-}" ] || exit 17
    [ -z "$target" ] || rm -rf -- "$target"
    ;;
esac
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  has-session|new-session|new-window|send-keys|kill-window)
    printf '%s\n' "$*" >> "${FM_FAKE_TMUX_LOG:?}"
    exit 0
    ;;
  capture-pane)
    printf '%s\n' "$*" >> "${FM_FAKE_TMUX_LOG:?}"
    printf '❯\n'
    exit 0
    ;;
  display-message)
    case "$*" in *'#{cursor_y}'*) printf '0\n' ;; *) printf 'firstmate\n' ;; esac
    exit 0
    ;;
  list-windows)
    printf '%s\n' "${FM_FAKE_TMUX_WINDOW:-}"
    exit 0
    ;;
esac
exit 1
SH
  cat > "$fakebin/claude" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/claude"
  : > "$dir/tmux.log"
  printf '%s\n' "$fakebin"
}

make_parent_and_project() {
  PARENT="$TMP_ROOT/parent"
  PROJECT="$TMP_ROOT/project"
  mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects" "$PROJECT"
  printf '# Fixture project\n\nCanonical project terminology.\n' > "$PROJECT/README.md"
  mkdir -p "$PROJECT/docs"
  printf '# Domain owner\n\nThe canonical domain owner is authoritative for alignment facts.\n' > "$PROJECT/docs/domain.md"
  printf '# Project operating knowledge\ncontext-owner: docs/domain.md\n' > "$PROJECT/AGENTS.md"
  git -C "$PROJECT" init -q
  git -C "$PROJECT" add README.md AGENTS.md docs/domain.md
  git -C "$PROJECT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  printf 'claude configured-model high\n' > "$PARENT/config/alignment-harness"
  FAKEBIN=$(make_runtime "$TMP_ROOT/runtime")
}

make_ephemeral_home() {
  local home="$TMP_ROOT/$1"
  git clone --quiet "$ROOT_REAL" "$home"
  printf '%s\n' "$home"
}

make_same_basename_project() {
  COLLISION_PROJECT="$TMP_ROOT/other/project"
  mkdir -p "$COLLISION_PROJECT"
  printf '# Other fixture project\n' > "$COLLISION_PROJECT/README.md"
  git -C "$COLLISION_PROJECT" init -q
  git -C "$COLLISION_PROJECT" add README.md
  git -C "$COLLISION_PROJECT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

run_session() {
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT_REAL" FM_HOME="$PARENT" \
    FM_DATA_OVERRIDE="$PARENT/data" FM_STATE_OVERRIDE="$PARENT/state" \
    FM_PROJECTS_OVERRIDE="$PARENT/projects" FM_CONFIG_OVERRIDE="$PARENT/config" \
    FM_FAKE_TREEHOUSE_HOME="$home" FM_FAKE_TMUX_LOG="$TMP_ROOT/runtime/tmux.log" \
    FM_SKIP_SECONDMATE_INHERIT=1 FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux \
    PATH="$FAKEBIN:$PATH" "$SESSION" "$@"
}

ack_preflight() {
  local home=$1 id=$2 token
  token=$(grep '^executor_ack_token=' "$PARENT/state/$id.alignment" | cut -d= -f2-)
  run_session "$home" acknowledge "$id" --kind preflight --executor-home "$home" --token "$token"
}

ack_reconciliation() {
  local home=$1 id=$2 token
  token=$(grep '^executor_ack_token=' "$PARENT/state/$id.alignment" | cut -d= -f2-)
  run_session "$home" acknowledge "$id" --kind reconciliation --executor-home "$home" --token "$token"
}

write_report() {
  local home=$1 id=$2 topic=$3 candidate=${4:-None identified.} project_path=${5:-$PROJECT} acknowledge=${6:-1}
  if [ "$acknowledge" -eq 1 ] \
    && [ "$(grep -c '^preflight_ack=acknowledged$' "$PARENT/state/$id.alignment" 2>/dev/null || true)" = 0 ]; then
    ack_preflight "$home" "$id" >/dev/null
  fi
  local home=$1 id=$2 topic=$3 candidate=${4:-None identified.} project_path=${5:-$PROJECT}
  cat > "$home/data/$id/report.md" <<EOF
# Pre-implementation alignment

## Project identity
Name: project
Path: $project_path

## Alignment identity
Session: $id
Topic: $topic
Source: local

## Goal
Deliver the aligned fixture outcome.

## Relevant facts
The current project README is canonical fixture knowledge.

## Settled decisions
Use the existing project owner and preserve the accepted behavior.

## Acceptance criteria
The resulting implementation follows the accepted contract.

## Out of scope
Unrelated project changes.

## Engineering discretion
The ordinary implementation worker chooses mechanical details.

## Remaining open decisions
None - no material open decisions remain.

## Durable-knowledge candidates
$candidate
EOF
}

assert_session_identity() {
  local id=$1 home=$2
  assert_grep "alignment_session=1" "$PARENT/state/$id.meta" \
    "fresh alignment did not carry its ephemeral session identity"
  assert_grep "kind=secondmate" "$PARENT/state/$id.meta" \
    "alignment runtime did not reuse the captain-facing Secondmate capability"
  assert_absent "$PARENT/data/secondmates.md" \
    "fresh alignment silently registered a persistent Secondmate"
  assert_not_contains "$(cat "$home/data/alignment-context.md")" \
    'The canonical domain owner is authoritative for alignment facts.' \
    "session copied unrelated canonical owner text into its compact context"
  assert_grep $'README.md\t' "$home/data/alignment-context.md" \
    "session omitted the maintained README owner from its index"
  assert_grep $'selected\tdocs/domain.md\t' "$home/data/alignment-context.md" \
    "session did not select the declared canonical documentation owner"
  assert_grep $'candidate\tREADME.md\t' "$home/data/alignment-context.md" \
    "session did not distinguish fallback documentation candidates from owners"
  assert_grep $'docs/oversized.md\t' "$home/data/alignment-context.md" \
    "session omitted the oversized owner from its navigable index"
  assert_not_contains "$(cat "$home/data/alignment-context.md")" 'unrelated owner payload' \
    "session loaded oversized owner content instead of keeping it navigable"
  assert_grep 'Current-document owner index' "$home/data/alignment-context.md" \
    "session did not provide a current-document owner index"
  assert_grep 'Historical alignment inventory' "$home/data/alignment-context.md" \
    "session did not include the compact historical inventory"
}

test_fresh_isolated_sessions_and_parent_archive() {
  local h1 h2 out token
  printf '# Oversized unrelated owner\n\n' > "$PROJECT/docs/oversized.md"
  awk 'BEGIN { for (i = 0; i < 10000; i++) print "unrelated owner payload" }' >> "$PROJECT/docs/oversized.md"
  git -C "$PROJECT" add docs/oversized.md
  git -C "$PROJECT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'add oversized owner fixture'
  h1=$(make_ephemeral_home session-one)
  out=$(run_session "$h1" start one "$PROJECT" 'first topic')
  assert_contains "$out" 'started alignment session one project=project topic=first topic' \
    "first fresh alignment was not launched"
  assert_session_identity one "$h1"
  assert_grep 'harness=claude' "$PARENT/state/one.alignment" \
    "alignment did not use the local harness configuration"
  assert_grep 'model=configured-model' "$PARENT/state/one.alignment" \
    "alignment did not use the configured model"
  assert_grep 'effort=high' "$PARENT/state/one.alignment" \
    "alignment did not use the configured effort"
  assert_grep 'launch_ack=acknowledged' "$PARENT/state/one.alignment" \
    "alignment did not record an observable launch acknowledgement"
  assert_grep 'readiness=pending' "$PARENT/state/one.alignment" \
    "launch delivery was incorrectly treated as semantic readiness"
  assert_not_contains "$(cat "$PARENT/state/one.alignment")" 'preflight_ack=acknowledged' \
    "fresh launch claimed semantic readiness before executor preflight"
  write_report "$h1" one 'first topic' 'None identified.' "$PROJECT" 0
  token=$(grep '^executor_ack_token=' "$PARENT/state/one.alignment" | cut -d= -f2-)
  if out=$(run_session "$h1" acknowledge one --kind preflight --executor-home "$PARENT" --token "$token" 2>&1); then
    fail "semantic readiness accepted acknowledgement from an unbound executor home"
  fi
  assert_contains "$out" 'not from its bound executor home' \
    "semantic readiness did not authenticate the executor home"
  if out=$(run_session "$h1" retain one 2>&1); then
    fail "retention accepted a report before executor semantic readiness acknowledgement"
  fi
  assert_contains "$out" 'executor-authenticated semantic readiness acknowledgement' \
    "retention did not enforce executor semantic readiness acknowledgement"
  h2=$(make_ephemeral_home session-two)
  out=$(run_session "$h2" start two "$PROJECT" 'second topic' --harness claude)
  assert_contains "$out" 'started alignment session two project=project topic=second topic' \
    "second fresh alignment was not launched"
  assert_present "$PARENT/state/one.alignment" "first session record was not retained by the parent"
  assert_present "$PARENT/state/two.alignment" "coexisting session record was not retained by the parent"
  [ "$h1" != "$h2" ] || fail "coexisting sessions shared an ephemeral home"
  assert_grep 'Session: one' "$h1/data/charter.md" "first charter lost its session identity"
  assert_grep 'Session: two' "$h2/data/charter.md" "second charter lost its session identity"
  pass "alignment sessions are fresh, project-scoped, captain-facing, and coexist without persistent registration"
}

test_project_key_reservation_isolates_same_basename_projects() {
  local home key_one key_two
  make_same_basename_project
  home=$(make_ephemeral_home collision-project)
  run_session "$home" start collision "$COLLISION_PROJECT" 'collision topic' --harness claude >/dev/null
  key_one=$(grep '^project_key=' "$PARENT/state/one.alignment" | cut -d= -f2-)
  key_two=$(grep '^project_key=' "$PARENT/state/collision.alignment" | cut -d= -f2-)
  [ "$key_one" != "$key_two" ] || fail "same-basename projects reused one archive key"
  assert_contains "$key_two" 'project-' "colliding project did not receive a deterministic hashed archive key"
  write_report "$home" collision 'collision topic' 'None identified.' "$COLLISION_PROJECT"
  run_session "$home" retain collision >/dev/null
  run_session "$home" close collision >/dev/null || fail "teardown did not honor the reserved hashed project key"
  assert_absent "$PARENT/state/collision.meta" "collision session runtime metadata survived teardown"
  pass "same-basename project archives reserve and retain distinct deterministic keys"
}

test_failed_start_removes_owned_project_reservation() {
  local failed_project home out status
  failed_project="$TMP_ROOT/failed-reservation-project"
  mkdir -p "$failed_project"
  printf '# Failed reservation fixture\n' > "$failed_project/README.md"
  git -C "$failed_project" init -q
  git -C "$failed_project" add README.md
  git -C "$failed_project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  home=$(make_ephemeral_home failed-reservation)
  out=$(run_session "$home" start failed-reservation "$failed_project" 'failed topic' --harness unknown 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "invalid harness unexpectedly launched"
  assert_absent "$PARENT/data/alignments/failed-reservation-project/.project-path" \
    "failed start leaked its project-key reservation"
  pass "failed alignment starts remove their unused project reservation"
}

test_failed_launch_marks_runtime_abandoned_before_rollback() {
  local home fake_root out status
  home=$(make_ephemeral_home failed-launch)
  fake_root="$TMP_ROOT/failed-launch-root"
  mkdir -p "$fake_root/bin"
  cat > "$fake_root/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
set -u
id=$1
home=$2
cat > "$FM_STATE_OVERRIDE/$id.meta" <<EOF
kind=secondmate
alignment_session=1
home=$home
EOF
exit 1
SH
  cat > "$fake_root/bin/fm-teardown.sh" <<'SH'
#!/usr/bin/env bash
set -u
id=$1
grep '^alignment_abandon=1$' "$FM_STATE_OVERRIDE/$id.meta" > "$FM_ASSERT_ABANDON"
rm -f -- "$FM_STATE_OVERRIDE/$id.meta"
exit 0
SH
  chmod +x "$fake_root/bin/fm-spawn.sh" "$fake_root/bin/fm-teardown.sh"
  out=$(FM_ROOT_OVERRIDE="$fake_root" FM_HOME="$PARENT" \
    FM_DATA_OVERRIDE="$PARENT/data" FM_STATE_OVERRIDE="$PARENT/state" \
    FM_PROJECTS_OVERRIDE="$PARENT/projects" FM_CONFIG_OVERRIDE="$PARENT/config" \
    FM_FAKE_TREEHOUSE_HOME="$home" FM_FAKE_TMUX_LOG="$TMP_ROOT/runtime/tmux.log" \
    FM_ASSERT_ABANDON="$TMP_ROOT/abandon-proof" PATH="$FAKEBIN:$PATH" \
    "$SESSION" start failed-launch "$PROJECT" 'failed topic' --harness claude 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "failed launch unexpectedly succeeded"
  assert_present "$TMP_ROOT/abandon-proof" "failed launch did not mark runtime metadata abandoned"
  assert_absent "$home" "failed launch rollback left the ephemeral home leased"
  assert_absent "$PARENT/state/failed-launch.alignment" "failed launch left the parent session record"
  pass "failed alignment launches mark runtime abandonment before teardown rollback"
}

test_hashed_project_key_survives_failed_basename_start() {
  local project_a project_b home_a home_b home_b2 fake_root key_b key_b2 out status
  project_a="$TMP_ROOT/interleaving/a/project"
  project_b="$TMP_ROOT/interleaving/b/project"
  mkdir -p "$project_a" "$project_b"
  printf '# Interleaving project A\n' > "$project_a/README.md"
  printf '# Interleaving project B\n' > "$project_b/README.md"
  git -C "$project_a" init -q
  git -C "$project_a" add README.md
  git -C "$project_a" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git -C "$project_b" init -q
  git -C "$project_b" add README.md
  git -C "$project_b" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  home_a=$(make_ephemeral_home interleaving-a)
  home_b=$(make_ephemeral_home interleaving-b)
  fake_root="$TMP_ROOT/interleaving-fake-root"
  mkdir -p "$fake_root/bin"
  cat > "$fake_root/bin/fm-spawn.sh" <<EOF
#!/usr/bin/env bash
set -u
if [ "\${1:-}" = interleaved-a ]; then
  FM_ROOT_OVERRIDE="$ROOT_REAL" FM_HOME="$PARENT" \\
    FM_DATA_OVERRIDE="$PARENT/data" FM_STATE_OVERRIDE="$PARENT/state" \\
    FM_PROJECTS_OVERRIDE="$PARENT/projects" FM_CONFIG_OVERRIDE="$PARENT/config" \\
    FM_FAKE_TREEHOUSE_HOME="$home_b" FM_FAKE_TMUX_LOG="$TMP_ROOT/runtime/tmux.log" \\
    FM_SKIP_SECONDMATE_INHERIT=1 FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux \\
    PATH="$FAKEBIN:\$PATH" "$ROOT_REAL/bin/fm-alignment-session.sh" \\
    start interleaved-b "$project_b" 'hashed survivor' --harness claude >/dev/null
fi
exit 1
EOF
  chmod +x "$fake_root/bin/fm-spawn.sh"
  out=$(FM_ROOT_OVERRIDE="$fake_root" FM_HOME="$PARENT" \
    FM_DATA_OVERRIDE="$PARENT/data" FM_STATE_OVERRIDE="$PARENT/state" \
    FM_PROJECTS_OVERRIDE="$PARENT/projects" FM_CONFIG_OVERRIDE="$PARENT/config" \
    FM_FAKE_TREEHOUSE_HOME="$home_a" FM_FAKE_TMUX_LOG="$TMP_ROOT/runtime/tmux.log" \
    FM_SKIP_SECONDMATE_INHERIT=1 FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux \
    PATH="$FAKEBIN:$PATH" "$SESSION" start interleaved-a "$project_a" \
    'failed basename owner' --harness claude 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "basename-owner start unexpectedly succeeded"
  key_b=$(grep '^project_key=' "$PARENT/state/interleaved-b.alignment" | cut -d= -f2-)
  assert_contains "$key_b" 'project-' \
    "colliding project did not receive a hashed key during the failed-start interleaving"
  assert_grep "$project_b" "$PARENT/data/alignments/$key_b/.project-path" \
    "colliding project did not retain its hashed key reservation"
  assert_absent "$PARENT/state/interleaved-a.alignment" \
    "failed basename-owner start left its parent session record"
  assert_absent "$home_a" "failed basename-owner start left its ephemeral home"
  home_b2=$(make_ephemeral_home interleaving-b2)
  run_session "$home_b2" start interleaved-b2 "$project_b" 'hashed survivor again' --harness claude >/dev/null
  key_b2=$(grep '^project_key=' "$PARENT/state/interleaved-b2.alignment" | cut -d= -f2-)
  [ "$key_b2" = "$key_b" ] || fail "rediscovery forgot the already-reserved hashed project key"
  pass "hashed project archive keys survive failed basename-owner starts"
}

test_archive_selective_retrieval_supersession_and_promotion() {
  local h1 h2 out brief
  h1="$TMP_ROOT/session-one"
  h2="$TMP_ROOT/session-two"
  write_report "$h1" one 'first topic' 'Domain term candidate.'
  run_session "$h1" retain one >/dev/null
  printf 'changed after completed alignment\n' > "$PROJECT/completed-delta.txt"
  if out=$(run_session "$h1" reconcile one 2>&1); then
    fail "parent-only reconciliation refreshed a completed immutable alignment"
  fi
  assert_contains "$out" 'completed alignment one is immutable' \
    "completed alignment did not require a revised outcome after a later delta"
  rm -f "$PROJECT/completed-delta.txt"
  # A substituted archive identity must not authorize direct ephemeral cleanup.
  sed -i "s#^project_path=.*#project_path=$TMP_ROOT/foreign-project#" \
    "$PARENT/data/alignments/project/one/metadata"
  if out=$(FM_ROOT_OVERRIDE="$ROOT_REAL" FM_HOME="$PARENT" \
    FM_DATA_OVERRIDE="$PARENT/data" FM_STATE_OVERRIDE="$PARENT/state" \
    FM_CONFIG_OVERRIDE="$PARENT/config" FM_FAKE_TREEHOUSE_HOME="$h1" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$FAKEBIN:$PATH" \
    "$ROOT_REAL/bin/fm-teardown.sh" one 2>&1); then
    fail "direct cleanup accepted an archive with a foreign project identity"
  fi
  assert_contains "$out" 'valid parent-owned archive' \
    "archive identity refusal did not preserve teardown safety"
  sed -i "s#^project_path=.*#project_path=$PROJECT#" \
    "$PARENT/data/alignments/project/one/metadata"
  # A matching archive under a key unrelated to the project path must not authorize cleanup.
  mkdir -p "$PARENT/data/alignments/substituted"
  mv "$PARENT/data/alignments/project/one" "$PARENT/data/alignments/substituted/one"
  sed -i 's/^project_key=.*/project_key=substituted/' "$PARENT/state/one.alignment" "$PARENT/data/alignments/substituted/one/metadata"
  sed -i "s#^archive=.*#archive=$PARENT/data/alignments/substituted/one/report.md#" "$PARENT/state/one.alignment"
  if out=$(FM_ROOT_OVERRIDE="$ROOT_REAL" FM_HOME="$PARENT" \
    FM_DATA_OVERRIDE="$PARENT/data" FM_STATE_OVERRIDE="$PARENT/state" \
    FM_CONFIG_OVERRIDE="$PARENT/config" FM_FAKE_TREEHOUSE_HOME="$h1" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$FAKEBIN:$PATH" \
    "$ROOT_REAL/bin/fm-teardown.sh" one 2>&1); then
    fail "direct cleanup accepted an archive under a substituted project key"
  fi
  assert_contains "$out" 'valid parent-owned archive' \
    "project-key validation did not preserve teardown safety"
  mv "$PARENT/data/alignments/substituted/one" "$PARENT/data/alignments/project/one"
  sed -i 's/^project_key=.*/project_key=project/' "$PARENT/state/one.alignment" "$PARENT/data/alignments/project/one/metadata"
  sed -i "s#^archive=.*#archive=$PARENT/data/alignments/project/one/report.md#" "$PARENT/state/one.alignment"
  sed -i 's/^project_key=.*/project_key=substituted/' "$PARENT/state/one.alignment"
  if out=$(run_session "$h1" promote one --mode local-only --yolo off --purpose implementation 2>&1); then
    fail "promotion accepted a record with a substituted project key"
  fi
  assert_contains "$out" 'no valid parent-owned archive' \
    "promotion did not validate the deterministic project archive key"
  sed -i 's/^project_key=.*/project_key=project/' "$PARENT/state/one.alignment"
  sed -i "s#^alignment_project_path=.*#alignment_project_path=$TMP_ROOT/foreign-runtime-project#" "$PARENT/state/one.meta"
  if out=$(FM_ROOT_OVERRIDE="$ROOT_REAL" FM_HOME="$PARENT" \
    FM_DATA_OVERRIDE="$PARENT/data" FM_STATE_OVERRIDE="$PARENT/state" \
    FM_CONFIG_OVERRIDE="$PARENT/config" FM_FAKE_TREEHOUSE_HOME="$h1" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$FAKEBIN:$PATH" \
    "$ROOT_REAL/bin/fm-teardown.sh" one 2>&1); then
    fail "direct teardown accepted a tampered immutable alignment project binding"
  fi
  assert_contains "$out" 'valid parent-owned archive' \
    "direct teardown did not bind cleanup to immutable runtime project identity"
  sed -i "s#^alignment_project_path=.*#alignment_project_path=$PROJECT#" "$PARENT/state/one.meta"
  out=$(run_session "$h1" inventory "$PROJECT")
  assert_contains "$out" $'session=one\ttopic=first topic' \
    "inventory did not enumerate the retained project artifact"
  assert_not_contains "$out" 'Domain term candidate.' \
    "metadata inventory loaded a historical report body"
  out=$(FM_ROOT_OVERRIDE="$ROOT_REAL" FM_HOME="$h1" \
    FM_DATA_OVERRIDE="$h1/data" FM_STATE_OVERRIDE="$h1/state" \
    "$SESSION" retrieve "$PROJECT" one --archive-home "$PARENT")
  assert_contains "$out" 'Domain term candidate.' \
    "explicit parent-owned historical retrieval did not return the selected report"
  mkdir -p "$TMP_ROOT/custom-data"
  mv "$PARENT/data/alignments" "$TMP_ROOT/custom-data/alignments"
  out=$(FM_ROOT_OVERRIDE="$ROOT_REAL" FM_HOME="$h1" \
    FM_DATA_OVERRIDE="$h1/data" FM_STATE_OVERRIDE="$h1/state" \
    "$SESSION" retrieve "$PROJECT" one --archive-home "$PARENT" \
      --archive-data "$TMP_ROOT/custom-data")
  assert_contains "$out" 'Domain term candidate.' \
    "retrieval did not preserve the explicitly configured parent archive data root"
  out=$(FM_ROOT_OVERRIDE="$ROOT_REAL" FM_HOME="$PARENT" \
    FM_DATA_OVERRIDE="$TMP_ROOT/custom-data" FM_STATE_OVERRIDE="$PARENT/state" \
    FM_PROJECTS_OVERRIDE="$PARENT/projects" FM_CONFIG_OVERRIDE="$PARENT/config" \
    "$SESSION" inventory "$PROJECT")
  assert_contains "$out" "report=$TMP_ROOT/custom-data/alignments/project/one/report.md" \
    "inventory emitted a report pointer for the wrong archive data root"
  mv "$TMP_ROOT/custom-data/alignments" "$PARENT/data/alignments"
  assert_contains "$(cat "$h1/data/charter.md")" \
    "bin/fm-alignment-session.sh retrieve $PROJECT HISTORICAL_SESSION_ID --archive-home $PARENT" \
    "ephemeral charter did not provide the parent archive retrieval boundary"
  sed -i 's/^status=.*/status=running/' "$PARENT/data/alignments/project/one/metadata"
  if out=$(FM_ROOT_OVERRIDE="$ROOT_REAL" FM_HOME="$h1" \
    FM_DATA_OVERRIDE="$h1/data" FM_STATE_OVERRIDE="$h1/state" \
    "$SESSION" retrieve "$PROJECT" one --archive-home "$PARENT" 2>&1); then
    fail "retrieval accepted an incomplete archive"
  fi
  assert_contains "$out" 'is not completed' \
    "retrieval did not validate archive completion status"
  sed -i 's/^status=.*/status=completed/' "$PARENT/data/alignments/project/one/metadata"
  cp "$PARENT/data/alignments/project/one/report.md" "$TMP_ROOT/one-report.md"
  printf 'not an alignment report\n' > "$PARENT/data/alignments/project/one/report.md"
  if out=$(FM_ROOT_OVERRIDE="$ROOT_REAL" FM_HOME="$h1" \
    FM_DATA_OVERRIDE="$h1/data" FM_STATE_OVERRIDE="$h1/state" \
    "$SESSION" retrieve "$PROJECT" one --archive-home "$PARENT" 2>&1); then
    fail "retrieval accepted an invalid archive report"
  fi
  assert_contains "$out" 'has an invalid report' \
    "retrieval did not validate the retained report contract"
  if out=$(FM_ROOT_OVERRIDE="$ROOT_REAL" FM_HOME="$PARENT" \
    FM_DATA_OVERRIDE="$PARENT/data" FM_STATE_OVERRIDE="$PARENT/state" \
    FM_CONFIG_OVERRIDE="$PARENT/config" FM_FAKE_TREEHOUSE_HOME="$h1" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$FAKEBIN:$PATH" \
    "$ROOT_REAL/bin/fm-teardown.sh" one 2>&1); then
    fail "direct teardown deleted a session after retained-report corruption"
  fi
  assert_contains "$out" 'valid parent-owned archive' \
    "direct teardown did not bind cleanup to the retained report digest"
  assert_present "$h1" "direct teardown removed the source after retained-report corruption"
  mv "$TMP_ROOT/one-report.md" "$PARENT/data/alignments/project/one/report.md"

  h2=$(make_ephemeral_home session-two-promotion)
  run_session "$h2" start two-promotion "$PROJECT" 'second topic' --harness claude >/dev/null
  write_report "$h2" two-promotion 'second topic' 'Superseding domain decision.'
  run_session "$h2" retain two-promotion --supersedes one --outcome both >/dev/null
  # Simulate a crash after archive publication but before the parent record update.
  sed -i '/^outcome=/d; s/^status=.*/status=running/' "$PARENT/state/two-promotion.alignment"
  if out=$(run_session "$h2" reconcile two-promotion 2>&1); then
    fail "reconciliation reopened an already archived immutable outcome"
  fi
  assert_contains "$out" 'completed alignment two-promotion is immutable' \
    "archived immutable outcome did not require a revised session during recovery"
  run_session "$h2" retain two-promotion >/dev/null
  assert_grep 'outcome=both' "$PARENT/state/two-promotion.alignment" \
    "idempotent retain did not recover the archived downstream outcome"
  run_session "$h2" retain two-promotion --outcome knowledge-only >/dev/null
  assert_grep 'outcome=knowledge-only' "$PARENT/state/two-promotion.alignment" \
    "explicit idempotent retain did not update the session outcome"
  assert_grep 'outcome=knowledge-only' "$PARENT/data/alignments/project/two-promotion/metadata" \
    "explicit idempotent retain left archive outcome metadata stale"
  assert_present "$PARENT/data/alignments/project/one/report.md" \
    "superseded historical report was discarded"
  assert_present "$PARENT/data/alignments/project/two-promotion/report.md" \
    "new superseding report was not archived"
  assert_grep 'supersedes=one' "$PARENT/data/alignments/project/two-promotion/metadata" \
    "archive did not record explicit supersession"
  out=$(run_session "$h2" inventory "$PROJECT")
  assert_contains "$out" $'session=one\ttopic=first topic' "historical inventory lost the earlier report"
  assert_contains "$out" $'session=two-promotion\ttopic=second topic' "historical inventory lost the superseding report"

  cp "$PARENT/data/alignments/project/two-promotion/report.md" "$TMP_ROOT/two-promotion-report.md"
  printf 'corrupted retained report\n' > "$PARENT/data/alignments/project/two-promotion/report.md"
  if out=$(run_session "$h2" promote two-promotion --mode local-only --yolo off --purpose knowledge-only 2>&1); then
    fail "promotion accepted a corrupted retained report"
  fi
  assert_contains "$out" 'no valid parent-owned archive' \
    "promotion did not validate the retained report contract"
  mv "$TMP_ROOT/two-promotion-report.md" "$PARENT/data/alignments/project/two-promotion/report.md"
  if out=$(run_session "$h2" promote two-promotion --mode local-only --yolo off --purpose implementation 2>&1); then
    fail "promotion reinterpreted a knowledge-only alignment as implementation"
  fi
  assert_contains "$out" 'does not authorize implementation promotion' \
    "unauthorized implementation promotion did not explain the retained outcome"
  out=$(run_session "$h2" promote two-promotion --mode local-only --yolo off --purpose knowledge-only)
  assert_contains "$out" 'created ordinary project follow-up two-promotion-followup' \
    "knowledge promotion did not create an ordinary project follow-up"
  brief="$PARENT/data/two-promotion-followup/brief.md"
  assert_present "$brief" "promotion did not create a normal ship brief"
  assert_grep 'Alignment contract: complete' "$brief" "promotion dropped the alignment barrier outcome"
  assert_grep 'Alignment source: data/alignments/project/two-promotion/report.md' "$brief" \
    "promotion did not point at the parent archive"
  assert_grep 'promote durable-knowledge candidates through the normal project documentation delivery path' "$brief" \
    "promotion bypassed the normal project-write boundary"
  [ -z "$(git -C "$PROJECT" status --porcelain)" ] \
    || fail "alignment promotion wrote project documentation directly"
  printf 'changed after hydration\n' > "$PROJECT/stale-alignment-input.txt"
  if out=$(run_session "$h2" promote two-promotion --mode local-only --yolo off --purpose knowledge-only --task-id stale-followup 2>&1); then
    fail "promotion accepted a project changed after hydration"
  fi
  assert_contains "$out" 'start a revised session and explicitly supersede the immutable outcome' \
    "stale completed promotion did not require a revised outcome"
  rm -f "$PROJECT/stale-alignment-input.txt"
  sed -i 's/^outcome=.*/outcome=knowledge-only/; s/^status=.*/status=running/' \
    "$PARENT/state/two-promotion.alignment"
  printf 'retain_pending_outcome=both\n' >> "$PARENT/state/two-promotion.alignment"
  run_session "$h2" retain two-promotion >/dev/null
  assert_grep 'outcome=both' "$PARENT/state/two-promotion.alignment" \
    "idempotent retain did not recover its pending outcome"
  assert_grep 'outcome=both' "$PARENT/data/alignments/project/two-promotion/metadata" \
    "idempotent retain did not reconcile pending archive outcome"

  local h3="$TMP_ROOT/session-neither"
  h3=$(make_ephemeral_home session-neither)
  run_session "$h3" start neither "$PROJECT" 'neither outcome' --harness claude >/dev/null
  write_report "$h3" neither 'neither outcome'
  run_session "$h3" retain neither --outcome neither >/dev/null
  if out=$(run_session "$h3" promote neither --mode local-only --yolo off --purpose implementation 2>&1); then
    fail "promotion created work from a neither alignment"
  fi
  assert_contains "$out" 'does not authorize implementation promotion' \
    "neither outcome did not reject explicit promotion"
  pass "archive discovery is metadata-only, retrieval is selective, supersession preserves history, and promotion stays on the normal project path"
}

test_promotion_detects_content_changes_to_preexisting_dirty_knowledge() {
  local home out status original
  original="$TMP_ROOT/alignment-readme-before"
  cp "$PROJECT/README.md" "$original"
  printf '\npreexisting local knowledge change\n' >> "$PROJECT/README.md"
  home=$(make_ephemeral_home dirty-knowledge)
  run_session "$home" start dirty-knowledge "$PROJECT" 'dirty knowledge topic' --harness claude >/dev/null
  ack_preflight "$home" dirty-knowledge >/dev/null
  printf '\npost-hydration edit to the same dirty owner\n' >> "$PROJECT/README.md"
  write_report "$home" dirty-knowledge 'dirty knowledge topic'
  out=$(run_session "$home" retain dirty-knowledge 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "retention accepted a changed preexisting dirty canonical owner"
  assert_contains "$out" 'changed since reconciliation' \
    "retention did not require freshness reconciliation before archiving"
  run_session "$home" reconcile dirty-knowledge >/dev/null
  out=$(run_session "$home" retain dirty-knowledge 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "retention accepted a refreshed snapshot without executor acknowledgement"
  assert_contains "$out" 'executor-authenticated semantic readiness acknowledgement' \
    "retention did not require executor acknowledgement after reconciliation"
  ack_reconciliation "$home" dirty-knowledge >/dev/null
  assert_grep 'reconciliation_ack=acknowledged' "$PARENT/state/dirty-knowledge.alignment" \
    "executor reconciliation acknowledgement was not durably recorded"
  assert_not_contains "$(cat "$PARENT/state/dirty-knowledge.alignment")" 'reconciliation_pending=1' \
    "executor reconciliation acknowledgement left the pending marker active"
  run_session "$home" retain dirty-knowledge >/dev/null
  run_session "$home" promote dirty-knowledge --mode local-only --yolo off --purpose implementation >/dev/null
  cp "$original" "$PROJECT/README.md"
  pass "retention requires reconciliation for changed canonical knowledge"
}

test_archive_staging_recovers_atomically() {
  local home="$TMP_ROOT/session-staging"
  home=$(make_ephemeral_home session-staging)
  run_session "$home" start staged "$PROJECT" 'staged topic' --harness claude >/dev/null
  write_report "$home" staged 'staged topic'
  mkdir -p "$PARENT/data/alignments/project/.staged.tmp"
  cp "$home/data/staged/report.md" "$PARENT/data/alignments/project/.staged.tmp/report.md"
  cat > "$PARENT/data/alignments/project/.staged.tmp/metadata" <<EOF
schema=fm-alignment-archive.v1
project_name=project
project_path=$PROJECT
project_key=project
session_id=staged
topic=staged topic
source=local
status=completed
report=report.md
supersedes=
outcome=both
report_digest=$(sha256sum "$PARENT/data/alignments/project/.staged.tmp/report.md" | awk '{print $1}')
retained=2024-01-01T00:00:00Z
EOF
  out=$(run_session "$home" inventory "$PROJECT")
  assert_not_contains "$out" $'session=staged\t' \
    "inventory exposed an unpublished retention staging archive"
  run_session "$home" retain staged >/dev/null
  assert_present "$PARENT/data/alignments/project/staged/report.md" \
    "retention did not publish a recovered staged archive"
  assert_absent "$PARENT/data/alignments/project/.staged.tmp" \
    "retention left the recovered staging directory behind"
  assert_grep 'outcome=both' "$PARENT/state/staged.alignment" \
    "retention did not recover the staged outcome"
  pass "retention recovers complete staging and publishes it atomically"
}

test_archive_symlink_ancestors_are_rejected() {
  local data escape archive_home out status
  data="$TMP_ROOT/symlink-data"
  escape="$TMP_ROOT/archive-escape"
  archive_home="$TMP_ROOT/symlink-archive-home"
  mkdir -p "$data" "$escape" "$archive_home/data"
  ln -s "$escape" "$data/alignments"
  out=$(FM_ROOT_OVERRIDE="$ROOT_REAL" FM_HOME="$PARENT" \
    FM_DATA_OVERRIDE="$data" FM_STATE_OVERRIDE="$PARENT/state" \
    FM_PROJECTS_OVERRIDE="$PARENT/projects" FM_CONFIG_OVERRIDE="$PARENT/config" \
    "$SESSION" inventory "$PROJECT" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "inventory followed a symlinked archive ancestor"
  assert_contains "$out" 'must not contain a symlink' \
    "inventory did not explain the unsafe archive ancestor"
  ln -s "$escape" "$archive_home/data/alignments"
  out=$(FM_ROOT_OVERRIDE="$ROOT_REAL" FM_HOME="$PARENT" \
    FM_DATA_OVERRIDE="$PARENT/data" FM_STATE_OVERRIDE="$PARENT/state" \
    FM_PROJECTS_OVERRIDE="$PARENT/projects" FM_CONFIG_OVERRIDE="$PARENT/config" \
    "$SESSION" retrieve "$PROJECT" one --archive-home "$archive_home" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "retrieval followed a symlinked archive ancestor"
  assert_contains "$out" 'must not contain a symlink' \
    "retrieval did not reject the unsafe archive ancestor"
  pass "archive inventory and retrieval reject symlinked parent ancestors"
}

test_teardown_rejects_symlinked_data_root() {
  local data escape out status
  data="$PARENT/data"
  escape="$TMP_ROOT/teardown-data-escape"
  mkdir -p "$escape"
  mv "$data" "$escape/data"
  ln -s "$escape/data" "$data"
  out=$(FM_ROOT_OVERRIDE="$ROOT_REAL" FM_HOME="$PARENT" \
    FM_DATA_OVERRIDE="$data" FM_STATE_OVERRIDE="$PARENT/state" \
    FM_CONFIG_OVERRIDE="$PARENT/config" FM_FAKE_TREEHOUSE_HOME="$TMP_ROOT/session-one" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$FAKEBIN:$PATH" \
    "$ROOT_REAL/bin/fm-teardown.sh" one 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "direct cleanup followed a symlinked data root"
  assert_contains "$out" 'valid parent-owned archive' \
    "symlinked data root did not preserve teardown safety"
  rm "$data"
  mv "$escape/data" "$data"
  pass "direct teardown rejects a symlinked data root"
}

test_spawn_requires_parent_alignment_record() {
  local home out status
  home=$(make_ephemeral_home forged-alignment)
  printf '%s\n' forged > "$home/.fm-secondmate-home"
  out=$(FM_ROOT_OVERRIDE="$ROOT_REAL" FM_HOME="$PARENT" \
    FM_DATA_OVERRIDE="$PARENT/data" FM_STATE_OVERRIDE="$PARENT/state" \
    FM_CONFIG_OVERRIDE="$PARENT/config" FM_FAKE_TREEHOUSE_HOME="$home" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$FAKEBIN:$PATH" \
    "$ROOT_REAL/bin/fm-spawn.sh" forged "$home" --secondmate --alignment-session \
      --harness claude 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "alignment spawn without a parent record was accepted"
  assert_contains "$out" 'requires a parent-created alignment record' \
    "missing parent alignment record did not explain the spawn refusal"
  cat > "$PARENT/state/forged.alignment" <<EOF
schema=fm-alignment-session.v1
session_id=forged
project_name=project
project_path=$PROJECT
project_key=../escape
topic=forged topic
home=$home
status=starting
source=local
EOF
  out=$(FM_ROOT_OVERRIDE="$ROOT_REAL" FM_HOME="$PARENT" \
    FM_DATA_OVERRIDE="$PARENT/data" FM_STATE_OVERRIDE="$PARENT/state" \
    FM_CONFIG_OVERRIDE="$PARENT/config" FM_FAKE_TREEHOUSE_HOME="$home" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$FAKEBIN:$PATH" \
    "$ROOT_REAL/bin/fm-spawn.sh" forged "$home" --secondmate --alignment-session \
      --harness claude 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "alignment spawn with a traversal project key was accepted"
  assert_contains "$out" 'project key is malformed or unsafe' \
    "unsafe project key did not explain the spawn refusal"
  rm -f "$PARENT/state/forged.alignment"
  pass "alignment spawning requires a bound parent record and safe project identity"
}

test_nested_project_context_is_bounded_and_tracks_repo_relative_prose() {
  local repo project home out
  repo="$TMP_ROOT/nested-repository"
  project="$repo/services/app"
  printf '# Host instructions\nFIRSTMATE GLOBAL SECRET\n' > "$TMP_ROOT/AGENTS.md"
  mkdir -p "$project/docs" "$project/specs"
  printf '# Root instructions\ncontext-owner: services/app/docs/root-domain.md\n' > "$repo/AGENTS.md"
  mkdir -p "$repo/services"
  printf '# Intermediate instructions\n' > "$repo/services/AGENTS.md"
  printf '# App instructions\ncontext-owner: docs/local-domain.md\n' > "$project/AGENTS.md"
  printf '# Root scoped domain owner\n' > "$project/docs/root-domain.md"
  printf '# App scoped domain owner\n' > "$project/docs/local-domain.md"
  printf '# Tracked specification\n' > "$project/specs/api.md"
  mkdir -p "$project/domains/billing"
  printf '# Billing owner\n' > "$project/domains/billing/domain.md"
  printf 'domain.md\n' > "$project/domains/billing/owner-pointer"
  git -C "$repo" init -q
  git -C "$repo" add AGENTS.md services
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'nested project fixture'
  home=$(make_ephemeral_home nested-project)
  out=$(run_session "$home" start nested-owners "$project" 'nested owner topic' --harness claude)
  assert_contains "$out" 'launch=acknowledged readiness=pending' \
    "nested project alignment did not separate launch delivery from semantic readiness"
  assert_grep 'Intermediate instructions' "$home/data/alignment-context.md" \
    "nested project omitted an intermediate AGENTS instruction"
  assert_not_contains "$(cat "$home/data/alignment-context.md")" 'FIRSTMATE GLOBAL SECRET' \
    "nested project imported an AGENTS file from an unrelated ancestor"
  assert_grep $'selected\tdocs/local-domain.md\t' "$home/data/alignment-context.md" \
    "nested project did not preserve its local scoped owner"
  assert_grep $'selected\tdocs/root-domain.md\t' "$home/data/alignment-context.md" \
    "nested project did not preserve its repository-scoped owner"
  assert_grep $'candidate\tspecs/api.md\t' "$home/data/alignment-context.md" \
    "nested project did not resolve tracked prose relative to the repository root"
  assert_grep $'selected\tdomains/billing/domain.md\t' "$home/data/alignment-context.md" \
    "nested project omitted a deeper scoped owner declaration"
  rm -f "$TMP_ROOT/AGENTS.md"
  pass "nested alignment hydration is repository-bounded and preserves scoped owners"
}

test_scoped_owners_and_explicit_contract_conflicts() {
  local home ambiguous
  printf '# Context owner\n' > "$PROJECT/docs/context-owner.md"
  printf '# Pointer owner\n' > "$PROJECT/docs/pointer-owner.md"
  printf 'docs/context-owner.md\n' > "$PROJECT/context-owner"
  printf 'docs/pointer-owner.md\n' > "$PROJECT/owner-pointer"
  home=$(make_ephemeral_home owner-scopes)
  run_session "$home" start owner-scopes "$PROJECT" 'owner scopes' --harness claude >/dev/null
  assert_grep $'selected\tdocs/domain.md\t' "$home/data/alignment-context.md" \
    "AGENTS owner was not preserved as a current owner"
  assert_grep $'selected\tdocs/context-owner.md\t' "$home/data/alignment-context.md" \
    "legitimate context owner was incorrectly discarded by declaration precedence"
  assert_grep $'selected\tdocs/pointer-owner.md\t' "$home/data/alignment-context.md" \
    "legitimate pointer owner was incorrectly discarded by declaration precedence"

  printf 'contract=shared docs/context-owner.md\n' > "$PROJECT/context-owner"
  printf 'contract=shared docs/pointer-owner.md\n' > "$PROJECT/owner-pointer"
  ambiguous=$(make_ephemeral_home owner-ambiguity)
  run_session "$ambiguous" start owner-ambiguity "$PROJECT" 'owner ambiguity' --harness claude >/dev/null
  assert_grep $'conflict\tdocs/context-owner.md\t' "$ambiguous/data/alignment-context.md" \
    "explicit same-contract context ambiguity was not surfaced"
  assert_grep $'conflict\tdocs/pointer-owner.md\t' "$ambiguous/data/alignment-context.md" \
    "explicit same-contract pointer ambiguity was not surfaced"
  rm -f "$PROJECT/context-owner" "$PROJECT/owner-pointer" \
    "$PROJECT/docs/context-owner.md" "$PROJECT/docs/pointer-owner.md"
  pass "alignment preserves scoped owners and only surfaces explicit same-contract conflicts"
}

test_teardown_requires_retention_and_abandon_is_explicit() {
  local h1 h3 h4 h5 out status
  h1="$TMP_ROOT/session-one"
  h3=$(make_ephemeral_home session-three)
  run_session "$h1" close one >/dev/null || fail "retained session could not be closed"
  assert_absent "$PARENT/state/one.meta" "closed session retained live runtime metadata"
  assert_present "$PARENT/data/alignments/project/one/report.md" \
    "closing a session removed the parent-owned historical archive"

  h5=$(make_ephemeral_home incomplete-abandon)
  run_session "$h5" start incomplete "$PROJECT" 'incomplete topic' --harness claude >/dev/null
  printf 'changed after incomplete alignment launch\n' > "$PROJECT/stale-incomplete-input.txt"
  printf '# Incomplete alignment evidence\n\nA useful unresolved observation.\n' > "$h5/data/incomplete/report.md"
  out=$(run_session "$h5" close incomplete --abandon 2>&1)
  assert_contains "$out" 'retained abandoned alignment evidence' \
    "abandonment did not retain incomplete alignment evidence"
  assert_absent "$h5" "abandoned alignment cleanup left the ephemeral home"
  assert_grep 'status=abandoned' "$PARENT/data/alignments/project/incomplete/metadata" \
    "abandoned alignment archive did not record its non-promotable status"
  assert_grep 'report_digest=' "$PARENT/data/alignments/project/incomplete/metadata" \
    "abandoned alignment archive did not bind its evidence digest"
  out=$(run_session "$h5" inventory "$PROJECT")
  assert_contains "$out" $'session=incomplete\ttopic=incomplete topic\tstatus=abandoned' \
    "abandoned alignment evidence was not discoverable"
  out=$(run_session "$h5" retrieve "$PROJECT" incomplete)
  assert_contains "$out" 'A useful unresolved observation.' \
    "abandoned alignment evidence could not be explicitly retrieved"
  rm -f "$PROJECT/stale-incomplete-input.txt"
  out=$(run_session "$h5" promote incomplete --mode local-only --yolo off --purpose implementation 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "abandoned alignment evidence authorized implementation"
  assert_contains "$out" 'must be retained before promotion' \
    "abandoned alignment promotion refusal did not preserve the non-promotable boundary"

  rm -rf "$h3"
  h3=$(make_ephemeral_home session-three)
  run_session "$h3" start three "$PROJECT" 'abandoned topic' --harness claude >/dev/null
  write_report "$h3" three 'abandoned topic'
  out=$(run_session "$h3" close three --abandon 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a complete unretained report was discarded by abandonment"
  assert_contains "$out" 'complete report that must be retained' "complete-report retention refusal did not explain teardown safety"
  out=$(FM_ROOT_OVERRIDE="$ROOT_REAL" FM_HOME="$PARENT" \
    FM_DATA_OVERRIDE="$PARENT/data" FM_STATE_OVERRIDE="$PARENT/state" \
    FM_CONFIG_OVERRIDE="$PARENT/config" FM_FAKE_TREEHOUSE_HOME="$h3" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$FAKEBIN:$PATH" \
    "$ROOT_REAL/bin/fm-teardown.sh" three 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "direct cleanup discarded an unretained alignment report"
  assert_contains "$out" 'has no retained report' "direct cleanup did not enforce the parent archive boundary"
  out=$(FM_ROOT_OVERRIDE="$ROOT_REAL" FM_HOME="$PARENT" \
    FM_DATA_OVERRIDE="$PARENT/data" FM_STATE_OVERRIDE="$PARENT/state" \
    FM_CONFIG_OVERRIDE="$PARENT/config" FM_FAKE_TREEHOUSE_HOME="$h3" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$FAKEBIN:$PATH" \
    "$ROOT_REAL/bin/fm-teardown.sh" three --force 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "forced cleanup discarded an unretained alignment report"
  assert_contains "$out" 'has no retained report' "forced cleanup bypassed the parent archive boundary"
  out=$(run_session "$h3" close three 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "unretained session close succeeded without explicit abandonment"
  assert_contains "$out" 'no retained report' "retention refusal did not explain teardown safety"
  assert_present "$PARENT/state/three.meta" "unsafe close removed the live session metadata"

  h4=$(make_ephemeral_home session-four)
  run_session "$h4" start four "$PROJECT" 'missing owner record' --harness claude >/dev/null
  printf 'alignment_abandon=1\n' >> "$PARENT/state/four.meta"
  rm -f "$PARENT/state/four.alignment"
  out=$(FM_ROOT_OVERRIDE="$ROOT_REAL" FM_HOME="$PARENT" \
    FM_DATA_OVERRIDE="$PARENT/data" FM_STATE_OVERRIDE="$PARENT/state" \
    FM_CONFIG_OVERRIDE="$PARENT/config" FM_FAKE_TREEHOUSE_HOME="$h4" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$FAKEBIN:$PATH" \
    "$ROOT_REAL/bin/fm-teardown.sh" four --force 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "direct abandonment cleanup proceeded without a parent session record"
  assert_contains "$out" 'valid parent session record' \
    "missing parent session record did not preserve abandonment safety"
  assert_present "$h4" "missing parent session record allowed leased-home deletion"

  rm -f "$h3/data/three/report.md"
  out=$(run_session "$h3" close three --abandon 2>&1)
  assert_contains "$out" 'closed alignment session three' "explicit abandoned close did not complete"
  assert_absent "$PARENT/state/three.meta" "abandoned close left a live runtime metadata record"
  assert_absent "$h3" "abandoned close did not remove the ephemeral home"
  pass "cleanup refuses unretained completed work and only closes an unarchived session with explicit abandonment"
}

make_parent_and_project
test_fresh_isolated_sessions_and_parent_archive
test_project_key_reservation_isolates_same_basename_projects
test_failed_start_removes_owned_project_reservation
test_hashed_project_key_survives_failed_basename_start
test_failed_launch_marks_runtime_abandoned_before_rollback
test_archive_selective_retrieval_supersession_and_promotion
test_promotion_detects_content_changes_to_preexisting_dirty_knowledge
test_archive_staging_recovers_atomically
test_archive_symlink_ancestors_are_rejected
test_teardown_rejects_symlinked_data_root
test_spawn_requires_parent_alignment_record
test_teardown_requires_retention_and_abandon_is_explicit
test_nested_project_context_is_bounded_and_tracks_repo_relative_prose
test_scoped_owners_and_explicit_contract_conflicts
echo '# all fm-alignment-session tests passed'
