# ORCH+ for Tern

Coordinate several projects, plans and agent conversations in [Tern](https://docs.stencil.so/tern/). Talk to the orchestrator about the work; use the adjacent **ORCHESTRATED WORK** panel to choose agents, attach conversations, start projects and answer decisions.

**Provider-native orchestration is often the best choice.** Use an agent's own delegation tools when one provider and one conversation already meet your needs. ORCH+ is useful when you want a shared view of concurrent plans, different providers or accounts, existing conversations, review and landing decisions.

[SPAWN](../SPAWN/README.md) owns agent configurations and launching. ORCH+ owns the organization and coordination of work. [USAGE](../USAGE/README.md) optionally supplies account usage and explicitly enabled capacity-routing evidence. Glitch integration is optional; ORCH+ does not require a Glitch installation for ordinary conversations and projects.

## Local first

The default is **this machine, your current OS account**. Local setup needs no SSH connection, host chooser, sudo or extra service. Agent CLIs must already be installed and authenticated, with the permissions you intend to give them.

For remote work, use Tern's existing connection to that host and open ORCH+ there. The same interface and pane-free connection are used; agents, saved configurations and mailboxes remain on the execution host. There is no separate ORCH+ SSH setup, parked transport pane, transport tab or background product daemon.

This is not cross-host federation: an orchestration coordinates work on one execution host. Standalone SPAWN SSH-command records remain separate from managed orchestration.

## Requirements

- A compatible Tern installation and matching [SPAWN](../SPAWN/README.md) package. The updater checks the exact package requirements in [requires.json](requires.json).
- Agent configurations that have completed SPAWN's managed setup for the work they will perform. An enabled account alone does not establish supported coordination or reporting capabilities.
- A prepared native-agent or managed local-terminal configuration with `coordinator-control-v1` for the orchestrator pane. Native agents receive notifications; terminal agents use the provisioned helper's bounded wait/poll route. Agent labels alone do not establish this capability.
- Optional: USAGE for display percentages. Quota-based routing additionally requires its capacity export and explicit account bindings.

Native OMP launching currently requires a reviewed POSIX execution-host shell. Windows managed local-terminal setup requires a native `.exe` with the supported Windows argument contract; native OMP and cross-user managed setup on Windows are not supported. A Windows desktop connected to a POSIX Tern host uses that host's supported native route. See [SPAWN's platform requirements](../SPAWN/README.md) before choosing an execution host.

## Install

Install SPAWN and ORCH+ on the host that will execute the work. For a desktop attached to a remote Tern host, install the matching packages on the desktop too, so their native window controls are available.

```sh
tern plugin install github.com/blastworksai/tools/plugins/tern/SPAWN
tern plugin install github.com/blastworksai/tools/plugins/tern/ORCH+
```

**Preferences › Plugins › Install…** accepts the same repository-subfolder sources. These commands install the default-branch packages, not an unpublished development candidate. A local package directory is also accepted. Use `tern plugin link` only for development: edits to linked files reload plugins.

Installing or reloading the plugin does not start agents or resume projects.

## Get started

1. Open **SPAWN** and complete agent setup. Installing SPAWN alone is not enough: ORCH+ checks the saved setup before it lets you create an orchestration.
2. Click **ORCH+** (the flow icon) in Tern's status bar to open its Config in a new pane, or open **ORCH+** from Tern's command palette. The status entry only opens Config: it starts no orchestration, admission or dispatch. On first start ORCH+ offers once to show plugin buttons in the status bar (the **Plugin segments** widget of the widget bar) if it is not placed; the Files pane no longer carries an ORCH+ button. Use **Define Default Settings** to save your preferences, then **New orchestration…** to give the orchestration a recognizable name. Later, **Edit Default Settings** changes the defaults for new orchestrations only.
3. Choose **Start orchestrator pane**, then an eligible agent. The compact picker loads available agents itself. Starting an agent may use model credits.
4. Describe what you want in the orchestrator conversation. Add projects, plans or other conversations as needed. Importing a plan does not authorize its tasks to execute: use that project's **START** decision.

The agent list shows provider icon, provider name and account label, with usage when available. Missing usage is shown as unavailable, never as zero. A displayed percentage is informational; it is not permission to switch accounts or models.

