# Changelog

All notable changes to Buildwright are documented here.

## [0.1.0] - 2026-06-10

### Added
- Initial build: native macOS terminal IDE (SwiftUI + SwiftTerm)
- tmux-backed panes: one tmux session per workspace, one window per pane; sessions survive app restarts
- Workspaces → tabs → split panes (rows, columns, nested), drag-to-resize dividers
- Claude Code status per pane (working / needs input / done) via Claude Code hooks, with macOS notifications
- Backlog sidebar reading ~/.claude/backlog: filters, search, detail view, status changes, create/edit, Start → Claude pane
- Browser panes (WKWebView) and CVR recording launcher
- Remote access: iPad/Blink-ready session names, bw companion CLI, Claude status in tmux status bar, mobile-tuned tmux defaults, Remote Access settings panel

## [0.1.1] - 2026-06-10

### Fixed
- "can't find session: _bw-…" when opening panes: tmux reaps a detached session with destroy-unattached set before the pane can attach. Helper sessions no longer use destroy-unattached; stale helpers are cleaned up explicitly at app launch and quit.
- Stray mis-grouped helper session when a pane attached before its workspace session existed (e.g. after a tmux server restart) — the attach path now recreates the workspace session first.

## [0.2.0] - 2026-06-10

### Added
- Attention management: menu-bar count of sessions waiting on you, attention queue sorted needs-input-first then oldest-first, ⌘J jump-to-next, status ages on pane badges ("needs you · 14m")
- "While you were away" re-entry strips: switching to a workspace (or reopening the app) summarizes which sessions finished, which are blocked, and the last Started backlog item — powered by per-workspace context snapshots that persist across restarts
- Breakfix and Feature pane templates: one-click Claude panes with guarded workflows (branch discipline, minimal-change rules, test-before-stop); editable in Settings → Templates

## [0.3.0] - 2026-06-10

### Added
- ⌘K command palette: jump to any pane (with live status badges), switch workspaces, Start backlog stories, or run any app action by typing a few letters
- ⌥⌘-arrow spatial pane navigation: focus moves to the geometrically nearest pane in that direction (90° cone preference so "right" never jumps diagonally)
- ⌘⌥1-9 workspace hotkeys
- Backlog close-the-loop: when a Started pane's Claude finishes, its header shows "mark E04-S2 done" — one click updates the board

## [0.7.0] - 2026-06-11

### Added
- Private browsing by default: browser panes now run as private sessions — no cookies, logins, or history are written to disk, and everything vanishes when the app quits. All private tabs share one in-session cookie jar, so logging into a site works across tabs until quit.
- Per-pane glasses button (tab strip): switch any browser pane between private (purple glasses) and persistent (cookies/logins saved across restarts). Switching reloads that pane's tabs against the other session.
- Settings → General → Browser: "Open browser panes in private mode" toggle controls the default for new panes (on by default).

## [0.6.0] - 2026-06-11

### Added
- Trackpad scrolling in terminal panes: two-finger scrolls (including momentum) are forwarded to tmux as mouse-wheel events, so they scroll tmux's server-side history (enters copy-mode automatically, like iTerm). Physical mouse wheels work too. Scroll speed is normalized so finger travel roughly matches content movement.

### Fixed
- Scrolling over a terminal pane previously moved SwiftTerm's local (always-empty) scrollback and did nothing visible — tmux keeps the history, so the events now go where the history lives.

## [0.5.0] - 2026-06-11

### Added
- Bookmarks, per project: a ☆ star in the browser address bar saves the current page (name + URL editable in a popover), and a slim bookmarks bar under the address bar shows them. Each workspace keeps its own set, plus a "shared across all workspaces" group for the things you use everywhere.
- Bookmark management: right-click a bookmark to open in a new tab, rename, move between workspace/shared, or delete. ⌘-click opens in a new tab.
- ⌘K command palette lists all bookmarks (workspace + shared) — type a few letters to jump to one; opens a browser pane automatically if none exists.

## [0.4.0] - 2026-06-11

### Added
- Browser tabs: each browser pane now has a tab strip with a + button. New tabs open blank with the cursor in the address bar; tab labels follow page titles. All tabs (and which one was active) are restored on app restart, and pre-tab saved states migrate automatically.
- Links that request a new window (target=_blank / window.open) and ⌘-clicked links now open in a new tab — previously they silently did nothing.
- Closing a tab selects its right-hand neighbor; closing the last tab closes the pane (standard browser behavior).

## [0.3.1] - 2026-06-11

### Changed
- Claude panes now launch with --dangerously-skip-permissions by default (no approval prompts). Toggleable in Settings → General; applies to new panes.
