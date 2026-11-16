# Stage 9. Models inside the product

Run this stage only when the finished product itself calls a model while it runs.
A model that only helped build the product does not count.

If the product calls no model at runtime, write `studio/09-runtime-models.md` with `Picked: none` and the reason in `Why:`.

The five rules are decided early.
In stage 3, every part that calls a model at runtime gets the five rules written into its spec as tasks.
The lane builds them with the rest of the part.
Stage 9 does not design them. It audits them.

## Five rules

### 1. The model chooses from a typed grammar

Do not let a model write the final result freely.
Define a strict schema of allowed choices: a fixed list of kinds, styles and slots.
The model fills in the schema.
Validate the answer against the schema.
Reject anything that does not fit.

### 2. Deterministic code builds the result

Plain code turns the validated choice into the real output.
The model never writes the raw artefact, such as geometry, SQL or markup.
Then a model mistake cannot produce a broken artefact.
Give the code real anchors from the actual state, such as slots taken from what already exists.

### 3. Two independent reads before a refusal

When a model might refuse or flag a request, ask two separate reads.
Each read sees the case alone.
Refuse only when the two reads agree on the reason.
One flag alone lets the request through, or sends it to a person, as you decide.

### 4. A call budget per request

Give each request a fixed number of model calls.
Count them in code.
When the budget is gone, stop and return a safe fallback.
Write the number in the evidence file.

### 5. Code scores quality

Do not ask a model to grade its own output.
Score with code: size limits, valid shape, rule checks, measured features.
Reject and retry within the budget when the score is low.

## The stage 9 audit

After build and proof, check every runtime model call against all five rules.
Record one check per rule, with its result (pass or fail and the evidence).
If any check fails, send a fix task to the owning lane.
After the lane's fix is merged, refresh the stage 8 proof for that part.

## Extra points

- Use the cheapest tier that does the job at runtime. Write which tier each call uses.
- Log every call with its inputs and its result, so a bad output can be replayed.
- Run the model in the narrowest permissions that work, for example read-only.
- Test with a fake model that returns fixed answers, so tests do not depend on a live model.

## Evidence file: `studio/09-runtime-models.md`

Contains: each runtime model call, its tier, its grammar, the builder that uses the result, the budget number and the scoring checks.
It also holds one line per rule with its audit result, and any fix task sent back with the refreshed proof.
End with the three lines.
`Picked:` the runtime calls audited, each by name, or `none`.
`Left out:` runtime uses of a model you rejected.
`Why:` one sentence.
