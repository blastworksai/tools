# TODO planning companion

CodexBWAI · MIT. This companion lives at `<glitch-root>/_local/tern-todo` after deployment. It adds no background job and overrides no managed Glitch skill or hook.

When creating, resuming or revising an interactive canonical plan with `/glitch-plan (Codex: $glitch-plan)`, follow CONTRACT.md for the agreed explicit checkpoint block and stable plan/checkpoint ids. Identify the durable interactive agent process from the runtime's own process id or `todo ancestry`, which prints only native process facts. Pass that verified numeric id on every invocation; 12345 below is only an example. Tool-shell variables may not persist between calls. Never select a shell, launcher, helper or the Tern daemon as the agent. If identity is ambiguous, report TODO unavailable rather than guess. The helper verifies the declared process is the caller or an ancestor owned by this OS account; it no longer infers an agent from process names.

Then run from that agent's own normal tool session:

```sh
python3 -I <glitch-root>/_local/tern-todo/bin/todo.py publish --agent-pid 12345 --plan /absolute/canonical/PLAN.md
```

Use the actual local Glitch root on another machine. On Windows, use an existing Python 3 that answers the real version probe, trying `py -3`, then `python`, then `python3`; PATH presence and Microsoft Store aliases are not installations. No pane number, SSH alias, socket, token or operator-entered path is required. The planning agent already knows its canonical record. The publisher verifies its live native Tern ancestry and records only the canonical path/id and process birth/owner identity. It does not copy or edit the plan.

Keep normal Progress, START HERE and checkpoint updates in the canonical plan. Those edits refresh in TODO automatically; a second publication is needed only on creation/resume, deliberate reattachment or a change of the session's active plan.

The helper opens publication metadata without following links and checks the actual open object before reading or changing modes. Symbolic links, unexpected extra links and replaced objects are refused, so metadata maintenance cannot be redirected onto another directory or the canonical plan. When pruning a different session's old record, it takes that record's own lock and reads and validates it again, avoiding deletion based on a stale pre-lock observation. On Windows, TODO's own reader permits replacement sharing and closes its handle on both success and failure. If a new record cannot be installed, the previous valid publication is preserved and temporary files are cleaned up.

Failed cleanup retracts only the same observed record owner/revision/process anchors, and per-record locks serialize cooperating publishers. The subsequent check-to-unlink sequence on that **same record** is not atomic against an outside or non-cooperating writer, which can replace the record after the check and lose that replacement to the unlink; no atomic compare-and-delete is claimed. Initial discovery handles temporary process-access/unknown failures differently: it keeps the error visible and retries, so a later successful inspection can recover the view. A real initial `ProcessEnded` emits `terminal=true` and exits rather than retrying.

Before ending or resetting the conversation (including /clear or /new where supported), closing the task, binning the plan or continuing without a plan, explicitly clear this session's binding:

```sh
python3 -I <glitch-root>/_local/tern-todo/bin/todo.py clear --agent-pid 12345
```

Clear never closes or prompts the agent. A dead or changed process invalidates its binding even if it could not clear before exiting. An existing TODO view never silently adopts a different plan: the operator attaches it explicitly.

If publication fails, report TODO as unavailable; preserve the canonical workflow and existing approvals. Do not ask the operator to locate a plan, infer a plan from prose, take another pane's record, install a dependency, or start/resume work solely to populate TODO. Plans without the explicit agreed block are adopted only when deliberately resumed or revised. Unviewed fleet/BWPM sessions are outside this companion.

Native Tern remote-host sessions publish on their execution host. Raw SSH into a host without a native Tern process tree is unsupported; do not copy socket credentials, forward Tern/agent sockets or trust keys automatically to work around it. On multi-account Linux hosts the publisher uses the existing `agents` group to make pointer metadata readable by the Tern host, while only its owning OS account can write it. The viewing account must also be able to inspect the process chain, read the canonical plan and traverse every plan ancestor; readable metadata alone is insufficient. Never copy plans or automatically change plan/ancestor permissions to provide that access.

macOS and Windows use the native account's owner-only protected cache and do not discover other accounts' stores. Solo-Mac and solo-Windows use, plus the existing Linux estate, are the current qualification targets unless later evidence expands them. Real-device acceptance remains a separate gate.

The descriptor registers this companion for the planning model to discover. It is an instruction contract, not proof that every managed planning invocation already follows it; rollout qualification must observe adoption.

Conversation resets are not kernel process exits. If the process stays alive and the explicit clear instruction is skipped, its old publication remains visible. The helper cannot observe conversation identity; this residual must be disclosed before rollout. A fresh planning session must clear an inherited binding before deliberately publishing its own current plan. The registry descriptor alone does not enforce either instruction.

## Actual workflow entry

`capability.json` advertises this companion; it does not invoke it. Install
`entry_hook.py` as an additive local hook for SessionStart, UserPromptSubmit and
PreToolUse/Skill. It supplies the companion instruction at the actual invocation
of both `/glitch-plan` and `/glitch-execute`, including a Skill tool invocation.
It never edits a plan, publishes metadata, sends input, blocks a command or
changes managed hooks. The owning agent still adopts and publishes the agreed
checkpoint block through its normal authorised tools.

When `/glitch-execute` deliberately resumes an existing agreed plan without a
block, create the summary from its agreed checkpoints before implementation or
operations, set current state from the executor's verified progress, then publish.
Do not wait for another `/glitch-plan` run. Do not rename agreed checkpoints or
reopen settled choices. Respect read-only sessions and another pane's ownership.

Existing agent processes may retain a snapshot of their hooks. Installation is
qualified only after a fresh ordinary planning/execution session follows the
entry instruction and the TODO pane (opened from the status bar) displays its plan. A payload probe
alone proves instruction delivery, not adoption. Do not restart an acting agent
or alter its plan from the installer.

This additive entry wiring is Claude-specific to the configured Glitch root.
Codex, Kimi, Muse and every other harness require explicit companion publication
by the owning agent through the commands above. No automatic entry delivery or
adoption is claimed for an unwired harness.
