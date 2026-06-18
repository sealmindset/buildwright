# Changelog

All notable changes to Buildwright are documented here.

## [Unreleased]

### Added
- Backlog Map (⇧⌘M, toolbar ⃕ button, Attention menu) — an elegant full-screen popup that renders the whole `~/.claude/backlog` board as a layered dependency/flow graph. Nodes are epics + stories/tasks/breakfix (status-coloured, with priority/effort/type badges); edges show epic→child containment (dashed) and explicit `depends:` dependencies (solid orange arrows, laid out left→right by dependency depth). Filters for status, type, priority, effort, search, and show-done; pinch/slider zoom; click a card to edit (reuses the detail sheet), ▶ to start a Claude pane, right-click to set status.
- Board-hygiene signals baked into the map (the Scrum Master's job — keep the board honest): **parallel-ready** items (can start now: ready/backlog, deps done, parent unblocked, no in-progress collision in the same category) ringed green with a one-click ▶; **stale** open items (untouched 14+ days) flagged amber with a "Stale only" filter; **superseded / no-longer-required** items (a `superseded_by:` key set by the Scrum Master) shown struck-through with a "→ Sx" badge and a "Superseded only" filter; plus a header pulse counting in-progress / stale / superseded and a node action to mark an item done — no longer required.

## [0.36.0] - 2026-06-18

### Added
- AI Scrum Master — code-grounded reconciliation + autonomous dispatch (E51). New `Reconciler` engine + cockpit Reconcile panel that audits the backlog board against a real codebase (default `~/Documents/GitHub/docai`, configurable) via a code→tests→live verification ladder, returns per-item verdicts (built/partial/not-built/unknown + confidence + evidence), auto-applies high-confidence reversible findings (mark-done/close-dup/re-status) with provenance + undo, and flags the rest.
- Dispatch: surfaces the next parallel-safe `not-built`/`partial` gap and starts it (behind an arm toggle, one at a time), running under the standing ship preamble's green-gate + harm-gate.
- Skill side: `/backlog reconcile` and `/backlog dispatch` subcommands; the standing prompt preamble (clarify-first + 100%-green gate + harm-gated ship) is auto-prepended to every `/backlog start`.

## [0.35.0] - 2026-06-18

### Added
- AI Scrum Master intake (E50): a ⌘⇧N quick-capture sheet and a `/backlog capture` skill subcommand sharing one triage engine — raw text is auto-classified (epic/story/task/breakfix/spike), sized (XS–XL), placed into the best-fit epic (or a new one), and filed with a provenance block and one-tap Undo.
- Backlog schema gained an optional `size` field and `breakfix`/`spike` item types (backward-compatible).

## [0.34.0] - 2026-06-15

### Added
- Resilience safety net (E46): coalesced render feed, per-pane flow control / render-budget backpressure, RAM-derived resource governor, emergency circuit-breaker + degradation ladder, main-thread hang watchdog, and agent reaping (reap-on-close + dead-pane reap).
- Buildwright plugin mechanism with CVR as the first installable plugin (E48); clean initial paint (size tmux before first capture).

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
