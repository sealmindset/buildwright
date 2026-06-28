---
id:        E52-S8
title:     M4c — Remote / iPad: companion CLI + mobile-tuned tmux + Remote Access panel
type:      story
status:    done
category:  helm
priority:  P2
size:      M
parent:    E52
created:   2026-06-19
updated:   2026-06-19
---

The moat Supacode lacks: reach the agent fleet from an iPad. Helm agents already run in tmux, so a
remote client (Blink/SSH, mosh) attaches as a normal client. Build on M4b (`~/Documents/GitHub/helm`,
main). Reference old Buildwright's Remote/ READ-ONLY; write clean.

## Definition of done
- [ ] Companion CLI (installable to ~/.local/bin): list agents/sessions (id · repo · branch · status), show fleet status, attach to one (`tmux attach -t helm-agent-<id>`). Mobile-friendly output.
- [ ] Mobile-tuned tmux on agent sessions: a status bar showing branch + Claude status, touch/mobile-friendly options — usable from Blink on iPad.
- [ ] Remote Access panel (Settings): SSH reachability + session names + how to attach from iPad (Blink/mosh) + optional mosh guidance + the companion-CLI usage.
- [ ] `swift build` clean; CLI list/status verified headlessly (spawn test agent → list → reap); tmux options asserted on spawn; M0–M4b verifiers still PASS; clean.
- [x] Harden the M1/M2 verifier fail-paths (verify-spawn/start/reap) to reap on exit like verify-ship — kill the recurring orphan-worktree/session cruft.

## Done (2026-06-19) — merged to helm `main`
`helmctl` companion CLI (ls/status/attach, reads census, installs to ~/.local/bin); mobile-tuned tmux
(status line + touch opts, session-scoped) on spawn; Remote Access panel (SSH/Blink/mosh guidance).
`verify-remote` PASS; **all verifiers leak-proofed** (VerifyCleanup — proven by injected failure → 0 orphans).
Also this pass: cleared 4 dead census entries (GUI reapOrphansOnLaunch), and **fixed a real perf footgun** —
`BacklogItem`/`BacklogEpic` were Equatable-but-not-Hashable, hitting the Obj-C `-hash` slow path in the
sidebar at board scale; now Hashable (keyed on id), verified clean against the real ~50-item board.
