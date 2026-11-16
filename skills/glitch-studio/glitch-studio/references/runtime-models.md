# Stage 9 — Models inside the product

This stage applies only when the product itself calls a model while it runs.
If it does not, write `studio/09-runtime-models.md` with `Picked: none` and the reason.

## Decided early, audited late

The four rules are decided early.
The planning brief asks that every part which calls a model at runtime gets the four rules as tasks.
The lane builds them with the rest of the part.
Stage 9 does not design them.
It audits them.

## The four rules

1. **The model chooses; code builds.**
   Define a typed grammar: a fixed set of options and fields.
   The model fills it in.
   Deterministic code turns the result into the real output.
   The model never writes the final artefact directly, so it cannot make a broken one.
2. **Two reads must agree before a refusal.**
   Two independent model calls check the same input.
   Refuse only when both raise the same concern.
3. **A call budget for every request.**
   Set a fixed number of model calls per request.
   Stop when it is spent.
4. **Code scores quality.**
   The host program measures the result.
   The model does not grade its own output.

## Also check

- The model runs with the least access it needs.
- Model output is validated against the grammar before anything uses it.
- A failed or invalid reply has a defined fallback that fails closed.

## The stage 9 audit

After build and proof, check every runtime model call against all four rules.
Record one check per rule, with its result (pass or fail, and the evidence).
Also check the three controls under "Also check".
Record one audit line for each, with its result and evidence.
If a check fails, write a fix task for the owning lane.
Give the user the task text to paste after `/glitch-plan` in a fresh window.
Then give the `/glitch-execute` line it prints.
After the fix is committed, refresh the stage 8 proof for that part.

## The evidence file

`studio/09-runtime-models.md` holds, per runtime call:
- `Tier:` the tier the call uses.
- `Grammar:` where it is defined.
- `Builder:` the code that builds from it.
- `Refusal rule:` the two-read rule as built.
- `Budget:` calls per request.
- `Scoring:` the code that scores quality.

It also holds one audit line per rule, with its result and evidence.
It holds one audit line each for least access, reply validation and the fail-closed fallback, with result and evidence.
It lists any fix task and the refreshed stage 8 proof.

Then the ending lines.
