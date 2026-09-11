#!/usr/bin/env bash
# fm-parent-channel-lib.sh - the one owner of a secondmate home's parent channel.
#
# WHY THIS EXISTS. A secondmate is a firstmate in its own home, and nobody reads
# its chat: the captain and the main firstmate see only what is appended to the
# parent channel. AGENTS.md tells every firstmate to reach the captain and to
# address the captain in every response, so a mate model reliably "reports" a
# PR-ready result, a finding, a decision, a blocker, or a failure in its own
# chat and skips the one status-file append that would actually deliver it.
# Four such misses were observed on 2026-09-02 across two mate homes; the
# watcher had delivered the parent's request each time and the work was done.
# The problem is therefore not one missed PR notice but every captain-facing
# outcome that depends on the model remembering to write to the channel.
# The fix is structural: every script that RECORDS a captain-facing outcome in a
# mate home publishes it on the parent channel itself, so delivery never
# depends on the model. This library owns where that channel lives and how a
# line is appended to it. The publishers are:
#   - bin/fm-inactive-reconcile.sh   a direct child's terminal done or failed
#                                    ledger line, on every watcher poll, plus
#                                    the silent-ledger inactive-outcome fallback
#   - bin/fm-pr-check.sh             a registered PR-ready line carrying the
#                                    canonical URL
#   - bin/fm-captain-hold.sh         a task held for the captain and its answer
#   - bin/fm-merge-outcome-lib.sh    a merged PR
#   - bin/fm-teardown.sh             the child's final ledger line, refusing to
#                                    remove the child while it is undelivered
#   - bin/fm-secondmate-report.sh     a marked request's correlated answer,
#                                    with this resolver choosing its destination
# The mate's own appends are reserved for judgement (bin/fm-brief.sh charter).
# docs/secondmate-parent-channel.md records the design and its coverage.
#
# THE CHANNEL. It is resolved from the home's own durable identity and parent
# binding, never from a caller's choice:
#   - the .fm-secondmate-home marker names the mate's id in its parent home;
#   - the .fm-secondmate-parent record (bin/fm-secondmate-parent-lib.sh) names
#     the route: a local route reports into the parent home's
#     state/<mate-id>.status, a remote route into this home's own
#     state/parent-replies.status, which the parent's remote reply adapter
#     mirrors line for line into that same parent file
#     (docs/remote-secondmates.md).
# The parent watcher classifies lines there exactly as it classifies any
# crewmate's status stream, so a captain-relevant line becomes a parent wake.
# The mate's OWN task-state scans skip that log through
# fm_parent_channel_is_own_log, the single predicate that tells the outbound
# channel apart from a task supervision log in the home that publishes on it.
#
# Lines follow the charter's "<state> [key=<slug>]: <note>" shape and are
# appended at most once by exact content, so a retried publication cannot
# duplicate a delivered event. An existing destination must be a regular,
# non-symlinked file; a missing one is created with its directory.
#
# Return codes, shared by every entry point that resolves the channel:
#   0  resolved, or appended / already present
#   1  this is a main home (no .fm-secondmate-home marker): nothing to report
#   2  the identity marker exists but is unusable (symlink, NUL, bad id)
#   3  the parent binding is missing or unreadable
#   4  the append itself failed
# A caller that has already recorded the outcome locally must surface a
# non-zero return rather than treat it as delivered.
#
# Sourced by the publishers above and by tests. No side effects on source.

_FM_PARENT_CHANNEL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$_FM_PARENT_CHANNEL_LIB_DIR/fm-secondmate-parent-lib.sh"

# shellcheck disable=SC2034 # Output globals read by sourcing callers.
FM_PARENT_CHANNEL_ID=
# shellcheck disable=SC2034 # Output globals read by sourcing callers.
FM_PARENT_CHANNEL_ROUTE=

