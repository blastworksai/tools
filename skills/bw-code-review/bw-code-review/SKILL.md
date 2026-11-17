---
name: bw-code-review
description: Review one GitHub pull request read-only, without running tests, then post one GitHub review with line notes and a plain-words summary. Checks the review text with a linter first. Use when told to "review PR <n>", "code-review this pull request" or "BW code review".
allowed-tools: Read, Bash, Grep, Glob
metadata:
  version: 1.0.0
  license: MIT
---

# bw-code-review: the closed review brief

You review one pull request.
You review what was asked against what was built, you cite evidence for every claim, and you file exactly one verdict.
This file is the whole brief: follow it in order, and do not widen it.

`SKILL_DIR` below means the folder that holds this file.
`OUT` means the staging folder that `stage.sh` prints (section 2).
`MIRROR` means the mirror path `stage.sh` prints.

## 0. The author's family never grades its own work

Before anything else, state which model family you are and which agent identity you run as (for example a family such as Claude, GPT or Gemini, and the name or login you act under).
Read `SKILL_DIR/config.json` if it exists.
Its `self_names` list (strings) adds more names that count as you.
Refuse the review if any of these names your family, your identity or any `self_names` entry (compare without regard to case):

- the PR author (`gh pr view <n> --repo <owner/name> --json author`, when `gh` is logged in);
- the branch name;
- any commit author or committer in the range, read from the mirror once section 2 has staged it (`git -C MIRROR log --format='%an <%ae> | %cn <%ce>' <merge_base>..<head_sha>`, the two-dot range of the PR's own commits, both SHAs from `OUT/meta.txt`).

A refusal writes no `verdict:` line, posts nothing anywhere, and tells the operator in one line that a reviewer from another model family should review it.
`check_review.py` fails a text with no verdict, so a refusal can never be posted by mistake.
Only the operator can overrule a refusal, and only by saying so explicitly.
If the operator overrules, quote the overrule word for word under a `## Review boundary` heading in the review.

## 1. Inputs

You are given a PR number on a GitHub repository (`<owner>/<name>`).

- Run `gh auth status`.
- When it succeeds, run `gh pr view <n> --repo <owner/name> --json title,body,author,headRefName,headRefOid,baseRefName`.
  Take the title and body as the statement of what was asked.
  The acceptance criteria, if any, are inside the body.
- If `gh` is not logged in, you cannot resolve the head.
  That is a REWORK NEEDED with `reason: could not observe: the PR head, because gh is not logged in`.
- If the PR body states no purpose, say so in the review and review against the title and the diff.

## 2. Staging

Stage the change with the helper, never by checking anything out:

```
bash SKILL_DIR/stage.sh <owner/name> <base-branch> <head>
```

- `<owner/name>` is the GitHub name, for example `octocat/hello-world`.
- `<base-branch>` is the branch the change lands on, for example `main`.
- `<head>` is the PR number (for example `407`), or the full 40-character head SHA.

It keeps a private bare mirror of the repository at `<root>/repos/<owner>__<name>.git` (mode 0700), created on first use.
The root is `${BW_REVIEW_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/bw-code-review}`.
It fetches the base branch and the head into that mirror with your own `gh` login, so the base is the moved branch, not a stale one.
It writes into `<root>/<head-short>/` (mode 0700): `diff.patch` (a three-dot diff with `-M -D`), `files.txt`, `stat.txt` and `meta.txt`.
It prints `mirror: <path>` and then, as its last line, the staging folder.
`OUT/meta.txt` also records `repo`, `mirror`, `base_sha` and `head_sha`.

- Read a changed file at the reviewed commit with `git -C MIRROR show <head_sha>:<path>`.
- Read the base side with `git -C MIRROR show <base_sha>:<path>`.
- Never read the change from a working tree: no checkout is the branch under review.
- `-D` shows a deleted file as a header only; read its old body with `git -C MIRROR show <base_sha>:<path>` if the deletion matters.
- If the fetch fails, `stage.sh` stops and says it could not observe.
  That is a REWORK NEEDED (`reason: could not observe: git fetch of <owner/name> into the review mirror failed`), never a defect in the change.
- `STAGE_NO_FETCH=1` stages from whatever the mirror already holds.
  If you use it, say in the review that the base was not moved.

## 3. Do not run tests

Do not run tests, linters, builds, installs or the program.
The review is a reading.
"The tests could not run" is not a finding.
You may run read-only git, `gh pr view` and `gh pr diff`, and nothing that writes, until section 7.

## 4. Priorities, in rank order

Ask three questions of every hunk.
One "no" fails the change.

1. **Correct?** Does it do what the PR asked, on every path, including the error paths?
2. **Production-safe?** Could it break something live: data loss, a security hole, a silent failure, a migration or deploy hazard, a guard switched off?
3. **Scoped to the ask?** Does it do only what the PR asked? Unasked changes are a finding.

No style notes.
Review against what was asked, not against what was built.

## 5. Findings

Put every finding under one heading, `## Findings`, one finding per line, in exactly this shape:

```
F1. src/queue/worker.py:42 — a None owner reaches .lower() and the sweep crashes on the first orphan row — HIGH — 0.8
```

- `F<n>.` numbers the finding (F1, F2, and so on; each number once).
- `<path>:<line>` is the file relative to the repository root and a line at the reviewed head; a range is `<path>:<start>-<end>`.
- Each finding's `<path>:<line>` should be a line the change added or kept in the diff when the problem is there, because those findings are pinned to the line in GitHub.
- A finding about code outside the diff stays valid and is shown in the review body only.
- Then the concrete failure scenario: what input or state, what goes wrong, who notices.
- Then the severity: exactly `HIGH`, `MEDIUM` or `LOW`.
- Then your confidence, a number from 0 to 1 (`0.8`, not `80%`).
- The separators are ` — ` (an em dash with a space either side); ` -- ` is accepted.
- With no findings, the only line under `## Findings` is `None.`
- Every non-blank line under `## Findings` must be a finding or `None.`; put commentary under another heading.
- Any line anywhere that starts with `F<number>.` is read as a finding and must follow the shape.

## 6. Output

Write the review into `OUT/review.md`, in this order:

1. A `## What this change does` section of 3 to 5 lines in plain words.
   Write Simplified Technical English: short active sentences, common words.
   Say what the change does and what it means for the people who use it, with no code names unless needed.
   `check_review.py` refuses a review without it.
2. `## Findings`, then any other prose under its own heading (for example `## Review boundary`).
3. The machine fields, last, with nothing after them.

The machine fields are parsed literally, not as Markdown.
Each is a bare line: no backticks, bold, bullets, code fences, indentation or trailing explanation.

```
verdict: <STATE>
```

`<STATE>` is exactly one of these two:

- `PASSED`: the work meets what the PR asked and you read the evidence yourself.
- `REWORK NEEDED`: name what fails (the findings do this), or say what you could not observe (below).
  It always carries a `reason:` line.

Write exactly one `verdict:` line in the whole text.
The checker treats any line that starts with `verdict:` or `reason:` in any case as a field, even in your prose, so never begin a prose line with those words.

**For REWORK NEEDED**, add exactly one more bare line, the reason, one line of 1 to 500 characters:

```
reason: <why the change needs rework, one line>
```

**When you could not observe something the verdict depends on**, the verdict is still REWORK NEEDED and the reason starts with the exact prefix `could not observe:` (lowercase, colon, one space) followed by what you could not observe and why; the description after the colon must not be empty:

```
verdict: REWORK NEEDED
reason: could not observe: <exactly what you could not observe and why, one line>
```

A timeout, a missing file, an unfetchable commit or a tool that would not start is `could not observe:`, never a defect finding against the change.
A verdict you cannot evidence is REWORK NEEDED with `could not observe:`, never a pass.

**For PASSED**, write no `reason:` line.

## 7. Check, then post

Run the checker on the file:

```
python3 SKILL_DIR/check_review.py OUT/review.md
```

If it exits 1, fix the text it names and run it again.
Never post a text that failed.

If the request says DRY RUN, make no outward write of any kind.
Run both of these and show their reports:

```
python3 SKILL_DIR/post_review.py OUT/review.md --pr <n> --dry-run
python3 SKILL_DIR/run_tracker.py OUT/review.md --pr <n> --dry-run
```

`post_review.py --dry-run` writes only its local payload files (`github_review.json`, `github_body.md` and `github_fallback.md`) in `OUT`.
Say "DRY RUN: not posted" and show the review.

Otherwise post.
Every body goes through a file, never inline.
Each write happens once: if one fails, say so plainly with its error and do not retry it.
The one exception is inside `post_review.py`.
After a definite 4xx refusal from GitHub, it posts the same body once as a plain PR comment.
After an unclear failure (a timeout, a 5xx or no answer), it reads the PR's reviews back once and posts that plain comment only when no matching review exists.
So in a rare case, when the first request completes late, the advice may appear twice.
If the read-back fails, it writes nothing more.

1. **GitHub.**
   If `gh auth status` fails, say "GitHub post skipped: gh is not logged in" and go on to step 2.
   Otherwise run once: `python3 SKILL_DIR/post_review.py OUT/review.md --pr <n>`.
   It checks the file, pins each finding to its changed line, and sends one GitHub pull-request review.
   The review type follows the verdict: Approve on PASSED, Request changes on REWORK NEEDED, and Comment when the PR author is the posting login.
   If the PR head has moved since staging, it stops and posts nothing: restage and review again.
   After a review or a fallback comment posts, it reads the head once more and says if the head moved.
   Only when it exits 0 does it write `OUT/github_result.json`.
2. **Tracker hook.**
   Run it only after `post_review.py` exited 0.
   When GitHub was skipped (no PR number, or `gh` not logged in), add `--no-github`.
   Never run it after a refusal or a moved head: without `OUT/github_result.json` it refuses.
   Run once: `python3 SKILL_DIR/run_tracker.py OUT/review.md --pr <n> --review-url <url from step 1, if any>` (or with `--no-github`).
   With no `SKILL_DIR/config.json`, or no `tracker_command` in it, it prints `tracker: none configured` and does nothing.
   The command is an argv list that runs with no shell, no input, a timeout, and no retry.

## 8. Report

End with, in plain words: the verdict, the repository and PR, the `OUT` folder, and which writes succeeded, which were skipped and which failed, each with its evidence line.
For the GitHub post, also say the review type sent, how many findings were pinned to a line and how many were not, and the review URL.
For the tracker, say what it printed.
