# studio: full report

skills/studio | retrieved 2026-11-15 | sha256 d43b11385f0d32013e405250c0da156f5ba35ba57e0e84b509667a707f2be9d0
Run 2026-11-15_d43b113 | Walkdown 0.3.1+blastworks.1
Static examination only. Nothing executed. Every finding below is a location to look at; none is a verdict. Stage order; nothing is ranked.

## 1 What ships

14 files, 2 formats, 0 script languages. 0 hooks (0 host configs). 0 agent or command definitions. 0 platform manifests.

Validation: PASS (gate 26/26, negative 7/7; measured 2026-11-02, same code and fixtures)

Pin: sha256 d43b11385f0d32013e405250c0da156f5ba35ba57e0e84b509667a707f2be9d0, 14 files, 40,685 bytes.

Formats: md 12, (none) 2.

Script languages: none.

### Entry points (2)

- README.md (readme)
- studio/SKILL.md (skill)

### Structural census (0)

None.

### Descriptions (always-on text) (1)

- studio/SKILL.md:3: `Use when someone says "build this the studio way", "run this with an orchestrator and lanes", "spec first, many builders", "split this build into parallel lanes" or "make a big product with many agents".`

### Agent and command tool grants (0)

None.

### Hooks (0)

None.

### Platform manifests (0)

None.

### Licenses (license files and declared license fields) (3)

- LICENSE: MIT; license file, matched by text
- studio/LICENSE: MIT; license file, matched by text
- studio/SKILL.md:4: MIT; declared in license


### What it needs

Programs are the ones Walkdown recognizes (`stages/04-phrases/tools.yaml`); declared means named in a dependency file, a skill's compatibility field, or an install line.

- No program Walkdown recognizes.
- No package imported.

### What ties it to one machine

Nothing found that ties it to one machine.

## 2 What the model actually reads

14/14 files (100.0%). 0 divergences. 0 lines changed by folding. 0 non-Latin runs. 0 passages in a language other than English. Validation INCOMPLETE: see 7.

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

2 entry points. 0 orphans. 54 dangling references (54 code; 1 of them into a folder the repository does not have). 8 dynamic loads: 0 files loaded only through one (named by nothing), 1 file reached only through a mention of a folder or wildcards. Graph incomplete by construction.

Validation: PASS (gate 11/11, negative 7/7; measured 2026-11-02, same code and fixtures)

Depth histogram (static = reached by direct references; dynamic = only through a load: a folder a config names, a code scan, wildcards in an instruction file; mention = only through a folder or wildcards named elsewhere): mention depth 1: 1; static depth 0: 2; static depth 1: 11.

### Entry points used (2)

- README.md (readme)
- studio/SKILL.md (skill)

### Orphans (reachable from no entry point) (0)

None.

### Files loaded only through a dynamic load (named by nothing) (0)

None.

### Files reached only through a mention of a folder or wildcards (not a load) (1)

- studio/LICENSE (depth 1, from README.md)

### Dynamic loads (8)

- README.md:38: directory `studio/` (mention) resolves to 11 files
- README.md:43: directory `studio/` (mention) resolves to 11 files
- prompts.md:5: directory `studio/` (mention) resolves to 11 files
- prompts.md:17: directory `studio/` (mention) resolves to 11 files
- studio/SKILL.md:20: directory `studio/` (mention) resolves to 11 files
- studio/SKILL.md:27: directory `studio/` (mention) resolves to 11 files
- studio/references/evidence.md:9: directory `studio/` (mention) resolves to 11 files
- studio/references/evidence.md:59: directory `studio/` (mention) resolves to 11 files

### On disk, left out of the manifest (a host that finds components by folder may still load them) (0)

None.

### Dangling references (53)

