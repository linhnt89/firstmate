#!/usr/bin/env bash
# fm-secondmate-report.sh - helper to append a correlated or direct parent report.
#
# A secondmate answering a marked from-firstmate request must report on the
# parent status channel with the request's corr=<id> token. This helper makes
# that easy, but correctness must not depend on using it: a plain echo of a
# status line that includes the same corr token is equally valid
# (bin/fm-pending-reply-lib.sh).
#
# Usage:
#   fm-secondmate-report.sh <status-file> <verb> <corr_id> <note...>
#   fm-secondmate-report.sh --doc <status-file> <verb> <corr_id> <doc-path> <note...>
#   fm-secondmate-report.sh --direct-doc <status-file> <verb> <alignment-id> <doc-path> <note...>
#
# Examples:
#   fm-secondmate-report.sh "$STATUS" done abcdef0123456789 "audit clean"
#   fm-secondmate-report.sh --doc "$STATUS" done abcdef0123456789 data/x/report.md "see report"
#   fm-secondmate-report.sh --direct-doc "$STATUS" done design-a1 data/design-a1/report.md "alignment ready"
#
# The status file must be the absolute parent route from the secondmate charter
# (state/<id>.status under the PARENT home), never a path relative to this
# secondmate home. Writing under the wrong home is detected as supporting
# evidence by the parent pending-reply guard and does not acknowledge the
# request. `--direct-doc` is only for a captain-initiated local alignment: it
# deliberately writes an uncorrelated keyed document pointer and never creates
# or consumes a pending-reply correlation.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"

usage() {
  cat <<'EOF' >&2
Usage:
  fm-secondmate-report.sh <status-file> <verb> <corr_id> <note...>
  fm-secondmate-report.sh --doc <status-file> <verb> <corr_id> <doc-path> <note...>
  fm-secondmate-report.sh --direct-doc <status-file> <verb> <alignment-id> <doc-path> <note...>
EOF
  exit 2
}

DOC_MODE=0
DIRECT_DOC_MODE=0
if [ "${1:-}" = "--doc" ]; then
  DOC_MODE=1
  shift
elif [ "${1:-}" = "--direct-doc" ]; then
  DIRECT_DOC_MODE=1
  shift
fi

if [ "$DIRECT_DOC_MODE" = 1 ]; then
  [ $# -ge 4 ] || usage
  STATUS_FILE=$1
  VERB=$2
  ALIGNMENT_ID=$3
  DOC_PATH=$4
  shift 4
  case "$ALIGNMENT_ID" in
    ''|.*|*[!A-Za-z0-9._-]*)
      echo "error: alignment-id must be a path-safe identifier (got '$ALIGNMENT_ID')" >&2
      exit 1
      ;;
  esac
  [ "${#ALIGNMENT_ID}" -le 64 ] || {
    echo "error: alignment-id is too long (maximum 64 characters)" >&2
    exit 1
  }
  case "$DOC_PATH" in
    data/"$ALIGNMENT_ID"/report.md) ;;
    *)
      echo "error: direct alignment document must be data/$ALIGNMENT_ID/report.md (got '$DOC_PATH')" >&2
      exit 1
      ;;
  esac
  case "$STATUS_FILE" in
    /*) ;;
    *) echo "error: direct alignment status file must be absolute: $STATUS_FILE" >&2; exit 1 ;;
  esac
  [ ! -L "$STATUS_FILE" ] || {
    echo "error: direct alignment status file must not be a symlink: $STATUS_FILE" >&2
    exit 1
  }
  [ -d "$(dirname "$STATUS_FILE")" ] || {
    echo "error: parent status directory is missing: $(dirname "$STATUS_FILE")" >&2
    exit 1
  }
  NOTE=$*
  if [ -n "$NOTE" ]; then
    printf '%s [key=alignment-%s]: %s (%s via-helper)\n' "$VERB" "$ALIGNMENT_ID" "$NOTE" "$DOC_PATH" >> "$STATUS_FILE"
  else
    printf '%s [key=alignment-%s]: alignment ready (%s via-helper)\n' "$VERB" "$ALIGNMENT_ID" "$DOC_PATH" >> "$STATUS_FILE"
  fi
  exit 0
fi

[ $# -ge 4 ] || usage
STATUS_FILE=$1
VERB=$2
CORR=$3
shift 3

case "$CORR" in
  corr=*) CORR=${CORR#corr=} ;;
esac
case "$CORR" in
  [a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9]) ;;
  *)
    echo "error: corr_id must be 16 hex characters (got '$CORR')" >&2
    exit 1
    ;;
esac

case "$STATUS_FILE" in
  '') usage ;;
esac
mkdir -p "$(dirname "$STATUS_FILE")" 2>/dev/null || true
if [ ! -d "$(dirname "$STATUS_FILE")" ]; then
  echo "error: cannot create parent directory for status file '$STATUS_FILE'" >&2
  exit 1
fi

token=$(fm_pending_reply_corr_token "$CORR")
if [ "$DOC_MODE" = 1 ]; then
  [ $# -ge 1 ] || usage
  DOC_PATH=$1
  shift
  NOTE=$*
  if [ -n "$NOTE" ]; then
    printf '%s [%s]: %s (%s via-helper)\n' "$VERB" "$token" "$NOTE" "$DOC_PATH" >> "$STATUS_FILE"
  else
    printf '%s [%s]: %s (via-helper)\n' "$VERB" "$token" "$DOC_PATH" >> "$STATUS_FILE"
  fi
else
  NOTE=$*
  if [ -n "$NOTE" ]; then
    printf '%s [%s]: %s (via-helper)\n' "$VERB" "$token" "$NOTE" >> "$STATUS_FILE"
  else
    printf '%s [%s]: (via-helper)\n' "$VERB" "$token" >> "$STATUS_FILE"
  fi
fi
