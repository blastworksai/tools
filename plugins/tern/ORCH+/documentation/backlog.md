# ORCH+ backlog

This is a list of future work.
None of these items is implemented.
None of them is authorised for build.
They are requests recorded for later, not promises.

## 1. Structured questions in the central orchestrator

Agents in orchestrated panes sometimes ask the person a structured question.
Today the person must find that pane to answer it.
The wish is to show the question in the central orchestrator and send the owner's answer back to the exact question that was asked.
This needs real question, answer and provenance APIs.
It must not work by reading or writing the agent's composer text.

## 2. Glitch Project Discovery

A switch for discovering Glitch projects automatically.
There is no active switch today, because it would do nothing.
It returns only when it has real behaviour that the person can observe.

## 3. Default Work-Source Switch

A setting that chooses where new work comes from by default.
There is no such setting today.
A future version must really change how work is taken in.
It must not be a decorative dropdown.

## 4. Show the cleanup summary when the user returns to the orchestrator conversation

After the scheduled cleanup, tell the person which communication resources remain and what needs attention.
The person should not need to open or click the ORCH+ panel to see it.
Today the summary appears on the next panel interaction.
Current SDK events cannot reliably tell a human message from an agent or automation message.
A future version must not trigger on every automated message.

## 5. Open the source plan from its board card

Clicking a plan's native board card should open the source plan.
Today the **Open plan** link beside the plan title in ORCH+ does this.

## 6. Safe cross-client controller takeover

Let a second client take over control of existing work.
It must not create duplicate agents.
It must not erase uncertainty about what the previous controller did.

## 7. Choose model and effort

Let the person choose the model and the effort level, not only the provider and account.
The provider's real capabilities and the saved launch configuration stay authoritative.
