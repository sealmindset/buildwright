---
id:        E44-S1
title:     Reap agent on pane close (confirm if busy, else auto)
type:      story
status:    done
category:  buildwright
priority:  P1
parent:    E44
created:   2026-06-14
updated:   2026-06-14
---

# Reap agent on pane close (confirm if busy, else auto)

When a pane is closed, kill the Claude agent that pane owned so it can't become a
standing orphan. **Idle agent → reap automatically and silently. Busy agent
(CPU active / mid-task / awaiting input) → prompt before killing.**

## Goal — the outcome we want
Closing a tmux-backed pane terminates its agent (and the tmux window), with a
confirm step only when the agent is actually doing something.

## Who it's for / the pain
rvance — stale agents accumulate to GBs because nothing reaps them on close.

## Constraints
- Only reap agents Buildwright OWNS (its tmux session windows). Never touch the
  user's other Terminal sessions or the live Claude Code conversation. (Ground
  truth: an owned agent is a child of Buildwright's tmux server PID; the current
  CLI session is NOT a tmux child — see the reaping memory.)
- "Busy" detection must be reliable: e.g. pane CPU above idle threshold, or a
  known awaiting-response state — not a naive guess.
- Non-destructive framing: the confirm dialog should note the transcript persists
  (`claude --resume` recovers it); only scrollback is lost.
- Preserve tmux persistence model — this reaps on explicit pane close, it does not
  change cross-restart survival of panes left open.

## Definition of done
- Close an idle pane → agent + tmux window gone, no prompt, RSS reclaimed.
- Close a busy pane → confirm dialog; cancel keeps it, confirm reaps it.
- No leak: closing N panes reaps N agents (verify with the freeze-probe census).
- The current conversation / other Terminal sessions are never affected.

## Open questions
- Where pane-close is handled in the code (find the close path + tmux kill-window
  call) — confirm against real code before wiring the reap.
- Exact "busy" signal available from the control client (CPU sample vs. a tracked
  awaiting-output flag).

## Absorbed by E46-S5 (2026-06-15)
Implemented as part of E46-S5 (reap-on-close confirm + dead-pane reap + governor census).
