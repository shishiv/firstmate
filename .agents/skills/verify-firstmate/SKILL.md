---
name: verify-firstmate
description: Prove a change to Firstmate's own bin/ scripts, backends, or skills end to end in a disposable lab home. Spawns one scout on the hc backend with a stand-in agent, checks its status line reaches the wake queue, steers it once, and tears it down. Use before calling a Firstmate change done, and whenever spawn, send, watch, wake-drain, teardown, or an hc/lab helper changed.
---

# verify-firstmate

Firstmate is a set of bash scripts and skills that supervise terminals; there is no server to launch.
The surface a change touches is the task lifecycle, so the proof drives that lifecycle for real in a lab home and reads the records it leaves.
Run this from the worktree that holds the change, never from the captain's home.

## Launch

```sh
bash .agents/skills/verify-firstmate/scripts/verify.sh --out <evidence-dir>
```

It exits 0 only when every step printed `PASS`.
The run builds, under a fresh `/tmp/fmvf.*` root, a marked lab home (`bin/fm-lab-home.sh`), a private herdr-core (unique `HC_SESSION`, `XDG_STATE_HOME`, `XDG_RUNTIME_DIR`), a local demo project with a bare origin, and a stand-in agent named `claude` that logs every line it is typed.
Ready means the private core answers `hc server status` and the scout's terminal exists under its label.
`--keep` leaves the scratch root for inspection.

## Doctor

Read-only checks before trusting a run:

```sh
command -v hc jq git treehouse
hc --version
herdr session list
git -C <worktree> rev-parse --short HEAD
```

The default Herdr session must be `running`; the run refuses to start otherwise because `bin/fm-herdr-lab.sh` records it as a tripwire.
The first lines of the output name the worktree sha, the hc version, the private hc session, the lab home, and the Herdr lab session, so a proof states what it ran against.

## Drive

`scripts/verify.sh` is the recipe; each step prints a `PASS:` or `FAIL:` line.

1. Spawn: `bin/fm-brief.sh vf1 demo --scout`, then `bin/fm-spawn.sh vf1 <demo> --scout --backend hc --harness "<stand-in> --fake"`. Asserts `backend=hc` in `state/vf1.meta` and a live terminal in the private core.
2. Notification: the stand-in's status lines land in `state/vf1.status`; `FM_POLL=1 bin/fm-watch.sh` must print `signal: .../vf1.status`, and `bin/fm-wake-drain.sh` must present the `done` line.
3. Steer: `bin/fm-send.sh vf1 '<text>'` exits 0, writes an inbox `.msg` record, and the stand-in receives the doorbell line.
4. Cleanup: `bin/fm-captain-hold.sh complete vf1 --none`, then `bin/fm-teardown.sh vf1`; the private core must list no terminal afterwards.

Mapped features (what each one proves and what this run leaves unproved) are in [`features/README.md`](features/README.md).

## Evidence

Written to `--out`: `spawn.txt`, `terminal.json`, `watch.out`, `drain.txt`, `received.txt` (what the stand-in was typed), `peek.txt`, `teardown.txt`.
Put the full run output in the PR.
Proof standards: every step goes through the real `bin/` entrypoint, the hc core is real, and only the agent is a stand-in.
Anything that depends on what a real harness renders or emits (composer state, native status, liveness of a named harness) is not proved here; use the live guards in `docs/verification/runtime-backends.md`.

## Cleanup

The script's EXIT trap stops only the private core (after checking `HC_SESSION` and `XDG_STATE_HOME` are still its own), tears down the lab home's helper state, runs `bin/fm-herdr-lab.sh teardown` for its named Herdr lab session, and removes the scratch root.
A teardown that finds the default Herdr session changed fails the run.
Evidence in `--out` survives.
Never touch the captain's home, `firstmate-portfolio`, terminal `t1`, or the `default` hc core.

## Isolation

Two runs side by side are safe: each has its own scratch root, hc session, and Herdr lab session.
The Herdr lab contract (`bin/fm-herdr-lab.sh`, session `fm-lab-*`, never `default`) is the only Herdr call path this skill uses.
