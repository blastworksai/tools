# Stage 7. Review and integrate

A lane that finished is not a lane that is right.
Review every lane before it merges.

## Review each lane

For each lane, in turn:

1. Read the diff against the spec. Does it do what the spec says, and only that?
2. Check the file list of every commit. Nothing outside the folder scope.
3. Check the contracts folder is untouched.
4. Check each task has one commit and one check.
5. Run the lane's checks yourself. Do not trust the lane's report.
6. Write down findings. Each finding names a file and a line or a task.

Send fixes back to the lane as a new task.
Do not fix a lane's work yourself unless the fix is a one-line integration change.

## The adversarial critic

For each lane, or for each group of lanes at a milestone, start a read-only critic.

- The critic reads. It edits nothing and runs no commands that change files.
- The critic is deep tier.
- Use a different model family from the lane's author whenever one is reachable.
- If none is reachable, write in the evidence file that the review is same-family, and ask the user to decide. STOP until they answer.
- Brief the critic with the spec, the contracts and the diff. Ask it to find wrong assumptions, missing cases, scope creep and claims nobody can test.
- Do not hand the critic your conclusion. A critic that is told the answer tends to agree.
- Take each finding as a lead. Check it yourself before you act on it.

## Integrate

Merge lanes one at a time.

1. Pick the next lane. Prefer the one that others depend on.
2. Merge it into the main line. Resolve conflicts yourself.
3. Run the full test suite on the merged result.
4. If tests fail, find the cause. Revert the merge if you cannot fix it fast.
5. Only then merge the next lane.

Never merge two lanes and test once.
Then you cannot tell which one broke the build.

After the last merge, run the full suite again and check the contracts have no unrecorded change.

## Evidence file: `studio/07-review-and-integrate.md`

One row per lane: lane, your review result, findings, critic model and family, critic result, merge commit, test result after the merge.
State clearly whether any review was same-family and what the user decided.
End with the three lines.
`Picked:` the lanes merged, in order.
`Left out:` lanes not merged and why.
`Why:` one sentence.
