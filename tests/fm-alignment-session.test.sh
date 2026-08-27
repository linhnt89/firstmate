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
  printf '# Project operating knowledge\n' > "$PROJECT/AGENTS.md"
  git -C "$PROJECT" init -q
  git -C "$PROJECT" add README.md AGENTS.md
  git -C "$PROJECT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  printf 'claude configured-model high\n' > "$PARENT/config/alignment-harness"
  FAKEBIN=$(make_runtime "$TMP_ROOT/runtime")
}

make_ephemeral_home() {
  local home="$TMP_ROOT/$1"
  git clone --quiet "$ROOT_REAL" "$home"
  printf '%s\n' "$home"
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

write_report() {
  local home=$1 id=$2 topic=$3 candidate=${4:-None identified.}
  cat > "$home/data/$id/report.md" <<EOF
# Pre-implementation alignment

## Project identity
Name: project
Path: $PROJECT

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
  assert_grep 'Canonical project terminology.' "$home/data/alignment-context.md" \
    "session did not hydrate current canonical project knowledge"
  assert_grep 'Historical alignment inventory' "$home/data/alignment-context.md" \
    "session did not include the compact historical inventory"
}

test_fresh_isolated_sessions_and_parent_archive() {
  local h1 h2 out
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

test_archive_selective_retrieval_supersession_and_promotion() {
  local h1 h2 out brief
  h1="$TMP_ROOT/session-one"
  h2="$TMP_ROOT/session-two"
  write_report "$h1" one 'first topic' 'Domain term candidate.'
  run_session "$h1" retain one >/dev/null
  out=$(run_session "$h1" inventory "$PROJECT")
  assert_contains "$out" $'session=one\ttopic=first topic' \
    "inventory did not enumerate the retained project artifact"
  assert_not_contains "$out" 'Domain term candidate.' \
    "metadata inventory loaded a historical report body"
  out=$(run_session "$h1" retrieve "$PROJECT" one)
  assert_contains "$out" 'Domain term candidate.' \
    "explicit historical retrieval did not return the selected report"

  write_report "$h2" two 'second topic' 'Superseding domain decision.'
  run_session "$h2" retain two --supersedes one --outcome both >/dev/null
  assert_present "$PARENT/data/alignments/project/one/report.md" \
    "superseded historical report was discarded"
  assert_present "$PARENT/data/alignments/project/two/report.md" \
    "new superseding report was not archived"
  assert_grep 'supersedes=one' "$PARENT/data/alignments/project/two/metadata" \
    "archive did not record explicit supersession"
  out=$(run_session "$h2" inventory "$PROJECT")
  assert_contains "$out" $'session=one\ttopic=first topic' "historical inventory lost the earlier report"
  assert_contains "$out" $'session=two\ttopic=second topic' "historical inventory lost the superseding report"

  out=$(run_session "$h2" promote two --mode local-only --yolo off --purpose both)
  assert_contains "$out" 'created ordinary project follow-up two-followup' \
    "knowledge promotion did not create an ordinary project follow-up"
  brief="$PARENT/data/two-followup/brief.md"
  assert_present "$brief" "promotion did not create a normal ship brief"
  assert_grep 'Alignment contract: complete' "$brief" "promotion dropped the alignment barrier outcome"
  assert_grep 'Alignment source: data/alignments/project/two/report.md' "$brief" \
    "promotion did not point at the parent archive"
  assert_grep 'promote durable-knowledge candidates through the normal project documentation delivery path' "$brief" \
    "promotion bypassed the normal project-write boundary"
  [ -z "$(git -C "$PROJECT" status --porcelain)" ] \
    || fail "alignment promotion wrote project documentation directly"
  pass "archive discovery is metadata-only, retrieval is selective, supersession preserves history, and promotion stays on the normal project path"
}

test_teardown_requires_retention_and_abandon_is_explicit() {
  local h1 h3 out status
  h1="$TMP_ROOT/session-one"
  h3=$(make_ephemeral_home session-three)
  run_session "$h1" close one >/dev/null || fail "retained session could not be closed"
  assert_absent "$PARENT/state/one.meta" "closed session retained live runtime metadata"
  assert_present "$PARENT/data/alignments/project/one/report.md" \
    "closing a session removed the parent-owned historical archive"

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
  rm -f "$h3/data/three/report.md"
  out=$(run_session "$h3" close three --abandon 2>&1)
  assert_contains "$out" 'closed alignment session three' "explicit abandoned close did not complete"
  assert_absent "$PARENT/state/three.meta" "abandoned close left a live runtime metadata record"
  assert_absent "$h3" "abandoned close did not remove the ephemeral home"
  pass "cleanup refuses unretained completed work and only closes an unarchived session with explicit abandonment"
}

make_parent_and_project
test_fresh_isolated_sessions_and_parent_archive
test_archive_selective_retrieval_supersession_and_promotion
test_teardown_requires_retention_and_abandon_is_explicit
echo '# all fm-alignment-session tests passed'
