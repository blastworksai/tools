# gcc-skill-review: full report

skills/gcc-skill-review | retrieved 2026-11-08 | sha256 8dfd6e2ced6dcd2a0cf53cdef010da9aa2e26184ae651f24cec249a3ba3681e4
Run 2026-11-08_8dfd6e2 | Walkdown 0.3.1+blastworks.1
Static examination only. Nothing executed. Every finding below is a location to look at; none is a verdict. Stage order; nothing is ranked.

## 1 What ships

8 files, 3 formats, 0 script languages. 0 hooks (0 host configs). 0 agent or command definitions. 0 platform manifests.

Validation: PASS (gate 26/26, negative 7/7; measured 2026-11-02, same code and fixtures)

Pin: sha256 8dfd6e2ced6dcd2a0cf53cdef010da9aa2e26184ae651f24cec249a3ba3681e4, 8 files, 29,692 bytes.

Formats: md 5, (none) 2, json 1.

Script languages: none.

### Entry points (2)

- README.md (readme)
- gcc-skill-review/SKILL.md (skill)

### Structural census (3)

- README.md:46: long-line: line 46: 543 characters (limit 500)
- gcc-skill-review/SKILL.md:3: long-line: line 3: 614 characters (limit 500)
- gcc-skill-review/SKILL.md:28: long-line: line 28: 884 characters (limit 500)

### Descriptions (always-on text) (1)

- gcc-skill-review/SKILL.md:3: `Per-step reliability eval of a user's own skill or workflow. Maps steps as deterministic/probabilistic, adds one evidence file per step, writes per-step claude plugin eval checks against a known-answer sample, runs 5 fresh sessions per model, fixes the earliest failing step (one sentence or code), reruns to prove it. Use for "review my skill", "find the weak step", "test my skill", "skill is unreliable", "different answer every run", "eval my skill", "GCC skill review", "Kem's skill review". Not for code diffs (code-review), untrusted repos (danger-protocol), or explaining a project (gcc-walk).`

### Agent and command tool grants (0)

None.

### Hooks (0)

None.

### Platform manifests (0)

None.

### Licenses (license files and declared license fields) (2)

- LICENSE: MIT; license file, matched by text
- gcc-skill-review/LICENSE: MIT; license file, matched by text


### What it needs

Programs are the ones Walkdown recognizes (`stages/04-phrases/tools.yaml`); declared means named in a dependency file, a skill's compatibility field, or an install line.

- `claude`: not declared; used at gcc-skill-review/SKILL.md:62 (instructions), gcc-skill-review/SKILL.md:71 (instructions), gcc-skill-review/references/plugin-eval.md:19 (instructions), gcc-skill-review/references/plugin-eval.md:121 (instructions)
- No package imported.

### What ties it to one machine

Nothing found that ties it to one machine.

## 2 What the model actually reads

8/8 files (100.0%). 0 divergences. 8 lines changed by folding. 0 non-Latin runs. 0 passages in a language other than English. Validation INCOMPLETE: see 7.

Validation: INCOMPLETE (gate 20/31, negative 22/24, recall 1/1; skipped: 13 rows; measured 2026-11-02, same code and fixtures)

### Divergences (reading A versus reading B) (0)

None.

### Lines changed by folding (8)

- gcc-skill-review/SKILL.md:28: removed or replaced U+2026
- gcc-skill-review/SKILL.md:37: removed or replaced U+2026, U+2026, U+2026
- gcc-skill-review/SKILL.md:53: removed or replaced U+2026, U+2026
- gcc-skill-review/SKILL.md:67: removed or replaced U+00D7
- gcc-skill-review/SKILL.md:105: removed or replaced U+2013
- gcc-skill-review/references/example.md:56: removed or replaced U+2026, U+2026
- gcc-skill-review/references/plugin-eval.md:114: removed or replaced U+2026, U+2026
- gcc-skill-review/references/plugin-eval.md:130: removed or replaced U+2026

### Non-Latin script runs (0)