# A mate id is used as a file-name component in the parent home, so it is
# accepted only when it is path-safe: no empty value, leading dot, slash, or
# character outside [A-Za-z0-9._-].
_fm_parent_channel_id_valid() {  # <id>
  local id=${1-}
  local LC_ALL=C
  case "$id" in
    ''|.*|*/*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

# The secondmate identity of <home>, printed, or non-zero for a main home (1)
# or an unusable identity marker (2).
fm_parent_channel_home_id() {  # <home>
  local home=$1 marker id
  marker="$home/.fm-secondmate-home"
  if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
    return 1
  fi
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 2
  [ "$(wc -c < "$marker")" -eq "$(LC_ALL=C tr -d '\0' < "$marker" | wc -c)" ] || return 2
  id=$(cat "$marker" 2>/dev/null) || return 2
  _fm_parent_channel_id_valid "$id" || return 2
  printf '%s\n' "$id"
}

# Resolve the channel destination for <home> whose state dir is <state>.
# Prints the destination path and sets FM_PARENT_CHANNEL_ID and
# FM_PARENT_CHANNEL_ROUTE. Returns 1 for a main home, 2 for an unusable
# marker, 3 for a missing or unreadable parent binding.
fm_parent_channel_destination() {  # <home> <state>
  local home=$1 state=$2 id rc=0
  FM_PARENT_CHANNEL_ID=
  FM_PARENT_CHANNEL_ROUTE=
  id=$(fm_parent_channel_home_id "$home") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  fm_secondmate_parent_record_parse "$home/.fm-secondmate-parent" || return 3
  case "$FM_SECONDMATE_PARENT_ROUTE" in
    local)
      [ -n "$FM_SECONDMATE_PARENT_HOME" ] || return 3
      # shellcheck disable=SC2034 # Output globals read by sourcing callers.
      FM_PARENT_CHANNEL_ID=$id
      # shellcheck disable=SC2034 # Output globals read by sourcing callers.
      FM_PARENT_CHANNEL_ROUTE=local
      printf '%s/state/%s.status\n' "$FM_SECONDMATE_PARENT_HOME" "$id"
      ;;
    remote)
      # shellcheck disable=SC2034 # Output globals read by sourcing callers.
      FM_PARENT_CHANNEL_ID=$id
      # shellcheck disable=SC2034 # Output globals read by sourcing callers.
      FM_PARENT_CHANNEL_ROUTE=remote
      printf '%s/parent-replies.status\n' "$state"
      ;;
    *) return 3 ;;
  esac
}

# Memo for the ownership test below. One state/*.status walk asks about every
# file in one home and a full resolution costs a subshell chain, so the answer
# is computed once per state dir and reused for the rest of that walk. Seeding
# writes .fm-secondmate-parent before .fm-secondmate-home and nothing rewrites
# it for the life of a home, so a memoized answer cannot go stale inside one
# process.
# shellcheck disable=SC2034 # Read by the predicate below across calls.
_FM_PARENT_CHANNEL_OWN_LOG_STATE=
# shellcheck disable=SC2034 # Read by the predicate below across calls.
_FM_PARENT_CHANNEL_OWN_LOG_IS_CHANNEL=0

# 0 when <path> is <state>'s own parent-channel outbound log rather than one of
# that home's task supervision logs.
#
# On the remote route the channel is exactly <state>/parent-replies.status. It is
# a stream the mate PUBLISHES on, so a task-state scan inside the mate home must
# skip it: every published line would otherwise be classified as a task named
# parent-replies, which is a phantom signal wake, a phantom open decision the
# drain offers to answer, and a phantom heartbeat-backstop row. Classifying that
# stream as a crewmate's status is the PARENT home's job, on the parent's own
# state/<mate-id>.status file.
# A main home has no marker and no remote route, so its scans and every ordinary
# <task>.status log are untouched.
# <state> is a home's state directory, which is how the scans below already
# address their files.
#
# Callers guard a state/*.status walk with it, so it never prints and answers
# only through its exit status:
#   for f in "$state"/*.status; do ...; fm_parent_channel_is_own_log "$state" "$f" && continue; ...; done
fm_parent_channel_is_own_log() {  # <state> <path>
  local state=$1 path=$2 home
  state=${state%/}
  [ "$path" = "$state/parent-replies.status" ] || return 1
  if [ "$_FM_PARENT_CHANNEL_OWN_LOG_STATE" != "$state" ]; then
    _FM_PARENT_CHANNEL_OWN_LOG_STATE=$state
    _FM_PARENT_CHANNEL_OWN_LOG_IS_CHANNEL=0
    # The resolver's own output is not captured: a command substitution would
    # run it in a subshell and lose the route global it sets. The route alone
    # settles ownership, because the remote route's destination is this path by
    # the channel contract in the header above.
    home=${state%/state}
    if fm_parent_channel_destination "$home" "$state" >/dev/null 2>&1 \
      && [ "$FM_PARENT_CHANNEL_ROUTE" = remote ]; then
      _FM_PARENT_CHANNEL_OWN_LOG_IS_CHANNEL=1
    fi
  fi
  [ "$_FM_PARENT_CHANNEL_OWN_LOG_IS_CHANNEL" = 1 ]
}

# Fold <text> onto one bounded line, so a note copied from a child ledger or a
# hold reason cannot break the channel's line framing.
#
# The bound is a BYTE bound - the channel's line framing, its at-most-once
# append, and the remote reader's position-plus-prefix cursor all reason in bytes
# - and the cut must land on a UTF-8 character boundary. The old fold ended in
# `cut -c1-1200` with `LC_ALL=C` scoped to the `tr` only, so `cut` inherited the
# caller's ambient locale, and `cut -c` counts bytes in a C/POSIX locale and
# characters in a UTF-8 one (measured on GNU coreutils 9.4 and BSD alike; uutils
# coreutils counts bytes whatever the locale). Where it counted bytes it cut at
# whatever byte came 1200th, so a multibyte character straddling the bound was
# split and the channel carried invalid UTF-8, which makes a consumer that
# strictly decodes the file fail on the whole record rather than on the note.
# That is why the failure looked platform-shaped: non-interactive Linux contexts
# (ssh, cron, CI) usually run a C/POSIX locale while macOS defaults to a UTF-8
# one. The boundary rule here is explicit and locale-independent, not delegated
# to `cut`. It bounds the note; it does not repair invalid bytes the caller
# already had.
fm_parent_channel_clean_note() {  # <text>
  # The local LC_ALL=C is deliberate: it is what makes ${#text} and ${text:0:1200}
  # count and slice BYTES in every bash, whatever locale the caller runs in. The
  # common at-or-under-bound path is then process-free; only a note over the
  # bound forks, piping through tail and od to inspect the cut.
  local LC_ALL=C text=$1
  local lead need have i
  # A scoped name, not the obvious `tail`: this array's type is visible to
  # ShellCheck wherever this library is sourced, and a scalar caller variable
  # sharing the name would then be flagged as an array misuse.
  local -a note_bytes
  text=${text//$'\t'/ }
  text=${text//$'\r'/ }
  text=${text//$'\n'/ }
  if [ "${#text}" -gt 1200 ]; then
    text=${text:0:1200}
    # The last four bytes cover the longest UTF-8 sequence, so scanning back
    # from the end finds the leading byte of a character the bound split.
    read -r -a note_bytes <<<"$(printf '%s' "$text" | tail -c 4 | od -An -v -tu1)"
    i=$((${#note_bytes[@]} - 1))
    while [ "$i" -gt 0 ] && [ $((note_bytes[i] & 192)) -eq 128 ]; do i=$((i - 1)); done
    lead=${note_bytes[i]}
    # How many bytes that character needs, by its leading byte.
    need=1
    [ "$lead" -lt 192 ] || need=2
    [ "$lead" -lt 224 ] || need=3
    [ "$lead" -lt 240 ] || need=4
    [ "$lead" -lt 248 ] || need=5
    # A sequence with fewer bytes present than it needs is the one the bound
    # cut; its bytes come off with it, and only they do.
    have=$((${#note_bytes[@]} - i))
    [ "$have" -ge "$need" ] || text=${text:0:$((1200 - have))}
  fi
  printf '%s\n' "$text"
}

# Append <line> to <path> unless that exact line is already there.
fm_parent_channel_append_once() {  # <path> <line>
  local path=$1 line=$2
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
  else
    mkdir -p "$(dirname "$path")" || return 1
  fi
  if grep -Fqx -- "$line" "$path" 2>/dev/null; then
    return 0
  fi
  printf '%s\n' "$line" >> "$path"
}

# Publish one parent-facing line from <home>. See the return codes above.
fm_parent_channel_report() {  # <home> <state> <line>
  local home=$1 state=$2 line=$3 destination rc=0
  destination=$(fm_parent_channel_destination "$home" "$state") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  fm_parent_channel_append_once "$destination" "$line" || return 4
}
