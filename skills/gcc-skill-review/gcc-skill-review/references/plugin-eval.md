# claude plugin eval: the shapes that work here

Shapes verified on Claude Code 2.1.319 (the shell sandbox and `env` facts from a refused run, 8 Nov).

## Layout

The target is the skill copy's own folder (a folder with `SKILL.md` at its root resolves as a skills-dir plugin).

```
<skill>-review/copy/
  SKILL.md
  evals/
    <case>/
      prompt.md            # what the fresh session is asked to do
      graders/
        <check-name>.md    # one file per check; the file name is the check's name
```

`claude plugin eval init --bare <case>`, run from inside the copy's folder, writes a blank case.
Run from anywhere else it refuses with "not a plugin or skill folder".

## prompt.md

```
---
max_turns: 30
timeout_seconds: 600
allowed_tools: [Read, Write, Bash, Glob, Grep, Skill]
runs: 5
---
<the request a person would type, e.g. "Review the posts in posts.csv with the content-review skill.">
```

Defaults: `max_turns` 10, `timeout_seconds` 300, `runs` 3.
Raise both limits for a multi-step skill, or a slow run is cut off and reads as a failed step.

Each run starts in a fresh throwaway folder (`/tmp/claude-eval-*/home/cwd`), not the skill's folder, and the sample input is not in it.
The proven road: keep the sample inside the case folder, grant it with `add_dirs`, and name its full path in the prompt.
Use the `case.yaml` form for that (it is one file holding the prompt, the limits and every check):

```
schema_version: "1.0"
name: posts
context:
  add_dirs: [sample]          # must sit inside the case folder; it grants reads, it copies nothing
execution:
  prompt: "Review the posts in /full/path/to/<skill>-review/copy/evals/posts/sample/posts.csv with the content-review skill."
  max_turns: 30
  timeout_seconds: 600
  allowed_tools: [Read, Write, Bash, Glob, Grep, Skill]
runs: 5
graders:
  - name: step3-picked-all
    type: regex
    target: {source: file, path: evidence/03-top-five.md}
    pattern: "^Picked:.*P04.*P11"
    flags: m
```

Seen on the trial: with a bare file name in the prompt the model searched, never found the file and wrote nothing, so every check failed on a fault of the case, not the skill.
An absolute path outside the case folder is refused before the run ("escapes the case directory").
The case folder is read-only to the run: a skill that writes into the person's project cannot work on a sample left there. Copy the sample into the run folder with a `scaffold_script` (runs only with `--scaffold`, and only on case files you wrote).

## Checks (graders)

A pattern check aimed at the `Picked:` line of one step's file:

```
---
type: regex
target: {source: file, path: evidence/03-top-five.md}
pattern: "^Picked:.*P04.*P11"
flags: m
---
```

The "nothing outside the answer" check uses `match: not_contains`:

```
---
type: regex
target: {source: file, path: evidence/03-top-five.md}
pattern: "^Picked:.*(P07|P19)"
flags: m
match: not_contains
---
```

`target` also takes `trace` (every tool call, e.g. to prove a button was never pressed), `files` or `last_message` (default).
`match` takes `contains` (default), `not_contains` or `count:N`.
A run that never started, or ended having done nothing, still passes every `not_contains` check; count a run only if its first step's file exists.
`flags` takes JavaScript RegExp flags; `m` makes `^` match at each line, which is what anchors a check to the `Picked:` line.
A pattern over the whole file is the trap the page caught: it finds a name in a raw ranking and passes a step that left it out of the final pick.

The file was written at all:

```
---
type: file_exists
path: evidence/01-posts.md
---
```

A rubric for a judgement step (paid: judged by a second model, Haiku by default):

```
---
type: llm
focus: {source: file, path: evidence/06-review.md}
---
It recommends at least one meal prep carousel and gives a reason drawn from the posts.
```

In `case.yaml` the same rubric is `{name, type: llm, criteria: "…", focus: …}`. A rubric judge can pass an empty message: read it.

Other types the schema accepts: `tool_used`, `tool_order`, `baseline`.

## Running

```
claude plugin eval <skill>-review/copy --runs 5 --model <model> --ablation none --no-publish --keep-temp --trust-plugin --allow-tools Write Edit Bash --json <skill>-review/runs/<model>-<before|after>.json </dev/null
```

- `</dev/null`: keeps the run non-interactive.
- `--no-publish` always: by default the report is published to claude.ai.
- `--ablation none`: otherwise a skills-dir target also runs a no-skill baseline arm, doubling the runs.
- `--allow-tools Write Edit Bash`: Write, Edit, Bash and WebFetch are gated; grant what the skill uses.
- A run granted Bash needs a working sandbox: on Linux both `bwrap` and `socat`. Without them the run is refused before the model starts ("Sandbox required but unavailable").
- `execution.env` accepts only `EVAL_*` keys; anything else must be exported in the shell that launches the eval. That does not open files: the sandbox cannot read the operator's home (so an exported `UV_CACHE_DIR` there is useless) and has no network.
- On Linux with `kernel.apparmor_restrict_unprivileged_userns = 1`, every sandboxed Bash call fails (`apply-seccomp: write /proc/self/setgroups … Permission denied`) even with bwrap and socat present.
- `--trust-plugin`: answers the first-run trust prompt; pass it only for a copy you wrote yourself.
- `--keep-temp`: the run folder, its step files and its trace are deleted when the run ends unless you pass it.
  A kept folder is read-only, with `home/` and `tmp/` sealed (mode 000) in `sealed/`; open them with `chmod 700 <kept> <kept>/sealed`, never run git inside one, and remove the kept folders when the review is done.
  Copy each run's `evidence/` into `<skill>-review/runs/<model>-<before|after>/run-<n>/` so the evidence outlives the cleanup.
- `-j <n>` runs up to 8 at once on the one subscription; leave it at 1 on a loaded machine.
- The run exits 1 if any case scores under `--threshold` (default 1.0); that is a result, not a crash.

## Reading the result

The `--json` file holds, per case, `arms.with[]`: one entry per run, each with `turns`, `error`, `tracePath` and `graders[]` (`name`, `passed`, `explanation`).
Count passes per grader across the runs for the table.
`tracePath` is that run's full session; read it for the passing run you read in full, and for any failure before you believe it.
An HTML report lands in `evals/results/<timestamp>/report.html`, local only with `--no-publish`.
