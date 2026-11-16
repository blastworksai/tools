# glitch-studio-pr2: full report

skills/glitch-studio | retrieved 2026-11-16 | sha256 223f8ed2993da2c0c9d596c03ade8a8d9f3b5378de14e1de16d5bd6cb2ff5129
Run 2026-11-16_223f8ed | Walkdown 0.3.1+blastworks.1
Static examination only. Nothing executed. Every finding below is a location to look at; none is a verdict. Stage order; nothing is ranked.

## 1 What ships

12 files, 3 formats, 0 script languages. 0 hooks (0 host configs). 0 agent or command definitions. 0 platform manifests.

Validation: PASS (gate 26/26, negative 7/7; measured 2026-11-02, same code and fixtures)

Pin: sha256 223f8ed2993da2c0c9d596c03ade8a8d9f3b5378de14e1de16d5bd6cb2ff5129, 12 files, 41,869 bytes.

Formats: md 9, (none) 2, json 1.

Script languages: none.

### Entry points (2)

- README.md (readme)
- glitch-studio/SKILL.md (skill)

### Structural census (0)

None.

### Descriptions (always-on text) (1)

- glitch-studio/SKILL.md:3: `Use when you want to build a product the studio way, with one orchestrator, frozen contracts, many checked lanes and proof that it works; say "build this the studio way", "studio build", "orchestrate this build" or "spec first, many lanes".`

### Agent and command tool grants (0)

None.

### Hooks (0)

None.

### Platform manifests (0)

None.

### Licenses (license files and declared license fields) (3)

- LICENSE: MIT; license file, matched by text
- glitch-studio/LICENSE: MIT; license file, matched by text
- glitch-studio/SKILL.md:4: MIT; declared in license


### What it needs

Programs are the ones Walkdown recognizes (`stages/04-phrases/tools.yaml`); declared means named in a dependency file, a skill's compatibility field, or an install line.

- No program Walkdown recognizes.
- No package imported.

### What ties it to one machine

Nothing found that ties it to one machine.

## 2 What the model actually reads

12/12 files (100.0%). 0 divergences. 0 lines changed by folding. 0 non-Latin runs. 0 passages in a language other than English. Validation INCOMPLETE: see 7.

Validation: INCOMPLETE (gate 20/31, negative 22/24, recall 1/1; skipped: 13 rows; measured 2026-11-02, same code and fixtures)

### Divergences (reading A versus reading B) (0)

None.

### Lines changed by folding (0)

None.

### Non-Latin script runs (0)

None.

### Passages in a language other than English (Latin script) (0)

None.

### Metadata carrying text (0)

None.

### Unread (0)

None.

## 3 What loads what

2 entry points. 1 orphan. 39 dangling references (39 code; 33 of them into a folder the repository does not have). 1 dynamic load: 0 files loaded only through one (named by nothing), 1 file reached only through a mention of a folder or wildcards. Graph incomplete by construction.

Validation: PASS (gate 11/11, negative 7/7; measured 2026-11-02, same code and fixtures)

Depth histogram (static = reached by direct references; dynamic = only through a load: a folder a config names, a code scan, wildcards in an instruction file; mention = only through a folder or wildcards named elsewhere): mention depth 1: 1; static depth 0: 2; static depth 1: 8.

### Entry points used (2)

- README.md (readme)
- glitch-studio/SKILL.md (skill)

### Orphans (reachable from no entry point) (1)

- capability.json

### Files loaded only through a dynamic load (named by nothing) (0)

None.

### Files reached only through a mention of a folder or wildcards (not a load) (1)

- glitch-studio/LICENSE (depth 1, from README.md)

### Dynamic loads (1)

- README.md:57: directory `glitch-studio/` (mention) resolves to 9 files

### On disk, left out of the manifest (a host that finds components by folder may still load them) (0)

None.

### Dangling references (6)

- README.md:24: `studio/` (code)
- README.md:50: `studio/` (code)
- glitch-studio/SKILL.md:49: `studio/` (code)
- glitch-studio/references/evidence.md:3: `studio/` (code)
- glitch-studio/references/evidence.md:51: `studio/` (code)
- glitch-studio/references/study-reference.md:35: `THIRD_PARTY_NOTICES.md` (code)