None.

### Passages in a language other than English (Latin script) (0)

None.

### Metadata carrying text (0)

None.

### Unread (0)

None.

## 3 What loads what

2 entry points. 1 orphan. 30 dangling references (30 code; 13 of them into a folder the repository does not have). 1 dynamic load: 0 files loaded only through one (named by nothing), 1 file reached only through a mention of a folder or wildcards. Graph incomplete by construction.

Validation: PASS (gate 11/11, negative 7/7; measured 2026-11-02, same code and fixtures)

Depth histogram (static = reached by direct references; dynamic = only through a load: a folder a config names, a code scan, wildcards in an instruction file; mention = only through a folder or wildcards named elsewhere): mention depth 1: 1; static depth 0: 2; static depth 1: 4.

### Entry points used (2)

- README.md (readme)
- gcc-skill-review/SKILL.md (skill)

### Orphans (reachable from no entry point) (1)

- capability.json

### Files loaded only through a dynamic load (named by nothing) (0)

None.

### Files reached only through a mention of a folder or wildcards (not a load) (1)

- gcc-skill-review/LICENSE (depth 1, from README.md)

### Dynamic loads (1)

- README.md:37: directory `gcc-skill-review/` (mention) resolves to 4 files

### On disk, left out of the manifest (a host that finds components by folder may still load them) (0)

None.

### Dangling references (17)

- gcc-skill-review/SKILL.md:30: `skill>-review/` (code)
- gcc-skill-review/SKILL.md:38: `map.md` (code)
- gcc-skill-review/SKILL.md:82: `counts-before.md` (code)
- gcc-skill-review/SKILL.md:97: `counts-after.md` (code)
- gcc-skill-review/references/plugin-eval.md:12: `evals/` (code)
- gcc-skill-review/references/plugin-eval.md:13: `case>/` (code)
- gcc-skill-review/references/plugin-eval.md:14: `prompt.md` (code)
- gcc-skill-review/references/plugin-eval.md:15: `graders/` (code)
- gcc-skill-review/references/plugin-eval.md:16: `check-name>.md` (code)
- gcc-skill-review/references/plugin-eval.md:31: `posts.csv` (code)
- gcc-skill-review/references/plugin-eval.md:39: `case.yaml` (code)
- gcc-skill-review/references/plugin-eval.md:114: `case.yaml` (code)
- gcc-skill-review/references/plugin-eval.md:121: `after>.json` (code)
- gcc-skill-review/references/plugin-eval.md:133: `home/` (code)
- gcc-skill-review/references/plugin-eval.md:133: `sealed/` (code)
- gcc-skill-review/references/plugin-eval.md:133: `tmp/` (code)
- gcc-skill-review/references/plugin-eval.md:134: `evidence/` (code)

### Dangling references into a folder the repository does not have (often one the workflow creates when it runs) (13)

- README.md:37: `.claude/skills/` (code)
- gcc-skill-review/SKILL.md:30: `.agents/skills/` (code)
- gcc-skill-review/SKILL.md:30: `.claude/skills/` (code)
- gcc-skill-review/SKILL.md:43: `skill>-review/copy/` (code)
- gcc-skill-review/SKILL.md:52: `evidence/03-top-five.md` (code)
- gcc-skill-review/SKILL.md:62: `skill>-review/copy/evals/` (code)
- gcc-skill-review/SKILL.md:75: `skill>-review/runs/` (code)
- gcc-skill-review/references/plugin-eval.md:10: `skill>-review/copy/` (code)
- gcc-skill-review/references/plugin-eval.md:55: `evidence/03-top-five.md` (code)
- gcc-skill-review/references/plugin-eval.md:71: `evidence/03-top-five.md` (code)
- gcc-skill-review/references/plugin-eval.md:82: `evidence/03-top-five.md` (code)
- gcc-skill-review/references/plugin-eval.md:100: `evidence/01-posts.md` (code)
- gcc-skill-review/references/plugin-eval.md:109: `evidence/06-review.md` (code)

