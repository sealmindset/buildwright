---
id:        E52-S3
title:     M1 — Agents + worktree isolation: spawn, Agent Grid, multi-repo, reaping
type:      story
status:    done
category:  helm
priority:  P1
size:      L
parent:    E52
created:   2026-06-19
updated:   2026-06-19
---

The milestone where Helm becomes the product. Build on M0 (`~/Documents/GitHub/helm`).
The agent (Claude Code, deep) becomes the primary object: spawn → its own worktree + branch +
tmux session + Claude pane; the **Agent Grid** home; **multi-repo registry**; pooled surfaces
fanned out past capacity 1; and **reaping/lifecycle** (the BW1 freeze lesson — never accumulate orphans).

## Definition of done
- [ ] `Agent` model (Claude Code): spawn creates `<repo>/.worktrees/<branch>` + branch + tmux session + claude pane.
- [ ] Multi-repo registry (configured repos; each agent scoped to one).
- [ ] Agent status via Claude Code hooks (working / needs-input / done) → tile state.
- [ ] SurfacePool capacity > 1: attach-on-focus, evict LRU; many agents, few live surfaces.
- [ ] Agent Grid home: status tiles (repo · branch · state); click → focus → surface attaches showing that agent's pane.
- [ ] Reaping: close/kill an agent → tmux session killed + worktree pruned; reap orphans; census.
- [x] `swift build` clean; spawn/grid/reap verified headlessly; GUI smoke updated.

## Done (2026-06-19) — merged to helm `main` (7a570bd)
Agent Grid home; spawn → worktree+branch+tmux+Claude pane (rollback on fail); multi-repo registry
(`repos.json`); status via `helm-hook` → `~/.claude/settings.json` (non-destructive, env-gated on
HELM_AGENT_ID); SurfacePool cap 6 + LRU; reaping (kill session + prune worktree + conservative branch
delete; launch census reaps orphans). Verified independently: build clean, `verify-pool` PASS, repo
left clean. **NOTE:** launching the GUI installs `~/.local/bin/helm-hook` + merges Helm hooks into
`~/.claude/settings.json` (by design, reversible). Deferred to M2: 2-D grid + keyboard nav, backlog-driven spawns.
