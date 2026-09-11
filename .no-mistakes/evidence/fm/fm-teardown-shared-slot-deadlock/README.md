# Live validation evidence — fm-teardown shared pool-slot deadlock fix

Branch `fm/fm-teardown-shared-slot-deadlock` (tip `ce459c0`). This directory holds
the live drive of the change against the real product plus the targeted
regression suites.

## What was driven live

`live-drive.sh` runs the real `bin/fm-teardown.sh` (branch tip) against isolated
fixtures. Nothing in the product's decision path is stubbed:

- **real tmux server**, isolated with `TMUX_TMPDIR=$LIVE/tmux` (never the user's
  server); the recorded endpoint is a genuine window whose `#{pane_pid}` is the
  real pane leader.
- **real process tree** — `ps`/`lsof` see real pids, real cwds, real reparenting.
- **real treehouse pool slot** — created by `treehouse get --lease` in the
  fixture project, returned by the product's own `treehouse return --force`.
- **real git** for the landed/unlanded copy proof (bare origin + remote-tracking
  branch).
- **real symlinked fm home** for the aliased-identity readings.
- **real herdr server** for the Herdr branch of the backend contract.

The one stand-in is the agent inside the pane: a compiled sleeper renamed `pi`
(a genuine agent harness would write user-level session state outside this run's
boundary).

## Fixture construction and cleanup

- Fixtures live under `LIVE=/tmp/fm-live-teardown` and are removed by the
  driver's `EXIT` trap, together with every `~/.treehouse/<project>-<hash>` pool
  directory the run leased. Nothing is written inside the repository worktree.
  The pre-fix comparison binary lives in `/tmp/fm-prefix/bin/` (the parent
  commit's `bin/fm-teardown.sh`, with the other `bin/` entries symlinked back to
  the branch checkout so its `SCRIPT_DIR` siblings resolve).
- Case shape: public git project → leased pool slot → `state/<task>.meta` for two
  records naming that slot → one real tmux window per endpoint → real teardown.

## Files

| file | what it is |
|---|---|
| `live-drive.sh` | the live driver (scenario-per-case, `PASS`/`FAIL` per check) |
| `live-drive.log` | full transcript of the final run — 18 checks, all pass |
| `transcripts/S*.stderr` / `.stdout` | the actual streams each case produced |
| `transcripts/regression-teardown-endpoint-safety.log` | `tests/fm-teardown-endpoint-safety.test.sh` |
| `transcripts/regression-herdr-backend.log` | `tests/fm-backend-herdr.test.sh` |

## Readings exercised

| case | reading | result |
|---|---|---|
| S1 | co-claimant endpoint gone (`missing`, `dead`), copy landed, own processes own the slot → collected, slot returned | pass |
| S2 | both endpoints live, plain and `--force` → refused, nothing mutated, no release order offered | pass |
| S3 | this record gone + co-claimant live → refused, names the record to tear down first; following that order collects the pair | pass |
| S3b | both records gone → still contested, no order invented | pass |
| S4 | orphaned process rooted in the slot (ppid 1) → refused with the pid diagnostic | pass |
| S4b | unlanded work in the shared copy, plain and `--force` → refused, copy untouched | pass |
| S4c | secondmate co-claimant → refused even with `--force` | pass |
| S5 | symlinked fm home: release works, self-collision does not | pass |
| S6 | backend contract: real tmux pane leader named; absent window names nothing; real herdr pane shell pid returned | pass |
| S6b | reported reproduction slot: herdr root pid 53633 is the ancestor of all four pids rooted in it | pass |
| S7 | same aliased home: pre-fix build refuses against its own record (self-collision reproduced live), branch tip collects it | pass |

## Not driven live

The guard's "the backend cannot name the pane leader" refusal branch. On a stable
host no shipped backend reaches it: `state=alive` and a nameable pane leader are
the same read for both tmux (`list-windows` membership) and herdr (`pane
process-info` agreeing on the pane id) — verified live in S6. Driving it needs a
stubbed backend probe, which the repo's regression test does
(`tests/fm-teardown-endpoint-safety.test.sh`, case (d)
`unprovable pane leader`).
