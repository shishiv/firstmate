# Worker memory scope

## Sub-features

- Every pane launch runs through `bin/fm-worker-memory-scope.sh` in `firstmate.slice/fm-worker-<id>-<spawn_gen>.scope` with `MemoryMax` from `config/worker-memory-high` (absent: 2G).
- The worker keeps its PID, so the harness ancestry and `bin/fm-crew-state.sh` read it as before.
- A relaunch gets a new scope, and systemd collects the old one.
- `off` in `config/worker-memory-high` gives the uncapped launch.
- In a full scope the kernel kills the agent's command before the agent: the agent runs at `oom_score_adj` 400 and each shell-tool command at 1000 (`docs/configuration.md` "Worker memory scope").

## How to get to it (user POV)

Nothing to do: every spawn and relaunch is capped. The captain writes `off` or another size to `config/worker-memory-high` to change it.

## Driving it with the lab

`scripts/verify.sh` steps "worker memory scope" (the hc scout `vf1`) and "relaunch and off switch on a private tmux server" (scout `vf2`).
Observable end state, in `scope.txt`: `MemoryMax=2147483648` for each scope, the stand-in's `/proc/<pid>/cgroup` ending in `/firstmate.slice/<unit>`, `ancestry=comm claude`, and `crew-state=state: working`.
After teardown or relaunch, `systemctl --user show <old unit> -p LoadState` reads `not-found`.
With `off`, the relaunched stand-in's cgroup names no `fm-worker-` scope and the launch file carries no wrapper.
The `[compare]` lines show that `bin/fm-crew-state.sh` and tmux's `pane_current_command` read the scoped worker exactly as the uncapped one, both while it runs and after it stops.
`relaunch.txt` records which relaunch path ran.
`scripts/kill-order.sh` fills a 200M worker-named scope twice, and `kill-order.txt` reads `agent_adj=500`, `command_adj=500`, `agent_rc=137` for the launch before the kill order, then `agent_adj=400`, `command_adj=1000`, `command_rc=137`, `agent_survived=yes`, `agent_rc=0` for the launch now.

## What this run does not prove

- The lab panes run with a private `XDG_RUNTIME_DIR`, so they reach the user manager through the helper's `--machine=<user>@.host` branch. The direct `--user` branch is proved by the real-systemd case in `tests/fm-worker-memory-scope.test.sh`.
- `bin/fm-control.sh relaunch` refuses the stand-in (it is not a verified harness), so the lab relaunches through `bin/fm-spawn.sh <id> --relaunch` after stopping it. `tests/fm-spawn-worker-memory-scope.test.sh` drives `bin/fm-control.sh relaunch` against a fake pane.
- The kernel kill at the real 2G cap: no lab worker grows past 2G, and the kill-order run uses a 200M cap lowered with `systemctl --user set-property --runtime`, because a host drop-in for `fm-worker-.scope` can pin the cap.
- A real harness's shell tool: the kill-order command is a `bash -c` run by a stand-in agent, and that the Kiro and Pi bash tools read `BASH_ENV` is the live guard `tests/fm-worker-shell-live-e2e.test.sh`.

## Gotchas

- `bin/fm-control.sh` has no relaunch on hc (`fm_control_backend_relaunch_supported`), so the relaunch half runs on a private tmux server under the lab home's `TMUX_TMPDIR`.
