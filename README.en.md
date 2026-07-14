# 🦀 ClawnPet — A Desktop Pet for Claude

**日本語版 → [README.md](README.md)**

A native macOS desktop pet that lives outside the Claude Desktop window, watches
your Claude sessions, and gives you a live play-by-play of what Claude is doing —
inspired by "desktop pet" companions, built for Claude.

| Idle | Thinking | Working | Reply arrived! |
|---|---|---|---|
| ![idle](docs/images/idle.png) | ![thinking](docs/images/1_thinking.png) | ![working](docs/images/2_working.png) | ![celebrating](docs/images/3_celebrating.png) |

> **Unofficial project.** Not affiliated with or endorsed by Anthropic.
> It only *reads* local files that Claude apps already write on your machine —
> no network access, no injection, no automation of the Claude app itself.

## What it does

- **Always-on-top floating pet** — no Dock icon, follows you across Spaces, draggable
- **Detects when you send a message** and shows the prompt text in a speech bubble while "thinking"
- **Narrates tool use in real time** — terminal work, code edits, web searches, sub-agents…
- **Jumps and sparkles when the reply lands**, quoting the first line of the response
- Falls asleep after 8 quiet minutes; wakes on the next event
- Shows how many Claude Code sessions are alive (`session ×N`)
- Works with **every Claude Code session on your machine**: Claude Desktop (CCD), CLI,
  IDE extensions — plus Claude Desktop's own send events

## Install & run

```bash
./build.sh                        # requires Xcode Command Line Tools (Swift)
open build/ClawnPet.app
```

To keep it around:

```bash
cp -R build/ClawnPet.app /Applications/
open /Applications/ClawnPet.app
```

Auto-start at login: System Settings → General → Login Items → add ClawnPet.app.

## Controls

| Action | Result |
|---|---|
| Drag | Move it anywhere (position is remembered) |
| Double-click | Pet it (it celebrates) |
| Right-click / 🦀 menu bar icon | Menu: demo, snapshot, reset position, quit |

## How it works (read-only, nothing leaves your machine)

| Watched path | Signal |
|---|---|
| `~/.claude/projects/**/*.jsonl` | Session transcripts (user messages / tool_use / assistant text / project) |
| `~/.claude/history.jsonl` | Prompt text across all sessions, the moment you hit send |
| `~/Library/Logs/Claude/main.log` | Claude Desktop send / session-pause events |
| `~/.claude/sessions/*.json` | Registry of live sessions (with pid liveness check) |

It auto-follows the most recently active transcript, so it narrates whichever
session you are currently driving. The full investigation notes (including what
*didn't* work and the CDP path for claude.ai web chat) are in
[docs/FEASIBILITY.md](docs/FEASIBILITY.md) (Japanese).

## Debugging

| Env var | Meaning |
|---|---|
| `CLAWN_DEBUG=1` | Log events / state transitions to stderr |
| `CLAWN_DEMO=1` | Play a demo of all motions at launch |
| `CLAWN_WATCH_DIR` / `CLAWN_HISTORY` / `CLAWN_MAINLOG` | Override watched paths (for testing) |
| `CLAWN_SNAPSHOT_PATH` | Where SIGUSR1 snapshots are written |

Signals: `SIGUSR1` = save a PNG snapshot of the pet, `SIGUSR2` = toggle demo.

## Uninstall

Menu bar 🦀 → "Quit Clawn", then delete `/Applications/ClawnPet.app`.
(The only persisted state is the window position in UserDefaults.)

## Project layout

```
Sources/ClawnPet/
├── main.swift         # entry point
├── AppDelegate.swift  # window / menu bar / timers / demo / signals
├── PetCore.swift      # PetEvent / PetBrain (state machine)
├── PetView.swift      # drawing, animation, speech bubble
└── Watchers.swift     # TailReader + transcript / history / main.log watchers
```

## License

[MIT](LICENSE)
