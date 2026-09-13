#!/usr/bin/env bash
# tests/fm-wake-drain-inbox-ack.test.sh - a note's SOURCE decides when that note
# is archived, and only the source does.
#
# The incident this pins: a board counting unacknowledged notes kept climbing
# because an acknowledged wake row closed the row while the note it announced
# stayed in state/inbox/ until somebody remembered a second, separate
# acknowledgement. Coupling the two is only safe once a note can say who wrote
# it, because archiving the captain's own words on a row acknowledgement would
# swallow them silently. So: a notification-class note archives with its row, a
# captain-authored note never does, and the automatic archival is always named on
# the acknowledgement's own output.
#
# This is a portable regression driving the real bin/fm-inbox.sh and
# bin/fm-wake-drain.sh over real note records; nothing here stubs the behaviour
# under test.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
INBOX="$ROOT/bin/fm-inbox.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-inbox-ack-tests)

# Queue one real note through the public CLI as <source>, or with no --source at
# all when <source> is "-", and echo the note id the CLI printed.
queue_note_now() { # <state> <source|-> <body>
  local state=$1 source=$2 body=$3 out
  if [ "$source" = - ]; then
    out=$(FM_STATE_OVERRIDE="$state" "$INBOX" note "$body") || return 1
  else
    out=$(FM_STATE_OVERRIDE="$state" "$INBOX" note --source "$source" "$body") || return 1
  fi
  printf '%s\n' "$out" | sed -n 's/^queued //p'
}

# Drain the queue, then run the acknowledgement command that drain printed. Echoes
# the path of the acknowledgement's own stderr, which is where an automatic
# archival must be visible.
drain_then_ack() { # <state> <tag>
  local state=$1 tag=$2 dir seq gen
  dir=$(dirname "$state")
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/$tag.drain.out" 2> "$dir/$tag.drain.err" \
    || fail "$tag: the drain failed: $(cat "$dir/$tag.drain.err")"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-]*$/\1/p' "$dir/$tag.drain.err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$dir/$tag.drain.err")
  [ -n "$seq" ] && [ -n "$gen" ] \
    || fail "$tag: the drain printed no acknowledgement command: $(cat "$dir/$tag.drain.err")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$seq" --recovery-generation "$gen" \
    > "$dir/$tag.ack.out" 2> "$dir/$tag.ack.err" \
    || fail "$tag: the acknowledgement failed: $(cat "$dir/$tag.ack.err")"
  printf '%s\n' "$dir/$tag.ack.err"
}

test_captain_note_survives_its_acknowledged_wake_row() {
  local dir state id ackerr
  dir=$(make_case captain-note)
  state="$dir/state"
  id=$(queue_note_now "$state" - 'captain wrote this out of band') \
    || fail "queueing the captain's note failed"
  grep -qx 'source=text' "$state/inbox/$id.note" \
    || fail "a note queued with no --source did not record the captain's default source"

  ackerr=$(drain_then_ack "$state" captain)

  [ -f "$state/inbox/$id.note" ] \
    || fail "acknowledging the wake row archived the captain's own note"
  [ ! -e "$state/inbox/handled/$id.note" ] \
    || fail "the captain's own note reached handled/ without an explicit --ack"
  if grep -F 'archived' "$ackerr" >/dev/null; then
    fail "the acknowledgement reported archiving a captain-authored note: $(cat "$ackerr")"
  fi
  pass "a captain-authored note stays in state/inbox/ when its wake row is acknowledged"
}

test_notification_note_is_archived_with_its_wake_row() {
  local dir state id ackerr
  dir=$(make_case notification-note)
  state="$dir/state"
  id=$(queue_note_now "$state" relay 'relay: a watched PR merged') \
    || fail "queueing the notification note failed"
  grep -qx 'source=relay' "$state/inbox/$id.note" \
    || fail "the notification note did not record its source"

  ackerr=$(drain_then_ack "$state" notification)

  [ -f "$state/inbox/handled/$id.note" ] \
    || fail "a notification note did not follow its acknowledged wake row into handled/"
  [ ! -e "$state/inbox/$id.note" ] \
    || fail "a notification note stayed in state/inbox/ after its wake row was acknowledged"
  grep -F 'archived 1 notification note(s)' "$ackerr" >/dev/null \
    || fail "the acknowledgement did not name the automatic archival: $(cat "$ackerr")"
  grep -F "$id" "$ackerr" >/dev/null \
    || fail "the archival line did not name the archived note id: $(cat "$ackerr")"
  pass "a notification note is archived with its wake row and the archival is named"
}

