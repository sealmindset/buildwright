---
id:        E52
title:     Helm — agent-first orchestrator (native, libghostty)
type:      epic
status:    done
category:  helm
priority:  P1
size:      XL
design:    design.md
created:   2026-06-19
updated:   2026-06-19
---

## SHIPPED (2026-06-19) — full spec delivered, from scratch in one session
`~/Documents/GitHub/helm` on `main`. M0 foundation · M1 agents+worktrees · M2 board-driven loop ·
M3 GitHub-native ship (loop closed) · M4a plugins/CVR · M4b browser · M4c remote/iPad+helmctl ·
M4d re-entry · M4e notifications · M4f loop polish · M4g dashboards. **12 headless verifiers all PASS**,
clean launch against the real board, repo pristine. libghostty 1.2.6, tmux persistence, pooled surfaces
(50+-safe), Claude-deep, harm-gated autonomous ship. Unencumbered IP (FSL ruled out forking Supacode for
a startup). Next: cut a GitHub remote + release build/install; daily-drive.

# Helm — agent-first orchestrator (native macOS, on libghostty)

**Helm** is a from-scratch native macOS agent-orchestrator: run a fleet of Claude Code agents in
parallel, each isolated in its own git worktree, shipped through GitHub — driven by the Scrum
Master backlog. Four pillars: **worktree isolation · fully native (libghostty) · GitHub-native
PR/CI/merge · 50+ parallel agents.** Fresh identity — its own repo + bundle id, built clean
(no code carried from anywhere). What makes it *yours*: free, customizable, plugin-friendly
(CVR), backlog-driven, with tmux persistence + remote/iPad.

## Decisions (2026-06-19 interview — full spec in design.md)
- **Identity:** agent-first orchestrator; the agent (**Claude Code, deep** — status hooks, Scrum
  Master, ship gates, cost) is the primary object. Fresh name **Helm**; new repo + bundle id.
- **Spine (closed loop):** board item ▶ → fresh worktree+branch → agent runs under the standing
  ship preamble → 100% green → PR → harm-gate → merge → worktree pruned → item marked done.
- **Scale:** 50+ agents. **Agent-grid** home. **Pooled libghostty surfaces** (~6 live visible +
  ~45 headless tmux workers, surfaced on focus) — the thing that makes 50+ safe.
- **Multi-repo registry** (docai / splashdown / helm / …); each item's project picks its repo.
- **GitHub-native:** full in-app PR / CI / conflict / merge (gh CLI now, REST/GraphQL later).
- **Worktrees:** `<repo>/.worktrees/<branch>`. **Stack:** Swift + SwiftPM, native macOS 26, tmux persistence.
- **Design:** polished-product (Supacode-grade). North star: terminal stability · never freeze ·
  elegant · not bloated.

## Foundation already proven (this session, in `~/Documents/GitHub/bw-ghostty-spike`)
- libghostty embeds in SwiftPM, renders a tmux-backed pane, persistence survives restart.
- 30 live surfaces @ ~11% CPU / ~1 ms main-thread stall; freeze concern does not reproduce (E52-S1).

## Milestones (sequenced — each shippable + daily-drivable; full detail in design.md)
- **M0 Foundation** — Helm skeleton + libghostty pane + tmux persistence + pooled-surface core.
- **M1 Agents + worktrees** — Claude agent abstraction, spawn → worktree/branch/session, agent grid, multi-repo, reaping.
- **M2 Board-driven loop** — backlog sidebar + Start (ship preamble), capture, attention/status.
- **M3 GitHub-native ship** — green → PR → CI watch → harm-gate → merge → cleanup → done (in-app).
- **M4 Parity + extras** — remote/iPad, browser panes, CVR/plugins, dashboards, re-entry niceties.

## Definition of done
- [ ] M0–M4 delivered per the plan; Helm is the daily driver.
