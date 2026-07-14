# 🦀 ClawnPet — A Desktop Pet for Claude

**日本語版 → [README.md](README.md)**

A native macOS desktop pet that lives outside the Claude Desktop window, watches
your Claude sessions, and gives you a live play-by-play of what Claude is doing —
inspired by "desktop pet" companions, built for Claude.

| Idle | Thinking | Working | Reply arrived! | Multi-session |
|---|---|---|---|---|
| ![idle](docs/images/idle.png) | ![thinking](docs/images/1_thinking.png) | ![working](docs/images/2_working.png) | ![celebrating](docs/images/3_celebrating.png) | ![sessions](docs/images/multi_sessions.png) |

> **Unofficial project.** Not affiliated with or endorsed by Anthropic.
> It only *reads* local files that Claude apps already write on your machine —
> no network access, no injection, no automation of the Claude app itself.

## What it does

- **Always-on-top floating pet** — no Dock icon, follows you across Spaces, draggable
- **Detects when you send a message** and goes into "thinking" — status is narrated via session cards and voice
- **Narrates tool use in real time** — terminal work, code edits, web searches, sub-agents…
- **Jumps and sparkles when the reply lands**, quoting the first line of the response
- **Session cards** — stacks up to 6 active sessions as cards, each with a mini crab showing that session's mood
- **Click a card to jump to that session** — opens it in Claude Desktop via the `claude://resume` deep link
- **Voice narration** — VOICEVOX (Zundamon) or the macOS system voice reads out events in real time (switchable / off in the menu)
- **Faces where it's going** — while dragged, Clawn leans into the direction of travel and its eyes follow; it settles back to front when you stop
- **The crab never changes size** — same structure as ChatGPT's desktop pet: open or closed, the mascot stays 116×112. **Click the badge (session count) to unfold the cards above it**, and **click the ˅ button over its head to close them**. The badge is orange while working, green otherwise; watching, narration and notifications continue while closed
- **A different voice per session** — VOICEVOX speakers are auto-assigned per project, so you can tell sessions apart by ear
- **Reply notifications** — finished responses also land in Notification Center; clicking one jumps to that session
- **claude.ai web chat support (opt-in)** — launch Claude Desktop with a debug port and ClawnPet narrates web-chat sends/completions too, via CDP
- Falls asleep after 8 quiet minutes; wakes on the next event
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
| Click the badge (top right) | Open the session cards |
| ˅ button above its head | Close the session cards |
| Click a session card | Open that session in Claude Desktop |
| Click | Pet it (it celebrates; size never changes) |
| Double-click | Toggle open / closed (same as badge / ˅) |
| Drag | Move it anywhere (position is remembered) |
| Right-click / 🦀 menu bar icon | Menu: voice engine, open/close, demo, quit, … |

## How it works (read-only, nothing leaves your machine)

| Watched path | Signal |
|---|---|
| `~/.claude/projects/**/*.jsonl` | Session transcripts (user messages / tool_use / assistant text / project) |
| `~/.claude/history.jsonl` | Prompt text across all sessions, the moment you hit send |
| `~/Library/Logs/Claude/main.log` | Claude Desktop send / session-pause events |
| `~/.claude/sessions/*.json` | Registry of live sessions (with pid liveness check) |

It follows up to 6 transcripts active within the last 30 minutes in parallel; the
main Clawn narrates whichever session moved most recently. The full investigation
notes (including what *didn't* work and the CDP path for claude.ai web chat) are in
[docs/FEASIBILITY.md](docs/FEASIBILITY.md), and the design overview lives in
[docs/architecture.html](docs/architecture.html) (both Japanese).

### Voice narration (VOICEVOX)

If [VOICEVOX](https://voicevox.hiroshiba.jp/) is running (`localhost:50021`),
Zundamon narrates your sessions; otherwise ClawnPet falls back to the macOS
system voice. Switch engines (or mute) from the 🦀 menu bar icon.
Turn on "セッションごとに声を変える" (per-session voice) and ClawnPet
auto-assigns an installed VOICEVOX speaker to each project, so you can tell
who's talking without looking.

### Reply notifications

Finished responses can also be posted to Notification Center
(🦀 menu → "返信を通知センターに出す"). Clicking a notification jumps to that
session. Ad-hoc builds that macOS refuses notification permission for fall
back to `osascript` notifications automatically.

### claude.ai web chat (opt-in, CDP)

Launch Claude Desktop with a remote-debugging port and ClawnPet will narrate
web chat activity too (send → streaming → done):

```bash
osascript -e 'quit app "Claude"'; sleep 2
open -a Claude --args --remote-debugging-port=9222
CLAWN_CDP_PORT=9222 open -n /Applications/ClawnPet.app
```

Without `CLAWN_CDP_PORT` the CDP watcher stays off (default). Web chat is
narrated at "thinking → done" granularity (message bodies aren't available).
> ⚠️ A debug port is reachable by every local process — not recommended for daily use.

## Debugging

| Env var | Meaning |
|---|---|
| `CLAWN_DEBUG=1` | Log events / state transitions to stderr |
| `CLAWN_DEMO=1` | Play a demo of all motions at launch |
| `CLAWN_WATCH_DIR` / `CLAWN_HISTORY` / `CLAWN_MAINLOG` | Override watched paths (for testing) |
| `CLAWN_SNAPSHOT_PATH` | Where SIGUSR1 snapshots are written |
| `CLAWN_TEST_FACING` | Pin the facing pose (`1`=right, `-1`=left; for visual testing) |

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
├── PetView.swift      # drawing, animation, session cards
└── Watchers.swift     # TailReader + transcript / history / main.log watchers
```

## License

[MIT](LICENSE)
