# ORCH+ for Tern

Run a team of AI agents from one controller in [Tern](https://docs.stencil.so/tern/): start a coordinator, hand out tasks, watch health, roll tired agents over to fresh context and land their work one merge at a time. Every step stays under your explicit control.

ORCH+ adds orchestration on top of native Tern and [SPAWN](../SPAWN/README.md). Tern gives you panes, sessions and native agents. SPAWN holds your roster of configured agent accounts and launches them. ORCH+ uses that roster to run managed workers:

- it assigns each worker an exact task;
- it reads the worker's structured reports through a private mailbox;
- it asks you whenever a decision is needed;
- it records every effect so that a launch, stop or message happens at most once, even across reloads.

Optionally, [USAGE](../USAGE/README.md) 2.1.0 or later supplies remaining-quota evidence so new work goes to an account with capacity left (see [Quota routing via USAGE](#quota-routing-via-usage)); without it, ORCH+ works fully and routing stays off.

![The ORCH+ controller: managed dispatch, worker health, owner gates and the landing queue](assets/screenshots/controller.png)

## What it does

- **One controller per logical session.** One ORCH+ view claims the controller for a logical session. Other views of the same session show the same facts read-only and can reveal the controller.
- **Dispatch through SPAWN.** You pick a configured SPAWN record from a revision-pinned catalog and type the assignment. ORCH+ never sees commands, SSH settings or credentials and has no raw-command fallback.
- **Structured reports, not screen scraping.** Workers report through a private report mailbox (READY, HEARTBEAT, ASK, CHECKPOINT, DONE and others). ORCH+ never reads transcripts or terminal output and never types into a pane.
- **Owner gates.** Questions, proposals, quota fallbacks and landing approvals become durable gates that only you answer.
- **Verified rollover.** A worker or coordinator close to its context limit hands over to a fresh successor. The handover uses a checkpoint the worker attests to, and no transcript is copied.
- **Landing queue.** Merges are queued per project, repository and target branch, with one granted slot per target and your approval for every grant.
- **Reload recovery.** After a reload, ORCH+ guides you step by step back to a running controller. Uncertain effects are never replayed.
- **Quota routing (optional).** Fresh USAGE evidence decides whether your chosen record still has quota left, and which of the alternatives you allowed to use if it does not.

## Requirements

- Tern 0.9.10 or later.
- [SPAWN](../SPAWN/README.md) 0.3.0 or later, installed on the same Tern host, with at least one record that declares the `report-files-v1` mailbox capability. A coordinator additionally needs a record provisioned with `coordinator-control-v1`.
- Optional, for quota routing only: [USAGE](../USAGE/README.md) 2.1.0 or later, with its read-only capacity export enabled and each SPAWN account bound in USAGE Setup (**Bind SPAWN accounts…**; OMP records through **Associate OMP records…**).

## Install

Install SPAWN and ORCH+ on the Tern host that will run your agents. If you work from a desktop attached to a remote Tern host, also install both on the desktop so their window code (buttons, pickers, the Files button) loads there.

```sh
tern plugin link /path/to/SPAWN
tern plugin link "/path/to/ORCH+"
tern plugin reload orchplus --json
```

You can also use **Preferences › Plugins › Install…** and enter the ORCH+ directory, the one that contains `plugin.toml`. Tern reloads plugins whenever a linked directory changes, so edit a copy, not the linked directory, while agents are running.

Installing or reloading ORCH+ starts nothing. After installation you have two entry points:

- the **Open ORCH+ Config** button (`flow` icon) in the Files pane header, beside the SPAWN and WORK buttons. It opens the session's Config page;
- the **ORCH+** command in the command palette. It opens the controller.

![The ORCH+ button in the Files pane header, with its tooltip](assets/screenshots/files-button.png)

Both entry points reveal an existing ORCH+ view in the current session rather than opening a second one. If ORCH+ cannot tell which view you mean, it shows a chooser.

## Use

All ORCH+ controls are native buttons, except the two reload recovery commands described in [Recover after a reload](#recover-after-a-reload), which you run from the command palette. Buttons that change something ask for confirmation, or open a picker or prompt, before they act. Once the controller has run its first command, a dispatch or assistance button runs only in the window that owns the controller; every other window showing the same controller ignores it. (Assistance on a controller restored after a host reload stays open to any window, so you can still inspect or stop its recorded owner.) A button from an outdated view is refused as stale and never replayed. If the host gets no confirmation from an ORCH+ window within 30 s, the press expires with a notice that it will not run later. A window may still have run it, so check the current state before pressing again.

### Claim the controller

1. Open ORCH+ from the palette.
2. On a brand-new installation, choose **Initialize first-use authority…** and confirm that there are no earlier owners and no lost store. ORCH+ never replaces missing data silently.
3. Select your logical session. If this really is separate work, choose **Register a distinct logical session…** instead.
4. Choose **Claim controller in this pane**. Only this view can now dispatch; every other view shows the same owner as occupied.

Closing the controller pane does not release ownership. Reopen ORCH+, select the same session and use **Recheck**. To move ownership to a new pane, follow the recovery steps shown on the owner card. Each step asks you to confirm that the old owner and its executors have stopped.

### Config page

Every ORCH+ view has a **Config** button, and the Files-header button opens Config directly. **Open ORCH+ controller** takes you back. Only the active controller can edit settings. Other views show them read-only, with the reason.

Checkboxes and −/+ buttons edit a draft. **Save session settings** commits only the fields you changed, and is refused if someone else saved in the meantime. **Enter value…** and **Enter time…** accept a single bounded value.

![The ORCH+ Config page: rollover, task routing, scheduling, mailbox sweep and the pane orchestration list](assets/screenshots/config.png)

| Setting | Default | Range |
| --- | --- | --- |
| Automatic worker rollover | off | on/off |
| Roll over at x% of worker-reported context | 80 | 1–99 |
| Include orchestrator (coordinator) in rollover | off | on/off |
| Use remaining quota / weekly reset in task routing | off | on/off |
| Keep in reserve (%) | 10 | 0–99 |
| Evidence max age | 15 min | 1–15 min |
| Allowed alternatives for initial dispatch | none | up to 24 explicit records |
| Allow a different provider / account / model (initial dispatch) | off | on/off each |
| Allowed alternatives and permissions for worker / coordinator rollover | none / off | up to 24 records each |
| Concurrent routed launches per session | 0 (no limit) | 0–32 |
| Automatic progress-report requests | off | on/off |
| Poll interval | 5 s | 1–60 s |
| Heartbeat | 60 s | 5 s–1 h |
| Stale after | 3 min | heartbeat–24 h |
| Nightly orphan mailbox sweep | on | on/off |
| Sweep time | 03:00 | local 24-hour time |

The **Pane orchestration list** shows every agent pane in the current session, ticked by default. Unticking a managed worker excludes it from automatic report requests and automatic rollover. Unticking never stops or retires anything. **Pause new work** / **Resume scheduling** holds or releases new work without blocking settlement.

Launch records, accounts, models and host settings stay in **SPAWN Config**. ORCH+ Config cannot set commands or credentials.

### Assign tasks and start a coordinator

1. In the controller, choose **Load configured SPAWN catalog**. You see the configured records with their capabilities, plus the reason any record is unavailable. Use **Next catalog page** when there are more.
2. Choose **Assign explicit task to …** for an ordinary worker, or **Start selected coordinator …** for the session's coordinator, then type the assignment.
3. SPAWN provisions the worker's report mailbox and launches the configured record in its configured directory and placement. The worker accepts the exact assignment and starts reporting.

Each worker's health card shows its native state, its last report, context use (as reported by the worker) and pending gates. **Queue immutable progress request** asks a worker for a report now, and **Open exact relevant pane** reveals it. Workers follow [worker-brief.md](worker-brief.md); coordinators additionally follow [coordinator-brief.md](coordinator-brief.md).

A coordinator only proposes. Each proposal becomes an owner gate that you answer with **Answer exact question…**. A coordinator can never launch agents, merge code or change accounts itself.

When work is done, **Finish ordinary worker…** stops the worker's exact pane and then retires its mailbox. A DONE report alone never stops anything. A coordinator finishes through **Request graceful coordinator retirement** or its own release.

### Worker rollover

**Roll over worker…** on a worker's health card, or automatic rollover at the Config threshold, works in four steps:

1. ORCH+ asks the worker for a CHECKPOINT that lists completed and remaining work and includes fresh check results.
2. It starts a fresh successor from the same SPAWN record, with the checkpoint as its assignment.
3. It waits until the successor accepts the exact handover and is observed running.
4. Only then does it stop the predecessor.

The predecessor keeps running until the successor is accepted. A failed step holds with a reason. You can cancel with **Cancel rollover…**, and nothing is retried blindly.

### Coordinator rollover

With **Include orchestrator (coordinator) in rollover** on, or through **Roll over coordinator…**, the coordinator hands over in the same way. Two coordinators never run at the same time:

1. The coordinator checkpoints and is retired.
2. Its exact pane stops and its mailbox is retired.
3. Only then is the successor started, carrying the handover.

If the stop is uncertain, the handover waits for the owner recovery steps.

If the successor fails to start or to accept the handover, no coordinator is active, because the predecessor is already retired. The hold says so and shows SPAWN's reason. To continue, stop the successor pane, then run fenced recovery on the successor's orchestrator owner card. That closes the rollover, and you can start a new coordinator from the retained checkpoint.

### Landing queue

A worker that wants to merge sends a landing request for an exact checkpointed commit and target branch. Each request opens a **landing approval** gate. Only the head of the target's queue can be granted, and only when:

- you have approved the request;
- the worker's latest checkpoint for that commit has fresh passing checks;
- the target head is the one the request expected.

The worker performs its own approved merge and reports the result. ORCH+ never runs git.

If the target moved before the grant, the item is blocked as `target_moved`. ORCH+ then sends the worker exactly one `landing_refresh` notice with the expected and current heads, and the worker sends a fresh request. Use **Move up**/**Move down** and **Cancel…** on ungranted items. When a granted result is lost, use **Result lost — hold slot…** and later **Reconcile observed outcome…**.

### Adopt a hand-opened agent pane

On the Config page, an idle, ticked agent pane that you opened yourself offers **Attach pane N as ORCH+ worker…** once a catalog is loaded. Pick a matching `native-agent` SPAWN record and type the assignment. You also confirm that you checked this exact pane. ORCH+ re-checks the pane just before acting. From then on it is an ordinary managed worker.

Nothing is adopted automatically, and shell panes are never typed into. Coordinators cannot be adopted.

### Recover after a reload

After a plugin or host reload, the controller becomes uncertain and nothing new runs. In the window you are working in, run **ORCH+ Reload recovery guide** from the command palette. The same list appears in the controller as the **Reload recovery checklist**, and it walks you through:

1. continuing the controller in this window, after you confirm the old executors stopped. You can also run **ORCH+ Continue controller in this window** from the palette directly;
2. recovering the previous SPAWN owner in **SPAWN: Running agents**;
3. **Continue after reload / reattach explicitly…** for each worker, with its recorded pane.

Use the palette commands, not the **Continue controller after reload…** and **Guided reload recovery — next step…** buttons, after a reload. A button press does not tell ORCH+ which window it came from. When two windows show the same session (for example a desktop window attached to a remote host and a window on that host), a press could otherwise open the picker in the other window and make that window the controller's origin. The buttons therefore only work in the window that already owns the controller. A palette command always runs in the window you typed it in. If several controllers are open in the session, focus the one to recover first.

ORCH+ reads uncertain effects back from SPAWN automatically, with read-only status reads only. **Read retained SPAWN outcome (never relaunch)** does the same read on demand.

Work that was queued but had not launched yet moves to the continued window. Its launch then runs there, even when its mailbox provision finished only after you continued. A launch that had already started in the old window is never re-run; it stays uncertain until its outcome is read back.

Some never-launched work cannot move: SPAWN already received its launch or provision (for example a launch whose window authorization expired and was rechecked), or it is an adoption whose ask was never sent. Continuation marks that request as never executed, and the worker shows **Cancel never-launched work…**. If SPAWN received the request, ORCH+ first reads SPAWN's retained status of it and cancels only when that request can never run: SPAWN has no record of it, rejected it, or reports that it was refused before any effect (an expired challenge counts). While SPAWN still holds a live challenge, wait 30 seconds and try again. Cancelling removes the worker and frees its reservations, including a coordinator start's slot. Nothing is stopped or re-sent, and a provisioned mailbox stays unused. Then queue the assignment again; it gets a new launch request.

### Quota routing via USAGE

> **Needs USAGE 2.1.0 or later.** Quota routing reads USAGE's read-only `usage.capacity` block and needs an owner-confirmed binding between each SPAWN account and its USAGE reading (USAGE Setup: enable capacity export, **Bind SPAWN accounts…**, and **Associate OMP records…** for OMP records). With routing on and no bound evidence, ORCH+ holds the task and says why ("no allowed record has sufficient fresh quota"). It never guesses. Routing is off by default.

Turn on **Use remaining quota / weekly reset in task routing** and enable USAGE's read-only capacity export (ORCH+ opens USAGE's capacity block in the background **SPAWN bridges** tab and reuses it after reloads). For each new task or coordinator start, the record you chose launches unchanged as long as its fresh, identity-bound USAGE evidence shows more remaining quota than the reserve. Otherwise ORCH+ picks the allowed alternative with the earliest weekly reset, but only if its provider, account and model changes are permitted in Config. If no permitted alternative qualifies, ORCH+ opens a quota-fallback gate for you to decide.

Missing, stale or unbound evidence never counts as "plenty". An OMP record uses its account's quota only after you associate it with that account in USAGE Setup (**Associate OMP records…**); until then it is unbound. USAGE confirms the evidence again right before each launch. **Refresh quota evidence from USAGE** and **Re-check capacity now** fetch fresh evidence. Rollover successors use their own allowlists.

## Where ORCH+ runs

ORCH+ orchestrates on the Tern host it runs on. The controller, the coordinator, the workers, their mailboxes and SPAWN's records all live on that one host:

- **Local agents:** open ORCH+ in a local Tern window.
- **Agents on a remote host:** attach a Tern window to that remote Tern host and open ORCH+ there. That host's ORCH+ and SPAWN run the work, and the desktop only displays it.

ORCH+ never reaches across an SSH hop. SPAWN records that launch through SSH are not eligible for managed dispatch, although ordinary SPAWN SSH launches keep working. There is no federation between hosts and no automatic migration.

## Safety guarantees and limits

- **Exactly-once effects.** Every launch, mailbox operation, message, wake and stop is recorded with an exclusive claim before it runs. After a lost or ambiguous result, ORCH+ only reads status back. It never resends or relaunches.
- **Fail closed.** Reloads, storage failures, capacity limits and missing panes keep ownership and work occupied until you verify and recover them explicitly. A timeout or missing pane never counts as "stopped".
- **No transcripts.** ORCH+ never reads a pane's transcript or screen and never types into terminals. Workers communicate only through structured reports, and you communicate with them through immutable replies.
- **No SSH hop.** See [Where ORCH+ runs](#where-orch-runs).
- **Your decisions are explicit.** Approvals, attestations and recovery steps are buttons you press. ORCH+ labels operator attestations as such, and never invents approval or infers a merge from DONE or an idle pane.

Known limits:

- Tern's UI events do not authenticate a person. Any process running as your OS user could press the same buttons.
- Effects are driven by an attached ORCH+ window. With no window attached, nothing new starts, and the nightly sweep catches up on the next attach.
- A confirmed native pane stop does not prove that every remote child process exited.
- Model and profile selectors are shown as unverified. SPAWN provides owner-entered text only.
- Landing does not use quota routing. Reserves cannot be set per quota window.
- Durability is that of Tern's plugin key-value store. One Tern host process per data directory is assumed.

The full protocol is documented in [REFERENCE.md](REFERENCE.md): storage limits, mailbox and sweep rules, dispatch and recovery details, and rollover and landing state machines.

## Verification

The tests run inside Tern's Lua runtime against a disposable data directory, together with a disposable SPAWN package. The entrypoint `tests/run.luau` takes the plugin directory and one or more `group[/section]` selections:

```lua
local root = "/path/to/ORCH+"
return assert(loadstring(tern.fs.read(root .. "/tests/run.luau")))(root, "dispatch/rejected_read")
```

| Group | Covers |
| --- | --- |
| `state` | authority registry, admission, persistence and capacity reserves |
| `transport` | report-files-v1 codecs, closed reply schemas, hashing |
| `authority` | host block: duplicate views, stale buttons, store changes, restore |
| `dispatch` | dispatch reducer: claims, results, quota routing, rollover, retirement, sweep |
| `reports` | report intake, context usage, landing queue and refresh notices |
| `gates` | owner gates, answers and cancellation |
| `health` | window scheduler, health, reload recovery, bridge panes, Config views |

Run each group in its own callback; long sections can also run one at a time. SPAWN has its own suites. See its [README](../SPAWN/README.md#tests). [REFERENCE.md](REFERENCE.md#test-sections) lists the named sections.

## Files

- `plugin.toml`: package manifest and the `orchestrator` block
- `window.luau`: palette commands (open, continue controller, recovery guide), Files button, button routing, scheduling, SPAWN and USAGE bridges
- `host.luau`: controller and Config block, and the only writer of ORCH+ state
- `views.luau`: controller and Config rendering
- `state.luau`: ownership registry and persistence rules
- `dispatch.luau`: dispatch, report, gate, rollover, landing and sweep reducer
- `transport.luau`: report-files-v1 codecs
- `quota.luau`: USAGE capacity normalization and routing rule
- `worker-brief.md`, `coordinator-brief.md`: contracts for managed agents
- `REFERENCE.md`: full protocol reference
- `mockups/`: conceptual SVG mockups
- `assets/screenshots/`: the screenshots in this README
- `tests/`: native regression suites

API references: [host lifecycle and block views](https://docs.stencil.so/tern/reference/api-host.html), [native UI nodes and actions](https://docs.stencil.so/tern/reference/ui.html), [window APIs](https://docs.stencil.so/tern/reference/api-window.html).

## License

MIT. See the repository [LICENSE](../../../LICENSE).
