# TODO rollout runbook

Blastworks.ai · MIT. Use the reviewed tools release and the existing release route. Live rollout requires separate authority for each target.

## Configure an execution host

1. Confirm the native Tern daemon, its execution account and the immutable TODO package approved for that machine. Use the account that owns its Glitch root and the hook settings. Use an installed Python 3.11 or later for automatic setup on Linux. Verify which real Claude and Codex executables that account uses, including any shell aliases.
2. Install the local package with `tern plugin install "$TODO_PACKAGE"`. Use `tern plugin install --force "$TODO_PACKAGE"` for an approved update. Preserve plugin data. If the daemon is stopped, setup runs on its next eligible load.
3. Enable **Do you use Glitch?** in TODO Settings on that host. An existing opt-in stays in effect across package updates. The helper uses an explicitly set `GLITCH_ROOT` in the daemon environment or an unambiguous owned local Glitch installation. Resolve any ownership or root ambiguity on that host before retrying. A connected window on another host does not authorize its remote daemon to write hook settings.
4. Read `TODO hook setup` in the native daemon log. `installed` or `current` means the helper read back its hook configuration. `unconfigured` and `error` carry the reason. An interrupted run can retry at the next eligible load. Switching Glitch off stops future automatic setup. Use rollback or removal for hooks already registered.
5. Open a fresh agent session in native Tern. In Codex, review and trust the intended TODO hooks through `/hooks`. The helper does not grant trust or restart agent sessions. Verify a real execute in that pane and inspect TODO's selected plan. A callback receipt alone does not prove that the view displays it.

The installer writes a versioned companion under `<glitch-root>/_local/tern-todo/versions/` and a setup record under `_local/tern-todo/.setup/`. It refreshes the discoverable companion descriptor and docs when their existing copies match a known version. It merges Claude's local `.claude/settings.local.json` and Codex's effective `$CODEX_HOME/hooks.json`, or `~/.codex/hooks.json` by default. It preserves other hooks and settings. The engine's `.codex` directory cannot serve as an automatic setup target, including via an alias. Managed Glitch files remain under engine ownership.

## Verify on the target

- In Claude Code, use `/glitch-execute "plans/Fixture plan.md"`. In Codex, use `$glitch-execute "plans/Fixture plan.md"`. Confirm the correct title and a checkpoint change in TODO. In Codex 0.172.0, `/glitch-execute` is not accepted by the native slash menu.
- Compare the fixture's bytes before and after the hook alone. Use a separate agreed legacy fixture to check the one scoped adoption command after the authorized block edit. The planning companion explains the block and the generic interface for other agents. [Planning companion](../integrations/glitch-plan-session-view/README.md)
- Reset one of two panes and verify that the other remains bound. Claude `/clear` reports the reset in the same process. Codex `/new` reports the new session on its first prompt, so its old pane binding can remain visible until then. Confirm that ordinary turns and compaction preserve the binding.
- Verify an already authorized native remote route with the same checks. The execution host owns its own opt-in and setup. Raw SSH without native Tern ancestry cannot publish. The viewer account needs permission to inspect the live process chain, read the plan and traverse its ancestor folders. Do not copy plans or credentials, forward sockets, or change permissions to work around a failed check.

Disposable Linux probes measured Claude Code 2.1.332, Codex 0.172.0 and Tern 0.9.22. Claude typed execute and the native Skill path published through TODO discovery. Fresh Claude panes published after the native package install and update. The update preserved Glitch consent. Native Codex entry and lifecycle were exercised. Record the exact versions, reviewed source, installed hashes, native trust, view and remote results for each rollout. Automatic hook setup supports interactive native Linux panes. Headless sessions, workers and read-only modes identified by the harness fall outside that path. Automatic macOS and Windows hook setup, native remote rollout, and runtime versions beyond the measured set still need qualification.

## Check, roll back or remove the hook setup

Run the installed package's helper as the same account. Use the actual absolute installed package and approved Glitch root. Turn off **Do you use Glitch?** before a rollback or removal to prevent a future eligible load from setting the hooks up again.

```sh
python3 -I "$TODO_INSTALLED/integrations/glitch-plan-session-view/install_hooks.py" --root "$GLITCH_ROOT" --action check
python3 -I "$TODO_INSTALLED/integrations/glitch-plan-session-view/install_hooks.py" --root "$GLITCH_ROOT" --action rollback
python3 -I "$TODO_INSTALLED/integrations/glitch-plan-session-view/install_hooks.py" --root "$GLITCH_ROOT" --action remove
```

Use one action at a time. `check` reads back the current recorded registration. `rollback` restores the recorded prior TODO registration. `remove` removes the identified TODO hooks. Other hooks and permission settings stay intact. If readback reports conflicting edits, stop and reconcile that account's settings before retrying. Start a fresh agent session to verify the result. Keep the canonical plans and the separate native TODO package data. Removing the package itself is a distinct action (`tern plugin remove todo`).

For an approved runtime at a nonstandard location, the installer also accepts `--claude-executable` and `--codex-executable` with absolute native executable paths. It still checks ownership, permissions and version before registering hooks.

The manual publisher and reader retain their native metadata protections and platform boundaries. Linux metadata access uses the existing `agents` group where available. macOS and Windows use owner-only caches. A cooperating writer's record lock serializes replacements and cleanup. Cleanup's final check and unlink are separate operations against a writer outside that lock. [Validation record](VALIDATION.md)
