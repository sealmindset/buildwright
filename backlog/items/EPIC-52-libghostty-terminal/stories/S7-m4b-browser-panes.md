---
id:        E52-S7
title:     M4b — Browser panes: WKWebView + tabs + bookmarks + private-by-default
type:      story
status:    done
category:  helm
priority:  P2
size:      M
parent:    E52
created:   2026-06-19
updated:   2026-06-19
---

Tiled WKWebView browser panes alongside the agent terminals — handy beside a focused agent
(docs, preview, the app the agent is changing). Build on M4a (`~/Documents/GitHub/helm`, main).
Reference old Buildwright's Browser/ approach READ-ONLY; write clean.

## Definition of done
- [ ] Browser pane: WKWebView + address bar + back/forward/reload; **private-by-default** (nonPersistent data store) with a per-pane glasses toggle (private↔persistent).
- [ ] Tabs: per-pane tab strip with +, page-title labels, restore on restart.
- [ ] Bookmarks: ☆ star + bookmarks bar; per-workspace + shared set; manage (rename/move/delete).
- [ ] Integration: a "+ Browser" affordance opens a browser pane in Helm's window/focus model; open panes/tabs persist across restart.
- [x] `swift build` clean; non-GUI parts verified (tab/bookmark model codable round-trips, private-store wiring) headlessly; M0–M4a verifiers still PASS; GUI smoke updated.

## Done (2026-06-19) — on helm `main`
Browser panes = grid tiles trailing agent tiles (shared focus model). WKWebView + address bar/nav,
private-by-default (shared nonPersistent store) + per-pane glasses toggle; tabs (+ , restore-on-restart);
bookmarks (per-workspace + shared, full CRUD). "+ Browser" / ⌘T. `verify-browser` PASS (headless model/
persistence); M0–M4a verifiers still PASS; repo clean (0 sessions, no orphan worktrees).
