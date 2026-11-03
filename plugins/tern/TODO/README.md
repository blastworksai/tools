# TODO for Tern

Checkpoint visibility for the interactive `/glitch-plan` → `/glitch-execute` workflow. The canonical plan contains explicit agreed checkpoints, their current state and a blocked reason. The panel is a read-only native Tern checklist.

TODO is adapted from [Felipe Carneiro's session-list](https://github.com/felipevdc1/tern-session-list), MIT. 

## Scope

Interactive sessions only. The writer/executor updates the one canonical plan; the plugin displays its explicit checkpoint block. It never interprets dated prose as task completion, writes the plan, sends an agent prompt, adopts another task or grants release/deployment authority.

The panel binds to an explicitly selected source and stable `plan_id`. It does **not** follow another terminal's number. Restoring a view preserves that same source/id; replacing a file with a different plan is refused. A failed read clears previous success and shows an error.

## Planning integration

The companion contract in [integrations/glitch-plan-session-view/CONTRACT.md](integrations/glitch-plan-session-view/CONTRACT.md) describes how `/glitch-plan` adds the block and how its interactive executor maintains it. Keep normal Build choices, detailed tasks, dated Progress and the sole START HERE. Existing plans gain the block deliberately when resumed/revised; there is no bulk migration or inferred state.

Example (the helper generates a fresh stable plan id):

```sh
todo template --title "CSV import" --step "Implement the parser" --step "Prove the import" --step "Review and land the change"
```

Use the installed package’s absolute `bin/todo` path (`bin/todo.cmd` on Windows), or an optional PATH shortcut, for these CLI examples; the Tern installer does not add a command to PATH.

Canonical plan files use UTF-8 with LF or CRLF line endings. The reader never rewrites their bytes. The command prints a fenced JSON block between `<!-- TERN-SESSION:START -->` and `<!-- TERN-SESSION:END -->`; the agent places it in the canonical plan through its normal write path. States are `pending`, `active`, `blocked`, `done`. At most one is active. `current` names the active/blocked checkpoint, or is null; blocked checkpoints require a reason. Stable ids survive description/reordering changes. The view never edits these fields.

The companion is a source integration asset, **not an installed override of managed Glitch skills**. Live customization/upstream integration is not planned.

## Local or SSH

Choose **TODO: attach to this tab** in Tern's palette, select the agent's plan location and enter its absolute path:

- **Local:** the file is on the machine running this Tern session's daemon, even when a different desktop displays it. The agent can itself be SSH-launched if that host shares the canonical plan filesystem.
- **SSH:** the plan is on an explicitly reviewed ordinary SSH destination. The read-only reader is sent over SSH stdin to Python 3; no remote package installation or source write occurs. Existing host-key trust and authentication remain required. No key is copied, no host is trusted automatically and no forwarding is enabled. Forced agent-launch aliases (`seat-*`) are refused.

The remote source requires Python 3 and a POSIX shell. Native local reading is portable Python; the Windows command shim uses existing `py` or `python3`. No new package dependency or listening service is added. Authentication errors, unsupported shells, missing Python and invalid checkpoint blocks fail visibly. SSH access never falls back to another source or identity.

Direct source checks (no Tern environment required):

```sh
todo source --plan /absolute/PLAN.md
todo source --plan /absolute/PLAN.md --ssh reviewed-host
```

The reader returns only the validated checkpoint object, not whole plan prose, instructions or credentials. Requests have a finite deadline; each panel refreshes independently. Local sources refresh every 1.5 seconds and healthy SSH sources every 15 seconds. An SSH read failure clears previous success immediately, waits at least 60 seconds, then backs off to a maximum of five minutes; a successful read resets the delay. SSH always requires an already trusted host key and never updates known_hosts. There is no seat-wide lock or FORGE lookup. Usage/read errors return 1, never the Stop-hook continuation code 2. No hook is installed or required.

## Runtime and rollout

**Tern 0.9.8 or later is the minimum supported runtime for both the session daemon and viewing client.** The same connected suite passes on 0.9.8 (`f21d9a3`) and 0.9.10 (`2ad447b`). Both runs observe initial local rendering and test later SSH/restore behavior through real native host callbacks; authenticated remote/restored client visuals remain a pilot check. Confirm the actual running binary/client versions; changing a symlink does not update a running daemon. This plugin does not update or restart Tern.

Install the package with Tern's ordinary installer:

```sh
tern plugin install github.com/blastworksai/tools/plugins/tern/TODO
```

Plugin ID is `todo`; displayed name is **TODO**. Install on the actual session host/client combination; do not run a deployed service/plugin from a group-writable development checkout. See [docs/RUNBOOK.md](docs/RUNBOOK.md).

## Verification

```sh
python3 -m unittest discover -s tests -p todo_test.py
python3 tests/todo_smoke.py --evidence /absolute/private/evidence.json
```

The connected test uses a disposable Tern daemon, private Xvfb window and real loopback SSH server with generated temporary keys and strict host-key checking. It touches no live configuration or provider. Source and restored identity, local/SSH state changes, visible failures and independent views are checked. See [docs/VALIDATION.md](docs/VALIDATION.md) for observed results and unqualified platforms; loopback SSH is not proof of a remote Windows/macOS deployment.

The package contains only its active implementation and tests. Upstream legacy request, reminder and orphan-management code is not included.

## Attribution

Original plugin/native-checklist approach: Felipe Carneiro (`felipevdc1/tern-session-list`), MIT, based on f5920de0cc1018fa9814e5f0c6cca83a7ddf34dc. Original LICENSE remains. Explicit checkpoint reader, local/SSH source path and workflow contract: BlastworksAI, MIT. This fork does not claim independent origin of the native checklist design. 
