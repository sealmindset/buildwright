---
id:        E46-S18
title:     Clear leftover SwiftTerm selection-wash on pane process exit
type:      breakfix
status:    backlog
category:  buildwright
priority:  P2
size:      S
parent:    E46
created:   2026-06-18
updated:   2026-06-18
---

# Clear leftover SwiftTerm selection-wash on pane process exit

## Goal — the outcome we want
When an agent/TUI process exits, the pane shows no full-buffer inverse-video
"selection wash." Selection state is cleared on the exit transition as a hard
guarantee, not left to a later click/keystroke/resize to mop up.

## Who it's for / the pain — who benefits and why it matters
rvance, every time an epic/agent finishes: the whole pane flashes "selected,"
which reads as a glitch and obscures the final output until you interact
elsewhere. Cosmetic but constant, and it undercuts the polished-cockpit feel.

## Constraints — must-haves, limits, non-negotiables
- SwiftTerm `scrollWheel`/selection internals are public-not-open in places — work
  with the available API surface (monitors/transitions), don't fork SwiftTerm.
- Do NOT ship a guess. Confirm what *creates* the whole-buffer selection at exit
  before fixing (see [[debug-with-live-tests-not-theory]]).
- Same display subsystem E46 already reworked (output coalescing S1, render-budget
  S2, idle-converge) — keep the fix consistent with that plumbing.

## Definition of done — how we'll know it's complete
- [ ] Root cause of the whole-buffer selection at exit is confirmed and documented.
- [ ] On process exit, no inverse-video wash appears — both plain shell panes and
      Claude/agent panes verified clean.
- [ ] Fix clears selection on the exit transition (hard guarantee), verified on a
      live installed build, not just in theory.

## Open questions
- What creates the whole-buffer selection at completion (stray gesture, triple-click,
  or an auto select-all somewhere)?
- With a pane washed, does ⌘C copy the entire screen's text (confirms a real
  selection vs. an overlay)?

## Captured
> When an agent/epic finishes, the whole terminal pane flashes an inverse-video "selection wash" over the entire pane — looks selected but isn't; it clears when you click, type, or resize elsewhere. It's a real leftover SwiftTerm text selection that survives because the exiting TUI turns mouse reporting off, so SwiftTerm stops clearing selections on output. Need to confirm what creates the whole-buffer selection at process exit, then clear it on the exit transition. Buildwright app.

_via /backlog capture · 2026-06-18_

## Scrum Master triage
- type: breakfix · size: S · placement: E46 (confidence 0.62)
- reasoning: SwiftTerm terminal-render correctness in the same display subsystem E46 reworked (output coalescing S1, render-budget S2, idle-converge); the idle-converge refresh is itself implicated in clearing the wash.
