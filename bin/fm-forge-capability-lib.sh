#!/usr/bin/env bash
# Resolve the forge provider and write capability required by a project.
#
# This file is the single owner of machine-local forge capability policy.
# Project origins remain forge-neutral for cloning and fetching, while a
# provider-specific review or merge operation must name the provider whose
# credentials and CLI will perform it.
#
# Optional config/forge-capabilities records one host per line:
#   <host> <github|gitlab> <read-only|read-write>
#
# The file is local and gitignored. Known hosted forge hosts are inferred when
# no record exists and default to read-write for backward compatibility. An
# arbitrary self-hosted host needs a record so its provider is unambiguous.
# A read-only record deliberately suppresses write prerequisites, but never
# changes a project's registered delivery mode or permits a forge write.
set -u

FM_FORGE_CAPABILITY_FILE=${FM_FORGE_CAPABILITY_FILE:-${FM_CONFIG_OVERRIDE:-${FM_HOME:-.}/config}/forge-capabilities}
FM_FORGE_CAPABILITY_ERROR=
FM_FORGE_PROVIDER=
FM_FORGE_HOST=
FM_FORGE_CAPABILITY=
FM_FORGE_ORIGIN=
FM_FORGE_PROJECT=
FM_FORGE_MODE=

# Bash 3.2 has no case-conversion parameter expansion. Keep provider
# resolution usable on the system Bash shipped by supported macOS releases.
fm_forge_lower_ascii() {
  printf '%s' "${1-}" | LC_ALL=C tr '[:upper:]' '[:lower:]'
}

fm_forge_capability_host_valid() {
  local host=${1-}
  local LC_ALL=C
  [ -n "$host" ] && [ "${#host}" -le 253 ] || return 1
  case "$host" in
    *[!A-Za-z0-9._-]*|.*|*.|*..*) return 1 ;;
  esac
  return 0
}

fm_forge_capability_validate() {
  local file=${1:-$FM_FORGE_CAPABILITY_FILE} line number host provider access extra
  FM_FORGE_CAPABILITY_ERROR=
  [ -e "$file" ] || [ -L "$file" ] || return 0
  [ -f "$file" ] && [ ! -L "$file" ] || {
    FM_FORGE_CAPABILITY_ERROR="config/forge-capabilities is not a regular file"
    return 1
  }
  number=0
  local -a seen_hosts=()
  local normalized_host
  while IFS= read -r line || [ -n "$line" ]; do
    number=$((number + 1))
    case "$line" in
      ''|'#'*) continue ;;
    esac
    host=
    provider=
    access=
    extra=
    read -r host provider access extra <<< "$line"
    if [ -n "$extra" ] || [ -z "$host" ] || [ -z "$provider" ] || [ -z "$access" ]; then
      FM_FORGE_CAPABILITY_ERROR="line $number must contain: <host> <github|gitlab> <read-only|read-write>"
      return 1
    fi
    if ! fm_forge_capability_host_valid "$host"; then
      FM_FORGE_CAPABILITY_ERROR="line $number has an invalid host"
      return 1
    fi
    case "$provider" in github|gitlab) ;; *)
      FM_FORGE_CAPABILITY_ERROR="line $number has an unsupported provider '$provider'"
      return 1
      ;;
    esac
    case "$access" in read-only|read-write) ;; *)
      FM_FORGE_CAPABILITY_ERROR="line $number has an unsupported capability '$access'"
      return 1
      ;;
    esac
    normalized_host=$(fm_forge_lower_ascii "$host")
    case " ${seen_hosts[*]} " in
      *" $normalized_host "*)
        FM_FORGE_CAPABILITY_ERROR="line $number repeats host '$host'"
        return 1
        ;;
    esac
    seen_hosts+=("$normalized_host")
  done < "$file" || {
    FM_FORGE_CAPABILITY_ERROR="could not read config/forge-capabilities"
    return 1
  }
  return 0
}

