# TODO

## Setup
- [ ] Install mosh for iPad remote access: `brew install mosh` (Remote Access panel guides this)
- [ ] Grant Accessibility permission if you want CVR Chromium window auto-docking

## E50: AI Scrum Master intake (shipped 2026-06-18 — verify in the GUI)
- [ ] Quit + relaunch /Applications/Buildwright.app to load the new build (⌘⇧N / E50).
- [ ] Smoke-test ⌘⇧N: capture a throwaway thought → triage + file → `✓ Filed … — Undo` toast → hit Undo (or `/backlog undo`) so no test item lingers. Also confirm via ⌘K palette ("Capture to backlog").
- [ ] Sanity-check the app door's live `claude -p` triage quality (placement/size look right on real captures).
- [ ] (Optional) Bump the hardcoded version in Scripts/bundle.sh when cutting a real release.
- Skill door (`/backlog capture` + `/backlog undo`, schema `size`/breakfix/spike) is live; verified by the E46-S18 capture.

## Bug: full-pane "selection wash" when an epic finishes — now tracked as backlog E46-S18 (diagnosed 2026-06-16, not yet fixed)
- [ ] Symptom: when an agent/epic finishes, the whole terminal pane shows an inverse-video wash (looks "selected"); pane still works; clears when you type/click/resize elsewhere.
- [ ] Diagnosis (high confidence): it's a real SwiftTerm text selection. SwiftTerm only clears selections on streaming output when mouse reporting is ON (`feedPrepare`/`linefeed` guard on `allowMouseReporting`). On process exit the TUI turns mouse reporting OFF, so SwiftTerm deliberately preserves the selection and it renders over the whole pane. `keyDown`/`mouseDown`/`resizeSubviews`/idle-converge each reset `selection.active` → that's why it clears.
- [ ] OPEN: what *creates* the whole-buffer selection at completion (stray gesture? triple-click? auto select-all?). This decides fix: "clear selection on process-exit transition" vs. fix a gesture path. Do NOT ship a guess — confirm first.
- [ ] To confirm next session: (1) with a pane washed, does ⌘C copy the entire screen's text? (2) does it happen on plain shell panes too, or only Claude/agent panes? OR build an instrumented debug build that logs selection state at the moment a pane exits.

## Next session (2026-06-15)
- [ ] Reinstall from main to run the full safety net + CVR plugin: `git checkout main && Scripts/bundle.sh --install`
- [ ] Smoke-test (GUI-only confirms): governor chip in Attention menu, watchdog recovery notification, busy-close confirm alert, Settings → Plugins tab, a real CVR recording (toolbar top-center; captures land in `<workspace>/cvr-captures`)
- [ ] E46 Phase 2 — `buildwrightd` supervisor daemon (backlog E46-S7…S11): the big lift that makes the GUI disposable
- [ ] E46 Phase 3 — full self-heal (auto-rebind, drift anneal) + chaos suite as a release gate (S12…S15); remote/AFK (S16…S17)
- (Full plan + status: ~/.claude/backlog E46 + E48)

## Ideas (deliberately deferred — pick up whenever real use demands them)
- [ ] Saved layout presets per workspace ("my standard docai layout")
- [ ] Per-workspace browser profiles (separate cookie jars)
- [ ] Notification focus mode (batch pings while heads-down)
- [ ] Synchronized input across panes (tmux synchronize-panes toggle in UI)
- [ ] App icon
- [ ] Code signing + notarization if ever distributed beyond this machine

## Completed
- [x] Private browsing by default + per-pane glasses toggle + Settings default; old web data wiped from disk (v0.7.0)
- [x] Browser tabs: tab strip with +, popup links open as tabs, restore on restart (v0.4.0)
- [x] Per-project bookmarks: ☆ star + bookmarks bar, shared set, ⌘K integration (v0.5.0)
- [x] Trackpad scrolling in tmux panes (v0.6.0)
- [x] ⌘K command palette (v0.3.0)
- [x] ⌥⌘-arrow pane navigation + ⌘⌥1-9 workspace hotkeys (v0.3.0)
- [x] Backlog close-the-loop: "mark item done" on finished Started panes (v0.3.0)
- [x] Attention queue, ⌘J, menu-bar count, status ages (v0.2.0)
- [x] "While you were away" re-entry strips + context snapshots (v0.2.0)
- [x] Breakfix/Feature ship templates (v0.2.0)
- [x] Fix tmux helper-session reaping ("can't find session") (v0.1.1)
- [x] Installed to /Applications
