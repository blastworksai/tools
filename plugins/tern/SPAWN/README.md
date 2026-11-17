# SPAWN for Tern

Set up your available agents, then choose an account to start in [Tern](https://docs.stencil.so/tern/).

SPAWN keeps one saved launch record per provider account: Claude, Codex, Kimi, Muse, Agy/Antigravity, Grok, OMP or a custom command. It starts one selected account and shows the result. Use [ORCH+](../ORCH+/README.md) to coordinate multiple agents; SPAWN no longer has a **Spawn all** action.

The default is **this machine, your current OS account**: no SSH, sudo or extra service is needed. For remote work, use Tern's existing connection and the SPAWN installation on that execution host. ORCH+'s managed connection is pane-free: no parked transport tab, split, deck chip or product daemon. Standalone SPAWN's optional SSH-command records are a separate, advanced launch mode, not the managed remote route.

[USAGE](../USAGE/README.md) and [ORCH+](../ORCH+/README.md) build on SPAWN's roster.

## What it does

- **One record per account.** Provider, account suffix (`Work`, `Personal`, …), command, arguments, working directory and placement. Optionally an OS user, an SSH destination and, for OMP, a startup prompt.
- **Start one agent.** Choose the provider/account you want. Every start uses that account's reviewed settings.
- **As many copies as you want.** Every Spawn starts a new launch with its own pane, even when the same account is already running. Disabled records are skipped.
- **Honest outcomes.** Every launch is reported as `Starting`, `Running`, `Waiting for input`, `Exited` or `Failed`. A closed pane is never counted as a successful exit, and a launch is shown as live only while its pane exists.
- **Output is kept.** Terminal launches run inside an ordinary shell, so a failing command leaves its error and exit status on screen.
- **Native OMP.** Choose **Native agent** for OMP's message API; **Local terminal** uses helper polling instead. Native OMP sessions receive their saved startup prompt once per launch, never again on reload.
- **Tabs you can tell apart.** Tabs are named `ProviderSuffix` (for example `CodexWork`), coloured per provider, and show the provider's icon on local and remote hosts.
- **Guided setup.** Tern's configured default helper discovers installed providers, checks their supported flags and asks clear account/permission questions. It submits a complete roster for review; success is reported only after SPAWN confirms the save. No existing SPAWN account is required. Manual JSON import remains under Advanced.
- **Plain `+` is untouched.** Tern's normal new-tab button keeps working as before. Loading SPAWN never starts anything by itself.

## Requirements

- Tern 0.9.10 or later.
- The provider CLIs you want to run, already installed and signed in on the machine where the agents will run (the *execution host*).
- Native OMP launches need a POSIX shell (`sh`, `bash`, `dash`, `ksh`, `zsh`) on the execution host. Terminal launches also work under PowerShell (`pwsh`/`powershell`).

## Install

Install SPAWN on the Tern host that will run your agents. If you work from a desktop connected to a remote host, also install it on the desktop so its window half (menus, tab icons) loads there.

```sh
tern plugin install github.com/blastworksai/tools/plugins/tern/SPAWN
```

The source installs the default-branch package; a local source directory is also accepted. `tern plugin link /path/to/SPAWN` is for development only. Tern reloads plugins whenever linked files change, so never edit a linked checkout while agents are running.

### Update

Run **SPAWN: Check for updates** from the command palette. When a newer version is on GitHub, **SPAWN: Update** installs it in place: it checks the release's requirements and asks first, and can also update connected remote hosts through the existing Tern connection. Tern then reloads its plugins and retains your settings. Compatible ORCH+/SPAWN reconnection is automatic; unresolved identity or effects remain visible holds rather than repeated launches.

The preview is not a pinned commit. Installation checks the actual package, requirements and load evidence; a different installed version is not the preview's success. If reload or missing process evidence leaves an uncertain result, use **SPAWN: Resolve update outcome**. It never repeats the install, and resolving as unverified does not certify success. A positively running installer cannot be overridden.

A copy installed before the updater existed needs one manual update:

    tern plugin install --force github.com/blastworksai/tools/plugins/tern/SPAWN

A linked development checkout (`tern plugin link`) is never updated by the plugin; `git pull` it yourself.

## Use

Open **SPAWN** from its status-bar segment (sparkle icon) or the command palette. There is no Files-pane button. The first time, SPAWN offers once to add the **Plugin segments** widget to the status bar if it is not placed. Either way it opens a real pane beside the active pane, not a floating menu. An unconfigured installation opens **Setup**; a configured one opens **Start an agent**. Opening either page starts nothing.

1. **Set up agents.** On **Setup**, the **Guided setup** heading already shows its device choices (**Single device** by default, or **Multi device**) and **Find execution machine(s)**, which stays grey and disabled until you choose Multi device. One **Start Guided setup — may use model credits** action follows. Or use **Add agent on current machine** for manual entry. The description identifies the execution host. The desktop and an attached remote host are different machines.
   Guided setup uses the working folder reported by that execution host. A desktop can display remote paths in its own format; SPAWN does not use that display path to launch the helper. If the host folder changes before startup, setup stops without starting a helper.
2. **Approve once, in the helper.** Check the executable, arguments, account routing, folder and permission choices in the helper's own approval. After you submit it, SPAWN saves, prepares and verifies the roster automatically and shows progress, specific failures and the final result in its own pane. There is no review popup and no second click.
3. **Start an agent.** Choose one eligible saved account. Each agent row shows Tern's own icon for its provider (a generic mark for an unknown one), its launch command underneath and a **Spawn** button. Disabled or review-required records show why they cannot start. This one page is SPAWN's own layout (a bold title, one bordered card per agent, Options cards) beside the same page navigation, because Tern's settings rows have no icon slot; every other page keeps the settings layout. Each click creates a separate session; it does not reuse an unrelated running pane.
4. **Watch current agents.** **Current agents** shows current observations and lets you open the corresponding sessions. Failed/exited history, raw identifiers and request repair are under **Advanced**. Missing evidence means unknown, not stopped.
5. **Finished launches clear themselves.** SPAWN observes its panes and moves definitively ended launches to history. This updates SPAWN's own records; it does not stop an agent or close its pane to make the status look successful.

If an interrupted window request has a saved refusal, nothing ran: SPAWN acknowledges it with an info toast and continues with your next request. Other interrupted outcomes require **Running agents → Advanced → Transport review**. Inspect the retained outcome before acknowledging it; acknowledgement does not prove success, cancel an admitted job or authorize replay.

### Guided setup and review

Configure a default helper in Tern settings, then choose **Guided setup**. SPAWN recommends **OMP in ACP mode** for the structured questions; it does not change your Tern default automatically. Other supported configured defaults remain usable. The helper opens to the left of SPAWN. A pending click is consumed once; wait for the displayed result rather than clicking repeatedly.

Guided setup first asks **Single or Multi Device Setup**, then discovers Tern's known devices and asks which is the primary execution machine. The desktop's connection to a remote Tern host is not an extra SSH hop for agents on that host. On the selected execution machine, terminal agents use **Local terminal** and supported native agents keep their native integration. An SSH alias or loopback address alone never proves that a destination is this machine.

Before agent questions, discovery checks accessible execution-host locations for a real Glitch installation and all supported provider executables, including Agy, Muse and OMP. A suggested Glitch folder comes from that observation, not a hardcoded `/opt/glitch`. Multiple or inaccessible candidates are explained rather than guessed. Custom SSH keys and account paths also need actual discovery or explicit input; examples are not machine defaults.

Permission choices include normal provider defaults and an explicit unrestricted option when that installed CLI supports it. You can apply a choice to all accounts, a selected subset or one account at a time, then review the effective settings. For Codex, `--dangerously-bypass-approvals-and-sandbox` disables both safeguards when the installed version supports it. Names such as `--yolo` and `--auto` differ between providers and versions: setup must read their actual help, not infer meaning from the name.

The helper follows `skills/setup/SKILL.md` and submits through its run-bound helper. SPAWN binds the result to that setup run, execution host, session and source pane; it does not scrape terminal output.

The helper's approval is the only approval. It names the exact roster and the checks SPAWN will run: terminal checks are offline; each native OMP account gets one harmless model message that the approval discloses (accounts, model, possible credits). The helper's result carries that scope as `paid_checks` (the exact native agent IDs it disclosed), bound to the run and result like the roster. After the run-bound submission, SPAWN saves the roster, then runs resource preparation, route verification, owned diagnostic cleanup, final save/readback and status refresh automatically. A native account not listed in `paid_checks` is saved but never checked automatically: SPAWN names it, and **Prepare agents for ORCH+** later shows its account, model, permissions and possible credits before you click. Optional provider-backed readiness tests stay separate and never run from this flow. Disabled agents stay unchanged; a roster with nothing enabled, an SSH route or a record needing review is saved without preparation and SPAWN says why.

A save is identical-skipping: identical records are skipped; conflicts refuse the import rather than partly changing the roster. Delivery is not acceptance, and a roster-save receipt is not full setup success. SPAWN reports the actual committed/prepared outcome, naming any incomplete account; it never reports a successful login or real-task readiness from these checks.

Normal pages show readable summaries. **Advanced** holds full-record JSON, diagnostics and exceptional retained-result recovery. A pending retained submission must be resolved or explicitly discarded as the exact submission; changing tabs or typing another run ID does not authorize it.

Guided roster setup, managed setup and optional provider-backed readiness are separate. A saved roster does not prove login, managed capabilities or success of a real task.

### Prepare an agent for ORCH+

Open **SPAWN → Setup → Prepare agents for ORCH+**. It works with an empty roster and needs no existing OMP setup agent. ORCH+'s setup link opens or focuses this same SPAWN page; SPAWN remains the roster and provisioning owner. The optional readiness link returns to ORCH+. Missing ORCH+ or a closed/stale source is a visible refusal, not permission to create another controller.

An enabled ordinary roster record is not necessarily a managed worker. Managed setup prepares the fresh launch/input contract, repository working folder and reviewed mailbox helpers required by ORCH+. Merely loading a catalog does not create resources or establish provider readiness. ORCH+ owns its compact agent picker and loads the available catalog automatically; SPAWN owns the saved configurations and setup, not orchestration projects or conversations.

1. Preparation follows install order. If ORCH+ is already installed when agents are configured, Guided setup prepares them as part of the same flow. If ORCH+ is installed after SPAWN and saved agents still need preparation, Setup offers one **Prepare agents for ORCH+** action for the missing work only, with the account, model, permissions and possible credits of any paid native check shown on the action before you click (terminal-only work is offline). Prepared agents are reused, and when all are prepared SPAWN shows that state instead of a button. Preparation counts only for the launch and account settings it was made for: editing a prepared agent's command, folder, account or route withdraws it, and a saved OS account that differs from the verified worker identity is not treated as prepared. To inspect or re-prepare one account, or create a record, open **Advanced → Inspect or re-prepare agents** and review its account, executable, folder, route and permission settings.
2. Choose **Prepare and save** for that account, or the roster action above. One approval covers resource checks, route verification, owned diagnostic cleanup, saving and refresh. Native routes disclose one real model message per selected native account, preserving its model/profile/authentication and permission flags. Terminal checks use an offline helper. These routes are not sandboxes.
3. SPAWN checks the selected identity, executable, folder, arguments and mailbox access, then publishes exact packaged helpers to stable, digest-specific bundles. When the selected terminal CLI's own help declares `--prompt-interactive`, SPAWN can use it for an otherwise inferred final task slot. Explicit input modes, separators and custom task positions remain unchanged. Ordinary launch arguments and review/disabled state are preserved.
4. Saving follows only successful route observation and confirmed cleanup of its own temporary diagnostic. Observation lasts at most **45 seconds**, normally ending early after positive native identity. Missing/ambiguous identity, changed settings, active or uncertain work, or incomplete cleanup stops the workflow with the actual reason. It does not repeat an issued diagnostic or launch a replacement.
5. Optionally choose **Check provider readiness…** for ORCH+'s separately consented real task/report/check/landing exercise. Required setup does not certify authentication, custom CLI flag meanings or task readiness.

**Advanced** exposes the stable ID, task argument position, mailbox folder, detailed observations and full-record JSON. Choosing another existing POSIX OS user is available on the normal preparation page. For exceptional manual record changes use **Advanced → Configured agents → Full record JSON**, then **Approve reviewed command and settings**. Do not set `mailbox.verified` merely to make a record selectable.

Adopting an existing Native OMP record with `fresh_native_default:true` keeps its fresh contract (`omp` with no arguments) separate from its ordinary resume command and arguments. A native default combined with model/profile selectors remains unsupported: review an explicit fresh executable/argv contract in the full record editor first. Adoption retains explicit execution-host bindings rather than silently retargeting the record.

Managed setup runs on the execution host, not through an SSH hop. For a remote machine, run ORCH+ and SPAWN on that target host with same-host records. On POSIX, leaving the Unix-user field empty uses the current account; an explicit user uses existing noninteractive `sudo -n -u <user> -H --` access, even if the name matches the current account. Before preparation, SPAWN checks the actual selected identity and home, resolves its executable and checks access to the working folder. An implicit cross-user mailbox root uses that verified home at `.local/share/tern-spawn/managed`; explicit saved roots remain unchanged. Probes require the selected account's helper tools and durable mailbox access. SPAWN does not create OS accounts, grant sudo access, copy credentials or repair PATH, authentication, Git trust or permissions.

Saved literal same-host `sudo` commands are reviewed under their embedded OS account, not the host plugin's account. Preparation accepts only `-n`, `-H`, one `-u`/`--user` selector and an optional `--` before the actual worker executable. It normalizes both ordinary and fresh routes to that executable plus the explicit user, adjusts task argument positions past the removed wrapper and avoids double `sudo`. Ordinary resume arguments, provider/permission flags, backend and selectors remain intact. Conflicting explicit users, different ordinary/fresh accounts, nested wrappers and unsupported sudo options refuse before resources or diagnostic consent; fix both contracts in the full-record editor rather than falling back to the current account. Only the exact generated plugin-data `managed` root relocates to the verified account home; a chosen root is checked as that account and never silently replaced. Helpers, producer access, prerequisites and provision readback all use the selected execution account. This prepares a new reviewed transport declaration; it does not change an already issued mailbox identity or transfer an old generation's enrolment token.

Managed launch also checks an explicit or embedded OS account against the prepared mailbox identity. A stale connection prepared for another account must be prepared again; it cannot launch using another user's private helpers.

For native Linux launches under an existing OS account, verification follows the native foreground process to a unique descendant owned by that account. It checks the actual arguments and working folder under the selected identity and rechecks process start identities. A root-owned `sudo` wrapper with an unreadable working folder is not accepted as the agent. This does not widen directory permissions or replace the native pane binding.

An Advanced resource probe alone does not complete setup. The one-action workflow must also finish the approved native model-turn or offline terminal route check and observe cleanup before automatic saving. A no-provider/no-desktop investigation must stop short of those gates, leaving the record unverified.

The diagnostic opens only in the desktop where you click its consent button. Multiple remote desktops can stay connected even when their native window keys are identical. A reload never repeats the model turn; an interrupted diagnostic is reconciled for cleanup only. Execution-host pane IDs and desktop pane IDs are tracked separately.
The execution host verifies the exact diagnostic command and working directory. Desktop path presentation is not identity evidence: for example, Windows may display a remote Linux directory with backslashes. Observation and cleanup still require the unique command, captured session membership and confirmed host/desktop pane binding.

Native OMP setup is POSIX-only. Windows managed local-terminal setup requires an explicit native `.exe` with the Windows CRT argv contract, not a batch/script or command-code substitute; Windows native OMP and cross-user setup are unsupported. PowerShell helper execution must already be allowed by the operator's policy: a policy refusal is a prerequisite failure. SPAWN ships no `RemoteSigned` override and does not claim default-policy Windows support.

A Windows desktop connected to a POSIX Tern execution host uses that host's Native OMP route. This is the supported design, not a claim of completed Windows-desktop/remote-host qualification; systematic native qualification remains incomplete.

On macOS, terminal continuation needs the optional **Python 3 + ctypes + native libproc** capability on the execution host. **Prepare agents for ORCH+ → Check terminal continuation capability** reports whether it is available. SPAWN does not install Python or make it a global dependency. Ordinary launches and Native OMP do not need it; real-device macOS qualification remains separate.

These routes run as the selected OS account, **not in a sandbox**. Labels, profiles and role prompts do not isolate identities or files. Ordinary standalone Guided setup, launch history and the updater flow above are unchanged. Setup observations are not full runtime qualification, completed landing/deployment evidence or desktop-updater acceptance.


### Launch modes

| Mode | Use it for | How it runs |
| --- | --- | --- |
| **Terminal** | Most CLIs | Opens a normal shell pane on the execution host and types the approved command into it once. The shell stays after the command ends. |
| **SSH terminal** | An account on another machine | Runs `ssh` from that shell with the saved destination, user and key path, then the command on the other side. The remote command is quoted for a POSIX shell. |
| **Native OMP** | OMP only | Starts a native Tern OMP session with the saved command, working directory and startup prompt. |

### Record fields

| Field | Meaning |
| --- | --- |
| `id` | Stable identifier (`codex-work`). |
| `provider`, `account_label` | Provider name and account suffix; together they form the tab name. |
| `backend` | `local-terminal`, `ssh-command` or `native-agent` (Terminal, SSH terminal, Native OMP). |
| `command`, `arguments` | The executable and its separate arguments. SPAWN never guesses a command from a label. |
| `cwd` | Working directory (default `~`). |
| `user` | Optional OS user; the command runs through `sudo -n -H -u <user> --` and then that account's passwd login shell (a constant `/bin/sh -c` script; the program and arguments travel as one quoted command run after the profile, in the launch folder), so its `~/.profile` PATH and tokens apply. |
| `host`, `key_path` | SSH destination and optional key file path (never the key itself). |
| `prompt` | OMP startup prompt. Native OMP needs a non-empty prompt. |
| `enabled` | Whether this account can be started. There is no batch-inclusion setting. |
| `placement` | `tab`, `split` or `replace_if_alone`. |
| `provider_family` | Optional explicit underlying AI provider for wrappers, OMP and review policy. Configure it in Advanced agent settings; the display name is not identity proof. |

Advanced manual import example (**Agent settings → Advanced → Setup → Paste setup JSON**):

```json
{
  "schema": 2,
  "agents": [
    {
      "id": "codex-work", "provider": "Codex", "account_label": "Work",
      "backend": "local-terminal", "enabled": true,
      "command": "codex", "arguments": [], "cwd": "~", "placement": "tab"
    }
  ]
}
```

## How it works

Everything runs on the execution host. The desktop window never builds or types a provider command.

1. The window records which host and session you are in and sends a versioned request through the host's Config block.
2. The host checks the request, reserves the account and stores the reply in one atomic write.
3. The window opens a pane carrying a harmless one-time ticket.
4. The host's spawn hook recognises the ticket and keeps the shell. Outside the hook's 50 ms budget, it re-checks the session and then writes the approved command into that shell once.
5. Host events (command started/finished, pane exited) become saved outcomes, which the window displays.

Configuration and launch authority use Tern's host-owned per-plugin key-value store. Window observers and caches use native data files scoped to the actual window key, connection and start time. Reload reuses that incarnation's files; a reused window key gets a separate journal, and unresolved old journals are retained. No extra service or daemon is needed.

ORCH+ paired-control authorization consumes one exact live native challenge. A queued duplicate callback after that consumption cannot execute again or replace the committed reply with a stale-challenge rejection. A restored bridge remains a read-only reconciliation view; saved block state never grants execution authority.

On POSIX hosts each launch line starts with `SPAWN_PROVIDER=<provider>`, which is how Tern's built-in provider icons reach remote tabs.

### Storage limits and cleanup

The host-owned launch state has a 120,000-byte ceiling (about 1.6 KB per launch). SPAWN keeps itself under it automatically:

- Config forgets a settled, unchanged session only after two complete inspections of every native window agree it is absent. Another live window's empty or finished history is retained. Missing, partial, changing or unqualified client views hold cleanup; active launches and managed obligations always keep their sessions. Scopes created or changed during inspection are never added to its deletion set.
- Each session keeps only its 26 most recent finished launches. Running launches are never trimmed.

**Clear history** under **Advanced** on the Running agents page removes finished entries by hand.

## Security

- SPAWN stores no secrets: no passwords, tokens or key contents. Sign in through each provider's own login flow.
- Commands are split into an executable plus arguments and quoted for the target shell. They are never evaluated as free-form scripts. Lines containing terminal control characters are refused.
- Account labels are not isolation. If accounts must not see each other's files, give each its own OS user or machine; SPAWN does not create users or profiles.
- Any window in the same Tern session can ask the host to launch saved records. It cannot change what a record runs without going through Config's revision checks.

## Known limitations

- Custom colour artwork for Kimi, Muse, Agy and Grok appears only on local panes. Remote tabs show Tern's built-in provider icons, because remote pane IDs cannot yet be matched to tab elements ([tern-sdk#221](https://github.com/stencil-hq/tern-sdk/issues/221)).
- A provider tab shows its icon while the provider is running; after it exits, the tab shows the shell icon again.
- Native OMP needs a non-empty startup prompt; Tern's start API rejects blank ones ([tern-sdk#213](https://github.com/stencil-hq/tern-sdk/issues/213)).
- Host restarts are recognised only on hosts whose daemon identity can be read (Linux). On other hosts the restart epoch is unverifiable, so only the pane rule applies: a launch settles when its pane is gone.
- `Running` means the process is alive. It does not prove the provider is signed in or its model is ready.

## Managed dispatch bridge (for ORCH+)

SPAWN also provides `spawn.dispatch`, the internal bridge [ORCH+](../ORCH+/README.md) uses to launch, wake, stop and retire managed workers from SPAWN's roster. ORCH+ establishes its native paired connection automatically without a parked transport pane. Ordinary SPAWN use never needs to open or trigger this bridge, and it changes nothing about normal launches.

- **Fresh managed launch.** The host builds an immutable fresh command for the saved setup; the exact authorised ORCH+ window starts it through native `agents:start` (OMP) or terminal layout APIs. Managed panes carry no ordinary ticket. Use **Managed local setup** to prepare and verify the route; complete-record editing remains an Advanced option.
- **Explicit authorisation.** Each mutation is staged `pending`, then authorised by a one-shot, time-bound nonce checked against the live ORCH+ owner and window. A public request alone never causes an effect, and uncertain effects are never retried.
- **Report-files mailboxes.** Workers report through bounded, opaque mailbox handles served by reviewed helpers (`mailbox_target.*`, `mailbox_worker.*`); no bridge operation accepts paths, commands or credentials.
- **Helper-run checks and checkout facts.** ORCH+ can provision a mailbox with an authenticated assignment manifest (declared checks, files, scope and base ref), bound into the mailbox's provision digest. On a record that declares `check-runner-v1`, the worker helper's `checkout` mode reports the git worktree, head and changed files, and `run-checks` runs one declared check's exact argv from that manifest, without a shell, reporting its exit code and output digest. Workers cannot publish these reports themselves; the execution target needs `git`. `release-manager-v1` marks a record whose workers may receive ORCH+ landing and deploy grants and report deploy results.
- **Recovery.** Compatible paired reconnection happens automatically. Exceptional managed bindings, retained outcomes and **Fence managed controller for recovery** stay under **Advanced**. Unknown effects remain held: reconnection never authorizes replay.
- **Legacy catalog inspection.** Older saved catalogs may encode empty `capabilities` or `unsupported` lists as objects. Inspection normalizes only those known empty lists in a detached copy; it does not rewrite saved responses or worker history. Missing fields, nonempty maps and unknown capability values remain migration holds.
- **No policy or accounts.** SPAWN does not collect credentials, quotas or account inventory and does not enforce model policy; USAGE collects evidence and ORCH+ owns policy.

The full protocol, request and result fields, mailbox limits, retention, rollback and recovery rules, and runtime evidence required before enabling a managed capability are in [BRIDGE.md](BRIDGE.md).

## Tests

The ordinary launch scenarios run inside Tern's Lua runtime with `tern shot`:

```sh
env SPAWN_PACKAGE_DIR="/path/to/SPAWN" tern shot /path/to/SPAWN/tests/behavior.txt --out /tmp/spawn-behavior
env SPAWN_PACKAGE_DIR="/path/to/SPAWN" tern shot /path/to/SPAWN/tests/authority.txt --out /tmp/spawn-authority
```

Both exit 0 when every scenario prints its `PASS` line.

The Guided setup groups (`setup_review`, `guided_setup`) also fit `tern shot`, because `guided_setup` yields between phases to stay inside the 50 ms window-half slice:

```sh
env SPAWN_PACKAGE_DIR="/path/to/SPAWN" tern shot /path/to/SPAWN/tests/guided_setup.txt --out /tmp/spawn-guided
```

All Luau groups run through the native runner `tests/run.luau`:

```lua
return assert(loadstring(tern.fs.read(root .. "/tests/run.luau")))(root,
  "behavior,authority,backend,dispatch,window_dispatch,mailbox,host_editor,retirement_adapter,setup_review,guided_setup")
```

Mailbox helper regressions run outside Tern: `python3 tests/mailbox_posix.py` on POSIX and `powershell -NoProfile -File tests/mailbox_helpers.ps1` on Windows. Group sections and coverage are listed in [BRIDGE.md](BRIDGE.md#verification-entrypoints).

## Files

- `plugin.toml`: package, Config block and `spawn.dispatch` block declaration
- `provider_icons.luau`: the one provider-to-icon map, used by the window (tab icons) and the host (Start an agent rows)
- `window.luau`: menus, status-bar launcher, request transport, pane allocation, outcome display, tab names, colours and icons
- `host.luau`: Config, setup and Running agents block on the execution host
- `authority.luau`: saved configuration, reservations and request handling (the only writer of SPAWN's state)
- `host_executor.luau`: tickets, shell detection, command rendering and submission, outcome observation
- `launch_state.luau`: launch phases, automatic settlement and history trimming
- `launch_resolution.luau`: shared record validation, ordinary/fresh argv selection, OS-user and SSH identity resolution
- `config.luau`: record validation, migration and the guided-setup prompt
- `native_cli.luau`: bounded calls to Tern's own CLI; pure executable discovery comes from `updater/discovery.luau`
- `backend.luau`: managed fresh-launch construction and serializers
- `bridge_protocol.luau`: `spawn.dispatch` framing and parsing
- `wire/codec.luau`: strict report-files-v1 byte contract, vendored from `shared/report-files-v1`
- `dispatch.luau`: host-side managed dispatcher
- `dispatch_window.luau`: window-side managed executor
- `dispatch.css`: bridge view styling (hides machine nodes)
- `mailbox.luau`, `mailbox_adapter.luau`, `mailbox_capabilities.luau`: mailbox planning, fixed helper protocol and configured mailbox contract
- `mailbox_target.sh`, `mailbox_target.ps1`, `mailbox_worker.sh`, `mailbox_worker.ps1`, `mailbox_json.awk`, `mailbox_reply.jq`: reviewed POSIX and Windows mailbox helpers
- `capability.json`: package capability descriptor
- `CHANGELOG.md`: release notes
- `tern.d.luau`: Tern type definitions for luau-lsp
- `BRIDGE.md`: managed dispatch bridge reference
- `assets/icons/`: provider artwork from [lobe-icons](https://github.com/lobehub/lobe-icons) (MIT, see `assets/icons/LICENSE.lobe-icons.txt`)
- `assets/screenshots/`: historical captures; these may not match the current interface
- `tests/`: `run.luau` runner, `behavior.txt`/`authority.txt` shot scenarios, Luau suites (`behavior`, `authority`, `backend`, `dispatch`, `window_dispatch`, `mailbox`, `host_editor`, `retirement_adapter`, `setup_review`, `guided_setup`) and mailbox helper regressions (`mailbox_posix.py`, `mailbox_helpers.ps1`)

## License

MIT. See the repository [LICENSE](../../../LICENSE). Provider artwork is © LobeHub under its own MIT licence.
