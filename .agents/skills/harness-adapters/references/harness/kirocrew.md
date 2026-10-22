# Kiro Crew

The `kirocrew` harness runs a worker as one chat of the captain's Kiro Crew gateway, so the captain can read every worker in Crew's dashboard while firstmate supervises it from an ordinary task pane.
Verified as a CREWMATE and SCOUT adapter on 2026-10-22 with KiroCrew `main` 0be5bcd9 (0.11.0), its "Kiro Agent" engine, and kiro-cli 2.33.1 on Linux, on the tmux and Herdr backends ([verification](../../../../../docs/verification/kirocrew.md)).
It is refused for `--secondmate`: it has no primary supervision protocol.

## Operating facts

| Fact | Value |
|---|---|
| Program | `../../../../../bin/fm-kirocrew-run.mjs` on Node 22 or newer, resolved as the absolute `node` from `PATH`. It sets its process title, so the kernel process name is exactly `fm-kirocrew`, which `../../../../../bin/fm-harness.sh` and the liveness classifier anchor on. |
| Setup | `../../../../../bin/fm-kirocrew-setup.sh` once per home: it writes the worker agent file `firstmate-worker` into Crew's Kiro agents folder and registers the self-managed app `firstmate`. Crew reads agent files only when its gateway starts, so a new file needs a gateway restart. `config/kirocrew` names the gateway ([`docs/configuration.md`](../../../../../docs/configuration.md) "Kiro Crew (config/kirocrew)"). |
| Launch | `fm-kirocrew-run.mjs --home --config-dir --task --state --label --cwd <worktree> [--busy-writer --busy-gen] [--resume] [--herdr-pane --herdr-session] [--model] [--effort] -- "<launch envelope>"`. A fresh launch creates a new chat named `fm-<home-tag>-<task>-<stamp>`, titled `firstmate · <task>`, on the worker agent in temporary memory mode, with the worktree as its project, and sends the envelope as the first message. `../../../../../bin/fm-spawn.sh` refuses the launch before anything exists when `fm-kirocrew.mjs ping` cannot reach the gateway or the app. |
| Wire | `../../../../../bin/fm-kirocrew.mjs` owns every Crew call. It uses only the app token that Crew trades for `<crew-home>/apps/firstmate/.app_secret`; the token travels as Crew's auth cookie and is cached in `state/.kirocrew-token` (0600). |
| Busy state | The program writes `kirocrew-client` records through `../../../../../bin/fm-busy-event.sh` from the turn flags Crew reports for the chat: a turn start applies busy, a turn end applies idle with the turn-ended wake, an interrupt or exit applies idle without the wake. A chat that Crew dropped is resumed, and its lost turn ends with the wake. |
| Rendered tail | `Kiro Crew is working · esc to cancel` while a turn runs, `Kiro Crew · idle` between turns, `Kiro Crew is waiting for a tool approval in the Crew dashboard` while a tool waits. The program owns this rendering; it carries no spinner or clock. |
| Composer | `› ` followed by the unsent text; an empty row means nothing is pending. Every accepted send prints `(sent)` or `(queued for the next turn)`, the delivery signals `../../../../../bin/fm-composer-lib.sh` reads. |
| In-turn steering | None. Crew queues every app message to a busy chat for its next turn, even one sent with `steer`. Firstmate's typed doorbell still lands, and the worker reads its inbox on that next turn. |
| Interrupt | One `Escape`. The program calls Crew's stop route, which cancels the turn and keeps the chat; Crew's interrupt route is a different verb that only cuts a turn short for a queued message. |
| Exit | `/quit` (or `/exit`), one Enter: the program closes the chat and exits. SIGHUP and SIGTERM close it too. A closed chat keeps its transcript in Crew. |
| Resume | A relaunch passes `--resume`: the program adopts the chat recorded in `state/<id>.kirocrew-slot` when it is live, or resumes its transcript, which restores agent, project, model, effort, and the conversation. A fresh launch closes a recorded live chat and starts a new one, so a reused task id never continues an older conversation. |
| Model | `--model <id>`, set on the chat. |
| Effort | `--effort <low\|medium\|high\|xhigh\|max>`; Crew refuses any other level. |
| Autonomy | Crew asks for approval on every shell and file tool unless the chat is in Trust mode. Only the app's `sessionApproval` permission lets firstmate set Trust, and Crew grants it only when the captain enables the app on its page in the dashboard. Until then every tool waits for an approval in the dashboard, and an unanswered approval expires after 180 s as a refusal. The program says so in the pane at start. |
| Herdr | Herdr does not detect the program, and firstmate's Herdr liveness read requires a registered agent, so the program reports itself as the task pane's agent with `herdr pane report-agent` and releases it on exit. The pane and session come only from `--herdr-pane` and `--herdr-session`, which fm-spawn passes on the Herdr backend; inherited `HERDR_*` variables are never read. |
| Backends | tmux and Herdr only. |
| Environment | The worker's tools run inside the Crew gateway's process tree, not under the pane's environment, so per-task variables that firstmate exports in the pane (for example the git commit-message hooks environment) do not reach them. |
