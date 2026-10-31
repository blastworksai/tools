# skillshare

Skills and prompts from Blastworks, free to use under the MIT licence.

## ⚠️ Not a condom. Not a guarantee.

These are little helpers, not security products.
A check that finds nothing does not mean something is safe.
No guarantees, no warranty, and no liability if you get burned anyway.

## Contents

| Item | What it does |
| --- | --- |
| [DANGER PROTOCOL](skills/danger-protocol/) | Read-only check of a GitHub repo before you install or run it. |

### Tern plug-ins

| Plug-in | What it does |
| --- | --- |
| [TERN FLEET USAGE](skills/tern-fleet-usage/) | Read-only Tern plug-in for sanitized subscription usage feeds. |

## How to use a skill

- **Claude Code:** copy the skill's folder into `~/.claude/skills/` (or your project's `.claude/skills/`), then ask for it by name.
- **Any other agent (Codex, Cursor, …):** paste the contents of `SKILL.md` as your prompt.

For DANGER PROTOCOL specifically:

- Run it in a throwaway VM or container, not on the machine with your passwords, SSH keys and crypto.
- Keep your agent's permission prompts on. No `--yolo`, no `--dangerously-skip-permissions`.
- Don't open the repo in your editor in trusted mode.
- It reads the source, not the installer you download. Those are not proven to be the same thing.

## Licence

MIT. See [LICENSE](LICENSE).
