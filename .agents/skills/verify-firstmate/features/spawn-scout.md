# Spawn a scout on hc

## Sub-features

- Brief scaffold with `bin/fm-brief.sh`.
- Pool worktree from `treehouse`, launch line typed with `hc send`.
- Task metadata with `backend=hc`, `hc_session`, `hc_terminal`.

## How to get to it (user POV)

The captain asks firstmate for an investigation; firstmate runs `bin/fm-spawn.sh <id> <project> --scout`.

## Driving it with the lab

`scripts/verify.sh` step "spawn one scout on hc".
Observable end state: `spawned vf1 harness=claude kind=scout window=<session>:t1`, `backend=hc` in `state/vf1.meta`, and `hc get t1` reports a live terminal.

## Gotchas

- The stand-in is named `claude` so the harness classifier accepts it; it proves nothing about a real harness.
- The wake and spawn output carry a "WORKTREE TANGLE" banner when the checkout running the proof is on a feature branch; that is expected here and is not a failure.