- README.md:43: `studio/00-frame.md` (code)
- README.md:43: `studio/09-runtime-models.md` (code)
- prompts.md:31: `studio/00-frame.md` (code)
- prompts.md:42: `THIRD_PARTY_NOTICES.md` (code)
- prompts.md:43: `studio/01-study-reference.md` (code)
- prompts.md:54: `studio/02-domain-skills.md` (code)
- prompts.md:66: `studio/03-parts-and-specs.md` (code)
- prompts.md:77: `studio/04-contracts.md` (code)
- prompts.md:87: `studio/05-lanes.md` (code)
- prompts.md:98: `studio/06-model-tiers.md` (code)
- prompts.md:110: `studio/07-review-and-integrate.md` (code)
- prompts.md:118: `studio/08-proof.md` (code)
- prompts.md:125: `studio/09-runtime-models.md` (code)
- studio/SKILL.md:43: `studio/00-frame.md` (code)
- studio/SKILL.md:52: `THIRD_PARTY_NOTICES.md` (code)
- studio/SKILL.md:52: `studio/01-study-reference.md` (code)
- studio/SKILL.md:58: `studio/02-domain-skills.md` (code)
- studio/SKILL.md:66: `studio/03-parts-and-specs.md` (code)
- studio/SKILL.md:75: `studio/04-contracts.md` (code)
- studio/SKILL.md:86: `studio/05-lanes.md` (code)
- studio/SKILL.md:93: `studio/06-model-tiers.md` (code)
- studio/SKILL.md:103: `studio/07-review-and-integrate.md` (code)
- studio/SKILL.md:112: `studio/08-proof.md` (code)
- studio/SKILL.md:118: `studio/09-runtime-models.md` (code)
- studio/SKILL.md:124: `studio/08-proof.md` (code)
- studio/references/domain-skills.md:42: `studio/02-domain-skills.md` (code)
- studio/references/evidence.md:11: `studio/00-frame.md` (code)
- studio/references/evidence.md:12: `studio/01-study-reference.md` (code)
- studio/references/evidence.md:13: `studio/02-domain-skills.md` (code)
- studio/references/evidence.md:14: `studio/03-parts-and-specs.md` (code)
- studio/references/evidence.md:15: `studio/04-contracts.md` (code)
- studio/references/evidence.md:16: `studio/05-lanes.md` (code)
- studio/references/evidence.md:17: `studio/06-model-tiers.md` (code)
- studio/references/evidence.md:18: `studio/07-review-and-integrate.md` (code)
- studio/references/evidence.md:19: `studio/08-proof.md` (code)
- studio/references/evidence.md:20: `studio/09-runtime-models.md` (code)
- studio/references/evidence.md:72: `studio/02-domain-skills.md` (code)
- studio/references/evidence.md:84: `studio/09-runtime-models.md` (code)
- studio/references/lanes.md:45: `studio/04-contracts.md` (code)
- studio/references/lanes.md:48: `studio/05-lanes.md` (code)
- studio/references/model-tiers.md:18: `studio/06-model-tiers.md` (code)
- studio/references/model-tiers.md:28: `studio/03-parts-and-specs.md` (code)
- studio/references/model-tiers.md:39: `studio/06-model-tiers.md` (code)
- studio/references/prove-it.md:37: `studio/08-proof.md` (code)
- studio/references/review-and-integrate.md:47: `studio/07-review-and-integrate.md` (code)
- studio/references/runtime-models.md:6: `studio/09-runtime-models.md` (code)
- studio/references/runtime-models.md:52: `studio/09-runtime-models.md` (code)
- studio/references/specs-and-contracts.md:39: `studio/03-parts-and-specs.md` (code)
- studio/references/specs-and-contracts.md:57: `contracts/` (code)
- studio/references/specs-and-contracts.md:79: `studio/04-contracts.md` (code)
- studio/references/study-reference.md:23: `THIRD_PARTY_NOTICES.md` (code)
- studio/references/study-reference.md:33: `studio/01-study-reference.md` (code)
- studio/references/study-reference.md:38: `THIRD_PARTY_NOTICES.md` (code)

### Dangling references into a folder the repository does not have (often one the workflow creates when it runs) (1)

- studio/references/evidence.md:77: `skills/weather/SKILL.md` (code)

### Not scanned for references (0)

None.

### Reference depth, directly reached files (13)

- LICENSE: depth 1, from README.md
- README.md: depth 0
- prompts.md: depth 1, from README.md
- studio/SKILL.md: depth 0
- studio/references/domain-skills.md: depth 1, from studio/SKILL.md
- studio/references/evidence.md: depth 1, from README.md
- studio/references/lanes.md: depth 1, from studio/SKILL.md
- studio/references/model-tiers.md: depth 1, from studio/SKILL.md
- studio/references/prove-it.md: depth 1, from studio/SKILL.md
- studio/references/review-and-integrate.md: depth 1, from studio/SKILL.md
- studio/references/runtime-models.md: depth 1, from studio/SKILL.md
- studio/references/specs-and-contracts.md: depth 1, from studio/SKILL.md
- studio/references/study-reference.md: depth 1, from studio/SKILL.md

