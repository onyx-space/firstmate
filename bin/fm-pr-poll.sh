#!/usr/bin/env bash
# Static watcher program for a validated PR/MR poll sidecar.
# It emits exactly one merged line for a merged PR or MR and stays silent
# otherwise, including on every error, so a failed lookup can never be read as
# a merge. The provider-tagged identity is data in the sidecar and is never
# interpolated into this source: these bytes are identical for every task.
# Each vendor provider is read through its own standard CLI, gh for GitHub and
# glab for GitLab, so an upstream checkout needs no extra tooling to follow
# either. An instance-hosted HTTP forge (Gitea and its descendants) has no such
# CLI and is read through its own API with curl instead, using a token this home
# supplies in local, gitignored <home>/config/pr-forge-hosts; that file's
# format and owner are documented in docs/configuration.md "HTTP forge hosts".
#
# This script also owns that file's one implementation, so the arm path asks it
# whether a forge URL is acceptable (`--forge-token <pr-url>`) rather than
# reading the list a second way; that intake mode reports failures on stderr,
# while the merge path above stays silent as always.
set -u
LC_ALL=C
export LC_ALL

FM_HOME=${FM_HOME:-}
if [ -z "$FM_HOME" ]; then
  # The state-side shim is invoked with no environment under a direct run, and
  # its own path is <home>/state/<id>.check.sh, so its home is one level up.
  case "$0" in
    *.check.sh) FM_HOME=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd) || FM_HOME= ;;
  esac
fi

forge_config_file() {
  [ -n "${FM_HOME:-}" ] || return 1
  printf '%s/config/pr-forge-hosts\n' "$FM_HOME"
}

# Prints the token configured for an exact <base-url> match and returns 1 when
# this home names no such host or names it without a token. A line that is not
# exactly "<base-url> <token>" is skipped rather than guessed at, so the intake
# diagnostic below stays the one place an unusable list is reported.
forge_token_lookup() {
  local base=${1-} file line entry token
  file=$(forge_config_file) || return 1
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    case "$line" in ''|'#'*) continue ;; esac
    entry=${line%%[[:space:]]*}
    token=${line#"$entry"}
    token=${token#"${token%%[![:space:]]*}"}
    case "$token" in ''|*[[:space:]]*) continue ;; esac
    [ "$entry" = "$base" ] || continue
    printf '%s\n' "$token"
    return 0
  done < "$file"
  return 1
}

# Prints scheme://host[:port] for an instance-hosted forge pull request URL and
# returns 1 for any other URL, including the two vendor shapes. The sidecar is
# revalidated against this shape rather than trusted, exactly as the vendor
# branches below revalidate theirs.
http_forge_base() {
  local raw=${1-} pattern
  pattern='^(https?)://([A-Za-z0-9.-]{1,253}(:[0-9]{1,5})?)/([A-Za-z0-9._-]{1,100})/([A-Za-z0-9._-]{1,100})/pulls/([1-9][0-9]*)$'
  [[ "$raw" =~ $pattern ]] || return 1
  printf '%s://%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

if [ "$#" -eq 2 ] && [ "$1" = --forge-token ]; then
  base=$(http_forge_base "${2-}") || {
    printf 'error: %s is not an instance-hosted forge pull request URL\n' "${2-}" >&2
    exit 1
  }
  if token=$(forge_token_lookup "$base"); then
    printf '%s\n' "$token"
    exit 0
  fi
  printf 'error: %s is not a configured forge host for this home\n' "$base" >&2
  if config=$(forge_config_file); then
    printf 'error: add a "%s <token>" line to %s\n' "$base" "$config" >&2
  else
    printf 'error: add a "%s <token>" line to this home'"'"'s config/pr-forge-hosts\n' "$base" >&2
  fi
  exit 1
fi

if [ "$#" -eq 6 ] && [ "$1" = --validated ]; then
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
elif [ "$#" -eq 0 ]; then
  case "$0" in
    *.check.sh) data=${0%.check.sh}.pr-poll ;;
    *) exit 0 ;;
  esac

  [ -f "$data" ] && [ ! -L "$data" ] || exit 0
  { exec 3< "$data"; } 2>/dev/null || exit 0
  IFS= read -r provider <&3 || exit 0
  IFS= read -r url <&3 || exit 0
  IFS= read -r host <&3 || exit 0
  IFS= read -r path <&3 || exit 0
  IFS= read -r number <&3 || exit 0
  if IFS= read -r _extra <&3; then
    exit 0
  fi
  exec 3<&-
else
  exit 0
fi

case "$number" in
  [1-9]*) ;;
  *) exit 0 ;;
