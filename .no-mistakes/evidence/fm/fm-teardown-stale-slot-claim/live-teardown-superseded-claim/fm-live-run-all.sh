#!/usr/bin/env bash
# Run every live scenario for the fm-teardown superseded-slot-claim change.
set -u
WORK=${1:-/tmp/fm-live-ev}
DRIVER=/tmp/fm-live-superseded.sh
BASE=/tmp/fm-live-base
rm -rf "$WORK"; mkdir -p "$WORK"

run() {  # <name> <mode> [extra env assignments...]
  local name=$1 mode=$2; shift 2
  mkdir -p "$WORK/$name"
  env "$@" bash "$DRIVER" "$mode" "$WORK/$name" >/dev/null 2>&1
  echo "ran $name exit=$(grep -h '^exit=' "$WORK/$name/env.txt" || echo missing)"
}

run 01-release-superseded-claim            release
run 02-release-base-commit-deadlock        release FM_LIVE_ROOT="$BASE"
run 03-incident-recovery-both-records      recover-both
run 04-refusal-reverse-superseded-side     reverse
run 05-refusal-no-owner-record             no-owner-record
run 06-refusal-both-claims-predate-owner   both-predate
run 07-refusal-secondmate-co-claimant      secondmate
run 08-refusal-unlanded-shared-copy        unlanded
run 09-refusal-unowned-slot-process        unowned-process
run 10-no-force-ship-path-reading-engages  recover-both FM_LIVE_KIND=ship FM_LIVE_NOFORCE=1 FM_LIVE_REPORT=1
echo "work=$WORK"