## 4 What the text asks for

4a 0 · 4b 11 · 4c 3 · 4d 0 hits on 14 lines (8 read by a model, 6 human-facing); benign share not measured (stage 6 labels did not run). Hosts: 3, 0 not named in the docs. Confirm-first or prohibited actions in instruction text: 0, 0 with no confirmation step, 0 stated as prohibitions. Conditionals: 18 absence, 3 harness, 2 error. Definitions: 3, 0 conflicts, 3 safety-word definitions. Long files with flagged lines: 0, 0 with some past the reader window. Sentences repeated across files: 9, 1 flagged. Lines that look like committed secrets: 0.

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

#### phrase.L.override (3 lines)

Patterns: L.forget 2, L.skip-confirm 1

- README.md:52 [L.forget] (human): `- A way to start fresh sub-agents or fresh sessions for the lanes. Without it, the skill still works, but you run each lane yourself in a new chat.`
- studio/SKILL.md:5 [L.forget] (model): `compatibility: The host loads skills, runs shell commands and git, and can start fresh sub-agents or fresh sessions. It needs no particular model.`
- studio/references/runtime-models.md:41 [L.skip-confirm] (model): `Do not ask a model to grade its own output.`

#### phrase.A.consent (0 lines)

None.

#### phrase.B.defs (7 lines)

Patterns: B.means 1, B.safety-adjective 1, B.safety-exception 5

- README.md:33 [B.means] (human): `8. **Prove it.** Done means demonstrated: screenshots at fixed sizes for what you see, a real run for everything else.`
- README.md:46 [B.safety-exception] (human): `It never redoes a stage whose file exists unless you ask.`
- prompts.md:21 [B.safety-exception] (subagent): `Do not redo a stage whose file exists unless I ask.`
- studio/SKILL.md:30 [B.safety-exception] (model): `Never redo a stage whose file exists unless the user asks.`
- studio/SKILL.md:100 [B.safety-adjective] (model): `` Ask a read-only critic to read it too. Use another model family if one is reachable.\nIf none is reachable, write that the review is same-family. STOP and let the user decide.\nMerge lanes one at a time. Run the tests after each merge.\nWrite `studio/07-review-and-integrate.md`. ``
- studio/references/evidence.md:62 [B.safety-exception] (model): `4. Never redo a stage whose file exists unless the user asks.`
- studio/references/review-and-integrate.md:18 [B.safety-exception] (model): `Do not fix a lane's work yourself unless the fix is a one-line integration change.`

#### phrase.H.anti-review (0 lines)

None.

#### phrase.I.conditional (1 line)

Patterns: I.environment 1

- studio/SKILL.md:44 [I.environment] (model): `STOP if the project is not in git. Ask the user to start a repository.`

### 4c Changing the environment

#### phrase.E.perms (0 lines)

None.

#### phrase.C.second-order (0 lines)

None.

#### phrase.D.trust (0 lines)

None.

#### phrase.E.env (1 line)

Patterns: E.persist-target 1, E.self-install 1

- README.md:38 [E.self-install, E.persist-target] (human): `` **An agent that loads skills:** copy the inner [`studio/`](studio/) folder into your agent's skills folder (for example `~/.claude/skills/`), then say "build this the studio way" and describe the product. ``

#### phrase.J.prohibited (2 lines)

Patterns: J.confirm-first 2

- LICENSE:9 [J.confirm-first] (human): `to use, copy, modify, merge, publish, distribute, sublicense, and/or sell`
- studio/LICENSE:9 [J.confirm-first] (human): `to use, copy, modify, merge, publish, distribute, sublicense, and/or sell`

### 4d Talking to the human

#### phrase.G.human (0 lines)

None.

### Tables

Hosts: 3, 0 not named in the docs. Confirm-first or prohibited actions in instruction text: 0, 0 with no confirmation step, 0 stated as prohibitions. Conditionals: 18 absence, 3 harness, 2 error. Definitions: 3, 0 conflicts, 3 safety-word definitions. Long files with flagged lines: 0, 0 with some past the reader window. Sentences repeated across files: 9, 1 flagged. Lines that look like committed secrets: 0.

### Endpoints (hosts named anywhere; documented = named in the docs) (3)

- blastworks.ai: documented, other; 3 docs; first at LICENSE:3
- chatdom.io: documented, other; 2 instructions, 4 docs; first at LICENSE:26
- devpost.com: documented, other; 2 instructions, 4 docs; first at LICENSE:26

