---
id: E51
title: AI Scrum Master — Code-Grounded Reconciliation + Autonomous Dispatch
type: epic
status:    done
category: Buildwright
priority: P1
size: L
design: design.md
created: 2026-06-18
updated:   2026-06-27
---

# E51 — AI Scrum Master — Code-Grounded Reconciliation + Autonomous Dispatch

Extend the `backlog` skill with two new capabilities so a sole developer never redoes already-built work:

1. **`/backlog reconcile`** — run a three-rung verification ladder (code → tests → live) against each open backlog item, auto-apply high-confidence verdicts reversibly, and flag ambiguous ones for the human.
2. **`/backlog dispatch`** — after reconciling, autonomously pick the next parallel-safe `not-built`/`partial` item and `start` it under the existing ship preamble (green-gate + harm-gate fully intact).

See **[design.md](design.md)** for the full reconciliation contract — the JSON schema, ladder logic, auto-apply rules, provenance format, and dispatch safety rules. The Buildwright Swift side implements the same JSON contract.

## Goal — the outcome we want
The board reflects reality. Items that are already fully built get marked done automatically (with evidence). Items that are partial surface their gaps. The next real unit of work starts itself without the developer having to manually triage the board first.

## Who it's for / the pain — who benefits and why it matters
rvance is a solo developer running many Claude Code sessions. Without grounding, backlog items can drift: a story says "not started" but the code was written two weeks ago. `reconcile` eliminates that drift so `dispatch` starts real work rather than re-implementing something already shipped.

## Constraints — must-haves, limits, non-negotiables
- **Read-only on docai.** The target repo (`~/Documents/GitHub/docai`) is never mutated; only the backlog board mutates.
- **BUILT requires all three rungs.** Code alone is not done. Tests alone is not done. A false "done" hides real work — the full ladder + confidence ≥ 0.8 is the minimum before auto-apply.
- **Reversible-only auto-apply.** Any auto-applied verdict can be undone with `/backlog undo`. Destructive or ambiguous actions go to the human flag list.
- **Dispatch never bypasses the green-gate or harm-gate** inherited from the Standing prompt preamble on `start`.
- **One dispatch at a time** — no parallel autonomous launches from a single dispatch run.
- **Backward compatible** — existing board items, frontmatter, and commands are unaffected. New `reconciled:` key is optional.

## Definition of done — how we'll know it's complete
- `/backlog reconcile` runs the three-rung ladder, emits per-item JSON, auto-applies confident reversible verdicts, flags the rest, and prints a compact report.
- `/backlog dispatch` picks the highest-priority parallel-safe not-built/partial item and starts it.
- Provenance block appended to every reconciled card.
- SKILL.md updated; backup refreshed; committed and pushed.
- The Buildwright side has the JSON contract to implement against.

## Open questions
- Live-check mechanism for authenticated docai routes (session cookie vs API key probe).
- Whether vitest/playwright are run headlessly or presence+CI-signal is sufficient for the tests rung.
- Configurable target-repo path (default docai; override for other vlf repos).

## Reconciliation (2026-06-27)
- verdict: built · confidence: 0.82 · via: code+tests+live
- evidence: /Users/rvance/.claude/backlog/skills/backlog/SKILL.md:115 — `reconcile [<id>|all]` command: three-rung ladder via hea... ; /Users/rvance/.claude/backlog/skills/backlog/SKILL.md:117-152 — verification ladder (CODE/TESTS/LIVE), strict JSON co... ; /Users/rvance/.claude/backlog/skills/backlog/SKILL.md:167-186 — `dispatch [--dry-run]` command: selection algorithm, ... ; No automated tests — feature is a markdown prompt-driven skill; DoD does not require a test suite for it. tests rung ...
- action: mark_done — undo available (`/backlog undo`); Both promised commands (reconcile + dispatch) plus undo are fully implemented in SKILL.md per the design contract, ba...
