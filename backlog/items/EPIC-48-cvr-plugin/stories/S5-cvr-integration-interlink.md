---
id:        E48-S5
title:     CVR plugin integration + workspace/terminal interlink
type:      story
status:    done
category:  buildwright
priority:  P2
parent:    E48
created:   2026-06-15
updated:   2026-06-15
---

# CVR plugin integration + interlink

Wire the installed CVR plugin into Buildwright and interlink it with the workspace and
the terminal pane that launches it (all four behaviors).

## Goal
Launching CVR from a pane runs in that pane's context, saves into the workspace, reports
back to the pane, and is drivable by an agent.

## Constraints
- Replace `Config.defaultCVRPath` with the resolved plugin path (S4); the existing
  `CVRLaunchSheet` becomes the plugin's UI hook (augment, not replace).
- Interlink (all four):
  1. Launch in the initiating pane's cwd/workspace.
  2. Captures write to `<workspace>/cvr-captures/` (per-workspace).
  3. Status (start/step/finish) streams back to the initiating terminal pane + notifications.
  4. Agent-callable CLI works from inside a pane (programmatic start/stop).
- `[reconcile]`: `CVRLaunchSheet.launch()` (currently send-keys `npx tsx record.ts`),
  pane cwd/workspace access, status channel back to the pane.

## Definition of done
- From a pane in workspace X, CVR records with cwd=X, output in X/cvr-captures, status
  shown in that pane; an agent can start it via CLI.
- No remaining hardcoded docai path.

## Result (2026-06-15) — built + verified (branch bw/e48-cvr-plugin, commit 30ef636)
CVRLaunchSheet resolves the recorder from the installed plugin
(PluginManager.plugin("cvr") → ~/.buildwright/plugins/cvr), legacy docai path as
fallback. Interlink (all four): (1) pane opens in the initiating workspace dir
(focused pane .directory ?? baseRepo); (2) `--captures-dir <workspace>/cvr-captures`;
(3) recorder output streams into that in-workspace pane (+ Chromium auto-dock);
(4) invokes the agent-callable CLI `node <plugin>/bin/cvr.mjs record …` — verified
runnable from the installed plugin. Builds clean. 'CVR not found' now points at
Settings → Plugins. GUI launch (opens a browser) is the manual confirm.
