# Changes: 2026-11-02_5ed2fd7 -> 2026-11-02_6c2dee6

Old: sha256 5ed2fd77b8e7, 2 files. New: sha256 6c2dee6583cc, 2 files.

What a newer version adds, from the findings both runs already made. Model reads (stage 6) are not compared. A change is a location to read; none is a verdict.

Summary: 1 files changed, 1 agent tool grants changed, 17 new phrase hits, 14 phrase hits gone, 17 of the new phrase hits in text a model reads; cost: largest at its fullest 1,575 -> 2,859 tokens (+1,284).

## What it costs (estimated tokens)

| | Earlier | Now | Change |
|---|---|---|---|
| Every session | 96 | 96 | +0 |
| Every session in this folder | none | none |  |
| Largest at its fullest | 1,575 | 2,859 | +1,284 |
| Not used at run time | 1,902 | 1,902 | +0 |

## Agent tool grants changed (1)

- SKILL.md: (no agent) -> Agent, Bash, Glob, Grep, Read

## New phrase hits in text a model reads (17)

- SKILL.md:69: phrase.B.defs `4. **Fan out four read-only auditors, one slice each** (in parallel with Agent when available, otherwise one after another). Each brief opens with the rules abo...`
- SKILL.md:5: phrase.C.second-order `allowed-tools: Read, Grep, Glob, Bash, Agent`
- SKILL.md:45: phrase.E.env `git -c core.hooksPath=/dev/null -c core.symlinks=false -c core.fsmonitor=false "\$@"`
- SKILL.md:125: phrase.E.env `| "A plain 'git clone', or a quick plain 'git log' on the clone, is safe enough" | Checkout runs installed filter drivers the repo selects, any git command runs...`
- SKILL.md:47: phrase.E.perms `chmod +x "$Q/qgit"`
- SKILL.md:75: phrase.G.human `- Every shell, PowerShell and Python script: 'curl | sh', downloads, privilege escalation, persistence, credential reads.`
- SKILL.md:105: phrase.H.anti-review `6. **Clean up.** Delete the quarantine copy (it is scratch) and log the verdict where the session keeps its record.`
- SKILL.md:87: phrase.K.exfil `**4.3 Network egress and telemetry.**`
- SKILL.md:90: phrase.K.exfil `- Analytics: which service, which events and properties, whether there is an opt-out, whether prompts, files, paths or keys ride along.`
- SKILL.md:88: phrase.K.exfil `- Every hard-coded outbound host, grouped: third-party providers, the vendor's own backend, analytics, unknown.`
- SKILL.md:75: phrase.K.exfil `- Every shell, PowerShell and Python script: 'curl | sh', downloads, privilege escalation, persistence, credential reads.`
- SKILL.md:95: phrase.K.exfil `- Obfuscation: long base64 or hex blobs in source, 'eval' / 'new Function' / decode-then-execute, 'String.fromCharCode' chains, unexpected embedded files, Troja...`
- SKILL.md:102: phrase.K.exfil `Then the findings that matter with their evidence, each called MALICIOUS or SKETCHY-BUT-LEGITIMATE (normal telemetry, scraping that risks the user's own account...`
- SKILL.md:110: phrase.L.override `2. **Mechanical scan.** Links, commands, injection phrases ("ignore previous", "you are now"), hidden Unicode, long encoded blobs, docx macros and external rela...`
- SKILL.md:76: phrase.creds `- Dependencies: git, URL and tarball dependencies, patch or override sections, unusual registries ('.npmrc', '.cargo/config*'), lockfile entries not resolving t...`
- SKILL.md:73: phrase.creds `- Every build script, read in full: network fetches, downloads, spawned processes, writes outside the build output folder, harvested environment variables or cr...`
- SKILL.md:75: phrase.remote-load `- Every shell, PowerShell and Python script: 'curl | sh', downloads, privilege escalation, persistence, credential reads.`

## Files changed (1)

- SKILL.md (model)

Phrase hits gone: 14.
