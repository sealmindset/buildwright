---
id:        E46-S1
title:     Render off main thread + coalesced draws (storm root-cause fix)
type:      story
status:    in-progress
category:  buildwright
priority:  P1
parent:    E46
created:   2026-06-15
updated:   2026-06-15
---

## Implementation notes (2026-06-15)
**Increment 1 — coalesced feed (DONE, builds):** `ControlModeTerminalView.deliver`
no longer feeds SwiftTerm per `%output`. Bytes accumulate in a per-view FIFO
(`pendingFeed`) and flush once per runloop turn, capped at 128KB/flush with the
remainder rescheduled — so a flood yields to draw/input between hops instead of
freezing. Order preserved (single buffer, all on main); replay-drop semantics kept
(`pendingFeed` cleared in `refreshFromTmux`, dropped while `awaitingHistory`).
Grounded in the real path: `TmuxControlClient` parses on main (`@MainActor`,
DispatchQueue.main) and `feed` can't run off-main (SwiftTerm buffer not thread-safe
vs. the main-thread draw).

**Deferred — Increment 2 (parse off main):** move `%output` unescape/parse off the
main thread on a serial queue, paired with **E46-S2 flow control** (the right place
to stop a parse storm: pause the flood at tmux so bytes never arrive). Split out to
keep this increment low-risk on the daily-driver app and testable on its own.
---

# Render off main thread + coalesced draws

The 2026-06-14 freeze root cause: `%output` ingestion + SwiftTerm feeding happens on
the main thread, so an output storm starves the UI/WindowServer → desktop freeze.
Move ingestion/parsing off the main thread and commit draws coalesced at display
refresh so a storm can never starve the UI.

## Goal
Output bursts (one pane or many) never block the main thread; draw rate is bounded.

## Constraints
- Parse/model-update on a background queue; only the actual draw/commit on main.
- Coalesce: batch %output and update views at display cadence (e.g. CVDisplayLink /
  ~60Hz), not per-event.
- Must not break the size-sync / scramble fixes (v0.30–0.33) or SwiftTerm correctness.
- `[reconcile]`: find the current %output→SwiftTerm feed path + which thread it runs on.

## Definition of done
- Flooding a pane with continuous output keeps the app interactive (verified live).
- No visual regression (no garble/scramble); chaos "flood %output" case (E46-S15) passes.
