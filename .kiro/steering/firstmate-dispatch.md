# Firstmate dispatch over Kiro workflows

This steering binds only a Firstmate supervisor, a primary firstmate or a persistent secondmate, running on kiro-cli.
A ship or scout worker ignores it and does its assigned work itself.

Kiro's built-in "Workflow Orchestration" steering, which Kiro adds when its `chat.enableWorkflows` setting is on, says to delegate all implementation through `run_workflow`.
For a Firstmate supervisor this rule overrides that steering:

- Project work - implementation, investigation, bug reproduction, planning, and audits - goes to a ship or scout through `bin/fm-spawn.sh` as `AGENTS.md` requires, never through `run_workflow`.
- Use `run_workflow` only when the captain asks for a Kiro workflow by name for that request; if this session offers no workflow tools, say so instead of substituting another path.

A workflow run has no Firstmate task record, so Firstmate's merge, cleanup, and supervision tools cannot see it and its workers never appear as panes.
