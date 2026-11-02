# dangerprotocol: full report

https://github.com/blastworksai/tools/tree/main/skills/dangerprotocol | retrieved 2026-11-02 | sha256 6c2dee6583cc187a099c503a0c99a288bbe891944f08007fccabdf2a1b539697
Run 2026-11-02_6c2dee6 | Walkdown 0.3.1+blastworks.1
Static examination only. Nothing executed. Every finding below is a location to look at; none is a verdict. Stage order; nothing is ranked.

## 1 What ships

2 files, 1 format, 0 script languages. 0 hooks (0 host configs). 1 agent or command definition. 0 platform manifests.

Validation: PASS (gate 26/26, negative 7/7; measured 2026-11-02, same code and fixtures)

Pin: sha256 6c2dee6583cc187a099c503a0c99a288bbe891944f08007fccabdf2a1b539697, 2 files, 19,039 bytes.

Formats: md 2.

Script languages: none.

### Entry points (2)

- README.md (readme)
- SKILL.md (skill)

### Structural census (0)

None.

### Descriptions (always-on text) (1)

- SKILL.md:3: `Use before you install, run or trust a GitHub repo you don't know - "danger protocol this repo", "is this repo safe", "check this repo for malware or spyware". A read-only review in quarantine - nothing from the repo is ever run - across build scripts, runtime behaviour, network traffic and hidden payloads, ending in one verdict that says what it could not prove. Not a guarantee.`

### Agent and command tool grants (1)

- SKILL.md:5: tools ['Read', 'Grep', 'Glob', 'Bash', 'Agent']; job `Use before you install, run or trust a GitHub repo you don't know - "danger protocol this repo", "is this repo safe", "check this repo for malware or spyware". A read-only review in quarantine - nothing from the repo is ever run - across build scripts, runtime behaviour, network traffic and hidden payloads, ending in one verdict that says what it could not prove. Not a guarantee.`

### Hooks (0)

None.

### Platform manifests (0)

None.

### Licenses (license files and declared license fields) (1)

- SKILL.md:4: MIT; declared in license


### What it needs

Programs are the ones Walkdown recognizes (`stages/04-phrases/tools.yaml`); declared means named in a dependency file, a skill's compatibility field, or an install line.

- `curl`: not declared; used at SKILL.md:75 (instructions)
- `git`: not declared; used at SKILL.md:45 (instructions), SKILL.md:52 (instructions), SKILL.md:52 (instructions), SKILL.md:125 (instructions), SKILL.md:125 (instructions)
- `npm`: not declared; used at SKILL.md:124 (instructions)
- No package imported.

### What ties it to one machine

Nothing found that ties it to one machine.

## 2 What the model actually reads

2/2 files (100.0%). 1 divergence (1 details). 0 lines changed by folding. 0 non-Latin runs. 0 passages in a language other than English. Validation INCOMPLETE: see 7.

Validation: INCOMPLETE (gate 20/31, negative 22/24, recall 1/1; skipped: 13 rows; measured 2026-11-02, same code and fixtures)

### Divergences (reading A versus reading B) (1)

