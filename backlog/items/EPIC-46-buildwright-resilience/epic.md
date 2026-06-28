---
id:        E46
title:     Buildwright Resilience — self-healing, self-governing cockpit
type:      epic
status:    ready
category:  buildwright
priority:  P1
design:    design.md
created:   2026-06-15
updated:   2026-06-15
---

# Buildwright Resilience — self-healing, self-governing cockpit

Everything (terminals + agents) runs under one roof (one app + one tmux server). A
leak, resource mismanagement, output storm, or main-thread hang can self-DoS the
machine — it froze a 128GB M4 Max desktop on 2026-06-14. Make resilience structural:
self-governing, self-preserving, self-healing — and provably so. Full design in
`design.md`.

## Goal — the outcome we want
No agent/output/leak condition can freeze the desktop. Resources are governed
continuously even with the GUI closed; the GUI can hang/crash/relaunch with zero
impact on agents; faults (tmux death, main-thread hang, drift) self-heal; resilience
is proven by a chaos suite that gates releases.

## Who it's for / the pain
rvance — wants Buildwright as his primary daily AI cockpit but needs to trust it has
his back after a hard desktop freeze. "I'm on an M4 Max / 128GB for goodness sakes."

## Constraints — must-haves, limits, non-negotiables
- Scope stays **cockpit, bulletproofed** — no editor/file-tree/LSP. "Main IDE" = trust.
- Keep tmux + iTerm2 control-mode model (persistence + iPad essential).
- Two-tier defense: normal = warn-only (E44); cliff = automatic shed-load.
- Degrade rendering first, agents last; never kill anything but clearly-dead, and only
  at the cliff; transcripts persist (`claude --resume`).
- Governor must run even with the GUI closed (→ launchd daemon).
- Every resilience property must have a chaos test (no theory-only fixes).

## Definition of done
- Phase 1 (safety net) eliminates the output-storm freeze in-process.
- buildwrightd owns tmux+agents+governor; GUI is a reconnecting client.
- All four self-heal behaviors live; health panel warns pre-cliff.
- Chaos suite gates releases (green-or-no-ship), runnable without swift-testing.

## Architecture (decided via interview 2026-06-15)
Separate **launchd login-agent daemon `buildwrightd`** owns per-workspace tmux servers,
agents, the two-tier resource governor, per-pane flow control, and self-heal; the
SwiftUI app is a thin reconnecting renderer. Thresholds auto-derived from RAM
(overridable). Ship the **safety net in-process first**, then extract into the daemon,
then self-heal + chaos gate.

## Open questions
See design.md §Open questions (budget %, IPC choice, agent-pause mechanism, daemon
surface). Absorbs **E44** (E44-S1→S5, E44-S2→S3/S5, E44-S3→S10).

Stories: Phase 1 S1–S6 (safety net) · Phase 2 S7–S11 (daemon) · Phase 3 S12–S15 (self-heal + chaos). Phase 1 detailed as cards; 2–3 enumerated in design.md, split when Phase 1 nears done.