### Confirm-first and prohibited actions in instruction text (0)

None.

### Conditionals (23)

- prompts.md:18: absence: if `If it does not exist` then `tell me we start at stage 0.`
- prompts.md:44: absence: if `If no part needs this` then `` write the file with `Picked: none`. ``
- prompts.md:51: absence: if `If none exists` then `write a small skill before any product code: auth and token types, the endpoints the product uses, scopes, rate limits, payload examples, known traps.`
- prompts.md:55: harness: if `If there is no outside platform` then `` write the file with `Picked: none`. ``
- prompts.md:97: absence: if `If no second family is reachable` then `say the review will be same-family and ask me.`
- prompts.md:125: absence: if `If the product calls no model at runtime` then `` write `studio/09-runtime-models.md` with `Picked: none` and the reason. ``
- studio/SKILL.md:21: error: if `If a check did not run` then `say so in the file.`
- studio/SKILL.md:28: absence: if `If it does not exist` then `begin at stage 0.`
- studio/SKILL.md:101: absence: if `If none is reachable` then `write that the review is same-family.`
- studio/references/domain-skills.md:4: harness: if `before any product code touches that platform.` then `Give it a small skill that holds the facts,`
- studio/references/domain-skills.md:17: absence: if `If none exists` then `write a small domain skill.`
- studio/references/domain-skills.md:40: harness: if `When the platform changes` then `update the skill.`
- studio/references/evidence.md:65: absence: if `If the folder is missing` then `begin at stage 0.`
- studio/references/evidence.md:66: absence: if `If a file exists but lacks the three ending lines` then `treat it as unfinished and finish it.`
- studio/references/lanes.md:35: absence: if `If a contract is wrong or missing` then `stop and ask the orchestrator.`
- studio/references/model-tiers.md:19: absence: if `If a tier has no fitting model` then `say so.`
- studio/references/model-tiers.md:36: absence: if `If no` then `write "no second family reachable" and that the review is same-family.`
- studio/references/prove-it.md:13: absence: if `If none exists` then `write a short one now with the user: colours, fonts, mood, screen sizes.`
- studio/references/review-and-integrate.md:27: absence: if `If none is reachable` then `write in the evidence file that the review is same-family, and ask the user to decide.`
- studio/references/review-and-integrate.md:39: error: if `If tests fail` then `find the cause.`
- studio/references/runtime-models.md:6: absence: if `If the product calls no model at runtime` then `` write `studio/09-runtime-models.md` with `Picked: none` and the reason in `Why:`. ``
- studio/references/specs-and-contracts.md:83: absence: if `if none` then `Add a section "Changes after freeze", empty otherwise each change with its reason and the lanes told.`
- studio/references/study-reference.md:12: absence: if `If no part qualifies` then `` write the evidence file with `Picked: none`. ``

### Definitions (3)

- prompts.md:115: "done" (explicit): `demonstrated.`
- studio/SKILL.md:108: "done" (explicit): `demonstrated.`
- studio/references/prove-it.md:3: "done" (explicit): `demonstrated.`

### Terms defined more than one way (0)

None.

### Safety words defined (3)

- prompts.md:115: "done"
- studio/SKILL.md:108: "done"
- studio/references/prove-it.md:3: "done"

### Lines that look like committed secrets (values never shown) (0)

None.

### Position of flagged lines in long files (first 10% / middle 80% / last 10%) (0)

None.

### Settings that restrict tools (a fact, never a risk) (0)

None.

### Sentences repeated across files a model reads (9)

- prompts.md:9: in 2 files (2 times): `The method comes from the Chatdom.io build write-up (TwitchCon 2026 hackathon, 1st place): https://devpost.com/software/chatdom-io.`
- prompts.md:50: in 2 files (2 times): `For each one, look for an existing skill first.`
- prompts.md:60: in 2 files (2 times): `Split the product into separable parts.`
- prompts.md:63: in 2 files (2 times): `One task is one check and one commit.`
- prompts.md:73: in 2 files (2 times): `Add a small check that the contracts compile or validate.`
- prompts.md:74: in 2 files (2 times): `Commit them before any lane starts.`
- prompts.md:93: in 2 files (2 times): `List the models you can actually reach in this session.`
- studio/SKILL.md:30: in 2 files (2 times), flagged B.safety-exception: `Never redo a stage whose file exists unless the user asks.`
- studio/SKILL.md:102: in 2 files (2 times): `Merge lanes one at a time.`

