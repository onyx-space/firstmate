# Live validation — Gitea (instance-hosted HTTP forge) merge watch + upgrade migration

Branch: `fm/pr-check-rejects-http-internal-forge`
Base: `3e447e7fbd668e3d9424e211102e9315f4fd5fa1` → Target: `18d87e62ca571f4ac8a90ddedef53dc1ecc6f449`

Intent: when the captain merges a pull request on the internal Gitea
(h machine `10.0.99.5:3000`, company `127.0.0.1:8418`), MAIN is woken and
replies, exactly as for a GitHub merge — without disturbing other work (that is,
without the upgrade leaving armed watches stale and waking MAIN on every sweep).

Everything here was driven against the real product binaries from the worktree.
No fake `curl`, no stub forge: the poll made real HTTP requests.

| file | what it shows |
|---|---|
| `01-http-forge-merge-wake.txt` | Arming + watching a Gitea pull request, and the wake on merge. Includes the same flow driven against the **real** internal Gitea (`10.0.99.5:3000`) with a real merged pull request (throwaway repo, deleted afterwards). |
| `02-upgrade-poll-migration.txt` | Red-before/green-after of the upgrade migration: a pre-change watch is rejected and its merge missed, then re-anchored and its merge observed. Also the real `bin/fm-update.sh` run (re-exec + refresh), idempotence, the no-wake-storm sweep, and loud reporting of a watch that cannot be re-anchored. |
| `03-adversarial-guards.txt` | Refusal of an unlisted host and of a refused token at arming; the poll staying silent for doctored sidecar identities and a de-configured host; and `bin/fm-watch-arm.sh` re-anchoring a stale watch before its first check sweep. |

Result: every scenario was driven live and passed.

Reproduction notes: the local forge was a ~60-line Python `http.server` on
`127.0.0.1:8731` serving the Gitea pull-request API (real response shape,
`Authorization: token` required); the "pre-change bytes" are `git show
3e447e7:bin/fm-pr-poll.sh`. The real-Gitea leg created a throwaway repo
`admin/fm-live-e2e` through the Gitea API and deleted it afterwards (the instance
is back to its original three repositories).