### Not scanned for references (0)

None.

### Reference depth, directly reached files (6)

- LICENSE: depth 1, from README.md
- README.md: depth 0
- gcc-skill-review/SKILL.md: depth 0
- gcc-skill-review/references/example.md: depth 1, from gcc-skill-review/SKILL.md
- gcc-skill-review/references/plugin-eval.md: depth 1, from README.md
- prompts.md: depth 1, from README.md

## 4 What the text asks for

4a 1 · 4b 4 · 4c 15 · 4d 0 hits on 18 lines (15 read by a model, 3 human-facing); benign share not measured (stage 6 labels did not run). Hosts: 4, 0 not named in the docs. Confirm-first or prohibited actions in instruction text: 6, 5 with no confirmation step, 0 stated as prohibitions. Conditionals: 3 absence, 1 error, 1 environment, 1 version. Definitions: 0, 0 conflicts, 0 safety-word definitions. Long files with flagged lines: 0, 0 with some past the reader window. Sentences repeated across files: 0, 0 flagged. Lines that look like committed secrets: 0.

Validation: PASS (gate 153/153, negative 121/121, recall 43/43; measured 2026-11-02, same code and fixtures)

Every hit is a locator. Benign share not measured here; stage 6 labels, when run, read the lines a model sees (section 6). Audience is who the file addresses, by path.

### 4a Reaching out

#### phrase.K.exfil (0 lines)

None.

#### phrase.creds (1 line)

Patterns: creds.env-enum-code 1

- gcc-skill-review/references/plugin-eval.md:3 [creds.env-enum-code] (model): `` Shapes verified on Claude Code 2.1.319 (the shell sandbox and `env` facts from a refused run, 8 Nov). ``

#### phrase.remote-load (0 lines)

None.

### 4b Taking the wheel

#### phrase.L.override (0 lines)

None.

#### phrase.A.consent (0 lines)

None.

#### phrase.B.defs (4 lines)

Patterns: B.safety-adjective 4

- gcc-skill-review/SKILL.md:28 [B.safety-adjective] (model): `` Skill runs scripts (needs a shell)? Check now (Linux/WSL; plain Windows: use WSL): `command -v bwrap socat`, and `sysctl kernel.apparmor_restrict_unprivileged_userns` must not be 1 (Ubuntu 24.04+ default; every sandboxed shell command then fails with `apply-seccomp … setgroups`). The sandbox also cannot read the user's home or reach the network, so a skill that installs or downloads at run time cannot run there. Either tool missing → the eval refuses every run at 0 turns; any of these → tell the person before stage 1 and offer, in one structured question: fresh sessions instead (one at a time, each unsandboxed on its own throwaway copy of the sample, scored by the same checks; say the isolation is weaker), fixing the host (installing `socat` or changing AppArmor needs their go), or stopping after stage 3 with the pattern checks proven on hand-written good and wrong files. ``
- gcc-skill-review/references/plugin-eval.md:62 [B.safety-adjective] (model): `` The case folder is read-only to the run: a skill that writes into the person's project cannot work on a sample left there. Copy the sample into the run folder with a `scaffold_script` (runs only with `--scaffold`, and only on case files you wrote). ``
- gcc-skill-review/references/plugin-eval.md:130 [B.safety-adjective] (model): `` - On Linux with `kernel.apparmor_restrict_unprivileged_userns = 1`, every sandboxed Bash call fails (`apply-seccomp: write /proc/self/setgroups … Permission denied`) even with bwrap and socat present. ``
- gcc-skill-review/references/plugin-eval.md:133 [B.safety-adjective] (model): `` A kept folder is read-only, with `home/` and `tmp/` sealed (mode 000) in `sealed/`; open them with `chmod 700 <kept> <kept>/sealed`, never run git inside one, and remove the kept folders when the review is done. ``

#### phrase.H.anti-review (0 lines)

None.

#### phrase.I.conditional (0 lines)

None.

### 4c Changing the environment

