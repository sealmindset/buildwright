---
id:        E46-S2
title:     Per-pane flow control / backpressure (render budget)
type:      story
status:    in-progress
category:  buildwright
priority:  P1
parent:    E46
created:   2026-06-15
updated:   2026-06-15
---

## Implementation notes (2026-06-15, builds — commit 6dd8327)
Render-budget backpressure, driven by OUR buffer (not tmux's `pause-after`,
which can't see the backlog once S1 drains the pipe into `pendingFeed`):
- `TmuxControlClient.setPaneFlow(paneID,state)` → `refresh-client -A %pane:pause|continue`
  (verified supported on tmux 3.6b); parse `%pause`/`%continue` → new Event cases →
  routed via `TmuxManager.handleControlEvent` → `TerminalViewCache.flowPaused/flowContinued`.
- View: pause when `pendingFeed ≥ 1MB`, continue when drained `≤ 256KB` (hysteresis);
  `flowPaused` is our authoritative intent (race-free), `flowConfirmedPaused` records
  tmux's notification for diagnostics/health.
- Resume on refresh/rebind/remove so a pane is never left paused for other (iPad) clients.
- tmux buffers paused output and replays on continue — no data loss.
- `flow=paused|ok` added to diagnostic snapshot.

Pending: live-test under flood (with S1) — confirm a runaway pane pauses + UI stays
responsive. Increment-2 (parse off main) still deferred; backpressure now caps the
parse-storm load regardless.
---

# Per-pane flow control / backpressure

Give each pane a render/byte budget; a pane whose unrendered backlog exceeds budget is
paused via tmux control-mode flow control and resumed when the renderer drains it. A
runaway agent throttles itself instead of drowning the UI.

## Goal
No single pane's output can outrun the renderer; bursts self-throttle, interactivity
preserved.

## Constraints
- Use tmux control-mode flow control — `[reconcile]` exact API (`%pause`/`%continue`,
  `refresh-client` flow-control flags, `pause-after`).
- Per-pane budget, not global; resume promptly when drained (no stuck-paused panes).
- Interactive typing/output must feel instant under normal load (tune budget).
- Tightened further by the circuit-breaker under cliff pressure (E46-S4).

## Definition of done
- A flood on one pane pauses that pane only; other panes + UI stay responsive.
- Paused panes always resume; no permanent stalls. Chaos flood case passes.
