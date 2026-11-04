#!/usr/bin/env python3
"""Deliver the TODO companion at actual workflow entry; CodexBWAI, MIT.

Instruction delivery only: no plan/publication writes, prompts, shell execution,
transcript reads, authentication or blocking exit codes. The owning planning
agent performs adoption through its normal permitted write/tool path.
"""
import json
import re
import sys
from pathlib import Path

COMPANION = str(Path(__file__).resolve().parent)

ENTRY = re.compile(r"^\s*[/\$]glitch-(plan|execute)(?:\s|$)")
NOTICE = (
    f"TODO interactive planning integration: read {COMPANION}/README.md "
    "and CONTRACT.md now. At /glitch-execute entry, deliberately adopt this exact "
    "canonical plan BEFORE implementation/operations: if it lacks the TERN-SESSION "
    "checkpoint block, add it through your normal authorised plan-write path, using "
    "the plan's already-agreed checkpoints and your verified current state. Preserve "
    "checkpoint names, conditions, approvals, Build choices and START HERE. Do not "
    "guess completion or ask the operator for the plan path. Identify your own durable "
    "agent PID using native ancestry, then publish this plan with the companion. "
    "For /glitch-plan, add the block and publish when the agreed plan is written. "
    "Maintain the block during execution. A descriptor or a previous publication "
    "does not complete this step. If this session is read-only or does not own the "
    "plan, report TODO unavailable instead of writing or adopting it. Fleet/BWPM "
    "work is excluded. Never send input to another agent."
)


def context(payload):
    event = payload.get("hook_event_name")
    if event == "SessionStart":
        return (f"TODO lifecycle: read {COMPANION}/README.md; clear "
                "your OWN inherited binding on fresh startup/reset, using your verified "
                "durable agent PID. Publish only when deliberately adopting your own "
                "interactive canonical plan. Never clear another agent's binding.")
    if event == "UserPromptSubmit":
        prompt = payload.get("prompt", payload.get("user_prompt", ""))
        return NOTICE if isinstance(prompt, str) and ENTRY.match(prompt) else None
    if event == "PreToolUse" and payload.get("tool_name") == "Skill":
        value = payload.get("tool_input")
        skill = value.get("skill") if isinstance(value, dict) else None
        return NOTICE if skill in ("glitch-plan", "glitch-execute") else None
    return None


def main():
    try:
        payload = json.load(sys.stdin)
        if not isinstance(payload, dict):
            return
        message = context(payload)
        if message:
            print(json.dumps({"hookSpecificOutput": {
                "hookEventName": payload["hook_event_name"],
                "additionalContext": message}}))
    except (ValueError, TypeError, OSError):
        # TODO must never block an agent or replace an existing safety hook.
        return


if __name__ == "__main__":
    main()
