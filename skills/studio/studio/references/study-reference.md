# Stage 1. Study reference

Purpose: do not reinvent a hard part when strong open source already solved it.
Study it first.
Then write your own spec with that knowledge.

## When to run it

Run it for a part that is hard and common.
Examples: a rendering engine, a network layer, a parser, a sync protocol, a map renderer.
Skip it for plain glue code.
If no part qualifies, write the evidence file with `Picked: none`.

## Steps

1. List the hard parts from the frame (stage 0).
2. For each hard part, send a light-tier scout to list candidates. Ask for name, link, licence, size, last activity and what it does well.
3. Choose the best one to three candidates per part. Prefer permissive licences. Mark any licence that limits reuse.
4. Tell the user, in one message, every download or clone you want to do. Give the target and the licence for each.
5. STOP. Wait for the user's yes. A yes to one item is not a yes to the rest. Reading a project page in a browser is not a download; cloning, downloading and installing are.
6. For each approved candidate, send a deep-tier reader to take it apart. Ask how it is built, which parts to learn from, which traps it avoids and what you should not copy.
7. Write one study note per part in the project, for example `studio-notes/<part>.md`. Keep it under one page.
8. Write credits and licences in `THIRD_PARTY_NOTICES.md` in the project: name, link, licence, what you took (an idea, a design or code), and where it lives in your project.

## Rules

- Never download, clone or install anything without the user's yes.
- Reading a project page in a browser needs no yes.
- Never copy code whose licence you did not read.
- Ideas and designs need credit too. Name the source in the code and in the notices file.
- If a licence is unclear, write that, and treat the code as not reusable.
- A study note says what to learn, not just what exists.

## Evidence file: `studio/01-study-reference.md`

Write:

- A table: part, candidates seen, candidate studied, licence, fetch approved (yes or no), study note path.
- The path of `THIRD_PARTY_NOTICES.md`.

End with the three lines.
`Picked:` the candidates studied, by name, and the rule you used.
`Left out:` the candidates and parts you skipped.
`Why:` one sentence.
