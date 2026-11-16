# rocket-fuel: full report

/opt/glitch/workspaces/tools--publish-rocket-fuel/skills/rocket-fuel | retrieved 2026-11-09 | sha256 cb838e6fbce026fbcdc7b0271f4a582efe7544e5014ddb5bc7966abd539161c9
Run 2026-11-09_cb838e6 | Walkdown 0.3.1+blastworks.1
Static examination only. Nothing executed. Every finding below is a location to look at; none is a verdict. Stage order; nothing is ranked.

## 1 What ships

4 files, 2 formats, 0 script languages. 0 hooks (0 host configs). 1 agent or command definition. 0 platform manifests.

Validation: PASS (gate 26/26, negative 7/7; measured 2026-11-09, same code and fixtures)

Pin: sha256 cb838e6fbce026fbcdc7b0271f4a582efe7544e5014ddb5bc7966abd539161c9, 4 files, 10,371 bytes.

Formats: md 3, (none) 1.

Script languages: none.

### Entry points (2)

- README.md (readme)
- SKILL.md (skill)

### Structural census (0)

None.

### Descriptions (always-on text) (1)

- SKILL.md:3: `A collaboration protocol for founder-led AI work, adapted from the Wickman/Winters Visionary/Integrator model. Invoke only when the Operator explicitly calls it. On invocation, recommend BASIC or FULL and ask the Operator which convergence budget to use.`

### Agent and command tool grants (1)

- SKILL.md:7: tools ['Read', 'Bash', 'Grep', 'Glob']; job `A collaboration protocol for founder-led AI work, adapted from the Wickman/Winters Visionary/Integrator model. Invoke only when the Operator explicitly calls it. On invocation, recommend BASIC or FULL and ask the Operator which convergence budget to use.`

### Hooks (0)

None.

### Platform manifests (0)

None.

### Licenses (license files and declared license fields) (2)

- LICENSE: MIT; license file, matched by text
- SKILL.md:4: MIT; declared in license


### What it needs

Programs are the ones Walkdown recognizes (`stages/04-phrases/tools.yaml`); declared means named in a dependency file, a skill's compatibility field, or an install line.

- No program Walkdown recognizes.
- No package imported.

### What ties it to one machine

Nothing found that ties it to one machine.

## 2 What the model actually reads

4/4 files (100.0%). 0 divergences. 1 line changed by folding. 0 non-Latin runs. 0 passages in a language other than English. Validation INCOMPLETE: see 7.

Validation: INCOMPLETE (gate 20/31, negative 22/24, recall 1/1; skipped: 13 rows; measured 2026-11-09, same code and fixtures)

### Divergences (reading A versus reading B) (0)

None.

### Lines changed by folding (1)

- SKILL.md:101: removed or replaced U+2013

### Non-Latin script runs (0)

None.

### Passages in a language other than English (Latin script) (0)

None.

### Metadata carrying text (0)

None.

### Unread (0)

None.

## 3 What loads what

2 entry points. 0 orphans. 0 dangling references. 0 dynamic loads: 0 files loaded only through one (named by nothing), 0 files reached only through a mention of a folder or wildcards.

Validation: PASS (gate 11/11, negative 7/7; measured 2026-11-09, same code and fixtures)

Depth histogram (static = reached by direct references; dynamic = only through a load: a folder a config names, a code scan, wildcards in an instruction file; mention = only through a folder or wildcards named elsewhere): static depth 0: 2; static depth 1: 2.

### Entry points used (2)

- README.md (readme)
- SKILL.md (skill)

### Orphans (reachable from no entry point) (0)

None.

### Files loaded only through a dynamic load (named by nothing) (0)

None.

### Files reached only through a mention of a folder or wildcards (not a load) (0)

None.

### Dynamic loads (0)

None.

### On disk, left out of the manifest (a host that finds components by folder may still load them) (0)

None.

### Dangling references (0)

None.

### Dangling references into a folder the repository does not have (often one the workflow creates when it runs) (0)

None.

### Not scanned for references (0)

None.

### Reference depth, directly reached files (4)

- LICENSE: depth 1, from README.md
- NOTICE.md: depth 1, from README.md
- README.md: depth 0
- SKILL.md: depth 0

## 4 What the text asks for

4a 0 · 4b 0 · 4c 2 · 4d 0 hits on 2 lines (1 read by a model, 1 human-facing); benign share not measured (stage 6 labels did not run). Hosts: 0, 0 not named in the docs. Confirm-first or prohibited actions in instruction text: 0, 0 with no confirmation step, 0 stated as prohibitions. Conditionals: 1 absence. Definitions: 0, 0 conflicts, 0 safety-word definitions. Long files with flagged lines: 0, 0 with some past the reader window. Sentences repeated across files: 0, 0 flagged. Lines that look like committed secrets: 0.