### Will it trigger

What each host does with a skill's, agent's, or command's frontmatter is in `stages/04-phrases/trigger.yaml` (dated, with sources).

1 skill: 1 Claude chooses by its description.

Skill descriptions here take about 51 tokens (203 characters). Claude Code's listing of every installed skill holds about 1% of the context: about 320 tokens at 32,000, 2,000 at 200,000.

- `studio/SKILL.md` (skill): auto; description 203 characters

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

- `studio/SKILL.md`

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
    - stage 01 struct.description studio/SKILL.md:3: description: always-on text

### Text in context at load

Bytes at load: descriptions 203 (1, exact).

- studio/SKILL.md:3: description, 203 bytes, exact

### What it costs and what ships

Expected context: 32,000 tokens (a line for 200,000 beside it). Tokens are estimated from size: about 4 bytes of English text per token; text in other scripts runs high.

- Every session, once installed (descriptions, hooks): 51 tokens, under 1% of 32,000, under 1% of 200,000
- When the largest skill runs: 1,382 tokens, 4% of 32,000, under 1% of 200,000
- That skill and everything it names: 6,736 tokens, 21% of 32,000, 3% of 200,000
- With its wildcard and folder loads: 7,074 tokens, 22% of 32,000, 4% of 200,000
- The largest is `studio/SKILL.md`, of 1 skill, agent, or command.

Every skill, agent, or command, by tier (tokens):

- studio/SKILL.md: runs 1,382, with what it names 6,736, with wildcard loads 7,074

#### Loads into the AI: 11 files, 27.6 KB, 7,074 tokens

- `studio/SKILL.md`: skills, agents, and commands, 5.4 KB, 1,382 tokens
- `studio/references/domain-skills.md`: named by a file the AI loads, 2.2 KB, 559 tokens, reached from `studio/SKILL.md`
- `studio/references/evidence.md`: named by a file the AI loads, 3.1 KB, 794 tokens, reached from `studio/SKILL.md`
- `studio/references/lanes.md`: named by a file the AI loads, 1.9 KB, 493 tokens, reached from `studio/SKILL.md`
- `studio/references/model-tiers.md`: named by a file the AI loads, 1.9 KB, 484 tokens, reached from `studio/SKILL.md`
- `studio/references/prove-it.md`: named by a file the AI loads, 1.9 KB, 481 tokens, reached from `studio/SKILL.md`
- `studio/references/review-and-integrate.md`: named by a file the AI loads, 2.3 KB, 582 tokens, reached from `studio/SKILL.md`
- `studio/references/runtime-models.md`: named by a file the AI loads, 2.3 KB, 580 tokens, reached from `studio/SKILL.md`
- `studio/references/specs-and-contracts.md`: named by a file the AI loads, 3.3 KB, 835 tokens, reached from `studio/SKILL.md`
- `studio/references/study-reference.md`: named by a file the AI loads, 2.1 KB, 546 tokens, reached from `studio/SKILL.md`
- `studio/LICENSE`: reached only by a wildcard or a folder read, 1.3 KB, 338 tokens, reached from `studio/SKILL.md`

#### Used another way: 0 files, 0 bytes, 0 tokens

None.

#### Not used at run time: 3 files, 12.1 KB, 3,102 tokens

- `LICENSE`: written for people, 1.3 KB, 338 tokens
- `README.md`: written for people, 3.9 KB, 990 tokens
- `prompts.md`: nothing points to it, 6.9 KB, 1,774 tokens

### Agent and command posture (0)

None.

### Stated limits: read-only wording a model reads, and what backs it (1)

- studio/SKILL.md:100: stated; Stated in the text; Walkdown found no tool setting that enforces it (studio/SKILL.md has no tools list). `` Ask a read-only critic to read it too. Use another model family if one is reachable.\nIf none is reachable, write that the review is same-family. STOP and let the user decide.\nMerge lanes one at a time. Run the tests after each merge.\nWrite `studio/07-review-and-integrate.md`. ``

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

- studio/references/lanes.md:20: The lane repeats this until the task list is done:

## 6 Needs a human read

12 questions (8 labeling, 4 relational). Packet only: no model read (06-packet.md in the run folder).

Validation: PASS (gate 125/125, negative 11/11, recall 0/165; skipped: 124 rows; measured 2026-11-02, same code and fixtures)

