---
name: forensics
description: >-
  Read-only post-mortem for failed or unexpectedly stopped Firstmate tasks, sessions, supervision, delivery runs, and recovery loops.
  Use when asked for forensics, a post-mortem, why a task stopped, why recovery repeated, or when a Firstmate outcome needs a preserved-evidence cause chain.
  Use diagnose-crash instead when the primary evidence is an operating-system core dump.
user-invocable: true
metadata:
  internal: true
---

# Firstmate forensics

Turn Firstmate's durable records into one falsifiable cause chain.
The deliverable is a private, issue-ready report that cites the evidence, names the owning source boundary, proposes the smallest fix, and states what would disprove the conclusion.

Forensics is archaeology.
It does not reproduce by rerunning work.

## Safety boundary

The normal session-start and wake-handling contracts run before this skill.
Once the forensic pass begins, remain read-only except for the final report.

For task forensics, start with `FM_HOME=<owning-home> bin/fm-forensics-collect.sh <task-id>` and inspect its stdout packet without redirecting it into fleet state.
The collector's script header and `--help` behavior own its fixed ceilings, redaction, and output mechanics.
Its anomaly labels are leads to verify against source evidence, never conclusions.

Allowed inspection includes `cat`, `jq`, `rg`, `nl`, `stat`, `ps`, `journalctl`, `coredumpctl info`, `git status`, `git diff`, `git log`, `git show`, `git reflog`, `treehouse status`, `bin/fm-crew-state.sh`, and `bin/fm-peek.sh`.
Use `diagnose-crash` for core-dump analysis and cite its result rather than duplicating that procedure here.

Do not drain or acknowledge wakes, execute a registered check, send instructions, control a worker, run a delivery pipeline, fetch, checkout, reset, clean, stash, merge, replay, retry, relaunch, or clean up a task.
Do not invoke `no-mistakes axi respond`.
Do not read a second mate's conversation.

Treat secrets, customer data, message contents, student data, and financial data as excluded evidence.
Record hashes, timestamps, counts, identifiers, and sanitized fields instead.

## Home and ownership

Bind every command to the home that owns the subject.
Set `FM_HOME` explicitly for Firstmate scripts when the shell is not already in that home.

Main may inspect its direct report and the parent-facing records of a second mate.
Forensics of a second mate's child tree runs in that second mate's home and returns through its parent channel.
Main never reconstructs the child tree or reads the child's chat.

If the subject has no durable task identity, define a bounded fleet or session subject before reading evidence.

## Evidence hierarchy

Use the narrowest authoritative evidence first.

1. `bin/fm-crew-state.sh <task>` gives the currently attributed state.
2. `state/<task>.meta` binds the task to its kind, project, isolated copy, worker tool, endpoint, delivery mode, and merge posture.
3. `state/<task>.status` is append-only event history.
   A status line is never current-state truth by itself.
4. `data/<task>/brief.md` owns accepted intent and Firstmate instructions.
5. `tasks-axi show <task> --full` owns backlog state, dependencies, holds, and completion links.
6. The recorded isolated copy owns Git facts.
   Inspect it with `git -C <path>` and never move it.
7. `state/<task>.inbox/` and `handled/` prove which instructions were published and acknowledged.
8. `state/branch-outcomes.jsonl` records supervision outcomes already delivered to main.
9. `state/procevent-inbox/` records captured external-process results and their handled markers.
10. `state/<task>.check.sh`, its trust record, and PR poll sidecars explain a registered poll.
    Read the bytes and provenance, but never execute the check.
11. The relevant script header, `--help`, docs, and tests own intended runtime behavior.

For an ordinary direct report, the recorded worker session JSONL is the closest analogue to an activity log.
Resolve it from the task's own endpoint or backend record, then inspect only the subject's session.
Search `toolResult` entries with `isError: true`, pair each result with its tool call and preceding assistant text, and follow the chain back to the first incorrect state assumption.
Never read a second mate's conversation or any unrelated session file.

Usage and cost evidence is harness-specific.
Compare usage only within a source that records the same fields and model basis.
Report cost anomalies as unavailable when no normalized durable ledger exists.

Use raw `.wake-queue` rows only to establish publication order and identity.
Never treat queue presence as current task state.

## Procedure

### 1. Freeze the question

Quote the observed symptom exactly.
Name the subject, home, time window, and the last outcome the captain believed.
Separate the initiating trigger, masking condition, and visible symptom.

Completion criterion.
One sentence states what failed without assigning a cause.

### 2. Inventory custody

Read the collector packet, then inspect only the source records whose availability or lead labels can change the explanation.
Read the task's current state, metadata, brief, full backlog item, bounded status history, and isolated-copy Git state when the packet shows that source is relevant.
Record absent, unreadable, stale, contradictory, or duplicated records as evidence.
Do not repair them.

For a crash, compare recorded endpoint identity with the live process and cgroup facts.
For a delivery run, inspect its existing status and artifacts without starting or responding to it.

Completion criterion.
Every artifact that can change the verdict has an owner, path, and freshness statement.

### 3. Build the timeline

Order events by durable timestamp and sequence.
Join records with task id, decision key, correlation id, PR identity, branch head, process id, or wake sequence.
Distinguish publication time from observation time.

Look for these patterns.

- A terminal event followed by another start for the same work.
- A landed change whose backlog item remained open.
- An answered decision whose exact key never resolved.
- An instruction that remained outside `handled/`.
- A run head that differs from the task branch head.
- A missing endpoint with a preserved isolated copy.
- Repeated wake rows whose foreign queue never advanced.
- A process-event result without a handled acknowledgement.
- A branch outcome that covered the event but remained unprocessed by main.

Completion criterion.
The timeline has no unexplained transition between the last healthy state and the symptom.

