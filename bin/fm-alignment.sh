#!/usr/bin/env bash
# Check the pre-implementation alignment contract carried by a ship brief, or
# validate the durable report produced by an alignment executor.
#
# Usage:
#   fm-alignment.sh check <brief>
#   fm-alignment.sh validate-report <report> [--complete]
#
# A brief may omit the contract for compatibility with older tasks.  Such a
# brief is accepted unchanged, while `bypassed` accepts a clear mechanical task,
# `required` refuses implementation, and `complete` requires a source and a
# complete alignment outcome.  A complete outcome is the implementation
# contract copied from a local report or external handoff; this command never
# interprets its settled decisions.
#
# Alignment reports use the headings Goal, Relevant facts, Settled decisions,
# Acceptance criteria, Out of scope, Engineering discretion, and Remaining open
# decisions.  `--complete` additionally requires the last section to say that
# no material open decisions remain.
set -eu

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

[ "$#" -ge 2 ] || usage
COMMAND=$1
FILE=$2
shift 2

[ -f "$FILE" ] && [ ! -L "$FILE" ] || fail "expected an ordinary file: $FILE"

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
    inside && /^## / { exit }
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
  local content=$1 remaining first count
  remaining=$(section_body "$content" 'Remaining open decisions')
  first=$(printf '%s\n' "$remaining" | awk 'NF { print; exit }')
  count=$(printf '%s\n' "$remaining" | awk 'NF { count++ } END { print count + 0 }')
  [ "$count" = 1 ] || return 1
  case "$first" in
    None*|'No material open decisions remain'*) return 0 ;;
  esac
  return 1
}

check_brief() {
  local brief=$1 count contract content
  count=$(grep -c '^Alignment contract:' "$brief" 2>/dev/null || true)
  if [ "$count" = 0 ]; then
    # Pre-contract briefs are deliberately left compatible with ordinary
    # delegation. New scaffolds carry an explicit bypassed line.
    return 0
  fi
  [ "$count" = 1 ] || fail "$brief must contain exactly one 'Alignment contract:' line"
  contract=$(sed -n 's/^Alignment contract:[[:space:]]*//p' "$brief")
  case "$contract" in
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
    *) fail "$brief has unknown alignment contract '$contract' (use bypassed, required, or complete)" ;;
  esac
}

case "$COMMAND" in
  check)
    [ "$#" = 0 ] || usage
    check_brief "$FILE"
    ;;
  validate-report)
    complete=0
    if [ "$#" -gt 0 ]; then
      [ "$#" = 1 ] && [ "$1" = --complete ] || usage
      complete=1
    fi
    content=$(validate_sections "$FILE")
    if [ "$complete" -eq 1 ]; then
      remaining_is_clear "$content" \
        || fail "$FILE still has material open decisions in '## Remaining open decisions'"
    fi
    printf 'valid\n'
    ;;
  *) usage ;;
esac