- README.md:59: A-only, carrier details, method static-style: `` **Method:** source-only and read-only, on a quarantine clone of the repo as of 11 Oct 2026.\nFour parallel auditors (build/install, runtime, network, hidden payloads).\nNothing was built or run, and the clone was deleted afterwards.\nThat run is the method that became this skill.\n\n**Not tested:** the installer and offline editing.\nThe privacy and account-ban points below were read from the code, not observed by running the app.\n\n### What's clean [Certain]\n\n- **Build and install:** nothing runs that shouldn't. All 1,044 Rust packages come from crates.io and every npm package but one comes from the official registry.\n- **Your machine:** it doesn't read your real browsers' logins or cookies, or your system keychain. It doesn't start itself at login, update itself, or capture keys, screen, microphone or camera.\n- **Hidden code:** none. No crypto-miner, password stealer or remote-control code, and no disguised scripts. The Python files are never run by the app.\n- **Your API keys and provider logins** only ever go to the provider they belong to.\n\n### What to actually worry about, worst first\n\n1. **Microsoft Clarity records your sessions inside the app.** That covers clicks and scrolls, and probably prompts you type [Likely]. There's no setting to turn it off.\n2. **When you're logged into an ArtCraft account, your prompts and generated images or videos are copied to their servers.** That happens even when you pay Midjourney or fal yourself with your own key [Certain]. Image-to-image also uploads your reference images to their storage first [Likely].\n3. **Your logins are saved as plain text.** Provider cookies (ChatGPT, Grok, Midjourney) and API keys sit unprotected in `~/Artcraft`, where any other program or backup tool can copy them [Certain].\n4. **The app is built carelessly.** Its window can read any file your user account can read, can send to any website, and loads outside scripts. No current code abuses this. But a hacked outside script could read your files or saved keys and send them anywhere [Certain about the setup; no exploit seen].\n5. **Your accounts could get banned.** It defeats the bot checks of Grok, Sora/ChatGPT and Midjourney, which breaks their terms. Any ban would land on the accounts you log in with.\n\n**What this check doesn't cover:** the installer you'd download from their website. Only the source code was audited, so nothing here proves their installer was built from this exact code.\n\n### If you want to try it anyway\n\n- Run it in a VM or a separate user account.\n- Log into the AI sites with throwaway accounts, not your main ChatGPT or Midjourney.\n- Stay logged out of ArtCraft's own account.\n- Block `clarity.ms`, `posthog.com` and `google-analytics.com`.\n\n### Follow-up: can it run without AI connectivity?\n\n**No.** ArtCraft has no AI of its own: it's a front end for online AI services, so offline it can't generate anything [Certain].\nThe editing tools would probably still open, but even they lean on the vendor's servers.\n\n- **No local AI engine.** It has no image model and no way to connect to a local one such as ComfyUI or Ollama. ComfyUI appears only as a job type on the vendor's own servers [Certain].\n- One on-device vision library (Google's MediaPipe) is listed as a dependency, but nothing in the code uses it [Certain].\n- **Every generation goes online.** Images, video, audio, image-to-3D and background removal all go either to the vendor's servers or to Midjourney, fal, Grok, Sora or WorldLabs [Certain].\n- **The 3D canvas needs their servers too.** The app ships with no 3D models; the asset kits come from the vendor's library. Saving a 3D scene uploads it to their servers rather than to a file on your machine [Certain].\n- **The video editor is the one part that works locally.** It saves projects inside the app's own storage on your machine [Certain].\n- **The other desktop app in the repo is no better.** It's a newer Rust-only rewrite, and its own README says every generation goes through the vendor's servers and starts by asking you to sign in [Certain].\n\nWhether the 2D and 3D canvas opens and works with the network cut off can't be told from the code; proving it means running the app offline, which wasn't done.\nIf you want local AI art, this is the wrong tool. A local tool such as ComfyUI, running models on your own GPU, is the offline route. ``

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

2 entry points. 0 orphans. 7 dangling references (7 code). 0 dynamic loads: 0 files loaded only through one (named by nothing), 0 files reached only through a mention of a folder or wildcards.

Validation: PASS (gate 11/11, negative 7/7; measured 2026-11-02, same code and fixtures)

Depth histogram (static = reached by direct references; dynamic = only through a load: a folder a config names, a code scan, wildcards in an instruction file; mention = only through a folder or wildcards named elsewhere): static depth 0: 2.

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

### Dangling references (7)

- SKILL.md:66: `build.rs` (code)
- SKILL.md:66: `setup.py` (code)
- SKILL.md:78: `.claude/` (code)
- SKILL.md:78: `.cursor/` (code)
- SKILL.md:78: `AGENTS.md` (code)
- SKILL.md:78: `CLAUDE.md` (code)
- SKILL.md:120: `install.sh` (code)

### Dangling references into a folder the repository does not have (often one the workflow creates when it runs) (0)

None.

### Not scanned for references (0)

None.

### Reference depth, directly reached files (2)

- README.md: depth 0
- SKILL.md: depth 0

## 4 What the text asks for

4a 12 · 4b 5 · 4c 6 · 4d 2 hits on 22 lines (16 read by a model, 6 human-facing); benign share not measured (stage 6 labels did not run). Hosts: 3, 0 not named in the docs. Confirm-first or prohibited actions in instruction text: 0, 0 with no confirmation step, 0 stated as prohibitions. Conditionals: none. Definitions: 1, 0 conflicts, 0 safety-word definitions. Long files with flagged lines: 0, 0 with some past the reader window. Sentences repeated across files: 0, 0 flagged. Lines that look like committed secrets: 0.