#### phrase.E.perms (1 line)

Patterns: E.exec-primitive 1

- gcc-skill-review/references/plugin-eval.md:133 [E.exec-primitive] (model): `` A kept folder is read-only, with `home/` and `tmp/` sealed (mode 000) in `sealed/`; open them with `chmod 700 <kept> <kept>/sealed`, never run git inside one, and remove the kept folders when the review is done. ``

#### phrase.C.second-order (4 lines)

Patterns: C.error-instruction 4

- gcc-skill-review/SKILL.md:28 [C.error-instruction] (model): `` Skill runs scripts (needs a shell)? Check now (Linux/WSL; plain Windows: use WSL): `command -v bwrap socat`, and `sysctl kernel.apparmor_restrict_unprivileged_userns` must not be 1 (Ubuntu 24.04+ default; every sandboxed shell command then fails with `apply-seccomp … setgroups`). The sandbox also cannot read the user's home or reach the network, so a skill that installs or downloads at run time cannot run there. Either tool missing → the eval refuses every run at 0 turns; any of these → tell the person before stage 1 and offer, in one structured question: fresh sessions instead (one at a time, each unsandboxed on its own throwaway copy of the sample, scored by the same checks; say the isolation is weaker), fixing the host (installing `socat` or changing AppArmor needs their go), or stopping after stage 3 with the pattern checks proven on hand-written good and wrong files. ``
- gcc-skill-review/references/plugin-eval.md:60 [C.error-instruction] (model): `` Seen on the trial: with a bare file name in the prompt the model searched, never found the file and wrote nothing, so every check failed on a fault of the case, not the skill.\nAn absolute path outside the case folder is refused before the run ("escapes the case directory").\nThe case folder is read-only to the run: a skill that writes into the person's project cannot work on a sample left there. Copy the sample into the run folder with a `scaffold_script` (runs only with `--scaffold`, and only on case files you wrote). ``
- gcc-skill-review/references/plugin-eval.md:140 [C.error-instruction] (model): `` The `--json` file holds, per case, `arms.with[]`: one entry per run, each with `turns`, `error`, `tracePath` and `graders[]` (`name`, `passed`, `explanation`).\nCount passes per grader across the runs for the table.\n`tracePath` is that run's full session; read it for the passing run you read in full, and for any failure before you believe it. ``
- prompts.md:45 [C.error-instruction] (subagent): `step order showing passes out of five. For every failure quote that\nstep's Picked line. Give it one of four verdicts: the step was\nwrong, the skill left it open, an earlier step handed it a wrong\ninput, the check was wrong. Then read one run that passed`

#### phrase.D.trust (0 lines)

None.

#### phrase.E.env (1 line)

Patterns: E.self-install 1

- gcc-skill-review/SKILL.md:43 [E.self-install] (model): `` Copy the skill to `<skill>-review/copy/`; change only the copy. ``

#### phrase.J.prohibited (9 lines)

Patterns: J.confirm-first 9

- LICENSE:11 [J.confirm-first] (human): `to use, copy, modify, merge, publish, distribute, sublicense, and/or sell`
- README.md:53 [J.confirm-first] (human): `` - **The eval report is published to claude.ai by default.** The skill always passes `--no-publish`. ``
- gcc-skill-review/LICENSE:11 [J.confirm-first] (human): `to use, copy, modify, merge, publish, distribute, sublicense, and/or sell`
- gcc-skill-review/SKILL.md:71 [J.confirm-first] (model): `claude plugin eval <skill>-review/copy --runs 5 --model <model> --ablation none --no-publish --keep-temp --trust-plugin --allow-tools Write Edit Bash --json <skill>-review/runs/<model>-before.json </dev/null`
- gcc-skill-review/SKILL.md:74 [J.confirm-first] (model): `` `--no-publish` always (default publishes the report to claude.ai). `--trust-plugin` only for the copy you wrote. ``
- gcc-skill-review/references/example.md:17 [J.confirm-first] (model): `Input: a spreadsheet of 30 invented posts (format, topic, reach, likes, comments, saves, shares).`
- gcc-skill-review/references/plugin-eval.md:121 [J.confirm-first] (model): `claude plugin eval <skill>-review/copy --runs 5 --model <model> --ablation none --no-publish --keep-temp --trust-plugin --allow-tools Write Edit Bash --json <skill>-review/runs/<model>-<before|after>.json </dev/null`
- gcc-skill-review/references/plugin-eval.md:125 [J.confirm-first] (model): `` - `--no-publish` always: by default the report is published to claude.ai. ``
- gcc-skill-review/references/plugin-eval.md:143 [J.confirm-first] (model): `` An HTML report lands in `evals/results/<timestamp>/report.html`, local only with `--no-publish`. ``

