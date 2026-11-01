# DANGER PROTOCOL

**A prompt to sanity-check a GitHub repo before you run it.**

## ⚠️ Read this first. Seriously.

This is not a condom.
It's a quick look under the hood, nothing more.
You can still get F***** in the a**.
No guarantees, no warranty, and no liability on my side if you install something nasty after it said "looks fine".

## Why

Every day there's a new reel hyping some "free open-source X" or "10x your Claude GitHub Repo".
Before I even consider stealing, erm, harvesting something or installing anything, I point my Glitch at the repo and make it look for dodgy scripts, spyware and hidden payloads first.
This is the prompt I use: [`SKILL.md`](SKILL.md).

## How to use it

**Glitch or Claude Code:** give it [`SKILL.md`](SKILL.md) and tell it to make it into a skill, then ask it to make a reflex that invokes it whenever you say the phrase **DANGER PROTOCOL**.
I thought it sounded cool.

**Any other agent (Codex, Cursor, whatever):**

1. Open your coding agent or harness in an **empty** folder inside a VM or container.
2. Paste these two lines, fill in the `<...>` bits, then paste the whole of [`SKILL.md`](SKILL.md) under them:

   ```
   DANGER PROTOCOL check.
   Do a hostile-code review of this repo: <REPO_URL>
   What I'm worried about: <e.g. "I saw it hyped on Instagram, want to know if it's spyware or has dodgy install scripts">
   ```

3. Read the verdict, and especially the "what this could not prove" part.

## I would still read this

- Run this in a throwaway VM or container, not on the machine with your passwords, SSH keys and crypto.
- Keep your agent's permission prompts ON. No `--yolo`, no `--dangerously-skip-permissions`. [And you know I'm all about that yolo life]
- Don't open the repo in your editor in "trusted" mode. Workspace tasks and settings can run code.
- If you're about to give the thing your API keys, your accounts or your money: get a human who knows security to look.

## The small print

I know you won't read this. But it's context.

- **It reads the source, not the installer.** The .exe or .dmg you download from their website doesn't have to be built from the code on GitHub. This check says nothing about that file.
- **"No findings" doesn't mean "safe".** AI misses things and sometimes makes things up. Good malware is written to get past exactly this kind of read. Your AI is lazy: it doesn't necessarily read every single line of code, even if you ask nicely.
- **It's a snapshot.** The next update can change everything.
- **Dependencies only get a skim.** A big project pulls in hundreds of packages, and nobody is reading all of them.
- **Your agent is exposed too.** A hostile repo can hide instructions aimed at the AI reading it (prompt injection). That's why the prompt treats everything in the repo as data, and why step 1 clones it so that neither git nor a symlink can reach outside the quarantine.

(Do you think I opened enough umbrellas?)

## Example: ArtCraft

Here's the feedback I got when I asked it to look at [TOTAL BULLSHIT REPO] `storytold/artcraft` [/TOTAL BULLSHIT REPO], on 13 Oct 2026.

<details>
<summary><b>Verdict: no malware, spyware or dodgy scripts found in the code. Still privacy-hungry.</b> (click to read the full audit)</summary>

**Method:** source-only and read-only, on a quarantine clone of the repo as of 11 Oct 2026.
Four parallel auditors (build/install, runtime, network, hidden payloads).
Nothing was built or run, and the clone was deleted afterwards.
That run is the method that became this skill.

**Not tested:** the installer and offline editing.
The privacy and account-ban points below were read from the code, not observed by running the app.

### What's clean [Certain]

- **Build and install:** nothing runs that shouldn't. All 1,044 Rust packages come from crates.io and every npm package but one comes from the official registry.
- **Your machine:** it doesn't read your real browsers' logins or cookies, or your system keychain. It doesn't start itself at login, update itself, or capture keys, screen, microphone or camera.
- **Hidden code:** none. No crypto-miner, password stealer or remote-control code, and no disguised scripts. The Python files are never run by the app.
- **Your API keys and provider logins** only ever go to the provider they belong to.

### What to actually worry about, worst first

1. **Microsoft Clarity records your sessions inside the app.** That covers clicks and scrolls, and probably prompts you type [Likely]. There's no setting to turn it off.
2. **When you're logged into an ArtCraft account, your prompts and generated images or videos are copied to their servers.** That happens even when you pay Midjourney or fal yourself with your own key [Certain]. Image-to-image also uploads your reference images to their storage first [Likely].
3. **Your logins are saved as plain text.** Provider cookies (ChatGPT, Grok, Midjourney) and API keys sit unprotected in `~/Artcraft`, where any other program or backup tool can copy them [Certain].
4. **The app is built carelessly.** Its window can read any file your user account can read, can send to any website, and loads outside scripts. No current code abuses this. But a hacked outside script could read your files or saved keys and send them anywhere [Certain about the setup; no exploit seen].
5. **Your accounts could get banned.** It defeats the bot checks of Grok, Sora/ChatGPT and Midjourney, which breaks their terms. Any ban would land on the accounts you log in with.

**What this check doesn't cover:** the installer you'd download from their website. Only the source code was audited, so nothing here proves their installer was built from this exact code.

### If you want to try it anyway

- Run it in a VM or a separate user account.
- Log into the AI sites with throwaway accounts, not your main ChatGPT or Midjourney.
- Stay logged out of ArtCraft's own account.
- Block `clarity.ms`, `posthog.com` and `google-analytics.com`.

### Follow-up: can it run without AI connectivity?

**No.** ArtCraft has no AI of its own: it's a front end for online AI services, so offline it can't generate anything [Certain].
The editing tools would probably still open, but even they lean on the vendor's servers.

- **No local AI engine.** It has no image model and no way to connect to a local one such as ComfyUI or Ollama. ComfyUI appears only as a job type on the vendor's own servers [Certain].
- One on-device vision library (Google's MediaPipe) is listed as a dependency, but nothing in the code uses it [Certain].
- **Every generation goes online.** Images, video, audio, image-to-3D and background removal all go either to the vendor's servers or to Midjourney, fal, Grok, Sora or WorldLabs [Certain].
- **The 3D canvas needs their servers too.** The app ships with no 3D models; the asset kits come from the vendor's library. Saving a 3D scene uploads it to their servers rather than to a file on your machine [Certain].
- **The video editor is the one part that works locally.** It saves projects inside the app's own storage on your machine [Certain].
- **The other desktop app in the repo is no better.** It's a newer Rust-only rewrite, and its own README says every generation goes through the vendor's servers and starts by asking you to sign in [Certain].

Whether the 2D and 3D canvas opens and works with the network cut off can't be told from the code; proving it means running the app offline, which wasn't done.
If you want local AI art, this is the wrong tool. A local tool such as ComfyUI, running models on your own GPU, is the offline route.

</details>