If no agent is eligible, the interface explains the missing setup. It does not silently substitute a raw terminal command or grant capabilities based on an account's name.

## ORCHESTRATED WORK

The side panel is organized by project:

- Each project, imported plan or WORK ON item is a top-level item.
- Its agent conversations are children. A conversation row includes **provider · account — pane name**, using the pane's current name, including your renames.
- **ACTIVE** means the project has live associated work or conversations. An idle but still-live conversation remains active.
- **START** is the explicit action for an unstarted project. An active project can still contain newly added, held work; its project menu offers the corresponding START action.

Adding or selecting a project does not restart its existing work. Completing a project retains its result under **Finished projects**. Reopening does not replay earlier tasks or launches. Live conversations and unsettled effects must be dealt with before a project can finish.

### Start an agent session

Choose **New Agent Session**, then an existing project or **New project…**, then an agent. The click starts that session through its saved SPAWN configuration. Describe and refine its task in the agent pane, not in a form asking you to enumerate files, checks and internal identifiers.

Code work still needs a concrete scope, appropriate checks and a repository/target before it can be reviewed and landed. The conversation and coordinator establish those details; hiding technical controls does not remove the checks.

### Attach a conversation

Choose **Attach Existing Agent Session** and select the existing session. With Glitch integration enabled, ORCH+ can use available structured work context; otherwise, or when that context is not sufficient, choose an existing project or name a new one.

Attachment preserves the conversation and its context. It does not inject a task, change its permissions or automatically start imported work.

You can then opt into managed coordination:

- **Native OMP:** send enrollment to the exact idle conversation through its native message API. A busy conversation remains attached without being interrupted.
- **Terminal agent:** copy the enrollment instructions once and paste them into that conversation yourself. Copying is not acceptance; ORCH+ waits for the actual matching reply.

Detaching a passive association leaves the conversation running. Moving a managed conversation to another project changes its association, not its existing task or context.

### Add plans, boards and Glitch work

Use the orchestration or project menu to **Add plan file…**, **Add board…**, or start from a saved template. Several plans and projects can coexist in one orchestration. Plans are shown together by logical checkpoints/features rather than arbitrary small pages.

**WORK ON** is available only when Glitch integration and its separate WORK ON switch are enabled. It requires [WORK](../WORK/README.md); ordinary ORCH+ use does not. WORK opens its native project and unarchived-plan picker and returns the selection to ORCH+. It does not start a second standalone agent.

On first use, ORCH+ creates an **ORCH+ Board** using Tern's native board format. It shows checkpoints, tasks and their supported file changes, steps and validation checks. The fixed lanes are **Plans**, **Todo**, **Doing**, **Review** and **Done**. There is no lane-configuration step.

The linked board follows source changes while the controlling window is attached, including while work is paused. A progress-note edit does not create work or rewrite cards. Source completion and work progress update the corresponding owned cards; unrelated cards and human edits are retained. Changed or ambiguous managed tasks remain held instead of restarting completed work.

Use **Open plan** beside a plan title in ORCH+ to open its source on the execution host. The board's **Source plan** reference retains the link and synchronization information.

Plan checkpoints preserve their order. Independent tasks can run concurrently within the configured limits; sequential tasks wait for their prerequisites. Adding or synchronizing a plan does not authorize execution: use the project's **START** action unless you explicitly enabled automatic starts.

The board file belongs to the desktop window. On a remote Tern connection, it is not automatically on the execution host. ORCH+ confirms remote board access and retains unresolved writes rather than repeating them. External inbox polling is available only when the observing window runs on the execution host.

## Settings

Settings open in a real pane, with labeled fields and collapsible groups. Raw JSON, ownership details and manual recovery stay under **Advanced**.

- **SAVE AS DEFAULT ORCHESTRATION SETTINGS** applies to future orchestrations. The first explicit save defines your defaults even if you leave every value unchanged.
- **SAVE FOR THIS ORCHESTRATION INSTANCE ONLY** applies to the current orchestration. It does not change your defaults.

