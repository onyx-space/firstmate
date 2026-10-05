# fm-lint.sh progress reporting — live validation evidence

Method: drove the real `bin/fm-lint.sh` (real pinned ShellCheck 0.11.0) in the
worktree at commit `b23c639`; no stubs or mocks were used for these runs.

## 1. CI-parity single invocation emits a bounded ticker (cadence 1s)

Command (explicit paths keep `--external-sources` + full dataflow, the same
single-invocation worker branch CI uses):

    env CI='' GITHUB_ACTIONS='' FM_LINT_PROGRESS_SECS=1 FM_LINT_JOBS=1 \
      bin/fm-lint.sh bin/fm-lock.sh bin/fm-peek.sh bin/fm-on.sh \
                     bin/fm-wake-grant.sh bin/fm-marker-lib.sh

Result: exit 0, stdout empty, stderr shows 82 ticker lines, one per second,
each naming the live target count of the shard:

    fm-lint.sh: ShellCheck still running over 2 target(s), 1s elapsed
    ...
    fm-lint.sh: ShellCheck still running over 3 target(s), 1s elapsed
    ...
    fm-lint.sh: ShellCheck still running over 3 target(s), 75s elapsed

Last tick at 75s; the run finished at ~83s with no tick after the invocation
returned (ticker stopped before the worker returned).

## 2. Default cadence is 30s

Same workload with `FM_LINT_PROGRESS_SECS` unset:

    fm-lint.sh: ShellCheck still running over 3 target(s), 30s elapsed
    fm-lint.sh: ShellCheck still running over 3 target(s), 60s elapsed

Result: exit 0, first tick at exactly 30s -> default is 30.

## 3. FM_LINT_PROGRESS_SECS=0 disables the ticker, verdict unchanged

Same workload with `FM_LINT_PROGRESS_SECS=0`: exit 0, stdout empty, and
stderr contains only the two header lines — 0 ticker lines while ShellCheck ran
for ~75s. Identical clean verdict to run 1.

## 4. Per-target (local changed-file) mode prints checked i/N <path>

Command (no explicit paths, no CI env -> local changed-file mode,
FOLLOW_SOURCES=0 -> per-target loop):

    env GITHUB_ACTIONS='' CI='' bin/fm-lint.sh

Result: exit 0; stderr shows

    fm-lint.sh: local changed-file mode; ShellCheck source following disabled
    fm-lint.sh: checked 1/1 bin/fm-lint.sh

## 5. Verdict/flags unchanged — progress never touches stdout

Two runs over a temp defect fixture (`echo $undefined_variable`,
SC2154+SC2086), one with progress on and one off:

    FM_LINT_PROGRESS_SECS=1 bin/fm-lint.sh /tmp/fm-lint-defect/bad.sh
    FM_LINT_PROGRESS_SECS=0 bin/fm-lint.sh /tmp/fm-lint-defect/bad.sh

Both: exit=1, byte-identical stdout diagnostics (SC2154 warning, SC2086 info).
Progress output is stderr-only, so CI's diagnostic stream is untouched.
