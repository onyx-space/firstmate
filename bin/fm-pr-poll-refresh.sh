#!/usr/bin/env bash
# Refresh already-armed merge polls onto the current bin/fm-pr-poll.sh bytes.
#
# The watcher runs the tracked bin/fm-pr-poll.sh of the home it watches and
# requires each task's state/<id>.check.sh to be byte-identical to it
# (bin/fm-pr-lib.sh's fm_pr_poll_artifacts_valid), so any release that changes
# those bytes leaves every already-armed watch stale: that task stops being
# polled, and firstmate is woken on every check sweep with "rejected
# unauthenticated state checks" until the poll is re-armed. A merge landing in
# that window would be missed. This script is the migration for that window, and
# the fleet-update path runs it after each home's fast-forward (bin/fm-update.sh)
# so supervision never resumes on stale artifacts.
#
# The template is the file the consuming watcher executes, not whichever repo
# happened to invoke this script: it defaults to this repo's bin/fm-pr-poll.sh
# (the running home) and a caller migrating another home passes --template with
# THAT home's own bin/fm-pr-poll.sh, so every state copy is anchored to the
# template its own watcher byte-compares against.
#
# Each stale task is re-published through the same
# fm_pr_poll_prepare/fm_pr_poll_publish_prepared pair the arming path uses, so
# the sidecar identity, the registration format, the private-file rules, and the
# rollback on a failed publication are all the existing ones. Task metadata is
# never written: pr= and pr_head= survive untouched, and a recorded pr_head= is
# never re-derived or dropped. No network and no forge CLI is involved, because
# the refresh only re-anchors bytes the home already holds.
#
# Idempotent by construction: a task already carrying the current template bytes
# with valid artifacts is left alone and reported as current, so repeating the
# command - in one update, or on an already-migrated home - changes nothing.
#
# Never silent about a live poll: a task this cannot refresh is named with the
# reason and its artifacts are left exactly as they were, because losing a watch
# quietly is the failure this exists to prevent. It also preflights the task's
# own metadata identity before publishing, so a task whose record no longer
# matches its sidecar is reported instead of having its artifacts rolled back
# under it. A non-zero exit means at least one live poll still needs
# "bin/fm-pr-check.sh <id> <pr-url>" by hand.
#
# A home with nothing armed is a no-op, and stays one even where bin/ is
# partial: a missing template is reported only for a task that actually needs
# re-anchoring.
#
# Usage: fm-pr-poll-refresh.sh [--state <state-dir>] [--template <poll-template>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() { echo "usage: fm-pr-poll-refresh.sh [--state <state-dir>] [--template <poll-template>]" >&2; }

TEMPLATE="$FM_ROOT/bin/fm-pr-poll.sh"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --state)
      [ "$#" -ge 2 ] || { usage; exit 1; }
      STATE=$2
      shift 2
      ;;
    --template)
      [ "$#" -ge 2 ] || { usage; exit 1; }
      TEMPLATE=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

TEMPLATE_USABLE=0
if [ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ]; then
  TEMPLATE_USABLE=1
fi

REFRESHED=0
CURRENT=0
FAILED=0

report_failure() {  # <id> <reason>
  printf 'error: merge poll for %s could not be refreshed: %s\n' "$1" "$2" >&2
  FAILED=$((FAILED + 1))
}

# One live poll. The task id comes from the artifact name, so it is validated
# before any task path is constructed.
refresh_one() {  # <id>
  local id=$1 data="$STATE/$1.pr-poll" meta="$STATE/$1.meta"
  local provider url host path number
  if ! fm_pr_task_id_valid "$id"; then
    report_failure "${id:-<unnamed>}" "not a usable task id; remove or re-arm the artifact by hand"
    return 0
  fi
  if ! fm_pr_poll_data_parse "$data"; then
    report_failure "$id" "its poll sidecar is unreadable; re-arm it with bin/fm-pr-check.sh"
    return 0
  fi
  provider=$FM_PR_DATA_PROVIDER
  url=$FM_PR_DATA_URL
  host=$FM_PR_DATA_HOST
  path=$FM_PR_DATA_PATH
  number=$FM_PR_DATA_NUMBER

  # A task already on the current bytes with intact artifacts is done. Both
  # halves are required: matching bytes alone would skip a task whose
  # registration no longer describes them, which is exactly what the watcher
  # rejects.
  if cmp -s "$TEMPLATE" "$STATE/$id.check.sh" \
    && fm_pr_poll_artifacts_valid "$STATE" "$id" "$TEMPLATE"; then
    CURRENT=$((CURRENT + 1))
    return 0
  fi

  # Preflight the metadata binding the publication verifies at its end. A
  # mismatch there would roll the just-published artifacts back and leave the
  # task without a watch at all, so it is reported here with the artifacts
  # untouched instead.
  #
  # A missing template is only a problem for a task that needs refreshing, so a
  # home that arms no polls stays a silent no-op even where bin/ is partial.
  if [ "$TEMPLATE_USABLE" != 1 ]; then
    report_failure "$id" "the poll template $TEMPLATE is unavailable, so its watch cannot be re-anchored; restore bin/fm-pr-poll.sh or re-arm it with bin/fm-pr-check.sh $id $url"
    return 0
  fi
  if [ ! -f "$meta" ] || [ -L "$meta" ]; then
    report_failure "$id" "its task record is missing; re-arm it with bin/fm-pr-check.sh $id $url"
    return 0
  fi
  if ! fm_pr_metadata_identity_parse "$meta" \
    || [ "$FM_PR_META_PROVIDER" != "$provider" ] || [ "$FM_PR_META_URL" != "$url" ] \
    || [ "$FM_PR_META_HOST" != "$host" ] || [ "$FM_PR_META_PATH" != "$path" ] \
    || [ "$FM_PR_META_NUMBER" != "$number" ]; then
    report_failure "$id" "its task record does not match the recorded pull request $url; re-arm it with bin/fm-pr-check.sh $id $url"
    return 0
  fi

  if ! fm_pr_poll_prepare "$STATE" "$id" "$provider" "$url" "$host" "$path" "$number" "$TEMPLATE"; then
    fm_pr_poll_cleanup
    report_failure "$id" "its artifacts could not be prepared for republication; re-arm it with bin/fm-pr-check.sh $id $url"
    return 0
  fi
  if ! fm_pr_poll_publish_prepared; then
    fm_pr_poll_cleanup
    report_failure "$id" "its artifacts could not be republished; re-arm it with bin/fm-pr-check.sh $id $url"
    return 0
  fi
  if ! fm_pr_poll_artifacts_valid "$STATE" "$id" "$TEMPLATE"; then
    report_failure "$id" "its artifacts are still not the current contract; re-arm it with bin/fm-pr-check.sh $id $url"
    return 0
  fi
  printf 'refreshed: %s %s\n' "$id" "$url"
  REFRESHED=$((REFRESHED + 1))
}

if [ -d "$STATE" ] && [ ! -L "$STATE" ]; then
  for data in "$STATE"/*.pr-poll; do
    [ -e "$data" ] || [ -L "$data" ] || continue
    id=${data##*/}
    refresh_one "${id%.pr-poll}"
  done
fi

printf 'poll-refresh: refreshed=%s current=%s failed=%s\n' "$REFRESHED" "$CURRENT" "$FAILED"
[ "$FAILED" -eq 0 ]
