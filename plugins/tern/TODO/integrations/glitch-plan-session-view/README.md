# TODO planning companion

CodexBWAI · MIT. This companion lives at `<glitch-root>/_local/tern-todo` after deployment. It adds no background job and overrides no managed Glitch skill or hook.

When creating, resuming or revising an interactive canonical plan with `/glitch-plan (Codex: $glitch-plan)`, follow CONTRACT.md for the agreed explicit checkpoint block and stable plan/checkpoint ids. Identify the durable interactive agent process from the runtime's own process id or `todo ancestry`, which prints only native process facts. Pass that verified numeric id on every invocation; 12345 below is only an example. Tool-shell variables may not persist between calls. Never select a shell, launcher, helper or the Tern daemon as the agent. If identity is ambiguous, report TODO unavailable rather than guess. The helper verifies the declared process is the caller or an ancestor owned by this OS account; it no longer infers an agent from process names.

Then run from that agent's own normal tool session:

```sh
python3 -I <glitch-root>/_local/tern-todo/bin/todo.py publish --agent-pid 12345 --plan /absolute/canonical/PLAN.md
```

Use the actual local Glitch root on another machine; on Windows use its existing `py -3 -I` launcher. No pane number, SSH alias, socket, token or operator-entered path is required. The planning agent already knows its canonical record. The publisher verifies its live native Tern ancestry and records only the canonical path/id and process birth/owner identity. It does not copy or edit the plan.

Keep normal Progress, START HERE and checkpoint updates in the canonical plan. Those edits refresh in TODO automatically; a second publication is needed only on creation/resume, deliberate reattachment or a change of the session's active plan. An invalid new publication retracts the old binding rather than leaving stale success.

Before ending or resetting the conversation (including /clear or /new where supported), closing the task, binning the plan or continuing without a plan, clear this session's binding:

```sh
python3 -I <glitch-root>/_local/tern-todo/bin/todo.py clear --agent-pid 12345
```

Clear never closes or prompts the agent. A dead or changed process invalidates its binding even if it could not clear before exiting. An existing TODO view never silently adopts a different plan: the operator attaches it explicitly.

If publication fails, report TODO as unavailable; preserve the canonical workflow and existing approvals. Do not ask the operator to locate a plan, infer a plan from prose, take another pane's record, install a dependency, or start/resume work solely to populate TODO. Plans without the explicit agreed block are adopted only when deliberately resumed or revised. Unviewed fleet/BWPM sessions are outside this companion.

Native Tern remote-host sessions publish on their execution host. Raw SSH into a host without a native Tern process tree is unsupported; do not copy socket credentials or trust keys automatically to work around it. On multi-account Linux hosts the publisher uses the existing `agents` group to make pointer metadata readable by the Tern host, while only its owning OS account can write it. macOS and Windows use the native account's protected cache.

The descriptor registers this companion for the planning model to discover. It is an instruction contract, not proof that every managed planning invocation already follows it; rollout qualification must observe adoption.

Conversation resets are not kernel process exits. If the process stays alive and the clear instruction is skipped, its old publication remains visible. The helper cannot observe conversation identity; this residual must be disclosed before rollout. A fresh planning session must clear an inherited binding before deliberately publishing its own current plan. The registry descriptor alone does not enforce either instruction.

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
entry instruction and the real TODO button displays its plan. A payload probe
alone proves instruction delivery, not adoption. Do not restart an acting agent
or alter its plan from the installer.