test_mixed_batch_archives_only_the_notification() {
  local dir state captain_id relay_id ackerr
  dir=$(make_case mixed-batch)
  state="$dir/state"
  captain_id=$(queue_note_now "$state" - 'captain wrote this out of band') \
    || fail "queueing the captain's note failed"
  relay_id=$(queue_note_now "$state" relay 'relay: upstream left a review comment') \
    || fail "queueing the notification note failed"

  ackerr=$(drain_then_ack "$state" mixed)

  [ -f "$state/inbox/handled/$relay_id.note" ] \
    || fail "the notification note was not archived"
  [ -f "$state/inbox/$captain_id.note" ] \
    || fail "the captain's note was archived alongside the notification"
  [ ! -e "$state/inbox/handled/$captain_id.note" ] \
    || fail "the captain's note reached handled/ in a mixed batch"
  grep -F "$relay_id" "$ackerr" >/dev/null \
    || fail "the archival line did not name the archived notification: $(cat "$ackerr")"
  if grep -F "$captain_id" "$ackerr" >/dev/null; then
    fail "the archival line named a captain-authored note as archived: $(cat "$ackerr")"
  fi
  pass "one acknowledged batch archives its notification note and leaves the captain's"
}

test_explicit_ack_still_archives_every_source() {
  local dir state captain_id relay_id
  dir=$(make_case explicit-ack)
  state="$dir/state"
  captain_id=$(queue_note_now "$state" - 'captain wrote this out of band') \
    || fail "queueing the captain's note failed"
  relay_id=$(queue_note_now "$state" relay 'relay: a watched PR merged') \
    || fail "queueing the notification note failed"

  FM_STATE_OVERRIDE="$state" "$INBOX" drain --ack "$captain_id" "$relay_id" >/dev/null \
    || fail "an explicit --ack failed"

  [ -f "$state/inbox/handled/$captain_id.note" ] \
    || fail "an explicit --ack no longer archives a captain-authored note"
  [ -f "$state/inbox/handled/$relay_id.note" ] \
    || fail "an explicit --ack no longer archives a notification note"
  pass "an explicit drain --ack still archives a note of either source"
}

test_a_source_that_could_break_the_record_header_is_refused() {
  local dir state out err
  dir=$(make_case bad-source)
  state="$dir/state"
  err="$dir/bad-source.err"

  if FM_STATE_OVERRIDE="$state" "$INBOX" note --source 'relay
injected=value' 'body' >"$dir/bad-source.out" 2>"$err"; then
    fail "a source carrying a newline was accepted"
  fi
  if [ -e "$state/inbox" ] && [ -n "$(find "$state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null)" ]; then
    fail "a refused source still queued a note"
  fi
  pass "a source that could inject a record header line is refused and queues nothing"
}

test_legacy_record_is_not_classified_by_its_body() {
  local dir state id ackerr
  dir=$(make_case legacy-record)
  state="$dir/state"
  id=$(queue_note_now "$state" - 'captain wrote this out of band') \
    || fail "queueing the captain's note failed"

  # A record queued before the source field existed carries only id/at in its
  # header; the body after the separator is the captain's text and must never
  # decide the record's class.
  {
    printf 'id=%s\n' "$id"
    printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf -- '--\n'
    printf 'source=relay\n'
    printf 'this line is the captain speaking, not a notification\n'
  } > "$state/inbox/$id.note"

  ackerr=$(drain_then_ack "$state" legacy)

  [ -f "$state/inbox/$id.note" ] \
    || fail "a header-less legacy record was archived from a body line"
  [ ! -e "$state/inbox/handled/$id.note" ] \
    || fail "a header-less legacy record reached handled/ from a body line"
  if grep -F 'archived' "$ackerr" >/dev/null; then
    fail "the acknowledgement archived a legacy record from its body: $(cat "$ackerr")"
  fi
  pass "a legacy record without a header source is not classified by its body"
}

# The relay producer queues notifications with `fm-inbox.sh note <text>` and no
# `--source`. Until that producer is updated (another lane's work), every note it
# queues must keep counting as the captain's and must never be auto-archived.
test_producer_argv_shape_stays_captain_authored() {
  local dir state id ackerr
  dir=$(make_case producer-argv)
  state="$dir/state"

  id=$(FM_STATE_OVERRIDE="$state" "$INBOX" note 'relay: a watched PR merged' \
    | sed -n 's/^queued //p')
  [ -n "$id" ] || fail "the producer's argv shape did not print a note id"

  ackerr=$(drain_then_ack "$state" producer)

  [ -f "$state/inbox/$id.note" ] \
    || fail "a note queued with no --source was archived with its wake row"
  [ ! -e "$state/inbox/handled/$id.note" ] \
    || fail "a note queued with no --source reached handled/ with its wake row"
  if grep -F 'archived' "$ackerr" >/dev/null; then
    fail "the acknowledgement archived a note queued with no --source: $(cat "$ackerr")"
  fi
  pass "a note queued through the producer's argv shape counts as captain-authored"
}

test_captain_note_survives_its_acknowledged_wake_row
test_notification_note_is_archived_with_its_wake_row
test_mixed_batch_archives_only_the_notification
test_explicit_ack_still_archives_every_source
test_a_source_that_could_break_the_record_header_is_refused
test_legacy_record_is_not_classified_by_its_body
test_producer_argv_shape_stays_captain_authored
