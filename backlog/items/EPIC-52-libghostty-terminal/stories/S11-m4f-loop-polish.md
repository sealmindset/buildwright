---
id:        E52-S11
title:     M4f — Loop polish: PR detail + conflict resolution + auto-merge toggle + context/token + Record button
type:      story
status:    done
category:  helm
priority:  P2
size:      L
parent:    E52
created:   2026-06-19
updated:   2026-06-19
---

The finale — make the closed loop feel finished. The M3/M4-deferred polish. Build on M4e
(`~/Documents/GitHub/helm`, main). After this, the full M4 spec is delivered.

## Definition of done
- [ ] PR detail panel: CI check list + diff (gh), per-agent, in the focused-agent detail view.
- [ ] In-app conflict resolution (at least: surface conflicting files + a resolve flow / open-in-pane; detection already exists).
- [ ] Auto-merge toggle UI on the tile/detail (model + safe-track gating already wired in M3).
- [ ] Per-agent context/token surfacing (from Claude hooks / cost).
- [ ] Clickable while-you-were-away strip → jump to the named failed/needs-you agent (+ "since you left" age in the header).
- [ ] Record toolbar button: deliver the CVR plugin's RecordAction into the focused agent's pane (the last CVR inch).
- [ ] `swift build` clean; new logic verified headlessly; M0–M4e verifiers still PASS; clean.
