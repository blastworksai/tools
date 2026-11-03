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

Choose **TODO: attach to this panel** in Tern's palette. TODO detects the panel's native execution host, then asks for the absolute plan path there:

- **Native Tern remote host:** the detected host/address is shown and its existing session backend reads the file directly. A remote desktop's identity hop is not mistaken for the agent host. No second SSH login or agent-launch command is run.
- **Local panel:** a bounded native `tern process` query identifies the actual local foreground/child process. Ordinary local execution skips the Local/SSH chooser.
- **Terminal running SSH:** the destination/login is extracted from structured native process arguments and prefilled. Confirm that it accepts ordinary file commands before using it. The original remote command is never replayed. Known `seat-*` launch aliases, custom ports/keys/jumps/options and opaque wrappers require a reviewed file-reading alias that preserves that route; TODO never silently drops a port or key override.

Unavailable or ambiguous metadata retains explicit source selection. **TODO: attach with another source** always offers the manual override. A host/tab change, or a local process change while the path prompt is open, cancels attachment instead of using stale detection. Detection metadata and pane/process numbers are never saved; the view still pins only its selected file source and stable plan id.

“Local” means local to the selected Tern session host, even when another computer displays it. A genuinely remote SSH file source requires existing authentication/host trust, Python 3 and a POSIX remote shell. No key is copied, host trusted automatically, remote package installed or agent prompted. SSH destinations must accept ordinary file-reading commands; an agent-launch key cannot be reused just because its destination was detected.

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

### Quick invocation

Click **TODO** in Tern’s Files pane header to attach the current panel’s plan. It runs the same connection-aware attach flow as **TODO: attach to this panel** in the command palette. The existing bindable action remains `plugin.todo.show`.
