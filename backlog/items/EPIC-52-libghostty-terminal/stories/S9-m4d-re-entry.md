---
id:        E52-S9
title:     M4d — Re-entry: while-you-were-away strips + context snapshots + breakfix/feature templates
type:      story
status:    done
category:  helm
priority:  P2
size:      M
parent:    E52
created:   2026-06-19
updated:   2026-06-19
---

Smooth return-to-work, which matters most at fleet scale (you can't watch 50 agents). Build on M4c
(`~/Documents/GitHub/helm`, main). Reference old Buildwright's re-entry approach READ-ONLY; write clean.

## Definition of done
- [ ] "While you were away" strip: on foreground/relaunch, a dismissable summary of fleet changes since last-seen — N shipped / done / need-you / failed, with the items — computed from a persisted last-seen snapshot vs current state.
- [ ] Context snapshots: persist per-agent state + last-seen so the digest is accurate across relaunch (builds on the census + status files).
- [ ] Breakfix/Feature templates: "New from template" spawns an agent with a guarded pre-filled prompt (branch discipline, minimal-change, test-before-stop); templates editable (stored in app-support).
- [ ] `swift build` clean; digest + template store verified headlessly (synthetic before/after fleet → assert the strip; template CRUD); M0–M4c verifiers still PASS; clean (leak-proof verifiers).
