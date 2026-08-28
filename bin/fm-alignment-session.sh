#!/usr/bin/env bash
# Manage fresh, project-scoped local alignment sessions.
#
# Usage:
#   fm-alignment-session.sh start <session-id> <project> <topic> [options]
#   fm-alignment-session.sh start <project> <topic> [options]
#   fm-alignment-session.sh retain <session-id> [report] [--supersedes <id>[,<id>...]] [--outcome <implementation|knowledge-only|both|neither>]
#   fm-alignment-session.sh inventory <project>
#   fm-alignment-session.sh retrieve <project> <historical-session-id> [--archive-home <parent-home>] [--archive-data <data-root>]
#   fm-alignment-session.sh reconcile <session-id>
#   fm-alignment-session.sh acknowledge <session-id> --kind <preflight|reconciliation> --executor-home <home> --token <token>
#   fm-alignment-session.sh promote <session-id> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off> [--purpose <implementation|knowledge-only|both>] [--task-id <id>]
#   fm-alignment-session.sh close <session-id> [--abandon]
#
# `start` leases a fresh firstmate worktree, marks it as an ephemeral alignment
# home, hydrates a bounded charter from the resolved project, and launches the
# existing captain-facing Secondmate runtime without registering a persistent
# Secondmate.  The parent owns the session record and archive.
#
# `retain` is the parent-owned completion boundary.  It validates and copies a
# session report into data/alignments/<project-key>/<session-id>/ before `close`
# can remove the ephemeral home.  It requires the bound executor's semantic
# readiness acknowledgement against the accepted hydration snapshot.
# `inventory` reads only archive metadata, while `retrieve` is the explicit
# opt-in that reads one historical report body. `reconcile` publishes refreshed
# knowledge as pending for a mutable session; `acknowledge` lets only its bound
# executor accept the preflight or refreshed snapshot. Completed reports are
# immutable and require a revised, explicitly superseding session after a later
# project or archive change.
#
# `promote` creates an ordinary ship brief containing the accepted alignment
# outcome.  It never edits project documentation and never launches a
# captain-facing implementation worker.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

usage() {
  local status=${1:-2}
  if [ "$status" -eq 0 ]; then
    sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
  else
    sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//' >&2
  fi
  exit "$status"
}

fail() {
  printf 'alignment-session: %s\n' "$*" >&2
  exit 1
}

case "${1:-}" in
  -h|--help) usage 0 ;;
esac

[ "$#" -ge 1 ] || usage
COMMAND=$1
shift

