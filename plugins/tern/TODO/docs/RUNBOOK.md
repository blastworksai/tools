# TODO rollout runbook

CodexBWAI · MIT. The owner has authorized merge and deployment to specific hosts and desktop clients. The simplified tools release route is GitHub-only, outside FORGE/ReleaseManager. These instructions confer no additional authority.

1. Obtain a fresh cross-family review on the exact PR head. Match every runtime hash in evidence to that head. Merge only after the review passes, then verify the merged subtree matches the reviewed package.
2. Check the actual running Tern daemon/client versions (minimum 0.9.8), installed TODO package and owning account. Do not update or restart Tern. Install only the reviewed immutable TODO release with the normal local-package installer, preserving plugin data. Read back the plugin catalogue and installed file hashes. Compare all three companion helper hashes with the installed plugin helpers; refuse schema/version skew. [VALIDATION.md](VALIDATION.md) records the integrated source hashes and distinguishes them from the immutable handoff for this later coordinated comparison. They are not installed-companion receipts; neither Task 2C nor integration performed a rollout.
3. Install the planning companion in the actual local Glitch root at `<glitch-root>/_local/tern-todo`: copy its capability.json, README.md, CONTRACT.md, the package MIT LICENSE, the three bin/*.py helper modules, and integrations/glitch-plan-session-view/entry_hook.py as `<glitch-root>/_local/tern-todo/entry_hook.py`. Use owner-writable code with read access for the agent accounts that use it; do not execute a deployed helper from a writable development worktree. Do not edit managed Glitch skills/hooks. Use an existing, successfully probed Python 3 (`py -3`, then `python`, then `python3` on Windows); PATH presence and Microsoft Store aliases are not proof of an interpreter. No dependency installation is needed.
4. In an actual interactive native Tern agent session, deliberately resume an agreed canonical plan, maintain its explicit checkpoint block, and run the companion’s publish command from the agent’s normal tool session. Identify and supply the actual durable agent pid from runtime facts, never a launcher/shell. Explicitly clear before conversation reset/end and on fresh startup; disclose and obtain owner acceptance that an in-process reset without clear leaves the old publication visible. Verify the descriptor is visible through Glitch’s supported capability reader and observe a planning session following its instruction. Presence alone is not workflow adoption. Do not bulk-convert plans.
5. Click TODO in Files, choose that session and verify that the plan appears without asking for a path or sending agent input. Native local/SSH membership chooses the execution host. A raw SSH shell without native Tern ancestry is unsupported. No discovered alias is reused for a secondary SSH login; no credential or authentication state is copied. If multiple native windows can claim the new panel, attachment must fail closed; retry only from one unambiguous window/layout.
6. Observe pending, active, blocked-with-reason and done in the real client while canonical checkpoints change. Clear the publication and verify old success disappears while the agent stays alive. Reattach the now-unpublished session: show the no-plan notice and exit TODO only. A changed canonical plan id or publication must never be silently adopted. Repeat on solo Windows/macOS accounts and the existing Linux estate; helper and host-state checks are not visual acceptance, and macOS/Windows cross-account viewing is not implied.
7. At a normal maintenance boundary, restore the view. It retains its canonical path/id and live process birth/owner binding, never a bare pane number. An ended/reused process or different source is refused. Inaccessible process inspection remains visible and nonterminal rather than being mislabeled ended. No task is resumed merely by displaying its checklist.
8. Record exact reviewed/merged SHAs, installed file hashes, running versions, companion adoption and visual results on the tools PR and canonical interactive PLAN. Qualify limitations explicitly. Close owned review/probe panes after saved results are verified; create fresh ones for further work.

Install on each client machine through that machine's own existing authorized connection. No borrowed key, SSH access change, service restart, fleet/BWPM operation or FORGE write is part of this rollout.

## Account and platform boundaries

On Linux, group-readable publication metadata is only one prerequisite. The viewing host account must also be able to inspect the publishing process chain, read the canonical plan and traverse every plan ancestor. Never solve a failure by copying plans, automatically changing plan/ancestor permissions or forwarding Tern/agent sockets. The publisher changes only its own metadata modes: Linux `0751`/`0640` with the estate's `agents` group where available, macOS owner-only `0700`/`0600`, and Windows protected per-user ACLs. The explicit macOS legacy inventory and migration cover only that account's publication metadata, never canonical plans.

Metadata opens refuse followed links and revalidate the actual open descriptor/handle, including file type, ownership and link count. Mode migration uses those checked objects rather than a path that could have been swapped, preserving symlink targets and canonical modes. Pruning takes each different record's own lock, then reads and validates that record again before considering removal. TODO's Windows reader allows the sharing needed for replacement and closes its handle on success and error. If replacement fails, the previous valid publication remains rather than being retracted. Initial discovery treats temporary access/unknown failures as visible retryable states, allowing recovery when inspection later succeeds. A real initial `ProcessEnded` emits `terminal=true` and exits rather than retrying.

macOS and Windows stores are not shared across accounts. Qualification targets are solo-Mac, solo-Windows and the existing Linux multi-account estate unless later evidence expands them. The author handoff records 34 passing Python unit tests and a 13-check Linux native publication probe whose replace-failure case asserts `reader.closed` on the exception path. Integration then corrected hardlinked-lock mutation, open-handle Windows security validation and interpreter fixture assertions; the corrected source and new regressions remain unrun here. Real Mac/Windows, Linux-estate, Luau and native connected acceptance remain open. Windows sharing and handle behavior have mocked handoff coverage, not real Windows proof. The Luau discovery fixture uses captured real helper output for its terminal case but remains unrun until ORCH+ coordination.

Cooperating publishers use the native per-record writer lock, and failed cleanup compares the observed owner/revision/process anchors before unlinking. The final check-to-unlink sequence on the **same record** is **not atomic** against an outside or non-cooperating writer: such a writer can replace the record after the check and have its replacement unlinked. Different-record locking/revalidation does not remove this race. Do not describe cleanup as atomic compare-and-delete; preserve the limitation during rollout and review.

Removal is a separate authorized action: `tern plugin remove todo`. Never remove a canonical plan, another account’s data or an unrelated plugin.

## Claude workflow entry

The descriptor/reflex alone does not invoke adoption. After installing the reviewed
companion, append these command hooks to the supported machine-local
`.claude/settings.local.json`; merge each event array, preserving all existing
hooks, permissions and unrelated settings. Back up the original privately first.
Do not edit managed `.claude/settings.json` or managed hook files.

Command for each entry: `python3 -I <glitch-root>/_local/tern-todo/entry_hook.py`
with timeout 5, where `<glitch-root>` is that machine's Glitch root.

- SessionStart: matcher `startup|resume|clear` (exclude compact).
- UserPromptSubmit: no matcher.
- PreToolUse: matcher `Skill`.

Read back all three additions and compare the remaining settings to the original.
The hook supplies context only. The owning agent adds/maintains the agreed block
and publishes through its own normal tools; the installer never writes its plan.
Existing processes may retain hook snapshots: qualify a fresh ordinary
`/glitch-execute` invocation and real TODO display, not just a payload probe.
Never restart an acting session or send it input without the operator's go.

This wiring covers Claude sessions opening that Glitch root, not Codex/Kimi/Muse or
other CLI hook configurations. Every other harness requires explicit companion
publication by its owning agent through the documented interface. Descriptor
presence, an unwired hook or a payload probe is not automatic entry adoption.
