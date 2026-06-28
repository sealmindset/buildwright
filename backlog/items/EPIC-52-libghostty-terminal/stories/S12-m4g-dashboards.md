---
id:        E52-S12
title:     M4g — Dashboards: Finish Line + Backlog Map + Mission Control (final slice)
type:      story
status:    done
category:  helm
priority:  P2
size:      L
parent:    E52
created:   2026-06-19
updated:   2026-06-19
---

The last slice. Board + fleet visualization. Build on M4f (`~/Documents/GitHub/helm`, main).
After this, the entire Helm M4 spec is delivered. Reference old Buildwright's Finish Line /
Backlog Map / Mission Control READ-ONLY; write clean.

## Definition of done
- [ ] Finish Line: live burn-down from the board — tier the work (Next / Blockers / In-flight / Polish / Later), counts, inflow-by-day, scope toggle (helm/all), search; in-flight reflects running agents.
- [ ] Backlog Map: full-screen dependency/flow graph — epic→child containment + `depends:` edges, status-colored nodes with type/priority/size badges, filters + zoom, click → focus/start.
- [ ] Mission Control: fleet pane-of-glass — agents summarized by state/repo with the board tie-in.
- [ ] `swift build` clean; the computations (tiering, graph node/edge derivation, fleet summary) verified headlessly on a synthetic board+fleet; M0–M4f verifiers still PASS; clean.
