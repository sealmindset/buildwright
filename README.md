# Buildwright

A native macOS terminal IDE built for running many Claude Code sessions at once — the convenience of a terminal, the polish of a real Mac app, with genuine tmux underneath and your backlog board driving the work.

## Features

- **Tiling panes, any arrangement** — split into rows, columns, or any nested combination; add, delete, and drag-resize freely
- **Real tmux under the hood** — every workspace is one tmux session, every pane a window inside it; sessions survive app crashes, restarts, and reboots
- **Native terminal feel** — panes render into native SwiftTerm buffers via tmux *control mode* (the iTerm2 integration model): trackpad scrollback, text selection, copy, and Cmd+F find all behave like Terminal.app
- **Built for Claude Code** — each pane shows whether Claude is working (●), needs you (◉), or done (✓); unfocused sessions ping you with a macOS notification that says *what* Claude needs (read from the session transcript)
- **Mission Control** — ⇧⌘K (or ⌥⌘B from anywhere in macOS): every pane in every workspace as one glanceable grid — status, wait time, Claude's last message; click to jump
- **Worktree isolation** — spawn a Claude pane in its own git worktree + branch (⌃⌘N) so parallel agents never trample each other; clean worktrees auto-remove on close, branches kept
- **Linear-preferred safety gate** — a new Claude pane in a folder where another is working goes *on deck* automatically and starts when the first finishes (⌥⌘T to tee up the next prompt while the current one runs); escape hatches: start now, or run isolated in a worktree
- **Chat panes** — a Claude thinking partner opened in your backlog board: discuss ideas, push back, file the keepers as backlog items; never touches code, always safe to run alongside anything
- **Project isolation** — each Claude pane runs in its own folder with its own session, context, and MCP; zero cross-talk
- **Backlog sidebar** — your `~/.claude/backlog` board rendered with filters, search, and editing; click **▶ Start** on any story to spawn a Claude pane pre-loaded with that item
- **Shell + browser panes** — zsh panes and WKWebView browser panes mix into any layout; browsers dock left or right
- **CVR launcher** — kick off a CVR recording session with the Chromium window auto-tiled beside the IDE
- **iPad remote access** — attach to any workspace from Blink Shell: `mosh your-mac -- tmux attach -t docai`
- **Attention management** — menu-bar count of sessions waiting on you (visible even when the app is hidden), ⌘J jumps to whoever has waited longest, statuses show their age ("needs you · 14m")
- **"While you were away"** — switching back to a workspace (or reopening the app) shows what changed since you left: which sessions finished, which are blocked on you, and which backlog item you were on
- **Breakfix / Feature templates** — one-click Claude panes pre-loaded with guarded workflows (branch discipline, smallest-possible-change rules, test-before-stop); prompts editable in Settings → Templates

## Tech Stack

| Component | Technology |
|-----------|-----------|
| App | Swift, SwiftUI + AppKit, macOS 14+ |
| Terminal emulation | SwiftTerm |
| Session engine | tmux (≥ 3.2, default socket) |
| Browser panes | WKWebView |
| Build | Swift Package Manager |

## Prerequisites

- macOS 14+ with Xcode (or Swift 6+ toolchain)
- `tmux` (`brew install tmux`)
- Claude Code CLI (`claude`) for Claude panes
- Optional: `mosh` for roaming iPad connections, Tailscale for access from anywhere

## Getting Started

```bash
git clone <repo-url>
cd buildwright

# Build and run during development
swift run

# Or build a proper app bundle
./Scripts/bundle.sh            # → dist/Buildwright.app
./Scripts/bundle.sh --install  # → /Applications/Buildwright.app
```

On first launch, Buildwright:
1. Asks you to create a workspace (a name + base folder, e.g. `~/Documents/GitHub/docai`)
2. Installs the `bw` companion CLI and `bw-hook` into `~/.local/bin`
3. Merges status-reporting hooks into `~/.claude/settings.json` (they no-op outside Buildwright panes)
4. Opens your first Claude pane in the base folder

## Keyboard Shortcuts

