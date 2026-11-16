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
- Art direction: <path, fixed screenshot sizes, or "no visual parts">
- Third-party notices file: <path, or "none">

## Tiers

The tier mapping is: <list: tier, model, from the latest mapping>.
Each part has one tier: <list: part, tier>.
The tier guides the builder level.
`/glitch-execute` runs every builder at the one level this plan names.
Choose that level for the hardest part in this plan.
This plan covers only parts that fit one level: <list of parts>.

## Runtime models

These parts call a model while the product runs: <list, or "none">.
For each of them, add these as tasks inside the part's own task:
1. The model fills a typed grammar of fixed options, and code builds the result from it.
2. Two independent reads must agree before a refusal.
3. A fixed call budget for each request, counted in code.
4. Code scores quality, never the model.
Also: least access for the model, validation of every reply, and a fallback that fails closed.

## Checkpoint rules

If there is one part and nothing shared, skip rule 1.
There is then no contracts checkpoint.
The freeze point is the base commit before the first lane.
Write that commit's name here: <base commit, or "not used">.

1. The FIRST checkpoint writes the frozen contracts.
   - There is one contracts place: <folder, for example shared/contracts/>.
   - The exact contract text is below. It was written by the studio orchestrator before this plan.
   - The task of this checkpoint is one builder task.
     The builder writes that text into the contracts place, word for word.
     It changes nothing else.
   - The `/glitch-execute` orchestrator checks that the file equals the text below.
     Then it commits the file as the freeze commit, before any lane starts.
   - The contracts are: <list: each shared type or interface, and which parts use it>.
   - Only the studio orchestrator changes a contract.
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
   - A visual part is shown by screenshots at these sizes: <list of sizes, from the art direction file>.
   - Every other part is shown by a real run of it.
8. There are no lane merges.
   The lanes commit in order on the same branch, one commit per lane.
   The tests run after each lane commit.
9. The plan ends with a final checkpoint where a read-only reviewer of another model family reads every lane's diff.

## Contract text

<the exact contract text, as written in the studio contracts file, or "none">

## Build choices

orchestration: glitch
```
