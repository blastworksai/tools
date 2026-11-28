# TODO planning companion

Blastworks.ai · MIT.

On Linux, enable **Do you use Glitch?** in the installed TODO package on the host and account that run the agent. TODO configures the supported local Claude and Codex hooks when that host loads the package, including after an update. Use a fresh agent session. In Codex, review and trust the TODO hooks through `/hooks`. Setup does not change Codex trust. See the package runbook for the host logs, supported versions and rollback.

Enter `/glitch-execute "plans/Example plan.md"` in Claude Code or `$glitch-execute "plans/Example plan.md"` in Codex. Use one explicit canonical plan path. Quote paths with spaces. A supported Claude `Skill` call also supplies the exact plan argument. When the plan has a valid `TERN-SESSION` block, the hook publishes its identity to TODO for this pane. Open TODO and select the session if asked. Edits to the block refresh the view.

Keep Progress, START HERE and the agreed checkpoint block in the canonical plan. Use [CONTRACT.md](CONTRACT.md) when writing or maintaining the block. If execution deliberately resumes a plan with no block, the hook supplies one `todo.py adopt` command. The owning executor adds the agreed block through its normal authorized plan write, then runs that exact command once in the same agent session. A malformed block must be corrected through the normal plan workflow.

Claude `/clear` clears its old binding. Codex `/new` can leave the previous binding visible until the next input starts the new session. Ordinary turns and compaction leave a binding in place. A dead process invalidates its binding. For the generic interface below, clear before resetting or ending the conversation.

## Other interactive agents

Use the shipped `bin/todo.py` from the installed package or from the matching companion version reported by setup. Run these commands as the owning agent. Use `ancestry` to identify its durable PID. Select the agent process and verify its live Tern ancestry before passing the PID. The path and PID below are examples.

```sh
python3 -I /path/to/bin/todo.py ancestry
python3 -I /path/to/bin/todo.py publish --agent-pid 12345 --plan /absolute/canonical/PLAN.md
python3 -I /path/to/bin/todo.py clear --agent-pid 12345
```

The descriptor advertises the companion to Glitch. The native hooks trigger publication. The helper changes publication metadata only. Fleet and BWPM work are outside this integration.
