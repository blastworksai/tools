# Interactive planning companion — CodexBWAI, COMMANDER-993

Use this view for interactive `$glitch-plan` work only. Fleet execution and BWPM/FORGE are outside it.

Follow the full companion at `integrations/glitch-plan-session-view/CONTRACT.md`: add one explicitly agreed checkpoint block to the canonical plan, preserve stable plan/checkpoint ids, and keep the executor's current/blocked/done states consistent with its verified Progress evidence and sole START HERE. Deliberately adopt existing plans; never infer completion from prose or rewrite the whole plan to satisfy a parser.

The Files button first selects a live agent session. On an explicit TODO metadata request through native Tern, report only YOUR current canonical interactive plan: do not adopt work, infer a plan from the current directory or another pane, modify files, or continue a task because of this query.

Reply in exactly one line:

```text
TODO_PLAN_REPLY v1 {"request_id":"<the exact request id>","state":"active","path":"<absolute canonical path on your execution host>","plan_id":"<existing plan id in its TODO checkpoint block>"}
```

If you are not working on a plan, return the same request id with `"state":"none"`, omitting path/id. If you have an active plan without the explicit checkpoint block, return `"state":"unsupported"`; do not create a block just to answer. The query authorizes metadata disclosure only, never work or continuation. TODO exits its own flow on none/unsupported; it never closes your session. Unknown, stale and malformed replies are errors, not no-plan evidence.

The native agent endpoint and a verifiably empty sendable native composer are required. Terminal-only CLI agents without that structured composer are currently unsupported. TODO does not type protocol requests into arbitrary terminal prompts or replace existing drafts. Local means the execution host; ordinary reviewed SSH file transport can read a remote canonical plan. The selected file and reported stable id become the read-only source identity.

No hook is installed or required. The source companion is not automatically wired into managed Glitch skills. Customization/upstream adoption, exact-head review, authenticated real-client qualification and deployment remain explicit gates. Use native Tern for communication; Herdr is retired and Interceptor is unrelated.
