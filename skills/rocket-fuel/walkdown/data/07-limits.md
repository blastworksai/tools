# rocket-fuel run 2026-11-09_e2a595c: not examined

- Stage 02-reader validation INCOMPLETE (gate 20/31, negative 22/24, recall 1/1; skipped: 13 rows): its zeros are not validated for the skipped checks.
- (02-reader) tesseract not installed (no tesseract binary, no pytesseract): images and PDF pages are skipped for OCR (read.divergence skip); images and PDFs with no text layer are listed as read.unread
- (02-reader) html render: playwright not installed: HTML files are read with static style only (read.divergence skip, carrier rendered)
- (02-reader) v1 limit: the language check (read.language) reads prose only: Markdown, plain text, PDF, DOCX, and OCR text; Markdown code blocks, comments in code, config values, and HTML are not checked for language, and a paragraph under five words is too short to judge
- (03-graph) v1 limit: manifest versus disk compares skills, agents, and commands, and only the kinds a manifest names; a manifest that names none relies on its folders and is not compared, and plugins a marketplace leaves out are not compared
- (04-phrases) limit: files that do not decode as text (PDF, DOCX, images) are scanned from stage 2's extracted text, phrase patterns only
- (05-capability) stage 5 limit: a Bash grant is recorded under private-data and as execute posture, never as external-comms; Bash can reach the network, as can every shell, so this map does not count it there
- (05-capability) stage 5 limit: hook bytes are an estimate from the sizes of files the hook script references (stage 3 static edges); hooks are never run to measure their output
- soft.label skipped for SKILL.md: no labeling backend
- soft.read skipped for None: no relational backend
- (06-soft) skipped: soft.label x1: no labeling backend
- (06-soft) skipped: soft.read x1: no relational backend
- Static examination only. Nothing in the artifact was executed, fetched, or installed.
- Stage 6 answers are located observations from the backends section 6 names; they never change a stage 1 to 5 finding. Hit counts carry a benign share only when stage 6 labels ran.
- Version drift (class 8): each run examines one pinned copy. walkdown.py compares it with the previous run of the same repository when there is one (changes.md next to this report); what the artifact becomes after its next update is seen only by auditing it again.
- English-language scope: the phrase layer is blind to non-English text (stage 2 lists non-Latin runs, and prose passages in another language in Latin script; a short line can slip past that check).
- Stage 4 matches patterns; a payload phrased outside every pattern reads as no hit. A zero here is not safety.
