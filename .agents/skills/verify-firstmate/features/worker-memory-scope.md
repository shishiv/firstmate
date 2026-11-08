# Worker memory scope

## Sub-features

- Every pane launch runs through `bin/fm-worker-memory-scope.sh` in `firstmate.slice/fm-worker-<id>-<spawn_gen>.scope` with `MemoryHigh` from `config/worker-memory-high` (absent: 3G).
- The worker keeps its PID, so the harness ancestry and `bin/fm-crew-state.sh` read it as before.
- A relaunch gets a new scope, and systemd collects the old one.
- `off` in `config/worker-memory-high` gives the uncapped launch.

## How to get to it (user POV)

Nothing to do: every spawn and relaunch is capped. The captain writes `off` or another size to `config/worker-memory-high` to change it.

## Driving it with the lab

`scripts/verify.sh` steps "worker memory scope" (the hc scout `vf1`) and "relaunch and off switch on a private tmux server" (scout `vf2`).
Observable end state, in `scope.txt`: `MemoryHigh=3221225472` for each scope, the stand-in's `/proc/<pid>/cgroup` ending in `/firstmate.slice/<unit>`, `ancestry=comm claude`, and `crew-state=state: working`.
After teardown or relaunch, `systemctl --user show <old unit> -p LoadState` reads `not-found`.
With `off`, the relaunched stand-in's cgroup names no `fm-worker-` scope and the launch file carries no wrapper.
The `[compare]` lines show that `bin/fm-crew-state.sh` and tmux's `pane_current_command` read the scoped worker exactly as the uncapped one, both while it runs and after it stops.
`relaunch.txt` records which relaunch path ran.

## What this run does not prove

- The lab panes run with a private `XDG_RUNTIME_DIR`, so they reach the user manager through the helper's `--machine=<user>@.host` branch. The direct `--user` branch is proved by the real-systemd case in `tests/fm-worker-memory-scope.test.sh`.
- `bin/fm-control.sh relaunch` refuses the stand-in (it is not a verified harness), so the lab relaunches through `bin/fm-spawn.sh <id> --relaunch` after stopping it. `tests/fm-spawn-worker-memory-scope.test.sh` drives `bin/fm-control.sh relaunch` against a fake pane.
- The kernel throttling itself: no lab worker grows past 3G.

## Gotchas

- `bin/fm-control.sh` has no relaunch on hc (`fm_control_backend_relaunch_supported`), so the relaunch half runs on a private tmux server under the lab home's `TMUX_TMPDIR`.