### Dangling references into a folder the repository does not have (often one the workflow creates when it runs) (33)

- glitch-studio/SKILL.md:75: `studio/00-frame.md` (code)
- glitch-studio/SKILL.md:99: `studio/01-study-reference.md` (code)
- glitch-studio/SKILL.md:114: `studio/02-domain-skills.md` (code)
- glitch-studio/SKILL.md:145: `studio/03-parts-and-specs.md` (code)
- glitch-studio/SKILL.md:148: `studio/04-contracts.md` (code)
- glitch-studio/SKILL.md:154: `studio/05-lanes.md` (code)
- glitch-studio/SKILL.md:168: `studio/06-model-tiers.md` (code)
- glitch-studio/SKILL.md:186: `studio/07-review-and-integrate.md` (code)
- glitch-studio/SKILL.md:204: `plans/archive/` (code)
- glitch-studio/SKILL.md:227: `studio/08-proof.md` (code)
- glitch-studio/SKILL.md:245: `studio/09-runtime-models.md` (code)
- glitch-studio/references/domain-skills.md:37: `studio/02-domain-skills.md` (code)
- glitch-studio/references/evidence.md:11: `studio/00-frame.md` (code)
- glitch-studio/references/evidence.md:12: `studio/01-study-reference.md` (code)
- glitch-studio/references/evidence.md:13: `studio/02-domain-skills.md` (code)
- glitch-studio/references/evidence.md:14: `studio/03-parts-and-specs.md` (code)
- glitch-studio/references/evidence.md:15: `studio/04-contracts.md` (code)
- glitch-studio/references/evidence.md:16: `studio/05-lanes.md` (code)
- glitch-studio/references/evidence.md:17: `studio/06-model-tiers.md` (code)
- glitch-studio/references/evidence.md:18: `studio/07-review-and-integrate.md` (code)
- glitch-studio/references/evidence.md:19: `studio/08-proof.md` (code)
- glitch-studio/references/evidence.md:20: `studio/09-runtime-models.md` (code)
- glitch-studio/references/evidence.md:41: `plans/archive/` (code)
- glitch-studio/references/evidence.md:69: `studio/02-domain-skills.md` (code)
- glitch-studio/references/evidence.md:73: `skills/weather-feed/SKILL.md` (code)
- glitch-studio/references/model-tiers.md:42: `studio/00-frame.md` (code)
- glitch-studio/references/model-tiers.md:43: `studio/06-model-tiers.md` (code)
- glitch-studio/references/planning-brief.md:57: `shared/contracts/` (code)
- glitch-studio/references/prove-it.md:41: `studio/08-proof.md` (code)
- glitch-studio/references/runtime-models.md:4: `studio/09-runtime-models.md` (code)
- glitch-studio/references/runtime-models.md:48: `studio/09-runtime-models.md` (code)
- glitch-studio/references/runtime-models.md:53: `studio/09-runtime-models.md` (code)
- glitch-studio/references/study-reference.md:41: `studio/01-study-reference.md` (code)

### Not scanned for references (0)

None.

### Reference depth, directly reached files (10)

- LICENSE: depth 1, from README.md
- README.md: depth 0
- glitch-studio/SKILL.md: depth 0
- glitch-studio/references/domain-skills.md: depth 1, from glitch-studio/SKILL.md
- glitch-studio/references/evidence.md: depth 1, from glitch-studio/SKILL.md
- glitch-studio/references/model-tiers.md: depth 1, from glitch-studio/SKILL.md
- glitch-studio/references/planning-brief.md: depth 1, from glitch-studio/SKILL.md
- glitch-studio/references/prove-it.md: depth 1, from glitch-studio/SKILL.md
- glitch-studio/references/runtime-models.md: depth 1, from glitch-studio/SKILL.md
- glitch-studio/references/study-reference.md: depth 1, from glitch-studio/SKILL.md

## 4 What the text asks for

4a 0 · 4b 6 · 4c 2 · 4d 0 hits on 8 lines (5 read by a model, 3 human-facing); benign share not measured (stage 6 labels did not run). Hosts: 3, 0 not named in the docs. Confirm-first or prohibited actions in instruction text: 0, 0 with no confirmation step, 0 stated as prohibitions. Conditionals: 9 absence, 2 error, 2 harness. Definitions: 2, 1 conflict, 2 safety-word definitions. Long files with flagged lines: 0, 0 with some past the reader window. Sentences repeated across files: 17, 1 flagged. Lines that look like committed secrets: 0.

