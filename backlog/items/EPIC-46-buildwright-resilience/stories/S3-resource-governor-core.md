---
id:        E46-S3
title:     Resource governor core (RAM-derived budgets + amber warn)
type:      story
status:    done
category:  buildwright
priority:  P1
parent:    E46
created:   2026-06-15
updated:   2026-06-15
---

# Resource governor core

Continuous resource tracking with two tiers. This story builds the tracking + the
**amber / warn-only** tier (the cliff/auto tier is E46-S4). Folds in the E44-S2 census.

## Goal
Buildwright always knows its footprint + system pressure and warns before the cliff —
never auto-killing in normal life.

## Constraints
- Signals: macOS `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` (normal/warn/critical) +
  own footprint via `proc_pid_rusage`/libproc (sum owned-agent RSS + render memory).
- Budgets **auto-derived from physical RAM**, overridable in Settings.
- Owned-agent identity = tmux parentage, never a `claude` name match (agents rename to
  `2.1.x`); never count the live Claude Code session or other apps.
- Amber tier = warn-only (E44-S2 behavior): health surface + one-click "reap stale".

## Definition of done
- Accurate live footprint + pressure state; amber warning fires before the cliff.
- Census numbers match `Scripts/bw-freeze-probe.sh`. No auto-kill in this tier.

## Result (2026-06-15) — built (branch bw/e46-s3-governor; PR #1 S1+S2 merged to main first)
`Resilience/ResourceGovernor.swift`: subscribes to macOS memory pressure
(DispatchSource normal/warning/critical) + samples owned-agent phys_footprint every 6s
(proc_pid_rusage over `tmux list-panes -s` pane pids of TmuxManager.ownedSessionNames()).
RAM-derived budgets: amber = pressure-warning OR footprint >25% phys OR ≥12 agents;
red = pressure-critical OR >50% phys. Warn-only (no kill — that's S4). Tier + census
(`N agents · X.X GB · pressure · tier`) surface in the Attention menu when not green;
started in AppState.bootstrap. Builds clean (rusage interop OK); census query path
verified live (tmux pane_pid lookup). Pending: in-app visual confirm of the amber/red
menu line + footprint accuracy under a real agent load (GUI). Settings-overridable
thresholds + the full health panel are E46-S14.
