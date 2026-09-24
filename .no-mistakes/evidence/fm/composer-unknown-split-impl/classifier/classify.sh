#!/usr/bin/env bash
# classify.sh <lib.sh> <frame-file> <caps> <cursor|-> <identity|->
# Drives the REAL shared classifier (fm_composer_classify_screen) from either
# the base or the head revision over a real frame. caps/identity are the exact
# descriptors the herdr adapter passes (styled=1 cursor=0 identity=1 rows=20).
set -u
lib=$1 frame=$2 caps=$3 cursor=$4 identity=$5
[ "$cursor" = - ] && cursor=
[ "$identity" = - ] && identity=
# shellcheck source=/dev/null
. "$lib"
fm_composer_classify_screen "$caps" "$(cat "$frame")" "$cursor" "$identity"