Validation: PASS (gate 153/153, negative 121/121, recall 43/43; measured 2026-11-02, same code and fixtures)

Every hit is a locator. Benign share not measured here; stage 6 labels, when run, read the lines a model sees (section 6). Audience is who the file addresses, by path.

### 4a Reaching out

#### phrase.K.exfil (8 lines)

Patterns: K.assembly-code 1, K.http-verb 1, K.md-carrier 1, K.telemetry 5

- README.md:59 [K.md-carrier] (human): `<details>`
- README.md:92 [K.telemetry] (human): `` - Block `clarity.ms`, `posthog.com` and `google-analytics.com`. ``
- SKILL.md:75 [K.http-verb] (model): `` - Every shell, PowerShell and Python script: `curl | sh`, downloads, privilege escalation, persistence, credential reads. ``
- SKILL.md:87 [K.telemetry] (model): `**4.3 Network egress and telemetry.**`
- SKILL.md:88 [K.telemetry] (model): `- Every hard-coded outbound host, grouped: third-party providers, the vendor's own backend, analytics, unknown.`
- SKILL.md:90 [K.telemetry] (model): `- Analytics: which service, which events and properties, whether there is an opt-out, whether prompts, files, paths or keys ride along.`
- SKILL.md:95 [K.assembly-code] (model): `` - Obfuscation: long base64 or hex blobs in source, `eval` / `new Function` / decode-then-execute, `String.fromCharCode` chains, unexpected embedded files, Trojan Source bidi characters (U+202A to U+202E, U+2066 to U+2069), zero-width characters, very long single lines, minified JS in source folders (identify the library, check its tail for injected `fetch`, `WebSocket` or `eval`). ``
- SKILL.md:102 [K.telemetry] (model): `Then the findings that matter with their evidence, each called MALICIOUS or SKETCHY-BUT-LEGITIMATE (normal telemetry, scraping that risks the user's own accounts, plaintext key storage).`

#### phrase.creds (3 lines)

Patterns: creds.enumerate 1, creds.path 2

- README.md:73 [creds.path] (human): `- **Your machine:** it doesn't read your real browsers' logins or cookies, or your system keychain. It doesn't start itself at login, update itself, or capture keys, screen, microphone or camera.`
- SKILL.md:73 [creds.enumerate] (model): `- Every build script, read in full: network fetches, downloads, spawned processes, writes outside the build output folder, harvested environment variables or credentials.`
- SKILL.md:76 [creds.path] (model): `` - Dependencies: git, URL and tarball dependencies, patch or override sections, unusual registries (`.npmrc`, `.cargo/config*`), lockfile entries not resolving to the official registry, typosquatted names. ``

#### phrase.remote-load (1 line)

Patterns: RL.pipe-shell 1

- SKILL.md:75 [RL.pipe-shell] (model): `` - Every shell, PowerShell and Python script: `curl | sh`, downloads, privilege escalation, persistence, credential reads. ``

### 4b Taking the wheel

#### phrase.L.override (1 line)

Patterns: L.identity 1

- SKILL.md:110 [L.identity] (model): `2. **Mechanical scan.** Links, commands, injection phrases ("ignore previous", "you are now"), hidden Unicode, long encoded blobs, docx macros and external relationships, any "turn this into a script and run it" or "visit this site".`

#### phrase.A.consent (0 lines)

None.

#### phrase.B.defs (2 lines)

Patterns: B.safety-adjective 2

- SKILL.md:3 [B.safety-adjective] (model): `description: Use before you install, run or trust a GitHub repo you don't know - "danger protocol this repo", "is this repo safe", "check this repo for malware or spyware". A read-only review in quarantine - nothing from the repo is ever run - across build scripts, runtime behaviour, network traffic and hidden payloads, ending in one verdict that says what it could not prove. Not a guarantee.`
- SKILL.md:69 [B.safety-adjective] (model): `` 4. **Fan out four read-only auditors, one slice each** (in parallel with Agent when available, otherwise one after another).\n   Each brief opens with the rules above, the quarantine path, one line on what the project is and what the user is worried about, and asks for findings with `file:line` evidence, a severity (none / low / medium / high) and a MALICIOUS or SKETCHY-BUT-LEGITIMATE call, in under 700 words. ``

