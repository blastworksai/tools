# Stages 3 and 4. Parts, specs and frozen contracts

Many lanes can build at once only if each one owns a clear piece and every shared type is fixed.

## Stage 3. Parts and specs

### Split into parts

A part is a piece of the product that a lane can build alone.
Good signs: it lives in its own folder, it has a clear input and output, and another part needs it only through a contract.
A part that touches every other part is too big.
Cut it again.

### Write a spec per part

One file per part, for example `specs/<part>.md`.
Each spec holds:

- Goal: what the part does, in three lines.
- Folder scope: the one folder this part may edit.
- Contracts it uses: names of the shared types and interfaces.
- Domain skills it must read: from stage 2.
- Study notes it must read: from stage 1.
- Art direction, if the part is visual.
- A task list.
- For a part that calls a model at runtime: one task for each of the five rules in [runtime-models.md](runtime-models.md).

Write each spec so that a fresh session can pick it up cold.
It has no memory of your conversation.
Everything it needs is in the spec and the files the spec names.

### One task is one check and one commit

A task is small.
It has one check that can fail, and one commit when the check passes.
Write each task as: what to make, how to check it, what the commit says.
A task that needs two unrelated checks is two tasks.
A task that edits outside the spec's folder is wrong. Move it or change the spec.

### Evidence file: `studio/03-parts-and-specs.md`

One row per part: part, spec path, folder scope, task count, contracts used, calls a model at runtime (yes or no).
End with the three lines.
`Picked:` the parts, each by name.
`Left out:` what you decided not to build.
`Why:` one sentence.
STOP and show the user the part list before stage 4.

## Stage 4. Frozen contracts

### What a contract is

A contract is a shared type, an interface or a message shape that two or more parts use.
Examples: a record both a producer and a consumer read, an event name and its payload, a function signature a lane must implement.

### Write them first

Put all contracts in one place, for example a `contracts/` folder or one shared package.
Write them yourself, as the orchestrator.
Commit them before any lane starts.
That commit must come before every lane's first commit.
With one part and nothing shared, there is no contract file.
Record the base commit before the first lane as the freeze point, skip writing and committing contracts, and write `Picked: none` with the reason.

### Freeze them

From that commit on:

- Only the orchestrator changes a contract.
- A lane never edits the contracts folder. Its scope does not include it.
- A lane that needs a change stops. It writes what it needs and why into a note, and tells you.
- You decide. If you change a contract, you commit the change, tell every lane that uses it, and record it in the evidence file.
- A change that breaks other lanes may need those lanes to rebase before they go on.

### Write contracts with care

Use deep-tier work for contracts.
A wrong contract costs every lane.
Give each type a short comment saying who produces it and who reads it.
Add a small check that the contracts compile or validate.

### Evidence file: `studio/04-contracts.md`

List each contract: name, path, producer, readers.
Write the commit that froze them.
Add a section "Changes after freeze", empty if none, otherwise each change with its reason and the lanes told.
End with the three lines.
`Picked:` the contracts, each by name.
`Left out:` shared things you decided stay local to one part.
`Why:` one sentence.
With one part only and no sharing, write the base commit as the freeze point, then `Picked: none` and the reason.
