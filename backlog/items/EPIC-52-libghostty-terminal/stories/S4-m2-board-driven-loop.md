---
id:        E52-S4
title:     M2 — Board-driven loop: backlog sidebar + Start (ship preamble), capture, attention, grid polish
type:      story
status:    done
category:  helm
priority:  P1
size:      L
parent:    E52
created:   2026-06-19
updated:   2026-06-19
---

The Scrum Master drives the fleet. Build on M1 (`~/Documents/GitHub/helm`, main).
Start a backlog item → it spawns an agent in the right repo's worktree and runs the item under
the standing ship preamble. Plus ⌘⇧N capture, attention surfacing, and the grid/titlebar polish.

## Definition of done
- [ ] Backlog reader + sidebar: parse `~/.claude/backlog` (epics/stories/frontmatter); browse, filter, search.
- [ ] **Start** an item → resolve its project→repo → spawn an M1 agent in a worktree → run prompt = standing preamble + item body in the Claude pane → set item in-progress.
- [ ] Attention surfacing: a "needs you" sort + count (needs-input / done / failed bubble up).
- [ ] ⌘⇧N capture → triage → file into the board (verified against a TEMP board, not the real one).
- [ ] Grid polish: 2-D tile layout + keyboard nav; dark/seamless titlebar (the screenshot nit).
- [x] `swift build` clean; Start/sidebar verified headlessly WITHOUT triggering an autonomous run; GUI smoke updated.

## Done (2026-06-19) — merged to helm `main`
Backlog sidebar (live-watch parse of ~/.claude/backlog, filter/search); Start → project→repo →
agent in worktree → prompt = standing preamble + item body → in-progress; attention "needs-you first"
+ count; ⌘⇧N capture (triage → file → undo); 2-D NSCollectionView grid + keyboard nav; dark seamless
titlebar. Verified independently: build clean, `verify-start` PASS (no autonomous run), real board 0 dirty.
`HELM_BACKLOG_DIR`/`HELM_SKILL_FILE` overrides keep tests off the real board. M3 prep: `Agent.backlogItemID` persisted.
