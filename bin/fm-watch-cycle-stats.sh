#!/usr/bin/env bash
# One-line self-check of how long watcher cycles are taking, computed from the
# arm-owned lifecycle ledger (state/.watch-cycle-exits.log).
#
# Usage:
#   fm-watch-cycle-stats.sh [--recent <n>]
#
# The ledger is the watcher's own record of every observed cycle, and its
# `started_at` and `ended_at` fields are epoch seconds, so a cycle's duration is
# their difference. Because bin/fm-watch.sh touches the liveness beacon at the
# TOP of every poll, a cycle's duration is also how stale that beacon got while
# the cycle ran - which is what makes this a supervision-health number rather
# than only a performance one. A cycle that runs long enough goes blind: the
# classifier's bounded scan is what keeps one task's growing status log from
# making ordinary cycles long in the first place.
#
# Prints one line:
#   watcher cycles: median 13s · mean 14s · max 21s · cycles 37 of 37 · threshold 150s
# and, when the median reaches the threshold, one further explicit line:
#   watcher cycles: ALERT median 210s >= threshold 150s over 37 cycles - ordinary
#   cycles already run long enough to blind supervision for their duration
#
# The threshold defaults to half of FM_GUARD_GRACE, the bound the guard allows a
# beacon to age before it reports supervision blind: at that point an ordinary
# cycle already spends half that budget, leaving no headroom for one slow cycle.
# FM_WATCH_CYCLE_MEDIAN_ALERT_SECS overrides it.
#
# Reads only the ledger; starts nothing and never fails a caller's turn (a
# ledger it cannot read prints an explicit EMPTY line and exits 0).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LEDGER="${FM_WATCH_CYCLE_LOG:-$STATE/.watch-cycle-exits.log}"
GRACE=${FM_GUARD_GRACE:-300}
case "$GRACE" in ''|*[!0-9]*|0) GRACE=300 ;; esac
THRESHOLD=${FM_WATCH_CYCLE_MEDIAN_ALERT_SECS:-$(( GRACE / 2 ))}
case "$THRESHOLD" in ''|*[!0-9]*|0) THRESHOLD=$(( GRACE / 2 )) ;; esac

RECENT=''
while [ $# -gt 0 ]; do
  case "$1" in
    --recent) RECENT=${2-}; shift 2 ;;
    -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'error: unknown argument: %s\nhelp: fm-watch-cycle-stats.sh [--recent <n>]\n' "$1" >&2; exit 2 ;;
  esac
done
case "$RECENT" in ''|*[!0-9]*) RECENT='' ;; esac

if [ ! -f "$LEDGER" ] || [ ! -r "$LEDGER" ] || [ -L "$LEDGER" ]; then
  printf 'watcher cycles: EMPTY - no readable cycle ledger at %s\n' "$LEDGER"
  exit 0
fi

stats=$(perl -e '
  my $recent = shift // "";
  my (@d, $seen);
  while (my $line = <STDIN>) {
    chomp $line;
    my %f;
    for my $kv (split /\t/, $line) {
      my ($k, $v) = split /=/, $kv, 2;
      next if !defined $v;
      $f{$k} = $v;
    }
    next unless defined $f{started_at} && defined $f{ended_at};
    next unless $f{started_at} =~ /^[0-9]+$/ && $f{ended_at} =~ /^[0-9]+$/;
    my $dur = $f{ended_at} - $f{started_at};
    next if $dur < 0;
    push @d, $dur;
    $seen++;
  }
  $seen = 0 unless defined $seen;
  my $total = scalar @d;
  if ($recent ne "" && $recent > 0 && $total > $recent) {
    @d = @d[($total - $recent) .. ($total - 1)];
  }
  my $n = scalar @d;
  if ($n == 0) { printf "EMPTY\t0\t0\t0\t0\t%s", $seen; exit 0; }
  my @sorted = sort { $a <=> $b } @d;
  my $median = $n % 2 ? $sorted[int($n / 2)]
                      : int(($sorted[$n / 2 - 1] + $sorted[$n / 2]) / 2);
  my $sum = 0; $sum += $_ for @d;
  my $mean = int($sum / $n + 0.5);
  my $max = $sorted[-1];
  printf "OK\t%s\t%s\t%s\t%s\t%s", $median, $mean, $max, $n, $seen;
' "$RECENT" < "$LEDGER" 2>/dev/null) || stats=''

if [ -z "$stats" ]; then
  printf 'watcher cycles: EMPTY - no readable cycle ledger at %s\n' "$LEDGER"
  exit 0
fi

status=${stats%%$'\t'*}; rest=${stats#*$'\t'}
median=${rest%%$'\t'*}; rest=${rest#*$'\t'}
mean=${rest%%$'\t'*}; rest=${rest#*$'\t'}
max=${rest%%$'\t'*}; rest=${rest#*$'\t'}
count=${rest%%$'\t'*}; total=${rest#*$'\t'}

if [ "$status" = EMPTY ] || [ "$count" -eq 0 ]; then
  printf 'watcher cycles: EMPTY - no completed cycles recorded (%s rows seen)\n' "$total"
  exit 0
fi

printf 'watcher cycles: median %ss · mean %ss · max %ss · cycles %s of %s · threshold %ss\n' \
  "$median" "$mean" "$max" "$count" "$total" "$THRESHOLD"
if [ "$median" -ge "$THRESHOLD" ]; then
  printf 'watcher cycles: ALERT median %ss >= threshold %ss over %s cycles - ordinary cycles already run long enough to blind supervision for their duration\n' \
    "$median" "$THRESHOLD" "$count"
fi
exit 0
