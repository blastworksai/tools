# Stage 5. Lanes

A lane is one fresh agent session working one spec.

## Set up

For each spec:

0. Before the first lane, pick a tier for each lane from the mapping you made in stage 0. Use [model-tiers.md](model-tiers.md). You may revise the mapping; say so if you do. Write down the lane tiers; stage 6 records them.
1. Make a git worktree on its own branch, cut from the freeze commit recorded in stage 4 (the base commit when there are no contracts).
2. Give the lane the spec path and tell it its folder scope.
3. Tell the lane to read the domain skills and study notes the spec names.
4. Start a fresh sub-agent or fresh session at the lane's tier. It must not inherit your conversation.

Run lanes in parallel only when their folder scopes do not overlap.
Run them one after another when they do.
Do not start more lanes than you can review.

## The loop

The lane repeats this until the task list is done:

1. Take the next task from the spec.
2. Write its check first.
3. Run the check. See it fail. If it passes before any code, the check is wrong. Fix the check.
4. Write the smallest change that makes it pass.
5. Run the check. See it pass.
6. Run the other checks in the lane's folder.
7. Commit. One task, one commit, with the check in the same commit.
8. Go back to step 1.

## Rules for a lane

- Never edit outside the folder scope.
- Never edit the contracts.
- If a contract is wrong or missing, stop and ask the orchestrator. Do not work around it.
- If a task is unclear, stop and ask. Do not guess.
- Do not merge. Do not touch other branches.
- Leave the worktree clean at the end.
- At the end, write a short report: tasks done, tasks not done, anything odd.

## Rules for the orchestrator

- Check each lane's commits touch only its folder. Use the commit file lists.
- Answer a lane's stop note fast. A stopped lane costs time.
- Record each contract change in `studio/04-contracts.md`.
- Keep lane work small enough to review in one sitting.

## Evidence file: `studio/05-lanes.md`

One row per lane: lane name, spec, branch, worktree path, folder scope, task count, commit count, tier chosen, stops raised.
End with the three lines.
`Picked:` the lanes started, each by name.
`Left out:` specs you did not start, and why.
`Why:` one sentence.