Validation: PASS (gate 153/153, negative 121/121, recall 43/43; measured 2026-11-02, same code and fixtures)

Every hit is a locator. Benign share not measured here; stage 6 labels, when run, read the lines a model sees (section 6). Audience is who the file addresses, by path.

### 4a Reaching out

#### phrase.K.exfil (0 lines)

None.

#### phrase.creds (0 lines)

None.

#### phrase.remote-load (0 lines)

None.

### 4b Taking the wheel

#### phrase.L.override (1 line)

Patterns: L.forget 1

- glitch-studio/SKILL.md:5 [L.forget] (model): `compatibility: Host needs Glitch's /glitch-idea, /glitch-plan and /glitch-execute skills, the ability to load skills, run shell and git, and start fresh sub-agents or sessions. It never needs a named model.`

#### phrase.A.consent (0 lines)

None.

#### phrase.B.defs (2 lines)

Patterns: B.safety-exception 2

- glitch-studio/SKILL.md:65 [B.safety-exception] (model): `8. Never redo a finished stage, unless the user asks.`
- glitch-studio/references/evidence.md:63 [B.safety-exception] (model): `8. Never redo a finished stage, unless the user asks.`

#### phrase.H.anti-review (2 lines)

Patterns: H.unbounded 2

- README.md:15 [H.unbounded] (human): `Nothing counts until it has been shown working.`
- glitch-studio/SKILL.md:12 [H.unbounded] (model): `Nothing counts until it is shown working.`

#### phrase.I.conditional (1 line)

Patterns: I.failure-path 1

- glitch-studio/references/evidence.md:20 [I.failure-path] (model): `` | 9 | `studio/09-runtime-models.md` | per runtime call: tier, grammar, builder, refusal rule, budget, scoring; one line per rule (four) with its audit result; one audit line each for least access, reply validation and fail-closed fallback, with evidence; any fix task; the rerun of each failed check with its new result and evidence; the refreshed stage 8 proof; `Picked: pending` while a fix task is open; or `Picked: none` with the reason | ``

### 4c Changing the environment

#### phrase.E.perms (0 lines)

None.

#### phrase.C.second-order (0 lines)

None.

#### phrase.D.trust (0 lines)

None.

#### phrase.E.env (0 lines)

None.

#### phrase.J.prohibited (2 lines)

Patterns: J.confirm-first 2

- LICENSE:9 [J.confirm-first] (human): `to use, copy, modify, merge, publish, distribute, sublicense, and/or sell`
- glitch-studio/LICENSE:9 [J.confirm-first] (human): `to use, copy, modify, merge, publish, distribute, sublicense, and/or sell`

### 4d Talking to the human

#### phrase.G.human (0 lines)

None.

### Tables

Hosts: 3, 0 not named in the docs. Confirm-first or prohibited actions in instruction text: 0, 0 with no confirmation step, 0 stated as prohibitions. Conditionals: 9 absence, 2 error, 2 harness. Definitions: 2, 1 conflict, 2 safety-word definitions. Long files with flagged lines: 0, 0 with some past the reader window. Sentences repeated across files: 17, 1 flagged. Lines that look like committed secrets: 0.

### Endpoints (hosts named anywhere; documented = named in the docs) (3)

- blastworks.ai: documented, other; 3 docs; first at LICENSE:3
- chatdom.io: documented, other; 4 docs; first at LICENSE:26
- devpost.com: documented, other; 4 docs; first at LICENSE:26

### Confirm-first and prohibited actions in instruction text (0)

None.

### Conditionals (13)

