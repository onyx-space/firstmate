#!/usr/bin/env bash
# Live probe fixture: one real actionable wake, then a quiet arm cycle.
# First invocation closes with a single actionable wake line, exactly the shape
# bin/fm-watch-arm.sh produces for a queued signal; later invocations stay
# armed and silent so the probe observes exactly one delivery.
if [ "${1:-}" = "--handling-delivered" ]; then exit 0; fi
trap 'exit 0' TERM INT
marker="${FM_HOME:-/tmp}/state/.probe-wake-delivered"
printf 'watcher: started pid=%s\n' "$$"
if [ ! -e "$marker" ]; then
  : > "$marker"
  printf 'signal: wake-consumption-probe\n'
  exit 0
fi
while :; do sleep 5; done
