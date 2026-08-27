#!/usr/bin/env bash
# Behavior tests for the explicit per-task delivery contract (AGENTS.md section 7)
# across bin/fm-spawn.sh, bin/fm-promote.sh, and bin/fm-project-mode.sh.
#
# A ship task's delivery mode and yolo posture are firstmate's decision at intake,
# so the tools refuse to guess: the spawn and a scout promotion require both flags,
# validate them against a closed set, and the spawn additionally refuses to launch
# when the brief it is about to hand the worker records a different mode. Scout
# spawns carry no delivery posture at all. The registry keeps only the captain's
# standing posture, for the mechanical consumers and for one advisory notice.
#
# Every spawn case here stops before any endpoint exists: the delivery checks run
# ahead of backend creation, and a fake `tmux` that exits non-zero backstops the
# cases that are meant to get past them, so no window or worktree is ever created.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
PROJECT_MODE="$ROOT/bin/fm-project-mode.sh"
ALIGNMENT="$ROOT/bin/fm-alignment.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-delivery)

# A home with one registered project, one project directory, and a fake tmux that
# refuses, so a spawn that clears the delivery checks still creates nothing.
# Echoes "<home>|<project-dir>|<fakebin>".
make_home() {  # <name> [<registry-line>...]
  local name=$1 home projects fakebin
  shift
  home="$TMP_ROOT/$name/home"
  projects="$TMP_ROOT/$name/projects"
  fakebin="$TMP_ROOT/$name/bin"
  mkdir -p "$home/data" "$home/state" "$home/config" "$projects/proj" "$fakebin"
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" > "$home/data/projects.md"
  fi
  printf '%s\n' "$home|$projects/proj|$fakebin"
}

write_brief() {  # <home> <id> [<recorded-mode>]
  local home=$1 id=$2 mode=${3:-}
  mkdir -p "$home/data/$id"
  {
    printf 'You are a crewmate.\n\n# Definition of done\n'
    [ -z "$mode" ] || printf 'Delivery contract: mode=%s\n' "$mode"
  } > "$home/data/$id/brief.md"
}

