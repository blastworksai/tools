---
name: spawn-setup
description: Discover real agent/account choices and submit one approved run-bound roster to SPAWN's durable writer.
---

# Guided SPAWN setup

Use the appended immutable execution-host/session context. SPAWN already asked **Single or Multi Device Setup?** and, for Multi, **Which Device is the primary execution machine?**, before its one **Start Guided setup** action. Work on that selected machine, not its attached desktop. Do not repeat topology, guess missing devices, create transport connections/panes or federate hosts. Keep helper left/SPAWN right; OMP ACP is recommended, but never change the configured Tern default.

## Run the question script: two phases

Run the appended `questions_script` (POSIX shell: `sh <questions_script> --cwd <cwd> [--glitch-root <path>]...` with one `--glitch-root` for `glitch_installation.root` and for every entry of its `candidates` in any state, since the script re-verifies each; PowerShell for `.ps1`, `-GlitchRoot`, `-Cwd`, then the same `--` answer flags). It is read-only: it finds the CLIs, every OS account and install that can run them, Glitch and the permission flags each install's own `--help` shows, and prints JSON `{phase, intro, prompts, derived, limits}`. Never improvise questions or choices; never ask for a model or startup prompt.

1. **Phase 1** (no answer flags) asks only about accounts. Print every `intro` line verbatim, one per line; never summarise it. Never propose a label of your own.
2. Render `prompts` in order, each question with your native structured-question tool, word for word (title, header, options, descriptions; `limits` already fit Claude Code and OMP). Print a prompt's `lines` verbatim before it. `preselected` is the default answer: use the tool's default/recommended field (OMP's `ask` takes one HTML `<form>`: a fieldset per question, radio for single, checkbox for multiSelect, `checked` for preselected; its option text is the label, its description follows it). At most 4 questions per call.
3. Conditions: `when` `{question, is}` asks a question only when that earlier answer was that label. `for_each` repeats a template once per option picked in its `questions` (or once per `items` entry): `{provider}` is that option's label, `{cli}` its `value`. `for_each_count` makes that earlier answer `{N}`. Other on `count` must be a whole number from `other.whole_number`. An option with `"type":true` (or Other) takes typed text. Yes with no provider picked counts as No.
4. **Phase 2:** run the script again with `next.argv` plus, per `labels` answer, `--accounts <cli>=<labels>`: `numbered` gives `{provider} 1,...,{provider} {N}`; typed text passes as typed. A reply `{"ok":false,"why":...}` is shown verbatim and that answer asked again.
5. **Change some**, a typed path or **Skip it**: ask which agent and which install (`derived.candidates[].option` for its provider), a typed absolute path or skip, then run phase 2 again with `derived.rerun.argv` plus `--map <id>=<key or path>` or `--skip <id>`. The operator types a path only when the mapping says no install was found, and the script checks it. Never log in, switch, share or copy an account.
6. **Custom** permission text: split on spaces, run `--check-args <cli> <word>...`; use only its `arguments`, else show `why` and ask again. **Change something** or Other elsewhere: ask what to change, then ask that prompt again. Choose nothing the user did not select.

Never install, launch saved agents, create accounts/credentials/profiles/keys, copy secrets, grant access, alter Glitch or bypass trust. Availability proves neither login nor readiness. Never use another account's CLI path; an account the script did not list stays omitted.

## Records and approval

1. Default to the selected machine/current OS account. Same-machine terminal providers use `local-terminal`; prefer `native-agent` for OMP when supported. A POSIX account or same-host sudo wrapper does not make OMP terminal-only: keep the account, executable and permission argv with native delivery. Respect an explicitly requested terminal-only route. Native preparation verifies the real route before saving. Desktop SSH is not another agent hop. Never infer an old SSH destination is local from name/IP, `ssh -G`, aliases or forwarding; preserve it until the user selects the Tern execution machine. Genuine remote SSH stays Advanced/not managed-ready.
2. Per agent take `id`, `provider`, `provider_family`, `account_label` and `command` from `derived.accounts[]`. Folder: **All** gives every agent the Glitch folder (the **Which Glitch folder?** answer when asked), **Choose per agent** gives it to the agents picked and `home` to the rest, **None** or no Glitch gives each its `home`. For a non-operator account write `user` plus that account's own executable in `command`, no `sudo` wrapper (SPAWN's stored shape; its review labels `user` as SSH user).
3. `arguments`: Default and YOLO are that agent's `derived.permissions` entry, Custom the checked words; never add, copy or broaden a flag. Codex YOLO bypasses approvals and sandbox; Kimi `--auto` is not its normal mode. Keep supported selectors (`model_selector: true` = real model); no silent model substitution or login inference; login needs separate consent; never request, display or store secrets.
4. OMP's `provider_family` is the service the user chose; never use `omp`. Native OMP records need the nonempty `prompt` field (no other name) set to `derived.omp_prompt`. Preserve IDs, literal paths, argv, model/profile, placement, enabled state and unrelated metadata. No standalone bulk startup; ORCH+ orchestrates tasks.
5. The review prompt is the approval. Before it (its `show_first`) print one row per agent you will save, under `derived.review.columns`: `id`, `account`, `command`, its arguments, its folder and its paid check, in human language; `{N}` in its question is that count. **This is the only approval:** SPAWN asks nothing after it. Terminal accounts get offline checks; each native OMP account gets one harmless paid model message (name model, permissions, credits, no sandbox). List exactly the native IDs you disclosed in `paid_checks`; SPAWN checks no other native account. No user JSON/IDs, unapproved edits or conflict-evading renames.

