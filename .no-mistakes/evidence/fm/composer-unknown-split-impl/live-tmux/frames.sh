#!/usr/bin/env bash
# frames.sh <kind> - draw a controlled screen in a real tmux pane, then idle.
set -u
kind=$1
printf '\033[2J\033[H'
case "$kind" in
  deadshell)
    printf 'transcript\n$ make build\n┌─────┬─────┐\n│ a   │ b   │\n$ '
    ;;
  deadshell_closed_box)
    printf 'transcript\n╭────────────────────╮\n│                    │\n╰────────────────────╯\n$ '
    ;;
  box_empty)
    printf '╭────────╮\n│ >      │\n╰────────╯'
    printf '\033[1A\033[4G'
    ;;
  box_pending)
    printf '╭──────────╮\n│ > fix it │\n╰──────────╯'
    printf '\033[1A\033[4G'
    ;;
  blank)
    printf 'transcript line one\ntranscript line two\n'
    ;;
esac
sleep 900
