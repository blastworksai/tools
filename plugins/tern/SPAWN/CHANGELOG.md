# Changelog

## 0.6.9

- **Guided setup asks one exact, fixed set of questions.** The helper used to improvise its questions: one list titled "Claude (anthropic)" held every provider's accounts, and "Glitch installation not detected" meant it had never looked. SPAWN now ships `structuredquestions.sh` (and `structuredquestions.ps1` for Windows) beside the setup skill. The helper runs it once. It is read-only: it finds every provider CLI as each candidate account (`sudo -n -i -u <account>`), reads each OMP account's own service from its config, checks permission flags against the installed `--help`, and prints the prompts already filled in: Accounts (one list per provider), IDs and labels, Folder, Permissions (one question per provider, Normal preselected), the OMP service per OMP account, and the final Save. The helper shows them word for word in its own question tool. It never asks for a model or a startup prompt (OMP records get the fixed default prompt).
- The script splits prompts to the stricter of Claude Code's AskUserQuestion (1-4 questions per prompt, 2-4 options per question) and OMP's ask tool, for example "Agy: which accounts should SPAWN run? (1 of 2)" when five accounts would not fit one list.
- The setup skill shrank by about 2 KB (it is stored in durable authority metadata at its byte budget), and the run context SPAWN appends now names the script's path.
- **Glitch is searched in more places.** Besides the launch folder's and the plugin's parent folders, setup now checks the Glitch root WORK saved on that host, `/opt/glitch` and `~/Glitch` (`%USERPROFILE%\Glitch` on Windows), each verified the same way (SKILLS-210).

## 0.6.8

- **Guided setup resolves each agent's CLI as the account that runs it.** On a host with several OS accounts, the setup helper looked up `grok` as the operator and wrote the operator's `/home/<operator>/.local/bin/grok` into another account's record; that account cannot run the file, and preparation stopped at that record. The setup skill now resolves every cross-account CLI through the same login route SPAWN launches with (`sudo -n -i -u <account> -- sh -c 'command -v <cli>'`), checks that the account can execute it, shows an account without the CLI as unavailable instead of borrowing another account's file, and proposes the account, provider and CLI table itself, so the operator approves it without typing paths.
- Preparation checks (account, home, executable, helper tools) now run on that same `sudo -i` login route instead of a bare `sudo -n -u … -H`, so a tool found at discovery on the account's login PATH is the one preparation finds.
- The helper writes such a record in the shape SPAWN stores after preparation: the account in `user` and that account's own executable in `command`, with no `sudo` wrapper (SKILLS-209).

## 0.6.7

- **Forget protocol `spawn-work-v1`.** SPAWN now answers the Forget exchange used by ORCH+: a capability check, a read-only preview of what would be discarded, and the discard itself. The discard is protected by a durable fence, a reservation cleanup journal, and accounting for helper child processes, so a repeated or interrupted discard is safe (SKILLS-205).
- Agents run as another OS account now start through a real `sudo -i` login, so they get that account's own PATH, including `/usr/local/bin` and `uv`. The program, its arguments and the folder cross to the other account as encoded data, so nothing in them is interpreted by a shell on the way. A launch with an empty folder is refused (SKILLS-208).

## 0.6.6

- **A helper result that SPAWN refuses is no longer silent.** Guided setup could finish with 0 agents saved and no message. Cause 1: the helper (OMP) moved itself out of its launch folder after SPAWN bound it, and SPAWN refused the result because the pane's folder no longer equalled the launch folder; the pane is now identified by its id, session, command and window incarnation only. Cause 2: the helper wrote the OMP startup prompt as `startup_prompt` instead of `prompt`; that refusal is legitimate, now names the field, and the setup skill names `prompt` exactly. Every refusal is also published to the window, so Recover setup result shows "SPAWN refused the helper's result: ..." instead of "No complete explicit submission is available".
- The OMP helper stays in the folder SPAWN started it in. OMP silently switches to a temp folder when started in a home folder; SPAWN now adds `--allow-home` for an OMP helper only when the chosen folder is a home folder.
- Agents run as another OS account now enter that account's login shell, so its `~/.profile` PATH (`~/.local/bin`) and exported login tokens apply. The shell is read from the account's passwd entry (never from the environment), the approved program and arguments travel as one fully single-quoted command run after the profile, and the launch folder is restored after it, so a profile cannot move the agent or change its argv. `-n` is kept (no password prompt). This covers literal `sudo -n -H -u <account> -- <program>` records that carry no separate user field. `sudo -i` is not used because it leaves `$` unescaped. Its lookups run with a fixed PATH, a program name starting with `-` is refused, and the account's profile still builds the real PATH. An explicit `sudo -i`/`-s`, a shell target, an unknown shell or a missing passwd tool is run through plain `/bin/sh` or as before. If your sudoers rules allow only specific programs, they must also allow `/bin/sh`.
- A refusal shown on Setup is bound to its own authority, setup run and submission binding; another run never displays it.

