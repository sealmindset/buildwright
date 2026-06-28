---
id:        E44-S2
title:     Agent census in header + cap warning (warn, never auto-kill)
type:      story
status:    done
category:  buildwright
priority:  P1
parent:    E44
created:   2026-06-14
updated:   2026-06-14
---

# Agent census in header + cap warning (warn, never auto-kill)

Surface how many Claude agents are live and their total memory, and warn when it
grows past a threshold — but **never auto-kill**. The user decides; give them a
one-click "reap stale" to act on the warning.

## Goal — the outcome we want
A live agent count + total RSS visible in the app, a non-blocking warning past N
agents, and a one-click action to reap stale/idle agents. Accumulation becomes
visible and self-correcting instead of silent.

## Who it's for / the pain
rvance — today the standing army (26 agents / 10.7 GB) is invisible until the
machine is in trouble. Same idea as the existing per-pane size chip: make the
hidden state visible so it self-corrects.

## Constraints
- **Warn only — never auto-kill** (explicit decision). The cap drives a warning +
  affordance, not automatic termination.
- Count + RSS must reflect Buildwright-owned agents (children of its tmux server),
  not every `claude` process on the machine.
- Agents rename their process title to their version (e.g. `2.1.177`) — don't rely
  on a `claude` name match; use tmux pane ownership as the source.
- "Reap stale" should target idle agents and respect the S1 confirm-if-busy rule.
- Threshold N configurable in Settings (default ~8); warning is non-blocking.

## Definition of done
- Header shows `N agents · X.X GB` for the workspace, refreshed periodically.
- Past N, the indicator warns (color/badge) without blocking anything.
- A one-click "reap stale" reaps idle agents (confirm any busy ones).
- Numbers match `Scripts/bw-freeze-probe.sh`'s census file.

## Open questions
- Exact placement (workspace header next to the size chip? Mission Control?).
- Whether RSS is summed from `ps` per agent PID on a timer (cheap enough?) vs. a
  lighter proxy — decide against real code / perf.

## Absorbed by E46-S5 (2026-06-15)
Implemented as part of E46-S5 (reap-on-close confirm + dead-pane reap + governor census).
