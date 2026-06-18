# Buildwright

A native macOS terminal IDE built for running many Claude Code sessions at once — the convenience of a terminal, the polish of a real Mac app, with genuine tmux underneath and your backlog board driving the work. Built with Swift Package Manager (`Package.swift`).

## Development Guidelines

### Multi-Session Development

Multiple Claude Code sessions may run against this repo concurrently, each in its own git worktree on a `session/*` branch (one repo, multiple working dirs sharing one `.git`). Sessions integrate only through `main` via PRs — never through the filesystem. Follow these rules to avoid cross-contaminating another session's work:

- **Stage only your own changes.** Prefer `git add <specific paths>` over `git add -A` — a blanket add in a shared checkout can sweep another session's uncommitted files into your PR.
- **One feature per branch**, branched fresh off `origin/main`.
- **Rebase after every merge.** When any PR lands on `main`, run `git fetch origin && git rebase origin/main` before continuing, so duplicates collapse and conflicts surface early.
- **Never assume you're the only session.** If files you didn't create show up staged, stop and surface it rather than committing them.
- **Watch for shared runtime state when running the app.** Each worktree gets its own SwiftPM `.build/` and `dist/` (good, isolated), but two instances of the built app share the same bundle identifier and therefore the same `UserDefaults`, Application Support, and other on-disk app state. If a session needs to run the app, isolate that state (e.g. a per-session app-support dir or defaults domain) so concurrent runs don't stomp each other.
