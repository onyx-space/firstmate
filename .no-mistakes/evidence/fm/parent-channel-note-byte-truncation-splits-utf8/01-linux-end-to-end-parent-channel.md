# Linux verification: the parent channel's note fold never splits a UTF-8 character

Branch `fm/parent-channel-note-byte-truncation-splits-utf8`, target commit `032d0cd`.
The fix is in `bin/fm-parent-channel-lib.sh` (`fm_parent_channel_clean_note`), which
`bin/fm-inactive-reconcile.sh`'s `clean_field` and every other publisher now share.

The reported defect only reproduces where `cut -c` counts bytes, so every result below
was produced on Linux, not on this agent's macOS host:

| host | uname | `cut` | note |
|---|---|---|---|
| h | Linux aarch64 | GNU coreutils 9.4 | the version named in the field report |
| w | Linux x86_64 (WSL2) | uutils coreutils 0.8.0 | counts bytes whatever the locale |
| m | Darwin arm64 | BSD | the contrast the intent describes: does not reproduce |

## 1. End-to-end: a secondmate home publishes a child's terminal ledger note

`drive.py <repo-root> <out-dir>` builds a real secondmate home (identity marker +
`route=local` parent binding) with 16 direct children, each holding a terminal
`done:` ledger line whose note is far past the channel's 1200-byte bound. The
alignments are `0..7` ASCII bytes of padding before a 3-byte (`中`) or 4-byte (`😀`)
run, so the bound lands mid-character in most of them. It then runs the REAL
`bin/fm-inactive-reconcile.sh scan` -- the publisher the watcher runs on every poll --
and reads the parent home's `state/mate.status` channel file.

The expectation for each line is computed independently in Python (the largest prefix
of at most 1200 bytes that ends on a character boundary); every check is on the bytes
the product wrote.

### After the fix, on h
| case | note bytes | expected | valid UTF-8 | note text kept | result |
|---|---|---|---|---|---|
| child-cjk-0 (pad 0) | 1198 | 1198 | yes | yes | pass |
| child-cjk-1 (pad 1) | 1199 | 1199 | yes | yes | pass |
| child-cjk-2 (pad 2) | 1200 | 1200 | yes | yes | pass |
| child-cjk-3 (pad 3) | 1198 | 1198 | yes | yes | pass |
| child-cjk-4 (pad 4) | 1199 | 1199 | yes | yes | pass |
| child-cjk-5 (pad 5) | 1200 | 1200 | yes | yes | pass |
| child-cjk-6 (pad 6) | 1198 | 1198 | yes | yes | pass |
| child-cjk-7 (pad 7) | 1199 | 1199 | yes | yes | pass |
| child-emoji-0 (pad 0) | 1199 | 1199 | yes | yes | pass |
| child-emoji-1 (pad 1) | 1200 | 1200 | yes | yes | pass |
| child-emoji-2 (pad 2) | 1197 | 1197 | yes | yes | pass |
| child-emoji-3 (pad 3) | 1198 | 1198 | yes | yes | pass |
| child-emoji-4 (pad 4) | 1199 | 1199 | yes | yes | pass |
| child-emoji-5 (pad 5) | 1200 | 1200 | yes | yes | pass |
| child-emoji-6 (pad 6) | 1197 | 1197 | yes | yes | pass |
| child-emoji-7 (pad 7) | 1198 | 1198 | yes | yes | pass |

Whole-record consumer (a strict UTF-8 decode of the entire 16-line channel file -- the
failure the intent names, one bad byte making the whole record unreadable):

* after the fix: **decode succeeds** (decoded 21531 bytes, 16 lines)
* before the fix, same host, same drive: **UnicodeDecodeError: invalid continuation byte at byte 1274 (0xe4) of 21552**

At-most-once after deleting the delivery receipt and replaying the same outcomes: 16 lines on the first pass, 16 after the replay, so the exact-content append still suppresses the duplicate.

