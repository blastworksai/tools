# Stage 6. Model per job

You make the first mapping in stage 0, because stage 1 already sends scouts and readers at a tier.
Stage 5 picks a tier for each lane from it, and may revise it. Say so if you do.
Stage 6 writes down the final mapping.

Different jobs need different amounts of thinking.
Pay for deep thinking only where a mistake is costly.
Use cheaper work for volume.

## The four tiers

- **deep.** The things that must be right: contracts, the core engine or model of the product, milestone reviews, and the critic.
- **standard.** Most features, integration, merges and servers.
- **bulk.** Volume work: assets, tests, sweeps and repeated variants. Fan it out, with one folder per worker.
- **light.** Scouting, summaries and quick lookups.

## Map tiers to your models

1. List the models you can actually reach in this session. Do not assume. Try them if you must.
2. For each tier, pick the model and the effort setting that fits. If you reach only one model, map every tier to it and vary only the effort.
3. Write the mapping table in `studio/06-model-tiers.md` (in stage 6, from the final mapping; the first one goes in `studio/00-frame.md`).
4. If a tier has no fitting model, say so. Use the nearest and record the gap.

The mapping belongs to this build.
Models change.
Do not put a model name into a spec or a lane brief. Write the tier.
The mapping table turns tiers into models.

## Give each part a tier

For every part in `studio/03-parts-and-specs.md`, write its tier and one line why.
Tasks inside a part may use a lower tier than the part's own tier. Say so.

## The critic

The critic should be a different model family from the author, so it does not share blind spots.
Check if one is reachable.
If yes, write which one.
If no, write "no second family reachable" and that the review is same-family.
The user decides whether to go on.

## Evidence file: `studio/06-model-tiers.md`

Contains:

- The mapping table: tier, model, effort, reachable (yes or no).
- A tier for every part, with one line why.
- The tiers the lanes actually used, one per lane.
- The critic line: model and family, or "none reachable".

End with the three lines.
`Picked:` the mapping you used.
`Left out:` models you could not reach or chose not to use.
`Why:` one sentence.
