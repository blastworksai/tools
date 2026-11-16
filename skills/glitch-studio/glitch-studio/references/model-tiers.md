# Stage 6 — Model per job

Goal: spend strong models where an error costs most, and cheap models on volume.
The skill names four tiers.
You map them to real models.

You make the first mapping at stage 0, because stage 1 already sends scouts and readers at a tier.
Stage 5 picks a tier for each lane from it, and may revise it.
Stage 6 writes down the final mapping.

## The four tiers

- **deep.** Contracts, the parts that must be right, and the critic.
- **standard.** Most features, integration and merges.
- **bulk.** Volume work: assets, tests, sweeps.
  Fan it out, with one folder for each worker.
- **light.** Scouting and summaries.

## Steps

1. List the models this session can actually reach.
   Do not list a model you have not seen offered.
2. Map each tier to one of them.
   Write the model's family next to it.
   If you can reach only one, map all four tiers to it.
3. Pick the critic.
   It must be from a different family than the author of the work it reads.
   If no other family is reachable, write that the review is same-family.
   The user decides whether to accept it.
4. Give every part from stage 3 one tier, with one line of reason.
5. Name the effort or depth setting for each tier only if the host offers one.

## The evidence file

The first mapping goes in `studio/00-frame.md`.
`studio/06-model-tiers.md` holds:
- A table: tier, model, family, reachable (yes or no).
- A table: part, tier, reason.
- `Tiers used:` the tier each lane actually used.
- `Revision note:` what changed from the stage 0 mapping and why, or `none`.
- `Critic:` the model and family, or `none reachable`.
- `Same-family review:` yes or no.
  If yes, add the user's decision.

Then the ending lines.