home_is_safe() {
  local home=$1
  case "$home" in /*) ;; *) return 1 ;; esac
  [ -d "$home" ] && [ ! -L "$home" ] || return 1
}

path_is_ancestor() {
  local ancestor=$1 path=$2
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in "$ancestor"/*) return 0 ;; esac
  return 1
}

id_valid() {
  local id=${1-}
  case "$id" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#id}" -le 64 ]
}

field_valid() {
  case "${1-}" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
}

require_parent_home() {
  case "$FM_HOME" in /*) ;; *) fail "FM_HOME must be an absolute firstmate home" ;; esac
  [ -d "$FM_HOME" ] && [ ! -L "$FM_HOME" ] \
    || fail "FM_HOME is missing or unsafe: $FM_HOME"
}

hash_text() {
  local text=$1
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$text" | sha256sum | cut -c1-12
  else
    printf '%s' "$text" | shasum -a 256 | cut -c1-12
  fi
}

archive_path_safe() {
  local path=$1 probe=$1
  case "$path" in /*) ;; *) fail "alignment archive path must be absolute: $path" ;; esac
  while [ "$probe" != / ]; do
    [ ! -L "$probe" ] || fail "alignment archive path must not contain a symlink: $probe"
    probe=$(dirname -- "$probe")
  done
}

safe_dir() {
  local dir=$1
  archive_path_safe "$dir"
  if [ -e "$dir" ] && [ ! -d "$dir" ]; then
    fail "alignment path is not a directory: $dir"
  fi
  mkdir -p "$dir"
  [ -d "$dir" ] && [ ! -L "$dir" ] || fail "alignment directory is unsafe: $dir"
}

lock_dir() {
  local lock=$1
  [ ! -e "$lock" ] || fail "another alignment session operation is already running: $lock"
  mkdir "$lock" 2>/dev/null || fail "another alignment session operation is already running: $lock"
  ALIGNMENT_LOCK=$lock
  trap 'rmdir "$ALIGNMENT_LOCK" 2>/dev/null || true' EXIT
}

read_record_field() {
  local file=$1 key=$2
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  sed -n "s/^${key}=//p" "$file" | tail -n 1
}

record_set() {
  local file=$1 key=$2 value=$3 tmp
  field_valid "$value" || fail "record value for $key contains a line separator"
  tmp="$file.tmp.$$"
  awk -F= -v key="$key" '$1 != key' "$file" > "$tmp"
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv -f -- "$tmp" "$file"
}

record_remove() {
  local file=$1 key=$2 tmp
  tmp="$file.tmp.$$"
  awk -F= -v key="$key" '$1 != key' "$file" > "$tmp"
  mv -f -- "$tmp" "$file"
}

session_record_path() { printf '%s/%s.alignment\n' "$STATE" "$1"; }

project_path_resolve() {
  local input=$1 candidate
  if [ -d "$PROJECTS/$input" ]; then
    candidate=$PROJECTS/$input
  elif [ -d "$FM_HOME/$input" ]; then
    candidate=$FM_HOME/$input
  else
    candidate=$input
  fi
  [ -d "$candidate" ] || fail "project is not a directory: $input"
  candidate=$(CDPATH='' cd -- "$candidate" 2>/dev/null && pwd -P) \
    || fail "project cannot be resolved: $input"
  git -C "$candidate" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || fail "project is not a git repository: $candidate"
  printf '%s\n' "$candidate"
}

project_name_for_path() {
  local path=$1 name
  name=$(basename "$path")
  name=$(printf '%s' "$name" | sed 's/[^A-Za-z0-9._-]/-/g')
  [ -n "$name" ] || name=project
  printf '%s\n' "$name"
}

project_key_for_path() {
  local path=$1 data_root=${2:-$DATA} name root meta existing_path reserved_path collision=0
  archive_path_safe "$data_root/alignments"
  # An exact project reservation wins over fresh basename allocation. This is
  # essential when a colliding project already owns a hashed key but the
  # original basename owner's failed start removed only its own reservation.
  for root in "$data_root/alignments"/*; do
    [ -d "$root" ] && [ ! -L "$root" ] || continue
    archive_path_safe "$root"
    if [ -f "$root/.project-path" ] && [ ! -L "$root/.project-path" ] \
      && [ "$(cat "$root/.project-path" 2>/dev/null || true)" = "$path" ]; then
      printf '%s\n' "$(basename "$root")"
      return
    fi
    for meta in "$root"/*/metadata; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      existing_path=$(read_record_field "$meta" project_path || true)
      if [ "$existing_path" = "$path" ]; then
        printf '%s\n' "$(basename "$root")"
        return
      fi
    done
  done
  name=$(project_name_for_path "$path")
  root="$data_root/alignments/$name"
  if [ -d "$root" ] && [ ! -L "$root" ]; then
    if [ -f "$root/.project-path" ] && [ ! -L "$root/.project-path" ]; then
      reserved_path=$(cat "$root/.project-path")
      if [ "$reserved_path" = "$path" ]; then
        printf '%s\n' "$name"
        return
      fi
      [ -z "$reserved_path" ] || collision=1
    fi
    for meta in "$root"/*/metadata; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      existing_path=$(read_record_field "$meta" project_path || true)
      if [ "$existing_path" = "$path" ]; then
        printf '%s\n' "$name"
        return
      fi
      [ -z "$existing_path" ] || collision=1
    done
  fi
  if [ "$collision" -eq 1 ]; then
    printf '%s-%s\n' "$name" "$(hash_text "$path")"
  else
    printf '%s\n' "$name"
  fi
}

archive_root_for() { printf '%s/alignments/%s\n' "$DATA" "$1"; }
archive_dir_for() { printf '%s/alignments/%s/%s\n' "$DATA" "$1" "$2"; }
archive_report_pointer() {
  local key=$1 sid=$2
  if [ "$DATA" = "$FM_HOME/data" ]; then
    printf 'data/alignments/%s/%s/report.md\n' "$key" "$sid"
  else
    printf '%s/alignments/%s/%s/report.md\n' "$DATA" "$key" "$sid"
  fi
}

published_archive_metadata_valid() {
  local meta=$1 project=$2 key=$3 archive_dir sid report outcome
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  archive_dir=$(dirname -- "$meta")
  sid=$(basename -- "$archive_dir")
  id_valid "$sid" || return 1
  case "$sid" in .*.tmp) return 1 ;; esac
  archive_path_safe "$archive_dir"
  [ "$(read_record_field "$meta" project_name || true)" = "$(project_name_for_path "$project")" ] || return 1
  [ "$(read_record_field "$meta" project_path || true)" = "$project" ] || return 1
  [ "$(read_record_field "$meta" project_key || true)" = "$key" ] || return 1
  [ "$(read_record_field "$meta" session_id || true)" = "$sid" ] || return 1
  [ -n "$(read_record_field "$meta" topic || true)" ] || return 1
  case "$(read_record_field "$meta" status || true)" in completed|abandoned) ;; *) return 1 ;; esac
  [ "$(read_record_field "$meta" report || true)" = report.md ] || return 1
  outcome=$(read_record_field "$meta" outcome || true)
  case "$outcome" in implementation|knowledge-only|both|neither) ;; *) return 1 ;; esac
  report="$archive_dir/report.md"
  [ -f "$report" ] && [ ! -L "$report" ] || return 1
  [ "$(read_record_field "$meta" report_digest || true)" = "$(file_content_digest "$report")" ] || return 1
}

session_load() {
  local id=$1 record
  record=$STATE/$id.alignment
  id_valid "$id" || fail "invalid alignment session id: $id"
  [ -f "$record" ] && [ ! -L "$record" ] \
    || fail "no alignment session record for $id"
  SESSION_ID=$id
  SESSION_RECORD=$record
  SESSION_PROJECT_NAME=$(read_record_field "$record" project_name || true)
  SESSION_PROJECT_PATH=$(read_record_field "$record" project_path || true)
  SESSION_PROJECT_KEY=$(read_record_field "$record" project_key || true)
  SESSION_TOPIC=$(read_record_field "$record" topic || true)
  SESSION_HOME=$(read_record_field "$record" home || true)
  SESSION_STATUS=$(read_record_field "$record" status || true)
  SESSION_ARCHIVE=$(read_record_field "$record" archive || true)
  SESSION_HEAD=$(read_record_field "$record" project_head || true)
  SESSION_STATUS_DIGEST=$(read_record_field "$record" project_status_digest || true)
  SESSION_HYDRATION_HEAD=$(read_record_field "$record" hydration_project_head || true)
  SESSION_HYDRATION_STATUS_DIGEST=$(read_record_field "$record" hydration_project_status_digest || true)
  SESSION_HYDRATION_ARCHIVE_DIGEST=$(read_record_field "$record" hydration_archive_inventory_digest || true)
  [ -n "$SESSION_PROJECT_NAME" ] && [ -n "$SESSION_PROJECT_PATH" ] \
    && [ -n "$SESSION_PROJECT_KEY" ] && [ -n "$SESSION_HOME" ] \
    || fail "alignment session record for $id is incomplete"
}

file_content_digest() {
  local file=$1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$file" | awk '{print $1}'
  else
    shasum -a 256 -- "$file" | awk '{print $1}'
  fi
}

project_status_digest() {
  local project=$1 file digest snapshot
  snapshot=$(
    {
      canonical_owner_declaration_sources "$project"
      canonical_owner_declarations "$project"
      canonical_document_paths "$project"
    } | LC_ALL=C sort -u | while IFS= read -r file; do
      [ -f "$file" ] && [ ! -L "$file" ] || continue
      digest=$(file_content_digest "$file") || exit 1
      printf '%s\t%s\n' "$file" "$digest"
    done
    printf 'git-status\t%s\n' "$(git -C "$project" status --porcelain=v1 --untracked-files=all)"
  ) || return 1
  hash_text "$snapshot"
}

capture_hydration_snapshot() {
  SESSION_HYDRATION_HEAD=$(git -C "$SESSION_PROJECT_PATH" rev-parse HEAD) \
    || return 1
  SESSION_HYDRATION_STATUS_DIGEST=$(project_status_digest "$SESSION_PROJECT_PATH") \
    || return 1
  SESSION_HYDRATION_ARCHIVE_DIGEST=$(hydration_archive_inventory_digest "$SESSION_PROJECT_PATH" "$SESSION_ID") \
    || return 1
}

hydration_archive_inventory_digest() {
  local project=$1 exclude_session=${2:-} inventory
  inventory=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" FM_PROJECTS_OVERRIDE="$PROJECTS" \
    inventory_session "$project") || return 1
  if [ -n "$exclude_session" ]; then
    inventory=$(printf '%s\n' "$inventory" | awk -v sid="$exclude_session" '
      $1 == "artifacts=0" || $1 ~ /^artifacts=/ { next }
      index($0, "session=" sid "\t") == 1 { next }
      { print; if (index($0, "session=") == 1) count++ }
      END { print "artifacts=" (count + 0) }
    ')
  fi
  hash_text "$inventory"
}

hydration_snapshot_valid() {
  local current_head current_status current_inventory
  [ -n "${SESSION_HYDRATION_HEAD:-}" ] \
    && [ -n "${SESSION_HYDRATION_STATUS_DIGEST:-}" ] \
    && [ -n "${SESSION_HYDRATION_ARCHIVE_DIGEST:-}" ] || return 1
  current_head=$(git -C "$SESSION_PROJECT_PATH" rev-parse HEAD 2>/dev/null || true)
  current_status=$(project_status_digest "$SESSION_PROJECT_PATH" || true)
  [ "$current_head" = "$SESSION_HYDRATION_HEAD" ] \
    && [ "$current_status" = "$SESSION_HYDRATION_STATUS_DIGEST" ] || return 1
  current_inventory=$(hydration_archive_inventory_digest "$SESSION_PROJECT_PATH" "$SESSION_ID" || true)
  [ -n "$current_inventory" ] && [ "$current_inventory" = "$SESSION_HYDRATION_ARCHIVE_DIGEST" ]
}

retained_archive_valid() {
  local expected_dir expected_report meta expected_key report_digest
  expected_key=$(project_key_for_path "$SESSION_PROJECT_PATH")
  [ "$SESSION_PROJECT_KEY" = "$expected_key" ] || return 1
  expected_dir=$(archive_dir_for "$SESSION_PROJECT_KEY" "$SESSION_ID")
  archive_path_safe "$expected_dir"
  expected_report="$expected_dir/report.md"
  meta="$expected_dir/metadata"
  [ "$SESSION_ARCHIVE" = "$expected_report" ] || return 1
  [ -f "$expected_report" ] && [ ! -L "$expected_report" ] || return 1
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  report_digest=$(read_record_field "$meta" report_digest || true)
  [ -n "$report_digest" ] && [ "$report_digest" = "$(file_content_digest "$expected_report")" ] || return 1
  [ "$(read_record_field "$meta" session_id || true)" = "$SESSION_ID" ] || return 1
  [ "$(read_record_field "$meta" project_name || true)" = "$SESSION_PROJECT_NAME" ] || return 1
  [ "$(read_record_field "$meta" project_path || true)" = "$SESSION_PROJECT_PATH" ] || return 1
  [ "$(read_record_field "$meta" project_key || true)" = "$SESSION_PROJECT_KEY" ] || return 1
  [ "$(read_record_field "$meta" topic || true)" = "$SESSION_TOPIC" ] || return 1
  [ "$(read_record_field "$meta" status || true)" = completed ] || return 1
  case "$(read_record_field "$meta" outcome || true)" in
    implementation|knowledge-only|both|neither) ;;
    *) return 1 ;;
  esac
  [ "$(read_record_field "$meta" outcome || true)" = "$(read_record_field "$SESSION_RECORD" outcome || true)" ] || return 1
  "$SCRIPT_DIR/fm-alignment.sh" validate-report "$expected_report" --complete \
    --session "$SESSION_ID" --project "$SESSION_PROJECT_NAME" >/dev/null 2>&1 || return 1
  grep -Fqx "Path: $SESSION_PROJECT_PATH" "$expected_report" || return 1
  grep -Fqx "Topic: $(read_record_field "$meta" topic || true)" "$expected_report" || return 1
}

firstmate_home_is_fresh() {
  local home=$1 name
  home_is_safe "$home" || fail "treehouse did not return a safe alignment home: $home"
  [ "$home" != "$FM_HOME" ] || fail "alignment home cannot be the active firstmate home"
  [ "$home" != "$FM_ROOT" ] || fail "alignment home cannot be the firstmate repository"
  path_is_ancestor "$FM_HOME" "$home" && fail "alignment home is inside the active firstmate home"
  path_is_ancestor "$FM_ROOT" "$home" && fail "alignment home is inside the firstmate repository"
  [ -f "$home/AGENTS.md" ] || fail "alignment home is not a firstmate worktree: missing AGENTS.md"
  [ -d "$home/bin" ] || fail "alignment home is not a firstmate worktree: missing bin/"
  [ ! -e "$home/.env" ] && [ ! -L "$home/.env" ] \
    || fail "alignment home contains a prior private environment file"
  for name in data state config projects; do
    [ ! -e "$home/$name" ] || [ ! -L "$home/$name" ] \
      || fail "alignment home has an unsafe $name directory"
    if [ -e "$home/$name" ]; then
      [ -d "$home/$name" ] || fail "alignment home has a non-directory $name path"
      [ -z "$(find "$home/$name" -mindepth 1 -print -quit 2>/dev/null)" ] \
        || fail "alignment home is not fresh: $home/$name contains prior operational state"
    fi
  done
}

return_home() {
  local home=$1
  [ -e "$home" ] || return 0
  command -v treehouse >/dev/null 2>&1 \
    || fail "treehouse is unavailable while returning alignment home $home"
  (cd "$FM_ROOT" && treehouse return --force "$home" >/dev/null) \
    || fail "could not return alignment home $home; retained it for recovery"
}

alignment_config() {
  local line
  [ -f "$CONFIG/alignment-harness" ] || return 0
  [ ! -L "$CONFIG/alignment-harness" ] || fail "alignment-harness config must not be a symlink"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in \#*) continue ;; esac
    printf '%s\n' "$line"
    return
  done < "$CONFIG/alignment-harness"
}

repository_root_for_project() {
  local project=$1 root
  root=$(git -C "$project" rev-parse --show-toplevel 2>/dev/null) || return 1
  CDPATH='' cd -- "$root" 2>/dev/null && pwd -P
}

canonical_document_paths() {
  local project=$1 repo prefix relative candidate
  repo=$(repository_root_for_project "$project") || return 1
  prefix=$(git -C "$project" rev-parse --show-prefix 2>/dev/null) || return 1
  # `git ls-files` reports paths relative to the repository root, not the
  # resolved project path. Filter by the repository prefix before rebuilding
  # an absolute path, so nested projects do not accidentally prepend the
  # project path twice or import a sibling project's documentation.
  while IFS= read -r -d '' relative; do
    case "$relative" in
      "$prefix"*) ;;
      *) continue ;;
    esac
    candidate="$repo/$relative"
    [ -f "$candidate" ] && [ ! -L "$candidate" ] || continue
    path_is_ancestor "$project" "$candidate" || [ "$candidate" = "$project" ] || continue
    canonical_document_is_text "$candidate" || continue
    printf '%s\n' "$candidate"
  done < <(git -C "$project" ls-files --full-name -z -- \
    '*.md' '*.mdx' '*.rst' '*.adoc' '*.txt' 2>/dev/null)
  if [ -d "$project/docs" ] && [ ! -L "$project/docs" ]; then
    find "$project/docs" -type f ! -name '*.report.md' -print
  fi
  find "$project" -maxdepth 1 -type f \( -name '*.md' -o -name '*.mdx' -o -name '*.rst' -o -name '*.adoc' -o -name '*.txt' \) -print
}

canonical_owner_declaration_sources() {
  local project=$1 repo current file
  repo=$(repository_root_for_project "$project") || return 1
  current=$project
  while :; do
    file="$current/AGENTS.md"
    if [ -f "$file" ] && [ ! -L "$file" ]; then
      printf '%s\n' "$file"
    fi
    [ "$current" = "$repo" ] && break
    case "$current" in
      "$repo"/*) current=$(dirname "$current") ;;
      *) break ;;
    esac
  done
  find "$project" \( -path "$project/.git" -o -path '*/.git' \) -prune -o \
    -type f \( \
      -name '.context-owner' -o -name 'context-owner' -o \
      -name '.owner-pointer' -o -name 'owner-pointer' \
    \) -print | LC_ALL=C sort
}

