# TODO for Tern

Plan visibility for the interactive `/glitch-plan` → `/glitch-execute` workflow. The canonical plan contains explicit agreed checkpoints, and optionally the tasks, file changes, implementation steps and validation checks under them, each with a current state and, when blocked, a reason. The panel is a read-only native Tern checklist. TODO also works as a native Tern board when Glitch is off.

## Status bar, settings and boards

TODO lives in Tern's status bar: the **TODO** segment (icon `list-checks`) opens a **TODO Settings** pane, a new pane and never a popout. The same pane opens from the Command Palette (`Ctrl+Shift+P`) with **TODO: Open Settings**. If the **Plugin segments** widget is not in the widget bar, the first window start asks once, per plugin installation, whether to add it (the shared status-bar prompt); the palette command always works. TODO adds nothing to the Files pane.

The settings pane has these fields:

1. **Attach to**: the live agent or terminal sessions that suit the current mode. Closed, parked or ineligible sessions never appear, and the choice is checked again right before TODO attaches, opens a board or syncs.
2. **Do you use Glitch?** Off by default.
3. Glitch **Off**: **Board** (On by default) opens Tern's ordinary board for the attached local session's folder. Board Off shows `No TODO source is enabled. Turn on Board or enable Glitch integration in TODO Settings.`
4. Glitch **On**: the TODO pane shows `/glitch-plan progress will be shown in the TODO pane.` and **Sync Glitch Plan to Tern Board?** (Off by default).

Settings are stored in the plugin's own key/value store with closed validation and safe defaults.

### Board sync (Glitch to Tern, one way)

With sync On, TODO keeps one managed board per stable plan (`<plugin data>/boards/<plan_id>.md`) with the lanes Pending, Active, Blocked and Done. Every checkpoint, task, file change, step and validation check is a card. A card's identity is its canonical id, kept in a `todo-id-<id>` tag, never its title or a native card id, so renames update in place and re-reading a plan changes nothing. Reordering changes nothing on the board. Changing a state moves the card to its lane. An entity removed from the plan has its managed card removed. A different plan id gets a different board; the old board is left alone. Cards without a `todo-id-` tag are never touched. Turning sync Off stops all writes and leaves the cards where they are; there is no cleanup.

**Size limits.** A plan can hold up to 500 checkpoints, tasks and items for viewing. A plan syncs to a board only up to **250** of them (`MAX_SYNC_ENTITIES` in `lib/board_sync.luau`). Above 250, sync is refused with a visible message in TODO Settings, nothing is written, and the plan view still works. The reason: Tern reads at most 500 cards from a board and cannot page, so two windows that both write a complete copy of the plan must still fit in one read. Then every duplicate is visible and the ordinary repair removes it. Your own cards on the board count toward the same 500-card read. When a read is cut short, TODO writes no new card and reports it; it only removes managed cards it can see to be duplicates or no longer in the plan. Tern's typings promise no card order inside a lane, so TODO never assumes its cards are read before yours. TODO never removes a card by counting. Tern edits never write to the Glitch plan. `cx.board` is desktop and local only, so remote sessions can be viewed (sync Off) but cannot be a board target; the settings list leaves them out for the board modes.

