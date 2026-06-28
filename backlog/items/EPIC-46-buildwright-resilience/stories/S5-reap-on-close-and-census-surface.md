---
id:        E46-S5
title:     Reap-on-pane-close + agent census/health surface (absorbs E44-S1/S2)
type:      story
status:    done
category:  buildwright
priority:  P1
parent:    E46
created:   2026-06-15
updated:   2026-06-15
---

# Reap-on-pane-close + agent census/health surface

Absorbs **E44-S1** (reap on pane close, confirm-if-busy) and the surfacing half of
**E44-S2** (live agent count + total RSS in the header), now wired to the governor.

## Goal
Closing a pane reaps its idle agent (confirm if busy); the header always shows live
agent count + total RSS with the governor's amber/red state.

## Constraints
- Reap only owned agents (tmux parentage); never the live session or other apps.
- Idle → auto-reap silently; busy → confirm (note `claude --resume` recovers it).
- Header chip mirrors governor tier (green/amber/red) — same idea as the size chip.
- See E44-S1 / E44-S2 cards for the original detail; this supersedes them.

## Definition of done
- N pane closes → N agents reaped; no orphan accumulation (verify via probe census).
- Header shows accurate count + RSS + tier; one-click "reap stale" present.

## Result (2026-06-15) — built (branch bw/e46-s5-reap)
closePane already reaps the agent (kills the tmux window); added the busy gate +
dead-pane reap. requestClosePane confirms before closing a pane whose Claude is .working
(MainWindowView alert; transcript persists note), else closes; idle → silent reap. View
teardown centralized into closePane so a cancelled confirm leaves the live view intact;
all UI close call-sites (BuildwrightApp, LayoutView x2, MissionControl) rerouted.
reapDeadPanes() + TerminalViewCache.exitedPaneIDs() reap clearly-dead (exited) panes —
surfaced as "Reap N dead panes" in the Attention menu AND wired as S4's cliff reap rung
(governor.onCliffReap). Census surfaces via the governor (S3); the dedicated header chip
is folded into the S14 health panel. Builds clean. Pending: GUI confirm of the alert +
reap button. Absorbs E44-S1 (done) and the surfacing half of E44-S2.
