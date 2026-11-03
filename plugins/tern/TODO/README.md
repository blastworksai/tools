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

## Session discovery and source location

Click **TODO** in the Files pane and choose the live agent session to follow. TODO uses Tern's native agent communication to request that session's active canonical plan path and existing checkpoint plan id. The operator is not asked for the path. The request is metadata only: it must not start, resume, adopt or modify work. This explicit user-requested query supersedes the earlier no-agent-prompt design.

An explicit `none` reply shows **This session is not working on a plan** and exits the TODO attachment flow; the agent remains open. An active plan without a TODO checkpoint block is reported as unsupported. Busy agents, missing native communication, timeout, changed sessions or malformed replies end the flow with a detection error, never an invented no-plan result. There is no raw terminal-input fallback, automatic retry or automatic continuation.

Native remote Tern sessions use their execution host directly. Local panels use bounded, window-scoped native process metadata to identify their file-reading route. Raw SSH destinations can be detected, but the automatic discovery flow currently requires a native Tern remote connection for remote reads. A detected SSH alias does not prove that its key permits ordinary file commands; TODO will not reuse an unverified agent-launch key. Raw SSH, custom command-line port/key/jump overrides and opaque wrappers end the flow rather than ask the operator or silently change the route. Existing SSH trust/authentication and a POSIX remote shell with Python 3 are required. No credential is copied, host trusted automatically or remote package installed. The accepted reply's stable plan id is pinned before the first read.

The protocol and current qualification limits are in [agents/INSTRUCTIONS.md](agents/INSTRUCTIONS.md) and [docs/VALIDATION.md](docs/VALIDATION.md). Native agent-protocol support is required; a generic terminal is not treated as a safe agent input endpoint.

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

Click **TODO** in Tern’s Files pane header, choose a live agent session, then let TODO query that session for its active canonical plan. The picker lists native agents and terminal panes (including CLI agents), labelled with their host, Tern session, program and pane identity. Selection reveals the chosen panel, detects its connection and requests its active plan through native Tern agent communication. Closed, parked or disconnected targets are excluded; a target that changes while the picker is open must be selected again. **TODO: attach to this panel** in the command palette remains the direct route for the focused panel. The existing bindable action remains `plugin.todo.show`.
