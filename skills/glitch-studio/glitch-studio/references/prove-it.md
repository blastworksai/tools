# Stage 8 — Prove it

Goal: done means shown.
A green test is not proof that a person can use the thing.

## Visual parts

A part is visual if a person looks at it.
1. Use the art direction from stage 3: colours, type, spacing, mood.
   The file and the fixed sizes are in file 03.
2. Use those sizes.
   They have at least one small and one large size, for example 390x844 and 1280x800.
3. Take a screenshot of the real running part at each size.
4. Judge each screenshot against the art direction.
   Say what matches and what does not.
5. Send each defect back to the owning lane as a fix task.
   You do not fix product code yourself.
   Give the user the task text to paste after `/glitch-plan` in a fresh window.
   Then give the `/glitch-execute` line it prints.
   After the fix is committed, take new screenshots.
   Repeat until the screenshots match.
6. Check that each image file has the size you named.
7. Save the images in the project and list their paths.

## Every other part

1. Run the real part.
   Start it, call it, feed it real input.
2. Record the command and the output.
3. Show one case that must fail, and show that it fails.
4. A unit test alone does not count.
5. Send each defect back to the owning lane as a fix task.
   Give the user the task text to paste after `/glitch-plan` in a fresh window.
   Then give the `/glitch-execute` line it prints.
   After the fix is committed, run the part again.

## The evidence file

`studio/08-proof.md` is never `none`.
It holds one block per part:
- `Part:` its name.
- `Kind:` visual or behaviour.
- `Proof:` screenshot paths with sizes, or the command and result.
- `Judged against:` the art direction path, or the expected output.
- `Result:` pass or fail, in plain words.

Then the ending lines.