### 4d Talking to the human

#### phrase.G.human (0 lines)

None.

### Tables

Hosts: 4, 0 not named in the docs. Confirm-first or prohibited actions in instruction text: 6, 5 with no confirmation step, 0 stated as prohibitions. Conditionals: 3 absence, 1 error, 1 environment, 1 version. Definitions: 0, 0 conflicts, 0 safety-word definitions. Long files with flagged lines: 0, 0 with some past the reader window. Sentences repeated across files: 0, 0 flagged. Lines that look like committed secrets: 0.

### Endpoints (hosts named anywhere; documented = named in the docs) (4)

- blastworks.ai: documented, other; 4 docs; first at LICENSE:5
- claude.ai: documented, other; 2 instructions, 1 docs; first at README.md:53
- glitchcatclub.com: documented, other; 1 instructions, 4 docs; first at LICENSE:3
- instagram.com: documented, other; 1 instructions, 4 docs; first at LICENSE:3

### Confirm-first and prohibited actions in instruction text (6)

- gcc-skill-review/SKILL.md:71: confirm-first, `publish`, no confirmation step: `claude plugin eval <skill>-review/copy --runs 5 --model <model> --ablation none --no-publish --keep-temp --trust-plugin --allow-tools Write Edit Bash --json <skill>-review/runs/<model>-before.json </dev/null`
- gcc-skill-review/SKILL.md:74: confirm-first, `publish`, no confirmation step: `` `--no-publish` always (default publishes the report to claude.ai). `--trust-plugin` only for the copy you wrote. ``
- gcc-skill-review/references/example.md:17: confirm-first, `posts (format, topic, reach, likes, comments`, no confirmation step: `Input: a spreadsheet of 30 invented posts (format, topic, reach, likes, comments, saves, shares).`
- gcc-skill-review/references/plugin-eval.md:121: confirm-first, `publish`, confirmation at line 130: `claude plugin eval <skill>-review/copy --runs 5 --model <model> --ablation none --no-publish --keep-temp --trust-plugin --allow-tools Write Edit Bash --json <skill>-review/runs/<model>-<before|after>.json </dev/null`
- gcc-skill-review/references/plugin-eval.md:125: confirm-first, `publish`, no confirmation step: `` - `--no-publish` always: by default the report is published to claude.ai. ``
- gcc-skill-review/references/plugin-eval.md:143: confirm-first, `publish`, no confirmation step: `` An HTML report lands in `evals/results/<timestamp>/report.html`, local only with `--no-publish`. ``

### Conditionals (6)

- gcc-skill-review/SKILL.md:14: error: if `before believing a failed check.` then `- Open the step's file`
- gcc-skill-review/SKILL.md:25: absence: if `If none` then `` offer to invent a small one with planted answers (shape: `references/example.md`) and have them confirm the answers. ``
- gcc-skill-review/SKILL.md:102: absence: if `before/after or the script; anything a passing run got wrong that no check caught; what was not proven.` then `Then: the map with steps to move into code; the sentence`
- gcc-skill-review/references/plugin-eval.md:128: absence: if `before the model starts ("Sandbox required but unavailable").` then `Without them the run is refused`
- gcc-skill-review/references/plugin-eval.md:135: environment: if `once on the one subscription; leave it at 1 on a loaded machine.` then `` - `-j <n>` runs up to 8 at ``
- gcc-skill-review/references/plugin-eval.md:136: version: if `` if any case scores under `--threshold` (default 1.0); that is a result `` then `- The run exits 1 not a crash.`