## 0.6.5

- **Guided setup is one flow with one approval.** On Setup, **Guided setup** is now a heading with helper text, not a button. Its device choices (**Single device** by default, or **Multi device**) and **Find execution machine(s)** are shown by default and indented beneath it; discovery is grey and disabled while Single device is selected. Exactly one action follows, **Start Guided setup — may use model credits**, and Single device needs no discovery step.
- After the helper submits its run-bound result, SPAWN saves, prepares and verifies the agents automatically and shows progress, specific failures and the final result in its own pane. The floating "Review the complete submitted configuration" picker, **Save and prepare these agents** and **Save settings only** are gone. The exact run/result binding, digest fences, once-only effects and unresolved-outcome handling are unchanged, and only what the helper's approval disclosed runs: optional provider-backed readiness tests stay separate and are never started by this flow.
- Preparation follows install order. When ORCH+ is installed after SPAWN and saved agents still need preparation, Setup offers one **Prepare agents for ORCH+** action for the missing work only (valid preparation is reused); when all agents are prepared it shows that state with no button. Per-agent inspection and re-preparation moved under **Advanced**.
- The helper's result may carry `paid_checks`, the native agent IDs whose paid model check it disclosed; only those are prepared automatically, others are saved and named as not checked. **Prepare agents for ORCH+** shows account, model, permissions and credits before the click, and a prepared agent whose launch or account settings change is no longer counted as prepared.
- The authority validates a preparation manifest against the retained result's own scope (terminal accounts plus `paid_checks`), so an undisclosed native account is saved with the roster and never prepared; a broader or narrower manifest is refused. Preparation is withdrawn when any launch-relevant field of a prepared agent changes, including fresh executable/arguments and task position.
- The "Submitted setup result ready for review" lead is replaced by a short "received" lead that clears once setup completes.

## 0.6.4

- The **Start an agent** title is plain bold text instead of a Markdown heading, which some Tern builds (seen on Windows) drew as the raw "# Start an agent".

## 0.6.3

- The status-bar prompt never re-grants a released question: a released token is recorded in its own file a stale settings write cannot undo, and a release written after the host stopped polling is still honoured (SKILLS-185).

## 0.6.2

- **Start an agent** shows Tern's own provider icon on every agent row, the way USAGE does. The page is now SPAWN's own layout beside the same page navigation, because Tern 0.9.22 settings rows have no icon slot: a heading, the lead, one bordered card per agent (icon and bold "provider — label", the command line underneath, **Spawn** at the right), Refresh and Advanced cards under Options, and Close at the top right. A disabled or review-gated agent shows its reason next to its name. Spawn clicks send the same `launch:<id>` action as before. An unknown provider shows a generic mark. Every other page stays on the settings layout.
- One provider-to-icon map (`provider_icons.luau`) now serves both halves. The old CSS dots and artwork on the Start an agent rows are removed; tab artwork and `tern.chrome.program_icon` registration are unchanged.

## 0.6.1

- The status-bar prompt follows Tern 0.9.22's widget bar: it offers to place the **Plugin segments** widget (preference `widgets`, id `status`) instead of reading the retired `status_bar` preference, which raised "Unknown preference" and marked the prompt as asked. Installs that hit that error are asked once more.

## 0.6.0