canonical_owner_declarations_from_source() {
  local project=$1 source=$2 scope base declarations declaration candidate contract
  local -a bases=()
  scope=$(CDPATH='' cd -- "$(dirname "$source")" 2>/dev/null && pwd -P) || return 1
  case "$(basename "$source")" in
    .context-owner|context-owner|.owner-pointer|owner-pointer)
      bases=("$scope")
      declarations=$(awk '/^[[:space:]]*#/ { next } NF { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print }' "$source")
      ;;
    *)
      # AGENTS pointers historically resolve from the project root. Try the
      # declaration source scope first for nested repositories, then preserve
      # that compatibility when a parent AGENTS file uses project-relative text.
      bases=("$scope")
      [ "$scope" = "$project" ] || bases+=("$project")
      declarations=$(awk '
        /^[[:space:]]*(context-owner|context_owner|owner-pointer|owner_pointer)[[:space:]]*[:=]/ {
          line=$0
          sub(/^[[:space:]]*(context-owner|context_owner|owner-pointer|owner_pointer)[[:space:]]*[:=][[:space:]]*`?/, "", line)
          sub(/`?[[:space:]]*$/, "", line)
          print line
        }
      ' "$source")
      ;;
  esac
  while IFS= read -r declaration; do
    declaration=${declaration#\`}
    declaration=${declaration%\`}
    declaration=${declaration%\\)}
    declaration=${declaration#\\(}
    [ -n "$declaration" ] || continue
    contract=
    if [[ "$declaration" =~ ^contract[=:]([A-Za-z0-9._-]+)[[:space:]]+([^[:space:]]+)$ ]]; then
      contract=${BASH_REMATCH[1]}
      declaration=${BASH_REMATCH[2]}
    fi
    case "$declaration" in /*) continue ;; esac
    printf '%s' "$declaration" | LC_ALL=C grep -Eq '[[:space:],:;()]' && continue
    for base in "${bases[@]}"; do
      candidate="$base/$declaration"
      [ -f "$candidate" ] && [ ! -L "$candidate" ] || continue
      candidate=$(CDPATH='' cd -- "$(dirname "$candidate")" 2>/dev/null && pwd -P)/$(basename "$candidate") || continue
      path_is_ancestor "$project" "$candidate" || [ "$candidate" = "$project" ] || continue
      canonical_document_is_text "$candidate" || continue
      printf '%s\t%s\n' "$candidate" "$contract"
    done
  done <<< "$declarations"
}

canonical_owner_declarations() {
  local project=$1
  canonical_owner_declaration_candidates "$project" | cut -f3 | LC_ALL=C sort -u
}

canonical_owner_declaration_candidates() {
  local project=$1 source kind scope candidate contract
  while IFS= read -r source; do
    case "$(basename "$source")" in
      AGENTS.md) kind=agents ;;
      .context-owner|context-owner) kind=context ;;
      .owner-pointer|owner-pointer) kind=pointer ;;
      *) continue ;;
    esac
    scope=$(CDPATH='' cd -- "$(dirname "$source")" 2>/dev/null && pwd -P) || continue
    while IFS=$'\t' read -r candidate contract; do
      printf '%s\t%s\t%s\t%s\t%s\n' "$kind" "$source" "$candidate" "$scope" "$contract"
    done < <(canonical_owner_declarations_from_source "$project" "$source")
  done < <(canonical_owner_declaration_sources "$project")
}

canonical_owner_resolutions() {
  local project=$1
  canonical_owner_declaration_candidates "$project" | LC_ALL=C sort -t $'\t' -k4,4 -k3,3 -k5,5 -k1,1 -k2,2 | \
    awk -F '\t' -v OFS='\t' '
      {
        row_kind[NR]=$1; row_source[NR]=$2; row_file[NR]=$3; row_scope[NR]=$4; row_contract[NR]=$5
        key=$4 SUBSEP $5 SUBSEP $3
        if (!(key in distinct)) { distinct[key]=1; distinct_count[$4 SUBSEP $5]++ }
      }
      END {
        for (i=1; i<=NR; i++) {
          scope=row_scope[i]
          contract=row_contract[i]
          key=scope SUBSEP contract SUBSEP row_file[i]
          if (contract != "" && distinct_count[scope SUBSEP contract] > 1) {
            print "conflict", row_kind[i], row_source[i], row_file[i], scope, contract
          } else if (!(key in selected)) {
            selected[key]=1
            print "selected", row_kind[i], row_source[i], row_file[i], scope, contract
          }
        }
      }
    '
}

canonical_document_is_text() {
  local file=$1
  [ ! -L "$file" ] && [ -f "$file" ] && LC_ALL=C grep -Iq . "$file"
}

canonical_document_title() {
  local file=$1 title
  title=$(LC_ALL=C awk '/^[[:space:]]*#[[:space:]]+/ { sub(/^[[:space:]]*#[[:space:]]+/, ""); print; exit }' "$file")
  [ -n "$title" ] || title='(untitled owner)'
  printf '%s\n' "$title" | tr '\t\r\n' '   '
}

write_agents_chain() {
  local project=$1 repo current file
  local -a chain=()
  repo=$(repository_root_for_project "$project") || return 1
  current=$project
  while :; do
    file="$current/AGENTS.md"
    if [ -f "$file" ] && [ ! -L "$file" ]; then
      chain+=("$file")
    fi
    [ "$current" = "$repo" ] && break
    case "$current" in
      "$repo"/*) current=$(dirname "$current") ;;
      *) break ;;
    esac
  done
  for ((current=${#chain[@]}-1; current>=0; current--)); do
    file=${chain[current]}
    printf '\n### AGENTS chain: %s\n\n' "${file#"$project"/}"
    cat "$file"
    printf '\n'
  done
}

write_canonical_context() {
  local context=$1 project=$2 file relative resolutions resolution kind source candidate scope contract
  resolutions=$(canonical_owner_resolutions "$project")
  {
    printf '# Alignment session context\n\n'
    printf 'Project: %s\nPath: %s\n\n' "$SESSION_PROJECT_NAME" "$project"
    printf 'This is a fresh session for exactly one project and one topic.\n'
    printf 'Canonical project knowledge below is supplied by Firstmate. Read the relevant owners before declaring readiness; documentation audience labels do not determine authority.\n\n'
    printf '## Current canonical project knowledge\n\n'
    printf 'Existing maintained owners are preferred over new memory files. This context supplies a compact scoped owner index; the strong executor reads topic-relevant owners directly from the project path.\n'
    write_agents_chain "$project"
    printf '\n### Current-document owner index\n\n'
    printf 'Entries are metadata only so unrelated or oversized owners cannot exhaust the session context. No owner is copied or truncated; inspect any required owner at its listed project path.\n\n'
    printf 'Selected current owners (all explicit declarations remain available unless an explicit same-contract overlap is proven):\n'
    while IFS=$'\t' read -r resolution kind source file scope contract; do
      [ "$resolution" = selected ] && [ -n "$file" ] || continue
      relative=${file#"$project"/}
      [ -n "$contract" ] || contract=unspecified
      printf 'selected\t%s\t%s bytes\t%s\tdeclared by %s\tscope=%s\tcontract=%s\n' \
        "$relative" "$(wc -c < "$file" | tr -d ' ')" "$(canonical_document_title "$file")" "$source" "$scope" "$contract"
    done <<< "$resolutions"
    printf '\nConflicting owner declarations (explicit incompatible same-contract overlap):\n'
    while IFS=$'\t' read -r resolution kind source file scope contract; do
      [ "$resolution" = conflict ] && [ -n "$file" ] || continue
      relative=${file#"$project"/}
      printf 'conflict\t%s\t%s bytes\t%s\tdeclared by %s\tscope=%s\tcontract=%s\n' \
        "$relative" "$(wc -c < "$file" | tr -d ' ')" "$(canonical_document_title "$file")" "$source" "$scope" "$contract"
    done <<< "$resolutions"
    printf '\nFallback document candidates (not assumed authoritative):\n'
    while IFS= read -r file; do
      canonical_document_is_text "$file" || continue
      relative=${file#"$project"/}
      canonical_owner_declarations "$project" | grep -F -x "$file" >/dev/null 2>&1 && continue
      printf 'candidate\t%s\t%s bytes\t%s\tread from project path %s\n' \
        "$relative" "$(wc -c < "$file" | tr -d ' ')" "$(canonical_document_title "$file")" "$file"
    done < <(canonical_document_paths "$project" | LC_ALL=C sort -u)
    printf '\n## Historical alignment inventory\n\n'
    printf 'The following metadata-only inventory is deterministic and project-scoped.\n'
    printf 'Do not load every historical report.\nUse the explicit retrieval command only for a relevant session.\n\n'
    FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" FM_PROJECTS_OVERRIDE="$PROJECTS" \
      "$SCRIPT_DIR/fm-alignment-session.sh" inventory "$project" 2>/dev/null || \
      printf 'No retained alignment artifacts exist for this project yet.\n'
  } > "$context"
}

write_session_charter() {
  local charter=$1 context=$2 parent_home_q project_q ack_token_q
  parent_home_q=$(printf '%q' "$FM_HOME")
  project_q=$(printf '%q' "$SESSION_PROJECT_PATH")
  ack_token_q=$(printf '%q' "$SESSION_ACK_TOKEN")
  cat > "$charter" <<EOF
You are a fresh, ephemeral captain-facing local alignment executor managed by Firstmate.
Work only on this bounded alignment conversation; do not wait for a human between turns.

# Alignment session
Project: $SESSION_PROJECT_NAME
Project path: $SESSION_PROJECT_PATH
Session: $SESSION_ID
Topic: $SESSION_TOPIC

Read the current project at the path above and read \
\`data/alignment-context.md\` before reasoning.
The context contains the AGENTS chain, a compact current-document owner index, and a compact historical inventory. Use the index and the project's owner pointers to inspect topic-relevant canonical owners directly before declaring the alignment ready; never silently omit or truncate a required owner.
Historical report bodies are not loaded automatically; after inventory identifies a relevant prior session, retrieve only that report with this explicit parent-owned command:
  bin/fm-alignment-session.sh retrieve $project_q HISTORICAL_SESSION_ID --archive-home $parent_home_q --archive-data $(printf '%q' "$DATA")

Launch acknowledgement proves only endpoint and instructions delivery; it is not semantic readiness.
After inspecting the topic-relevant current owners and primary evidence, acknowledge semantic preflight readiness from this executor home:
  FM_HOME=$parent_home_q bin/fm-alignment-session.sh acknowledge $SESSION_ID --kind preflight --executor-home "\$FM_HOME" --token $ack_token_q
Do not report substantive alignment readiness or completion until that command succeeds.

This session is captain-facing only for this alignment topic.
It is not a persistent Secondmate, it has no standing authority, and it must not become ordinary implementation work.
Ordinary implementation and knowledge-promotion work must be handed back to Firstmate for a normal non-captain-facing worker.
Do not edit the project repository, its documentation, or its git history.
Do not create commits, push, open a PR, or promote knowledge directly from this session.

# Report contract
Write the outcome, never a transcript, to data/$SESSION_ID/report.md.
The report must retain the project and session identity and contain these sections:

## Project identity
Name: $SESSION_PROJECT_NAME
Path: $SESSION_PROJECT_PATH

## Alignment identity
Session: $SESSION_ID
Topic: $SESSION_TOPIC
Source: local

## Goal

## Relevant facts

## Settled decisions

## Acceptance criteria

## Out of scope

## Engineering discretion

## Remaining open decisions

## Durable-knowledge candidates
Identify domain-language updates, high-significance ADR or decision-record candidates, explicitly superseded knowledge, and other documentation follow-ups separately from the implementation contract.
Candidates are proposals only and are not current canonical truth until Firstmate routes authorized project work.

Use the existing captain-hold lifecycle for every genuine material captain-owned decision.
Before reporting completion, run:
  FM_HOME=$SESSION_HOME bin/fm-alignment.sh validate-report data/$SESSION_ID/report.md --complete --session $SESSION_ID --project $SESSION_PROJECT_NAME
If the parent reports a changed project or historical inventory, wait for it to run reconcile, inspect the refreshed context, and acknowledge the refreshed snapshot from this executor home:
  FM_HOME=$parent_home_q bin/fm-alignment-session.sh acknowledge $SESSION_ID --kind reconciliation --executor-home "\$FM_HOME" --token $ack_token_q
Then notify the parent through the existing uncorrelated direct-alignment command:
  FM_HOME=$SESSION_HOME bin/fm-alignment.sh complete-direct $SESSION_ID
The parent will retain the validated report before this ephemeral session is closed.
If project knowledge or the historical inventory changed during this conversation, the parent must run \`bin/fm-alignment-session.sh reconcile $SESSION_ID\`; a completed immutable outcome cannot be refreshed in place, so start a revised session and explicitly supersede this report.

The parent status file is $STATE/$SESSION_ID.status.
Report only phase changes and terminal results there, not a detailed transcript.
EOF
  # Keep the context path in the charter explicit for humans and harnesses.
  printf '\nContext source: %s\n' "$context" >> "$charter"
}

reconcile_session() {
  local id=${1:-} now archive_dir
  require_parent_home
  [ -n "$id" ] || usage
  [ "$#" -eq 1 ] || usage
  id_valid "$id" || fail "invalid alignment session id: $id"
  mkdir -p "$STATE"
  lock_dir "$STATE/.alignment-session-$id.lock"
  session_load "$id"
  [ "$SESSION_STATUS" != closed ] || fail "alignment session $id is already closed"
  [ "$SESSION_STATUS" != completed ] \
    || fail "completed alignment $id is immutable; start a revised session and explicitly supersede it"
  archive_dir=$(archive_dir_for "$SESSION_PROJECT_KEY" "$SESSION_ID")
  archive_path_safe "$archive_dir"
  if [ -f "$archive_dir/metadata" ] && [ ! -L "$archive_dir/metadata" ] \
    && [ "$(read_record_field "$archive_dir/metadata" status || true)" = completed ]; then
    fail "completed alignment $id is immutable; start a revised session and explicitly supersede it"
  fi
  home_is_safe "$SESSION_HOME" \
    || fail "alignment session $id has an unsafe ephemeral home: $SESSION_HOME"
  [ -d "$SESSION_HOME/data" ] && [ ! -L "$SESSION_HOME/data" ] \
    || fail "alignment session $id has no safe data directory"
  write_canonical_context "$SESSION_HOME/data/alignment-context.md" "$SESSION_PROJECT_PATH" \
    || fail "could not refresh the alignment context"
  capture_hydration_snapshot \
    || fail "could not capture the pending reconciliation project and alignment inventory"
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  record_set "$SESSION_RECORD" pending_hydration_project_head "$SESSION_HYDRATION_HEAD"
  record_set "$SESSION_RECORD" pending_hydration_project_status_digest "$SESSION_HYDRATION_STATUS_DIGEST"
  record_set "$SESSION_RECORD" pending_hydration_archive_inventory_digest "$SESSION_HYDRATION_ARCHIVE_DIGEST"
  record_set "$SESSION_RECORD" reconciliation_pending 1
  record_set "$SESSION_RECORD" reconciliation_requested_at "$now"
  record_set "$SESSION_RECORD" readiness pending
  record_remove "$SESSION_RECORD" preflight_ack
  record_remove "$SESSION_RECORD" preflight_ack_at
  record_remove "$SESSION_RECORD" preflight_project_head
  record_remove "$SESSION_RECORD" preflight_project_status_digest
  record_remove "$SESSION_RECORD" preflight_archive_inventory_digest
  record_remove "$SESSION_RECORD" reconciliation_ack
  record_remove "$SESSION_RECORD" reconciliation_ack_at
  printf 'reconciliation pending for alignment session %s project=%s; executor acknowledgement is required\n' \
    "$id" "$SESSION_PROJECT_NAME"
}

session_executor_home_valid() {
  local home=$1 canonical parent_marker session_meta
  home_is_safe "$home" || return 1
  canonical=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || return 1
  [ "$canonical" = "$SESSION_HOME" ] || return 1
  [ -f "$home/.fm-secondmate-home" ] && [ ! -L "$home/.fm-secondmate-home" ] \
    || return 1
  [ "$(cat "$home/.fm-secondmate-home" 2>/dev/null || true)" = "$SESSION_ID" ] || return 1
  parent_marker="$home/.fm-secondmate-parent"
  [ -f "$parent_marker" ] && [ ! -L "$parent_marker" ] || return 1
  [ "$(read_record_field "$parent_marker" schema || true)" = fm-secondmate-parent.v1 ] || return 1
  [ "$(read_record_field "$parent_marker" route || true)" = local ] || return 1
  [ "$(read_record_field "$parent_marker" parent_home || true)" = "$FM_HOME" ] || return 1
  session_meta="$home/data/$SESSION_ID/session.meta"
  [ -f "$session_meta" ] && [ ! -L "$session_meta" ] || return 1
  [ "$(read_record_field "$session_meta" schema || true)" = fm-alignment-session.v1 ] || return 1
  [ "$(read_record_field "$session_meta" session_id || true)" = "$SESSION_ID" ] || return 1
  [ "$(read_record_field "$session_meta" project_name || true)" = "$SESSION_PROJECT_NAME" ] || return 1
  [ "$(read_record_field "$session_meta" project_path || true)" = "$SESSION_PROJECT_PATH" ] || return 1
  [ "$(read_record_field "$session_meta" topic || true)" = "$SESSION_TOPIC" ] || return 1
  [ -f "$STATE/$SESSION_ID.meta" ] && [ ! -L "$STATE/$SESSION_ID.meta" ] || return 1
}

semantic_readiness_valid() {
  [ "$(read_record_field "$SESSION_RECORD" launch_ack || true)" = acknowledged ] || return 1
  [ "$(read_record_field "$SESSION_RECORD" readiness || true)" = acknowledged ] || return 1
  [ "$(read_record_field "$SESSION_RECORD" preflight_ack || true)" = acknowledged ] || return 1
  [ "$(read_record_field "$SESSION_RECORD" reconciliation_pending || true)" != 1 ] || return 1
  [ "$(read_record_field "$SESSION_RECORD" preflight_project_head || true)" = "$SESSION_HYDRATION_HEAD" ] || return 1
  [ "$(read_record_field "$SESSION_RECORD" preflight_project_status_digest || true)" = "$SESSION_HYDRATION_STATUS_DIGEST" ] || return 1
  [ "$(read_record_field "$SESSION_RECORD" preflight_archive_inventory_digest || true)" = "$SESSION_HYDRATION_ARCHIVE_DIGEST" ] || return 1
}

acknowledge_session() {
  local id=${1:-} kind='' executor_home='' token='' now pending_head pending_status pending_archive
  require_parent_home
  [ -n "$id" ] || usage
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --kind) [ "$#" -ge 2 ] || usage; kind=$2; shift 2 ;;
      --kind=*) kind=${1#--kind=}; shift ;;
      --executor-home) [ "$#" -ge 2 ] || usage; executor_home=$2; shift 2 ;;
      --executor-home=*) executor_home=${1#--executor-home=}; shift ;;
      --token) [ "$#" -ge 2 ] || usage; token=$2; shift 2 ;;
      --token=*) token=${1#--token=}; shift ;;
      *) usage ;;
    esac
  done
  case "$kind" in preflight|reconciliation) ;; *) fail "acknowledgement requires --kind preflight or reconciliation" ;; esac
  [ -n "$executor_home" ] && [ -n "$token" ] || fail "acknowledgement requires executor home and token"
  if ! field_valid "$executor_home" || ! field_valid "$token"; then
    fail "acknowledgement identity contains a line separator"
  fi
  id_valid "$id" || fail "invalid alignment session id: $id"
  mkdir -p "$STATE"
  lock_dir "$STATE/.alignment-session-$id.lock"
  session_load "$id"
  [ "$SESSION_STATUS" != closed ] || fail "alignment session $id is already closed"
  [ "$SESSION_STATUS" = running ] || fail "alignment session $id is not ready for executor acknowledgement"
  [ "$(read_record_field "$SESSION_RECORD" launch_ack || true)" = acknowledged ] \
    || fail "alignment session $id has no launch delivery acknowledgement"
  [ "$(read_record_field "$SESSION_RECORD" executor_ack_token || true)" = "$token" ] \
    || fail "alignment session $id has an invalid executor acknowledgement token"
  session_executor_home_valid "$executor_home" \
    || fail "alignment session $id acknowledgement is not from its bound executor home"
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  case "$kind" in
    preflight)
      [ "$(read_record_field "$SESSION_RECORD" reconciliation_pending || true)" != 1 ] \
        || fail "alignment session $id has a pending reconciliation; acknowledge that refreshed snapshot instead"
      hydration_snapshot_valid \
        || fail "project or parent alignment inventory changed before preflight; run reconcile before acknowledging readiness"
      record_set "$SESSION_RECORD" preflight_project_head "$SESSION_HYDRATION_HEAD"
      record_set "$SESSION_RECORD" preflight_project_status_digest "$SESSION_HYDRATION_STATUS_DIGEST"
      record_set "$SESSION_RECORD" preflight_archive_inventory_digest "$SESSION_HYDRATION_ARCHIVE_DIGEST"
      record_set "$SESSION_RECORD" preflight_ack acknowledged
      record_set "$SESSION_RECORD" preflight_ack_at "$now"
      record_set "$SESSION_RECORD" readiness acknowledged
      ;;
    reconciliation)
      [ "$(read_record_field "$SESSION_RECORD" reconciliation_pending || true)" = 1 ] \
        || fail "alignment session $id has no pending reconciliation to acknowledge"
      pending_head=$(read_record_field "$SESSION_RECORD" pending_hydration_project_head || true)
      pending_status=$(read_record_field "$SESSION_RECORD" pending_hydration_project_status_digest || true)
      pending_archive=$(read_record_field "$SESSION_RECORD" pending_hydration_archive_inventory_digest || true)
      capture_hydration_snapshot \
        || fail "could not verify the refreshed project and alignment inventory"
      [ "$SESSION_HYDRATION_HEAD" = "$pending_head" ] \
        && [ "$SESSION_HYDRATION_STATUS_DIGEST" = "$pending_status" ] \
        && [ "$SESSION_HYDRATION_ARCHIVE_DIGEST" = "$pending_archive" ] \
        || fail "project or parent alignment inventory changed after reconcile; run reconcile again"
      record_set "$SESSION_RECORD" hydration_project_head "$pending_head"
      record_set "$SESSION_RECORD" hydration_project_status_digest "$pending_status"
      record_set "$SESSION_RECORD" hydration_archive_inventory_digest "$pending_archive"
      record_set "$SESSION_RECORD" hydration_reconciled_at "$now"
      record_remove "$SESSION_RECORD" pending_hydration_project_head
      record_remove "$SESSION_RECORD" pending_hydration_project_status_digest
      record_remove "$SESSION_RECORD" pending_hydration_archive_inventory_digest
      record_remove "$SESSION_RECORD" reconciliation_pending
      record_set "$SESSION_RECORD" reconciliation_ack acknowledged
      record_set "$SESSION_RECORD" reconciliation_ack_at "$now"
      record_set "$SESSION_RECORD" preflight_project_head "$pending_head"
      record_set "$SESSION_RECORD" preflight_project_status_digest "$pending_status"
      record_set "$SESSION_RECORD" preflight_archive_inventory_digest "$pending_archive"
      record_set "$SESSION_RECORD" preflight_ack acknowledged
      record_set "$SESSION_RECORD" preflight_ack_at "$now"
      record_set "$SESSION_RECORD" readiness acknowledged
      ;;
  esac
  printf 'acknowledged alignment session %s kind=%s readiness=acknowledged\n' "$id" "$kind"
}

session_id_new() {
  local base candidate suffix=0
  base="alignment-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  candidate=$base
  while [ -e "$STATE/$candidate.alignment" ] || [ -e "$STATE/$candidate.meta" ]; do
    suffix=$((suffix + 1))
    candidate="$base-$suffix"
  done
  printf '%s\n' "$candidate"
}

start_session() {
  local session_id='' project_input='' topic='' harness='' model='' effort='' backend='' line created executor_ack_token='' spawn_output='' spawn_status=0
  local -a pos=() spawn_args
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session|--session-id) [ "$#" -ge 2 ] || usage; session_id=$2; shift 2 ;;
      --project) [ "$#" -ge 2 ] || usage; project_input=$2; shift 2 ;;
      --topic) [ "$#" -ge 2 ] || usage; topic=$2; shift 2 ;;
      --harness) [ "$#" -ge 2 ] || usage; harness=$2; shift 2 ;;
      --model) [ "$#" -ge 2 ] || usage; model=$2; shift 2 ;;
      --effort) [ "$#" -ge 2 ] || usage; effort=$2; shift 2 ;;
      --backend) [ "$#" -ge 2 ] || usage; backend=$2; shift 2 ;;
      --) shift; while [ "$#" -gt 0 ]; do pos+=("$1"); shift; done ;;
      -*) usage ;;
      *) pos+=("$1"); shift ;;
    esac
  done
  if [ -z "$session_id" ] && [ "${#pos[@]}" -ge 3 ]; then
    session_id=${pos[0]}; project_input=${pos[1]}; topic=${pos[2]}
    [ "${#pos[@]}" -eq 3 ] || usage
  elif [ -z "$project_input" ] && [ "${#pos[@]}" -ge 2 ]; then
    project_input=${pos[0]}; topic=${pos[1]}
    [ "${#pos[@]}" -eq 2 ] || usage
  elif [ "${#pos[@]}" -gt 0 ]; then
    [ -n "$project_input" ] || project_input=${pos[0]}
    [ "${#pos[@]}" -gt 1 ] && [ -n "$topic" ] || topic=${pos[1]:-}
    [ "${#pos[@]}" -le 2 ] || usage
  fi
  require_parent_home
  [ -n "$project_input" ] || usage
  [ -n "$topic" ] || fail "one coherent alignment topic is required"
  field_valid "$topic" || fail "alignment topic contains a line separator"
  [ -n "$session_id" ] || session_id=$(session_id_new)
  id_valid "$session_id" || fail "invalid alignment session id: $session_id"
  field_valid "$project_input" || fail "project input contains a line separator"
  [ ! -L "$DATA" ] && [ ! -L "$STATE" ] || fail "alignment data/state directory must not be a symlink"
  mkdir -p "$DATA" "$STATE"
  lock_dir "$STATE/.alignment-session-$session_id.lock"
  PROJECT_KEY_LOCK="$STATE/.alignment-project-key.lock"
  PROJECT_KEY_WAIT=0
  while ! mkdir "$PROJECT_KEY_LOCK" 2>/dev/null; do
    PROJECT_KEY_WAIT=$((PROJECT_KEY_WAIT + 1))
    [ "$PROJECT_KEY_WAIT" -le 3000 ] || fail "another alignment project-key operation is stuck: $PROJECT_KEY_LOCK"
    sleep 0.01
  done
  printf '%s\n' "$$" > "$PROJECT_KEY_LOCK/pid"
  START_HOME_LEASED=0
  START_HOME=
  START_PROJECT_KEY_ROOT=
  START_PROJECT_KEY_RESERVATION=
  START_PROJECT_KEY_RESERVATION_CREATED=0
  alignment_start_cleanup() {
    local status=$? published_archive=
    if [ "$START_HOME_LEASED" -eq 1 ] && [ -n "$START_HOME" ] && [ -e "$START_HOME" ]; then
      if command -v treehouse >/dev/null 2>&1; then
        (cd "$FM_ROOT" && treehouse return --force "$START_HOME" >/dev/null) \
          || printf 'alignment-session: could not return failed-start home %s; preserve it for recovery\n' "$START_HOME" >&2
      else
        printf 'alignment-session: treehouse is unavailable while returning failed-start home %s\n' "$START_HOME" >&2
      fi
    fi
    if [ "$status" -ne 0 ] && [ "$START_PROJECT_KEY_RESERVATION_CREATED" -eq 1 ] \
      && [ -f "$START_PROJECT_KEY_RESERVATION" ] \
      && [ ! -L "$START_PROJECT_KEY_RESERVATION" ] \
      && [ "$(cat "$START_PROJECT_KEY_RESERVATION" 2>/dev/null || true)" = "$SESSION_PROJECT_PATH" ]; then
      if [ -d "$START_PROJECT_KEY_ROOT" ] && [ ! -L "$START_PROJECT_KEY_ROOT" ]; then
        published_archive=$(find "$START_PROJECT_KEY_ROOT" -mindepth 2 -maxdepth 2 \
          -type f -name metadata -print -quit 2>/dev/null || true)
      fi
      [ -n "$published_archive" ] || rm -f -- "$START_PROJECT_KEY_RESERVATION"
    fi
    if [ -n "${PROJECT_KEY_LOCK:-}" ]; then
      rm -f -- "$PROJECT_KEY_LOCK/pid"
      rmdir "$PROJECT_KEY_LOCK" 2>/dev/null || true
    fi
    rmdir "$ALIGNMENT_LOCK" 2>/dev/null || true
    return "$status"
  }
  trap alignment_start_cleanup EXIT
  [ ! -e "$STATE/$session_id.alignment" ] || fail "alignment session already exists: $session_id"
  [ ! -e "$STATE/$session_id.meta" ] || fail "task id is already in use: $session_id"
  if [ -f "$DATA/secondmates.md" ] \
    && awk -v id="$session_id" '$1 == "-" && $2 == id { found=1 } END { exit found ? 0 : 1 }' \
      "$DATA/secondmates.md"; then
    fail "alignment session id conflicts with a persistent Secondmate: $session_id"
  fi

  SESSION_PROJECT_PATH=$(project_path_resolve "$project_input")
  SESSION_PROJECT_NAME=$(project_name_for_path "$SESSION_PROJECT_PATH")
  SESSION_PROJECT_KEY=$(project_key_for_path "$SESSION_PROJECT_PATH")
  # Reserve every selected key, including a collision-hash key, while the
  # project-key lock is held. The reservation makes failed-start cleanup and
  # concurrent archive discovery observe the same project association.
  START_PROJECT_KEY_ROOT=$(archive_root_for "$SESSION_PROJECT_KEY")
  safe_dir "$START_PROJECT_KEY_ROOT"
  START_PROJECT_KEY_RESERVATION="$START_PROJECT_KEY_ROOT/.project-path"
  if [ -e "$START_PROJECT_KEY_RESERVATION" ] || [ -L "$START_PROJECT_KEY_RESERVATION" ]; then
    [ ! -L "$START_PROJECT_KEY_RESERVATION" ] || fail "project-key reservation is a symlink: $START_PROJECT_KEY_RESERVATION"
    [ "$(cat "$START_PROJECT_KEY_RESERVATION")" = "$SESSION_PROJECT_PATH" ] \
      || fail "project-key reservation belongs to another project"
  else
    printf '%s\n' "$SESSION_PROJECT_PATH" > "$START_PROJECT_KEY_RESERVATION"
    START_PROJECT_KEY_RESERVATION_CREATED=1
  fi
  rm -f -- "$PROJECT_KEY_LOCK/pid"
  rmdir "$PROJECT_KEY_LOCK"
  PROJECT_KEY_LOCK=
  if ! field_valid "$SESSION_PROJECT_NAME" || ! field_valid "$SESSION_PROJECT_PATH"; then
    fail "resolved project identity contains a line separator"
  fi
  SESSION_TOPIC=$topic
  SESSION_ID=$session_id
  SESSION_HEAD=$(git -C "$SESSION_PROJECT_PATH" rev-parse HEAD) \
    || fail "could not read the project's current commit"
  SESSION_STATUS_DIGEST=$(project_status_digest "$SESSION_PROJECT_PATH") \
    || fail "could not read the project's current status"
  SESSION_HOME=
  created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  SESSION_ACK_TOKEN=$(hash_text "$session_id|$SESSION_PROJECT_PATH|$created|$RANDOM")
  executor_ack_token=$SESSION_ACK_TOKEN

  line=$(alignment_config || true)
  if [ -n "$line" ]; then
    # shellcheck disable=SC2086
    set -- $line
    [ -n "$harness" ] || harness=${1:-}
    [ -n "$model" ] || model=${2:-}
    [ -n "$effort" ] || effort=${3:-}
  fi
  [ -n "$harness" ] || harness=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-harness.sh")
  [ -n "$harness" ] && [ "$harness" != unknown ] \
    || fail "no verified alignment harness is configured; set config/alignment-harness locally"
  if ! field_valid "$harness" || ! field_valid "$model" \
    || ! field_valid "$effort" || ! field_valid "$backend"; then
    fail "alignment runtime configuration contains a line separator"
  fi

  SESSION_HOME=$(cd "$FM_ROOT" && treehouse get --lease --lease-holder "alignment-$session_id") \
    || fail "treehouse could not lease an ephemeral alignment home"
  SESSION_HOME=$(CDPATH='' cd -- "$SESSION_HOME" 2>/dev/null && pwd -P) \
    || fail "treehouse returned an alignment home that cannot be canonicalized"
  START_HOME="$SESSION_HOME"
  START_HOME_LEASED=1
  firstmate_home_is_fresh "$SESSION_HOME"
  safe_dir "$SESSION_HOME/data"
  safe_dir "$SESSION_HOME/state"
  safe_dir "$SESSION_HOME/config"
  safe_dir "$SESSION_HOME/projects"
  [ ! -e "$SESSION_HOME/.fm-secondmate-home" ] \
    || fail "fresh alignment home already has a Secondmate identity marker"
  [ ! -e "$SESSION_HOME/.fm-secondmate-parent" ] \
    || fail "fresh alignment home already has a parent marker"
  printf '%s\n' "$session_id" > "$SESSION_HOME/.fm-secondmate-home"
  cat > "$SESSION_HOME/.fm-secondmate-parent" <<EOF
schema=fm-secondmate-parent.v1
route=local
parent_home=$FM_HOME
EOF
  mkdir -p "$SESSION_HOME/data/$session_id"
  cat > "$SESSION_HOME/data/$session_id/session.meta" <<EOF
schema=fm-alignment-session.v1
session_id=$session_id
project_name=$SESSION_PROJECT_NAME
project_path=$SESSION_PROJECT_PATH
topic=$topic
EOF
  write_canonical_context "$SESSION_HOME/data/alignment-context.md" "$SESSION_PROJECT_PATH"
  capture_hydration_snapshot \
    || fail "could not snapshot the project's hydrated knowledge and alignment inventory"
  write_session_charter "$SESSION_HOME/data/charter.md" "$SESSION_HOME/data/alignment-context.md"

  SESSION_RECORD=$(session_record_path "$session_id")
  cat > "$SESSION_RECORD" <<EOF
schema=fm-alignment-session.v1
session_id=$session_id
project_name=$SESSION_PROJECT_NAME
project_path=$SESSION_PROJECT_PATH
project_key=$SESSION_PROJECT_KEY
topic=$topic
home=$SESSION_HOME
status=starting
source=local
project_head=$SESSION_HEAD
project_status_digest=$SESSION_STATUS_DIGEST
hydration_project_head=$SESSION_HYDRATION_HEAD
hydration_project_status_digest=$SESSION_HYDRATION_STATUS_DIGEST
hydration_archive_inventory_digest=$SESSION_HYDRATION_ARCHIVE_DIGEST
executor_ack_token=$executor_ack_token
readiness=pending
reconciliation_pending=0
harness=$harness
model=${model:-default}
effort=${effort:-default}
created=$created
hydration_reconciled_at=$created
EOF

  spawn_args=("$session_id" "$SESSION_HOME" --secondmate --alignment-session --harness "$harness")
  [ -z "$model" ] || spawn_args+=(--model "$model")
  [ -z "$effort" ] || spawn_args+=(--effort "$effort")
  [ -z "$backend" ] || spawn_args+=(--backend "$backend")
  spawn_output=''
  spawn_status=0
  spawn_output=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" FM_STATE_OVERRIDE="$STATE" \
      FM_PROJECTS_OVERRIDE="$PROJECTS" FM_CONFIG_OVERRIDE="$CONFIG" \
      "$FM_ROOT/bin/fm-spawn.sh" "${spawn_args[@]}" 2>&1) || spawn_status=$?
  if [ "$spawn_status" -ne 0 ] || ! {
    [ -n "$spawn_output" ] \
      && printf '%s\n' "$spawn_output" | grep -Eq "^spawned $session_id harness=[^[:space:]]+ kind=secondmate .*worktree=" \
      && [ -f "$STATE/$session_id.meta" ] && [ ! -L "$STATE/$session_id.meta" ] \
      && [ "$(grep '^alignment_session=' "$STATE/$session_id.meta" | tail -1 | cut -d= -f2- || true)" = 1 ] \
      && [ "$(grep '^kind=' "$STATE/$session_id.meta" | tail -1 | cut -d= -f2- || true)" = secondmate ] \
      && [ "$(grep '^home=' "$STATE/$session_id.meta" | tail -1 | cut -d= -f2- || true)" = "$SESSION_HOME" ];
  }; then
    [ -z "$spawn_output" ] || printf '%s\n' "$spawn_output" >&2
    if [ -f "$STATE/$session_id.meta" ] && [ ! -L "$STATE/$session_id.meta" ]; then
      record_set "$STATE/$session_id.meta" alignment_abandon 1
      if ! FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" FM_STATE_OVERRIDE="$STATE" \
        FM_CONFIG_OVERRIDE="$CONFIG" "$FM_ROOT/bin/fm-teardown.sh" "$session_id" \
        >/dev/null 2>&1; then
        START_HOME_LEASED=0
        fail "alignment session $session_id launch failed and its endpoint could not be cleaned up"
      fi
    fi
    rm -f "$SESSION_RECORD"
    fail "alignment session $session_id launch or readiness acknowledgement failed"
  fi
  printf '%s\n' "$spawn_output"
  START_HOME_LEASED=0
  record_set "$SESSION_RECORD" launch_ack acknowledged
  record_set "$SESSION_RECORD" status running
  record_set "$SESSION_RECORD" readiness pending
  printf 'started alignment session %s project=%s topic=%s launch=acknowledged readiness=pending\n' \
    "$session_id" "$SESSION_PROJECT_NAME" "$SESSION_TOPIC"
  printf 'next: retain with fm-alignment-session.sh retain %s, then close it after the parent archive is durable\n' "$session_id"
}

validate_session_identity() {
  local report=$1
  "$SCRIPT_DIR/fm-alignment.sh" validate-report "$report" --complete \
    --session "$SESSION_ID" --project "$SESSION_PROJECT_NAME" >/dev/null \
    || fail "alignment report for $SESSION_ID is not a complete validated session report"
  grep -Fqx "Name: $SESSION_PROJECT_NAME" "$report" \
    || fail "alignment report does not identify project $SESSION_PROJECT_NAME"
  grep -Fqx "Path: $SESSION_PROJECT_PATH" "$report" \
    || fail "alignment report does not identify project path $SESSION_PROJECT_PATH"
  grep -Fqx "Session: $SESSION_ID" "$report" \
    || fail "alignment report does not identify session $SESSION_ID"
  grep -Fqx "Topic: $SESSION_TOPIC" "$report" \
    || fail "alignment report does not identify its recorded topic"
}

retain_abandoned_report() {
  local report archive_dir archive_tmp archive_meta source_report tmp
  report="$SESSION_HOME/data/$SESSION_ID/report.md"
  [ -s "$report" ] && [ ! -L "$report" ] || return 0
  archive_dir=$(archive_dir_for "$SESSION_PROJECT_KEY" "$SESSION_ID")
  archive_path_safe "$archive_dir"
  safe_dir "$(archive_root_for "$SESSION_PROJECT_KEY")"
  if [ -e "$archive_dir" ]; then
    [ -d "$archive_dir" ] && [ ! -L "$archive_dir" ] \
      || fail "abandoned alignment archive is unsafe: $archive_dir"
    archive_meta="$archive_dir/metadata"
    source_report="$archive_dir/report.md"
    [ -f "$archive_meta" ] && [ ! -L "$archive_meta" ] \
      || fail "abandoned alignment archive is incomplete: $archive_dir"
    [ "$(read_record_field "$archive_meta" project_path || true)" = "$SESSION_PROJECT_PATH" ] \
      || fail "abandoned alignment archive belongs to another project"
    [ "$(read_record_field "$archive_meta" status || true)" = abandoned ] \
      || fail "alignment $SESSION_ID already has a completed archive; retain the complete report instead"
    if [ ! -f "$source_report" ] || [ -L "$source_report" ] \
      || ! cmp -s "$report" "$source_report"; then
      fail "alignment $SESSION_ID already has different abandoned evidence"
    fi
  else
    archive_tmp="$(dirname "$archive_dir")/.$SESSION_ID.tmp"
    archive_path_safe "$archive_tmp"
    if [ -e "$archive_tmp" ]; then
      [ -d "$archive_tmp" ] && [ ! -L "$archive_tmp" ] \
        || fail "abandoned alignment staging path is unsafe: $archive_tmp"
      source_report="$archive_tmp/report.md"
      tmp="$archive_tmp/metadata"
      [ -f "$source_report" ] && [ ! -L "$source_report" ] \
        || fail "abandoned alignment staging path is incomplete: $archive_tmp"
      [ -f "$tmp" ] && [ ! -L "$tmp" ] \
        || fail "abandoned alignment staging path is incomplete: $archive_tmp"
      [ "$(read_record_field "$tmp" status || true)" = abandoned ] \
        || fail "abandoned alignment staging path has an invalid status"
      [ "$(read_record_field "$tmp" report_digest || true)" = "$(file_content_digest "$source_report")" ] \
        || fail "abandoned alignment staging path has an invalid report digest"
    else
      mkdir "$archive_tmp"
      RETENTION_TMP="$archive_tmp"
      source_report="$archive_tmp/report.md"
      cp -- "$report" "$source_report"
      tmp="$archive_tmp/metadata"
      {
        printf 'schema=fm-alignment-archive.v1\n'
        printf 'project_name=%s\nproject_path=%s\nproject_key=%s\n' \
          "$SESSION_PROJECT_NAME" "$SESSION_PROJECT_PATH" "$SESSION_PROJECT_KEY"
        printf 'session_id=%s\ntopic=%s\nsource=local\nstatus=abandoned\nreport=report.md\n' \
          "$SESSION_ID" "$SESSION_TOPIC"
        printf 'supersedes=\noutcome=neither\nreport_digest=%s\nretained=%s\n' \
          "$(file_content_digest "$source_report")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      } > "$tmp"
    fi
    [ ! -e "$archive_dir" ] && [ ! -L "$archive_dir" ] \
      || fail "alignment archive directory appeared during abandonment: $archive_dir"
    mv -- "$archive_tmp" "$archive_dir"
    RETENTION_TMP=
  fi
  record_set "$SESSION_RECORD" abandoned_archive "$archive_dir/report.md"
  record_set "$SESSION_RECORD" archive "$archive_dir/report.md"
  record_set "$SESSION_RECORD" outcome neither
  printf 'retained abandoned alignment evidence %s\n' "$archive_dir/report.md"
}

retain_session() {
  local current_id report='' supersedes='' outcome='' outcome_set=0 archive_dir archive_meta tmp source_report prior_archive expected_key archive_tmp staged_outcome pending_outcome staged_report_digest
  local -a superseded_ids=()
  [ "$#" -ge 1 ] || usage
  require_parent_home
  current_id=$1
  id_valid "$current_id" || fail "invalid alignment session id: $current_id"
  mkdir -p "$STATE"
  lock_dir "$STATE/.alignment-session-$current_id.lock"
  RETENTION_TMP=
  retention_cleanup() {
    local status=$?
    [ -z "$RETENTION_TMP" ] || rm -rf -- "$RETENTION_TMP"
    rmdir "$ALIGNMENT_LOCK" 2>/dev/null || true
    return "$status"
  }
  trap retention_cleanup EXIT
  session_load "$current_id"
  outcome=$(read_record_field "$SESSION_RECORD" outcome || true)
  expected_key=$SESSION_PROJECT_KEY
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --supersedes) [ "$#" -ge 2 ] || usage; supersedes=$2; shift 2 ;;
      --supersedes=*) supersedes=${1#--supersedes=}; shift ;;
      --outcome) [ "$#" -ge 2 ] || usage; outcome=$2; outcome_set=1; shift 2 ;;
      --outcome=*) outcome=${1#--outcome=}; outcome_set=1; shift ;;
      -*) usage ;;
      *) [ -z "$report" ] || usage; report=$1; shift ;;
    esac
  done
  [ -n "$outcome" ] || outcome=neither
  case "$outcome" in implementation|knowledge-only|both|neither) ;; *) fail "outcome must be implementation, knowledge-only, both, or neither" ;; esac
  [ "$SESSION_STATUS" != closed ] || fail "alignment session $SESSION_ID is already closed"
  [ -n "$report" ] || report="$SESSION_HOME/data/$SESSION_ID/report.md"
  report=$(CDPATH='' cd -- "$(dirname "$report")" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "$report")") \
    || fail "alignment report path cannot be resolved"
  [ -f "$report" ] && [ ! -L "$report" ] || fail "alignment report is missing or unsafe: $report"
  case "$report" in
    "$SESSION_HOME/data/$SESSION_ID/report.md") ;;
    *) fail "alignment report must come from the isolated session's report path" ;;
  esac
  validate_session_identity "$report"
  semantic_readiness_valid \
    || fail "alignment session $SESSION_ID requires executor-authenticated semantic readiness acknowledgement before retention"
  hydration_snapshot_valid \
    || fail "project or parent alignment inventory changed since reconciliation; run reconcile before retaining the report"
  archive_dir=$(archive_dir_for "$SESSION_PROJECT_KEY" "$SESSION_ID")
  archive_path_safe "$archive_dir"
  safe_dir "$(archive_root_for "$SESSION_PROJECT_KEY")"
  [ ! -e "$archive_dir" ] || [ ! -L "$archive_dir" ] \
    || fail "alignment archive directory is a symlink: $archive_dir"
  if [ -e "$archive_dir" ]; then
    archive_meta="$archive_dir/metadata"
    [ -f "$archive_meta" ] && [ ! -L "$archive_meta" ] \
      || fail "alignment archive directory is incomplete: $archive_dir"
    [ "$(read_record_field "$archive_meta" project_path || true)" = "$SESSION_PROJECT_PATH" ] \
      || fail "alignment archive belongs to another project"
    cmp -s "$report" "$archive_dir/report.md" \
      || fail "alignment session $SESSION_ID already has a different retained report"
    SESSION_ARCHIVE="$archive_dir/report.md"
    pending_outcome=$(read_record_field "$SESSION_RECORD" retain_pending_outcome || true)
    if [ "$outcome_set" -eq 0 ]; then
      case "$pending_outcome" in
        implementation|knowledge-only|both|neither) outcome=$pending_outcome ;;
        *) outcome=$(read_record_field "$archive_meta" outcome || true); [ -n "$outcome" ] || outcome=neither ;;
      esac
    fi
    record_set "$SESSION_RECORD" retain_pending_outcome "$outcome"
    record_set "$archive_meta" outcome "$outcome"
    record_set "$SESSION_RECORD" status completed
    record_set "$SESSION_RECORD" archive "$archive_dir/report.md"
    record_set "$SESSION_RECORD" outcome "$outcome"
    retained_archive_valid \
      || fail "alignment archive for $SESSION_ID is incomplete or belongs to another project"
    record_remove "$SESSION_RECORD" retain_pending_outcome
    printf 'retained alignment report %s\n' "$archive_dir/report.md"
    return 0
  fi
  archive_tmp="$(dirname "$archive_dir")/.$current_id.tmp"
  archive_path_safe "$archive_tmp"
  if [ -e "$archive_tmp" ]; then
    [ -d "$archive_tmp" ] && [ ! -L "$archive_tmp" ] \
      || fail "alignment archive staging path is unsafe: $archive_tmp"
    source_report="$archive_tmp/report.md"
    tmp="$archive_tmp/metadata"
    [ -f "$source_report" ] && [ ! -L "$source_report" ] \
      || fail "alignment archive staging path is incomplete: $archive_tmp"
    [ -f "$tmp" ] && [ ! -L "$tmp" ] \
      || fail "alignment archive staging path is incomplete: $archive_tmp"
    SESSION_ARCHIVE="$source_report"
    validate_session_identity "$source_report"
    [ "$(read_record_field "$tmp" session_id || true)" = "$SESSION_ID" ] \
      || fail "alignment archive staging path has the wrong session"
    [ "$(read_record_field "$tmp" project_name || true)" = "$SESSION_PROJECT_NAME" ] \
      || fail "alignment archive staging path has the wrong project name"
    [ "$(read_record_field "$tmp" project_path || true)" = "$SESSION_PROJECT_PATH" ] \
      || fail "alignment archive staging path has the wrong project"
    [ "$(read_record_field "$tmp" project_key || true)" = "$SESSION_PROJECT_KEY" ] \
      || fail "alignment archive staging path has the wrong archive key"
    [ "$(read_record_field "$tmp" status || true)" = completed ] \
      || fail "alignment archive staging path is not complete"
    [ "$(read_record_field "$tmp" report || true)" = report.md ] \
      || fail "alignment archive staging path has an invalid report pointer"
    staged_report_digest=$(read_record_field "$tmp" report_digest || true)
    [ -n "$staged_report_digest" ] && [ "$staged_report_digest" = "$(file_content_digest "$source_report")" ] \
      || fail "alignment archive staging path has no valid report digest"
    staged_outcome=$(read_record_field "$tmp" outcome || true)
    case "$staged_outcome" in
      implementation|knowledge-only|both|neither) ;; *) fail "alignment archive staging path has an invalid outcome" ;;
    esac
    if [ "$outcome_set" -eq 1 ] && [ "$staged_outcome" != "$outcome" ]; then
      fail "alignment archive staging path has a different outcome"
    fi
    outcome="$staged_outcome"
  else
    mkdir "$archive_tmp"
    RETENTION_TMP="$archive_tmp"
    source_report="$archive_tmp/report.md"
    cp -- "$report" "$source_report"
    validate_session_identity "$source_report"
    tmp="$archive_tmp/metadata"
    while IFS= read -r id; do
    [ -n "$id" ] || continue
    id_valid "$id" || fail "invalid superseded alignment id: $id"
    superseded_ids+=("$id")
    session_load "$id"
    [ "$SESSION_PROJECT_KEY" = "$expected_key" ] \
      || fail "superseded alignment $id belongs to another project"
    prior_archive=$(read_record_field "$SESSION_RECORD" archive || true)
    [ -n "$prior_archive" ] && [ -f "$prior_archive" ] && [ ! -L "$prior_archive" ] \
      || fail "superseded alignment $id has no retained historical report"
  done <<EOF
$(printf '%s' "$supersedes" | tr ',' '\n')
EOF
  session_load "$current_id"
  {
    printf 'schema=fm-alignment-archive.v1\n'
    printf 'project_name=%s\nproject_path=%s\nproject_key=%s\n' \
      "$SESSION_PROJECT_NAME" "$SESSION_PROJECT_PATH" "$SESSION_PROJECT_KEY"
    printf 'session_id=%s\ntopic=%s\nsource=local\nstatus=completed\nreport=report.md\n' \
      "$SESSION_ID" "$SESSION_TOPIC"
    printf 'supersedes=%s\noutcome=%s\nreport_digest=%s\nretained=%s\n' \
      "$(IFS=,; printf '%s' "${superseded_ids[*]:-}")" "$outcome" \
      "$(file_content_digest "$source_report")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$tmp"
  fi
  [ ! -e "$archive_dir" ] && [ ! -L "$archive_dir" ] \
    || fail "alignment archive directory appeared during retention: $archive_dir"
  archive_path_safe "$archive_dir"
  mv -- "$archive_tmp" "$archive_dir"
  RETENTION_TMP=
  record_set "$SESSION_RECORD" status completed
  record_set "$SESSION_RECORD" archive "$archive_dir/report.md"
  record_set "$SESSION_RECORD" outcome "$outcome"
  printf 'retained alignment report %s\n' "$archive_dir/report.md"
}

inventory_session() {
  local project_input=$1 project path key root meta sid status topic supersedes
  local meta_count=0
  require_parent_home
  project=$(project_path_resolve "$project_input")
  path=$(project_name_for_path "$project")
  key=$(project_key_for_path "$project")
  root=$(archive_root_for "$key")
  archive_path_safe "$root"
  printf 'project=%s\nproject_path=%s\n' "$path" "$project"
  [ ! -L "$root" ] || fail "alignment archive root is a symlink: $root"
  [ -d "$root" ] || {
    printf 'artifacts=0\n'
    return 0
  }
  while IFS= read -r meta; do
    [ -n "$meta" ] || continue
    published_archive_metadata_valid "$meta" "$project" "$key" || continue
    sid=$(read_record_field "$meta" session_id || true)
    status=$(read_record_field "$meta" status || true)
    topic=$(read_record_field "$meta" topic || true)
    supersedes=$(read_record_field "$meta" supersedes || true)
    printf 'session=%s\ttopic=%s\tstatus=%s\tsource=local\tsupersedes=%s\treport=%s\tretrieve=bin/fm-alignment-session.sh retrieve %q %q --archive-home %q --archive-data %q\n' \
      "$sid" "$topic" "$status" "$supersedes" "$(archive_report_pointer "$key" "$sid")" "$project" "$sid" "$FM_HOME" "$DATA"
    meta_count=$((meta_count + 1))
  done < <(find "$root" -mindepth 2 -maxdepth 2 -type f -name metadata \
    ! -path "$root/.*.tmp/metadata" -print | LC_ALL=C sort)
  printf 'artifacts=%s\n' "$meta_count"
}

retrieve_session() {
  local project_input sid project project_name key meta archive report topic outcome archive_home='' archive_data='' archive_data_set=0
  [ "$#" -ge 2 ] || usage
  project_input=$1
  sid=$2
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --archive-home) [ "$#" -ge 2 ] || usage; archive_home=$2; shift 2 ;;
      --archive-home=*) archive_home=${1#--archive-home=}; shift ;;
      --archive-data) [ "$#" -ge 2 ] || usage; archive_data=$2; archive_data_set=1; shift 2 ;;
      --archive-data=*) archive_data=${1#--archive-data=}; archive_data_set=1; shift ;;
      *) usage ;;
    esac
  done
  require_parent_home
  project=$(project_path_resolve "$project_input")
  if [ -n "$archive_home" ]; then
    home_is_safe "$archive_home" || fail "archive home is missing or unsafe: $archive_home"
    [ "$archive_data_set" -eq 1 ] || archive_data="$archive_home/data"
  else
    [ "$archive_data_set" -eq 0 ] || fail "--archive-data requires --archive-home"
    archive_data=$DATA
  fi
  archive_path_safe "$archive_data"
  [ -d "$archive_data" ] && [ ! -L "$archive_data" ] \
    || fail "archive data directory is missing or unsafe: $archive_data"
  key=$(project_key_for_path "$project" "$archive_data")
  id_valid "$sid" || fail "invalid alignment session id: $sid"
  meta="$archive_data/alignments/$key/$sid/metadata"
  archive_path_safe "$meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || fail "no retained alignment $sid for project $project"
  project_name=$(read_record_field "$meta" project_name || true)
  [ "$project_name" = "$(project_name_for_path "$project")" ] \
    || fail "alignment $sid has an invalid project identity"
  [ "$(read_record_field "$meta" project_path || true)" = "$project" ] \
    || fail "alignment $sid is associated with another project"
  [ "$(read_record_field "$meta" project_key || true)" = "$key" ] \
    || fail "alignment $sid has an invalid archive key"
  [ "$(read_record_field "$meta" session_id || true)" = "$sid" ] \
    || fail "alignment $sid has an invalid session identity"
  case "$(read_record_field "$meta" status || true)" in
    completed|abandoned) ;;
    *) fail "alignment $sid is not completed or explicitly abandoned" ;;
  esac
  outcome=$(read_record_field "$meta" outcome || true)
  case "$outcome" in
    implementation|knowledge-only|both|neither) ;;
    *) fail "alignment $sid has an invalid outcome" ;;
  esac
  topic=$(read_record_field "$meta" topic || true)
  [ -n "$topic" ] || fail "alignment $sid has no topic"
  [ "$(read_record_field "$meta" report || true)" = report.md ] \
    || fail "alignment $sid has an invalid report pointer"
  archive="$archive_data/alignments/$key/$sid"
  archive_path_safe "$archive"
  report="$archive/report.md"
  [ -f "$report" ] && [ ! -L "$report" ] || fail "retained alignment $sid has no report"
  [ "$(read_record_field "$meta" report_digest || true)" = "$(file_content_digest "$report")" ] \
    || fail "retained alignment $sid has an invalid report (content digest changed)"
  if [ "$(read_record_field "$meta" status || true)" = completed ]; then
    "$SCRIPT_DIR/fm-alignment.sh" validate-report "$report" --complete \
      --session "$sid" --project "$project_name" >/dev/null \
      || fail "retained alignment $sid has an invalid report"
    grep -Fqx "Path: $project" "$report" \
      || fail "retained alignment $sid report has an invalid project path"
    grep -Fqx "Topic: $topic" "$report" \
      || fail "retained alignment $sid report has an invalid topic"
  else
    printf 'Historical alignment %s was explicitly abandoned and is not implementation-ready.\n' "$sid" >&2
  fi
  cat "$report"
}

promote_session() {
  local task_id='' mode='' yolo='' purpose='' purpose_set=0 report brief outcome=neither tmp source_text
  [ "$#" -ge 1 ] || usage
  require_parent_home
  session_load "$1"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mode) [ "$#" -ge 2 ] || usage; mode=$2; shift 2 ;;
      --mode=*) mode=${1#--mode=}; shift ;;
      --yolo) [ "$#" -ge 2 ] || usage; yolo=$2; shift 2 ;;
      --yolo=*) yolo=${1#--yolo=}; shift ;;
      --purpose) [ "$#" -ge 2 ] || usage; purpose=$2; purpose_set=1; shift 2 ;;
      --purpose=*) purpose=${1#--purpose=}; purpose_set=1; shift ;;
      --task-id) [ "$#" -ge 2 ] || usage; task_id=$2; shift 2 ;;
      --task-id=*) task_id=${1#--task-id=}; shift ;;
      *) usage ;;
    esac
  done
  case "$mode" in no-mistakes|direct-PR|local-only) ;; *) fail "promotion requires --mode no-mistakes, direct-PR, or local-only" ;; esac
  case "$yolo" in on|off) ;; *) fail "promotion requires --yolo on or off" ;; esac
  if [ "$purpose_set" -eq 1 ]; then
    case "$purpose" in implementation|knowledge-only|both) ;; *) fail "purpose must be implementation, knowledge-only, or both" ;; esac
  fi
  [ "$SESSION_STATUS" = completed ] || fail "alignment $SESSION_ID must be retained before promotion"
  retained_archive_valid \
    || fail "alignment $SESSION_ID has no valid parent-owned archive"
  semantic_readiness_valid \
    || fail "alignment $SESSION_ID has no executor-authenticated semantic readiness acknowledgement"
  hydration_snapshot_valid \
    || fail "project or parent alignment inventory changed since alignment hydration; start a revised session and explicitly supersede the immutable outcome"
  outcome=$(read_record_field "$SESSION_RECORD" outcome || true)
  [ -n "$outcome" ] || outcome=neither
  if [ "$purpose_set" -eq 0 ]; then
    case "$outcome" in
      implementation|knowledge-only|both) purpose=$outcome ;;
      neither) fail "alignment $SESSION_ID has outcome neither; no downstream promotion is authorized" ;;
    esac
  else
    case "$outcome:$purpose" in
      implementation:implementation|knowledge-only:knowledge-only|both:implementation|both:knowledge-only|both:both) ;;
      *) fail "alignment $SESSION_ID outcome $outcome does not authorize $purpose promotion" ;;
    esac
  fi
  [ -n "$task_id" ] || task_id="${SESSION_ID}-followup"
  id_valid "$task_id" || fail "invalid promotion task id: $task_id"
  [ ! -e "$DATA/$task_id/brief.md" ] || fail "promotion task already exists: $task_id"
  FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" FM_STATE_OVERRIDE="$STATE" \
    "$FM_ROOT/bin/fm-brief.sh" "$task_id" "$SESSION_PROJECT_NAME" --mode "$mode" \
    >/dev/null
  brief="$DATA/$task_id/brief.md"
  tmp="$brief.tmp.$$"
  awk -v task="Implement the accepted alignment outcome for project $SESSION_PROJECT_NAME and purpose $purpose.\nUse the retained report only as historical rationale and promote durable-knowledge candidates through the normal project documentation delivery path.\nDo not reinterpret settled decisions or let a captain-facing session edit project documentation directly." \
    '!done && $0 == "{TASK}" { n=split(task, lines, "\\n"); for (i=1; i<=n; i++) print lines[i]; done=1; next } { print }' \
    "$brief" > "$tmp"
  mv -f -- "$tmp" "$brief"
  sed "s/^Alignment contract: unclassified$/Alignment contract: complete/" "$brief" > "$tmp"
  awk -v source="Alignment source: $(archive_report_pointer "$SESSION_PROJECT_KEY" "$SESSION_ID")" \
    '!done && $0 == "Alignment contract: complete" { print; print source; done=1; next } { print }' \
    "$tmp" > "$brief.new"
  mv -f -- "$brief.new" "$brief"
  source_text="$brief.outcome.$$"
  awk '/^## Project identity$/ { found=1 } found { print }' "$SESSION_ARCHIVE" > "$source_text"
  awk -v outcome_file="$source_text" \
    '/^# Setup$/ && !inserted { print "# Alignment outcome"; while ((getline line < outcome_file) > 0) print line; close(outcome_file); print ""; inserted=1 } { print }' \
    "$brief" > "$tmp"
  mv -f -- "$tmp" "$brief"
  rm -f -- "$source_text"
  "$SCRIPT_DIR/fm-alignment.sh" check "$brief" >/dev/null \
    || fail "compiled promotion brief did not pass the alignment barrier"
  record_set "$SESSION_RECORD" followup_task "$task_id"
  printf 'created ordinary project follow-up %s at %s\n' "$task_id" "$brief"
}

close_session() {
  local abandon=0 id=${1:-}
  require_parent_home
  [ -n "$id" ] || usage
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in --abandon) abandon=1; shift ;; *) usage ;; esac
  done
  id_valid "$id" || fail "invalid alignment session id: $id"
  mkdir -p "$STATE"
  lock_dir "$STATE/.alignment-session-$id.lock"
  session_load "$id"
  [ "$SESSION_STATUS" != closed ] || { printf 'alignment session %s is already closed\n' "$id"; return 0; }
  if [ "$SESSION_STATUS" = completed ]; then
    retained_archive_valid \
      || fail "alignment $id is marked completed without a valid parent-owned archive"
  elif [ "$abandon" -eq 0 ]; then
    fail "alignment $id has no retained report; use --abandon to close it explicitly"
  elif [ -s "$SESSION_HOME/data/$id/report.md" ] && [ ! -L "$SESSION_HOME/data/$id/report.md" ]; then
    if "$SCRIPT_DIR/fm-alignment.sh" validate-report "$SESSION_HOME/data/$id/report.md" \
      --complete --session "$id" --project "$SESSION_PROJECT_NAME" >/dev/null 2>&1; then
      fail "alignment $id has a complete report that must be retained before abandonment"
    fi
    retain_abandoned_report
  fi
  if [ "$abandon" -eq 1 ] && [ "$SESSION_STATUS" != completed ]; then
    [ -f "$STATE/$id.meta" ] && [ ! -L "$STATE/$id.meta" ] \
      || fail "alignment $id has no live runtime record to close"
    record_set "$STATE/$id.meta" alignment_abandon 1
  fi
  FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" FM_STATE_OVERRIDE="$STATE" \
    FM_CONFIG_OVERRIDE="$CONFIG" "$FM_ROOT/bin/fm-teardown.sh" "$id"
  [ ! -e "$SESSION_HOME" ] || fail "alignment home remains after cleanup; retained session record for retry"
  record_set "$SESSION_RECORD" status closed
  [ "$abandon" -eq 0 ] || record_set "$SESSION_RECORD" abandoned 1
  record_set "$SESSION_RECORD" closed "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'closed alignment session %s\n' "$id"
}

case "$COMMAND" in
  start|request|start-session) start_session "$@" ;;
  retain|archive) retain_session "$@" ;;
  inventory|list) [ "$#" -eq 1 ] || usage; inventory_session "$1" ;;
  retrieve|show) retrieve_session "$@" ;;
  reconcile|refresh) reconcile_session "$@" ;;
  acknowledge|ack) acknowledge_session "$@" ;;
  promote|compile) promote_session "$@" ;;
  close|cancel) close_session "$@" ;;
  *) usage ;;
esac
