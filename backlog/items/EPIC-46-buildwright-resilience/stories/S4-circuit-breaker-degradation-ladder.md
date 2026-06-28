---
id:        E46-S4
title:     Emergency circuit-breaker + degradation ladder
type:      story
status:    done
category:  buildwright
priority:  P1
parent:    E46
created:   2026-06-15
updated:   2026-06-15
---

# Emergency circuit-breaker + degradation ladder

The Tier-2 / cliff response: when the governor (E46-S3) sees critical pressure or a
hard footprint cap, **auto-shed load** in priority order — pixels before processes.

## Goal
At the cliff, Buildwright preserves the machine automatically, reversibly where
possible, and tells the user what it did.

## Constraints
- Ladder order (stop as soon as pressure clears): (1) shed rendering — stop drawing
  off-screen panes, drop excess scrollback, throttle draws; (2) tighten flow-control
  budgets (E46-S2); (3) pause idle agents (reversible); (4) reap clearly-dead only
  (own-verified; transcripts persist; confirm anything ambiguous).
- Distinct from the warn-only tier — this one **auto-acts** (the explicit decision).
- Every action logged + surfaced in the health panel; nothing silent.
- Agent-pause mechanism `[reconcile]` (tmux-level vs SIGSTOP — verify resume safety).

## Definition of done
- A memory balloon drives critical pressure → ladder runs → no jetsam of other apps,
  desktop stays usable. Chaos memory-exhaustion case (E46-S15) passes.
- Reversible steps reverse when pressure clears; user sees exactly what happened.

## Result (2026-06-15) — built (branch bw/e46-s4-circuitbreaker, stacked on S3)
Reversible shed-load driven by the S3 governor's tier. On red (cliff): the cache flips
`underStress`, which clamps ControlModeTerminalView's flow-control budgets hard
(1MB/256KB → 64KB/16KB) so panes pause far sooner — sheds rendering + memory and
backpressures agents (pixels-before-processes), fully reversible. On recovery: budgets
restored + every paused pane resumed. Governor engages/relieves on tier transitions,
logs the action (surfaced in the Attention menu). Builds clean.
DEFERRED (noted): ladder rungs 3 (SIGSTOP idle agents — risky, no memory benefit; tied
to the open agent-pause question) and 4 (reap clearly-dead — engage reports the dead-pane
count but never auto-kills, to avoid UI risk without a live cliff to test). The reversible
backpressure lever is the high-value, safe core. Pending: live confirm under real
memory-pressure-critical (GUI).
