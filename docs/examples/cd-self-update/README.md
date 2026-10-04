# CD self-update wiring: the two shapes

`bin/fm-cd-self-update.sh` is one bounded action: fast-forward this home, put its
tracked launch surfaces in place, start Pi once and assert it reports no error,
roll back and raise an alarm on any failure, and print one line per stage.
It arms nothing itself, so the shape below decides what invokes it.

## The event shape (the live one)

The doorbell is a merge report the relay already delivers over olink to the lane
serving the repository, plus one request file that session writes with
`bin/fm-cd-request.sh`. The platform's own file watch starts the chain, so
nothing polls and nothing runs on an idle endpoint.

- `fm-cd.path` + `fm-cd.service` - systemd user units: `PathChanged` on the
  request file starts one chain run.
- `com.onyx.fm-cd.plist` - launchd: `WatchPaths` on the same file.

Install on the endpoint that maintains the repository, substituting that
endpoint's user, home and checkout path:

```
install -Dm644 fm-cd.path fm-cd.service ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now fm-cd.path
```

```
cp com.onyx.fm-cd.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/"$(id -u)" ~/Library/LaunchAgents/com.onyx.fm-cd.plist
```

## The timer shape (rejected)

`fm-cd.timer` is kept only as the rejected example: a fixed 15-minute poll is
slow when there is something to install and empty work when there is not.
It is here so the decided shape is readable against the shape it replaced, not
as a recommendation.