#### phrase.H.anti-review (1 line)

Patterns: H.evidence 1

- SKILL.md:105 [H.evidence] (model): `6. **Clean up.** Delete the quarantine copy (it is scratch) and log the verdict where the session keeps its record.`

#### phrase.I.conditional (1 line)

Patterns: I.harness 1

- README.md:41 [I.harness] (human): `- If you're about to give the thing your API keys, your accounts or your money: get a human who knows security to look.`

### 4c Changing the environment

#### phrase.E.perms (2 lines)

Patterns: E.exec-primitive 1, E.perm-flags 1

- README.md:39 [E.perm-flags] (human): `` - Keep your agent's permission prompts ON. No `--yolo`, no `--dangerously-skip-permissions`. [And you know I'm all about that yolo life] ``
- SKILL.md:47 [E.exec-primitive] (model): `chmod +x "$Q/qgit"`

#### phrase.C.second-order (1 line)

Patterns: C.frontmatter-grant 1

- SKILL.md:5 [C.frontmatter-grant] (model): `allowed-tools: Read, Grep, Glob, Bash, Agent`

#### phrase.D.trust (1 line)

Patterns: D.pseudo-tag 1

- README.md:30 [D.pseudo-tag] (human): `Do a hostile-code review of this repo: <REPO_URL>`

#### phrase.E.env (2 lines)

Patterns: E.clone 1, E.git-keys 1

- SKILL.md:45 [E.git-keys] (model): `git -c core.hooksPath=/dev/null -c core.symlinks=false -c core.fsmonitor=false "\$@"`
- SKILL.md:125 [E.clone] (model): `` | "A plain `git clone`, or a quick plain `git log` on the clone, is safe enough" | Checkout runs installed filter drivers the repo selects, any git command runs config-named programs such as fsmonitor, and symlinks are followed on read. Every git call goes through `qgit`. | ``

#### phrase.J.prohibited (0 lines)

None.

### 4d Talking to the human

#### phrase.G.human (2 lines)

Patterns: G.perm-flags-docs 1, G.pipe-shell 1

- README.md:39 [G.perm-flags-docs] (human): `` - Keep your agent's permission prompts ON. No `--yolo`, no `--dangerously-skip-permissions`. [And you know I'm all about that yolo life] ``
- SKILL.md:75 [G.pipe-shell] (model): `` - Every shell, PowerShell and Python script: `curl | sh`, downloads, privilege escalation, persistence, credential reads. ``

### Tables

Hosts: 3, 0 not named in the docs. Confirm-first or prohibited actions in instruction text: 0, 0 with no confirmation step, 0 stated as prohibitions. Conditionals: none. Definitions: 1, 0 conflicts, 0 safety-word definitions. Long files with flagged lines: 0, 0 with some past the reader window. Sentences repeated across files: 0, 0 flagged. Lines that look like committed secrets: 0.

### Endpoints (hosts named anywhere; documented = named in the docs) (3)

- crates.io: documented, registry; 1 docs; first at README.md:72
- google-analytics.com: documented, other; 1 docs; first at README.md:92
- posthog.com: documented, other; 1 docs; first at README.md:92

### Confirm-first and prohibited actions in instruction text (0)

None.

### Conditionals (0)

None.

### Definitions (1)

- SKILL.md:57: "the empty config" (explicit): `no filter driver exists during checkout.`

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

Skill descriptions here take about 96 tokens (382 characters). Claude Code's listing of every installed skill holds about 1% of the context: about 320 tokens at 32,000, 2,000 at 200,000.

- `SKILL.md` (skill): auto; description 382 characters

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

Can read your data: yes · Can take outside input: yes · Can send data out: yes All three at once: it can read your data, take outside input, and send data out. That is the combination text from outside can steer into sending your data away. Install grants: context-injection, persistence, network.

Validation: PASS (gate 81/81, negative 24/24; measured 2026-11-02, same code and fixtures)

A map of capability, derived from stages 1 to 4; it reaches no verdict. A Bash grant is counted as private-data access and execute posture; on its own it does not count as external communication.

### Trifecta legs

- Can read your data: yes (3 citations)
    - stage 01 struct.agent-tools SKILL.md:5: tool grant: Read, Grep, Glob, Bash
    - stage 04 phrase.creds SKILL.md:73: phrase.creds: creds.enumerate
    - stage 04 phrase.creds SKILL.md:76: phrase.creds: creds.path
