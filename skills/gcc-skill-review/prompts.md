# The five prompts

Word for word from Kem's Glitch Cat Club lab page "Find the Weak Step" (5 October 2026). By Kem, [Glitch Cat Club](https://glitchcatclub.com) · [@kem_glitch](https://www.instagram.com/kem_glitch/). MIT, see [LICENSE](LICENSE).
`I` is the person whose skill it is; `you` is the agent.
Kem had not re-run the method with this exact wording after three lines changed; treat a surprise as the wording's fault before the skill's.

## Prompt 1 of 5 · map it

Read this skill and the sample input beside it. List every step in
order. For each step tell me: could code do this or does it need
your judgement, what it takes in, what it leaves behind that I could
check. Then list what the skill leaves unsaid. Rank those by how
likely each is to change the result. Draw the steps as a Mermaid
flowchart with square boxes for steps code could do and rounded
boxes for steps that need judgement. Flag only the three unsaid
things most likely to change the result.

## Prompt 2 of 5 · leave evidence

Make a copy of the skill. Change only the copy. Each step must save
its result to its own file before the next step starts. Keep any
file names the skill already uses. End each file with three lines.
Picked: every item you kept, each by name, then the rule you used.
Left out: what you dropped. Why: one sentence. Fix nothing else,
even where you can see something unsaid. The next prompts need to
see it fail.

## Prompt 3 of 5 · write the checks

Here is a sample input and the answers I know are right. For each
step write one check that everything in my answer was picked. Write
a second check that nothing outside my answer was picked. Write them
as grader files for claude plugin eval. Use a pattern check where
the answer is a fact. Aim it at the Picked line. Use a short rubric
only where the answer is a judgement. Where I gave you no answer for
a step, ask me. Run the skill once to get one good set of files.
Show me each check passes on them. Then hand-write one wrong file
for each step. Show me its check fails.

## Prompt 4 of 5 · run and count

Run the copy of the skill once as a trial. Then run it five times on
the same input with claude plugin eval. Each run is a fresh session.
Keep every run's files. Give me a table with one row per check in
step order showing passes out of five. For every failure quote that
step's Picked line. Give it one of four verdicts: the step was
wrong, the skill left it open, an earlier step handed it a wrong
input, the check was wrong. Then read one run that passed
everything. Tell me anything wrong that no check caught.

## Prompt 5 of 5 · fix one sentence

Take the earliest step where the verdict was step wrong or skill
left it open. If every check passed, take what you found wrong when
you read the passing run. Write the missing check first. Show me it
fails on the runs you kept. Find the sentence in the skill that
allowed it. If the right answer depends on a rule only I know, ask
me for the rule. Change only what the failing runs show is needed.
If the step is arithmetic or sorting, tell me it should be code. If
a check was wrong, fix the check. Say so. Run it five times again.
Show me every check before and after.
