# TODO planning companion

CodexBWAI · MIT. This companion lives at `<glitch-root>/_local/tern-todo` after deployment. It adds no background job and overrides no managed Glitch skill or hook.

When creating, resuming or revising an interactive canonical plan with `$glitch-plan`, follow CONTRACT.md for the agreed explicit checkpoint block and stable plan/checkpoint ids. Then run, from that agent's own normal tool session:

```sh
python3 -I /opt/glitch/_local/tern-todo/bin/todo.py publish --plan /absolute/canonical/PLAN.md
```

Use the actual local Glitch root on another machine; on Windows use its existing `py -3 -I` launcher. No pane number, SSH alias, socket, token or operator-entered path is required. The planning agent already knows its canonical record. The publisher verifies its live native Tern ancestry and records only the canonical path/id and process birth/owner identity. It does not copy or edit the plan.

Keep normal Progress, START HERE and checkpoint updates in the canonical plan. Those edits refresh in TODO automatically; a second publication is needed only on creation/resume, deliberate reattachment or a change of the session's active plan. An invalid new publication retracts the old binding rather than leaving stale success.

When closing the task, binning the plan, or continuing without a plan, clear this session's binding:

```sh
python3 -I /opt/glitch/_local/tern-todo/bin/todo.py clear
```

Clear never closes or prompts the agent. A dead or changed process invalidates its binding even if it could not clear before exiting. An existing TODO view never silently adopts a different plan: the operator attaches it explicitly.

If publication fails, report TODO as unavailable; preserve the canonical workflow and existing approvals. Do not ask the operator to locate a plan, infer a plan from prose, take another pane's record, install a dependency, or start/resume work solely to populate TODO. Plans without the explicit agreed block are adopted only when deliberately resumed or revised. Unviewed fleet/BWPM sessions are outside this companion.

Native Tern remote-host sessions publish on their execution host. Raw SSH into a host without a native Tern process tree is unsupported; do not copy socket credentials or trust keys automatically to work around it. On multi-account Linux hosts the publisher uses the existing `agents` group to make pointer metadata readable by the Tern host, while only its owning OS account can write it. macOS and Windows use the native account's protected cache.

The descriptor registers this companion for the planning model to discover. It is an instruction contract, not proof that every managed planning invocation already follows it; rollout qualification must observe adoption.