fm_forge_origin_host() {
  local raw=${1-} rest authority hostpart host normalized_host
  raw=${raw#"${raw%%[![:space:]]*}"}
  raw=${raw%"${raw##*[![:space:]]}"}
  [ -n "$raw" ] || return 1
  case "$raw" in
    file://*|/*) return 1 ;;
    *://*)
      rest=${raw#*://}
      authority=${rest%%/*}
      [ "$authority" != "$rest" ] || return 1
      authority=${authority##*@}
      case "$authority" in
        \[*\]*)
          hostpart=${authority%%']'*}']'
          host=${hostpart#'['}
          host=${host%']'}
          ;;
        *) host=${authority%%:*} ;;
      esac
      ;;
    *:*)
      rest=${raw%%/*}
      case "$rest" in *'@'*) rest=${rest##*@} ;; esac
      host=${rest%%:*}
      ;;
    *) return 1 ;;
  esac
  [ -n "$host" ] || return 1
  normalized_host=$(fm_forge_lower_ascii "$host")
  printf '%s\n' "$normalized_host"
}

fm_forge_config_for_host() { # <host>; prints "provider capability" or nothing
  local host=${1-} file=${2:-$FM_FORGE_CAPABILITY_FILE} line configured_host provider access
  host=$(fm_forge_lower_ascii "$host")
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    read -r configured_host provider access _ <<< "$line"
    configured_host=$(fm_forge_lower_ascii "$configured_host")
    if [ "$configured_host" = "$host" ]; then
      printf '%s %s\n' "$provider" "$access"
      return 0
    fi
  done < "$file"
}

fm_forge_cli_config_has_host() { # <gh|glab> <host>
  local cli=$1 host dir file
  host=$(fm_forge_lower_ascii "${2-}")
  case "$cli" in
    gh)
      dir=${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-${HOME:-}/.config}/gh}
      file="$dir/hosts.yml"
      [ -f "$file" ] || return 1
      awk -v want="$host" '
        /^[^[:space:]#][^:]*:/ {
          key=$0; sub(/:.*/, "", key); gsub(/[[:space:]]/, "", key)
          if (tolower(key) == tolower(want)) found=1
        }
        END { exit found ? 0 : 1 }
      ' "$file"
      ;;
    glab)
      dir=${GLAB_CONFIG_DIR:-${XDG_CONFIG_HOME:-${HOME:-}/.config}/glab-cli}
      file="$dir/config.yml"
      [ -f "$file" ] || return 1
      awk -v want="$host" '
        /^[[:space:]]+[^[:space:]#][^:]*:/ {
          key=$0; sub(/^[[:space:]]+/, "", key); sub(/:.*/, "", key); gsub(/[[:space:]]/, "", key)
          if (tolower(key) == tolower(want)) found=1
        }
        /api_host:[[:space:]]*/ {
          value=$0; sub(/^[^:]*:[[:space:]]*/, "", value); sub(/[[:space:]]+#.*/, "", value)
          sub(/^https?:\\/\\//, "", value); sub(/\\/.*/, "", value); sub(/:.*/, "", value)
          if (tolower(value) == tolower(want)) found=1
        }
        END { exit found ? 0 : 1 }
      ' "$file"
      ;;
    *) return 1 ;;
  esac
}

fm_forge_provider_for_host() { # <host>; sets FM_FORGE_PROVIDER
  local host configured github_known=0 gitlab_known=0
  host=$(fm_forge_lower_ascii "${1-}")
  FM_FORGE_PROVIDER=
  configured=$(fm_forge_config_for_host "$host" || true)
  if [ -n "$configured" ]; then
    FM_FORGE_PROVIDER=${configured%% *}
    printf '%s\n' "$FM_FORGE_PROVIDER"
    return 0
  fi
  case "$host" in
    github.com|*.github.com) github_known=1 ;;
    gitlab.com|*.gitlab.com|gitlab.*) gitlab_known=1 ;;
  esac
  fm_forge_cli_config_has_host gh "$host" 2>/dev/null && github_known=1 || true
  fm_forge_cli_config_has_host glab "$host" 2>/dev/null && gitlab_known=1 || true
  if [ "$github_known" -eq 1 ] && [ "$gitlab_known" -eq 1 ]; then
    FM_FORGE_CAPABILITY_ERROR="host '$host' is configured for both GitHub and GitLab; add one explicit provider record to config/forge-capabilities"
    return 1
  fi
  if [ "$github_known" -eq 1 ]; then
    FM_FORGE_PROVIDER=github
  elif [ "$gitlab_known" -eq 1 ]; then
    FM_FORGE_PROVIDER=gitlab
  fi
  [ -n "$FM_FORGE_PROVIDER" ] || return 1
  printf '%s\n' "$FM_FORGE_PROVIDER"
}