- glitch-studio/SKILL.md:50: absence: if `If it is missing` then `begin at stage 0.`
- glitch-studio/SKILL.md:119: absence: if `If none exists` then `write a small domain skill before any product code.`
- glitch-studio/SKILL.md:144: absence: if `If no part is deep tier` then `the default level is fine.`
- glitch-studio/SKILL.md:213: absence: if `If no other family is reachable` then `write same-family and ask the user to decide.`
- glitch-studio/SKILL.md:254: error: if `If a check fails` then `write a fix task for the owning lane.`
- glitch-studio/references/domain-skills.md:11: harness: if `If no platform applies` then `` write `Picked: none` and the reason. ``
- glitch-studio/references/domain-skills.md:18: harness: if `If a skill covers the platform` then `read it and record its name.`
- glitch-studio/references/evidence.md:15: absence: if `` if none); or `Picked `` then `` | 4 | `studio/04-contracts.md` | the exact contract text; per contract: name, path, producer, readers; the freeze commit (`pending` until the build) (or the base commit when there is one part and nothing shared); the rule that only the orchestrator changes a contract; a section "Changes after freeze" (`pending` until the build, then empty none` with the reason; `Plan:` line (and the archived plan path after the build) | ``
- glitch-studio/references/evidence.md:52: absence: if `If it is missing` then `begin at stage 0.`
- glitch-studio/references/model-tiers.md:15: absence: if `If no part is deep tier` then `the default level is fine.`
- glitch-studio/references/model-tiers.md:35: absence: if `If no other family is reachable` then `write that the review is same-family.`
- glitch-studio/references/runtime-models.md:43: error: if `If a check fails` then `write a fix task for the owning lane.`
- glitch-studio/references/study-reference.md:11: absence: if `If no part qualifies` then `` write `Picked: none` and the reason. ``

### Definitions (2)

- glitch-studio/references/evidence.md:11: "done" (explicit): `; the named hard parts; the named outside platforms or APIs; visual part yes or no; runtime model yes or no; the first tier-to-model mapping (tier, model, family, reachable); git state |`
- glitch-studio/references/prove-it.md:3: "done" (explicit): `shown.`

### Terms defined more than one way (1)

- "done": glitch-studio/references/evidence.md:11; glitch-studio/references/prove-it.md:3

### Safety words defined (2)

- glitch-studio/references/evidence.md:11: "done"
- glitch-studio/references/prove-it.md:3: "done"

### Lines that look like committed secrets (values never shown) (0)

None.

### Position of flagged lines in long files (first 10% / middle 80% / last 10%) (0)

None.

### Settings that restrict tools (a fact, never a risk) (0)

None.

### Sentences repeated across files a model reads (17)

- glitch-studio/SKILL.md:31: in 2 files (2 times): `A yes to one item is not a yes to the rest.`
- glitch-studio/SKILL.md:50: in 2 files (2 times): `If it is missing, begin at stage 0.`
- glitch-studio/SKILL.md:52: in 2 files (2 times): `A file without the three ending lines is unfinished.`
- glitch-studio/SKILL.md:54: in 2 files (2 times): `` A `pending` value does not make a file unfinished. ``
- glitch-studio/SKILL.md:56: in 2 files (2 times): `` If any of files 03, 04 and 05 says `Plan: not yet made`, continue the `/glitch-plan` hand-off. ``
- glitch-studio/SKILL.md:59: in 2 files (2 times): `` If file 07 says `Picked: pending`, STOP until the build and every fix task have run. ``
- glitch-studio/SKILL.md:62: in 2 files (2 times): `` If file 08 or 09 says `Picked: pending`, STOP until its fix task has run. ``
- glitch-studio/SKILL.md:65: in 2 files (2 times), flagged B.safety-exception: `Never redo a finished stage, unless the user asks.`
- glitch-studio/SKILL.md:142: in 2 files (2 times): `` The user chooses that level at the stop of `/glitch-plan`. ``
- glitch-studio/SKILL.md:144: in 2 files (2 times): `If no part is deep tier, the default level is fine.`
- glitch-studio/SKILL.md:215: in 3 files (6 times): `` Give the user the task text to paste after `/glitch-plan` in a fresh window. ``
- glitch-studio/SKILL.md:216: in 3 files (6 times): `` Then give the `/glitch-execute` line it prints. ``
- glitch-studio/SKILL.md:235: in 2 files (2 times): `You do not fix product code yourself.`
- glitch-studio/SKILL.md:243: in 2 files (2 times): `Stage 9 — Models inside the product`
- glitch-studio/SKILL.md:254: in 2 files (2 times): `If a check fails, write a fix task for the owning lane.`
- glitch-studio/SKILL.md:260: in 2 files (2 times): `Rerun every failed stage 9 check.`
- glitch-studio/SKILL.md:262: in 2 files (2 times): `Then refresh the stage 8 proof for that part.`