Absolute board/inbox paths and live pause/exclusion state are not copied into reusable defaults. A conflicting save keeps the draft and asks you to reload or review the changed settings; it does not overwrite newer configuration.

If a value blocks Save, its section opens and the field is marked in red with the required format or bounds. Correct the marked fields and save again; entered values remain in the draft. Alternative-agent lists are saved as sets, while reviewer preference order stays unchanged.

Choose saved agents as preferences even before their orchestration helpers are prepared. ORCH+ checks the required launch capabilities when work starts; choosing an agent here does not claim it is ready or launch it.

**Close** discards unsaved edits without waiting for the source pane to recover. **Browse** opens a folder/file list inside the relevant field: board files use the computer running the Tern window; repository and inbox paths use the execution host. A blank **Board file location** uses ORCH+'s managed plugin-data location, not your Desktop folder.

Fresh defaults allow four concurrent managed tasks, leave the quota-evidence-age override Off and enable automatic worker rollover. Existing explicitly saved preferences are preserved.

| Group | Settings |
| --- | --- |
| Glitch Integration | Enable Glitch and WORK ON separately. The WORK install/update action is needed only for WORK ON. |
| General | Automatic working-folder tracking, automatic starts and board location. |
| Agents and Routing | Preferred worker and orchestrator, verified USAGE quota routing, reserve, optional evidence-age limit, concurrent managed work and separate alternative-agent lists for new work and each rollover kind. |
| Review and Completion | Required review, different declared provider family, allowed reviewers and the merge/release agent. |
| Continuity | Automatic worker rollover, reported-context threshold and whether the orchestrator also rolls over. |
| Advanced | In-scope automatic approvals, cleanup, report timing, loop/review/stale-claim limits, external inbox and custom templates. |

Commands, permissions, account labels, models and declared provider families belong to **SPAWN**, not ORCH+.

### Project code and merging

Open a project, then **Settings → Code and merging**. ORCH+ discovers known project folders and reads the repository's locally known default branch. It does not assume that your current feature branch is the merge target, hardcode `main`, or contact the network to discover a default.

Choose the working folder and **Merge changes into** branch. A saved explicit target is retained when you reopen the form. **Advanced → Who handles merges?** chooses ORCH+ coordination or the repository's protected merge queue. This is a project setting, not a second global landing switch. Shared repository/target coordination still applies across local orchestrations.

Text, writing and research projects do not need a repository or release manager.

### Reports, cleanup and templates

Report polling checks for agent updates; the default is five minutes. Optional automatic report requests have their own fifteen-minute interval and do not interrupt busy agents. Reports become stale after the separate thirty-minute threshold. Initial enrollment and coordinator-activation receipts use a separate polling cadence of at most two seconds for up to two minutes, then return to the configured interval. These reads never resend startup instructions or start project work.

Night Cleanup checks settled communication resources once a day at the chosen `hh:mm:ss` desktop-local time. It catches up when a window returns after sleep. It never deletes plans, code or conversations, stops working agents, or discards uncertain messages. The next ORCH+ panel interaction can show the day's remaining communication-file inventory. See [the backlog](documentation/backlog.md) for the planned way to show the summary when you return to the orchestrator conversation.

Under **Advanced → OPTIONAL: Templates**, ask your orchestrator to help set up custom work item templates. A template has an ID, title, prompt, output path, optional next template, optional task type and named custom fields. `{input}` supplies the invocation input; `{name}` uses a supplied custom-field value. Each template has its own defaults; only explicit invocation overrides carry to the next template. A task type is metadata, not an instruction to switch agents. Template chains still obey work-start, scope and loop limits.


### Quota routing via USAGE

The setting is **Use remaining quota and weekly reset in task routing**. It is off by default. Enable USAGE's read-only capacity export and explicitly bind the SPAWN account to its USAGE reading; OMP records need an explicit association with the underlying account.

For each routed new task or coordinator start:

1. Keep the selected agent when its fresh, identity-bound readings are strictly above the configured reserve in every bound quota window.
2. Otherwise consider only the alternatives you allowed for that kind of launch, subject to the provider/account permissions you enabled.
3. Among qualifying alternatives, prefer the earliest weekly reset. Revalidate the exact evidence immediately before launch.
4. If none qualifies, hold the work and explain the decision needed. Missing, stale, revoked or unbound evidence never means unlimited capacity.

