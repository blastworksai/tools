# Stage 2. Domain skills

Purpose: an agent that guesses an outside API gets it wrong.
Give it a small skill that holds the facts, before any product code touches that platform.

## What counts as an outside platform

Any service or API your product calls or listens to.
Examples: a payments service, a chat platform, a weather feed, a map service, a login provider.
A library you install is not a platform.
Its own documentation is enough.

## Steps

1. List every outside platform from the frame (stage 0).
2. For each one, look for an existing skill first. Check your agent's skills folder and any skill library the user has. Use it if it fits.
3. If none exists, write a small domain skill. Keep it under about 150 lines.
4. If you must read documentation online for it, tell the user the target and wait for a yes first.
5. Check the skill against the platform's own documentation. Mark anything you could not verify.

## What a domain skill holds

- What the platform is for, in two lines.
- Auth: the token types, how to get each, how long each lasts, where secrets live. Never write a real secret into the skill.
- Endpoints or event types that the product uses: name, method, inputs, outputs.
- Scopes or permissions each endpoint needs.
- Rate limits and what to do when you hit one.
- Payload shapes, with one real example of each.
- Known traps and error codes.
- Where the official documentation lives.

List only what the product needs.
A long list of endpoints the product never calls is noise.

## Rules

- Write domain skills before the lanes start, so every lane can read them.
- A lane reads the domain skill for its part. It does not guess the platform.
- No secrets in a skill, ever.
- When the platform changes, update the skill. Tell the lanes.

## Evidence file: `studio/02-domain-skills.md`

Write one row per platform: platform, skill path, found or written, endpoints covered, token type, rate limit, what is unverified.
Write the skill files themselves in the project, for example `skills/<platform>/SKILL.md`.

End with the three lines.
`Picked:` the platforms that got a skill.
`Left out:` the platforms or endpoints you skipped.
`Why:` one sentence.
With no outside platform, `Picked: none` and say why.
