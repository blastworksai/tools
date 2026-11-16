# Planning brief

This is the text you hand to `/glitch-plan`.
Fill every placeholder in `<angle brackets>` from this project.
Remove nothing else.
The user pastes the result after `/glitch-plan` in a fresh window.

## The text

```
Plan the build of <product name>: <one-sentence outcome in the user's words>.

This plan will be built with Glitch orchestration.
Cut it so that many fresh builders can work side by side without touching the same file.

## Parts

The separable parts are:
<list: part name, one line on what it does, the folder it owns>

## Mandatory reading

Every builder reads these before it writes anything.
List them in the plan's context references as mandatory reading:
- Study notes: <paths to the notes from stage 1, or "none">
- Domain skills: <names or paths from stage 2, or "none">
- Art direction: <path, or "no visual parts">
- Third-party notices file: <path, or "none">

## Checkpoint rules

1. The FIRST checkpoint writes the frozen contracts.
   - There is one contracts place: <folder, for example shared/contracts/>.
   - The orchestrator writes it, and it is frozen before any lane starts.
   - The contracts are: <list: each shared type or interface, and which parts use it>.
   - Only the orchestrator changes a contract.
   - A lane that needs a change stops and asks.
2. Parts that can be built at the same time share one later checkpoint.
   `/glitch-execute` runs side by side only the tasks inside one checkpoint, and it lands checkpoints one at a time.
   A part that needs another part's result goes in a checkpoint after it.
3. Inside that checkpoint, each part is one task that owns one folder.
   The task lists its steps in order.
   Cut on file boundaries: no two tasks share a file.
4. Mark each of these tasks with `**INDEPENDENT**`.
   These tasks are the lanes.
   Each lane has one folder scope and never edits outside it.
5. A task that must wait states why on its own line, as `SEQUENTIAL: <reason>`.
6. Each step is one check.
   The builder writes the check, sees it fail, makes it pass, and takes the next step.
   The builder runs no git and reports each step: the check file, the failing run and the passing run.
   The orchestrator verifies the lane against the files on disk.
   Then it makes one commit for that lane, touching only the lane's folder.
7. Each checkpoint's validation shows the work done, not only tests green.
   - A visual part is shown by screenshots at these sizes: <list of sizes>.
   - Every other part is shown by a real run of it.
8. The plan ends with a final checkpoint where a reviewer of another model family reads every lane.
   Lanes merge one at a time, and the tests run after each merge.

## Build choices

orchestration: glitch
```
