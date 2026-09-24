#!/usr/bin/env bash
# Drives the real shared classifier (HEAD) over real captured frames plus the
# boundary frames the intent freezes. Prints "<label> = <verdict>".
set -u
EV=/home/onyx/.no-mistakes/evidence/01M39CXBX2VCWGK13DV6B9HHJV
# shellcheck source=/dev/null
. "$EV/classifier/head/fm-composer-lib.sh"
CAPS=$'styled=1\ncursor=0\nidentity=1\nrows=20'
NOCAP=$'styled=1\ncursor=0\nidentity=0\nrows=20'
PI_I=$'pi\tidle'; PI_D=$'pi\tdone'; PI_W=$'pi\tworking'; PI_B=$'pi\tblocked'
dead_live=$(cat "$EV/live-tmux/deadshell.ansi")
dead_live_plain=$(printf '%s\n' "$dead_live" | fm_composer_strip_ansi)
herdr_live=$(cat "$EV/live-herdr/default_w1G_p2.ansi")
say() { printf '%-58s = %s\n' "$1" "$2"; }

say "LIVE tmux deadshell, cursorless, pi idle"        "$(fm_composer_classify_screen "$CAPS" "$dead_live" "" "$PI_I")"
say "LIVE tmux deadshell, cursorless, pi working"     "$(fm_composer_classify_screen "$CAPS" "$dead_live" "" "$PI_W")"
say "LIVE tmux deadshell, cursorless, no identity"    "$(fm_composer_classify_screen "$CAPS" "$dead_live" "")"
say "LIVE herdr working-pane bytes, pi working"       "$(fm_composer_classify_screen "$CAPS" "$herdr_live" "" "$PI_W")"
say "LIVE herdr working-pane bytes, pi idle"          "$(fm_composer_classify_screen "$CAPS" "$herdr_live" "" "$PI_I")"

# Boundary: a shell-looking TRANSCRIPT row above a lower unpaired rule is not
# the bottom-most structure, so it must not read dead-shell.
tr_above=$'transcript\n$ make build\nmore transcript\n────────────────────────'
say "transcript \044 line above unpaired rule, pi working"  "$(fm_composer_classify_screen "$CAPS" "$tr_above" "" "$PI_W")"
say "transcript \044 line above unpaired rule, pi idle"     "$(fm_composer_classify_screen "$CAPS" "$tr_above" "" "$PI_I")"
say "transcript \044 line above unpaired rule, pi blocked"  "$(fm_composer_classify_screen "$CAPS" "$tr_above" "" "$PI_B")"

# Boundary: bottom-most shell row under an UNCLOSED border still dead-shell.
unclosed=$'transcript\n┌─────┬─────┐\n│ a   │ b   │\n$ '
say "bottom shell under unclosed table, pi idle"      "$(fm_composer_classify_screen "$CAPS" "$unclosed" "" "$PI_I")"
say "bottom shell under unclosed table, pi working"   "$(fm_composer_classify_screen "$CAPS" "$unclosed" "" "$PI_W")"

# Fix A preserved: table ABOVE a valid empty pi pair still reads empty.
pair_table=$'┌─────┬─────┐\n│ a   │ b   │\n├─────┼─────┤\n│ c   │ d   │\n└─────┴─────┘\n────────────────────────\n\n────────────────────────\n footer'
say "table above valid empty pi pair, pi idle"        "$(fm_composer_classify_screen "$CAPS" "$pair_table" "" "$PI_I")"

# Section 6 classes that must NEVER take a new value.
refusal=$'transcript\n────────────────────────\n\n────────────────────────\n footer\n┌─────┬─────┐\n│ a   │ b   │'
say "settled cursorless refusal, pi idle -> shape"    "$(fm_composer_classify_screen "$CAPS" "$refusal" "" "$PI_I")"
say "settled cursorless refusal, pi done -> shape"    "$(fm_composer_classify_screen "$CAPS" "$refusal" "" "$PI_D")"
say "cursorless refusal, pi blocked -> umbrella"      "$(fm_composer_classify_screen "$CAPS" "$refusal" "" "$PI_B")"
say "cursorless refusal, probe-absent -> umbrella"    "$(fm_composer_classify_screen "$CAPS" "$refusal" "" probe-absent)"
say "cursorless refusal, no identity capability"      "$(fm_composer_classify_screen "$NOCAP" "$refusal" "")"
say "pi pair, working -> busy (2nd busy path)"        "$(fm_composer_classify_screen "$CAPS" $'────────────────────────\n\n────────────────────────' "" "$PI_W")"
say "pi pair, idle -> empty"                          "$(fm_composer_classify_screen "$CAPS" $'────────────────────────\n\n────────────────────────' "" "$PI_I")"
say "pi pair, blocked -> umbrella"                    "$(fm_composer_classify_screen "$CAPS" $'────────────────────────\n\n────────────────────────' "" "$PI_B")"