- Fix mailbox retirement after a `checkout` without a manifest `base_ref`: the `checkout-base` pin is now a recognised file in producer, withdrawn-tail and target retirement (POSIX and Windows), and is removed with the mailbox instead of blocking it and its reservation.
- A `run-checks` result is refused (`git_unavailable: HEAD changed while the check ran`) when HEAD moves during the check, so a result never names a commit that was not checked.
- Inspect a current source whose worker or retained request carries persisted `terminal_process` proof as valid instead of `state_corrupt`.
- The status-bar prompt keeps a marker file beside `kv.json`, so a flag lost to a whole-store kv write and a host restart no longer asks twice.
- Fix a Windows (or any remote) window attached to a Linux host: SPAWN's host half no longer runs `tern inspect --window <client key>` on its own daemon, where a remote client's window key (for example the client's second window, `2`) does not exist ("Host session inspection unavailable or over limit"). For a remote execution host the host finds its own window for the Config pane from the windows its daemon lists; the client key stays a routing hint. Single-machine behaviour (key `""` or equal keys) is unchanged. Regression: `tests/remote_window_key.luau`. The same translation covers Guided setup (the host resolves its own window key for the client lookup and the `tern send --window` helper) and the managed diagnostic's native process inspection; the client key stays the echo value between the two halves.
- Remove the Files-pane button. The status-bar segment (sparkle) and the command palette remain; the plugin offers once to enable the status bar when it is off.
- Load setup-only window modules when needed rather than during native window initialization, retaining Tern's unchanged load and callback budgets.
- Accept Tern's `agent` presentation kind for real terminal-agent continuation, clipboard enrollment and authorized pane stop while preserving backend, binding, exit and retained process-identity checks.
- Revoke never-consumed old-window authorizations in the same durable commit as a newly admitted controller continuation. Preserve earlier outcomes and consumed authorizations instead of leaving unissued reads permanently pending.
- Keep managed terminal spawn capture in memory only; process-identity verification starts after actual acceptance, outside the native spawn-filter budget.
- Bind literal same-host sudo routes and agent-side helpers to the actual execution account; reject stale launch/mailbox account mismatches without exposing private plugin directories.
- Verify native Linux sudo launches through a unique selected-account descendant of the exact native process epoch, retaining the actual argument and working-folder checks.
- Retire a recovered, never-accepted failed startup only after a fresh native-window exit/absence witness and an unused producer journal; retain all uncertain or consumed generations.
- Ask single/multi-device topology before discovering devices and selecting the primary execution machine. Keep same-host terminals local and native integrations native; never infer SSH identity from a loopback hostname.
- Combine reviewed roster save and preparation, or prepare existing saved agents with one action. Bind the exact roster, revisions, per-record consent and clicking native recipient through resource checks, diagnostics, owned cleanup, save/readback and refresh.
- Publish the setup offer before opening its native approval link, and tolerate delayed surface publication only within the original clicked window's unchanged approval deadline. Refresh each entry against that same recipient before launch; preparation time and the actual diagnostic lifetime remain separate, and repeated or expired links cannot replay consent.
- Prevent preparation/launch races across ordinary, managed and uncertain work; preserve legacy unresolved obligations and reject disabled/review-gated records before diagnostic cost.
- Detect a declared interactive task-input flag from the selected terminal CLI's actual help. Preserve explicit argument contracts, ordinary launch arguments, disabled/review state and predecessor evidence.
- Serialize safe same-lane relay overlaps in their original carrier and drain retained callback output without repeating domain handling. Exact current observation callbacks can settle a `callback_pending` ordering advisory; genuine input/native-result holds and native-effect fences remain enforced.
- Prepare `coordinator-control-v1` for supported local-terminal agents as well as native agents. Terminal coordinators use the existing bounded helper wait/poll and typed activation route; capability metadata alone never activates a coordinator.
- Discover native setup routes from Tern's actual configured/observed commands and expose existing POSIX OS-user selection without guessing identity from provider/account labels. Preserve saved IDs and unrelated accounts during adoption.
- Verify the selected account, home, executable and working folder through existing noninteractive sudo access before preparing helpers. Use the verified selected home for implicit cross-user resources; keep explicit roots, permissions and credentials unchanged.
- When explicitly converting an existing SSH agent to a same-host managed route, drop the obsolete SSH destination and key while preserving its ID, account, arguments and unrelated settings. Retain native/local host bindings and the canonical-host eligibility check.
- Refuse restore/resume/continue/session-reuse arguments before preparing or launching a fresh managed native route. Remove provider-display-label restrictions without claiming arbitrary native/ACP compatibility.
- Open SPAWN's real side-by-side menu directly: Setup when unconfigured, Start an agent when configured. Put Guided setup first and keep diagnostics/history under Advanced.
- Retire Spawn all and its inclusion settings; keep explicit single-agent starts and ORCH+ multi-agent orchestration.
- Discover Glitch installations and every supported provider before guided questions. Check actual CLI help, support batch/subset/per-account permission choices, and report success only after a run-bound durable save receipt.
- Own canonical underlying `provider_family` declarations in Advanced agent settings, including admitted migration of existing declarations for ORCH+ review policy.
- Add exact post-ACCEPTED terminal process identity and read-only continuation checks. macOS uses an optional detected Python 3/ctypes/libproc capability, not a silently installed global dependency or a claim of real-device qualification.
- Add bounded read-only mailbox inventory and exact allocation observation. Keep positive absence/retained allocation distinct from uncertainty; only the existing guarded retirement path may reclaim a definitively rejected provision.
- Preserve original v1 managed state before migration writes; reuse and read back the exact original backup rather than leaving a redundant partial roster backup on refusal.
- Fix Guided setup and other queued SPAWN clicks from a desktop connected to a remote Tern host. Verify the source session on the execution host without comparing that host's SSH connection to the desktop's native window journal. Persist one desktop recipient before startup; another window cannot replace or acknowledge it, and incomplete or wrong-scope inspection still refuses the click.
- Give managed conversations the exact POSIX and Windows arguments for claiming and resolving a received control message, including the correct message identifier. Agents no longer need to inspect helper source to discover the command syntax.
- Publish a bounded, source-bound retirement receipt for a positively expired or superseded private control challenge, so it cannot permanently block later catalog reads and managed conversations. Retain the exact proof through backpressure and acknowledgement failure; never retire native effects or infer revocation from a disappearing source.
- Keep consecutive catalog reads on their original source lane while a completed read's exact callback acknowledgement drains. Publish native observation challenges only after the staging input settles; retain the existing immutable response/source-consumption order and all pending native-effect fences.
- Direct managed-diagnostic consent to the clicking desktop instead of choosing a remote connection by its window key. Bind the desktop incarnation and one-shot consent, retain separate host/desktop pane identities, and prevent replay after reload while preserving cleanup-only recovery.
- Use execution-host command/cwd evidence for managed diagnostic ownership instead of comparing desktop-formatted paths. Windows presentation of remote POSIX directories no longer blocks observation or cleanup; an unconfirmed host/desktop pane binding still prevents cleanup.
- Direct paired-migration inspection and confirmation to the clicking desktop. Keep execution-host session membership separate from desktop SDK IDs; bind the exact desktop namespace/incarnation and one-shot consent so remote windows sharing an empty key cannot claim each other's migration.
- Accept validated pre-setup catalog history during paired migration without publishing invented setup metadata. Validate the detached inspection body independently of new-protocol framing overhead while retaining the original stored-response bound and current wire limits; preserve original source hashes and active worker evidence. Accept namespace-free ORCH schema-v2 proofs only within the existing legacy paired-migration contract.
- Upgrade legacy windows that were indexed before their first journal save using the legacy empty-journal contract. Preserve existing journals and exclusion caches; missing published native journals still fail rather than reset.
- Use Tern's effective configured default agent for provider-neutral Guided setup, including an empty roster. Missing or blank defaults stop with an explicit settings instruction; no OMP record, provider fallback or account creation is required.
- Submit complete setup results through the captured run/host/session helper instead of scraping conversations. Preserve fresh source/configuration checks and explicit review/import confirmation; imports never launch records, and conflicting records refuse atomically.
- Keep machine-channel JSON non-rendering on normal pages and expose raw diagnostics/manual schema-2 import through Advanced. Recover retained results after source closure with fresh original-host/session confirmation and an immutable pending-result reference, avoiding duplicate maximum-size payloads in durable requests.
- Use incarnation-owned updater journals and host-only legacy migration instead of window-written host KV. Retain ambiguous installs through reload and expose **SPAWN: Resolve update outcome** without replay; check actual package requirements and native load evidence separately. Normal installation uses the repository-subfolder source, while linked development packages remain protected.
- Preserve other live windows' saved session authority and ordinary history. Automatic cleanup now requires two complete, stable native-window scans and unchanged pre-inspection scope evidence; incomplete views, incarnation changes and current managed obligations retain history.
- Refresh every live dispatch view after a successful store commit. After ORCH independently confirms session closure, discard the matching rendered response and saved view cursor only under current peer-closure proof; preserve unknown sources, other-scope challenges and durable execution obligations.
- Keep restored dispatch views read-only until a fresh native-verified request arrives. Do not advertise an executable control that the restored-view guard will refuse; retained-status inspection restores only the current projection, without replaying a saved request or bypassing the peer nonce fence.
- Keep window observers and caches in separate native-incarnation journals rather than shared window KV. Reload retains the same journal; a reused native key gets a different journal, preserves unresolved old history and cannot replay the old window's launch.
- Inspect legacy catalogs with empty capability/unsupported lists without a false persisted-evidence hold. Normalize only the detached inspection copy; preserve saved source bytes and active worker history, and continue refusing missing fields, nonempty maps and unknown capabilities.
- Share the strict report-files-v1 codec with ORCH+. Read only the requested mailbox object; retain complete validation before publishing a reply manifest.
- Use native Base64 encoding and shared executable discovery while preserving distinct managed/ordinary PowerShell wrappers, UTF-16LE conversion and ordinary SSH argument handling.
- Reject malformed Base64 and raw-NUL reply bytes before consumption. Drain Darwin `iconv` output while checking its status, so valid large UTF-8 replies are accepted and invalid bytes remain rejected.
- Preserve ordinary/unmanaged automatic launch settlement and bounded Failed/Exited history.
- Add the native **Managed local setup** owner page, standalone or linked from ORCH+, with explicit new-record creation/adoption, actual-account prerequisites and digest-specific stable helper bundles outside the installed package; preserve existing records and helper paths.
- Separate required setup, exact native-route proof, configured-CLI operator attestation and optional provider-backed readiness. Disclose the small real OMP diagnostic turn; bound the offline terminal helper observation to 45 seconds and retain unresolved identity/cleanup obligations rather than retrying from output.
- Support `review_disabled` landing proof without synthetic review IDs; retain mandatory declared-check references and passing current-revision checks in every review mode. `helper_checks` still requires review.
- Keep POSIX native OMP and Windows native `.exe`/CRT limits explicit. Refuse unmet PowerShell execution-policy prerequisites without a policy override; setup does not sandbox accounts or certify full task/landing, deployment or desktop-updater acceptance.
- Clarify native-agent continuation after ACCEPTED: ordinary workers resume only their original assignment; only explicit coordinator transport roles await activation. Review, landing and deployment retain their typed authorization gates.
- Preserve a live managed authorization challenge when a same-target status read replaces the bridge view. Authorize only the exact current execution projection; retain nonce, incarnation, recipient, deadline and peer-proof fences so duplicate submissions cannot repeat an effect.
- Preserve the requested Runtime or Managed page through native owner-context verification, so ORCH+ recovery opens the actual Runtime controls without bypassing SPAWN's independent fence and confirmation.

## 0.5.0

Requires Tern 0.9.10 (now declared in `requires.json`).

### Added

- Self-updater: **SPAWN: Check for updates** reports whether a newer SPAWN is on GitHub (a background check runs at most every 6 hours), and **SPAWN: Update** checks the release's `requires.json`, asks first, optionally updates connected remote hosts, then reinstalls with `tern plugin install --force`. Linked development checkouts are never updated. Copies installed before 0.5.0 need one manual `tern plugin install --force github.com/blastworksai/tools/plugins/tern/SPAWN`.
- Config has a **Spawn agents** page: one **Spawn all** button and one button per saved record with its provider logo, `Provider — Suffix` and its command, arguments and working directory. Disabled records and records needing review are greyed with the reason.
- Automatic settlement: the host checks its panes on load, every 15 seconds and after each observation, and moves ordinary launches to history by itself: `Exited` "Pane closed", `Failed` "Never started (ticket not claimed)" after 30 seconds, `Exited` "Host restarted" 20 seconds after a host restart. Agents Tern reruns in their pane within those 20 seconds are re-adopted as `Running`. On non-Linux hosts the restart epoch is unverifiable, so only the pane rule applies. Managed (ORCH+) launches are unchanged.

### Changed

- One record can run any number of copies: every Spawn starts a new launch. Only disabled records are skipped.
- The SPAWN menu is **Guided setup** (only until the first record is saved), **Config**, **Spawn all** and **Spawn specific**. **Running agents** and **Review setup result** left the menu; the `SPAWN: Running agents` and `SPAWN: Guided setup` palette commands stay, and **Review setup result** moved to Config › Setup while a setup run is active.
- The host-restart notice is one informational line, "Host restarted: N SPAWN agents ended (cleared automatically)", with no action.
- When a batch finishes, SPAWN closes the Config view it opened for that batch instead of hiding it, so no idle SPAWN block is left behind. A Config you opened, or are looking at, stays.
- Reset transport now waits only for live or managed attempts.

### Removed

- The `duplicate_policy` record field and the `skip`/`allow` duplicate choice.
- **Mark no longer running** and **Mark all N lost agents no longer running**, with the `resolve_attempt` and `resolve_lost_attempts` operations and the `Unknown` blocking state for ordinary launches.

### Fixed

- The Config › Setup **Guided setup** row raised an error; it now starts Guided setup.

### Upgrade notes

- Saved records, Paste JSON imports, setup results and managed imports that still carry `duplicate_policy` have it stripped on restore or import, never rejected.
- A retained or journalled old Mark request is cleared automatically ("An old Mark-no-longer-running request was cleared; SPAWN now does this automatically") and never replayed.
- Leftover parked SPAWN Config blocks from older versions are closed when the window loads, unless one still has a pending request.
- Launches left `Unknown` by an older version settle on the host's first check.

## 0.4.0

For ORCH+ 0.4.0. The mailbox helpers changed: reinstall `mailbox_target.*`, `mailbox_worker.*`, `mailbox_json.awk` and `mailbox_reply.jq` on each execution target. Ordinary SPAWN launches are unchanged.

Includes all 0.3.1 fixes (SPAWN 0.3.1 had no changelog of its own; its entries are the `SPAWN:` items under ORCH+ 0.3.1): a short focus guard keeps managed launches from taking focus; a pending request the host already refused is acknowledged automatically; attempts lost to a daemon restart are recognised and can be released together with **Mark all N lost agents no longer running** (`resolve_lost_attempts`); **Spawn all** waits 5 seconds between launches; unused-mailbox retirement accepts a launch whose window challenge expired unconsumed.

### Changed (breaking)

- Managed records may declare up to seven mailbox capabilities (was five): `check-runner-v1` and `release-manager-v1` are new. Config, the codec and both helpers accept the same set.
- REVIEW_RESULT is now `{review_id, round, artifact_revision, outcome, findings, summary?}`, with findings tied to file and line, instead of `evidence`. Coordinators no longer send it; ORCH+ reviewer workers do.
- `landing_grant` and `deploy_grant` replies need `release-manager-v1` in the provisioned capability set; the helpers refuse them otherwise (`capability_missing`).

### Added

- Assignment manifest: `mailbox_provision` accepts optional `manifest` bytes (declared checks, files, scope and base ref; at most 4,096 bytes). Its digest joins the provision binding digest and `provision.json`, and the target helper writes the bytes as `manifest.json`. Provisions without a manifest keep their 0.3.0 digest and descriptor.
- Helper mode `checkout` (POSIX and Windows) publishes CHECKOUT from git: worktree, common dir, branch, head, merge base, changed files (committed, staged, unstaged and untracked; at most 512) and a dirty flag. Without a manifest `base_ref`, the first `checkout` pins the launch HEAD in `<mailbox>/checkout-base`, so later checkouts report committed (including out-of-scope) files instead of only uncommitted ones; a tampered pin is refused `storage_error`.
- Helper mode `run-checks <check_id>` (Windows: `-Mode: run-checks -CheckId: <check_id>`) runs one declared check's exact argv from the authenticated manifest without a shell and publishes CHECK_RESULT with its argv digest, exit code, output digest and head.
- CHECK_RESULT and CHECKOUT are helper-only: publishing them through `report` is refused `helper_only_kind`. Refusals `capability_missing`, `manifest_missing`, `manifest_mismatch`, `check_undeclared` and `git_unavailable` are definite and publish nothing.
- New report kinds LABEL and DEPLOY_RESULT (the latter needs `release-manager-v1`); new reply kinds `review_request`, `rework`, `deploy_grant` and `label_request`; DONE may carry `output_ref`.
- The helper JSON validator accepts arrays of up to 512 entries (was 256), for CHECKOUT's changed-file list.

### Fixed

- POSIX `wait` no longer leaves `producer/lock` behind with no running helper, which refused every later call `producer_locked`. A later poll or an interrupted wait now waits up to 10 seconds for a capacity gate held by a target commit; if the gate stays busy, the helper leaves it untouched and still removes its own empty workspace and producer lock. A helper killed without cleanup still needs explicit stopped-producer recovery (see BRIDGE.md). The PowerShell helper's lock already ended with its process; its `wait` polls and post-retirement lock-file removal now wait out a busy gate the same way instead of failing `capacity_locked`.