fm_forge_context_for_origin() { # <origin>; sets FM_FORGE_*
  local origin=${1-} configured host provider capability
  fm_forge_capability_validate || return 1
  # shellcheck disable=SC2034 # exported context for callers of this sourced library
  FM_FORGE_ORIGIN=$origin
  FM_FORGE_HOST=
  FM_FORGE_PROVIDER=
  FM_FORGE_CAPABILITY=
  host=$(fm_forge_origin_host "$origin" 2>/dev/null || true)
  [ -n "$host" ] || {
    FM_FORGE_CAPABILITY_ERROR="origin has no supported forge host"
    return 1
  }
  FM_FORGE_HOST=$host
  configured=$(fm_forge_config_for_host "$host" || true)
  if [ -n "$configured" ]; then
    provider=${configured%% *}
    capability=${configured#* }
    case "$host:$provider" in
      github.com:gitlab|*.github.com:gitlab|gitlab.com:github|*.gitlab.com:github|gitlab.*:github)
        FM_FORGE_CAPABILITY_ERROR="host '$host' is a known $([[ "$host" == *github.com ]] && printf GitHub || printf GitLab) host but config selects $provider"
        return 1
        ;;
    esac
  else
    provider=$(fm_forge_provider_for_host "$host" 2>/dev/null || true)
    capability=
    if [ -z "$provider" ] && [[ "$origin" == */-/merge_requests/* ]]; then
      # A canonical GitLab MR URL carries an unambiguous provider marker even
      # when its self-hosted hostname is intentionally opaque.
      provider=gitlab
    fi
    [ -n "$provider" ] || {
      [ -n "$FM_FORGE_CAPABILITY_ERROR" ] || FM_FORGE_CAPABILITY_ERROR="cannot identify forge provider for host '$host'; add '<host> <github|gitlab> <read-only|read-write>' to config/forge-capabilities"
      return 1
    }
    capability=read-write
  fi
  FM_FORGE_PROVIDER=$provider
  FM_FORGE_CAPABILITY=$capability
  return 0
}

fm_forge_project_origin() { # <project-dir>; prints the configured origin before URL rewriting
  local project=$1 origin
  origin=$(git -C "$project" config --get remote.origin.url 2>/dev/null || true)
  [ -n "$origin" ] || origin=$(git -C "$project" remote get-url origin 2>/dev/null || true)
  [ -n "$origin" ] || return 1
  printf '%s\n' "$origin"
}

fm_forge_context_for_project() { # <project-dir> <mode>
  local project=$1 mode=${2:-} origin
  # shellcheck disable=SC2034 # exported context for callers of this sourced library
  FM_FORGE_PROJECT=$project
  # shellcheck disable=SC2034 # exported context for callers of this sourced library
  FM_FORGE_MODE=$mode
  origin=$(fm_forge_project_origin "$project" || true)
  [ -n "$origin" ] || {
    FM_FORGE_CAPABILITY_ERROR="project '$project' has no origin remote"
    return 1
  }
  fm_forge_context_for_origin "$origin"
}

fm_forge_origin_path() { # <origin>; prints project path without host or .git
  local raw=${1-} rest authority path
  raw=${raw#"${raw%%[![:space:]]*}"}
  raw=${raw%"${raw##*[![:space:]]}"}
  case "$raw" in
    *://*)
      rest=${raw#*://}
      authority=${rest%%/*}
      [ "$authority" != "$rest" ] || return 1
      path=${rest#*/}
      ;;
    *:*)
      path=${raw#*:}
      ;;
    *) return 1 ;;
  esac
  path=${path%%\?*}
  path=${path%%\#*}
  path=${path#/}
  path=${path%/}
  path=${path%.git}
  [ -n "$path" ] || return 1
  printf '%s\n' "$path"
}

fm_forge_project_url_from_origin() { # <origin>; prints an HTTPS project URL
  local origin=$1 host path
  host=$(fm_forge_origin_host "$origin") || return 1
  path=$(fm_forge_origin_path "$origin") || return 1
  printf 'https://%s/%s\n' "$host" "$path"
}

fm_forge_provider_cli() { # <provider>
  case "$1" in github) printf 'gh\n' ;; gitlab) printf 'glab\n' ;; *) return 1 ;; esac
}

