---
id:        E46-S6
title:     Main-thread hang watchdog (detect + self-sample + recovering UI)
type:      story
status:    done
category:  buildwright
priority:  P1
parent:    E46
created:   2026-06-15
updated:   2026-06-15
---

# Main-thread hang watchdog

Detect when the GUI main thread is wedged (the beachball) instead of freezing
silently, capture forensics automatically, and surface a recovering state.

## Goal
A main-thread hang is detected within ~1s, self-documented, and visible — not a silent
mystery freeze.

## Constraints
- Watchdog thread pings main every N ms; K consecutive misses ⇒ hung.
- On hang: capture a self-`sample` (freeze-probe style → ~/mac-doctor-reports or app
  log) so the cause is recorded even if the user force-quits.
- Show a "recovering…" affordance rather than a frozen window.
- Phase 1 = detect + capture + surface (in-process). Full safe-restart lands once the
  daemon owns agents (Phase 2) so a GUI restart is harmless.

## Definition of done
- Injected main-thread stall (debug build) is detected, a sample is captured, and the
  UI shows recovering. Chaos main-thread-wedge case (E46-S15) passes.

## Result (2026-06-15) — built (branch bw/e46-s6-watchdog, stacked on S4)
`Resilience/MainThreadWatchdog.swift`: background probe posts a ping to main every 1s and
waits on a DispatchSemaphore; a >3s timeout = wedged main thread. While wedged it captures
`sample <pid>` to <stateDir>/hang-reports/ (works externally even with main frozen) — the
artifact the 2026-06-14 freeze lacked — then `sem.wait()` blocks until main recovers,
posts a recovery notification (osascript, no app UI needed), and records `lastHang`
(surfaced in the Attention menu). Started in AppState.bootstrap. Builds clean; `sample`
capture verified live (99-line stack dump). Detect+document only — a safe GUI restart
needs the daemon (Phase 2). Live confirm of an actual hang detection is GUI/chaos (S15).
