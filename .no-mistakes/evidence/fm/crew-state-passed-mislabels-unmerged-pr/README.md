# Evidence — crew-state-passed-mislabels-unmerged-pr

Intent: the status line must not claim a PR merged that has not been proven
(机队状态行不能凭空声称一个没被证实的合并).

## What was driven live

`live-verify.sh <worktree-root>` drives the **real** `bin/fm-crew-state.sh`
against **real** inputs:

- run status from a **real** `no-mistakes axi status` call inside
  `/Users/onyx/code/cbm-axi`, whose checked-out branch tip (`8b3782b8`) is
  exactly the head of a real completed run (`outcome: passed`,
  `pr: https://github.com/onyx-space/cbm-axi/pull/2`);
- the merge proof from the **real** firstmate path: `bin/fm-pr-poll.sh`
  observes the real forge with `gh`, and `bin/fm-merge-outcome-lib.sh`'s
  `fm_merge_outcome_report` publishes the `*.pr-poll-merge-notified` record
  exactly as `bin/fm-watch.sh` does;
- task `state/<id>.meta` files and merge records in a throwaway `$TMPDIR` home,
  so the user's real firstmate state is untouched.

Same driver also runs two older revisions against the same live inputs:
base `aba68fc` (pre-change) and `e40b4b4` (the reviewed meta-first fix), to
reproduce the reported behaviour before the change.

| case | live inputs | fixed (this branch) | older revision |
|---|---|---|---|
| A | passed run, no merge record | `run passed: PR held for merge: <url>` | base `aba68fc`: `run passed: PR merged/closed` |
| B | passed run, merge recorded by the real poll from a real forge observation | `run passed: PR merged: <url>` | — |
| C | stale meta names another real merged PR; the run's own PR has no record | held for merge, names the run's PR, never the stale one | `e40b4b4`: `run passed: PR merged` |
| D | merge record present but empty | held for merge | — |

Reproduce: `./live-verify.sh /Users/onyx/.no-mistakes/worktrees/9573b29b9316/01M26XWAR71A7JAAGCGYNJ3F4F`
(needs `no-mistakes`, `gh`, and the initialized checkouts above).

`fm-crew-state.test.log` is the targeted repo suite run,
`tests/fm-crew-state.test.sh`, which drives the real script with stubbed
upstream tools (89 checks, all green).

## Limits of the live drive

- No bindable live run on this machine has an **open** PR: both bindable
  completed runs (`cbm-axi#2`, `tasks-axi#1`) reference PRs the forge already
  reports MERGED, and every other initialized repo's completed run fails the
  branch+head attribution rule (branch tip advanced past the run head). The
  open-PR instantiation of case A is therefore covered by the repo suite
  (`test_terminal_passed_without_merge_record_says_held_for_merge`), not live.
- A passed run with **no PR identity at all** cannot be bound live (the only
  such runs, in `cyber-mux` and `prime-agent`, fail the head rule), so that
  acceptance criterion is covered by the focused test
  `test_terminal_passed_without_pr_identity_names_no_url` added in this run.
