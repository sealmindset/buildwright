# BACKLOG BOARD — buildwright

**Epics:** ready 2 · done 4

## ready (2)
- **E44** · Buildwright agent lifecycle & freeze prevention  _[buildwright] P1_
    - E44-S1 · Reap agent on pane close (confirm if busy, else auto) _(done)_
    - E44-S2 · Agent census in header + cap warning (warn, never auto-kill) _(done)_
    - E44-S3 · Reattach without the all-panes redraw storm _(ready)_
- **E46** · Buildwright Resilience — self-healing, self-governing cockpit  _[buildwright] P1_
    - E46-S1 · Render off main thread + coalesced draws (storm root-cause fix) _(in-progress)_
    - E46-S2 · Per-pane flow control / backpressure (render budget) _(in-progress)_
    - E46-S3 · Resource governor core (RAM-derived budgets + amber warn) _(done)_
    - E46-S4 · Emergency circuit-breaker + degradation ladder _(done)_
    - E46-S5 · Reap-on-pane-close + agent census/health surface (absorbs E44-S1/S2) _(done)_
    - E46-S6 · Main-thread hang watchdog (detect + self-sample + recovering UI) _(done)_
    - E46-S16 · Remote/AFK access v1 — harden + document SSH+tmux per-workspace attach _(ready)_
    - E46-S17 · Remote/AFK access v2 — buildwrightd-brokered client + aggregate pane-of-glass _(ready)_
    - E46-S18 · ⚡Clear leftover SwiftTerm selection-wash on pane process exit _(backlog)_ [S]

## done (4)
- **E48** · CVR Plugin — self-contained recorder + Buildwright plugin mechanism  _[buildwright] P2_
    - E48-S1 · Relocate CVR control toolbar — top-center, draggable, collapsible _(done)_
    - E48-S2 · Stand up sealmindset/cvr — self-contained repo _(done)_
    - E48-S3 · Prove CVR is self-contained (clean-machine simulation) _(done)_
    - E48-S4 · Buildwright plugin mechanism (manifest install-from-GitHub) _(done)_
    - E48-S5 · CVR plugin integration + workspace/terminal interlink _(done)_
- **E50** · AI Scrum Master Intake — auto-triage captured text into the backlog  _[Buildwright] P2_
- **E51** · AI Scrum Master — Code-Grounded Reconciliation + Autonomous Dispatch  _[Buildwright] P1_ [L]
- **E52** · Helm — agent-first orchestrator (native, libghostty)  _[helm] P1_ [XL]
    - E52-S1 · 🔬Multi-surface stress spike — libghostty at Buildwright's pane fan-out _(done)_ [S]
    - E52-S2 · M0 — Foundation: Helm skeleton + libghostty pane + tmux persistence + pooled-surface core _(done)_ [M]
    - E52-S3 · M1 — Agents + worktree isolation: spawn, Agent Grid, multi-repo, reaping _(done)_ [L]
    - E52-S4 · M2 — Board-driven loop: backlog sidebar + Start (ship preamble), capture, attention, grid polish _(done)_ [L]
    - E52-S5 · M3 — GitHub-native ship: PR + CI watch + harm-gate merge + close the loop _(done)_ [L]
    - E52-S6 · M4a — Plugin system (install-from-GitHub) + CVR as the first plugin _(done)_ [L]
    - E52-S7 · M4b — Browser panes: WKWebView + tabs + bookmarks + private-by-default _(done)_ [M]
    - E52-S8 · M4c — Remote / iPad: companion CLI + mobile-tuned tmux + Remote Access panel _(done)_ [M]
    - E52-S9 · M4d — Re-entry: while-you-were-away strips + context snapshots + breakfix/feature templates _(done)_ [M]
    - E52-S10 · M4e — Push notifications: macOS notifications + helmctl watch + optional AFK webhook _(done)_ [M]
    - E52-S11 · M4f — Loop polish: PR detail + conflict resolution + auto-merge toggle + context/token + Record button _(done)_ [L]
    - E52-S12 · M4g — Dashboards: Finish Line + Backlog Map + Mission Control (final slice) _(done)_ [L]
