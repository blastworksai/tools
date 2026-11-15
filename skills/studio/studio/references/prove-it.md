# Stage 8. Prove it

Done means demonstrated.
Passing tests are not enough.
Someone must be able to see it work.

This stage is never `none`.

## Visual parts

A visual part is anything a person looks at: a page, a panel, a scene, an image, an animation.

1. Find the art direction. If none exists, write a short one now with the user: colours, fonts, mood, screen sizes. Save it in the project.
2. Choose fixed screen sizes. Use at least one small and one large size. Write them down, for example 390 by 844 and 1280 by 800.
3. Run the real product, not a mock.
4. Take a screenshot of the part at each size. Save it in the project, for example `proof/<part>-<width>x<height>.png`.
5. Check the real image size is the size you meant. Read the file header, do not trust the tool.
6. Judge each screenshot against the art direction. Write what matches and what does not.
7. Fix what is wrong. Take new screenshots. Repeat.
8. Check for overlap, clipped text and anything that crosses another element.

## Every other part

A part with no visual output still needs a real run.

1. Run the real code, with real input, as a user would. Not only unit tests.
2. Keep the command and its real output in `proof/<part>-run.md`.
3. Include one case that should fail and show that it fails the right way.
4. For a part that calls an outside platform, use a safe sandbox or fixture if one exists. Do not use real money or real user data.

## Rules

- Proof comes from files you can open, not from a claim.
- A screenshot taken before the last change does not count.
- If a part cannot be shown, say so and say why. Do not mark it done.

## Evidence file: `studio/08-proof.md`

One row per part: part, kind (visual or run), proof file paths, sizes checked, result, what is wrong.
End with the three lines.
`Picked:` the proofs made.
`Left out:` parts or sizes not proven and why.
`Why:` one sentence.
`Picked: none` is not allowed here.