Validation: PASS (gate 153/153, negative 121/121, recall 43/43; measured 2026-11-09, same code and fixtures)

Every hit is a locator. Benign share not measured here; stage 6 labels, when run, read the lines a model sees (section 6). Audience is who the file addresses, by path.

### 4a Reaching out

#### phrase.K.exfil (0 lines)

None.

#### phrase.creds (0 lines)

None.

#### phrase.remote-load (0 lines)

None.

### 4b Taking the wheel

#### phrase.L.override (0 lines)

None.

#### phrase.A.consent (0 lines)

None.

#### phrase.B.defs (0 lines)

None.

#### phrase.H.anti-review (0 lines)

None.

#### phrase.I.conditional (0 lines)

None.

### 4c Changing the environment

#### phrase.E.perms (0 lines)

None.

#### phrase.C.second-order (1 line)

Patterns: C.frontmatter-grant 1

- SKILL.md:7 [C.frontmatter-grant] (model): `allowed-tools: Read, Bash, Grep, Glob`

#### phrase.D.trust (0 lines)

None.

#### phrase.E.env (0 lines)

None.

#### phrase.J.prohibited (1 line)

Patterns: J.confirm-first 1

- LICENSE:8 [J.confirm-first] (human): `to use, copy, modify, merge, publish, distribute, sublicense, and/or sell`

### 4d Talking to the human

#### phrase.G.human (0 lines)

None.

### Tables

Hosts: 0, 0 not named in the docs. Confirm-first or prohibited actions in instruction text: 0, 0 with no confirmation step, 0 stated as prohibitions. Conditionals: 1 absence. Definitions: 0, 0 conflicts, 0 safety-word definitions. Long files with flagged lines: 0, 0 with some past the reader window. Sentences repeated across files: 0, 0 flagged. Lines that look like committed secrets: 0.

### Endpoints (hosts named anywhere; documented = named in the docs) (0)

None.

### Confirm-first and prohibited actions in instruction text (0)

None.

### Conditionals (1)

- SKILL.md:102: absence: if `After three NO-SHIPs` then `swap seats for up to two more rounds.** The previous builder authors a complete alternative honoring every locked Founder ruling; the previous strategist becomes the adversary.`

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

Skill descriptions here take about 64 tokens (254 characters). Claude Code's listing of every installed skill holds about 1% of the context: about 320 tokens at 32,000, 2,000 at 200,000.

- `SKILL.md` (skill): auto; description 254 characters

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

- `SKILL.md`

Copies kept for two hosts (0):

- None.

No one-host feature found.

### Current and clean

Facts with locations: Walkdown never says a date is past, a model retired, or a TODO matters. The patterns are in `stages/04-phrases/clean.yaml` (dated, with sources).

No unfinished text, dated claims, pinned model IDs, or older tool names.

## 5 What this touches

Can read your data: yes · Can take outside input: no · Can send data out: no Install grants: context-injection.

Validation: PASS (gate 81/81, negative 24/24; measured 2026-11-09, same code and fixtures)

A map of capability, derived from stages 1 to 4; it reaches no verdict. A Bash grant is counted as private-data access and execute posture; on its own it does not count as external communication.

### Trifecta legs

- Can read your data: yes (1 citation)
    - stage 01 struct.agent-tools SKILL.md:7: tool grant: Read, Grep, Glob, Bash
- Can take outside input: no (0 citations)
- Can send data out: no (0 citations)

### Install grants

- context-injection (1 citation)
    - stage 01 struct.description SKILL.md:3: description: always-on text

### Text in context at load

Bytes at load: descriptions 254 (1, exact).

- SKILL.md:3: description, 254 bytes, exact

### What it costs and what ships

Expected context: 32,000 tokens (a line for 200,000 beside it). Tokens are estimated from size: about 4 bytes of English text per token; text in other scripts runs high.

- Every session, once installed (descriptions, hooks): 64 tokens, under 1% of 32,000, under 1% of 200,000
- When the largest skill runs: 2,042 tokens, 6% of 32,000, 1% of 200,000
- That skill and everything it names: 2,042 tokens, 6% of 32,000, 1% of 200,000
- The largest is `SKILL.md`, of 1 skill, agent, or command.

Every skill, agent, or command, by tier (tokens):

- SKILL.md: runs 2,042, with what it names 2,042, with wildcard loads 2,042

