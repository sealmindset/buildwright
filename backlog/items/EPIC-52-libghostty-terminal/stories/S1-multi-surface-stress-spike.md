---
id:        E52-S1
title:     Multi-surface stress spike — libghostty at Buildwright's pane fan-out
type:      spike
status:    done
category:  buildwright
priority:  P1
size:      S
parent:    E52
created:   2026-06-19
updated:   2026-06-19
---

The E52 feasibility spike proved ONE libghostty surface (embed + tmux-backed + persistence).
Buildwright runs MANY panes at once, and each libghostty surface carries a Metal layer +
display link. Given the desktop-freeze history, scale is the one risk that could change the
retrofit decision. Prove it before committing the ~1–2 week retrofit.

**Timebox:** one focused agent session (~half a day). Output = a go/no-go report, not product.

## Goal — the outcome we want
Know whether libghostty holds up at Buildwright's real fan-out (10–20 concurrent surfaces):
memory, CPU, main-thread responsiveness, render stability — with hard numbers.

## Definition of done
- [x] Stood up 1 → 5 → 10 → 20 → 30 concurrent libghostty surfaces, each live (own PTY + streaming workload).
- [x] Measured per-surface RAM (~7 MB marginal, linear), total RSS, CPU idle vs active, main-thread stall.
- [x] Probed the freeze concern: does NOT reproduce — see why below.
- [x] Verdict: **GO**, numbers below.

## Outcome (2026-06-19) — GO
- **30 live surfaces, realistic workload: ~6.5% idle / 11% active CPU, worst main-thread stall ~1 ms, 285 MB total (~7 MB/surface, linear).** Zero crashes/corruption/leaked child procs.
- **Why the freeze concern doesn't reproduce:** (1) on-demand rendering — surfaces render only on grid change (coalesced to one main-thread tick), so idle panes cost ~0; (2) VT parsing runs **off the main thread** (`ghostty_surface_write_buffer` on the PTY-read queue), only Metal submit touches main. Stall only reached tens of ms under an unrealistic all-panes-flooding-`yes` torture test (CPU-core-bound, not a render problem).
- **Practical ceiling:** comfortably 20–30 live surfaces; memory-bound, not CPU-bound.
- **Mitigations to bank (not blockers):** suspend/teardown off-screen panes (`setSurfaceVisible(false)` — lib is occlusion-aware), coalesce/backpressure the byte feed for runaway-output panes, one shared `TerminalController` per window.
- **Before committing the retrofit:** rvance does a 5-min eyes-on run at N=20 (`SPIKE_WORKLOAD=log`, no autoquit) to confirm visual fidelity / GPU-side (the spike couldn't screenshot). Proof runnable at `~/Documents/GitHub/bw-ghostty-spike/TmuxSpike` (`RUN.md`).
