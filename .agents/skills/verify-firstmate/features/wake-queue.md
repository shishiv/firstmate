# Status line reaches the wake queue

## Sub-features

- `bin/fm-watch.sh` signal wake on a changed `state/<id>.status`.
- `bin/fm-wake-drain.sh` presenting the unread line and the outcome backstop.

## How to get to it (user POV)

A worker appends `done [at=...]: ...` to its status file and firstmate is woken.

## Driving it with the lab

Start `FM_HOME=<lab> FM_POLL=1 bin/fm-watch.sh`, append a `done` line, expect `signal: .../vf1.status` in its output, then run `bin/fm-wake-drain.sh`.
Observable end state: the drain prints `vf1 done [at=...]: lab scout finished`.

## Gotchas

- The run does not acknowledge the wake (`--ack-through`); the lab home is discarded.
- "WATCHER DOWN" in later output is expected: the watcher exits after queuing one wake.
