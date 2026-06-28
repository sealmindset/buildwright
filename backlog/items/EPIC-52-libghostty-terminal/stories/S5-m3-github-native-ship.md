---
id:        E52-S5
title:     M3 — GitHub-native ship: PR + CI watch + harm-gate merge + close the loop
type:      story
status:    done
category:  helm
priority:  P1
size:      L
parent:    E52
created:   2026-06-19
updated:   2026-06-19
---

Closes the loop. Build on M2 (`~/Documents/GitHub/helm`, main). When an agent reaches green and
opens its PR (per the standing ship preamble), Helm surfaces the PR + CI in-app, holds the
harm-gate, and on merge prunes the worktree and marks the board item done — `board ▶ … → shipped → done`.

## Definition of done
- [ ] Per-agent PR surfacing (gh): detect the PR on the agent's branch; PR # · state · CI on the tile + a detail panel.
- [ ] CI watch: poll the PR's checks; surface pass/fail; a red check leaves the (live) agent to auto-fix per the preamble.
- [ ] Harm-gate merge: in-app Merge = the human approval gate (harmful/app-impacting changes never auto-merge); auto-merge-for-safe optional behind a flag.
- [ ] On merge → `git worktree remove` + branch cleanup + set the board item `done` + board sync.
- [ ] A distinct "failed" agent state; basic conflict detection surfaced.
- [x] `GhClient` abstraction (gh CLI now, API later); ship state machine verified with a MOCKED gh — no real PR/CI/merge against any real repo; GUI smoke updated.

## Done (2026-06-19) — merged to helm `main`. THE LOOP IS CLOSED.
PR surfacing + CI watch + harm-gate Merge + loop-close (worktree prune + branch clean + board item
→ done) + failed/conflict states. `GhClient` (CLIGhClient via gh / MockGhClient). `verify-ship` PASS
end-to-end (mocked gh, throwaway repo, temp board — nothing real touched). **Independent run caught a
reaping leak** (verify-ship orphaned tmux sessions on its failure path — the freeze failure mode); fixed
with a hard guarantee (fail() reaps before exit), re-verified 0 strays. board ▶ → ship → done now runs hands-off, gated where it matters.
