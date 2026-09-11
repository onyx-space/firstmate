# Local Test evidence — fm/fm-ci-behavior-parallel-job-timeout

Change under test: rebalance the two portable parallel CI shards from **real CI
per-script timings** (instead of the local isolation-proof wall clocks), and raise
the two parallel lanes' job tripwire from 10 to 15 minutes.

## 1. Reported failure reproduced from the real CI artifacts (run 34586799603, PR #10)

`Behavior portable parallel 1` → cancelled on **all three attempts**
(attempt 1: 09:57:28→10:07:42, attempt 2: 10:22:43→10:32:55, attempt 3: 11:29:58→11:40:15),
each 612-617 s against `timeout-minutes: 10`.

Its uploaded timing artifact shows **every one of the 11 scripts exit=0, no gate
skips**, and a lane wall clock of **592675 ms** on the 600000 ms cap:

    282342 ms exit=0  tests/fm-captain-hold-lifecycle.test.sh
    162434 ms exit=0  tests/fm-lint.test.sh
     87711 ms exit=0  tests/fm-test-run.test.sh
     ...  (8 more, all exit=0)

That lane's membership is byte-identical to the base commit's hardcoded
`list_portable_parallel_1` → the failure is the stale balance model, not the code.

## 2. Root cause: the weights are now the measured CI maxima

Downloaded `fm-test-timing-portable-parallel-*` for all 12 CI runs cited in
`docs/fm-test-portable-shards.md` and recomputed the per-script slowest
measurement. The runner's own `parallel_est_1=` / `parallel_est_2=` on the
coverage-guard line equal those recomputed sums **exactly**:

    lane 1: 13 scripts, sum(max CI duration over 12 runs) = 406109 ms  == guard parallel_est_1
    lane 2: 11 scripts, sum(max CI duration over 12 runs) = 406067 ms  == guard parallel_est_2
    imbalance = 42 ms (was 8275 ms in the old model, and the old model matched no CI run)

Both CI heavyweights now land in different shards:
`fm-captain-hold-lifecycle` (282342) → lane 1, `fm-lint` (162434) → lane 2.

## 3. Re-partitioned against each run's own measured durations

| run | old lane 1 | old lane 2 | new lane 1 | new lane 2 | old worst | new worst |
|---|---:|---:|---:|---:|---:|---:|
| 34454669796 | 505420 | 161571 | 344435 | 322556 | 505420 | 344435 |
| 34460182760 | 517366 | 212965 | 365837 | 364494 | 517366 | 365837 |
| 34464528364 | 491032 | 200316 | 339574 | 351774 | 491032 | 351774 |
| 34482703624 | 513992 | 200680 | 355960 | 358712 | 513992 | 358712 |
| 34483083923 | 450973 | 206757 | 319594 | 338136 | 450973 | 338136 |
| 34487816755 | 527663 | 150188 | 350467 | 327384 | 527663 | 350467 |
| 34542464499 | 503134 | 212440 | 354809 | 360765 | 503134 | 360765 |
| 34549712118 | 527312 | 137576 | 341667 | 323221 | 527312 | 341667 |
| 34586799603 | 592302 | 197422 | 398622 | 391102 | **592302** | **398622** |

Worst lane over the 12 recorded runs: **592302 → 398622 ms of script time (-32.7%)**.
Measured job setup (job wall clock − lane artifact wall clock, from the API) is
**8-31 s** over 21 job records, so the worst healthy wall for the new partition is
≈ 423 s against the new 900 s cap (~2.1x) and also under the old 600 s cap.

## 4. Live lane drives (real runner, real suite, this worktree)

Both lanes were driven end-to-end with the CI-equivalent prerequisites
(`fm-tools` tsc on PATH, a freshly installed Pi package via `FM_PI_PACKAGE_DIR`):

    bin/fm-test-run.sh --lane portable-parallel-1 \
      --fail-on-gate-skip 'Pi extension typecheck prerequisite not found' --json ...
    → FM_TEST_SUMMARY total=13 failed=0 skipped_gate=0   exit=0

    bin/fm-test-run.sh --lane portable-parallel-2 \
      --fail-on-gate-skip 'Pi extension typecheck prerequisite not found' --json ...
    → FM_TEST_SUMMARY total=11 failed=0 skipped_gate=0   exit=0

Local wall clocks were inflated by unrelated load on this host (another session's
Gradle/DevEco build plus other agents, load average ~6.5 on 10 cores):
`fm-captain-hold-lifecycle` took 404746 ms locally vs 282342 ms in CI,
`fm-backend-herdr` 152176 ms vs 23740 ms. The cap arithmetic above therefore uses
the CI measurements, not these local clocks. What the local drives do prove:
both lanes are green with the new composition, no script gate-skips, and the two
new regression tests pass inside lane 2.

## 5. Adversarial drives

* Stale weight table — a removed row, a blank value, and a non-numeric value each
  make `--list --lane portable-parallel-{1,2}` exit **2** with **zero scripts
  listed** (no silent shrink) and an error pointing at
  `docs/fm-test-portable-shards.md`; `--check-coverage` also refuses.
* Gate-skip guard — with `tsc` absent the Pi typecheck test skips; the lane flag
  turns that into `exit=1` (`required gate skip token seen`) instead of a green
  skip, and with the prerequisites present the same script really runs and passes.
* Shared LPT helper refactor — the 5 portable-serial shards are still a disjoint
  exact cover of the 158-script serial lane.
* Stock macOS Bash 3.2.57 runs the new code path unchanged
  (`--check-coverage` and both lane listings under `/bin/bash`).
* Workflow semantics — parsed `ci.yml` into a normalised job model: both parallel
  jobs 10→15 min, both install the Pi package, both carry the guard token that
  matches every skip line the carried test emits, job ids/names/`needs` unchanged.
