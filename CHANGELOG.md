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
