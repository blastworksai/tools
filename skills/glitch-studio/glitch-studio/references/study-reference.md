# Stage 1 — Study reference

Goal: reuse proven designs for the hard parts, and credit them.
Do this before you write the spec for a part.

## Which parts

Pick a part when strong open source probably exists for it.
Examples: a map renderer, a network layer, a mesher, a chart library, a parser.
Skip a part that is plain product logic.
If no part qualifies, write `Picked: none` and the reason.

## Steps

1. **Scout (light tier).**
   One scout per part.
   Each scout lists up to five candidates: name, link, licence, size, last activity, and one line on fit.
   Use the tier mapping from stage 0.
   A scout may read what is on disk and may read project pages in a browser.
   A browser read is not a download.
2. **Ask the user.**
   Before any download, clone or install, show the user a list.
   Each row names the target and its licence.
   Wait for the user's yes.
   A yes to one item is not a yes to the rest.
   Do one fetch per yes, or one list per yes if the user says so.
   A candidate with a licence your project cannot use is not offered.
3. **Take apart (deep tier).**
   One agent per chosen candidate.
   It reads the design, not only the code.
   It answers: what idea do we take, what do we leave, what breaks if we copy it, and what does it cost to adopt.
4. **Leave a study note** per candidate, in `studio/notes/<part>-<candidate>.md`.
   Keep each note short: idea, evidence, decision, credit.
5. **Credits.**
   Add each source to a third-party notices file in the project root (for example `THIRD_PARTY_NOTICES.md`).
   Give the name, link, licence, and what you took.
   If you took only an idea and wrote your own code, say so.

## The evidence file

`studio/01-study-reference.md` holds:
- `Parts studied:` the parts, or `none`.
- One line per candidate: part, name, licence, user's yes (date), `no (date)` for a refused fetch, or `not asked`.
- `Fetches:` each download, clone or install with its target, its licence and the user's yes, or `none`.
- `Notes:` the paths of the study notes.
- `Notices file:` its path.

Then the ending lines.
