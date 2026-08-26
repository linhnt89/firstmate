#!/usr/bin/env bash
# tests/fm-control-herdr-smoke.test.sh - real-herdr smoke test for the agent
# lifecycle control plane (bin/fm-control.sh).
#
# tmux is the control plane's reference backend and is covered hermetically in
# tests/fm-control.test.sh. herdr is the OTHER backend whose recovery-grade
# agent-state classifier the control plane is allowed to trust, so its
# behavior is pinned here against the REAL binary rather than a stub: whether
# an agent is running, and therefore whether a lifecycle verb may act at all,
# comes from herdr's own agent registry.
#
# No real agent is launched. herdr's `pane report-agent` is the same registry
# the adapter reads, so registering and not registering an agent on a plain
# shell pane exercises the stale-registration boundary; a real shell-owned
# helper additionally proves lifecycle control refuses unattributed activity.
#
# Always runs on a private, named, throwaway lab session, never the default
# one (tests/herdr-test-safety.sh; the 2026-07-02 incident). Skips cleanly
# when herdr or jq is missing.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION="fm-lab-control-smoke-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=
cleanup_all() {
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  herdr_safe_stop_and_delete "$SESSION"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-control-herdr.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)
HOME_DIR="$SCRATCH/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/hsmoke"
printf '# brief\n' > "$HOME_DIR/data/hsmoke/brief.md"

# A real git worktree so the control plane's checkpoint has a real local copy.
PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b hsmoke "$WT"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-hsmoke" "$WT" "$SEEDED_TAB_ID") \
  || fail "create_task failed"
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
[ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] || fail "create_task did not return tab/pane ids"

{
  echo "window=$SESSION:$PANE_ID"
  echo "endpoint_task_id=hsmoke"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
} > "$HOME_DIR/state/hsmoke.meta"

# A second exact task pane exercises interpreter arguments without disturbing
# the first pane's stale-shell and shell-owned-helper lifecycle cases.
PY_TASK_ID=hsmoke-arg
PY_SCRATCH_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-$PY_TASK_ID" "$WT") \
  || fail "create_task failed for the argument-path regression pane"
read -r PY_TAB_ID PY_PANE_ID <<EOF
$PY_SCRATCH_IDS
EOF
[ -n "$PY_TAB_ID" ] && [ -n "$PY_PANE_ID" ] \
  || fail "argument-path create_task did not return tab/pane ids"
{
  echo "window=$SESSION:$PY_PANE_ID"
  echo "endpoint_task_id=$PY_TASK_ID"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$PY_TAB_ID"
  echo "herdr_pane_id=$PY_PANE_ID"
} > "$HOME_DIR/state/$PY_TASK_ID.meta"

run_control() {
  env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" \
    FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=2 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

# --- no registered agent: the endpoint exists but hosts no agent ------------

OUT=$(run_control hsmoke exit) || fail "exit against an agent-free herdr pane should be idempotent success: $OUT"
case "$OUT" in
  "already-stopped hsmoke"*) : ;;
  *) fail "an agent-free herdr pane should report already-stopped, got: $OUT" ;;
esac
pass "real herdr: exit on a pane with no registered agent is idempotent success"

if OUT=$(run_control hsmoke interrupt 2>&1); then
  fail "interrupt should refuse when herdr reports no agent on the pane: $OUT"
fi
case "$OUT" in
  *"nothing to interrupt"*) : ;;
  *) fail "the interrupt refusal should say there is no agent, got: $OUT" ;;
esac
pass "real herdr: interrupt refuses when herdr's own agent registry reports no agent"

# --- stale registration on a surviving shell: recovery classification --------

herdr pane report-agent "$PANE_ID" --source fm-control-smoke --agent fm-control-smoke-agent \
  --state idle --session "$SESSION" >/dev/null 2>&1 \
  || fail "could not register the stale-agent simulation on the task pane"

STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = dead ] || fail "herdr should classify a registered bare shell as dead after process reconciliation, got '$STATE'"
pass "real herdr: stale registration does not override the exact lone-idle-shell proof"

if OUT=$(run_control hsmoke interrupt 2>&1); then
  fail "interrupt should refuse after the registered agent is proven gone: $OUT"
fi
case "$OUT" in
  *"nothing to interrupt"*) : ;;
  *) fail "the interrupt refusal should name the already-stopped agent, got: $OUT" ;;
