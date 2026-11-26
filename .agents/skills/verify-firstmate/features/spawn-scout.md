# Spawn a scout on hc

## Sub-features

- Brief scaffold with `bin/fm-brief.sh`.
- Pool worktree from `treehouse`, launch line typed with `hc send`.
- Task metadata with `backend=hc`, `hc_session`, `hc_terminal`.
- Herdr.app placement: `herdr.space=fm-p-<project>` at spawn, and the same labels again after a relaunch that adopts the terminal.

## How to get to it (user POV)

The captain asks firstmate for an investigation; firstmate runs `bin/fm-spawn.sh <id> <project> --scout`.

## Driving it with the lab

`scripts/verify.sh` step "spawn one scout on hc".
Observable end state: `spawned vf1 harness=claude kind=scout window=<session>:t1`, `backend=hc` in `state/vf1.meta`, and `hc get t1` reports a live terminal labeled `herdr.space=fm-p-demo`.
The step "relaunch puts an hc terminal back in its project's space" relabels a second scout to a stale space and reads the labels back after `bin/fm-spawn.sh vf3 --relaunch`.

## Gotchas

- The stand-in is named `claude` so the harness classifier accepts it; it proves nothing about a real harness.
- The wake and spawn output carry a "WORKTREE TANGLE" banner when the checkout running the proof is on a feature branch; that is expected here and is not a failure.
