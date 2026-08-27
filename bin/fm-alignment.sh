#!/usr/bin/env bash
# Check the pre-implementation alignment contract carried by a brief, validate
# a durable local alignment report, or complete a direct local Secondmate
# alignment by notifying its parent without inventing a request correlation.
#
# Usage:
#   fm-alignment.sh check <brief> [--investigation|--promotion]
#   fm-alignment.sh validate-report <report> [--complete] [--session <id>] [--project <name>]
#   fm-alignment.sh start [<alignment-id>]
#   fm-alignment.sh complete-direct <alignment-id> [<note...>]
#
# A brief may omit the contract for compatibility with older tasks. Such a
# brief is accepted by ordinary implementation checks, while new scaffolds use
# `unclassified`: scouts may investigate in that state, but implementation and
# promotion require an explicit `bypassed` or `complete` decision. `required`
# refuses implementation, and `complete` requires a source and complete outcome.
# A complete outcome is the implementation contract copied from a local report
# or external handoff; this command never interprets its settled decisions.
#
# Alignment reports use the headings Goal, Relevant facts, Settled decisions,
# Acceptance criteria, Out of scope, Engineering discretion, and Remaining open
# decisions. `--complete` additionally requires the exact normalized sentinel
# `None - no material open decisions remain.` in the last section.
#
# `start` and `complete-direct` remain compatible with reports in already-seeded
# persistent Secondmate homes. New local sessions are managed by
# fm-alignment-session.sh, which adds project/session identity and a separate
# durable-knowledge-candidates section before the parent archives the report.
# `complete-direct` validates that report, resolves the locally seeded parent
# from .fm-secondmate-parent and .fm-secondmate-home, and appends a keyed,
# uncorrelated document pointer to the parent's status stream. Parent-routed
# marked requests continue to use fm-secondmate-report.sh with corr=<id>.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  local status=${1:-2}
  if [ "$status" -eq 0 ]; then
    sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
  else
    sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//' >&2
  fi
  exit "$status"
}

case "${1:-}" in
  -h|--help) usage 0 ;;
esac

fail() {
  printf 'alignment: %s\n' "$*" >&2
  exit 1
}

[ "$#" -ge 1 ] || usage
COMMAND=$1
shift
FILE=
case "$COMMAND" in
  check|validate-report)
    [ "$#" -ge 1 ] || usage
    FILE=$1
    shift
    [ -f "$FILE" ] && [ ! -L "$FILE" ] || fail "expected an ordinary file: $FILE"
    ;;
  start|complete-direct) ;;
  *) usage ;;
esac

alignment_content() {
  local file=$1 from_marker=${2:-0}
  if [ "$from_marker" -eq 1 ]; then
    awk '
      /^# Alignment outcome[[:space:]]*$/ { found=1; next }
      found { print }
      END { if (!found) exit 1 }
    ' "$file"
  else
    cat "$file"
  fi
}

section_body() {
  local content=$1 heading=$2
  printf '%s\n' "$content" | awk -v heading="## $heading" '
    $0 == heading { inside=1; next }
    inside && /^#{1,2}[[:space:]]/ { exit }
    inside && $0 !~ /^[[:space:]]*$/ { print }
  '
}