esac
pass "real herdr: lifecycle control refuses to send agent input to the surviving shell"

OUT=$(run_control hsmoke exit) || fail "exit on the proven stale shell should be idempotent success: $OUT"
case "$OUT" in
  "already-stopped hsmoke"*) : ;;
  *) fail "stale-shell exit should report already-stopped, got: $OUT" ;;
esac

herdr pane get "$PANE_ID" --session "$SESSION" >/dev/null 2>&1 \
  || fail "the control plane must never remove the endpoint it was operating on"
[ -d "$WT" ] || fail "the control plane must never remove the task's local copy"
pass "real herdr: stale-shell lifecycle recovery preserves the exact endpoint and local copy"

# A registered pane whose shell owns a background helper is not a positively
# attributed agent. Lifecycle control must refuse before sending interrupt or
# exit input, and the exact pane must remain available for later reconciliation.
fm_backend_herdr_send_literal "$SESSION:$PANE_ID" 'sleep 30 &' \
  || fail "could not stage a shell-owned helper"
fm_backend_herdr_send_key "$SESSION:$PANE_ID" Enter \
  || fail "could not submit the shell-owned helper"
sleep 0.3
STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = unreadable ] || fail "shell-owned helper activity must be unreadable, got '$STATE'"
pass "real herdr: shell-owned helper activity is not promoted to a live agent"

if OUT=$(run_control hsmoke interrupt 2>&1); then
  fail "interrupt should refuse for unattributed helper activity: $OUT"
fi
case "$OUT" in
  *"rather than a positively classified state"*) : ;;
  *) fail "the interrupt refusal should identify unattributed activity, got: $OUT" ;;
esac
if OUT=$(run_control hsmoke exit 2>&1); then
  fail "exit should refuse for unattributed helper activity: $OUT"
fi
case "$OUT" in
  *"rather than a positively classified state"*) : ;;
  *) fail "the exit refusal should identify unattributed activity, got: $OUT" ;;
esac
herdr pane get "$PANE_ID" --session "$SESSION" >/dev/null 2>&1 \
  || fail "lifecycle refusal must preserve the exact endpoint"
pass "real herdr: lifecycle control sends no input to an ambiguous shell-owned helper"

# A Python/Node-like interpreter with arbitrary /tmp/claude and /tmp/codex
# arguments must remain unattributed. The stale registration must not authorize
# lifecycle input into that process either.
herdr pane report-agent "$PY_PANE_ID" --source fm-control-smoke --agent fm-control-smoke-arg-agent \
  --state idle --session "$SESSION" >/dev/null 2>&1 \
  || fail "could not register the argument-path stale-agent simulation"
fm_backend_herdr_send_text_line "$SESSION:$PY_PANE_ID" \
  "python3 -c 'import time; time.sleep(30)' /tmp/claude/input.py /tmp/codex/data" \
  || fail "could not stage the arbitrary argument-path interpreter"
sleep 0.3
STATE=$(fm_backend_agent_state herdr "$SESSION:$PY_PANE_ID")
[ "$STATE" = unreadable ] || fail "arbitrary interpreter argument paths must stay unreadable, got '$STATE'"
pass "real herdr: arbitrary interpreter argument paths do not create positive attribution"

if OUT=$(run_control "$PY_TASK_ID" interrupt 2>&1); then
  fail "interrupt should refuse for arbitrary interpreter argument paths: $OUT"
fi
case "$OUT" in
  *"rather than a positively classified state"*) : ;;
  *) fail "the interpreter argument-path interrupt refusal was unclear, got: $OUT" ;;
esac
if OUT=$(run_control "$PY_TASK_ID" exit 2>&1); then
  fail "exit should refuse for arbitrary interpreter argument paths: $OUT"
fi
case "$OUT" in
  *"rather than a positively classified state"*) : ;;
  *) fail "the interpreter argument-path exit refusal was unclear, got: $OUT" ;;
esac
herdr pane get "$PY_PANE_ID" --session "$SESSION" >/dev/null 2>&1 \
  || fail "argument-path lifecycle refusal must preserve the exact endpoint"
pass "real herdr: lifecycle control sends no input to arbitrary interpreter argument paths"

fm_backend_herdr_kill "$SESSION:$PY_PANE_ID" 2>/dev/null || true
fm_backend_herdr_kill "$SESSION:$PANE_ID" 2>/dev/null || true