### Will it trigger

What each host does with a skill's, agent's, or command's frontmatter is in `stages/04-phrases/trigger.yaml` (dated, with sources).

1 skill: 1 Claude chooses by its description.

Skill descriptions here take about 60 tokens (240 characters). Claude Code's listing of every installed skill holds about 1% of the context: about 320 tokens at 32,000, 2,000 at 200,000.

- `glitch-studio/SKILL.md` (skill): auto; description 240 characters

Every entry has frontmatter its host reads and follows the rules.

### Ready for any AI

What each AI host reads is in `stages/04-phrases/hosts.yaml` (dated, with sources).

- Claude Code: none of its files (it reads CLAUDE.md, CLAUDE.local.md, .claude/CLAUDE.md; skills in .claude/skills).
- Codex: none of its files (it reads AGENTS.md; skills in .agents/skills).
- Gemini CLI: none of its files (it reads GEMINI.md; skills in .gemini/skills, .agents/skills).
- Cursor: none of its files (it reads .cursor/rules/*.mdc, AGENTS.md, .cursorrules; skills in .agents/skills, .cursor/skills, .claude/skills, .codex/skills).
- GitHub Copilot: none of its files (it reads .github/copilot-instructions.md, .github/instructions/*.instructions.md, AGENTS.md; skills in .github/skills, .claude/skills, .agents/skills).
- Windsurf: none of its files (it reads .windsurf/rules/*.md, AGENTS.md, .windsurfrules).
- Other tools that read AGENTS.md: none of its files (it reads AGENTS.md).

Skills no host reads where they sit (1); a host reads them once they are installed (copied into its skill folder, or added as a plugin):

- `glitch-studio/SKILL.md`

Copies kept for two hosts (0):

- None.

No one-host feature found.

### Current and clean

Facts with locations: Walkdown never says a date is past, a model retired, or a TODO matters. The patterns are in `stages/04-phrases/clean.yaml` (dated, with sources).

No unfinished text, dated claims, pinned model IDs, or older tool names.

## 5 What this touches

Can read your data: no · Can take outside input: no · Can send data out: no Install grants: context-injection.

Validation: PASS (gate 81/81, negative 24/24; measured 2026-11-02, same code and fixtures)

A map of capability, derived from stages 1 to 4; it reaches no verdict. A Bash grant is counted as private-data access and execute posture; on its own it does not count as external communication.

### Trifecta legs

- Can read your data: no (0 citations)
- Can take outside input: no (0 citations)
- Can send data out: no (0 citations)

### Install grants

- context-injection (1 citation)
    - stage 01 struct.description glitch-studio/SKILL.md:3: description: always-on text

### Text in context at load

Bytes at load: descriptions 240 (1, exact).

- glitch-studio/SKILL.md:3: description, 240 bytes, exact

### What it costs and what ships

Expected context: 32,000 tokens (a line for 200,000 beside it). Tokens are estimated from size: about 4 bytes of English text per token; text in other scripts runs high.

- Every session, once installed (descriptions, hooks): 60 tokens, under 1% of 32,000, under 1% of 200,000
- When the largest skill runs: 3,334 tokens, 10% of 32,000, 2% of 200,000
- That skill and everything it names: 8,659 tokens, 27% of 32,000, 4% of 200,000
- The largest is `glitch-studio/SKILL.md`, of 1 skill, agent, or command.

Every skill, agent, or command, by tier (tokens):

- glitch-studio/SKILL.md: runs 3,334, with what it names 8,659, with wildcard loads 8,659

#### Loads into the AI: 8 files, 33.8 KB, 8,659 tokens

- `glitch-studio/SKILL.md`: skills, agents, and commands, 13.0 KB, 3,334 tokens
- `glitch-studio/references/domain-skills.md`: named by a file the AI loads, 1.7 KB, 439 tokens, reached from `glitch-studio/SKILL.md`
- `glitch-studio/references/evidence.md`: named by a file the AI loads, 5.9 KB, 1,509 tokens, reached from `glitch-studio/SKILL.md`
- `glitch-studio/references/model-tiers.md`: named by a file the AI loads, 2.4 KB, 615 tokens, reached from `glitch-studio/SKILL.md`
- `glitch-studio/references/planning-brief.md`: named by a file the AI loads, 4.3 KB, 1,089 tokens, reached from `glitch-studio/SKILL.md`
- `glitch-studio/references/prove-it.md`: named by a file the AI loads, 1.9 KB, 485 tokens, reached from `glitch-studio/SKILL.md`
- `glitch-studio/references/runtime-models.md`: named by a file the AI loads, 2.6 KB, 669 tokens, reached from `glitch-studio/SKILL.md`
- `glitch-studio/references/study-reference.md`: named by a file the AI loads, 2.0 KB, 519 tokens, reached from `glitch-studio/SKILL.md`

#### Used another way: 0 files, 0 bytes, 0 tokens

None.

#### Not used at run time: 4 files, 7.1 KB, 1,812 tokens

- `LICENSE`: written for people, 1.3 KB, 334 tokens
- `README.md`: written for people, 4.2 KB, 1,066 tokens
- `glitch-studio/LICENSE`: written for people, 1.3 KB, 334 tokens
- `capability.json`: nothing points to it, 311 bytes, 78 tokens

### Agent and command posture (0)

None.

### Stated limits: read-only wording a model reads, and what backs it (0)

None.

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

Loops with no stated limit (1): no number of tries, give-up, or time on the line or the next (a limit may be stated elsewhere).

- glitch-studio/references/prove-it.md:22: Repeat until the screenshots match.

## 6 Needs a human read

9 questions (5 labeling, 4 relational). Packet only: no model read (06-packet.md in the run folder).

Validation: PASS (gate 125/125, negative 11/11, recall 0/165; skipped: 124 rows; measured 2026-11-02, same code and fixtures)

Questions a pattern cannot settle, and the answers of the backends named here. Every answer is a located observation; none changes a finding in sections 1 to 5.

- no backend: packet only

### Questions

- glitch-studio/SKILL.md:5 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- glitch-studio/SKILL.md:12 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- glitch-studio/SKILL.md:65 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- glitch-studio/references/evidence.md:20 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- glitch-studio/references/evidence.md:63 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- glitch-studio/references/evidence.md:11 [relational] Against the word's ordinary meaning, what does this definition change about how a model would act on instructions that use the word?
    - soft.read: skipped (no relational backend)
- glitch-studio/references/prove-it.md:3 [relational] Against the word's ordinary meaning, what does this definition change about how a model would act on instructions that use the word?
    - soft.read: skipped (no relational backend)
- glitch-studio/references/evidence.md:11 [relational] The same word is defined differently in these places. Which instructions elsewhere would read differently under each definition?
    - soft.read: skipped (no relational backend)
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
- soft.label skipped for glitch-studio/SKILL.md: no labeling backend
- soft.label skipped for glitch-studio/references/evidence.md: no labeling backend
- soft.read skipped for glitch-studio/references/evidence.md: no relational backend
- soft.read skipped for glitch-studio/references/prove-it.md: no relational backend
- soft.read skipped for None: no relational backend
- (06-soft) skipped: soft.label x5: no labeling backend
- (06-soft) skipped: soft.read x4: no relational backend
- Static examination only. Nothing in the artifact was executed, fetched, or installed.
- Stage 6 answers are located observations from the backends section 6 names; they never change a stage 1 to 5 finding. Hit counts carry a benign share only when stage 6 labels ran.
- Version drift (class 8): each run examines one pinned copy. walkdown.py compares it with the previous run of the same repository when there is one (changes.md next to this report); what the artifact becomes after its next update is seen only by auditing it again.
- English-language scope: the phrase layer is blind to non-English text (stage 2 lists non-Latin runs, and prose passages in another language in Latin script; a short line can slip past that check).
- Stage 4 matches patterns; a payload phrased outside every pattern reads as no hit. A zero here is not safety.

## Recommendations

Conditional on what the skill is for. Unranked, in stage order. None: no finding matched a recommendation template.


What this is not: static examination only. "Clean" means these stages found nothing; it does not mean the artifact is safe. This report offers possible issues with evidence and reaches no verdict. What to do with it is yours to decide.