Worker rollover and orchestrator rollover have separate alternative lists and provider/account permissions. The original agent stays preferred; its saved model and command are not rewritten. Reviewers and a separately selected release agent are not quota-routed.

The concurrent-work setting defaults to four routed work items in this orchestration, not four jobs per agent or a cap on every open session. Start conservatively: `max concurrent tasks = floor(RAM budget for tasks / peak RAM per task)`. Reserve memory for other applications and a safety margin, and measure representative work before raising the limit; CPU and disk pressure matter too. This setting does not reserve quota or account for unrelated sessions using the same account.

Optional display failures do not disable manual agent selection. Enabling quota routing is different: unavailable capacity evidence still holds routed work. Account usage deltas include other activity on the account; they are not exact per-worker billing.

### Review and landing

A builder proposes a completed change. Every declared check must pass through SPAWN's helper at the exact submitted revision. When review is required, a different reviewer must approve that revision.

By default, the existing accepted worker performs the merge/release after the required proof and approvals. It must have the actual managed release capability; the default does not grant it. You can instead select a separate eligible release agent. Neither mode permits the reviewer to approve its own work or bypass repository protections.

Different-family review uses the provider family saved in **SPAWN → Advanced agent settings**. Direct providers have known defaults; wrappers and OMP need the correct underlying provider declared. This is configuration, not proof of the model actually running or account isolation.

Each code project has a verified checkout, target ref and landing route:

- **ORCH+ coordinates this target:** one granted slot per shared repository/target across local orchestrations.
- **Use the repository's protected merge queue:** the repository owns serialization; ORCH+ still requires its normal approval and proof.

Changed target heads, conflicting checkout use, overlapping files, failed checks and uncertain merge outcomes remain decisions—not reasons to rerun an issued operation. Turning review off never turns declared checks off. A new revision invalidates earlier check/review proof.

### Worker and coordinator rollover

Automatic rollover uses the runtime's actual context measurements. Its default threshold is 55% of the headroom left after the first turn:

```text
context now >= first-turn context + 0.55 * (context window - first-turn context)
```

You can replace that calculation with one numeric percentage. Existing explicit percentage settings stay explicit; they are not silently converted. Billed tokens, output totals and guessed window sizes are not measurements. Missing, stale or inconsistent measurements show **unknown** and do not trigger automatic rollover.

Workers wait for the next completed checkpoint after reaching the threshold. Orchestrators do not wait for a project checkpoint. Both still require settled, idle controls and the normal handover checks; reaching the threshold is not permission to interrupt an issued operation.

A successor starts with its own context baseline, not the predecessor's counts. The successor accepts the exact handover before an ordinary predecessor can stop. Coordinator rollover is stricter: the predecessor must retire and its exact stop must be observed before the successor starts. Failed or uncertain steps stay held rather than launching more successors.

Agents are also instructed to suggest a fresh session immediately when context appears poisoned, naming the symptom and labelling suspicion as suspicion. Otherwise, workers check at checkpoint ends and orchestrators check at the threshold. Finishing a task alone is not a reason to suggest a new session.

These rules work when the agent reports genuine runtime measurements; ORCH+ does not invent them to enable automatic rollover.

## Update and reconnect

Use **ORCH+ Check for updates**, then the offered update action. The updater checks the actual downloaded package and requirements, requests approval, and retains the outcome. A preview is not proof that a particular commit was installed. Connected remote hosts use the existing Tern connection.

Compatible reloads and updates reconnect ORCH+ to SPAWN automatically when the exact retained controller and agent identities can be verified. Work, pause state, pending decisions and original requests are preserved. No normal **Update/reconnect** button or manual mailbox-startup step is required.

While an agent starts, its row shows progress rather than a success message. Once the pane is known, the row opens it. An interrupted start is checked against its retained outcome without launching another copy. Missing identity or an unresolved issued effect remains a visible hold with a safe action under **Advanced**.

Automatic reconnection does not erase ownership, attest that an old executor stopped, resume paused work or replay an uncertain launch.

