# Evidence: promptless `before_agent_start` no longer throws in the supervision extensions

Branch `fm/fm-branch-prompt-undefined-x1`, base `452749b`, target `7cba259`.

## What was driven

`live-probe.mjs` creates a **real** `AgentSession` through the **real** installed Pi
runtime (`/home/onyx/code/pi/packages/coding-agent`, the local fork build that `pi`
on this machine runs, v1.3.0), loads the tracked extension through Pi's own
`DefaultResourceLoader`, binds the same `onError` listener Pi's interactive mode
binds, and then drives the exact production sequence:

1. `session.prompt("...")` - an ordinary captain prompt (`messageType: "user"`,
   `before_agent_start` carries `prompt`).
2. `session.sendCustomMessage({customType: "fm-branch-processing", ...}, {triggerTurn: true})`
   - how the supervision branch delivers its own hidden processing request. On the
   real runtime this raises `before_agent_start` with `messageType: "custom"` and
   **no `prompt` field**.

The model provider is a local fake whose only `fetch` is intercepted in-process,
so no request and no credential leaves the machine.

## Files

| file | what it shows |
| --- | --- |
| `live-pi-branch-promptless-prefix-repro.log` | base-commit `fm-branch-supervision.ts` on the real runtime: Pi reports `event: "before_agent_start"`, `Cannot read properties of undefined (reading 'trim')` - the reported error, reproduced live. |
| `live-pi-branch-promptless-fixed.log` | target-commit source: the same two runs, `extensionErrors: []`, both `before_agent_start` events recorded (captain with prompt, programmatic without). |
| `live-pi-branch-promptless-fixed-line-reached.log` | target-commit source with a probe-only trace: the guarded staging line is reached for the promptless run (`prompt=undefined`) and does not throw. |
| `live-pi-watch-promptless-fixed.log` | target-commit `fm-primary-pi-watch.ts` on the real runtime: same sequence, `extensionErrors: []`. |
| `live-pi-watch-promptless-prefix.log` | base-commit watcher on the real runtime: also no error - pre-fix `consumeWake(generation, undefined)` matches no wake and is already benign, so this guard is defensive rather than a live bug fix. |
| `test-branch-promptless-fixed.log` | the new focused test in `tests/fm-pi-branch-extension.test.sh` passing on the target commit. |
| `test-branch-promptless-prefix-fails.log` | the same test against the base-commit extension source: fails with the reported `trim` TypeError. |
| `test-watch-promptless-fixed.log` / `test-watch-promptless-prefix-pass.log` | the new focused test in `tests/fm-pi-watch-extension.test.sh` - it passes on both, consistent with the guard being defensive. |
| `live-probe.mjs`, `live-probe-run.sh` | the harness used to produce the live logs. |

## Reproducing

The two suites are single files that run every test function listed at their
bottom. To run one function alone, cut the file at the line where the call list
starts and append only the wanted call (the temp harness this run used is shown
below; it was deleted from the worktree afterwards):

```
# every function definition, none of the calls, then the one call
sed -n '1,5000p' tests/fm-pi-branch-extension.test.sh > tests/zz-tmp-branch-only.test.sh
echo 'test_branch_promptless_programmatic_run_is_not_captain_dialog' >> tests/zz-tmp-branch-only.test.sh
bash tests/zz-tmp-branch-only.test.sh

sed -n '1,4092p' tests/fm-pi-watch-extension.test.sh > tests/zz-tmp-watch-only.test.sh
echo 'test_pi_programmatic_before_agent_start_consumes_nothing' >> tests/zz-tmp-watch-only.test.sh
bash tests/zz-tmp-watch-only.test.sh
```

To point the same test at the base-commit extension source, add an override line
between the two (`EXT=<path to base-commit fm-branch-supervision.ts>`): the
fixture copies `$EXT`, so the test then drives the pre-fix extension.

Live probe against the real Pi runtime (needs the local Pi build):

```
PI_PACKAGE_DIR=/home/onyx/code/pi/packages/coding-agent \
  ./live-probe-run.sh <path-to-fm-branch-supervision.ts> <tag>
```

The extension must sit next to its `.pi/extensions/lib/*.ts` imports; a bare copy
in another directory fails to load and silently produces no events.