### Before the fix (base commit `99e027c`), on h
| case | note bytes | expected | valid UTF-8 | note text kept | result |
|---|---|---|---|---|---|
| child-cjk-0 (pad 0) | 1200 | 1198 | **NO** | yes | fail |
| child-cjk-1 (pad 1) | 1200 | 1199 | **NO** | yes | fail |
| child-cjk-2 (pad 2) | 1200 | 1200 | yes | yes | pass |
| child-cjk-3 (pad 3) | 1200 | 1198 | **NO** | yes | fail |
| child-cjk-4 (pad 4) | 1200 | 1199 | **NO** | yes | fail |
| child-cjk-5 (pad 5) | 1200 | 1200 | yes | yes | pass |
| child-cjk-6 (pad 6) | 1200 | 1198 | **NO** | yes | fail |
| child-cjk-7 (pad 7) | 1200 | 1199 | **NO** | yes | fail |
| child-emoji-0 (pad 0) | 1200 | 1199 | **NO** | yes | fail |
| child-emoji-1 (pad 1) | 1200 | 1200 | yes | yes | pass |
| child-emoji-2 (pad 2) | 1200 | 1197 | **NO** | yes | fail |
| child-emoji-3 (pad 3) | 1200 | 1198 | **NO** | yes | fail |
| child-emoji-4 (pad 4) | 1200 | 1199 | **NO** | yes | fail |
| child-emoji-5 (pad 5) | 1200 | 1200 | yes | yes | pass |
| child-emoji-6 (pad 6) | 1200 | 1197 | **NO** | yes | fail |
| child-emoji-7 (pad 7) | 1200 | 1198 | **NO** | yes | fail |

12 of 16 lines carry a truncated character; the channel file no longer decodes at all.

### The bytes at the cut

```
new  child-cjk-1   tail: e4 b8 ad e4 b8 ad e4 b8 ad         (complete 中)
old  child-cjk-1   tail: b8 ad e4 b8 ad e4 b8 ad e4         (bare lead byte, invalid)
new  child-emoji-2 tail: f0 9f 98 80 f0 9f 98 80            (complete 😀)
old  child-emoji-2 tail: f0 9f 98 80 f0 9f 98 80 f0 9f 98   (3 of 4 bytes, invalid)
```

On `w` (uutils coreutils 0.8.0, x86_64) the same drive reaches the same verdict: after
the fix 16/16 cases pass and the whole file decodes; before the fix 4/16 pass and the file fails to decode.

## 2. The repository's own regression test, on Linux

`tests/fm-parent-channel.test.sh` is the regression test the intent requires (multibyte
text plus a cutting alignment, asserting valid UTF-8 output, verified on Linux). It folds
84 boundary alignments twice, once under the ambient locale and once under `LC_ALL=C`.

```
h (GNU coreutils 9.4), after the fix,  LC_ALL=C: ok - the note fold keeps a bounded one-line note that is valid UTF-8 (84 boundary alignments, ambient locale and LC_ALL=C)
h (GNU coreutils 9.4), before the fix, LC_ALL=C: not ok - the fold split a multibyte character at ASCII-prefix 0 in the ambient locale, so the channel line carried invalid UTF-8
w (uutils coreutils 0.8.0), after the fix,  LC_ALL=C: ok - the note fold keeps a bounded one-line note that is valid UTF-8 (84 boundary alignments, ambient locale and LC_ALL=C)
m (macOS Darwin arm64), after the fix, LC_ALL=C: ok - the note fold keeps a bounded one-line note that is valid UTF-8 (84 boundary alignments, ambient locale and LC_ALL=C)
```

The test fails against the pre-fix code on Linux and passes against the fix: the
reproduce-then-fix shape the intent asks for. `tests/fm-voice-relay.test.sh` (the
deny-list invariant added on this branch) also passes on h: `all voice relay cases passed`.

## 3. A second real publisher: `bin/fm-captain-hold.sh`

The fold is shared, so the fix has to reach its other call sites. `drive_hold.sh` drives
the real `fm-captain-hold.sh hold <task> --reason <long CJK reason>` CLI in a secondmate
home and reads the line it publishes on the parent channel.

```
after the fix:  {"hold_rc": 0, "channel_bytes": 1289, "reason_bytes": 1832, "channel_path": "/tmp/fm-hold-world.3obAPh/main/state/mate.status", "channel_lines": 1, "strict_decode": true, "one_line": true, "folded_reason_bytes": 1199, "bound_ok": true, "human_readable": true, "no_embedded_newline_or_tab": true, "channel_head": "needs-decision [key=captain-hold-sample-long-reason-1]: captain hold sample-long"}
before the fix: {"hold_rc": 0, "channel_bytes": 1290, "reason_bytes": 1832, "channel_path": "/tmp/fm-hold-world.G6PC5B/main/state/mate.status", "channel_lines": 1, "strict_decode": false, "decode_error": "byte 1288 0xe4: invalid continuation byte", "one_line": true}
```