- Can take outside input: yes (2 citations)
    - stage 04 phrase.remote-load SKILL.md:75: phrase.remote-load: RL.pipe-shell
    - stage 04 phrase.E.env SKILL.md:125: phrase.E.env: E.clone
- Can send data out: yes (2 citations)
    - stage 04 phrase.K.exfil SKILL.md:75: phrase.K.exfil: K.http-verb
    - stage 04 phrase.remote-load SKILL.md:75: phrase.remote-load: RL.pipe-shell

### Install grants

- context-injection (1 citation)
    - stage 01 struct.description SKILL.md:3: description: always-on text
- persistence (1 citation)
    - stage 04 phrase.E.env SKILL.md:45: phrase.E.env: E.git-keys
- network (2 citations)
    - stage 04 phrase.K.exfil SKILL.md:75: phrase.K.exfil: K.http-verb
    - stage 04 phrase.remote-load SKILL.md:75: phrase.remote-load: RL.pipe-shell

### Text in context at load

Bytes at load: descriptions 382 (1, exact).

- SKILL.md:3: description, 382 bytes, exact

### What it costs and what ships

Expected context: 32,000 tokens (a line for 200,000 beside it). Tokens are estimated from size: about 4 bytes of English text per token; text in other scripts runs high.

- Every session, once installed (descriptions, hooks): 96 tokens, under 1% of 32,000, under 1% of 200,000
- When the largest skill runs: 2,859 tokens, 9% of 32,000, 1% of 200,000
- That skill and everything it names: 2,859 tokens, 9% of 32,000, 1% of 200,000
- The largest is `SKILL.md`, of 1 skill, agent, or command.

Every skill, agent, or command, by tier (tokens):

- SKILL.md: runs 2,859, with what it names 2,859, with wildcard loads 2,859

#### Loads into the AI: 1 file, 11.2 KB, 2,859 tokens

- `SKILL.md`: skills, agents, and commands, 11.2 KB, 2,859 tokens

#### Used another way: 0 files, 0 bytes, 0 tokens

None.

#### Not used at run time: 1 file, 7.4 KB, 1,902 tokens

- `README.md`: written for people, 7.4 KB, 1,902 tokens

### Agent and command posture (1)

- SKILL.md:5: delegate, execute, read; job `Use before you install, run or trust a GitHub repo you don't know - "danger protocol this repo", "is this repo safe", "check this repo for malware or spyware". A read-only review in quarantine - nothing from the repo is ever run - across build scripts, runtime behaviour, network traffic and hidden payloads, ending in one verdict that says what it could not prove. Not a guarantee.`

### Stated limits: read-only wording a model reads, and what backs it (2)

- SKILL.md:3: contradicted; No tool setting backs it: the tools list of SKILL.md includes Bash. `description: Use before you install, run or trust a GitHub repo you don't know - "danger protocol this repo", "is this repo safe", "check this repo for malware or spyware". A read-only review in quarantine - nothing from the repo is ever run - across build scripts, runtime behaviour, network traffic and hidden payloads, ending in one verdict that says what it could not prove. Not a guarantee.`
- SKILL.md:69: contradicted; No tool setting backs it: the tools list of SKILL.md includes Bash. `` 4. **Fan out four read-only auditors, one slice each** (in parallel with Agent when available, otherwise one after another).\n   Each brief opens with the rules above, the quarantine path, one line on what the project is and what the user is worried about, and asks for findings with `file:line` evidence, a severity (none / low / medium / high) and a MALICIOUS or SKETCHY-BUT-LEGITIMATE call, in under 700 words. ``

### Pairs: Test data a model-read file references directly (0)

None.

### Pairs: Image a model-read file points at (0)

None.

### Pairs: Orphan with a phrase hit (0)

None.

### Pairs: Hidden text with a phrase hit (2)

- README.md:73: phrase.creds [creds.path]: `- **Your machine:** it doesn't read your real browsers' logins or cookies, or your system keychain. It doesn't start itself at login, update itself, or capture keys, screen, microphone or camera.`
- README.md:92: phrase.K.exfil [K.telemetry]: `` - Block `clarity.ms`, `posthog.com` and `google-analytics.com`. ``