TODO is adapted from [Felipe Carneiro's session-list](https://github.com/felipevdc1/tern-session-list), MIT.

![TODO’s native checklist beside an interactive agent session](assets/screenshots/todo-blurred.png)

*The TODO checklist stays readable; surrounding panes and connection details are blurred for privacy.*

## Plan schema

`schema` 2 nests `checkpoints[] -> tasks[] -> items[]`. Checkpoints carry `id`, `text`, `state`, optional `reason` and optional `tasks`. Tasks carry the same fields and optional `items`. Items carry the same fields plus `kind` (`file`, `step` or `validation`); a `file` item also carries its `path`. `schema` 1 (checkpoints only) stays valid and readable. Ids are lowercase, unique across the whole plan and stable; the nesting itself is the parent link, so a parent reference cannot dangle. At most one entity is `active` and `current` names it; a blocked entity needs a reason. Bounds: 30 checkpoints, 20 tasks per checkpoint, 30 items per task, 500 entities in all, 240 characters of text, 400 of reason.

## Scope

Interactive sessions only. The writer/executor updates the one canonical plan; the plugin displays its explicit checkpoint block. It never interprets dated prose as task completion, writes the plan, sends an agent prompt, adopts another task or grants release/deployment authority.

The panel binds to an explicitly selected source and stable `plan_id`. It does **not** follow another terminal's number. Restoring a view preserves that same source/id; replacing a file with a different plan is refused. A failed read clears previous success and shows an error.

While the selected plan is loading, the panel displays its reading status. A failed or ended source replaces the previous checklist with **Plan unavailable** and the diagnostic reason; it must not leave a blank panel or stale successful checkpoints. Loading, error and normal-plan views use container roots so Tern renders their contents.

## Planning integration

The companion contract in [integrations/glitch-plan-session-view/CONTRACT.md](integrations/glitch-plan-session-view/CONTRACT.md) describes how `/glitch-plan` adds the block and how its interactive executor maintains it. Keep normal Build choices, detailed tasks, dated Progress and the sole START HERE. Existing plans gain the block deliberately when resumed/revised; there is no bulk migration or inferred state.

Example (the helper generates a fresh stable plan id):

```sh
todo template --title "CSV import" --step "Implement the parser" --step "Prove the import" --step "Review and land the change"
```

Use the installed package’s absolute `bin/todo` path (`bin/todo.cmd` on Windows), or an optional PATH shortcut, for these CLI examples; the Tern installer does not add a command to PATH.

Canonical plan files use UTF-8 with LF or CRLF line endings. The reader never rewrites their bytes. The command prints a fenced JSON block between `<!-- TERN-SESSION:START -->` and `<!-- TERN-SESSION:END -->`; the agent places it in the canonical plan through its normal write path. States are `pending`, `active`, `blocked`, `done`. At most one is active. `current` names the active/blocked checkpoint, or is null; blocked checkpoints require a reason. Stable ids survive description/reordering changes. The view never edits these fields.

The companion is installed separately under `_local/tern-todo`, through Glitch’s supported local customization path. It does not override managed skills or hooks. Its publication instruction must be observed in the planning session; descriptor presence alone does not prove adoption. Claude's optional additive entry hook is specific to its configured Glitch root. Codex, Kimi, Muse and every other harness require explicit companion publication by the owning agent; automatic entry delivery or adoption is not claimed for them.

## Platform and account boundaries

Linux multi-account viewing requires **both** successful native process inspection and host-readable canonical-plan paths. The Tern host account must be able to read the plan and traverse every ancestor directory, as well as inspect the publishing process chain. Sharing pointer metadata alone is insufficient. On the existing Linux estate, per-owner publication directories and records use the `agents` group's read access (`0751` directories, `0640` records/locks); only the owning account can write them. Group membership and plan-path access remain deployment prerequisites.

macOS and Windows publication stores are owner-only. macOS uses `0700` directories and `0600` files; Windows uses the native account's protected cache and ACL. Discovery does not read another account's store. Solo-Mac and solo-Windows use, plus the existing Linux multi-account estate, are the current qualification targets unless later evidence expands that scope. This target statement is not a claim that the pending real-device gates have passed.

Never work around an account or path boundary by copying canonical plans, automatically changing plan or ancestor permissions, or forwarding Tern/agent sockets. TODO changes modes only on its own publication metadata, never on canonical plans. Native process birth and ownership interfaces come with the OS; there is no new package dependency or listening service. An inaccessible process inspection remains a visible, nonterminal unknown; only a definitively ended or changed process is terminal.

On Windows, a handle-bound exit time is definitive even when another process retains the exited process's handle and it no longer appears in the parent snapshot. A missing parent for a still-live process remains unknown; access and enumeration failures are not treated as exit.

The CLI disables Python bytecode writes before loading its installed helpers, including when the native reader invokes Python with `-I`. Discovery and publication do not add `__pycache__` files to the plugin installation; intentional publication metadata remains in its separate native store.

Publication metadata is opened without following links and checked through the open descriptor/handle, including ownership, file type and link count. Permission migration acts on those already-checked objects, so a pre-placed symbolic link cannot redirect mode changes to another directory or a canonical plan. When pruning an old session's record, the helper takes that record's own lock and reads and validates it again; a different session's newer record is not removed using an earlier observation. TODO's Windows reader keeps the previous bytes when a checked replacement is installed while its handle is open; new readers see the replacement. All handles are closed. A read-only target is refused without changing either file or clearing its attributes. If installing a replacement fails, the previous valid publication stays in place. During initial discovery, a temporary access/unknown failure stays visible and retries so a later readable publication can appear. A real initial `ProcessEnded` instead emits `terminal=true` and exits the flow rather than retrying.

The outside/non-cooperating **same-record** cleanup limitation remains: comparing a record and then unlinking it is not atomic, and an outside writer can replace it between those steps. Cooperating per-record locks do not remove that race.

## Session discovery and source location

Pick the live agent session under **Attach to** in TODO Settings (or run **TODO: attach to this panel**), and TODO resolves its explicitly published plan. It never asks the operator for the plan path or types into the agent. The planning companion publishes after an agreed plan is created or deliberately resumed/revised:

```sh
todo publish --agent-pid 12345 --plan /absolute/canonical/PLAN.md
todo clear --agent-pid 12345
```

Identify the agent’s actual durable process with its runtime or `todo ancestry` and pass its verified numeric pid on every invocation (12345 in the example is a placeholder); never use a shell/launcher/helper pid. See [the companion](integrations/glitch-plan-session-view/README.md). Publications contain only the existing canonical path/plan id and a verified live process birth/owner chain. The binding validates the explicitly declared publisher process, including its birth and owner; pane/PID reuse is refused. The planning agent must identify its own durable CLI process; no shell-name inference is used. The canonical record remains authoritative; normal edits refresh without republishing. Clear or process exit invalidates old success and stops polling the ended binding. A conversation reset in the same process is not detectable: the agent must explicitly clear before reset/end and on fresh-conversation startup; skipping that instruction can leave the previous plan visible until clear or process exit. A changed plan requires deliberate reattachment.

No active publication shows **No active plan is published for this session** and exits the TODO flow, leaving the agent running. Invalid metadata/access produces a detection error instead. This works with ordinary CLI agents: no native agent composer, draft inspection, prompt submission, hook, socket access or copied credential is needed.

Local and native SSH Tern sessions use the same host-side resolver. The viewing client confirms the native split beside the selected session; the execution host resolves that split to its own process metadata, using only window keys its own daemon lists (the client window's key is never sent across), then reads its own published canonical file. Client-side pane handles are never interpreted as host CLI ids. The label shows Local or SSH and the native host. Raw SSH into a machine without native Tern ancestry is unsupported; there is no guessed local path or automatic secondary SSH login. If multiple native windows can claim the new TODO panel, membership is ambiguous and attachment fails closed rather than selecting a window or source arbitrarily. Attach again from one unambiguous window/layout.

Direct source checks (no Tern environment required):

```sh
todo source --plan /absolute/PLAN.md
todo source --plan /absolute/PLAN.md --ssh reviewed-host
```

The reader returns only the validated checkpoint object, not whole plan prose, instructions or credentials. Requests have a finite deadline; each panel refreshes independently. Local sources refresh every 1.5 seconds and healthy SSH sources every 15 seconds. An SSH read failure clears previous success immediately, waits at least 60 seconds, then backs off to a maximum of five minutes; a successful read resets the delay. SSH always requires an already trusted host key and never updates known_hosts. There is no seat-wide lock or FORGE lookup. Usage/read errors return 1, never the Stop-hook continuation code 2. The viewer/reader needs no agent hook. Automatic Claude planning/execution entry uses the separately installed companion entry hook; that instruction delivery does not itself publish a plan.

## Runtime and rollout

**Tern 0.9.8 or later is the minimum supported runtime for both the session daemon and viewing client.** Connected runs on 0.9.8 (`f21d9a3`) and 0.9.10 (`2ad447b`) are historical pre-0.6.0 evidence, not current-head acceptance. Those runs observed initial local rendering and tested later SSH/restore behavior through native host callbacks; authenticated remote/restored client visuals remained open. Confirm the actual running binary/client versions; changing a symlink does not update a running daemon. This plugin does not update or restart Tern. It can update itself; see Update.

Install the package with Tern's ordinary installer:

```sh
tern plugin install github.com/blastworksai/tools/plugins/tern/TODO
```

### Update

Run **TODO: Check for updates** from the command palette. When a newer version is on GitHub, **TODO: Update** installs it in place: it checks the release's requirements and asks first, and can also update connected remote hosts. Tern then reloads all its plugins, and your settings carry over. If ORCH+ is running a controller, run **ORCH+ Reconnect** afterwards.

The preview is not a pinned commit. Installation checks the actual package, requirements and load evidence; a different installed version is not the preview's success. If reload or missing process evidence leaves an uncertain result, use **TODO: Resolve update outcome**. It never repeats the install, and resolving as unverified does not certify success. A positively running installer cannot be overridden.

A copy installed before the updater existed needs one manual update:

    tern plugin install --force github.com/blastworksai/tools/plugins/tern/TODO

A linked development checkout (`tern plugin link`) is never updated by the plugin; `git pull` it yourself.

Plugin ID is `todo`; displayed name is **TODO**. Install on the actual session host/client combination; do not run a deployed service/plugin from a group-writable development checkout. See [docs/RUNBOOK.md](docs/RUNBOOK.md). The current helper source hashes for a later coordinated companion/plugin rollout are recorded in [docs/VALIDATION.md](docs/VALIDATION.md); recording them performs no rollout.

## Verification

```sh
python3 -m unittest discover -s tests -p todo_test.py
python3 tests/todo_smoke.py --published --evidence /absolute/private/evidence.json
```

The connected test uses a disposable Tern daemon, private Xvfb window and real loopback SSH server with generated temporary keys and strict host-key checking. It touches no live configuration or provider. It is designed to check source and restored identity, local/SSH state changes, visible failures and independent views. See [docs/VALIDATION.md](docs/VALIDATION.md) for the actual 0.6.0+ head, current helper hashes, executed results and every unrun native/real-device gate; loopback SSH is not proof of a remote Windows/macOS deployment.

The package contains only its active implementation and tests. Upstream legacy request, reminder and orphan-management code is not included.

## Attribution

Original plugin/native-checklist approach: Felipe Carneiro (`felipevdc1/tern-session-list`), MIT, based on f5920de0cc1018fa9814e5f0c6cca83a7ddf34dc. Original LICENSE remains. Explicit checkpoint reader, local/SSH source path and workflow contract: BlastworksAI, MIT. This fork does not claim independent origin of the native checklist design.

### Quick invocation

Click **TODO** in the status bar (or press `Ctrl+Shift+P` and run **TODO: Open Settings**), choose a live agent session under **Attach to**, then let TODO resolve that session’s published canonical plan. The list shows native agents and terminal panes (including CLI agents), labelled with their host, program and pane identity. Closed, parked or disconnected targets are excluded. **TODO: attach to this panel** in the command palette remains the direct route for the focused panel. The existing bindable actions are `plugin.todo.show` and `plugin.todo.settings`.