validate_sections() {
  local file=$1 from_marker=${2:-0} content heading body
  content=$(alignment_content "$file" "$from_marker" 2>/dev/null) || {
    [ "$from_marker" -eq 1 ] && fail "$file is missing the '# Alignment outcome' section"
    fail "could not read report content from $file"
  }
  for heading in \
    'Goal' \
    'Relevant facts' \
    'Settled decisions' \
    'Acceptance criteria' \
    'Out of scope' \
    'Engineering discretion' \
    'Remaining open decisions'; do
    if [ "$(printf '%s\n' "$content" | grep -c -E "^## ${heading}[[:space:]]*$" || true)" != 1 ]; then
      fail "$file must contain exactly one '## $heading' section"
    fi
    body=$(section_body "$content" "$heading")
    [ -n "$body" ] || fail "$file has an empty '## $heading' section"
  done
  printf '%s\n' "$content"
}

remaining_is_clear() {
  local content=$1 remaining first normalized count
  remaining=$(section_body "$content" 'Remaining open decisions')
  first=$(printf '%s\n' "$remaining" | awk 'NF { print; exit }')
  count=$(printf '%s\n' "$remaining" | awk 'NF { count++ } END { print count + 0 }')
  [ "$count" = 1 ] || return 1
  normalized=$(printf '%s\n' "$first" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ "$normalized" = 'None - no material open decisions remain.' ]
}

validate_session_report() {
  local file=$1 session_id=$2 project_name=$3 content heading body
  content=$(validate_sections "$file")
  for heading in 'Project identity' 'Alignment identity' 'Durable-knowledge candidates'; do
    if [ "$(printf '%s\n' "$content" | grep -c -E "^## ${heading}[[:space:]]*$" || true)" != 1 ]; then
      fail "$file must contain exactly one '## $heading' section for an on-demand session"
    fi
    body=$(section_body "$content" "$heading")
    [ -n "$body" ] || fail "$file has an empty '## $heading' section"
  done
  grep -Fqx "Name: $project_name" "$file" \
    || fail "$file does not identify project $project_name"
  grep -Fqx "Session: $session_id" "$file" \
    || fail "$file does not identify session $session_id"
  remaining_is_clear "$content" \
    || fail "$file still has material open decisions in '## Remaining open decisions'"
}

check_brief() {
  local brief=$1 mode=${2:-implementation} count contract content
  count=$(grep -c '^Alignment contract:' "$brief" 2>/dev/null || true)
  if [ "$count" = 0 ]; then
    if [ "$mode" = promotion ]; then
      fail "$brief has no explicit alignment classification; classify it as bypassed or complete before promotion"
    fi
    # Pre-contract briefs are deliberately left compatible with ordinary
    # implementation and investigation. New scaffolds carry unclassified.
    return 0
  fi
  [ "$count" = 1 ] || fail "$brief must contain exactly one 'Alignment contract:' line"
  contract=$(sed -n 's/^Alignment contract:[[:space:]]*//p' "$brief")
  case "$contract" in
    unclassified)
      [ "$mode" = investigation ] && return 0
      fail "$brief has unclassified alignment; explicitly choose bypassed or complete before implementation" ;;
    bypassed) return 0 ;;
    required) fail "implementation is waiting for pre-implementation alignment" ;;
    complete)
      count=$(grep -c '^Alignment source:[[:space:]]*[^[:space:]].*$' "$brief" 2>/dev/null || true)
      [ "$count" = 1 ] || fail "$brief must contain one non-empty 'Alignment source:' line"
      content=$(validate_sections "$brief" 1)
      remaining_is_clear "$content" \
        || fail "$brief still has material open decisions in '## Remaining open decisions'"
      return 0
      ;;
    '') fail "$brief has an empty 'Alignment contract:' value" ;;
    *) fail "$brief has unknown alignment contract '$contract' (use unclassified, bypassed, required, or complete)" ;;
  esac
}

alignment_id_valid() {
  local id=${1-}
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#id}" -le 64 ]
}

