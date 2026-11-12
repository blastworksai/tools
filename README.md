<p align="center">
  <a href="https://www.blastworks.ai/"><img src="https://raw.githubusercontent.com/blastworksai/howgozit/master/assets/blastworks-banner.png" alt="Blastworks.ai" width="100%"></a>
</p>

# TOOLS

You'll find skills and tools that I've tinkered with, that I find useful, and that I want to share with the world here. 
Everything is MIT License, so fork away. Feedback is appreciated, and stars are a dopamine hit, so hit me.

Published [Walkdown](https://github.com/BytesFromToby/Walkdown) reviews cite findings to file and line.
Where available, follow the Walkdown link in the table for the results.

## SKILLS

| Skill | What it does | Walkdown review |
| --- | --- | --- |
| [DANGER PROTOCOL](skills/dangerprotocol/README.md) | Read-only check of a GitHub repo before you install or run it. | [results](https://blastworksai.github.io/tools/skills/dangerprotocol/walkdown/summary.html) |
| [ROCKET FUEL](skills/rocket-fuel/README.md) | Founder-led collaboration with assigned seats and Operator-selected BASIC or FULL adversarial convergence. | [results](https://blastworksai.github.io/tools/skills/rocket-fuel/walkdown/summary.html) |
| [TERN PLUGIN DEVELOPMENT](skills/tern-plugin-development/README.md) | Create, test, debug, and package Tern plugins with isolated integration tests and pure Luau modules. | [results](https://blastworksai.github.io/tools/skills/tern-plugin-development/walkdown/summary.html) |
| [GCC SKILL REVIEW](skills/gcc-skill-review/README.md) | Find the weak step in your own skill: map its steps, check each one over five fresh runs, fix the one that fails and prove the fix. Method by Kem, [Glitch Cat Club](https://glitchcatclub.com) · [@kem_glitch](https://www.instagram.com/kem_glitch/). | [results](https://blastworksai.github.io/tools/skills/gcc-skill-review/walkdown/summary.html) |
| [GLITCH IDEA](skills/glitch-idea/README.md) | Capture a software idea, explore it step by step in a local browser page with your agent, and hand a planning prompt to `/glitch-plan`. Opens on your own computer over SSH, docked in Tern. | [results](https://blastworksai.github.io/tools/skills/glitch-idea/walkdown/summary.html) |
| [IDEA DISCOVERY](skills/idea-discovery/SKILL.md) | Discover ideas worth exploring with AI through a guided conversation. | Not published |

## PLUGINS

| Name | Plugin for | What it does |
| --- | --- | --- |
| [TODO](plugins/tern/TODO/README.md) | Tern | Interactive `/glitch-plan` checkpoints, read from the agent’s canonical plan locally or over SSH. |
| [WORK](plugins/tern/WORK/README.md) | Tern | Native pane listing active [Glitch](https://github.com/Glitch-Cat-Club) workspaces known to `/work-on`, with per-row GitHub links and a Work On button that opens an agent beside WORK. [SPAWN](plugins/tern/SPAWN/README.md) optional: with it, Work On shows a drop-down of available SPAWN agents; without SPAWN, Work On opens your default agent. |
| [SPAWN](plugins/tern/SPAWN/README.md) | Tern | Define and SPAWN your (entire) agentic army. |
| [USAGE](plugins/tern/USAGE/README.md) | Tern | Show your subscription usage across all agents. DEPENDENCY: NEEDS [SPAWN](plugins/tern/SPAWN/README.md). |
| [ORCH+](plugins/tern/ORCH+/README.md) | Tern | Orchestration+ Basic Improvements to Native Tern Orchestration. DEPENDENCY: NEEDS [SPAWN](plugins/tern/SPAWN/README.md) 0.4.0+; [USAGE](plugins/tern/USAGE/README.md) 2.1.0+ optional for quota routing. |
| [GLITCH IDEA](skills/glitch-idea/glitch-idea/tern-plugin/README.md) | Tern | Opens the GLITCH IDEA page, already paired, in a pane above your focused pane. Part of the [GLITCH IDEA](skills/glitch-idea/README.md) skill. |

Each plugin checks GitHub for its own newer version and updates itself from Tern's command palette (*Check for updates*). See [the shared updater](shared/tern-updater/README.md).

## Found a bug? Have an idea?

Open an issue on this repository. Stars mean nothing, but they're free, and we like them. ⭐

<p align="center">
  <a href="https://www.blastworks.ai/"><img src="https://raw.githubusercontent.com/blastworksai/howgozit/master/assets/blastworks-banner.png" alt="Blastworks.ai" width="360"></a><br>
  <b>All built by <a href="https://www.blastworks.ai/">blastworks.ai</a></b>: AI won't replace you. It frees you up.<br>
  <a href="https://www.blastworks.ai/">blastworks.ai</a> · MIT licence, see <a href="LICENSE">LICENSE</a>
</p>
