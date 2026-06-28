---
id:        E52-S10
title:     M4e — Push notifications: macOS notifications + helmctl watch + optional AFK webhook
type:      story
status:    done
category:  helm
priority:  P2
size:      M
parent:    E52
created:   2026-06-19
updated:   2026-06-19
---

Get pinged when an agent needs you — so you can walk away from 50 agents. Build on M4d
(`~/Documents/GitHub/helm`, main). Reference old Buildwright's notification approach READ-ONLY; write clean.

## Definition of done
- [ ] macOS notifications on agent transition to needs-input / done / failed / shipped (title = branch, body = what happened); click → focus that agent; setting to enable/disable + which transitions.
- [ ] `helmctl watch` — a tail mode (over SSH on iPad too): watches census + status files, prints a line + optional bell when an agent lands in needs-input/done/failed/shipped (`--bell`, `--needs-input-only`).
- [ ] Optional AFK push webhook: a configurable URL (ntfy/Slack-style) in settings; POST a short message on needs-you/failed/shipped so an iPad gets a real push without an SSH session. No-op if unconfigured.
- [ ] `swift build` clean; dispatch logic + webhook payload + `helmctl watch` detection verified headlessly (no real OS notifications, no network); M0–M4d verifiers still PASS; clean.
