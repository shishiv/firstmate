# verify-firstmate features

One file per user-facing path of the task lifecycle.
`scripts/verify.sh` drives the first three together, then hands test selection to `bin/fm-test-run.sh`; the rest are not driven yet.

- [spawn-scout.md](spawn-scout.md) - `bin/fm-spawn.sh` puts a scout on the hc backend.
- [wake-queue.md](wake-queue.md) - a status line becomes a wake the supervisor drains.
- [steer-and-teardown.md](steer-and-teardown.md) - `bin/fm-send.sh` steers, `bin/fm-teardown.sh` cleans up.

Not mapped yet: ship spawns, relaunch, other backends (tmux, herdr), secondmates, and the merge path.
