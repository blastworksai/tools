# Stage 8 — Prove it

Goal: done means shown.
A green test is not proof that a person can use the thing.

## Visual parts

A part is visual if a person looks at it.
1. Get the art direction: colours, type, spacing, mood.
   If there is none, ask the user for one, or write a short one and ask.
2. Fix the sizes before you start.
   Use at least one small and one large size, for example 390x844 and 1280x800.
3. Take a screenshot of the real running part at each size.
4. Judge each screenshot against the art direction.
   Say what matches and what does not.
5. Send each defect back to the owning lane as a task.
   You do not fix product code yourself.
   After the fix is merged, take new screenshots.
   Repeat until the screenshots match.
6. Check that each image file has the size you named.
7. Save the images in the project and list their paths.

## Every other part

1. Run the real part.
   Start it, call it, feed it real input.
2. Record the command and the output.
3. Show one case that must fail, and show that it fails.
4. A unit test alone does not count.
5. Send each defect back to the owning lane as a task.
   After the fix is merged, run the part again.

## The evidence file

`studio/08-proof.md` is never `none`.
It holds one block per part:
- `Part:` its name.
- `Kind:` visual or behaviour.
- `Proof:` screenshot paths with sizes, or the command and result.
- `Judged against:` the art direction path, or the expected output.
- `Result:` pass or fail, in plain words.

Then the ending lines.
