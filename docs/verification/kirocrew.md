# Kiro Crew (kirocrew) verification

This page records the live evidence behind the `kirocrew` adapter contract in [the harness reference](../../.agents/skills/harness-adapters/references/harness/kirocrew.md).
`tests/fm-kirocrew-harness.test.sh` replays these facts against `tests/fixtures/fm-kirocrew-fake-gateway.mjs` and needs no Crew install.

## Setup verified

- 2026-10-22, Linux, KiroCrew `main` 0be5bcd9 (version 0.11.0; the stable channel then offered 0.9.0, which was not checked), Python 3.12.14, kiro-cli 2.33.1, Herdr 0.9.5, tmux, Node 26.
- An isolated gateway: its own data home, `KIRO_HOME=<data home>/kiro`, port 5477, no service, no tunnel, `agent.acp_backend=kas` (the "Kiro Agent" engine), auto-update and telemetry off.
- Approvals in the lab ran under Crew's ad hoc auto-approve (YOLO), because only the dashboard can grant the app Trust (below).

## Gateway facts

| Fact | Evidence |
|---|---|
| A self-managed app registers with `POST /api/apps/register` as the dashboard owner, and Crew writes `<data home>/apps/<app>/.app_secret`. The registration answer also carries the secret. | HTTP 201 on registration |
| `POST /api/apps/<app>/token` with `X-App-Secret` returns an app token that works as the `mc_token_<port>` cookie; a loopback request without an Origin header passes the CSRF barrier. The token survived gateway restarts. | `GET /api/chat/slots` HTTP 200 as the app |
| `POST /api/chat/slots {name, agent, agent_kind: "template", memory_mode: "temporary", title}` creates a chat owned by the app (`app=firstmate`, `origin=app`). An agent file added after the gateway started answers 409 `agent_choice_unavailable` until a restart. | slot rows |
| `POST .../project {project}`, `.../model {model}`, `.../reasoning-effort {reasoning_effort}`, `.../turn-timeout {secs}` apply to the app's own chat. `PATCH .../muted` answers 403 `muted_user_only` to an app. | HTTP 200 and 403 |
| `POST /api/chat?ws=1 {slot, message}` answers a receipt and runs the turn on the gateway; a busy chat answers `{queued: true}`. App messages never steer a running turn: `steer: true` queues too. A 60,288-character message arrived whole. | slot history |
| `POST .../stop` cancels the running turn and keeps the chat. `POST .../interrupt` answers 400 `queue empty, use /stop instead` when nothing is queued. | live runs |
| In Normal mode every shell and file tool asks for approval; an agent file cannot pre-approve them on the Kiro Agent engine (`WITHHELD_FROM_AUTO_APPROVE`). `POST /api/chat/mode {mode: "trust", slot}` answers 403 `session_approval_not_granted` without the app's `sessionApproval` permission, and Crew accepts that consent only from its dashboard (`session_approval_consent_required` from the API and the CLI). An unanswered approval expires after 180 s as a refusal. | HTTP 403; expired approval row |
| A gateway restart drops the live chats and the turn in flight, keeps the transcripts, and resets YOLO. `POST .../resume {key: "dashboard_<chat>"}` restores the chat with agent, project, model, effort and conversation memory. A chat with no messages is not saved. | resumed chat recalled an earlier marker |
| `DELETE /api/chat/slots/<chat>` closes the chat and keeps its transcript in the owner's session list. | `GET /api/sessions` as owner |
| A worker on the `firstmate-worker` agent ran `git ls-remote` over SSH from its key file with no SSH agent, read `gh auth status` from the keyring, and called a project agent from `<project>/.kiro/agents/` through its sub-agent tool. | chat transcripts |
| Every gateway start links `~/.local/bin/kirocrew` to its own launcher when the name is free. | `ls -la ~/.local/bin/kirocrew` after a start |

## Live firstmate runs

| Run | Result |
|---|---|
| `fm-spawn.sh kc-live2 ... --scout --harness kirocrew --backend tmux` in a lab home on a private tmux server | The pane ran the program; Crew showed the chat `firstmate · kc-live2` in its sidebar, with the agent, project, model and effort in the chat footer; the worker wrote its report and `done` line; the busy record ended `idle kirocrew-client` with the turn-ended wake; `fm-crew-state.sh` read `done`. |
| `fm-send.sh kc-live2 ...` | The doorbell landed, the record went busy (`user-message`), the worker read its inbox. |
| `fm-control.sh kc-live2 interrupt` | `interrupt-delivered ... verified=agent-alive`; Crew recorded a soft stop; the record went `idle` (`interrupted`) without a wake. |
| `fm-control.sh kc-live2 relaunch` | The new program resumed the same chat (`(resumed)`), received the relaunch brief, and the worker continued from its inbox. |
| `fm-spawn.sh kc-live3 ... --backend herdr` in an isolated Herdr lab session (`bin/fm-herdr-lab.sh`) | Same outcome as tmux. Before the program registered with Herdr, firstmate read the live pane as `dead`; after it, `herdr agent list` showed the pane as agent `kirocrew`, and `fm-send`, `fm-control interrupt` and `relaunch` worked. |
| `fm-control.sh kc-live3 exit` | The program closed the chat and exited. |

## Refresh

Repeat the lab runs after a Crew release that touches app routes, chat routes, approvals, or restart handling, and after a Herdr release that changes `pane report-agent`.
