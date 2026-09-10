# fm/herdr-server-exec — mechanism verification

Change: `fm_backend_herdr_server_ensure` now launches the session's herdr server via
`exec` (`fm_backend_herdr_server_exec`) instead of `fm_backend_herdr_cli ... server`,
so no forked shell is left waiting on the server.

## 1. Regression reproduction (test fails before, passes after)

The new test `test_server_ensure_leaves_no_forked_shell_waiting_on_the_server`
detects whether the herdr server is left parented to a forked shell.

- Against **base** (`b1ad702`, original launch): FAILS —
  `not ok - the herdr server is left parented to a forked shell ('bash') that waits on it indefinitely`
- Against **target** (`686d3d8`, exec launch): PASSES —
  `ok - fm_backend_herdr_server_ensure: exec's the server, so no forked shell outlives the call waiting on it`

## 2. Mechanism: the stray bash holds NO caller descriptor (it is process hygiene, not an fd fix)

Ran the REAL base-commit `fm_backend_herdr_cli` + `fm_backend_herdr_server_ensure`
against a stateful fake `herdr` that logs its own parent, then inspected the stray
bash's open fds with `lsof`:

```
=== log content ===
server_pid=372
server_ppid=368
server parent comm = bash
stray shell fds (0-9):
    COMMAND PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
    bash    368 onyx    0r   CHR    3,2      0t0   336 /dev/null
    bash    368 onyx    1w   CHR    3,2      0t0   336 /dev/null
    bash    368 onyx    2w   CHR    3,2      0t0   336 /dev/null
```

The forked `bash` (pid 368) is the server's parent for the server's whole lifetime,
but its only fds are `/dev/null` on 0/1/2 — **no channel/pipe descriptor at all**.
This directly confirms the change's comment:

- "bash assigns a non-interactive asynchronous command's stdin from /dev/null" → fd 0 is `/dev/null`
- "the caller redirects stdout/stderr" → fd 1/2 are `/dev/null`
- "the forked shell holds no caller descriptor to begin with" → no high fd, no ssh-channel fd

So the mechanism is **process hygiene** (a stray `bash` waits on the server forever),
NOT a file-descriptor fix. The earlier "bash leaves redirect-saved stdout/stderr on a
high fd, holding the ssh channel open" theory is disproven: no such fd exists.

## 3. End-to-end with the real herdr binary (0.8.2)

`tests/fm-backend-herdr-smoke.test.sh` (real herdr, isolated lab session) passes fully,
including the exec-based relaunch path:

```
ok - real herdr: container_ensure starts the isolated session's server, ...
ok - real herdr: BOTH workspace ids/labels AND both tasks' pane ids survive a session stop + fresh server restart (multi-workspace shape)
```

`fm_backend_herdr_server_ensure` (now exec-based) is exercised directly after a
`session stop`, and the server starts and reports running correctly.

## Conclusion

The change is correct as written. The comment's mechanism description is accurate
and verified empirically; no comment rewrite is needed.