run_spawn() {  # <home> <fakebin> <spawn-args...>
  local home=$1 fakebin=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects-unused" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# A ship spawn must stop when its delivery contract was never decided or cannot be
# a task mode, and must leave no task metadata behind when it does.
test_ship_spawn_requires_a_valid_delivery_contract() {
  local rec home proj fakebin label flags expect out status n=0
  rec=$(make_home required)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  while IFS='|' read -r label flags expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    write_brief "$home" "delivery-required-$n" no-mistakes
    # shellcheck disable=SC2086  # flags is an intentional word-split arg list
    out=$(run_spawn "$home" "$fakebin" "delivery-required-$n" "$proj" claude $flags)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain the contract"
    assert_absent "$home/state/delivery-required-$n.meta" "$label: refused spawn wrote task metadata"
  done <<'ROWS'
missing both flags||ship spawns require --mode
missing --yolo|--mode no-mistakes|ship spawns require --yolo
missing --mode|--yolo off|ship spawns require --mode
unknown mode|--mode nope --yolo off|must be one of no-mistakes, direct-PR, local-only
unknown yolo|--mode no-mistakes --yolo maybe|--yolo must be on or off
conditional policy as a task mode|--mode no-mistakes-prod-only --yolo off|classify this task's surface
ROWS
  pass "fm-spawn: a ship spawn requires a valid explicit mode and yolo before anything is created"
}

# A scout has no merge to govern and a secondmate's posture is fixed, so the flags
# are refused rather than accepted and quietly ignored.
test_scout_and_secondmate_refuse_delivery_flags() {
  local rec home proj fakebin out status
  rec=$(make_home refused)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-scout-a1

  out=$(run_spawn "$home" "$fakebin" delivery-scout-a1 "$proj" claude --scout --mode direct-PR)
  status=$?
  [ "$status" -ne 0 ] || fail "a scout spawn carrying --mode should exit non-zero"
  assert_contains "$out" "--mode applies only to ship spawns" "scout spawn did not refuse --mode"

  out=$(run_spawn "$home" "$fakebin" delivery-scout-a1 "$proj" claude --scout --yolo on)
  status=$?
  [ "$status" -ne 0 ] || fail "a scout spawn carrying --yolo should exit non-zero"
  assert_contains "$out" "--yolo applies only to ship spawns" "scout spawn did not refuse --yolo"

  out=$(run_spawn "$home" "$fakebin" delivery-sm-a2 "$home" --secondmate --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a secondmate spawn carrying delivery flags should exit non-zero"
  assert_contains "$out" "applies only to ship spawns" "secondmate spawn did not refuse the delivery flags"
  pass "fm-spawn: scout and secondmate spawns refuse ship delivery flags"
}

# The brief is what the worker actually follows, so a spawn whose explicit mode
# disagrees with the brief's recorded contract must refuse instead of launching a
# worker whose instructions contradict the recorded task delivery.
test_spawn_refuses_a_brief_mode_mismatch() {
  local rec home proj fakebin out status
  rec=$(make_home agreement)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-mismatch-b1 no-mistakes
  out=$(run_spawn "$home" "$fakebin" delivery-mismatch-b1 "$proj" claude --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a brief/spawn mode mismatch should exit non-zero"
  assert_contains "$out" "delivery mismatch for delivery-mismatch-b1" "mismatch refusal did not name the task"
  assert_contains "$out" "the brief says mode=no-mistakes but this spawn passed --mode direct-PR" \
    "mismatch refusal did not show both sides of the disagreement"
  assert_absent "$home/state/delivery-mismatch-b1.meta" "mismatched spawn wrote task metadata"

  # The agreeing case clears the check and only fails later, at the refusing tmux.
  write_brief "$home" delivery-agree-b2 direct-PR
  out=$(run_spawn "$home" "$fakebin" delivery-agree-b2 "$proj" claude --mode direct-PR --yolo off)
  assert_not_contains "$out" "delivery mismatch" "an agreeing mode was reported as a mismatch"

  # A brief scaffolded before the contract line existed warns once and continues.
  write_brief "$home" delivery-legacy-b3
  out=$(run_spawn "$home" "$fakebin" delivery-legacy-b3 "$proj" claude --mode local-only --yolo off)
  assert_contains "$out" "records no delivery contract line" "a legacy brief did not warn about its missing contract"
  assert_not_contains "$out" "delivery mismatch" "a legacy brief was treated as a mismatch"
  pass "fm-spawn: the brief's recorded mode and the spawn's explicit mode must agree"
}

# The registry is the captain's standing posture, so dropping below its rigor is
# allowed but never silent, while matching or exceeding it stays quiet. An
# unregistered project resolves to the same no-mistakes standing default
# (AGENTS.md section 7), so a downgrade there is announced too. A conditional
# policy is excluded because both of its legs are legitimate classifications.
test_spawn_notices_a_rigor_downgrade_against_the_registry() {
  local rec home proj fakebin out label mode registry expect registered n=0
  while IFS='|' read -r label registry mode expect registered; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    rec=$(make_home "deviation-$n" "$registry")
    IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
    write_brief "$home" "delivery-dev-$n" "$mode"
    out=$(run_spawn "$home" "$fakebin" "delivery-dev-$n" "$proj" claude --mode "$mode" --yolo off)
    case "$expect" in
      notice)
        assert_contains "$out" "less rigor than the captain's standing posture" \
          "$label: no deviation notice for a rigor downgrade"
        assert_contains "$out" "the standing posture for proj is $registered" \
          "$label: notice did not name the standing posture it compared against" ;;
      quiet)
        assert_not_contains "$out" "less rigor than the captain's standing posture" \
          "$label: printed a deviation notice that is not a downgrade" ;;
    esac
  done <<'ROWS'
no-mistakes project shipped direct-PR|- proj [no-mistakes] - fixture (added 2026-01-01)|direct-PR|notice|no-mistakes
no-mistakes project shipped local-only|- proj [no-mistakes] - fixture (added 2026-01-01)|local-only|notice|no-mistakes
no-mistakes project shipped no-mistakes|- proj [no-mistakes] - fixture (added 2026-01-01)|no-mistakes|quiet|no-mistakes
local-only project shipped no-mistakes|- proj [local-only] - fixture (added 2026-01-01)|no-mistakes|quiet|local-only
conditional policy shipped direct-PR|- proj [no-mistakes-prod-only] - fixture (added 2026-01-01)|direct-PR|quiet|no-mistakes-prod-only
unregistered project resolves to the no-mistakes standing default|- other [no-mistakes] - fixture (added 2026-01-01)|direct-PR|notice|no-mistakes
ROWS
  pass "fm-spawn: a rigor downgrade against the registered posture is announced, never blocked"
}

# A scout's deliverable is a report, so it records no delivery posture at all;
# teardown already treats an absent mode as the most protective one.
test_scout_records_no_delivery_posture() {
  local rec home proj fakebin out
  rec=$(make_home scout-meta "- proj [direct-PR] - fixture (added 2026-01-01)")
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-scoutmeta-c1
  out=$(run_spawn "$home" "$fakebin" delivery-scoutmeta-c1 "$proj" claude --scout)
  assert_not_contains "$out" "less rigor" "a scout spawn consulted the registered delivery posture"
  assert_not_contains "$out" "delivery mismatch" "a scout spawn checked a delivery contract it does not carry"
  pass "fm-spawn: a scout spawn resolves no delivery posture from the registry"
}

write_alignment_report() {
  local path=$1 remaining=${2:-None - no material open decisions remain.}
  cat > "$path" <<EOF
# Pre-implementation alignment

## Goal
Deliver the agreed outcome.

## Relevant facts
The repository provides the existing mechanism.

## Settled decisions
Use the existing implementation path.

## Acceptance criteria
The behavior is covered by executable tests.

## Out of scope
Unrelated workflow changes.

## Engineering discretion
The worker chooses routine implementation details.

## Remaining open decisions
$remaining
EOF
}

test_alignment_report_and_spawn_barrier() {
  local rec home proj fakebin report brief out status
  rec=$(make_home alignment)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  report="$home/alignment-report.md"
  write_alignment_report "$report" '- Choose between the existing and replacement contract.'
  out=$($ALIGNMENT validate-report "$report")
  [ "$out" = valid ] || fail "an in-progress alignment report should validate structurally"
  out=$($ALIGNMENT validate-report "$report" --complete 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a report with an open material decision passed the complete check"
  assert_contains "$out" "material open decisions" "incomplete alignment report did not name its remaining decisions"

  brief="$home/data/alignment-required/brief.md"
  mkdir -p "$(dirname "$brief")"
  cat > "$brief" <<'EOF'
# Definition of done
Delivery contract: mode=no-mistakes
Alignment contract: required
EOF
  out=$(run_spawn "$home" "$fakebin" alignment-required "$proj" claude --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a required alignment contract reached backend creation"
  assert_contains "$out" "alignment barrier refused" "required alignment refusal did not identify the barrier"
  assert_absent "$home/state/alignment-required.meta" "required alignment refusal published task metadata"

  brief="$home/data/alignment-bypassed/brief.md"
  mkdir -p "$(dirname "$brief")"
  cat > "$brief" <<'EOF'
# Definition of done
Delivery contract: mode=no-mistakes
Alignment contract: bypassed
EOF
  out=$(run_spawn "$home" "$fakebin" alignment-bypassed "$proj" claude --mode no-mistakes --yolo off 2>&1)
  assert_not_contains "$out" "alignment barrier refused" "bypassed alignment contract was treated as blocked"

  brief="$home/data/alignment-complete/brief.md"
  mkdir -p "$(dirname "$brief")"
  cat > "$brief" <<'EOF'
# Definition of done
Delivery contract: mode=no-mistakes
Alignment contract: complete
Alignment source: data/alignment-report.md

# Alignment outcome

## Goal
Deliver the agreed outcome.

## Relevant facts
The repository provides the existing mechanism.

## Settled decisions
Use the existing implementation path.

## Acceptance criteria
The behavior is covered by executable tests.

## Out of scope
Unrelated workflow changes.

## Engineering discretion
The worker chooses routine implementation details.

## Remaining open decisions
None - no material open decisions remain.
EOF
  "$ALIGNMENT" check "$brief" || fail "a complete alignment brief with no open decisions was rejected"
  out=$(run_spawn "$home" "$fakebin" alignment-complete "$proj" claude --mode no-mistakes --yolo off 2>&1)
  assert_not_contains "$out" "alignment barrier refused" "complete alignment contract was treated as blocked"
  pass "fm-alignment: reports distinguish open decisions and the spawn barrier preserves bypass and completion paths"
}

test_alignment_parses_generated_briefs_and_requires_exact_sentinel() {
  local rec home proj fakebin brief outcome out status
  rec=$(make_home generated-alignment)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" generated-brief-a1 proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "generated ship brief should scaffold"
  brief="$home/data/generated-brief-a1/brief.md"
  outcome="$home/generated-outcome.md"
  write_alignment_report "$outcome"
  awk 'NR == 1 { print "# Alignment outcome"; next } { print }' "$outcome" > "$outcome.tmp"
  mv "$outcome.tmp" "$outcome"
  FM_GENERATED_OUTCOME="$outcome" awk '
    /^Alignment contract: unclassified$/ {
      print "Alignment contract: complete"
      print "Alignment source: generated-outcome.md"
      next
    }
    /^# Setup$/ && !inserted {
      while ((getline line < ENVIRON["FM_GENERATED_OUTCOME"]) > 0) print line
      close(ENVIRON["FM_GENERATED_OUTCOME"])
      inserted=1
    }
    { print }
  ' "$brief" > "$brief.tmp"
  mv "$brief.tmp" "$brief"
  "$ALIGNMENT" check "$brief" || fail "a completed real generated ship brief was rejected"

  sed 's/^None - no material open decisions remain\.$/None except the storage contract remains undecided./' \
    "$brief" > "$brief.tmp"
  mv "$brief.tmp" "$brief"
  out=$($ALIGNMENT check "$brief" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a misleading None-prefix sentinel passed the alignment barrier"
  assert_contains "$out" "material open decisions" \
    "misleading completion sentinel did not report the remaining decision"

  sed 's/^None except the storage contract remains undecided\.$/No material open decisions remain, except storage./' \
    "$brief" > "$brief.tmp"
  mv "$brief.tmp" "$brief"
  out=$($ALIGNMENT check "$brief" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a misleading No-material-prefix sentinel passed the alignment barrier"
  pass "fm-alignment: real generated briefs parse to the next top-level heading and require an exact sentinel"
}

test_unclassified_ship_and_scout_barriers() {
  local rec home proj fakebin brief out status
  rec=$(make_home unclassified-barrier)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" unclassified-ship-a1 proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "ship scaffold for the unclassified barrier should succeed"
  brief="$home/data/unclassified-ship-a1/brief.md"
  out=$(run_spawn "$home" "$fakebin" unclassified-ship-a1 "$proj" claude --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "an unclassified ship was allowed to spawn"
  assert_contains "$out" "alignment barrier refused" "unclassified ship refusal did not identify the alignment barrier"
  assert_absent "$home/state/unclassified-ship-a1.meta" "unclassified ship refusal published task metadata"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" unclassified-scout-a2 proj --scout >/dev/null 2>&1 \
    || fail "scout scaffold for the unclassified barrier should succeed"
  brief="$home/data/unclassified-scout-a2/brief.md"
  "$ALIGNMENT" check "$brief" --investigation \
    || fail "an unclassified scout was not allowed to investigate"
  out=$(run_spawn "$home" "$fakebin" unclassified-scout-a2 "$proj" claude --scout 2>&1)
  assert_not_contains "$out" "alignment barrier refused" \
    "unclassified scout investigation was treated as an implementation refusal"
  pass "fm-alignment: new ships require classification while scouts may investigate unclassified"
}

test_direct_secondmate_alignment_completion() {
  local parent second id report out status
  parent="$TMP_ROOT/direct-alignment-parent"
  second="$TMP_ROOT/direct-alignment-secondmate"
  id=direct-alignment-a1
  mkdir -p "$parent/state" "$second/data" "$second/state"
  printf '%s\n' direct-mate > "$second/.fm-secondmate-home"
  cat > "$second/.fm-secondmate-parent" <<EOF
schema=fm-secondmate-parent.v1
route=local
parent_home=$parent
EOF
  out=$(FM_HOME="$second" "$ALIGNMENT" start "$id" 2>&1) || fail "direct alignment start failed: $out"
  report="$second/data/$id/report.md"
  assert_present "$report" "direct alignment start did not allocate the local report"
  write_alignment_report "$report"
  out=$(FM_HOME="$second" "$ALIGNMENT" complete-direct "$id" "captain alignment settled" 2>&1)
  status=$?
  expect_code 0 "$status" "direct alignment completion should notify the parent"
  assert_grep 'done [key=alignment-direct-alignment-a1]: captain alignment settled (data/direct-alignment-a1/report.md via-helper)' \
    "$parent/state/direct-mate.status" "direct alignment did not write the keyed parent document pointer"
  assert_no_grep 'corr=' "$parent/state/direct-mate.status" \
    "direct alignment fabricated a parent correlation token"

  # The marked parent-routed route remains correlated and uses the same helper.
  FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-secondmate-report.sh" --doc \
    "$parent/state/direct-mate.status" done 0123456789abcdef data/direct-alignment-a1/report.md \
    "marked alignment" || fail "correlated parent report route stopped working"
  assert_grep 'done [corr=0123456789abcdef]' "$parent/state/direct-mate.status" \
    "marked alignment did not preserve its correlation"
  pass "fm-alignment: direct captain alignment uses a local report and uncorrelated keyed parent notification"
}

# Promotion is where a scout's ship contract is finally decided, so it requires the
# same explicit values and writes them into the task's durable record.
test_promote_requires_and_records_the_delivery_contract() {
  local home meta out status
  home="$TMP_ROOT/promote/home"
  mkdir -p "$home/state"
  meta="$home/state/promote-d1.meta"

  write_scout_meta() {
    printf 'window=fm-promote-d1\nkind=scout\nworktree=/tmp/wt\n' > "$meta"
  }

  write_scout_meta
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion without --mode should exit non-zero"
  assert_contains "$out" "promotion requires --mode" "promote refusal did not name the missing mode"
  assert_grep 'kind=scout' "$meta" "refused promotion still changed the task record"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode direct-PR 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion without --yolo should exit non-zero"
  assert_contains "$out" "promotion requires --yolo" "promote refusal did not name the missing merge posture"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode no-mistakes-prod-only --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion on a conditional policy should exit non-zero"
  assert_contains "$out" "classify this task's surface" "promote did not refuse the conditional policy as a task mode"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode direct-PR --yolo on 2>&1)
  status=$?
  expect_code 0 "$status" "a promotion carrying both flags should succeed"
  assert_grep 'kind=ship' "$meta" "promotion did not restore ship teardown protection"
  assert_grep 'mode=direct-PR' "$meta" "promotion did not record the decided delivery mode"
  assert_grep 'yolo=on' "$meta" "promotion did not record the decided merge posture"
  assert_contains "$out" "ship instructions for mode=direct-PR" "promotion hint did not carry the decided mode"
  [ "$(grep -c '^mode=' "$meta")" = 1 ] || fail "promotion left more than one mode= line in the task record"
  pass "fm-promote: promotion requires the delivery contract and records it exactly once"
}

test_promote_refuses_unclassified_alignment() {
  local rec home proj fakebin meta out status brief
  rec=$(make_home promote-unclassified)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  meta="$home/state/promote-unclassified.meta"
  printf 'window=fm-promote-unclassified\nkind=scout\nworktree=/tmp/wt\n' > "$meta"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" promote-unclassified proj --scout >/dev/null 2>&1 \
    || fail "scout scaffold for promotion classification should succeed"
  brief="$home/data/promote-unclassified/brief.md"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-unclassified \
    --mode direct-PR --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "unclassified scout promotion should be refused"
  assert_contains "$out" "alignment barrier refused promotion" \
    "unclassified promotion refusal did not identify the alignment barrier"
  assert_grep 'kind=scout' "$meta" "unclassified refusal changed the scout kind"
  pass "fm-promote: unclassified scouts cannot be promoted without an explicit classification"
}

test_promote_refuses_material_alignment() {
  local rec home proj fakebin meta out status brief
  rec=$(make_home promote-alignment)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  meta="$home/state/promote-alignment.meta"
  printf 'window=fm-promote-alignment\nkind=scout\nworktree=/tmp/wt\n' > "$meta"
  brief="$home/data/promote-alignment/brief.md"
  mkdir -p "$(dirname "$brief")"
  cat > "$brief" <<'EOF'
# Definition of done
Alignment contract: required
EOF
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-alignment \
    --mode direct-PR --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "scout promotion with required alignment should be refused"
  assert_contains "$out" "alignment barrier refused promotion" \
    "promotion refusal did not identify the alignment barrier"
  assert_grep 'kind=scout' "$meta" "refused aligned promotion changed the scout kind"
  pass "fm-promote: material alignment remains a barrier before scout implementation promotion"
}

# The registry parser survives for the mechanical consumers only. It accepts the
# conditional policy, maps it to its most rigorous leg for them, and exposes the
# raw annotation for the one caller that must tell a policy from a flat mode.
test_project_mode_maps_the_conditional_policy() {
  local home out err
  home="$TMP_ROOT/project-mode/home"
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- prodproj [no-mistakes-prod-only] - fixture (added 2026-01-01)
- yoloproj [no-mistakes-prod-only +yolo] - fixture (added 2026-01-01)
- flatproj [direct-PR] - fixture (added 2026-01-01)
- typoproj [no-mistakez] - fixture (added 2026-01-01)
EOF
  out=$(FM_HOME="$home" "$PROJECT_MODE" prodproj 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "conditional policy did not map to its most rigorous leg (got '$out')"
  err=$(FM_HOME="$home" "$PROJECT_MODE" prodproj 2>&1 >/dev/null)
  [ -z "$err" ] || fail "a registered conditional policy still warned as unknown: $err"

  out=$(FM_HOME="$home" "$PROJECT_MODE" yoloproj 2>/dev/null)
  [ "$out" = "no-mistakes on" ] || fail "conditional policy dropped its +yolo posture (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" --raw prodproj 2>/dev/null)
  [ "$out" = "no-mistakes-prod-only off" ] || fail "--raw did not expose the registered annotation (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" --raw flatproj 2>/dev/null)
  [ "$out" = "direct-PR off" ] || fail "--raw altered a flat registered mode (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" typoproj 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "a typo'd mode no longer falls back to the most rigorous default"
  err=$(FM_HOME="$home" "$PROJECT_MODE" typoproj 2>&1 >/dev/null)
  assert_contains "$err" "unknown mode" "a typo'd registry mode stopped warning"
  pass "fm-project-mode: the conditional policy is accepted, mapped for mechanical callers, and readable raw"
}

test_alignment_report_and_spawn_barrier
test_alignment_parses_generated_briefs_and_requires_exact_sentinel
test_unclassified_ship_and_scout_barriers
test_direct_secondmate_alignment_completion
test_ship_spawn_requires_a_valid_delivery_contract
test_scout_and_secondmate_refuse_delivery_flags
test_spawn_refuses_a_brief_mode_mismatch
test_spawn_notices_a_rigor_downgrade_against_the_registry
test_scout_records_no_delivery_posture
test_promote_requires_and_records_the_delivery_contract
test_promote_refuses_unclassified_alignment
test_promote_refuses_material_alignment
test_project_mode_maps_the_conditional_policy
echo "# all fm-task-delivery tests passed"
