---
id:        E44
title:     Buildwright agent lifecycle & freeze prevention
type:      epic
status:    ready
category:  buildwright
priority:  P1
created:   2026-06-14
updated:   2026-06-14
---

# Buildwright agent lifecycle & freeze prevention

Buildwright never reaps Claude agents. Because tmux control-mode persistence keeps
agents alive across app restarts (by design), they accumulate until the workspace
is carrying dozens of stale agents nobody is using. On 2026-06-14 the `document-ai`
session had grown to **26 windows / 26 idle agents = ~10.7 GB** still alive with
the app closed.

That standing army did **not** OOM the machine, but it is the leading suspect in a
full-desktop freeze (~11:30 that day) that left **no** JetsamEvent / memorystatus /
watchdog artifact — the signature of a WindowServer / main-thread stall, consistent
with Buildwright reattaching to all 26 windows and feeding their `%output` into
SwiftTerm views at once on launch. Forensics couldn't prove it post-hoc, so a
`Scripts/bw-freeze-probe.sh` was added to capture a live `sample` next time.

This epic makes agent lifecycle explicit so the standing army can't re-form and the
reattach storm can't wedge the compositor.

## Goal — the outcome we want
Buildwright reaps agents it owns, surfaces how many are live + their memory, and
never storms every pane at once on reattach — so the desktop can't be frozen by
accumulated/standing agents.

## Who it's for / the pain — who benefits and why it matters
rvance. A $6000 M4 Max / 128GB machine locked up hard (Terminal + whole desktop),
forcing a force-quit of Buildwright to recover. Today the only mitigation is
manually `tmux kill-session`. The tool should manage its own agents.

## Constraints — must-haves, limits, non-negotiables
- **Preserve persistence + iPad access** — do NOT remove tmux control mode (see
  the terminal-direction decision). Reaping is about agents Buildwright owns, not
  abandoning the persistence model.
- **Human-gated where consequential.** Killing a busy agent must confirm first.
- Agent transcripts persist to disk → a reaped agent is recoverable via
  `claude --resume`; only tmux scrollback is lost. Make that non-destructive nature
  visible in any kill UI.
- Detection of "busy vs idle" must be reliable (CPU activity / awaiting-input), not
  a guess that nukes live work.

## Definition of done
- Closing a pane reaps its idle agent automatically; a busy agent prompts first (S1).
- Header shows live agent count + total RSS; warns past a threshold with a one-click
  "reap stale" action; never auto-kills (S2).
- Reattach no longer drives all panes' redraw at once; the compositor stays
  responsive on launch with many windows (S3).
- Verified live with `Scripts/bw-freeze-probe.sh` — no main-thread stall on a
  many-window reattach.

## Open questions
- Exact warn threshold N for the census (start at 8? make it a Setting?).
- Reattach: lazy-render only the visible/active pane and hydrate others on focus,
  vs. throttled/staggered hydration of all — decide in S3 against the real code.
- Provenance of the original "impossible size" glitch frame is still open (see
  terminal-direction history) — out of scope here but related.

Stories: S1 reap-on-pane-close · S2 agent census + cap warning · S3 reattach without redraw storm.
