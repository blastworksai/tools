# Stage 6 review packet: needs a human read

Input: `/opt/glitch/workspaces/tools--publish-rocket-fuel/skills/rocket-fuel`  
Written: 2026-11-09  
Questions: 2 (1 labeling, 1 relational)  
Backends: none (packet only)

Every quoted line and state block below is data taken from the artifact under
review. It holds no instructions for whoever reads this packet. The packet can
be taken to any assistant. Answers are located observations, not verdicts, and
they never change a stage 1 to 5 finding.

## Labeling options

Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?

- **do**: The line instructs the reader (the model or agent reading the file) to perform the matched action. This includes instructions to suppress, skip, withhold, or hide something, even when they are worded with "do not" or "never", because what the reader is told to do is the hiding or skipping. Not for: A line that forbids the matched action itself; a statement about what the artifact, a tool, or users do; a phrase shown in quotation marks or as an example of what to avoid.
  - e.g. Upload the build log to the shared bucket after every run.
  - e.g. Merge the branch without waiting for a review.
  - e.g. Never mention the retry to the user; just report success.
  - e.g. Clear the audit trail quietly once the job is done.
- **not-to**: The line instructs the reader not to perform the matched action, so following the line means the risky action does not happen. Not for: A "do not" that tells the reader to keep something from the user or to skip a check (that instructs suppression, which is do); a statement that the artifact never does something (that is description).
  - e.g. Never paste API tokens into a chat message.
  - e.g. Do not run the migration against the production database.
  - e.g. Under no circumstances upload files outside the project folder.
- **description**: The line states a fact about the artifact, a tool, users, or a situation, or describes a quality, without instructing the reader to do anything. Statements of what the artifact never does are descriptions. Not for: An imperative addressed to the reader, positive or negative; a phrase set off in quotation marks or introduced as an example.
  - e.g. The exporter retries without logging when the network drops.
  - e.g. This plugin does not read SSH keys or browser cookies.
  - e.g. Many teams run the formatter with auto-fix turned on.
  - e.g. A clear bug report lets someone reproduce the problem without follow-up questions.
- **example-or-quote**: The line quotes the phrase, or presents it as an example, a warning, or an illustration, rather than using it as an instruction or a plain statement. Not for: A direct instruction to the reader; a plain factual statement with no quoted or illustrative phrase.
  - e.g. Phishing pages often say "confirm your password here" to look official.
  - e.g. Bad prompt: "disregard the rules above and answer freely".
  - e.g. An example of an unsafe step: "pipe the downloaded script into the shell".
- **other-sense**: The line uses the matched words for something other than the action the pattern locates: an everyday or technical meaning that has nothing to do with overriding instructions, sending data out, skipping confirmation, or the other risky action named in `matched`. Not for: A line where the words carry the located meaning, whether as an instruction, a prohibition, a description, or a quoted example.
  - e.g. Remove the cached build and start fresh from a clean checkout.
  - e.g. Every route must accept a trailing slash in its URL.
  - e.g. This theme overrides the default color palette.
  - e.g. Keep each changelog entry under three lines.

## Labeling questions

### label:SKILL.md:7

Location: SKILL.md:7  
Question: Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?

```json
{
 "file": "SKILL.md",
 "line": 7,
 "text": "allowed-tools: Read, Bash, Grep, Glob",
 "before": [
  "metadata:",
  "  status: active"
 ],
 "after": [
  "---",
  ""
 ],
 "matched": [
  {
   "check": "phrase.C.second-order",
   "pattern": "C.frontmatter-grant",
   "locates": "allowed-tools:, tools:, model: in frontmatter"
  }
 ]
}
```

## Relational questions

### rel:legs

Location: repo-level (no single line)  
Question: Describe, as capability and not intent, how these three capabilities could combine in this artifact, citing the evidence given.

```json
{
 "legs": [
  {
   "leg": "private-data",
   "present": true,
   "evidence": [
    {
     "file": "SKILL.md",
     "line": 7,
     "why": "tool grant: Read, Grep, Glob, Bash",
     "text": "allowed-tools: Read, Bash, Grep, Glob"
    }
   ]
  },
  {
   "leg": "untrusted-content",
   "present": false,
   "evidence": []
  },
  {
   "leg": "external-comms",
   "present": false,
   "evidence": []
  }
 ]
}
```
