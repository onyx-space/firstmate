#!/usr/bin/env bash
# Cross-revision invariant sweep: HEAD may only turn a BASE `unknown` into one
# of the two named refusals; every BASE `empty` (the only positive proof) must
# stay byte-for-byte `empty`, and HEAD must never invent a new `empty`.
set -u
EV=/home/onyx/.no-mistakes/evidence/01M39CXBX2VCWGK13DV6B9HHJV
source_lib() { . "$1"; }
CAPS=$'styled=1\ncursor=1\nidentity=1\nrows=20'
NOCAP=$'styled=1\ncursor=0\nidentity=0\nrows=20'
IDENTS=('' 'probe-absent' $'pi\tidle' $'pi\tdone' $'pi\tworking' $'pi\tblocked' $'pi\tweird' $'codex\tidle' $'claude\tworking')
declare -A FRAMES
for f in "$EV"/live-herdr/*.ansi "$EV"/live-tmux/*.ansi; do
  [ -e "$f" ] || continue
  FRAMES["live:$(basename "$f")"]=$(cat "$f")
done
FRAMES[cons:deadshell]=$'transcript above\n$ '
FRAMES[cons:unclosed_shell]=$'transcript\n┌─────┬─────┐\n│ a   │ b   │\n$ '
FRAMES[cons:tr_above_rule]=$'transcript\n$ make build\nmore transcript\n────────────────────────'
FRAMES[cons:pair_table]=$'┌─────┬─────┐\n│ a   │ b   │\n└─────┴─────┘\n────────────────────────\n\n────────────────────────\n footer'
FRAMES[cons:refusal]=$'transcript\n────────────────────────\n\n────────────────────────\n footer\n┌─────┬─────┐\n│ a   │ b   │'
FRAMES[cons:pair]=$'transcript\n────────────────────────\n\n────────────────────────\n footer'
FRAMES[cons:leftbar]=$'┃\n┃  Ask anything...\n┃\n┃  Build\n╹▀▀▀▀▀▀▀▀'

base_verdict() { # <frame> <caps> <ident>
  bash -c '. "$0"; fm_composer_classify_screen "$1" "$2" "" "$3"' "$EV/classifier/base/fm-composer-lib.sh" "$2" "$1" "$3"
}
head_verdict() {
  bash -c '. "$0"; fm_composer_classify_screen "$1" "$2" "" "$3"' "$EV/classifier/head/fm-composer-lib.sh" "$2" "$1" "$3"
}

viol=0; empties_base=0; empties_head=0; changed=0; total=0
for name in "${!FRAMES[@]}"; do
  for capsname in CAPS NOCAP; do
    capsv=${!capsname}
    for ident in "${IDENTS[@]}"; do
      b=$(base_verdict "${FRAMES[$name]}" "$capsv" "$ident")
      h=$(head_verdict  "${FRAMES[$name]}" "$capsv" "$ident")
      total=$((total+1))
      [ "$b" = empty ] && empties_base=$((empties_base+1))
      [ "$h" = empty ] && empties_head=$((empties_head+1))
      if [ "$b" = empty ] && [ "$h" != empty ]; then
        echo "VIOLATION empty->$h: $name caps=$capsname ident=[$ident]"; viol=$((viol+1)); fi
      if [ "$b" != empty ] && [ "$h" = empty ]; then
        echo "VIOLATION nonempty->empty: $name caps=$capsname ident=[$ident] (base=$b)"; viol=$((viol+1)); fi
      if [ "$b" != "$h" ]; then
        changed=$((changed+1))
        case "$b:$h" in
          unknown:unknown-busy|unknown:unknown-shape|unknown:need-identity) ;;
          *) echo "UNEXPECTED change base=$b head=$h: $name caps=$capsname ident=[$ident]"; viol=$((viol+1)) ;;
        esac
      fi
      case "$h" in
        empty|pending|pending-unproven|unknown|unknown-busy|unknown-shape|need-identity) ;;
        *) echo "UNDECLARED verdict '$h': $name caps=$capsname ident=[$ident]"; viol=$((viol+1)) ;;
      esac
    done
  done
done
echo "sweep: total=$total base_empty=$empties_base head_empty=$empties_head changed=$changed violations=$viol"