After a coordinator really launched but failed before acceptance or activation, **Advanced → Remove failed startup…** can request removal only after that coordinator owner has completed fenced recovery, with no consumption, unresolved operation or restoration. SPAWN first checks the exact original pane through its genuine authorized native window and proves the producer journal unused before retiring the original mailbox and launch reservation. Unknown ORCH+ lifecycle evidence does not mean exit: only SPAWN's fresh exact exit/absence witness permits helper effects. Across a continued window epoch, an existing target is refused as potentially restored; only genuine original-pane absence is accepted. A refused or uncertain retirement stays visible; no stop, acceptance or release is invented, and the original mailbox account/target is not moved. Only confirmed retirement removes the old worker and frees that same record for preparation. This action does not START project work.

Focused regressions: `dispatch/rollover_coordinator_successor_rejected` covers recovered failed-startup retirement and refusal fences; `dispatch/quota_coordinator_rollover` covers a policy-authorized coordinator account switch with distinct successor transport/owner/handover, the predecessor retained and project START still off.

Coordinator rollover fixes the selected successor record in its prepared immutable provisioning draft before retiring the predecessor. This target binding grants neither a successor owner nor an execution slot: both wait for the predecessor's exact stop and mailbox retirement. The quota alternative permissions remain unchanged.


If an update outcome is uncertain, use **ORCH+ Resolve update outcome** rather than repeating the installation. An old installation without the updater needs one manual update:

```sh
tern plugin install --force github.com/blastworksai/tools/plugins/tern/ORCH+
```

Linked development checkouts are not updated by the plugin. Do not delete plugin state to clear a warning or reinitialize only one side of an existing ORCH+/SPAWN pair: retained work and delivery identities must remain consistent.

## Boundaries and limits

- **Managed effects are recorded before execution.** Lost or ambiguous results are read back, not blindly resent. This prevents replay; it is not proof that an uncertain operation succeeded.
- **No terminal scraping or automatic enrollment paste.** Coordination uses structured reports and native APIs. A pane title is a display name, not identity or authorization.
- **Roles are not a sandbox.** Agents retain their configured OS, provider and tool permissions. Same-user processes can affect each other's files; helper results are not tamper-proof against that same user.
- **Repository rules still apply.** ORCH+ coordinates known work but does not discover every unrelated process, install branch protection or lock repositories across separate hosts/data directories.
- **Unknown is not stopped.** A missing pane, timeout or idle conversation does not establish termination. Confirmed pane closure does not prove that every remote child process exited.
- **An attached window drives new effects.** With no attached controlling window, nothing new starts. Background observation uses the existing bounded wake mechanism; it is not a persistent ORCH+ service. A missed nightly mailbox sweep catches up on attachment.
- **Stored work is retained.** Pause stops new work, not settlement. UI grouping or hiding Advanced does not discard pending evidence, reports, decisions or uncertain effects.

See [REFERENCE.md](REFERENCE.md) for protocol limits, ownership and recovery, structured reports, capacity rules and the review/landing state machines. Managed agents follow [worker-brief.md](worker-brief.md); orchestrators additionally follow [coordinator-brief.md](coordinator-brief.md).

## Documentation

Technical documentation, walkthroughs and architecture are in [documentation/README.md](documentation/README.md). Planned future work is in [documentation/backlog.md](documentation/backlog.md). Optional behaviour that exists only in source is not claimed as qualified on every provider or platform.

## Verification

Native regression suites run in Tern's Lua runtime with disposable plugin data. The entrypoint accepts a group or named section:

```lua
local root = "/path/to/ORCH+"
return assert(loadstring(tern.fs.read(root .. "/tests/run.luau")))(root, "dispatch/rejected_read")
```

State-machine tests do not replace the native walkthrough. The shared `report-files-v1/tests/native_smoke.py` harness exercises actual controls and disposable conversations, records screenshots and retained outcomes, and checks that ordinary Tern remains untouched. Provider-backed scenarios require explicit consent and report their scope separately from deterministic terminal fixtures. See the [shared protocol verification guide](../../../shared/report-files-v1/README.md).

## License

MIT. See the repository [LICENSE](../../../LICENSE).
