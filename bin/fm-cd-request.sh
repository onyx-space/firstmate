#!/usr/bin/env bash
# Write the request file one doorbell event leaves for the CD chain.
#
# The event this serves is a merged pull request in a repository this endpoint
# maintains: the relay reports the merge to the session that serves the
# repository, that session writes one request, and the platform's own file watch
# starts bin/fm-cd-self-update.sh. Only the merged transition is accepted; a
# closed-without-merge report is refused by name, because the two are told apart
# in the report itself ("open -> merged" against "open -> closed") and acting on
# the second would install a commit nobody merged.
#
# The shape is the one the fleet already uses for deployment events, so no second
# mechanism exists: {"repository", one of "pr" or "commit", "asked_by", "at"}.
# A field outside that shape is not read, and a caller that names neither or both
# of pr and commit is refused rather than guessed at.
#
# The file is written to a temporary name in the same directory and renamed into
# place, so a watcher never starts a run on half a request.
#
# Usage: fm-cd-request.sh --event merged --repository <owner/name> (--pr <n> | --commit <sha>) [--asked-by <name>] [--path <file>] [--dry-run] [--help]
#   --event       the transition the report carried; only "merged" is accepted
#   --repository  the repository the report named
#   --pr          the pull request number that merged
#   --commit      the merged commit id, when the report names a commit instead
#   --asked-by    who writes the request (default firstmate@<machine key>)
#   --path        request file to write (default $XDG_CONFIG_HOME/olink/deploy/request.json)
#   --dry-run     print the request and write nothing
#   --help        print this header
set -euo pipefail

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed -n 's/^# \{0,1\}//p' | sed '$d'; }

default_asked_by() {
  local current="$HOME/.pi/agent/data/olist-machine"
  local legacy="$HOME/.pi/agent/data/origmd-machine"
  local file="$current" key=""
  if [ ! -e "$current" ] && [ -e "$legacy" ]; then file="$legacy"; fi
  [ -r "$file" ] && key="$(head -n 1 "$file" 2>/dev/null | tr -d '[:space:]')"
  printf 'firstmate@%s' "${key:-unknown}"
}
REQUEST_PATH="${FM_CD_REQUEST_PATH:-${XDG_CONFIG_HOME:-$HOME/.config}/olink/deploy/request.json}"
EVENT=""; REPOSITORY=""; PR=""; COMMIT=""; ASKED_BY=""; DRY_RUN=no

while [ "$#" -gt 0 ]; do
  case "$1" in
    --event) [ "$#" -ge 2 ] || { echo "fm-cd-request: --event needs a value" >&2; exit 2; }; EVENT="$2"; shift 2 ;;
    --repository) [ "$#" -ge 2 ] || { echo "fm-cd-request: --repository needs a value" >&2; exit 2; }; REPOSITORY="$2"; shift 2 ;;
    --pr) [ "$#" -ge 2 ] || { echo "fm-cd-request: --pr needs a value" >&2; exit 2; }; PR="$2"; shift 2 ;;
    --commit) [ "$#" -ge 2 ] || { echo "fm-cd-request: --commit needs a value" >&2; exit 2; }; COMMIT="$2"; shift 2 ;;
    --asked-by) [ "$#" -ge 2 ] || { echo "fm-cd-request: --asked-by needs a value" >&2; exit 2; }; ASKED_BY="$2"; shift 2 ;;
    --path) [ "$#" -ge 2 ] || { echo "fm-cd-request: --path needs a value" >&2; exit 2; }; REQUEST_PATH="$2"; shift 2 ;;
    --dry-run) DRY_RUN=yes; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "fm-cd-request: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$EVENT" ] || { echo "fm-cd-request: --event is required (only \"merged\" is accepted)" >&2; exit 2; }
if [ "$EVENT" != merged ]; then
  echo "fm-cd-request: refused: event \"$EVENT\" is not a merge; a closed-without-merge report must not install anything" >&2
  exit 2
fi
[ -n "$REPOSITORY" ] || { echo "fm-cd-request: --repository is required" >&2; exit 2; }
if [ -n "$PR" ] && [ -n "$COMMIT" ]; then
  echo "fm-cd-request: refused: name either --pr or --commit, not both" >&2
  exit 2
fi
if [ -z "$PR" ] && [ -z "$COMMIT" ]; then
  echo "fm-cd-request: refused: one of --pr or --commit is required" >&2
  exit 2
fi
if [ -n "$PR" ]; then
  case "$PR" in ''|*[!0-9]*) echo "fm-cd-request: refused: --pr must be a positive whole number, got \"$PR\"" >&2; exit 2 ;; esac
  [ "$PR" -gt 0 ] || { echo "fm-cd-request: refused: --pr must be positive, got \"$PR\"" >&2; exit 2; }
fi
if [ -n "$COMMIT" ]; then
  case "$COMMIT" in ''|*[!0-9a-f]*) echo "fm-cd-request: refused: --commit must be a lowercase hexadecimal id, got \"$COMMIT\"" >&2; exit 2 ;; esac
fi
[ -n "$ASKED_BY" ] || ASKED_BY="$(default_asked_by)"

AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [ -n "$PR" ]; then
  body="$(printf '{\n  "repository": "%s",\n  "pr": %s,\n  "asked_by": "%s",\n  "at": "%s"\n}\n' "$REPOSITORY" "$PR" "$ASKED_BY" "$AT")"
else
  body="$(printf '{\n  "repository": "%s",\n  "commit": "%s",\n  "asked_by": "%s",\n  "at": "%s"\n}\n' "$REPOSITORY" "$COMMIT" "$ASKED_BY" "$AT")"
fi

if [ "$DRY_RUN" = yes ]; then
  printf 'fm-cd-request: dry-run: would write %s\n%s' "$REQUEST_PATH" "$body"
  exit 0
fi

dir="$(dirname "$REQUEST_PATH")"
mkdir -p "$dir"
tmp="$dir/.request.$$.tmp"
cleanup() { rm -f "$tmp" 2>/dev/null || true; }
trap cleanup EXIT
printf '%s' "$body" > "$tmp"
mv -f "$tmp" "$REQUEST_PATH"
trap - EXIT
printf 'fm-cd-request: wrote %s (repository %s, %s, asked_by %s)\n' \
  "$REQUEST_PATH" "$REPOSITORY" "$([ -n "$PR" ] && printf 'pr %s' "$PR" || printf 'commit %s' "$COMMIT")" "$ASKED_BY"