### 4. Scan for anomaly classes

Treat every collector label, detector result, and prior forensic report as a lead to verify.
Do not promote a label to a conclusion.

| Anomaly | Firstmate evidence |
| --- | --- |
| Repeated work | Repeated task starts, repeated decision keys, duplicate correlation ids, or a completed task dispatched again. |
| Cost spike | Comparable usage records from the same worker tool and model. |
| Timeout or wedge | Recorded wait reason, current worker state, pane evidence, and elapsed time. |
| Missing artifact | A terminal result whose promised PR, report, commit, receipt, or durable evidence does not exist. |
| Crash | Missing recorded endpoint, dead recorded process, stale owner lock, or a `diagnose-crash` result. |
| Integrity issue | Session-start bootstrap, home-summary, backlog, or record-divergence diagnostics. |
| Error trace | Subject session JSONL tool errors, registered process-event result, or durable pipeline result. |

Use a completed backlog row as the analogue of a completed key.
Verify its expected artifact in both the durable record and the owning project or report path.

### 5. Trace the cause into source

Start at the earliest durable divergence, not the loudest final error.
Read every caller of the suspected function or script boundary.
Compare the failing path with a proven healthy sibling path.
Read relevant history and executable tests.

Use these source owners as the initial map.

- Dispatch and isolated-copy publication live in `bin/fm-spawn.sh` and backend helpers.
- Worker control and relaunch live in `bin/fm-control.sh` and `docs/agent-control.md`.
- Wake durability and watcher behavior live in `bin/fm-wake-lib.sh`, `bin/fm-watch.sh`, and `docs/watcher-continuity.md`.
- Current-state attribution lives in `bin/fm-crew-state.sh` and `bin/fm-classify-lib.sh`.
- Backlog transitions live in `bin/fm-backlog-transition-lib.sh` and compatible `tasks-axi` behavior.
- Supervision outcomes and leases live in `bin/fm-branch-outcome.sh`, `bin/fm-lease-lib.sh`, and `docs/pi-supervision-branch.md`.
- Second-mate routing and recovery live in `secondmate-provisioning` and the parent status channel.

Treat this map as leads.
The current source and tests decide ownership.

Completion criterion.
The proposed root cause names a file, function or state transition, and a counterfactual that would prevent the symptom.

### 6. Challenge the explanation

Name the strongest competing explanation.
Seek evidence that would falsify the leading cause.
Explain both the failing path and the healthy comparison path.
Keep contradictory evidence in the report.

Completion criterion.
Confidence reflects what the artifacts prove, not how plausible the story sounds.

### 7. Design the smallest fix

Name the authoritative file and function to change.
Prefer one fix at the shared causal boundary over guards in every caller.
State the regression test that fails before the fix and passes after it.
Keep repair, retry, and delivery outside the forensic pass.

If the cause lies in an external tool, identify the smallest local containment and the upstream issue separately.

### 8. Write the report

For a task, write `data/<task>/forensics-<UTC timestamp>.md`.
For a fleet or session subject, write `data/forensics/<slug>-<UTC timestamp>.md`.
Create only the final report and any missing parent directory.

Use this shape.

```markdown
# Forensics: <subject>

## Symptom

<exact observed symptom>

## Scope and custody

- Home: <home>
- Subject: <task or bounded fleet subject>
- Window: <start to end>
- Evidence preserved: <yes or exception>

## Evidence chain

1. `<path>:<line>` or `<path> field=<field>` proves <fact>.
2. `<path>:<line>` or `<path> field=<field>` proves <next fact>.

## Timeline

| Time or sequence | Event | Evidence |
| --- | --- | --- |

## Root cause

<specific source boundary and failing transition>

## Contributing conditions

- <condition that amplified or masked the failure>

## Disconfirming evidence

- <evidence against the leading explanation and why it does not overturn it>

## Proposed fix

<minimal falsifiable change>

## Regression test

<executable test and expected before or after result>

## Confidence

<high, medium, or low> because <evidence limits>
```

Use `nl -ba` line numbers for text and source files.
For JSONL, cite the physical line plus the identifying fields.
Do not cite a terminal excerpt when the same fact has a durable record.
Keep the local private report useful, but scrub secret values, customer content, credentials, authorization headers, and environment values.
Before an issue is filed, replace home-directory prefixes with `~`, prefer repository-relative paths, and remove private hostnames or identifiers that do not affect the cause.

### 9. Complete without acting

Read the final report from disk and verify every causal claim has a citation.
Run `captain-hold-lifecycle` before declaring the investigation complete.
Relay the cause, consequence, and recommendation in plain language.

Offer to file an issue with `gh-axi` only after the captain explicitly approves that outward action.
Never file automatically.

Ask at most two clarification questions when the artifacts leave a genuinely material fork.
Otherwise state the uncertainty and finish with the strongest evidence-supported cause.

## Anti-patterns

- Running the failed task, registered check, delivery pipeline, or recovery command to reproduce the symptom.
- Reading a second mate or unrelated worker conversation.
- Treating a repeated status line as proof that the worker repeated the action.
- Treating a dead endpoint as proof that the isolated copy or committed work is gone.
- Calling a symptom such as loop, timeout, stale worker, or race the root cause.
- Omitting the healthy comparison path or disconfirming evidence.
- Filing an issue without explicit captain approval.

## Success criteria

- The bounded collector packet was reviewed before deeper inspection.
- The symptom is quoted exactly.
- Current state and event history are not conflated.
- Every causal step cites a path and line or structured field.
- The root cause names one source boundary and a falsifiable counterfactual.
- The strongest competing explanation is addressed.
- The fix is smaller than the symptom workarounds it replaces.
- The regression test exercises the public or executable behavior.
- The final report is the only forensic write.