### Pairs: Load-only file with a phrase hit (0)

None.

### Pairs: Instruction in a script a context-injecting hook runs (0)

None.

### Do the tools fit the job

Entries checked: 1 (1 with a tools list, 0 agents with none). The yardstick is each entry's own words, over what it reads, against its own grants; families and hook facts are in `stages/05-capability/fit.yaml`, the cues in `stages/04-phrases/asks.yaml`.

Read-only claims the tools contradict (2): the words say read-only and a tool or setting beside them can write.

- SKILL.md:3: says read-only; its own tools can write
- SKILL.md:69: says read-only; its own tools can write

## 6 Needs a human read

17 questions (16 labeling, 1 relational). Packet only: no model read (06-packet.md in the run folder).

Validation: PASS (gate 125/125, negative 11/11, recall 0/165; skipped: 124 rows; measured 2026-11-02, same code and fixtures)

Questions a pattern cannot settle, and the answers of the backends named here. Every answer is a located observation; none changes a finding in sections 1 to 5.

- no backend: packet only

### Questions

- SKILL.md:3 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- SKILL.md:5 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- SKILL.md:45 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- SKILL.md:47 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- SKILL.md:69 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- SKILL.md:73 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- SKILL.md:75 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- SKILL.md:76 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- SKILL.md:87 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- SKILL.md:88 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- SKILL.md:90 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- SKILL.md:95 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- SKILL.md:102 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- SKILL.md:105 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- SKILL.md:110 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- SKILL.md:125 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- (repo) [relational] Describe, as capability and not intent, how these three capabilities could combine in this artifact, citing the evidence given.
    - soft.read: skipped (no relational backend)

## 7 Not examined

- Stage 02-reader validation INCOMPLETE (gate 20/31, negative 22/24, recall 1/1; skipped: 13 rows; measured 2026-11-02, same code and fixtures): its zeros are not validated for the skipped checks.
- (02-reader) tesseract not installed (no tesseract binary, no pytesseract): images and PDF pages are skipped for OCR (read.divergence skip); images and PDFs with no text layer are listed as read.unread
- (02-reader) html render: playwright not installed: HTML files are read with static style only (read.divergence skip, carrier rendered)
- (02-reader) v1 limit: the language check (read.language) reads prose only: Markdown, plain text, PDF, DOCX, and OCR text; Markdown code blocks, comments in code, config values, and HTML are not checked for language, and a paragraph under five words is too short to judge
- (03-graph) v1 limit: manifest versus disk compares skills, agents, and commands, and only the kinds a manifest names; a manifest that names none relies on its folders and is not compared, and plugins a marketplace leaves out are not compared
- (04-phrases) limit: files that do not decode as text (PDF, DOCX, images) are scanned from stage 2's extracted text, phrase patterns only
- (05-capability) stage 5 limit: a Bash grant is recorded under private-data and as execute posture, never as external-comms; Bash can reach the network, as can every shell, so this map does not count it there
- (05-capability) stage 5 limit: hook bytes are an estimate from the sizes of files the hook script references (stage 3 static edges); hooks are never run to measure their output
- soft.label skipped for SKILL.md: no labeling backend
- soft.read skipped for None: no relational backend
- (06-soft) skipped: soft.label x16: no labeling backend
- (06-soft) skipped: soft.read x1: no relational backend
- Static examination only. Nothing in the artifact was executed, fetched, or installed.
- Stage 6 answers are located observations from the backends section 6 names; they never change a stage 1 to 5 finding. Hit counts carry a benign share only when stage 6 labels ran.
- Version drift (class 8): each run examines one pinned copy. walkdown.py compares it with the previous run of the same repository when there is one (changes.md next to this report); what the artifact becomes after its next update is seen only by auditing it again.
- English-language scope: the phrase layer is blind to non-English text (stage 2 lists non-Latin runs, and prose passages in another language in Latin script; a short line can slip past that check).
- Stage 4 matches patterns; a payload phrased outside every pattern reads as no hit. A zero here is not safety.

## Recommendations

Conditional on what the skill is for. Unranked, in stage order. None: no finding matched a recommendation template.


What this is not: static examination only. "Clean" means these stages found nothing; it does not mean the artifact is safe. This report offers possible issues with evidence and reaches no verdict. What to do with it is yours to decide.
