# Evidence: parent-channel note fold (UTF-8 boundary) + voice deny list

Change under test: `fm/parent-channel-note-byte-truncation-splits-utf8` @ `18f4496`
(base `99e027c`). The diff replaces the byte-cutting `cut -c1-1200` fold in
`bin/fm-parent-channel-lib.sh` `fm_parent_channel_clean_note()` with an explicit
locale-independent whole-character cut, routes `bin/fm-inactive-reconcile.sh`
`clean_field()` through that one fold, and restores strict decoding of the durable
voice records reads.

Everything below was driven in this run. The publisher scenarios drive the real
CLI (`bin/fm-inactive-reconcile.sh`, `bin/fm-captain-hold.sh`) and then read the
persisted channel file with a strict UTF-8 decoder — the consumer the field
failure reported. Pre-fix comparisons use the base-commit implementation of the
same function, or the full base-commit tree; nothing about the code under test is
stubbed.

## Files

| artifact | what it shows |
|---|---|
| `parent-channel-fold-macos.txt` | macOS: publisher e2e (change vs pre-fix), captain-hold publisher, framing, pre-damaged channel, in-tree regression test both ways |
| `parent-channel-fold-linux-gnu.txt` | Linux, GNU coreutils 9.4 (h): fold sweep, in-tree test both ways, publisher e2e both ways, the changed call site's own suite |
| `parent-channel-fold-linux-w.txt` | Linux, uutils cut 0.8.0 (w, the machine where the field failure was found): same set |
| `parent-channel-fold-two-byte-shape.txt` | the 2-byte character shape (U+00E9) at the publisher level, all three hosts |
| `fold-contract-probe.txt` | exact output of the fold vs an independently computed whole-character prefix, 17 cases, three hosts |
| `voice-deny-list-damaged-record.txt` | the damaged-record deny-list case: suite passes on the change, fails on the tolerant decode, plus the CLI answer itself |
| `fm-fold-e2e.sh` | driver: real reconcile publisher → bounded CJK/2-byte/emoji note at several alignments → strict decode of `state/parent-replies.status` |
| `fm-hold-e2e.sh` | driver: real `fm-captain-hold.sh hold --reason <long CJK>` (a second call site) |
| `fm-framing-e2e.sh` | driver: a CRLF ledger line carrying a tab must stay one clean channel line |
| `fm-damaged-channel-e2e.sh` | driver: a channel file already holding an invalid byte keeps accepting publications and is not rewritten |
| `fold-align.sh` | driver: 42 alignments of the fold alone, counting invalid UTF-8 and over-bound output |
| `fold-contract-probe.sh` | driver: exact-output probe incl. 2-byte shapes and the exact-bound values |

## Headline numbers

* fold alone, 42 alignments: pre-fix `invalid_utf8=30` (w, uutils) / `over_bound=42` (h, GNU, ambient) — change `0 / 0` everywhere.
* publisher e2e, 8 alignments: pre-fix 6 strict-decode failures — change 0, on macOS, GNU/Linux and uutils/Linux, with byte-identical fault positions.
* in-tree regression test: fails against the pre-fix fold on both Linux hosts and on macOS; passes against the change.
* captain-hold publisher: pre-fix folded note 2747 bytes (bound 1200) — change 1199.
