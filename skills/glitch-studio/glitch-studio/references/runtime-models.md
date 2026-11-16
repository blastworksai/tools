# Stage 9 — Models inside the product

This stage applies only when the product itself calls a model while it runs.
If it does not, write `studio/09-runtime-models.md` with `Picked: none` and the reason.

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

## The evidence file

`studio/09-runtime-models.md` holds:
- `Grammar:` where it is defined.
- `Builder:` the code that builds from it.
- `Refusal rule:` the two-read rule as built.
- `Budget:` calls per request.
- `Scoring:` the code that scores quality.

Then the ending lines.
