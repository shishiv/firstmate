# Steer and tear down

## Sub-features

- `bin/fm-send.sh` writes a durable inbox record and rings a doorbell line.
- `bin/fm-peek.sh` shows the terminal screen.
- `bin/fm-teardown.sh` closes the terminal and returns the worktree.

## How to get to it (user POV)

The captain gives a mid-task instruction; firstmate steers the worker, and cleans up when it lands.

## Driving it with the lab

`scripts/verify.sh` steps "steer once" and "cleanup through teardown".
Observable end state: `state/vf1.inbox/*.msg` exists, the stand-in logged the doorbell line, and the private core lists no terminal after teardown.

## Gotchas

- Teardown needs the decision gate closed first: `bin/fm-captain-hold.sh complete vf1 --none`.
- A steer into a real harness composer (submit confirmation) is not proved by a stand-in.
