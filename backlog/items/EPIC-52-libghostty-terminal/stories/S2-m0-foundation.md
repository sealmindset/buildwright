---
id:        E52-S2
title:     M0 — Foundation: Helm skeleton + libghostty pane + tmux persistence + pooled-surface core
type:      story
status:    done
category:  helm
priority:  P1
size:      M
parent:    E52
created:   2026-06-19
updated:   2026-06-19
---

First milestone of Helm. A runnable native macOS app: SwiftPM skeleton + libghostty
(`Lakr233/libghostty-spm` 1.2.6) + one tmux-control-mode-backed terminal pane with
persistence + the pooled-surface attach/detach seam (the thing that makes 50+ safe).
Built clean — no code ported from Buildwright. Reference proof: `~/Documents/GitHub/bw-ghostty-spike`.

## Definition of done
- [ ] New `helm` repo (Swift + SwiftPM, macOS 26, Apple Silicon); .gitignore/README/CHANGELOG; libghostty-spm pinned.
- [ ] App launches a window with a working libghostty terminal surface (HOST_MANAGED byte-feed).
- [ ] tmux control-mode client feeds the pane; session survives quit + relaunch (persistence).
- [ ] Pooled-surface core: attach surface on focus / detach on blur (seam ready for M1 fan-out).
- [x] `swift build` clean; runnable; manual GUI smoke documented.

## Done (2026-06-19)
`~/Documents/GitHub/helm` built clean (verified independently). Window + libghostty HOST_MANAGED
surface + tmux control-mode backing; **persistence verified headlessly** (`session_created` epoch
identical across quit/relaunch, scrollback survived). Pooled-surface seam in place (capacity 1).
`./run.sh` to launch. rvance greenlit M1. (swift-tools 6.2 for macOS .v26 — documented.)
