# GLITCH STUDIO

**Build a product with one orchestrator and many checked lanes, through Glitch.**

> **The method comes from the Chatdom.io build write-up (TwitchCon 2026 hackathon, 1st place): https://devpost.com/software/chatdom-io.**
> The wording here is ours; none of the write-up's text or code is copied.

## Why

A long build in one session drifts.
The agent forgets the plan, edits the same file twice, and calls a screen done that nobody has seen.
The write-up behind this skill shows another way.
One thread plans, writes the shared contracts, reviews and integrates.
Many fresh lanes each build one part, one small check at a time.
Nothing counts until it has been shown working.

Glitch already has the tools for much of this: `/glitch-idea`, `/glitch-plan` and `/glitch-execute`.
This skill does not repeat them.
It adds the parts they lack, and it shapes what you hand to them.

## What it does

The skill has ten stages, numbered 0 to 9.
Each stage writes one evidence file in a `studio/` folder in your project.

1. **Frame (0).** The main session is the orchestrator, not the typist.
2. **Align.** For a new idea, the skill suggests `/glitch-idea`.
   It never starts it for you.
3. **Study (1).** Scouts look for strong open source for the hard parts.
   Deeper reads take the best apart.
   Reading a page in a browser needs no yes.
   Every download, clone or install waits for your yes, and credits go in a third-party notices file.
4. **Domain skills (2).** Before product code touches an outside platform, a small skill for that platform exists.
   The skill looks for an existing one first.
5. **Parts, contracts, lanes (3, 4, 5).** The skill writes one planning brief and hands it to `/glitch-plan`.
   The brief carries the exact contract text. The first checkpoint's builder writes it, and the build commits it as the freeze, every separable part after it, and tasks cut on file boundaries and marked independent.
6. **Model per job (6).** Four tiers (deep, standard, bulk, light) mapped to the models your session can reach.
   The first mapping is made at stage 0, before the scouts start.
   Stage 6 records the intended mapping before the build, and the tiers actually used are filled in after it.
   `/glitch-execute` runs every builder at one level, so parts with very different tiers go in separate plans.
7. **Review and integrate (7).** `/glitch-execute` with Glitch orchestration runs the lanes.
   A reviewer of another model family reads every lane.
   Lanes commit in order, one commit each, and the tests run after each.
8. **Prove (8).** Visual parts get screenshots at fixed sizes.
   Every other part gets a real run.
9. **Models inside the product (9).** Only when the product itself calls a model.
   The planning brief asks for the rules as build tasks, and stage 9 audits them.

If the `studio/` folder already holds files, the skill reads them all.
It finishes any file that lacks the three ending lines first.
It finishes an open plan hand-off, and it stops while the build has not run.
Then it resumes at the first missing number.

## How to use it

Copy the inner [`glitch-studio/`](glitch-studio/) folder into the skills folder of your agent.
Then say "build this the studio way" and name the product.

## You need

- Glitch, with its `/glitch-idea`, `/glitch-plan` and `/glitch-execute` skills.
- A project folder under git.
- Enough reachable models to fill the four tiers.
  One model for all four tiers works, but the review is then same-family and you decide whether to accept it.

If you do not use Glitch, use the neutral `studio` skill from the same repository.
It holds all nine method points in one skill and needs no other skill.

## The limits

The skill is instructions, not code.
It cannot force a model to follow them, so the evidence files are how you check each stage.
It does not edit `/glitch-idea`, `/glitch-plan` or `/glitch-execute`.

## Credits

- **Method:** the Chatdom.io build write-up, https://devpost.com/software/chatdom-io.
- **Wording and packaging:** [blastworks.ai](https://www.blastworks.ai/).
- MIT licence, see [`LICENSE`](LICENSE).