### Definitions (0)

None.

### Terms defined more than one way (0)

None.

### Safety words defined (0)

None.

### Lines that look like committed secrets (values never shown) (0)

None.

### Position of flagged lines in long files (first 10% / middle 80% / last 10%) (0)

None.

### Settings that restrict tools (a fact, never a risk) (0)

None.

### Sentences repeated across files a model reads (0)

None.

### Will it trigger

What each host does with a skill's, agent's, or command's frontmatter is in `stages/04-phrases/trigger.yaml` (dated, with sources).

1 skill: 1 Claude chooses by its description.

Skill descriptions here take about 150 tokens (601 characters). Claude Code's listing of every installed skill holds about 1% of the context: about 320 tokens at 32,000, 2,000 at 200,000.

- `gcc-skill-review/SKILL.md` (skill): auto; description 601 characters

Every entry has frontmatter its host reads and follows the rules.

### Ready for any AI

What each AI host reads is in `stages/04-phrases/hosts.yaml` (dated, with sources).

For the hosts named (claude, codex):

- Claude Code: no instruction file it reads (CLAUDE.md, CLAUDE.local.md, .claude/CLAUDE.md, and 1 more).
- Codex: no instruction file it reads (AGENTS.md).

- Claude Code: none of its files (it reads CLAUDE.md, CLAUDE.local.md, .claude/CLAUDE.md; skills in .claude/skills).
- Codex: none of its files (it reads AGENTS.md; skills in .agents/skills).
- Gemini CLI: none of its files (it reads GEMINI.md; skills in .gemini/skills, .agents/skills).
- Cursor: none of its files (it reads .cursor/rules/*.mdc, AGENTS.md, .cursorrules; skills in .agents/skills, .cursor/skills, .claude/skills, .codex/skills).
- GitHub Copilot: none of its files (it reads .github/copilot-instructions.md, .github/instructions/*.instructions.md, AGENTS.md; skills in .github/skills, .claude/skills, .agents/skills).
- Windsurf: none of its files (it reads .windsurf/rules/*.md, AGENTS.md, .windsurfrules).
- Other tools that read AGENTS.md: none of its files (it reads AGENTS.md).

Skills no host reads where they sit (1); a host reads them once they are installed (copied into its skill folder, or added as a plugin):

- `gcc-skill-review/SKILL.md`

Copies kept for two hosts (0):

- None.

No one-host feature found.

### Current and clean

Facts with locations: Walkdown never says a date is past, a model retired, or a TODO matters. The patterns are in `stages/04-phrases/clean.yaml` (dated, with sources).

No unfinished text, dated claims, pinned model IDs, or older tool names.

## 5 What this touches

Can read your data: yes · Can take outside input: no · Can send data out: no Install grants: context-injection, persistence.

Validation: PASS (gate 81/81, negative 24/24; measured 2026-11-02, same code and fixtures)

A map of capability, derived from stages 1 to 4; it reaches no verdict. A Bash grant is counted as private-data access and execute posture; on its own it does not count as external communication.

### Trifecta legs

- Can read your data: yes (1 citation)
    - stage 04 phrase.creds gcc-skill-review/references/plugin-eval.md:3: phrase.creds: creds.env-enum-code
- Can take outside input: no (0 citations)
- Can send data out: no (0 citations)

### Install grants

- context-injection (1 citation)
    - stage 01 struct.description gcc-skill-review/SKILL.md:3: description: always-on text
- persistence (1 citation)
    - stage 04 phrase.E.env gcc-skill-review/SKILL.md:43: phrase.E.env: E.self-install

### Text in context at load

Bytes at load: descriptions 601 (1, exact).

- gcc-skill-review/SKILL.md:3: description, 601 bytes, exact

### What it costs and what ships

Expected context: 32,000 tokens (a line for 200,000 beside it). Tokens are estimated from size: about 4 bytes of English text per token; text in other scripts runs high.

- Every session, once installed (descriptions, hooks): 151 tokens, under 1% of 32,000, under 1% of 200,000
- When the largest skill runs: 1,917 tokens, 6% of 32,000, under 1% of 200,000
- That skill and everything it names: 4,572 tokens, 14% of 32,000, 2% of 200,000
- The largest is `gcc-skill-review/SKILL.md`, of 1 skill, agent, or command.

Every skill, agent, or command, by tier (tokens):

- gcc-skill-review/SKILL.md: runs 1,917, with what it names 4,572, with wildcard loads 4,572

#### Loads into the AI: 3 files, 17.9 KB, 4,572 tokens

- `gcc-skill-review/SKILL.md`: skills, agents, and commands, 7.5 KB, 1,917 tokens
- `gcc-skill-review/references/example.md`: named by a file the AI loads, 4.0 KB, 1,035 tokens, reached from `gcc-skill-review/SKILL.md`
- `gcc-skill-review/references/plugin-eval.md`: named by a file the AI loads, 6.3 KB, 1,620 tokens, reached from `gcc-skill-review/SKILL.md`

#### Used another way: 0 files, 0 bytes, 0 tokens

None.

#### Not used at run time: 5 files, 11.1 KB, 2,853 tokens

- `LICENSE`: written for people, 1.3 KB, 331 tokens
- `README.md`: written for people, 5.1 KB, 1,316 tokens
- `gcc-skill-review/LICENSE`: written for people, 1.3 KB, 331 tokens
- `capability.json`: nothing points to it, 295 bytes, 74 tokens
- `prompts.md`: nothing points to it, 3.1 KB, 801 tokens

### Agent and command posture (0)

None.

### Stated limits: read-only wording a model reads, and what backs it (2)

- gcc-skill-review/references/plugin-eval.md:62: stated; Stated in the text; Walkdown found no tool setting that enforces it (gcc-skill-review/SKILL.md has no tools list). `` The case folder is read-only to the run: a skill that writes into the person's project cannot work on a sample left there. Copy the sample into the run folder with a `scaffold_script` (runs only with `--scaffold`, and only on case files you wrote). ``
- gcc-skill-review/references/plugin-eval.md:133: stated; Stated in the text; Walkdown found no tool setting that enforces it (gcc-skill-review/SKILL.md has no tools list). `` A kept folder is read-only, with `home/` and `tmp/` sealed (mode 000) in `sealed/`; open them with `chmod 700 <kept> <kept>/sealed`, never run git inside one, and remove the kept folders when the review is done. ``

### Pairs: Test data a model-read file references directly (0)

None.

### Pairs: Image a model-read file points at (0)

None.

### Pairs: Orphan with a phrase hit (0)

None.

### Pairs: Hidden text with a phrase hit (0)

None.

### Pairs: Load-only file with a phrase hit (0)

None.

### Pairs: Instruction in a script a context-injecting hook runs (0)

None.

### Do the tools fit the job

Entries checked: 1 (0 with a tools list, 0 agents with none). The yardstick is each entry's own words, over what it reads, against its own grants; families and hook facts are in `stages/05-capability/fit.yaml`, the cues in `stages/04-phrases/asks.yaml`.

Every tool granted is one the words ask for, and nothing asks for a tool it lacks.

## 6 Needs a human read

16 questions (15 labeling, 1 relational). Packet only: no model read (06-packet.md in the run folder).

Validation: PASS (gate 125/125, negative 11/11, recall 0/165; skipped: 124 rows; measured 2026-11-02, same code and fixtures)

Questions a pattern cannot settle, and the answers of the backends named here. Every answer is a located observation; none changes a finding in sections 1 to 5.

- no backend: packet only

### Questions

- gcc-skill-review/SKILL.md:28 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- gcc-skill-review/SKILL.md:43 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- gcc-skill-review/SKILL.md:71 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- gcc-skill-review/SKILL.md:74 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- gcc-skill-review/references/example.md:17 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- gcc-skill-review/references/plugin-eval.md:3 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- gcc-skill-review/references/plugin-eval.md:60 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- gcc-skill-review/references/plugin-eval.md:62 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- gcc-skill-review/references/plugin-eval.md:121 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- gcc-skill-review/references/plugin-eval.md:125 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- gcc-skill-review/references/plugin-eval.md:130 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- gcc-skill-review/references/plugin-eval.md:133 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- gcc-skill-review/references/plugin-eval.md:140 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- gcc-skill-review/references/plugin-eval.md:143 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- prompts.md:45 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- (repo) [relational] Describe, as capability and not intent, how these three capabilities could combine in this artifact, citing the evidence given.
    - soft.read: skipped (no relational backend)

## 7 Not examined

- Stage 02-reader validation INCOMPLETE (gate 20/31, negative 22/24, recall 1/1; skipped: 13 rows; measured 2026-11-02, same code and fixtures): its zeros are not validated for the skipped checks.
- (02-reader) tesseract not installed (no tesseract binary, no pytesseract): images and PDF pages are skipped for OCR (read.divergence skip); images and PDFs with no text layer are listed as read.unread
- (02-reader) html render: playwright not installed: HTML files are read with static style only (read.divergence skip, carrier rendered)
- (02-reader) v1 limit: the language check (read.language) reads prose only: Markdown, plain text, PDF, DOCX, and OCR text; Markdown code blocks, comments in code, config values, and HTML are not checked for language, and a paragraph under five words is too short to judge
- (03-graph) v1 limit: manifest versus disk compares skills, agents, and commands, and only the kinds a manifest names; a manifest that names none relies on its folders and is not compared, and plugins a marketplace leaves out are not compared
- (03-graph) graph incomplete by construction: 1 dynamic load(s); targets resolved as of review time only
- (04-phrases) limit: files that do not decode as text (PDF, DOCX, images) are scanned from stage 2's extracted text, phrase patterns only
- (05-capability) stage 5 limit: a Bash grant is recorded under private-data and as execute posture, never as external-comms; Bash can reach the network, as can every shell, so this map does not count it there
- (05-capability) stage 5 limit: hook bytes are an estimate from the sizes of files the hook script references (stage 3 static edges); hooks are never run to measure their output
- soft.label skipped for gcc-skill-review/SKILL.md: no labeling backend
- soft.label skipped for gcc-skill-review/references/example.md: no labeling backend
- soft.label skipped for gcc-skill-review/references/plugin-eval.md: no labeling backend
- soft.label skipped for prompts.md: no labeling backend
- soft.read skipped for None: no relational backend
- (06-soft) skipped: soft.label x15: no labeling backend
- (06-soft) skipped: soft.read x1: no relational backend
- Static examination only. Nothing in the artifact was executed, fetched, or installed.
- Stage 6 answers are located observations from the backends section 6 names; they never change a stage 1 to 5 finding. Hit counts carry a benign share only when stage 6 labels ran.
- Version drift (class 8): each run examines one pinned copy. walkdown.py compares it with the previous run of the same repository when there is one (changes.md next to this report); what the artifact becomes after its next update is seen only by auditing it again.
- English-language scope: the phrase layer is blind to non-English text (stage 2 lists non-Latin runs, and prose passages in another language in Latin script; a short line can slip past that check).
- Stage 4 matches patterns; a payload phrased outside every pattern reads as no hit. A zero here is not safety.

## Recommendations

Conditional on what the skill is for. Unranked, in stage order. None: no finding matched a recommendation template.


What this is not: static examination only. "Clean" means these stages found nothing; it does not mean the artifact is safe. This report offers possible issues with evidence and reaches no verdict. What to do with it is yours to decide.
