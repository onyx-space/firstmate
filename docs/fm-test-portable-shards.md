# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

Two different things are described here, and they have different owners.

**Membership** of the proven-isolated set comes from the 2026-08-20 concurrent proof recorded in [fm-test-isolation-proof.md](fm-test-isolation-proof.md).
The proof ran 24 candidates with four workers and no failures.
It answers *which* scripts may run concurrently.

**Balance weights** for the two portable parallel shards come from those lanes' own CI timing artifacts, listed under [Parallel lanes](#parallel-lanes).
The proof's file `fm-test-isolation-proof.json` keeps its local wall clocks as the historical record of that proof; those clocks are not CI durations and are no longer used for packing.
Keeping the two apart is the whole point: the local proof's wall clocks were up to 18x below what the same script costs on a CI runner (`tests/fm-pr-merge.test.sh` 6290 ms there, 115843 ms in CI) and a few were above it, so packing from them left one shard holding both of the real heavyweights and three times the other shard's work on run 34586799603 (592.3 s against 197.4 s, both under one 600 s cap).

## Parallel lanes

The two parallel lanes are a longest-processing-time assignment of the proven-isolated set over the weight table embedded in `bin/fm-test-run.sh` as `portable_parallel_weight_hints`.
Each weight is the slowest `duration_ms` that script recorded across the `fm-test-timing-portable-parallel-*` artifacts of the CI runs below, taken on 2026-09-10 and 2026-09-11 from `onyx-space/firstmate`:
[34454669796](https://github.com/onyx-space/firstmate/actions/runs/34454669796), [34460182760](https://github.com/onyx-space/firstmate/actions/runs/34460182760), [34464528364](https://github.com/onyx-space/firstmate/actions/runs/34464528364), [34482703624](https://github.com/onyx-space/firstmate/actions/runs/34482703624), [34483083923](https://github.com/onyx-space/firstmate/actions/runs/34483083923), [34487816755](https://github.com/onyx-space/firstmate/actions/runs/34487816755), [34542464499](https://github.com/onyx-space/firstmate/actions/runs/34542464499), [34549712118](https://github.com/onyx-space/firstmate/actions/runs/34549712118), [34555469660](https://github.com/onyx-space/firstmate/actions/runs/34555469660), [34559834562](https://github.com/onyx-space/firstmate/actions/runs/34559834562), [34580845979](https://github.com/onyx-space/firstmate/actions/runs/34580845979), and [34586799603](https://github.com/onyx-space/firstmate/actions/runs/34586799603).
Shard 1 contributed nine runs and shard 2 twelve; every script record in all of them exited 0 with no gate skip, so no weight is inflated by a failing or skipping run.
Taking the slowest of many runs rather than one run is what keeps the balance honest on a slow runner.

Assignment, longest first within each shard, with the weight that placed it:

| shard | duration_ms | script |
|---:|---:|---|
| 1 | 282342 | `tests/fm-captain-hold-lifecycle.test.sh` |
| 1 | 32559 | `tests/fm-arm-pretool-check.test.sh` |
| 1 | 27295 | `tests/fm-x-mode.test.sh` |
| 1 | 23740 | `tests/fm-backend-herdr.test.sh` |
| 1 | 15799 | `tests/fm-cd-pretool-check.test.sh` |
| 1 | 6977 | `tests/fm-herdr-lab.test.sh` |
| 1 | 5256 | `tests/fm-send-popup-settle.test.sh` |
| 1 | 4032 | `tests/fm-send-strict.test.sh` |
| 1 | 3479 | `tests/fm-review-diff.test.sh` |
| 1 | 2305 | `tests/fm-brief.test.sh` |
| 1 | 1934 | `tests/fm-composer-ghost.test.sh` |
| 1 | 303 | `tests/fm-supervision-instructions.test.sh` |
| 1 | 88 | `tests/fm-transition-lib.test.sh` |
| 2 | 162434 | `tests/fm-lint.test.sh` |
| 2 | 115843 | `tests/fm-pr-merge.test.sh` |
| 2 | 87711 | `tests/fm-test-run.test.sh` |
| 2 | 13643 | `tests/fm-crew-state.test.sh` |
| 2 | 7389 | `tests/fm-pi-primary-types.test.sh` |
| 2 | 6330 | `tests/fm-grok-harness.test.sh` |
| 2 | 4822 | `tests/fm-composer-lib.test.sh` |
| 2 | 2508 | `tests/fm-tmux-submit-busy.test.sh` |
| 2 | 2334 | `tests/fm-spawn-batch.test.sh` |
| 2 | 2118 | `tests/fm-send-settle.test.sh` |
| 2 | 935 | `tests/fm-ensure-agents-md.test.sh` |

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-parallel-1` | 13 | 406109 ms (~406.1 s) |
| `portable-parallel-2` | 11 | 406067 ms (~406.1 s) |
| imbalance | | 42 ms |

The two heaviest scripts land in different shards, which is the assignment LPT exists to produce: `tests/fm-captain-hold-lifecycle.test.sh` (282.3 s, 3825 lines and grown by 12 commits since the isolation proof) opens shard 1, and `tests/fm-lint.test.sh` (162.4 s, the ShellCheck parity guard over the whole growing file set) opens shard 2.
Their union is 444.8 s, so packing them together would put one shard near the cap on script time alone; separating them is the single most important property of this partition.
The previous partition derived from the isolation proof put both in shard 1, where they measured 592.3 s of real CI script time on run 34586799603 against a 600 s cap while shard 2 used 197.4 s.

Re-partitioning the same observed runs is the honest way to read the improvement, because it holds runner speed and script set constant:

| run | old shard 1 | old shard 2 | re-partitioned 1 | re-partitioned 2 |
|---|---:|---:|---:|---:|
| [34454669796](https://github.com/onyx-space/firstmate/actions/runs/34454669796) | 505420 | 161571 | 344435 | 322556 |
| [34460182760](https://github.com/onyx-space/firstmate/actions/runs/34460182760) | 517366 | 212965 | 365837 | 364494 |
| [34464528364](https://github.com/onyx-space/firstmate/actions/runs/34464528364) | 491032 | 200316 | 339574 | 351774 |
| [34482703624](https://github.com/onyx-space/firstmate/actions/runs/34482703624) | 513992 | 200680 | 355960 | 358712 |
| [34483083923](https://github.com/onyx-space/firstmate/actions/runs/34483083923) | 450973 | 206757 | 319594 | 338136 |
| [34487816755](https://github.com/onyx-space/firstmate/actions/runs/34487816755) | 527663 | 150188 | 350467 | 327384 |
| [34542464499](https://github.com/onyx-space/firstmate/actions/runs/34542464499) | 503134 | 212440 | 354809 | 360765 |
| [34549712118](https://github.com/onyx-space/firstmate/actions/runs/34549712118) | 527312 | 137576 | 341667 | 323221 |
| [34586799603](https://github.com/onyx-space/firstmate/actions/runs/34586799603) | 592302 | 197422 | 398622 | 391102 |

Spreading the old shard 1 across both shards cuts the slowest lane from 450-593 s to 320-399 s.
The worst re-partitioned shard on record is 398622 ms, 33% below the 592675 ms that run's shard 1 actually took.

`bin/fm-test-run.sh` owns the partition: `portable_parallel_assignments` runs the same deterministic LPT helper the serial shards use, and `list_portable_parallel_1` / `list_portable_parallel_2` are its two shards.
The coverage guard refuses a partition whose union is not the whole proven-isolated set, so the membership proof cannot be weakened by rebalancing.
Both shards install the Pi coding-agent package and both pass `--fail-on-gate-skip 'Pi extension typecheck prerequisite not found'`, so either shard can carry `tests/fm-pi-primary-types.test.sh` and a rebalance cannot turn it into a silent gate skip.

Refresh the weights by downloading the per-shard timing artifacts from several runs where that lane uploaded one, replacing the `portable_parallel_weight_hints` table in `bin/fm-test-run.sh` with the slowest measured `duration_ms` per `path`, and updating both tables above:

```sh
for run in <run-id> <run-id> <run-id>; do
  gh run download "$run" -R onyx-space/firstmate --pattern 'fm-test-timing-portable-parallel-*' -D "/tmp/fm-par/$run"
done
jq -r '.scripts[] | [.path, .duration_ms] | @tsv' /tmp/fm-par/*/*/*.json \
  | awk -F'\t' '$2 > m[$1] { m[$1] = $2 } END { for (p in m) print p, m[p] }' \
  | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

The refresh fires on evidence rather than on a schedule: a shard whose measured wall approaches its job cap, or a `parallel_est_1=` / `parallel_est_2=` pair on the coverage-guard line that no longer matches what the lane takes, is the signal that the table has drifted.
`docs/fm-test-portable-shards.md` is the only place the estimate is written down, so a refresh that changes `bin/fm-test-run.sh` also changes both tables here.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, the `live-harness-optin` family, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

On green CI run [30725985757](https://github.com/kunchenguid/firstmate/actions/runs/30725985757), that remainder accumulated 19m04s of script time against a 20-minute job timeout.
On [PR 1495](https://github.com/kunchenguid/firstmate/pull/1495), its main step ran about 19m51s before the job was cancelled at that boundary.
`portable-serial-<k>of<n>` splits it across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/fm-test-run.sh`.
The 145 current hints include the slowest measurements retained from the `fm-test-timing-portable-serial-*` artifacts of three green CI runs on 2026-09-01, [33558082172](https://github.com/kunchenguid/firstmate/actions/runs/33558082172), [33523597838](https://github.com/kunchenguid/firstmate/actions/runs/33523597838), and [33463326167](https://github.com/kunchenguid/firstmate/actions/runs/33463326167), the completed-script measurements from [run 34342484144](https://github.com/kunchenguid/firstmate/actions/runs/34342484144), plus the 5121 ms native-Windows focused runner measurement for `tests/fm-pi-windows-shell-invocation.test.sh` from 2026-09-06T21:02Z.
Those per-script maxima total 4312606 ms of conservative balance weight.
Taking the slowest of several CI runs rather than a single run keeps the balance honest on a slow runner.
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default; the current 154-script lane has nine such scripts, bringing its assignment weight to 4555606 ms.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
Balance is still worth keeping current, because enough unmeasured scripts let one shard carry more than twice another shard's real work and reach the job cap while another runner sits idle.
That is not hypothetical: by 2026-09-01 the lane had grown from 116 to 139 scripts and from ~42 to ~63 minutes, 17 scripts were still unmeasured, and several hints were low by 2-5x, so shard 3 of 4 ran 17-20 minutes against its 20-minute cap while shard 1 ran 11.5 minutes and run [33574154856](https://github.com/kunchenguid/firstmate/actions/runs/33574154856) timed out seconds after a passing test.
`bin/fm-test-run.sh --check-coverage` now reports the unmeasured share as `serial_unhinted=` and refuses past `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`, so hint drift fails the coverage guard instead of silently pushing one shard into its job cap.
Refresh the hints whenever the serial lane gains scripts, rather than waiting for that bound to trip.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-serial-1of5` | 30 | 911111 ms (~15.19 min) |
| `portable-serial-2of5` | 31 | 911128 ms (~15.19 min) |
| `portable-serial-3of5` | 32 | 911128 ms (~15.19 min) |
| `portable-serial-4of5` | 31 | 911128 ms (~15.19 min) |
| `portable-serial-5of5` | 30 | 911111 ms (~15.19 min) |
| imbalance | | 17 ms |

The current table is generated from the runner's retained maxima plus its default for the nine unhinted scripts.
Run 34342484144 observed a shard reach about 20 minutes of passing work, so the 30-minute job cap keeps meaningful hang-tripwire margin for job setup and runner-speed spread.

The single longest script, `tests/fm-watch-triage.test.sh` at 262626 ms, is the floor for any shard count.

Refresh the CI-derived hints by downloading the per-shard timing artifacts from several green CI runs, replacing the `portable_serial_weight_hints` table in `bin/fm-test-run.sh` with the slowest measured `duration_ms` per `path`, and updating the table above:

```sh
for run in <run-id> <run-id> <run-id>; do
  gh run download "$run" -R kunchenguid/firstmate --pattern 'fm-test-timing-portable-serial-*' -D "/tmp/fm-serial/$run"
done
jq -r '.scripts[] | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*/*.json \
  | awk -F'\t' '$2 > m[$1] { m[$1] = $2 } END { for (p in m) print p, m[p] }' \
  | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

A timed-out shard uploads no artifact, so pick runs where every serial shard is green or the lane's slowest scripts go unmeasured in exactly the shard that needs them most.
Measure native-Windows-only scripts through the focused Git Bash runner and retain that `duration_ms` separately, because the portable CI shards skip them.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.
It reports the unmeasured serial share as `serial_unhinted=` and refuses when that share exceeds `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`, so the shards stay balanced on evidence rather than on the default weight.
It also prints both parallel lane estimates as `parallel_est_1=` and `parallel_est_2=`, which are the two numbers in the [Parallel lanes](#parallel-lanes) table, so the CI log carries the estimate a later refresh is compared against.
A proven-isolated script with no weight has no default and fails the guard loudly, because the proven set only changes through a new isolation proof, which measures its own durations.

## Timing artifacts

Portable shards, each portable serial shard, and the Herdr lane upload runner-generated timing JSON.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

| Lane | Bound | Rationale |
|---|---|---|
| portable parallel 1/2 | job `timeout-minutes: 15` | The balanced estimate from the retained per-script CI maxima is ~406 s of script time per shard; observed job setup, measured as job wall clock minus lane wall clock on runs 34454669796, 34464528364, and 34549712118 (job timestamps are minute-rounded), is 11-20 s. The worst healthy wall is therefore about 426 s, and 15 minutes leaves a little over 2x margin over it. The old 10-minute cap sits 1.4x above this new partition's worst healthy wall and 1.01x above the old one's, which is why rebalancing rather than the cap is the fix: on run 34586799603 shard 1 finished all 11 scripts green in 592.7 s and was cancelled at that cap. The parallel lanes run the same proven-isolated set on separate runners, so this is a hang tripwire and must stay a multiple of the healthy wall rather than a tight bound; do not raise it without refreshing the weight table above. |
| portable serial 1-5 | job `timeout-minutes: 30` | Current runners can take about 20 minutes; the 30-minute cap remains a hang tripwire while leaving margin for job setup and runner-speed spread. |
| Herdr | family-run step `timeout-minutes: 20`; job `timeout-minutes: 75` backstop | Healthy runs finished around 7 minutes before this lane gained `fm-backend-herdr-focus-flash-e2e`, which measures about 2 minutes against a real lab locally, so the step bound is still the hang tripwire (cleanup and timing artifacts still upload) while the job cap stays a last-resort backstop. Refresh this figure from the lane's uploaded timing artifact. |

Timeouts are hang tripwires rather than expected healthy durations.
`.github/workflows/ci.yml` owns the exact numbers.