Questions a pattern cannot settle, and the answers of the backends named here. Every answer is a located observation; none changes a finding in sections 1 to 5.

- no backend: packet only

### Questions

- prompts.md:21 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- studio/SKILL.md:5 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- studio/SKILL.md:30 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- studio/SKILL.md:44 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- studio/SKILL.md:100 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- studio/references/evidence.md:62 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- studio/references/review-and-integrate.md:18 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- studio/references/runtime-models.md:41 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- prompts.md:115 [relational] Against the word's ordinary meaning, what does this definition change about how a model would act on instructions that use the word?
    - soft.read: skipped (no relational backend)
- studio/SKILL.md:108 [relational] Against the word's ordinary meaning, what does this definition change about how a model would act on instructions that use the word?
    - soft.read: skipped (no relational backend)
- studio/references/prove-it.md:3 [relational] Against the word's ordinary meaning, what does this definition change about how a model would act on instructions that use the word?
    - soft.read: skipped (no relational backend)
- (repo) [relational] Describe, as capability and not intent, how these three capabilities could combine in this artifact, citing the evidence given.
    - soft.read: skipped (no relational backend)

## 7 Not examined

- Stage 02-reader validation INCOMPLETE (gate 20/31, negative 22/24, recall 1/1; skipped: 13 rows; measured 2026-11-02, same code and fixtures): its zeros are not validated for the skipped checks.
- (02-reader) tesseract not installed (no tesseract binary, no pytesseract): images and PDF pages are skipped for OCR (read.divergence skip); images and PDFs with no text layer are listed as read.unread
- (02-reader) html render: playwright not installed: HTML files are read with static style only (read.divergence skip, carrier rendered)
- (02-reader) v1 limit: the language check (read.language) reads prose only: Markdown, plain text, PDF, DOCX, and OCR text; Markdown code blocks, comments in code, config values, and HTML are not checked for language, and a paragraph under five words is too short to judge
- (03-graph) v1 limit: manifest versus disk compares skills, agents, and commands, and only the kinds a manifest names; a manifest that names none relies on its folders and is not compared, and plugins a marketplace leaves out are not compared
- (03-graph) graph incomplete by construction: 8 dynamic load(s); targets resolved as of review time only
- (04-phrases) limit: files that do not decode as text (PDF, DOCX, images) are scanned from stage 2's extracted text, phrase patterns only
- (05-capability) stage 5 limit: a Bash grant is recorded under private-data and as execute posture, never as external-comms; Bash can reach the network, as can every shell, so this map does not count it there
- (05-capability) stage 5 limit: hook bytes are an estimate from the sizes of files the hook script references (stage 3 static edges); hooks are never run to measure their output
- soft.label skipped for prompts.md: no labeling backend
- soft.label skipped for studio/SKILL.md: no labeling backend
- soft.label skipped for studio/references/evidence.md: no labeling backend
- soft.label skipped for studio/references/review-and-integrate.md: no labeling backend
- soft.label skipped for studio/references/runtime-models.md: no labeling backend
- soft.read skipped for prompts.md: no relational backend
- soft.read skipped for studio/SKILL.md: no relational backend
- soft.read skipped for studio/references/prove-it.md: no relational backend
- soft.read skipped for None: no relational backend
- (06-soft) skipped: soft.label x8: no labeling backend
- (06-soft) skipped: soft.read x4: no relational backend
- Static examination only. Nothing in the artifact was executed, fetched, or installed.
- Stage 6 answers are located observations from the backends section 6 names; they never change a stage 1 to 5 finding. Hit counts carry a benign share only when stage 6 labels ran.
- Version drift (class 8): each run examines one pinned copy. walkdown.py compares it with the previous run of the same repository when there is one (changes.md next to this report); what the artifact becomes after its next update is seen only by auditing it again.
- English-language scope: the phrase layer is blind to non-English text (stage 2 lists non-Latin runs, and prose passages in another language in Latin script; a short line can slip past that check).
- Stage 4 matches patterns; a payload phrased outside every pattern reads as no hit. A zero here is not safety.

## Recommendations

Conditional on what the skill is for. Unranked, in stage order. None: no finding matched a recommendation template.


What this is not: static examination only. "Clean" means these stages found nothing; it does not mean the artifact is safe. This report offers possible issues with evidence and reaches no verdict. What to do with it is yours to decide.
