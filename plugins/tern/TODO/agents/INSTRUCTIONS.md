# Interactive plan publication — CodexBWAI

Use TODO for visible interactive `/glitch-plan (Codex: $glitch-plan)` work. Unviewed fleet/BWPM/FORGE work is outside it.

Read the installed planning companion at `<glitch-root>/_local/tern-todo/README.md`, or the packaged `integrations/glitch-plan-session-view/README.md`. Deliberately maintain one agreed checkpoint block in the canonical plan, then run `todo publish --plan <its absolute path>` from this agent's own normal tool session. Clear with `todo clear` when the session stops working on a plan. Never publish another pane's plan or infer a plan from startup notes or the current directory.

Publication is metadata only: path, existing plan id and OS-verified process identity. It does not copy or modify canonical content. The viewer reads that canonical file; the planning/execution workflow remains authoritative. No model prompt, terminal input, continuation, provider work or hook is sent/installed by TODO.

The Files button asks the operator which session to follow. The host resolves that session's valid publication. No valid active publication means an informational notice and exit from the TODO flow; the selected agent stays open. Unsupported metadata/access or changed process/source produces a distinct error. An existing view never adopts a different plan automatically.

All source identity crosses through the existing native Tern execution host. Do not forward another Unix identity's socket or credentials. Raw SSH without native Tern host ancestry cannot publish. Helpers need only existing Python 3 and native OS interfaces; do not install anything to force a publication.

Publish/clear require --agent-pid: identify your actual durable interactive CLI process from runtime facts or the helper’s ancestry output. Do not guess a wrapper name or use the shell/helper pid. Clear before conversation reset/end and on fresh-conversation startup. An in-process reset without clear cannot be detected and may leave the previous plan visible; disclose this residual.
