# Evidence: rehome a structurally gone endpoint (fm/fm-rehome-dead-endpoint)

Change under test: `3e447e7..eefd8d11` — when a task's recorded endpoint is
structurally gone (`missing`), `fm-control relaunch` rebuilds it through the
backend's own creation path and republishes the record atomically, instead of
deadlocking against `fm-control exit`.

## Engines

The live drivers were run against `bin/` trees extracted with `git archive`
(never a hand-copied file):

| name | commit | what it is |
| --- | --- | --- |
| `target` | `eefd8d1` | the change under test |
| `prefix` | `fb2d6dc` | the change minus the abort reclaim (same rehome, no cleanup) |
| `base` | `3e447e7` | the merge base: relaunch refuses a `missing` endpoint |

## Live drives (real tmux server on a private socket, real worktree, real state)

Each driver builds a throwaway `FM_HOME`, a real git worktree, a real tmux
server on a private `-L` socket, and a real `pi` worker launched by the product
itself (a small isolated pi config dir; no session history is copied).

| artifact | driver | what it shows |
| --- | --- | --- |
| `live-rehome-target.txt` | `drivers/rehome-driver.sh` | recorded endpoint reads `missing`; `fm-control <id> relaunch` exits 0, creates the window in the recorded session in the task's own worktree, republishes `window=` in the record, `exit_result=endpoint-missing`, uncommitted `wip.txt` preserved, agent-state `alive` |
| `live-rehome-base.txt` | same, `base` engine | the same restart on the merge base: `exit=1`, no endpoint, no record change — the reported deadlock |
| `abort-target.txt` | `drivers/abort-driver.sh` | attempt 1 aborts between endpoint creation and publication (`refusing to pre-register Claude trust`): the created window is reclaimed, the record still names the gone endpoint; attempt 2 (retry) exits 0 and rebuilds the endpoint |
| `abort-prefix.txt` | same, `prefix` engine | attempt 1 leaves the orphan window behind and the retry fails with `window firstmate:fm-live2 already exists` — the regression the reclaim fixes |
| `adopt-abort-target.txt` | `drivers/adopt-driver.sh` | an endpoint that already exists and is agent-free is ADOPTED; the same pre-publication abort does **not** reclaim it (it survives at the same window id) |
| `live-reuse-target.txt` | `drivers/reuse-driver.sh` | reuse boundary: agent-free endpoint adopted at the same window id (`@1` -> `@1`), exactly one window, agent alive afterwards |
| `live-guards-target.txt` | `drivers/guards-driver.sh` | guards intact: `fm-control exit` still refuses a `missing` endpoint; `fm-spawn --relaunch` still refuses an endpoint whose pane holds a live agent, with the record unchanged |

## Hermetic run

`hermetic-relaunch-rehome-tests.txt` — `drivers/fm-control-relaunch.rehome-subset.sh`
runs the rehome/reclaim cases of `tests/fm-control-relaunch.test.sh` (real
`bin/fm-spawn.sh` and `bin/fm-control.sh`, stubbed tmux/herdr CLIs). This is the
repo's existing convention and the one the captain's decision named for the
flat-herdr acceptance, including `an aborted flat-herdr rehome reclaims the tab
it created` and `an abort never reclaims an adopted herdr tab`.

## Reproduce

```
bash drivers/rehome-driver.sh <engine-repo-root> <out-dir>
bash drivers/abort-driver.sh  <engine-repo-root> <out-dir>
bash drivers/adopt-driver.sh  <engine-repo-root> <out-dir>
bash drivers/reuse-driver.sh  <engine-repo-root> <out-dir>
bash drivers/guards-driver.sh <engine-repo-root> <out-dir>
bash drivers/fm-control-relaunch.rehome-subset.sh
```
