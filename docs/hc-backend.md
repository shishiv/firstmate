# hc runtime backend

hc is an experimental session-provider backend for herdr-core, the terminal core under Herdr.app.
It provides task terminals while Treehouse continues to provide git worktrees, the same split tmux uses.
herdr-core is not Herdr 1: the `herdr` backend ([`herdr-backend.md`](herdr-backend.md)) talks to the `herdr` multiplexer, and the two share no socket, id space, or CLI.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared selection and metadata semantics.
The adapter header in `bin/backends/hc.sh` owns design decisions and measured CLI facts; this page is the operator-facing mirror and must not contradict it.
[`verification/runtime-backends.md`](verification/runtime-backends.md#hc) records what was exercised against a real core.

## Setup

Prerequisites:

- `hc` on `PATH` (measured on `hc 0.1.13` and `hc 0.1.16`); `hc` starts its own core on first use.
- `jq` for JSON responses.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

Select hc with local `config/backend` containing `hc`, `FM_BACKEND=hc` for one launch, or an explicit request to Firstmate.
With none of those set, a Firstmate running in an hc terminal also selects hc by runtime detection; see "Selection" below.

The core a task lands on is the one `HC_SESSION` names when the task is spawned, or hc's `default` session when it is unset.
Herdr.app shows the `default` session's terminals.

## Selection

hc stamps `HC_TERMINAL_ID` and `HC_TERMINAL_SOCKET` into every process an hc terminal starts, including a tmux or Herdr 1 server started inside one, so the variables alone never select hc.
Runtime detection selects hc only on process proof: hc, asked over that socket, must report the named terminal live, and that terminal's own shell must be an ancestor of the deciding process.
The socket must also sit at hc's own path for its session under `XDG_RUNTIME_DIR`, and the session is the socket's name without `.sock`.
A tmux or Herdr 1 server started from an hc terminal detaches to the user's service manager, so its panes keep their own backend.
[Backend selection order](configuration.md#backend-selection-order) owns where this check sits among the other runtime markers.

The reverse nesting is the case this proof exists for.
A herdr-core started from a Herdr 1 or tmux pane passes that pane's `HERDR_ENV`, `HERDR_PANE_ID`, `HERDR_SOCKET_PATH`, and `TMUX` variables to every terminal it runs, and they outlive the pane.
Inside a proven hc terminal those variables are ignored: detection checks hc first, the supervisor-pane lookup in `bin/fm-supervisor-target-lib.sh` names the hc terminal, and the Herdr 1 adapter treats the inherited pane as no launcher at all, so an explicit `herdr` spawn uses this home's own labeled workspace instead of refusing on a pane that is gone.

## Task shape and metadata

Each task is one hc terminal running the user's login shell in the project directory, started with `--keep --no-parent --outlive-parent --no-notify`: it is independent of whichever hc terminal Firstmate itself runs in, and a terminal lost with its core comes back as a shell at the same address.
The terminal carries these labels:

| Label | Value | Purpose |
| --- | --- | --- |
| `firstmate.task` | `fm-<id>` | Task identity checked before input or close. |
| `firstmate.home` | `<hometag>` from `bin/fm-backend-hometag-lib.sh` | Keeps two homes with the same task id apart. |
| `firstmate.home-path` | The absolute home directory | Lets the Herdr.app mod below read the task's `state/` records. |
| `herdr.space` | `FM_HC_SPACE`, else the primary's own space, else `fm-<hometag>`; a secondmate's own home's space | Groups a home's tasks in one Herdr.app space. |
| `herdr.tab` | `<hometag>-fm-<id>` | One Herdr.app tab per task. |

The primary's own space is the `herdr.space` label of the live hc terminal that `state/.primary-endpoint` names on the same session, so a Kiro primary running in Herdr.app gets its workers as tabs beside its own.
A primary with no such terminal or label, or one in another core or app, gets one space per home, `fm-<hometag>`.
A secondmate is a different home, so its terminal opens that home's own space, `fm-<secondmate hometag>`, whatever `FM_HC_SPACE` or the primary's space say; the secondmate's own workers then join it as tabs beside it, unless `FM_HC_SPACE` is set in the secondmate's own environment.
Its identity labels stay those of the home that launched it, which owns its record.

On the `default` session, the one Herdr.app shows, the spawn then waits up to three seconds for the app to show the new tab and names the tab after the task (`<id>`) and the space after its home with `herdr-app do tab.rename` and `space.rename`: a secondmate home by its id, any other home by its folder name.
A renamed space keeps its name while it exists; a per-home space closes with its last task, and the next spawn names it again.
Only the new tab and its space are renamed: no other tab, terminal, or space is moved, renamed, or closed, and closing a task never closes the primary's tab.
Naming is best effort: with no app, or no tab in time, the task starts with the app's own names and the spawn prints a warning ([verification](verification/runtime-backends.md#hc)).

```text
backend=hc
window=<session>:<address>
hc_session=<session>
hc_terminal=<address>
```

`<address>` is hc's terminal address such as `t7`.
Every adapter call sets exactly the recorded `HC_SESSION` and drops any inherited `HC_SOCKET`, which hc would otherwise prefer, so a task keeps reaching its own core even when the caller's environment names another one.
An input, capture, or close that carries the task label refuses a terminal whose `firstmate.task` or `firstmate.home` label does not match, and a close without a label still refuses a terminal that lacks this home's labels.

## Primary session and doorbell

A Kiro primary in an hc terminal publishes `state/.primary-endpoint` with `backend=hc` and `target=<session>:<address>` for its own terminal.
The doorbell reads that terminal's screen with the `kiro-cli` harness identity, because hc's screen read carries no styling and only the harness identity proves Kiro's idle placeholder empty; a typed draft is never read as empty.
It then pastes and submits the doorbell line with `hc send`.
The away-mode daemon still supports only tmux and Herdr 1 supervisor panes and refuses an hc one at startup.

## Operations

| Operation | hc command |
| --- | --- |
| Container ensure | `hc server status` |
| Create task | `hc run --bg --keep --no-parent --outlive-parent --no-notify --cwd <project> --label ...` |
| Capture | `hc read --lines <n>` |
| Visible capture | `hc read --lines 0` |
| Send a line and submit | `hc send` |
| Named key | `hc keys` |
| Current path | `hc get`, the foreground process's `cwd` |
| Busy state | `hc get`, native `status.state` (`working` is busy) |
| Agent state | `hc get`, the foreground process and its process group, through the shared classifier |
| Close | `hc kill`, then `hc rm`, then `hc get` must answer not found |

## Limits

- `hc send` always presses Enter, so hc cannot type without submitting.
  `bin/fm-spawn.sh` pastes and submits the spawn launch line with `hc send` and consumes the Enter that follows it.
- Submitting a message uses `hc send` and then reads the composer; only a proven pending composer gets Enter retries.
- hc reports one foreground process per terminal.
  When that process is a launcher, the adapter also reads the rest of its process group from `ps`, which works only for terminals on the local machine.
- Right after a terminal starts, `hc get` can report no foreground process yet, and agent state reads `unreadable` until the shell is up.
- `bin/fm-control.sh` accepts the hc agent state as proof for `exit` and `relaunch`; a relaunch adopts a terminal whose agent ended, and refuses one that reads missing, because this plane does not recreate an hc terminal.
- A worker inherits `HC_SESSION`, `HC_TERMINAL_ID`, `HC_TERMINAL_SOCKET`, and `HC_SCOPE` from its terminal, and the `config/launch-env-allowlist` floor keeps them; a Kiro scout launched by `bin/fm-spawn.sh` reported its native status to herdr-core, and other harnesses are not verified.
- hc has no event stream this adapter consumes; supervision polls like tmux.

## Running the holder outside app.slice

The `default` session's holder (`herdr-core hold`) keeps the program of every terminal of every home.
`herdr-core serve` starts it with `systemd-run --user` and no `--slice`, so it lands in `app.slice`.
Where systemd-oomd watches `app.slice` (Omarchy does), one memory-pressure kill of that cgroup ends every terminal's program in every home at once.
Outside `app.slice` systemd-oomd picks another target, but the kernel's own OOM killer still applies.

Session start warns on an hc home when the running `default` holder sits under `app.slice` (`HC_HOLDER_CGROUP`).
A drop-in for the transient unit name prefix moves the next holder, and the holder already running stays where it is until it restarts.
`~/.config/systemd/user/hc-hold-.service.d/slice.conf`:

```ini
[Service]
Slice=herdr.slice
```

The slice is the one [`herdr-backend.md`](herdr-backend.md#running-the-server-under-systemd) defines.
Restarting the holder ends every terminal's program, so the switch needs a time when every fleet can stop.

## Herdr.app mod

`share/herdr-app/mods/firstmate/` is a Herdr.app mod that lists every Firstmate worker terminal grouped by home.
A secondmate is listed in the group of the home that launched it, and its own workers in a group of their own.
Each row shows the task, its project, the agent's status, an open decision or a ready PR, and the PR number, which opens the PR; clicking the row focuses the worker.
It reads `<home>/state/<id>.meta` and `<id>.status` through the `firstmate.home-path` label and re-reads them when the app reports a change in that folder, so a worker spawned before that label existed shows only its task and status.

Install it by copying the folder into the app's home, after checking it:

```sh
herdr-app check share/herdr-app/mods/firstmate
mkdir -p ~/.config/herdr-app/mods/firstmate
cp share/herdr-app/mods/firstmate/main.js share/herdr-app/mods/firstmate/mod.json ~/.config/herdr-app/mods/firstmate/
ls ~/.config/herdr-app/*.error 2>/dev/null
```

Herdr.app docks a new mod on the left of the shown layout the next time it starts; until then, `herdr-app do mod.open --name firstmate` opens it as a window, and the same command closes it.

## Tests

`tests/fm-backend-hc.test.sh` pins the adapter against a fake `hc`.
`tests/fm-backend-hc-liveness-live-e2e.test.sh` is the default-on live guard: it launches every installed harness bare in a private core and requires `alive`.
`tests/fm-backend-hc-smoke.test.sh` drives the real `hc` against a private core with its own `HC_SESSION` and scratch XDG directories, and skips when `hc` or `jq` is missing.
