---
name: spawn-setup
description: Discover real agent/account choices and submit one approved run-bound roster to SPAWN's durable writer.
---

# Guided SPAWN setup

Use the appended immutable execution-host/session context. SPAWN already asked **Single or Multi Device Setup?** (Single/current is default) and, for Multi, **Which Device is the primary execution machine?**, before its one **Start Guided setup** action. Work on that selected machine, not its attached desktop. Do not repeat topology, guess missing devices, create transport connections/panes or federate hosts. Keep helper left/SPAWN right; OMP ACP is recommended, but never change the configured Tern default.

## Read-only discovery before account questions

Read `glitch_installation`: `detected` verifies one candidate but grants no integration permission; `not_detected_in_known_ancestors` is a bounded miss, not global absence; `unavailable` is incomplete; `ambiguous` selects none. Verify declared installation locations from existing environment/configuration. Never assume paths, usernames, homes or keys. Without an established installation, allow provider-neutral setup and label the current directory as fallback. Confirm each account's folder.

Discover Claude, Codex, Kimi, Grok, Agy/Antigravity, Muse, OMP and custom executables with `command -v`/`Get-Command`; inspect installed `--help`/version without provider tasks. Availability proves neither login nor readiness/flags. Never install, launch saved agents, create accounts/credentials/profiles/keys, copy secrets, grant access, alter Glitch or bypass trust.

## Choices and approval

1. Show all seven providers plus Custom, including unavailable choices. Widget limits require additional named groups preserving selections, not omissions/Other. Ask providers/account counts; use provider plus label suffix. Labels do not isolate identities.
2. Default to the selected machine/current OS account. Same-machine terminal providers use `local-terminal`; prefer `native-agent` for OMP when its native integration is supported. An existing POSIX account or literal same-host sudo wrapper does not make supported OMP terminal-only: preserve that account, executable and permission argv with native message delivery. Respect an explicitly requested terminal-only route; explain that it uses helper polling instead. Native preparation must verify the real route before saving; provider labels alone prove nothing. Desktop SSH is not another agent hop. Never infer an old SSH destination is local from its name/IP, `ssh -G`, aliases or forwarding. Without positively established endpoint identity, preserve that route until the user explicitly selects the intended Tern execution machine and local/native route. Preserve account/ID/command/argv/folder; genuine remote SSH stays Advanced/not managed-ready. Discover actual account/home/authorization; invent no destinations or keys.
3. Show exact executable and separate argv. Retain supported account/profile/model selectors and explicit choices; ordinary default model is preselected, alternatives must be supported. No silent model substitution/login inference. Login requires separate consent; never request/display/store secrets. Mention Kimi `login --region` only if installed help supports it.
4. Offer Normal permissions preselected and native named choices using each CLI's exact verified flags/consequences. Support apply-to-all, a selected subset and individual overrides. Preserve entered choices and resolve contradictory selections/custom text before review. Codex's supported `--dangerously-bypass-approvals-and-sandbox` is **YOLO — no sandbox**, bypassing both protections. Kimi's supported Default, Ask when needed (`--yolo`) and Never ask (`--auto`) are distinct: `--auto` is not its normal mode. Claude/Agy may support `--dangerously-skip-permissions`; Muse/Grok may support `--yolo`; verify installed meanings. Never copy a generic `--auto`/`--yolo` across providers, silently broaden access or force known supported choices through Other. Unproven flags remain a named prerequisite, with Normal retained.
5. Declare lowercase `provider_family`: direct-service defaults Claude→anthropic, Codex→openai, Kimi→moonshot, Grok→xai, Agy→google, Muse→meta ([Muse source](https://dev.meta.ai/docs/overview)). Supported wrappers/configurations may differ. Ask/inspect non-secret configuration for OMP/custom/wrapped services; never use `omp` as the underlying provider. Declarations are configuration, not verified identity.
6. Ordinary Native OMP needs an approved nonempty startup prompt; other local providers keep terminal routes. Preserve IDs, literal paths, permission argv, model/profile, placement, enabled state and unrelated metadata. No standalone bulk startup; ORCH+ orchestrates tasks.
7. Review every account's changes, executable/argv, route, folder, model/profile, family and effective permissions in human language. Obtain complete explicit approval. **This is the only approval:** SPAWN asks nothing after it. State the exact roster and checks: terminal accounts get offline checks; each native OMP account gets one harmless model message (name model and permissions; may cost credits; not a sandbox). Optional provider readiness exercises are separate, offered by name. SPAWN runs only what you disclosed. No user JSON/IDs, unapproved edits, conflict-evading renames or broader permissions.

## Submit once; observe actual saving

After approval write one complete UTF-8 object, at most 120000 bytes, to the exact appended `result_path`:

```json
{"schema":2,"setup_run_id":"EXACT APPENDED RUN ID","confirmed":true,"agents":[{"id":"codex-work","provider":"Codex","provider_family":"openai","account_label":"Work","backend":"local-terminal","enabled":true,"command":"codex","arguments":[],"cwd":"/approved/folder","placement":"tab"}]}
```

Limit 32 unique records; omit unused/null fields. Preserve supported selectors/unchanged managed metadata. Never invent `mailbox.verified`, `evidence_ref`, resource proof or retired bulk fields. Rejections require corrected ordinary settings and fresh approval, not blind retry.

Run the appended helper once in its specified POSIX shell/PowerShell, never cmd.exe. Require injected `TERN_EXE`/`TERN_PANE_SOCKET`, not PATH/default-daemon guesses. Preserve config directory, run ID, binding, path, window and recipient. No raw store writes, transcript scraping, blind keys, replay or fabricated receipts.

Submission is not persistence. After you submit, SPAWN saves, prepares and verifies the roster itself and shows progress, failures and the result in its own pane: no popup, no extra click. A roster with nothing enabled, an SSH route or an unreviewed setting is saved unprepared and SPAWN says why. The existing durable writer receipt/UI proves the saved count; only final verified readback proves setup success. Do not request another helper model turn for status or make humans relay identifiers. If the helper cannot observe the final UI outcome, state what remains; never claim success. Preserve refusals with one corrective action; conflicts need Agent settings review. Discard requires a separate native decision; Cancel retains.

## Required preparation

Your one approval covers the save, account/command/folder checks, helper preparation, route verification, owned cleanup, final readback and status refresh. If agents still need preparation (ORCH+ installed later), SPAWN offers one **Prepare agents for ORCH+** action for the missing work; prepared agents are reused. Disabled accounts require explicit Enable agent before preparation; unreviewed settings require review/approval. Active/uncertain host work, including managed enrollment/mailbox obligations, blocks that record. A diagnostic reserves its record against new launches until cleanup. Later settings/membership changes cancel remaining consent. Capacity bounds are checked before diagnostic cost; never clear unread receipts or raise limits to force saving.

Keep separate per-record nonce/revision/identity, exact clicked recipient and once-only diagnostic/save. Never reuse consent or replay uncertainty/paid checks. Only all requested saves/readbacks justify **SPAWN SETUP SUCCESSFUL** plus count. Otherwise show **SPAWN Setup failed: <specific cause>**, observed saved count/unconfirmed remainder and one next action.

Preparation certifies neither login, CLI semantics nor optional paid readiness. macOS automatic terminal continuation additionally needs observed Python 3/ctypes/libproc: use SPAWN's check, explain missing prerequisites and approved installer/check-again action, never auto-install. This gates neither ordinary standalone launch nor native OMP and cannot certify legacy processes. Preserve uncertain effects, directories and history; never clear them for apparent success.
