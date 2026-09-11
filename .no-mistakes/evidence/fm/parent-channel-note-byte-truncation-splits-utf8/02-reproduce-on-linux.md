# Reproducing this on Linux

The change has no UI; the Artifacts on the PR are CLI transcripts plus the real
channel file the product wrote. To rerun it:

```sh
# pick a byte-counting `cut` host: h (GNU coreutils 9.4) or w (uutils coreutils 0.8.0)
mkdir -p /tmp/fmcheck/{new,old,run}
git -C <worktree> archive --format=tar HEAD | tar -x -C /tmp/fmcheck/new
git -C <worktree> archive --format=tar HEAD | tar -x -C /tmp/fmcheck/old
# pre-fix code for the comparison:
git -C <worktree> show 99e027c260ce2c57724b6f0d725d0020ceb69a22:bin/fm-parent-channel-lib.sh \
  > /tmp/fmcheck/old/bin/fm-parent-channel-lib.sh
git -C <worktree> show 99e027c260ce2c57724b6f0d725d0020ceb69a22:bin/fm-inactive-reconcile.sh \
  > /tmp/fmcheck/old/bin/fm-inactive-reconcile.sh
chmod +x /tmp/fmcheck/old/bin/*.sh

python3 drive.py      /tmp/fmcheck/new /tmp/fmcheck/run/new          # end-to-end publisher
python3 drive_edge.py /tmp/fmcheck/new /tmp/fmcheck/run/edge-new     # adversarial fold probes
bash    drive_hold.sh /tmp/fmcheck/new /tmp/fmcheck/run/hold         # second publisher (needs jq + tasks-axi)

LC_ALL=C bash /tmp/fmcheck/new/tests/fm-parent-channel.test.sh       # the regression test
LC_ALL=C bash /tmp/fmcheck/new/tests/fm-voice-relay.test.sh          # the deny-list invariant
```

`drive.py`'s world is a throwaway `mktemp -d` tree; nothing is written into the
worktree. Swap `new` for `old` to see the defect.
