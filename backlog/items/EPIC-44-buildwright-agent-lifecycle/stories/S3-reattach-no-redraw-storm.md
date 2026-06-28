---
id:        E44-S3
title:     Reattach without the all-panes redraw storm
type:      story
status:    ready
category:  buildwright
priority:  P1
parent:    E44
created:   2026-06-14
updated:   2026-06-14
---

# Reattach without the all-panes redraw storm

On launch/reattach, Buildwright wires up every window in the persistent tmux
session and feeds their `%output` into SwiftTerm views at once. With many windows
(26 on 2026-06-14) this is a main-thread + redraw storm that can stall WindowServer
into a full-desktop freeze — the leading hypothesis for the 11:30 freeze.

## Goal — the outcome we want
Reattaching to a session with many windows keeps the compositor responsive — no
main-thread stall, no desktop freeze — by not rendering every pane simultaneously
on launch.

## Who it's for / the pain
rvance — the freeze that started this epic. A persistent session is the whole point
of tmux control mode, so reattach must scale to many windows without wedging the UI.

## Constraints
- Keep tmux control-mode persistence intact — this is about HOW panes hydrate on
  reattach, not whether they survive.
- Likely approach (confirm against code): lazily render only the visible/active
  pane; hydrate others on focus, or stagger/throttle capture-replay across runloop
  ticks rather than all at once. Decide the exact strategy against the real code.
- Must not reintroduce the size-drift / replay-race / "impossible size" class of
  bugs (window-size manual; clamp-to-host; reconciler) — coordinate with that
  existing machinery.
- Initial paint must stay clean (the v0.34.0 "size before first capture" fix).

## Definition of done
- Reattach to a 20+ window session with no perceptible desktop stall.
- `Scripts/bw-freeze-probe.sh` (sudo) shows no main-thread / WindowServer stall
  during a many-window reattach.
- Non-visible panes still hydrate correctly (no blank/garbled panes on focus).
- No regression in the size-sync / scramble fixes.

## Open questions
- Where the reattach/hydration path lives (TmuxControlClient + TerminalViewCache +
  the per-pane capture-replay) — map it before changing.
- Lazy-on-focus vs. throttled-hydrate-all — pick based on what keeps reconciler
  correctness while killing the storm.