After the fix the channel line is one line, decodes strictly, keeps the note's text, and
folds the reason to 1199 bytes on a character boundary. Before the fix the same call
writes a line a strict decoder rejects at byte 1288 (`0xe4`, a truncated `中`).

## 4. Adversarial probes against the shared fold

`drive_edge.py` calls `fm_parent_channel_clean_note` out of the real
`bin/fm-parent-channel-lib.sh` in a fresh bash, varying the alignment, the size, and the
caller's locale, and asserting on the printed bytes.

### After the fix (15/15 probes pass)

| probe | locale | bytes | result |
|---|---|---|---|
| pad 0 then 3-byte characters | ambient | 1200 | pass |
| pad 1 then 3-byte characters | ambient | 1198 | pass |
| pad 2 then 3-byte characters | ambient | 1199 | pass |
| pad 0 then 4-byte characters | ambient | 1200 | pass |
| pad 1 then 4-byte characters | ambient | 1197 | pass |
| pad 2 then 4-byte characters | ambient | 1198 | pass |
| pad 3 then 4-byte characters | ambient | 1199 | pass |
| ascii exactly at the bound | ambient | 1200 | pass |
| ascii one byte over the bound | ambient | 1200 | pass |
| bound cuts a character whose leading byte is the 1201st | ambient | 1200 | pass |
| bound falls exactly on a character boundary | ambient | 1200 | pass |
| input already carries an undecodable byte | ambient | 1198 | pass |
| input ends inside a character it did not create | ambient | 1198 | pass |
| 1 MiB of multibyte text | ambient | 1200 | pass |
| identical output under every caller locale | - | {'C': 1198, 'C.UTF-8': 1198, 'en_US.UTF-8': 1198, 'POSIX': 1198} | pass |

### Before the fix (7/15 probes pass)

| probe | locale | bytes | result | notes |
|---|---|---|---|---|
| pad 0 then 3-byte characters | ambient | 1200 | pass |  |
| pad 1 then 3-byte characters | ambient | 1200 | fail | output is not valid UTF-8; output is not the boundary-truncated input |
| pad 2 then 3-byte characters | ambient | 1200 | fail | output is not valid UTF-8; output is not the boundary-truncated input |
| pad 0 then 4-byte characters | ambient | 1200 | pass |  |
| pad 1 then 4-byte characters | ambient | 1200 | fail | output is not valid UTF-8; output is not the boundary-truncated input |
| pad 2 then 4-byte characters | ambient | 1200 | fail | output is not valid UTF-8; output is not the boundary-truncated input |
| pad 3 then 4-byte characters | ambient | 1200 | fail | output is not valid UTF-8; output is not the boundary-truncated input |
| ascii exactly at the bound | ambient | 1200 | pass |  |
| ascii one byte over the bound | ambient | 1200 | pass |  |
| bound cuts a character whose leading byte is the 1201st | ambient | 1200 | pass |  |
| bound falls exactly on a character boundary | ambient | 1200 | pass |  |
| input already carries an undecodable byte | ambient | 1200 | fail | output is not valid UTF-8; output is not the boundary-truncated input |
| input ends inside a character it did not create | ambient | 1200 | fail | output is not valid UTF-8; output is not the boundary-truncated input |
| 1 MiB of multibyte text | ambient | 1200 | pass |  |
| identical output under every caller locale | - | {'C': 1200, 'C.UTF-8': 1801, 'en_US.UTF-8': 1801, 'POSIX': 1200} | fail | fold output differs by locale |

### Locale independence, which is the point of dropping `cut -c`

Same note, four caller locales:

```
after the fix:  {"C": 1198, "C.UTF-8": 1198, "en_US.UTF-8": 1198, "POSIX": 1198}
before the fix: {"C": 1200, "C.UTF-8": 1801, "en_US.UTF-8": 1801, "POSIX": 1200}
```

Before the fix the cut *inherited* the caller's locale: under `C`/`POSIX` it cut at a byte
and split a character, while under `C.UTF-8`/`en_US.UTF-8` it counted characters and never
truncated at all -- the fold returned 1801 bytes against a 1200-byte bound. After the fix
the bound is a byte bound in every locale and the output is byte-identical.

