# CD self-update: one bounded action per merge event

`bin/fm-cd-self-update.sh` brings a firstmate home to the merged commit and proves the home still starts Pi, and it stops exactly there.
Restarting supervision and taking a session over stay the captain's own actions, so the chain arms no watcher, claims no fleet lock, and never touches a running session.
This document owns the contract, the doorbell that invokes it, and the two wiring shapes.

## The contract

- **One action per event.** A merge report invokes the script once; it exits when that run ends.
  No daemon, no interval, and nothing resident.
- **Re-entrant and idempotent.** A replayed event, or a second caller, costs nothing: an already-current home reports `pull: already current` and the smoke run repeats under its own bound.
- **Bounded.** The smoke run is hard-bounded by `bin/fm-timeout-lib.sh`'s `fm_run_timed` (`FM_CD_SMOKE_TIMEOUT`, 90 seconds by default), the repo's single owner of bounded execution, so a hung child or grandchild cannot outlive the bound.
- **Recorded, then ignored.** `--reason` and `--repo` are written into the run's own output and into the failure record; nothing branches on them.
- **Failure keeps the scope.** A failed run returns the checkout to the head recorded before stage 1, only when the tree is clean and only over the commits this run moved, and appends one line to `state/fm-cd-failures.log`.
  It never forces, never stashes, and never discards unlanded work.
- **The report is per stage.** Each stage prints one line (what it did, or why it skipped), so a reader sees the run rather than a verdict.

## The stages

| stage | what it does | how it fails |
|---|---|---|
| pull | fast-forwards the default branch from `origin` under the guarded fast-forward rule (default branch, clean tree, real fast-forward). `bin/fm-ff-lib.sh` owns that rule for the other sync paths; this stage keeps its own copy so the chain's untracked launch artifacts do not count as dirty and an unreachable origin or a failed advance is an alarm rather than a skip | an unreadable remote: alarm, no move; a diverged remote: skipped, no move |
| install | puts the tracked launch surfaces in place: repairs an executable bit only where git records mode 100755 (the 100644 entries are libraries meant to be sourced), writes the `CLAUDE.md` pointer, relinks `.claude/skills`, and checks both project extensions are readable | a missing surface: alarm |
| smoke | starts Pi once in this home (`pi -p "reply with OK" --no-session`) and asserts four facts: exit 0, no `Error:`, no `Warning:`, and the reply | any of the four: alarm |
| rollback | returns the checkout to the pre-run head, only with a clean tree | a dirty tree: alarm and no move |
| report | one line per stage, plus the failure record | - |

Nothing under `data/`, `state/`, `config/`, `projects/` or `.no-mistakes/` is touched by the pull or the install stage, so a fast-forward never disturbs in-flight work.

## The doorbell

The event is a **merged pull request** reported to the lane that serves the repository, which is what the relay already delivers over olink.
That session writes one request file with `bin/fm-cd-request.sh`, and the platform's own file watch starts the chain.

- **Only the merged transition is accepted.** The relay's report tells the two apart in its own line (`open → merged` against `open → closed`); `bin/fm-cd-request.sh` refuses anything but `--event merged`, because installing a commit nobody merged is the failure this rule exists to prevent.
- **The request's shape is the fleet's existing one**, so no second mechanism exists: `{"repository", exactly one of "pr" or "commit", "asked_by", "at"}`, written to `${XDG_CONFIG_HOME:-$HOME/.config}/olink/deploy/request.json`, landed by writing a temporary file and renaming it into place.
  A malformed request is refused by name rather than guessed at, and a run that finds no request is a no-op.
- **An unread wake means no run.** If no session reads the merge report, no request file appears and nothing is installed; there is no interval fallback, and the manual `/updatefirstmate` path remains.

## Wiring

`docs/examples/cd-self-update/` carries both shapes: the live event shape (systemd `fm-cd.path` + `fm-cd.service`, or launchd `com.onyx.fm-cd.plist` with `WatchPaths`) and the rejected timer shape, kept so the decision is readable against what it replaced.

## Verification

`tests/fm-cd-self-update.test.sh` drives the chain against a fake Pi and asserts each of the four smoke facts separately, plus the rollback scope and the failure record.
`tests/fm-cd-request.test.sh` drives the request writer: the shape it lands, its atomicity, and the refusals (a non-merge event, both or neither of pr and commit, a malformed commit id).

## Boundaries

- No new resident process and no new repository: the chain is a script invoked per event, and the request writer is a script invoked by a session.
- The rule text stays owned by `origmd`; this document and these scripts cite it and copy none of it.
