# BW CODE REVIEW

**A read-only review of one GitHub pull request, posted as one real GitHub review.**

## Why

An agent that reviews its own work grades itself kindly.
A reviewer that runs the code can change the thing it is judging.
A review that is one long comment is hard to act on.

This skill reads the change and does nothing else.
It will not review a change its own model family wrote.
It pins each finding to the line it is about, and it opens with a short summary in plain words.
A checker refuses any review whose shape is wrong before anything is posted.

## What it does

1. **Family rule.** The reviewer states its own model family and agent identity. It refuses when the PR author, the branch name or any commit author or committer in the range names that family or identity. Only you can overrule that, and the overrule is quoted in the review.
2. **Stage.** Fetches the pull request into a private bare mirror on your machine. It never checks anything out and never runs tests.
3. **Review.** The agent reads the diff and the files at the reviewed commit, and writes `review.md`: a `## What this change does` section of 3 to 5 plain lines, then `## Findings` (one line each: `F1. path:line — what goes wrong — HIGH — 0.8`), then the verdict.
4. **Check.** `check_review.py` validates the file. One `verdict: PASSED` or `verdict: REWORK NEEDED`, a `reason:` on a rework only, the machine fields last, every finding in shape.
5. **Post.** `post_review.py` posts one GitHub review with line notes on the findings that sit on changed lines. Approve on a pass, Request changes on a rework, Comment when the PR author is the one posting. After a definite 4xx refusal from GitHub, it posts the same text once as a plain comment. After an unclear failure (a timeout, a 5xx or no answer), it reads the reviews back once and posts the plain comment only when no matching review exists, so in a rare case (the first request completes late) the advice may appear twice; if the read-back fails, it writes nothing more. If the PR head moved, it writes nothing. After a review or comment posts, it checks the head again, and a clean run writes `github_result.json`.
6. **Tracker hook (optional).** `run_tracker.py` runs one command you configure, once, with no shell: for example a comment on an issue. It refuses unless `github_result.json` shows the post succeeded for this PR and head; `--no-github` skips that check when GitHub was skipped. With no config it does nothing.

A review that could not look at something is never a pass. It is a REWORK NEEDED with `reason: could not observe: <what>`.

## How to use it

**Claude Code or Glitch:** copy the inner [`bw-code-review/`](bw-code-review/) folder into your `.claude/skills/` folder, then say "review PR 42 on owner/name" or "BW code review".
Add "DRY RUN" to build the payload and the tracker command without writing anything outward.

**Settings (optional):** copy `config.example.json` to `config.json` inside the skill folder.

- `self_names`: extra names that count as the reviewer, for the family rule.
- `tracker_command`: an argv list (never a shell string). These placeholders are replaced in each element: `{review}` `{verdict}` `{reason}` `{repo}` `{pr}` `{head}` `{review_url}`.
- `tracker_timeout_s`: seconds before the command is stopped (default 60).

Review files go under `${BW_REVIEW_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/bw-code-review}`.

**Tests:** `python3 -m pytest -q bw-code-review/tests` (offline, no network, no login).

## You need

- An agent that can read files and run shell commands (Claude Code, Codex or similar).
- `git`, `python3` (3.10 or newer, standard library only) and `bash`.
- The GitHub CLI `gh`, logged in, with access to the repository. It is the only credential used.

## Credit

The line notes and the plain-words summary come from the idea behind Ada AI, the Codegeist Unleashed 2023 winner ([write-up](https://devpost.com/software/cyborg-coder)). No code was copied: Ada AI's code is not public.

MIT licence, see [`LICENSE`](LICENSE).