#### Loads into the AI: 1 file, 8.0 KB, 2,042 tokens

- `SKILL.md`: skills, agents, and commands, 8.0 KB, 2,042 tokens

#### Used another way: 0 files, 0 bytes, 0 tokens

None.

#### Not used at run time: 3 files, 2.2 KB, 552 tokens

- `LICENSE`: written for people, 1.0 KB, 268 tokens
- `NOTICE.md`: written for people, 316 bytes, 79 tokens
- `README.md`: written for people, 820 bytes, 205 tokens

### Agent and command posture (1)

- SKILL.md:7: execute, read; job `A collaboration protocol for founder-led AI work, adapted from the Wickman/Winters Visionary/Integrator model. Invoke only when the Operator explicitly calls it. On invocation, recommend BASIC or FULL and ask the Operator which convergence budget to use.`

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

Entries checked: 1 (1 with a tools list, 0 agents with none). The yardstick is each entry's own words, over what it reads, against its own grants; families and hook facts are in `stages/05-capability/fit.yaml`, the cues in `stages/04-phrases/asks.yaml`.

Tools granted and never used (1): nothing the entry reads asks for the work they do (a skill's are pre-approved, never required).

- SKILL.md:7: Bash: pre-approved, and nothing it reads asks for running commands

## 6 Needs a human read

2 questions (1 labeling, 1 relational). Packet only: no model read (06-packet.md in the run folder).

Validation: PASS (gate 125/125, negative 11/11, recall 0/165; skipped: 124 rows; measured 2026-11-09, same code and fixtures)

Questions a pattern cannot settle, and the answers of the backends named here. Every answer is a located observation; none changes a finding in sections 1 to 5.

- no backend: packet only

### Questions

- SKILL.md:7 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- (repo) [relational] Describe, as capability and not intent, how these three capabilities could combine in this artifact, citing the evidence given.
    - soft.read: skipped (no relational backend)

## 7 Not examined

- Stage 02-reader validation INCOMPLETE (gate 20/31, negative 22/24, recall 1/1; skipped: 13 rows; measured 2026-11-09, same code and fixtures): its zeros are not validated for the skipped checks.
- (02-reader) tesseract not installed (no tesseract binary, no pytesseract): images and PDF pages are skipped for OCR (read.divergence skip); images and PDFs with no text layer are listed as read.unread
- (02-reader) html render: playwright not installed: HTML files are read with static style only (read.divergence skip, carrier rendered)
- (02-reader) v1 limit: the language check (read.language) reads prose only: Markdown, plain text, PDF, DOCX, and OCR text; Markdown code blocks, comments in code, config values, and HTML are not checked for language, and a paragraph under five words is too short to judge
- (03-graph) v1 limit: manifest versus disk compares skills, agents, and commands, and only the kinds a manifest names; a manifest that names none relies on its folders and is not compared, and plugins a marketplace leaves out are not compared
- (04-phrases) limit: files that do not decode as text (PDF, DOCX, images) are scanned from stage 2's extracted text, phrase patterns only
- (05-capability) stage 5 limit: a Bash grant is recorded under private-data and as execute posture, never as external-comms; Bash can reach the network, as can every shell, so this map does not count it there
- (05-capability) stage 5 limit: hook bytes are an estimate from the sizes of files the hook script references (stage 3 static edges); hooks are never run to measure their output
- soft.label skipped for SKILL.md: no labeling backend
- soft.read skipped for None: no relational backend
- (06-soft) skipped: soft.label x1: no labeling backend
- (06-soft) skipped: soft.read x1: no relational backend
- Static examination only. Nothing in the artifact was executed, fetched, or installed.
- Stage 6 answers are located observations from the backends section 6 names; they never change a stage 1 to 5 finding. Hit counts carry a benign share only when stage 6 labels ran.
- Version drift (class 8): each run examines one pinned copy. walkdown.py compares it with the previous run of the same repository when there is one (changes.md next to this report); what the artifact becomes after its next update is seen only by auditing it again.
- English-language scope: the phrase layer is blind to non-English text (stage 2 lists non-Latin runs, and prose passages in another language in Latin script; a short line can slip past that check).
- Stage 4 matches patterns; a payload phrased outside every pattern reads as no hit. A zero here is not safety.

## Recommendations

Conditional on what the skill is for. Unranked, in stage order. None: no finding matched a recommendation template.


What this is not: static examination only. "Clean" means these stages found nothing; it does not mean the artifact is safe. This report offers possible issues with evidence and reaches no verdict. What to do with it is yours to decide.
