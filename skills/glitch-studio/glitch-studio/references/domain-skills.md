# Stage 2 — Domain skills

Goal: no guessing at an outside platform.
Write or find a small skill for each platform before any product code touches it.

## When this applies

A platform applies when the product calls it, signs in with it, or reads data from it.
Examples: a payments service, a chat platform, a weather feed, a map service.
A library that runs inside your own process is not a platform.
If no platform applies, write `Picked: none` and the reason.

## Look first

Glitch version: before you write anything, look for an existing skill.
Search the skills folders your session can see.
Use the skill-finder skill when it is available.
If a skill covers the platform, read it and record its name.
Write a new one only for the gap.

## What a domain skill holds

Keep it small.
One page is usually enough.
- **Auth.** How a caller signs in, which token types exist, and how long each lasts.
- **Endpoints.** The calls the product needs: method, path, purpose.
- **Scopes.** Which permission each call needs.
- **Limits.** Rate limits and size limits, and what happens when you pass them.
- **Payloads.** One real example of each request and response, with the field names.
- **Traps.** What the documentation gets wrong or leaves unsaid.

Take the facts from the platform's own documentation.
If you cannot read it, say so in the skill and mark each fact as unchecked.

## The evidence file

`studio/02-domain-skills.md` holds one block per platform:
- `Platform:` its name.
- `Skill:` the name or path of the skill.
- `Found or written:` which one.
- `Endpoints:` the endpoints named in it.
- `Token types:` the ones named.
- `Limits:` the rate limits named.
- `Unverified:` the facts you could not check, or `none`.

Then the ending lines.
