---
id:        E50
title:     AI Scrum Master Intake — auto-triage captured text into the backlog
type:      epic
status:    done
category:  Buildwright
priority:  P2
design:    design.md
created:   2026-06-18
updated:   2026-06-27
---

# AI Scrum Master Intake — auto-triage captured text into the backlog

Raw ideas, bug reports, and feature requests arrive as unstructured text — in Slack,
in conversation, mid-session. Today they either get lost or require a manual
`/backlog story`  interview. Add a `/backlog capture <raw text>` command that acts as
an always-on AI Scrum Master: it reads the board, triages the text into the right epic
(or spawns a new one), sizes and types the item, and files it durably — no approval
gate. `/backlog undo` reverts the last capture. Full contract in `design.md`.

## Goal — the outcome we want
Zero-friction idea capture that is durably filed, correctly placed, and immediately
undoable. The board stays clean; no idea is lost; the AI does the placement work.

## Who it's for / the pain
rvance — ideas surface constantly mid-session and the current flow (manual `epic/story/task`
with a clarifying-Q interview) is too heavy for fleeting observations, bug sightings,
and on-the-fly feature notes. Capture must be instant; quality can be async.

## Constraints — must-haves, limits, non-negotiables
- **Auto-apply, no gate.** The whole point is zero friction. `undo` is the safety valve.
- **Durability first.** Every capture commits + pushes immediately (`sync`).
- **Backward-compatible schema.** Existing items (epic/story/task, no size field) stay valid.
- **Headless triage engine.** Runs as `claude -p` with read-only tools; pure JSON output.
- **Confidence threshold.** If best existing-epic fit < 0.6, the engine creates a new epic.
- **Undo is one-level only.** Targets the last capture; documented clearly.
- **Slack notify** after capture if webhook exists (same pattern as `start`/`done`).
- **New types: breakfix, spike.** Breakfix = defect under an existing epic. Spike = timeboxed investigation.
- **Size field.** XS | S | M | L | XL — guidance by type; absent = "—" on the board.

## Definition of done — how we'll know it's complete
- `/backlog capture <text>` runs end-to-end: triage → file → regen → sync → Slack → one-line summary.
- `/backlog undo` reverts the last capture cleanly, regens BOARD, syncs.
- BOARD.md renders `[S]` size chips and breakfix/spike markers.
- `SKILL.md` schema section documents `size` + new types; existing items stay valid.
- Design doc (`design.md`) is the canonical contract both the skill side and any future Buildwright integration implement.

## Open questions
- Should Buildwright surface a `/capture` hotkey that pipes selected terminal text to this command? (future, not in scope here)
- Rate-limiting: if capture fires in rapid succession, should items queue or each get its own commit? (current: each commits independently — simplest)

## Reconciliation (2026-06-27)
- verdict: built · confidence: 0.82 · via: code+tests+live
- evidence: /Users/rvance/.claude/skills/backlog/SKILL.md:188 — `capture <raw text>` AI Scrum Master auto-intake subcommand fully... ; /Users/rvance/.claude/skills/backlog/SKILL.md:228 — `undo` subcommand documented (git revert, one-level, never rewrit... ; /Users/rvance/.claude/skills/backlog/SKILL.md:28,32,44,45,47 — schema extended: type now epic|story|task|breakfix|spi... ; No automated tests exist or apply — this is a markdown skill (Claude-executed prose), not compiled code. Design §11 l...
- action: mark_done — undo available (`/backlog undo`); All Definition-of-Done pillars are present and live-proven: capture + undo subcommands, size/breakfix/spike schema wi...
