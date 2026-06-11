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
