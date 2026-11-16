# Stage 6 — Model per job

Goal: spend strong models where an error costs most, and cheap models on volume.
The skill names four tiers.
You map them to real models.

You make the first mapping at stage 0, because stage 1 already sends scouts and readers at a tier.
Stage 5 picks a tier for each lane from it, and may revise it.
Stage 6 runs before the build and records the intended tiers and the builder level you expect.
Stage 7 resume records what the lanes actually used.
There is one plan.
`/glitch-execute` runs every builder at the one builder level that plan names.
The user chooses that level at the stop of `/glitch-plan`.
If any part is deep tier, the brief tells the user to ask `/glitch-plan` for a higher builder level at that stop.
If no part is deep tier, the default level is fine.
The tier per part still guides the brief's task wording and the critic.

## The four tiers

- **deep.** Contracts, the parts that must be right, and the critic.
- **standard.** Most features and integration.
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
- `Builder level:` the level the plan names. Stage 7 resume records the level it actually names.
- A table: tier, model, family, reachable (yes or no).
- A table: part, tier, reason.
- `Tiers actually used:` the builder level the plan actually names, and the tier each lane had. `pending` until the build, then filled in at stage 7 resume.
- `Revision note:` what changed from the latest earlier mapping and why, including any change the build drove, or `none`.
- `Critic:` the model and family, or `none reachable`.
- `Same-family review:` yes or no.
  If yes, add the user's decision.

Then the ending lines.
