# Kiro Crew (kirocrew) verification

This page records the live evidence behind the `kirocrew` adapter contract in [the harness reference](../../.agents/skills/harness-adapters/references/harness/kirocrew.md).
`tests/fm-kirocrew-harness.test.sh` replays these facts against `tests/fixtures/fm-kirocrew-fake-gateway.mjs` and needs no Crew install.
`tests/fm-kirocrew-primary.test.sh` replays the facts behind a primary that runs in a Crew chat ([configuration](../configuration.md#a-primary-in-a-kiro-crew-chat)).

## Setup verified

- 2026-10-22, Linux, KiroCrew `main` 0be5bcd9 (version 0.11.0; the stable channel then offered 0.9.0, which was not checked), Python 3.12.14, kiro-cli 2.33.1, Herdr 0.9.5, tmux, Node 26.
- An isolated gateway: its own data home, `KIRO_HOME=<data home>/kiro`, port 5477, no service, no tunnel, `agent.acp_backend=kas` (the "Kiro Agent" engine), auto-update and telemetry off.
- The first live runs approved tools through Crew's ad hoc auto-approve (YOLO). The `kc-trust3` run below ran with YOLO off.
- From 2026-10-23 the firstmate app installs from this repository's app registry (`apps/firstmate/app.json`), and the instance runs under Crew's own system unit `kirocrew.service`, through a `~/.local/bin/kirocrew` launcher that sets `KIROCREW_HOME` and `KIRO_HOME`.

## Gateway facts

| Fact | Evidence |
|---|---|
| A self-managed app registers with `POST /api/apps/register` as the dashboard owner, and Crew writes `<data home>/apps/<app>/.app_secret`. The registration answer also carries the secret. `POST /api/security/trusted-apps/<app>` as the owner puts the app on Crew's trusted apps list. The `firstmate` manifest asks for `permissions {api: ["/api/chat"], events: ["slots:own"], sessionApproval: true}` and names `minKiroCrewVersion` 0.11.0. | HTTP 201 on registration; `bin/fm-kirocrew-setup.sh` against the lab gateway: trusted-apps accepted, the owner cookie passed to curl on stdin and in none of its arguments, `--check` printed `agent=firstmate-worker` and `trust=not-granted` before the consent and `trust=granted` after it |
| The 0.11.0 dashboard shows no Enable button for a self-managed app (`resources: app`). Its detail page shows only Installed and Uninstall, and the Library's enable sends no consent and then opens that same page. `POST /api/apps/<app>/enable {sessionApprovalConsent: true}` from the owner's dashboard session, the request the dashboard's own enable sends, enables the app and records the consent. | the captain's screenshot of `/apps/detail/firstmate`; `website/src/pages/AppDetailPage.tsx`; the captain ran that request in the browser console on that page, and `installed.json` then read `enabled: true`, `sessionApprovalConsentPending: false` |
| An app installed from a registry gets `resources: gateway`, `origin: registry` and `source: registry:<registry>`, and its detail page shows "Enable and allow chat control" with a confirmation dialog. Crew lists an app from `apps/<app>/app.json` in a registry repository that has no `app-registry.json`. It checks execution trust before an install clones anything, and a trust grant for a registry app must name the app's repository. | `bin/fm-kirocrew-setup.sh` against the instance on 2026-10-23: it installed the app from a branch in 15 s; the captain enabled it with that button, and the record then read `enabled: true`, `sessionApprovalConsentPending: false`; `registry_pipeline/indexes.py` and `security_trusted_apps.py` for the listing and trust rules |
| The consent reaches past the app's own chats. Crew's permission text says the app can send messages, approve or deny tool prompts, and switch the approval mode in the owner's chats, and after the consent the app's chat list also showed the owner's own chats. | detail page permission text; `GET /api/chat/slots` as the app listed the owner's `chat-3-…` and mate chats |
| `POST /api/apps/<app>/token` with `X-App-Secret` returns an app token that works as the `mc_token_<port>` cookie; a loopback request without an Origin header passes the CSRF barrier. The token survived gateway restarts. | `GET /api/chat/slots` HTTP 200 as the app |
| The cookie session of an app token ends one hour after the token is minted, and then Crew answers it 403 `forbidden`, its auth gate's answer, not 401. | a token minted at 12:21 UTC on 2026-10-23 answered 403 at 14:49 UTC; its claims read `session_exp - iat = 3600` |
| `POST /api/chat/slots {name, agent, agent_kind: "template", memory_mode: "temporary", title}` creates a chat owned by the app (`app=firstmate`, `origin=app`). An agent file added after the gateway started answers 409 `agent_choice_unavailable` until a restart. | slot rows |
| `POST .../project {project}`, `.../model {model}`, `.../reasoning-effort {reasoning_effort}`, `.../turn-timeout {secs}` apply to the app's own chat. `PATCH .../muted` answers 403 `muted_user_only` to an app. | HTTP 200 and 403 |
| `POST /api/chat?ws=1 {slot, message}` answers a receipt and runs the turn on the gateway; a busy chat answers `{queued: true}`. App messages never steer a running turn: `steer: true` queues too. A 60,288-character message arrived whole. | slot history |
| Crew starts an app's turn before it sends the `ws=1` receipt, so the next chat read already shows `running`. The handler spawns the turn task first (`chat_api/chat_send.py`), and `running` reads that task (`ChatSlot.turn_running`). | lab probe: receipt after 6 ms, the chat read 12 ms later showed the turn running, the turn ended after 10.9 s |
| `POST .../stop` cancels the running turn and keeps the chat. `POST .../interrupt` answers 400 `queue empty, use /stop instead` when nothing is queued. | live runs |
| In Normal mode every shell and file tool asks for approval; an agent file cannot pre-approve them on the Kiro Agent engine (`WITHHELD_FROM_AUTO_APPROVE`). `POST /api/chat/mode {mode: "trust", slot}` answers 403 `session_approval_not_granted` without the app's `sessionApproval` permission, and Crew accepts that consent only from its dashboard (`session_approval_consent_required` from the API and the CLI). An unanswered approval expires after 180 s as a refusal. | HTTP 403; expired approval row |
| A gateway restart drops the live chats and the turn in flight, keeps the transcripts, and resets YOLO. `POST .../resume {key: "dashboard_<chat>"}` restores the chat with agent, project, model, effort and conversation memory. A chat with no messages is not saved. | resumed chat recalled an earlier marker |
| `DELETE /api/chat/slots/<chat>` closes the chat and keeps its transcript in the owner's session list. | `GET /api/sessions` as owner |
| A worker on the `firstmate-worker` agent ran `git ls-remote` over SSH from its key file with no SSH agent, read `gh auth status` from the keyring, and called a project agent from `<project>/.kiro/agents/` through its sub-agent tool. | chat transcripts |
| Every gateway start links `~/.local/bin/kirocrew` to its own launcher when the name is free. | `ls -la ~/.local/bin/kirocrew` after a start |

## Primary facts

A Kiro primary in a Crew chat runs on the agent `firstmate-primary`. These facts come from probe chats on 2026-10-23 on the instance above.

| Fact | Evidence |
|---|---|
| On the Kiro Agent engine Crew runs an agent file's own `hooks` itself, in kiro-cli's object form (`agentSpawn`, `userPromptSubmit`, `preToolUse`, `postToolUse`, `stop`), with `/bin/sh -c` in the chat's project folder. A project's `.kiro/hooks` files do not fire. The stdin payload carries `hook_event_name` (`AgentSpawn`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`), `cwd`, `session_key` (`dashboard:<chat>`), and `prompt` or `assistant_text`. | a probe agent whose hooks logged their payloads; `agent_sdk/spec_hooks.py`; a probe project hook never ran |
| The standard output of an `AgentSpawn` or `UserPromptSubmit` hook reaches the model's context. A hook times out after 30 s unless its `timeout_ms` sets another bound, at most 300 s. | the probe chat's model, told to use no tool, reported the marker each hook printed; `hooks.py` `HOOK_TIMEOUT_MAX` |
| Crew runs every hook inside its sandbox: its own user and mount namespaces, the host's pid and network namespaces, and an environment allowlist (`PATH`, `HOME`, `LANG`, `KIROCREW_HOME`, `TMPDIR` and a few more, plus `KIROCREW_SPAWNED` and `KIROCREW_SANDBOX_*`). Crew removes the user-bus variables on purpose, because a bus address would let a sandboxed process start a unit outside the sandbox, so `systemd-run --user` fails there. The gateway answers on loopback, the home's state folder is writable, and a detached child outlives the turn and the chat close inside the hook's scope. | a probe hook compared its namespace ids with the host's and listed its environment names; `sandbox_spawn.py` |
| A hook runs under Crew's sandbox launcher, a `python3.12` child of the gateway process (comm `kirocrew`, argv `kirocrew gateway`). A tool shell runs under the chat's `kiro-cli-chat acp` and `kiro-cli acp` runtime, also a child of the gateway, in the host's mount namespace. The gateway is the one frame both share. | `ps` ancestry from a probe hook and from the probe chat's runtime |
| The app token sends a message into a chat the dashboard owner created, and that chat runs the turn. After the consent the app lists the owner's chats. | the probe's message ran a turn in an owner chat; `GET /api/chat/slots` as the app |
| A dashboard restart (`POST /api/restart`) re-executes the gateway in place: the pid stays, the comm becomes `python3.12`, and the argv becomes `python3.12 -s -P -m kiro_crew gateway --no-open`. The owner's open chats were listed again after it. | `ps` before and after the restart at 15:34 UTC on 2026-10-23; the owner's two chats in `GET /api/chat/slots` |
| Every chat row carries `turn_gen`, one random value per gateway process (Crew's chunk generation), so a changed value means a restart, also an in-place one. | `dashboard/chat_utils_completion.py` `chunk_generation`; `slot_projection.py` |

## Live firstmate runs

The runs before `kc-trust3` approved tools through the lab's YOLO.

| Run | Result |
|---|---|
| `fm-spawn.sh kc-trust4 ... --scout --harness kirocrew --backend tmux` with the installed app, on the gateway that `kirocrew.service` runs | `setup --check` printed `trust=granted`, and the worker chat read `trust: true`. The captain had armed YOLO from the dashboard for his own chat, so Crew's security log attributes both tool calls to `yolo`. The scout wrote its `done` line, and teardown closed the chat, 31 s after the spawn. |
| `fm-spawn.sh kc-trust3 ... --scout --harness kirocrew --backend tmux` with the app consented and YOLO off (`/api/admin/compliance/yolo-status` read `active: false` before and after) | Crew put the chat in Trust mode (`trust: true`). Both shell tool calls ran with no approval wait, and Crew's security event log records each one as `auto_approved` with `reason: trust`. The worker wrote its report and `done` line 26 s after the spawn. `fm-teardown.sh kc-trust3` printed `Kiro Crew chat … of kc-trust3 is closed`, and the chat left Crew's live list. |
| `fm-spawn.sh kc-live2 ... --scout --harness kirocrew --backend tmux` in a lab home on a private tmux server | The pane ran the program; Crew showed the chat `firstmate · kc-live2` in its sidebar, with the agent, project, model and effort in the chat footer; the worker wrote its report and `done` line; the busy record ended `idle kirocrew-client` with the turn-ended wake; `fm-crew-state.sh` read `done`. |
| `fm-send.sh kc-live2 ...` | The doorbell landed, the record went busy (`user-message`), and the worker read its inbox. Its shell has no `FM_TASK_INBOX`, so it listed the full inbox path from its brief (`find '<state>/kc-live2.inbox' ...` in the chat transcript). |
| `fm-control.sh kc-live2 interrupt` | `interrupt-delivered ... verified=agent-alive`; Crew recorded a soft stop; the record went `idle` (`interrupted`) without a wake. |
| `fm-control.sh kc-live2 relaunch` | The new program resumed the same chat (`(resumed)`), received the relaunch brief, and the worker continued from its inbox. |
| `fm-spawn.sh kc-live3 ... --backend herdr` in an isolated Herdr lab session (`bin/fm-herdr-lab.sh`) | Same outcome as tmux. Before the program registered with Herdr, firstmate read the live pane as `dead`; after it, `herdr agent list` showed the pane as agent `kirocrew`, and `fm-send`, `fm-control interrupt` and `relaunch` worked. |
| `fm-control.sh kc-live3 exit` | The program closed the chat and exited. |

## Not verified

- Tool approval by Trust alone with the installed app. In the `kc-trust4` run YOLO approved the tools. `kc-trust3` showed Trust alone approving tools with the earlier self-managed app, and Crew's approval path reads the chat's Trust flag, not the app.
- A gateway with neither Trust nor YOLO, where every tool waits for an approval: the program's status row and its Herdr `blocked` report during that wait have not run live.
- KiroCrew 0.9.0 (stable). The manifest names 0.11.0 as its minimum.
- The kernel process name `fm-kirocrew` outside Linux.

## Refresh

Repeat the lab runs after a Crew release that touches app routes, chat routes, approvals, or restart handling, and after a Herdr release that changes `pane report-agent`.