| Keys | Action |
|------|--------|
| ⌘N / ⇧⌘N | New Claude pane (split right / down) |
| ⌘D / ⇧⌘D | New shell pane (split right / down) |
| ⇧⌘B | New browser pane |
| ⌘W | Close focused pane |
| ⌘J | Jump to the pane that's been waiting on you longest |
| ⌘K | Command palette — jump to any pane, workspace, backlog item, or action |
| ⇧⌘K | Mission Control — every pane in every workspace, one grid |
| ⌥⌘B | Summon Buildwright + Mission Control from anywhere in macOS |
| ⌘↩ | Zoom focused pane (toggle) |
| ⌃⌘B | Broadcast input to every terminal pane in the tab (toggle, auto-disarms on tab switch) |
| ⌃⌘N | New Claude pane in an isolated git worktree |
| ⌥⌘T | Tee up the next prompt — queues behind the working pane, auto-starts when it finishes |
| ⌥⌘←↑↓→ | Move pane focus spatially |
| ⌘⌥1-9 | Switch workspace by position |
| ⌘T / ⇧⌘W | New tab / close tab |
| ⌘1 | Toggle backlog sidebar |
| ⌥⌘N | New workspace |
| Ctrl+B … | tmux prefix works when attached from another terminal (iPad/Blink); inside app panes keys go straight to your program |

## How the tmux Mapping Works

```
Buildwright window                     tmux server (survives everything)
┌─────────┬──────────┬─────────┐
│ BACKLOG │ claude   │ zsh     │       session: docai
│ sidebar │ (win @1) │ (win @2)│  ◄──►   ├─ window @1  claude
│         ├──────────┴─────────┤         ├─ window @2  zsh
│         │ claude (win @3)    │         └─ window @3  claude
└─────────┴────────────────────┘
```

The app holds one tmux *control mode* connection (`tmux -C`, the protocol behind iTerm2's tmux integration) per workspace. Pane output streams to the app as `%output` events and renders into native SwiftTerm buffers — so scrollback, selection, and search are local and native — while keystrokes go back via `send-keys` and each window is sized per-pane with `refresh-client -C`. tmux still owns every process. From any terminal — including Blink on iPad — the workspace is directly reachable:

```bash
tmux attach -t docai        # the whole workspace, panes as windows (Ctrl+B n/p to flip)
bw ls                       # workspaces + panes + Claude status
bw docai                    # attach via the helper
```

Closing a pane in the app kills its tmux window. Quitting the app kills nothing.

## Remote Access (iPad / Blink Shell)

Open **Settings → Remote Access** for live checks (SSH on, mosh, Tailscale) and copy-paste connection commands. The tmux status bar shows each Claude pane's state remotely: `● working ◉ needs you ✓ done`.

## Backlog Integration

The sidebar reads and writes `~/.claude/backlog` in the exact format the `/backlog` skill uses — frontmatter markdown plus a regenerated `BOARD.md` — so the skill and the sidebar stay perfectly interchangeable. Closed epics are hidden by default; each workspace remembers its own filters.

## Project Structure

```
buildwright/
├── Sources/Buildwright/
│   ├── BuildwrightApp.swift     # App entry, menus, shortcuts
│   ├── AppState.swift           # Central state + actions
│   ├── Models/                  # Workspace, Tab, Pane, LayoutNode (split tree)
│   ├── Tmux/                    # TmuxClient (CLI wrapper), TmuxManager (orchestration)
│   ├── Terminal/                # SwiftTerm pane hosting (cached, attach via tmux)
│   ├── Browser/                 # WKWebView panes
│   ├── Backlog/                 # Board parsing, watching, writing, sidebar UI
│   ├── Claude/                  # Hook installer + status monitor
│   ├── CVR/                     # CVR recording launcher + window docking
│   ├── Remote/                  # Remote Access panel + Settings
│   ├── UI/                      # Main window, layout renderer, tab bar
│   ├── Persistence/             # JSON state store
│   └── Support/                 # Config, shell exec, embedded scripts
├── Scripts/                     # bundle.sh, bw, bw-hook (reference copies)
└── Tests/BuildwrightTests/      # Layout tree, frontmatter, tmux command tests
```

## Development

```bash
# Tests (uses Xcode toolchain for Swift Testing)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

State lives in `~/Library/Application Support/Buildwright/state.json`. Claude status files live in `~/.local/state/buildwright/status/`. Both paths are overridable via `BUILDWRIGHT_STATE_DIR` / `BUILDWRIGHT_STATUS_DIR` / `BUILDWRIGHT_BACKLOG_DIR` environment variables.

## License

Internal use only.
