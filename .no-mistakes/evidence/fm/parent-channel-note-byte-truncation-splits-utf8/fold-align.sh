#!/usr/bin/env bash
# fold-align.sh <lib.sh> [label]
# Drives the REAL fold function from <lib.sh> across every cheap alignment of an
# ASCII prefix against its byte bound, then reads each folded note back with a
# strict UTF-8 decoder (the consumer the field failure reported).
set -u
lib=$1
label=${2:-$lib}
. "$lib"
out=/tmp/.fold-align.out
bad=0; total=0; over=0; noshape=0
intro='修好了：中文不会再被切成半个字 '
for len in $(seq 0 20); do
  pad=$(printf '%*s' "$len" '' | tr ' ' A)
  for kind in cjk emoji; do
    case $kind in
      cjk) body=$(printf '中%.0s' $(seq 1 500)) ;;
      emoji) body=$(printf '😀%.0s' $(seq 1 400)) ;;
    esac
    text="$intro$pad$body"
    folded=$(fm_parent_channel_clean_note "$text")
    printf '%s' "$folded" > "$out"
    total=$((total + 1))
    python3 -c 'import sys; open(sys.argv[1], encoding="utf-8", errors="strict").read()' "$out" 2>/dev/null || {
      bad=$((bad + 1)); echo "  INVALID-UTF8  len=$len kind=$kind"; }
    bytes=$(LC_ALL=C wc -c < "$out" | tr -d ' ')
    [ "$bytes" -le 1200 ] || { over=$((over + 1)); echo "  OVER-BOUND   len=$len kind=$kind bytes=$bytes"; }
    case "$text" in "$folded"*) ;; *) noshape=$((noshape + 1)); echo "  NOT-A-PREFIX len=$len kind=$kind";; esac
    case "$folded" in *"$intro"*) ;; *) noshape=$((noshape + 1)); echo "  LOST-TEXT    len=$len kind=$kind";; esac
  done
done
echo "$label: alignments=$total invalid_utf8=$bad over_bound=$over bad_shape=$noshape"