fm_forge_require_provider_tools() { # <provider> <host> <operation>
  local provider=$1 host=$2 operation=${3:-forge write} cli
  cli=$(fm_forge_provider_cli "$provider") || {
    echo "error: $operation requires a supported forge provider; '$provider' is unavailable" >&2
    return 1
  }
  if ! command -v "$cli" >/dev/null 2>&1; then
    echo "error: $operation requires $cli for $provider host $host; install $cli and retry" >&2
    return 1
  fi
  case "$provider" in
    github)
      command -v gh-axi >/dev/null 2>&1 || {
        echo "error: $operation requires gh-axi for GitHub host $host; install gh-axi and retry" >&2
        return 1
      }
      if ! gh auth status --hostname "$host" >/dev/null 2>&1; then
        echo "error: GitHub write capability is unavailable for host $host; run gh auth login --hostname $host" >&2
        return 1
      fi
      ;;
    gitlab)
      command -v jq >/dev/null 2>&1 || {
        echo "error: $operation requires jq for GitLab host $host; install jq and retry" >&2
        return 1
      }
      if ! GITLAB_HOST="$host" glab auth status --hostname "$host" >/dev/null 2>&1; then
        echo "error: GitLab write capability is unavailable for host $host; run glab auth login --hostname $host" >&2
        return 1
      fi
      ;;
  esac
}

fm_forge_require_write_project() { # <project-dir> <mode>
  local project=$1 mode=${2:-}
  [ "$mode" != local-only ] || return 0
  if ! fm_forge_context_for_project "$project" "$mode"; then
    echo "error: forge write for project '$project' is unavailable: $FM_FORGE_CAPABILITY_ERROR" >&2
    return 1
  fi
  [ "$FM_FORGE_CAPABILITY" = read-write ] || {
    echo "error: forge write for project '$project' is refused: $FM_FORGE_PROVIDER host $FM_FORGE_HOST is configured read-only; grant read-write capability in config/forge-capabilities" >&2
    return 1
  }
  fm_forge_require_provider_tools "$FM_FORGE_PROVIDER" "$FM_FORGE_HOST" "delivery for project '$project'"
}

fm_forge_require_write_provider() { # <provider> <host> <operation>
  local provider=$1 host=$2 operation=${3:-forge write} configured capability
  fm_forge_capability_validate || {
    echo "error: $operation is refused: invalid config/forge-capabilities - $FM_FORGE_CAPABILITY_ERROR" >&2
    return 1
  }
  configured=$(fm_forge_config_for_host "$host" || true)
  if [ -n "$configured" ]; then
    [ "${configured%% *}" = "$provider" ] || {
      echo "error: $operation is refused: host $host is configured for ${configured%% *}, not $provider" >&2
      return 1
    }
    capability=${configured#* }
  else
    # The caller has already parsed a canonical provider-specific review URL,
    # so an arbitrary self-hosted GitLab host does not need a second allowlist.
    capability=read-write
  fi
  [ "$capability" = read-write ] || {
    echo "error: $operation is refused: $provider host $host is configured read-only" >&2
    return 1
  }
  fm_forge_require_provider_tools "$provider" "$host" "$operation"
}

fm_forge_require_write_url() { # <PR/MR URL>
  local url=$1
  fm_forge_context_for_origin "$url" || {
    echo "error: forge write for '$url' is unavailable: $FM_FORGE_CAPABILITY_ERROR" >&2
    return 1
  }
  fm_forge_require_write_provider "$FM_FORGE_PROVIDER" "$FM_FORGE_HOST" "merge of '$url'"
}

fm_forge_required_targets() { # prints provider|host|capability|project|mode rows
  local projects=${1:-${FM_PROJECTS_OVERRIDE:-${FM_HOME:-.}/projects}} project label mode origin
  [ -d "$projects" ] || return 0
  for project in "$projects"/*; do
    [ -d "$project" ] || continue
    label=${project##*/}
    mode=$("${FM_ROOT:-.}/bin/fm-project-mode.sh" --raw "$label" 2>/dev/null | awk 'NR == 1 {print $1}')
    [ -n "$mode" ] || mode=no-mistakes
    [ "$mode" != local-only ] || continue
    origin=$(fm_forge_project_origin "$project" 2>/dev/null || true)
    [ -n "$origin" ] || continue
    fm_forge_origin_host "$origin" >/dev/null 2>&1 || continue
    if fm_forge_context_for_origin "$origin"; then
      printf '%s|%s|%s|%s|%s\n' "$FM_FORGE_PROVIDER" "$FM_FORGE_HOST" "$FM_FORGE_CAPABILITY" "$label" "$mode"
    else
      printf 'unknown|%s|unknown|%s|%s\n' "${FM_FORGE_HOST:-unknown}" "$label" "$mode"
    fi
  done
}