alignment_home() {
  [ -n "${FM_HOME:-}" ] || fail "FM_HOME is required for local Secondmate alignment"
  case "$FM_HOME" in /*) ;; *) fail "FM_HOME must be an absolute Secondmate home" ;; esac
  [ -d "$FM_HOME" ] || fail "FM_HOME is not a directory: $FM_HOME"
  [ ! -L "$FM_HOME" ] || fail "FM_HOME must not be a symlink: $FM_HOME"
}

new_alignment_id() {
  local base candidate suffix=0
  base="alignment-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  candidate=$base
  while [ -e "$FM_HOME/data/$candidate" ] || [ -L "$FM_HOME/data/$candidate" ]; do
    suffix=$((suffix + 1))
    candidate="$base-$suffix"
  done
  printf '%s\n' "$candidate"
}

start_alignment() {
  local id=${1:-} dir report tmp
  [ "$#" -le 1 ] || usage
  alignment_home
  [ -d "$FM_HOME/data" ] && [ ! -L "$FM_HOME/data" ] \
    || fail "Secondmate data directory is missing or unsafe: $FM_HOME/data"
  if [ -z "$id" ]; then
    id=$(new_alignment_id)
  fi
  alignment_id_valid "$id" || fail "invalid alignment id: $id"
  dir="$FM_HOME/data/$id"
  [ ! -L "$dir" ] || fail "alignment directory must not be a symlink: $dir"
  [ ! -e "$dir" ] || fail "alignment already exists: $dir"
  mkdir "$dir"
  report="$dir/report.md"
  tmp="$dir/.report.md.$$"
  cat > "$tmp" <<'EOF'
# Pre-implementation alignment

## Goal

Describe the desired outcome.

## Relevant facts

Record repository and environment facts that affect the outcome.

## Settled decisions

Record decisions actually settled with the captain.

## Acceptance criteria

Record the behavior that implementation must satisfy.

## Out of scope

Record excluded behavior and work.

## Engineering discretion

Record implementation choices left to the worker.

## Remaining open decisions

List material choices still owned by the captain.
EOF
  mv "$tmp" "$report"
  printf 'started alignment %s: %s\n' "$id" "$report"
}

complete_direct_alignment() {
  local id=${1:-} report content mate_id parent_home parent_status note session_project
  [ "$#" -ge 1 ] || usage
  alignment_home
  alignment_id_valid "$id" || fail "invalid alignment id: $id"
  report="$FM_HOME/data/$id/report.md"
  [ -f "$report" ] && [ ! -L "$report" ] \
    || fail "alignment report is missing or unsafe: $report"
  content=$(validate_sections "$report")
  if [ -f "$FM_HOME/data/$id/session.meta" ] && [ ! -L "$FM_HOME/data/$id/session.meta" ]; then
    session_project=$(sed -n 's/^project_name=//p' "$FM_HOME/data/$id/session.meta" | tail -1)
    [ -n "$session_project" ] || fail "alignment session metadata has no project name"
    validate_session_report "$report" "$id" "$session_project"
  else
    remaining_is_clear "$content" \
      || fail "$report still has material open decisions in '## Remaining open decisions'"
  fi

  # A direct captain conversation is a local Secondmate-only route. The seeded
  # identity and parent binding are the durable proof of which parent receives
  # this uncorrelated notification; no request correlation is fabricated.
  [ -f "$FM_HOME/.fm-secondmate-home" ] \
    && [ ! -L "$FM_HOME/.fm-secondmate-home" ] \
    || fail "direct alignment requires a seeded Secondmate identity marker"
  IFS= read -r mate_id < "$FM_HOME/.fm-secondmate-home" || true
  alignment_id_valid "$mate_id" || fail "Secondmate identity marker contains an invalid id"
  # shellcheck source=bin/fm-secondmate-parent-lib.sh
  . "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"
  fm_secondmate_parent_record_parse "$FM_HOME/.fm-secondmate-parent" \
    || fail "direct alignment requires a valid local Secondmate parent binding"
  [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] \
    || fail "direct alignment requires a local Secondmate parent route"
  parent_home=$FM_SECONDMATE_PARENT_HOME
  [ -d "$parent_home" ] && [ ! -L "$parent_home" ] \
    || fail "Secondmate parent home is missing or unsafe: $parent_home"
  parent_status="$parent_home/state/$mate_id.status"
  [ ! -L "$parent_status" ] || fail "parent status path must not be a symlink: $parent_status"
  note=${*:2}
  [ -n "$note" ] || note="alignment $id is implementation-ready"
  "$SCRIPT_DIR/fm-secondmate-report.sh" --direct-doc \
    "$parent_status" 'done' "$id" "data/$id/report.md" "$note"
}

case "$COMMAND" in
  check)
    check_mode=implementation
    if [ "$#" -gt 0 ]; then
      [ "$#" = 1 ] || usage
      case "$1" in
        --investigation) check_mode=investigation ;;
        --promotion) check_mode=promotion ;;
        *) usage ;;
      esac
    fi
    check_brief "$FILE" "$check_mode"
    ;;
  validate-report)
    complete=0
    session_id=
    project_name=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --complete) complete=1; shift ;;
        --session) [ "$#" -ge 2 ] || usage; session_id=$2; shift 2 ;;
        --project) [ "$#" -ge 2 ] || usage; project_name=$2; shift 2 ;;
        *) usage ;;
      esac
    done
    if [ -n "$session_id" ] || [ -n "$project_name" ]; then
      [ -n "$session_id" ] && [ -n "$project_name" ] || usage
      alignment_id_valid "$session_id" || fail "invalid alignment session id: $session_id"
      validate_session_report "$FILE" "$session_id" "$project_name"
    else
      content=$(validate_sections "$FILE")
      if [ "$complete" -eq 1 ]; then
        remaining_is_clear "$content" \
          || fail "$FILE still has material open decisions in '## Remaining open decisions'"
      fi
    fi
    printf 'valid\n'
    ;;
  start)
    start_alignment "$@"
    ;;
  complete-direct)
    complete_direct_alignment "$@"
    ;;
  *) usage ;;
esac