esac
case "$number" in
  *[!0-9]*) exit 0 ;;
esac

# Every component is revalidated here rather than trusted from the sidecar, and
# the stored URL must then be exactly reconstructible from those components, so
# a doctored sidecar cannot redirect this poll at another host or project.
case "$provider" in
  github)
    [ "$host" = github.com ] || exit 0
    owner=${path%%/*}
    repo=${path#*/}
    [ "${#owner}" -ge 1 ] && [ "${#owner}" -le 39 ] || exit 0
    case "$owner" in
      *[!A-Za-z0-9-]*|-*|*-|*--*) exit 0 ;;
    esac
    [ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || exit 0
    case "$repo" in
      .|..|*[!A-Za-z0-9._-]*) exit 0 ;;
    esac
    [ "$url" = "https://github.com/$owner/$repo/pull/$number" ] || exit 0
    state=$(gh pr view "$url" --json state -q .state 2>/dev/null) || exit 0
    [ "$state" = MERGED ] && printf '%s\n' merged
    ;;
  gitlab)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    [ "${#path}" -ge 3 ] && [ "${#path}" -le 1024 ] || exit 0
    case "$path" in
      /*|*/|*//*) exit 0 ;;
    esac
    # A GitLab project sits under at least one group at no fixed depth, and
    # GitLab reserves the "-" segment as its route separator.
    rest=$path
    segments=0
    while [ -n "$rest" ]; do
      case "$rest" in
        */*) segment=${rest%%/*}; rest=${rest#*/} ;;
        *) segment=$rest; rest= ;;
      esac
      segments=$((segments + 1))
      [ "$segments" -le 20 ] || exit 0
      [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || exit 0
      case "$segment" in
        .|..|-*|*.git|*.atom|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$segments" -ge 2 ] || exit 0
    [ "$url" = "https://$host/$path/-/merge_requests/$number" ] || exit 0
    # glab resolves the instance from the project URL passed to -R, so the host
    # comes from the validated record rather than glab's configured default.
    # It cannot take a merge request URL the way gh does: that form shells out
    # to git for the current repository, and the watcher runs in no repository.
    # The state is read from glab's own field output rather than its JSON,
    # because plain glab has no field selector and firstmate does not require a
    # JSON processor; only an exact "merged" wakes, so a changed format or an
    # unreadable merge request stays silent instead of reporting a merge.
    raw=$(glab mr view "$number" -R "https://$host/$path" 2>/dev/null) || exit 0
    state=$(printf '%s\n' "$raw" | sed -n 's/^state:[[:space:]]*//p' | head -1) || exit 0
    [ "$state" = merged ] && printf '%s\n' merged
    ;;
  gitea)
    # The site's own API is the only reader: the scheme and the authority are
    # part of the stored identity, so the URL is rebuilt from the stored parts
    # and must equal the stored URL byte for byte. github.com and the reserved
    # "."/".." path segments are refused for the same reason the parser refuses
    # them, because a doctored sidecar must not redirect this read.
    base=$(http_forge_base "$url") || exit 0
    [ "$host" = "${base#*://}" ] || exit 0
    case "$host" in github.com|github.com:*) exit 0 ;; esac
    [ "$url" = "$base/$path/pulls/$number" ] || exit 0
    owner=${path%%/*}
    repo=${path#*/}
    case "$owner" in ''|.|..|*[!A-Za-z0-9._-]*) exit 0 ;; esac
    case "$repo" in ''|.|..|*[!A-Za-z0-9._-]*) exit 0 ;; esac
    # No token, no read: an unconfigured or token-less host stays silent and
    # the arm path is where that is reported, exactly as a missing glab is.
    token=$(forge_token_lookup "$base") || exit 0
    [ -n "$token" ] || exit 0
    auth_file=$(mktemp "${TMPDIR:-/tmp}/fm-pr-poll.XXXXXX") || exit 0
    trap 'rm -f -- "$auth_file"' EXIT
    printf 'Authorization: token %s\n' "$token" > "$auth_file" || exit 0
    chmod 0600 "$auth_file" || exit 0
    body=$(curl -m 10 -s -H "@$auth_file" -H 'Accept: application/json' \
      "$base/api/v1/repos/$path/pulls/$number" 2>/dev/null) || exit 0
    rm -f -- "$auth_file"
    # Only an exact true reads as merged, so a changed response shape, an error
    # body, or a closed-but-unmerged pull request all stay silent.
    printf '%s\n' "$body" | grep -Eq '"merged"[[:space:]]*:[[:space:]]*true' \
      && printf '%s\n' merged
    ;;
  *) exit 0 ;;
esac
exit 0
