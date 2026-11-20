# ORCH+ backlog

This is a list of future work.
Item 1 has shipped (see below).
None of the other items is implemented.
None of them is authorised for build.
They are requests recorded for later, not promises.

## 1. Choose model and effort

Let the person choose the model and the effort level, not only the provider and account.
The provider's real capabilities and the saved launch configuration stay authoritative.
Shipped in ORCH+ 0.7.0 with SPAWN 0.8.0 (SKILLS-211; SPAWN's per-agent defaults shipped earlier).
After the person picks an agent, an optional form takes a model id and an effort for that one start.
The choice rides on that launch request, SPAWN applies it with the same rules as the saved fields and never edits the saved agent, and the agent row shows it as requested, not as confirmed.
Remaining: an agent saved as the preferred orchestrator or worker, a rollover successor and a quota-routed substitute still start on their saved settings, without the form.

## 2. Structured questions in the central orchestrator

Agents in orchestrated panes sometimes ask the person a structured question.
Today the person must find that pane to answer it.
The wish is to show the question in the central orchestrator and send the owner's answer back to the exact question that was asked.
This needs real question, answer and provenance APIs.
It must not work by reading or writing the agent's composer text.

## 3. Glitch Project Discovery

A switch for discovering Glitch projects automatically.
There is no active switch today, because it would do nothing.
It returns only when it has real behaviour that the person can observe.

## 4. Default Work-Source Switch

A setting that chooses where new work comes from by default.
There is no such setting today.
A future version must really change how work is taken in.
It must not be a decorative dropdown.

## 5. Open the source plan from its board card

Clicking a plan's native board card should open the source plan.
Today the **Open plan** link beside the plan title in ORCH+ does this.

## 6. Safe cross-client controller takeover

Let a second client take over control of existing work.
It must not create duplicate agents.
It must not erase uncertainty about what the previous controller did.

## 7. Show the cleanup summary when the user returns to the orchestrator conversation

After the scheduled cleanup, tell the person which communication resources remain and what needs attention.
The person should not need to open or click the ORCH+ panel to see it.
Today the summary appears on the next panel interaction.
Current SDK events cannot reliably tell a human message from an agent or automation message.
A future version must not trigger on every automated message.

## 8. Tern-native usage when USAGE is not installed

Tern 0.9.22 shows its own usage statistics for some providers in the widget bar.
When USAGE is not installed, offer Tern's own usage for those providers instead of showing usage as unavailable.
USAGE stays the recommended path, because it reports usage per account across many accounts, which Tern's own statistics do not.
First find out which providers and which data Tern exposes to plugins.
Shipped in 0.6.3: when USAGE is not installed, the agent picker adds one muted line under "Usage unavailable" that points to Tern's own widget (widget bar, AI usage limits) and to USAGE for per-account figures.
It shows no number.
Remaining: Tern 0.9.22 gives plugins no usage read API, so real numbers inside ORCH+ need a request to the Tern authors (for example a call that returns provider, window name, used percent, reset time and account label).
Quota routing stays held without USAGE.
Tracked as SKILLS-195.
