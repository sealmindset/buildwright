---
id:        E52-S6
title:     M4a — Plugin system (install-from-GitHub) + CVR as the first plugin
type:      story
status:    done
category:  helm
priority:  P1
size:      L
parent:    E52
created:   2026-06-19
updated:   2026-06-19
---

First slice of M4. Helm's extensibility — the differentiator. A manifest-based plugin
mechanism that installs from GitHub, plus CVR (Chromium recorder) packaged as the first plugin.
Build on M3 (`~/Documents/GitHub/helm`, main). Clean implementation (reference old Buildwright's
plugin/CVR approach read-only; the `cvr` repo is at `~/Documents/GitHub/cvr`).

## Definition of done
- [ ] Plugin manifest format + `PluginManager`: install-from-GitHub (clone + read manifest + register), enable/disable, uninstall; plugins live in Helm's app-support `plugins/` dir.
- [ ] Settings → Plugins panel: list installed, install from a GitHub URL, enable/disable, remove.
- [ ] CVR packaged as the first Helm plugin: installable, provides a "record" capability (launch CVR; captures land in a sensible per-agent/workspace dir).
- [x] `swift build` clean; install/register/enable/uninstall verified headlessly via a LOCAL throwaway plugin (no network); CVR plugin installs/registers; GUI smoke updated.

## Done (2026-06-19) — on helm `main`
Plugins panel (⌘,): install-from-GitHub (owner/repo · https via gh · local path), enable/disable/remove;
`helm-plugin.json` manifest + PluginManager + registry. CVR packaged as the first plugin (installs through
the same path; provides the `record` capability → per-workspace `cvr-captures`). `verify-plugins` PASS
(local source, temp app-support, no network); M0–M3 verifiers still PASS; real plugins dir untouched.
**Cleanup:** pruned 4 orphan agent worktrees/branches left by earlier verifier failure-runs (freeze-discipline).
Follow-up: harden verify-spawn/start/reap fail-paths to reap like verify-ship. Next M4: wire a Record toolbar affordance + pane-injection.