## Submit once; observe actual saving

After approval write one complete UTF-8 object, at most 120000 bytes, to the exact appended `result_path`:

```json
{"schema":2,"setup_run_id":"EXACT APPENDED RUN ID","confirmed":true,"agents":[{"id":"codex-work","provider":"Codex","provider_family":"openai","account_label":"Work","backend":"local-terminal","enabled":true,"command":"/home/work/.local/bin/codex","arguments":[],"user":"work","cwd":"/approved/folder","placement":"tab"}]}
```

Limit 32 unique records; omit unused/null fields; `paid_checks`: optional enabled-native IDs. Never invent `mailbox.verified`, `evidence_ref`, resource proof or retired bulk fields. Rejections need corrected ordinary settings and fresh approval, not blind retry.

Run the appended helper once in its specified POSIX shell/PowerShell, never cmd.exe. Require injected `TERN_EXE`/`TERN_PANE_SOCKET`, not PATH/default-daemon guesses. Preserve config directory, run ID, binding, path, window and recipient. No raw store writes, transcript scraping, blind keys, replay or fabricated receipts.

Submission is not persistence. SPAWN then saves, prepares and verifies the roster itself and shows progress, failures and the result in its own pane. The durable writer receipt proves the saved count; only final verified readback proves success. Do not request another helper turn for status or make humans relay identifiers. If you cannot observe the final outcome, state what remains; never claim success. Preserve refusals with one corrective action; conflicts need Agent settings review. Discard needs a separate native decision; Cancel retains.

## Required preparation

Your one approval covers the save, checks, preparation, route verification, owned cleanup and final readback. Disabled accounts need explicit Enable agent before preparation. Never clear unread receipts or raise limits to force saving. Never reuse consent or replay uncertainty/paid checks. Only all requested saves/readbacks justify **SPAWN SETUP SUCCESSFUL** plus count. Otherwise show **SPAWN Setup failed: <specific cause>**, observed saved count/unconfirmed remainder and one next action.

Preparation certifies neither login, CLI semantics nor optional paid readiness. macOS terminal continuation needs observed Python 3/ctypes/libproc: use SPAWN's check, never auto-install; it gates neither standalone launch nor native OMP. Preserve uncertain effects, directories and history.
