# CVR Plugin — self-contained recorder + Buildwright's first plugin mechanism

**Epic:** E48 · **Category:** buildwright · **Priority:** P2 · **Date:** 2026-06-15
Derived from the 2026-06-15 interview (two rounds, all decisions recorded below).

---

## 1. Problem & context
CVR ("the recorder") is integrated into Buildwright only as a **launcher** — the
engine is the docai Playwright tool at `~/Documents/GitHub/docai/tools/cvr`, and it's
not self-contained: `record.ts` imports `playwright` resolved from docai's repo-root
`node_modules`, so on a new machine **CVR is dead unless the whole docai repo is
cloned + `npm install`ed + Chromium installed**. Two problems:
1. **Portability coupling** — Buildwright can't stand alone with working CVR.
2. **On-page UX collision** — the injected control toolbar is pinned bottom-right
   (`record.ts:137` `position:fixed; bottom:16px; right:16px`), which overlaps most
   websites' own buttons/links.

Fix both: extract CVR into its own self-contained repo (`github.com/sealmindset/cvr`),
make it installable as a **Buildwright plugin** (Buildwright's first), interlinked with
the workspace/terminal that launches it, and move the toolbar out of the way.

## 2. Goals / Non-goals
**Goals**
- A standalone `sealmindset/cvr` repo that runs with **zero docai dependency**.
- Buildwright installs it **as a plugin** from GitHub (a small, general mechanism).
- CVR is **interlinked** with the initiating pane (cwd, output, status, agent CLI).
- On-page controls relocated **top-center, draggable + collapsible** — never covering
  site UI (top or bottom).

**Non-goals**
- Not a full IDE plugin marketplace; a lightweight manifest mechanism, CVR-first.
- Not retiring docai's copy now (left as-is; reconcile later).
- Not changing what CVR captures (steps/screens) — only packaging, integration, UX.

> Note: a "plugin system" was a historical cockpit anti-goal. This is a **deliberate,
> scoped reversal** for *tool* plugins (external tools Buildwright launches), not
> in-app extensions (no editor/LSP plugins). Recorded in memory.

## 3. Design principles
- **Self-contained or it's not a plugin.** A plugin must install + run from a clean
  machine with no sibling-repo assumptions.
- **Augment, don't replace** ([[principle-build-workflow]]): keep the existing launcher
  UX; swap its hardcoded path for the plugin; docai's copy untouched.
- **The initiating terminal owns the session.** CVR runs in that pane's context and
  reports back to it — workspace-interlinked, not global.
- **Out of the way by default.** On-page UI must never compete with the site under test.

## 4. Architecture
**The plugin (sealmindset/cvr, private):** own `package.json` (pinned `playwright`,
`tsx`, `typescript`), `tsconfig`, a `bin/` CLI entry (agent-callable), the generic
engine (`record.ts`, `bundle.ts`, `adapters/`, `recon.ts`), eFileMN drivers moved to
`/examples`, a `postinstall`/setup that runs `playwright install chromium`, and a
`plugin.json` manifest Buildwright reads.

**Buildwright plugin mechanism (new, minimal):**
- `plugin.json` schema: `name`, `repo`, `version`, `install` cmd, `launch` cmd/CLI,
  optional `ui` hooks (e.g. "adds a launch sheet"), `settings` keys.
- Plugins live in `~/.buildwright/plugins/<name>/` (clone target).
- Install flow: `gh repo clone`/`git clone` → run `install` → register manifest →
  surface in Settings → Plugins (list / update / remove / install-from-URL).
- CVR's existing launch sheet is reframed as the plugin's UI hook; `Config.defaultCVRPath`
  is replaced by the resolved plugin path.

**Interlink contract (all four chosen):**
1. **Launch in initiating pane's context** — CVR's cwd = the pane's workspace/dir.
2. **Per-workspace recordings** — captures write to `<workspace>/cvr-captures/` (not a
   global `captures/`).
3. **Status streams back to the pane** — start/step/finish surfaces in that terminal
   (and Buildwright notifications).
4. **Agent-callable CLI** — a stable `cvr record --url … --label …` so a Claude agent
   in a pane can drive it programmatically.

## 5. The on-page control toolbar (the UX story)
Replace the bottom-right fixed bar with a **top-center, draggable, collapsible** widget:
- Default position top-center; **draggable** anywhere; **collapsible** to a small dot.
- **Position persists** (localStorage per origin) so it stays where you put it.
- Keeps 📸 Capture / ✓ Finish + Ctrl+Shift+C / Ctrl+Shift+F.
- High z-index retained; pointer-events only on the widget; never overlaps site nav by
  default (top-center pill is narrow + draggable away if a site centers its header).

## 6. Phasing → stories (sequence chosen: button fix → port → plugin)
- **S1 — Button relocation (quick win, ships first):** rework the injected toolbar in
  the *current* `record.ts` (top-center, draggable, collapsible, persisted). Immediate
  relief; carries into the ported repo. (Pragmatic exception to "leave docai as-is":
  this one-file UX edit is the relief you asked to ship first.)
- **S2 — Stand up sealmindset/cvr (self-contained):** create private repo; own
  package.json/tsconfig/bin CLI; move engine + `/examples`; auto Chromium install;
  README; `plugin.json`. `gh repo create` + push.
- **S3 — Prove self-contained:** fresh clone → `npm ci` + browser install → full
  recording with zero docai dependency (clean-machine simulation).
- **S4 — Buildwright plugin mechanism:** `plugin.json` schema, `~/.buildwright/plugins`,
  install-from-GitHub (clone→install→register), Settings → Plugins (list/update/remove).
- **S5 — CVR plugin integration + interlink:** wire the four interlink behaviors;
  replace `Config.defaultCVRPath` with the resolved plugin; launch sheet becomes the
  plugin's UI hook.

## 7. `[reconcile]`-with-codebase markers
- `CVRLaunchSheet.launch()` + `Config.defaultCVRPath` (swap path → plugin resolution).
- `record.ts` toolbar injection (lines ~132-146) for S1.
- How panes expose cwd/workspace + a way to stream status back (TmuxManager/AppState).
- Stable signing/launchd already exist; plugin dir under `~/.buildwright` is new.

## Open questions / risks
- Plugin install auth for a **private** repo (gh CLI token vs deploy key) — confirm in S4.
- Per-origin persisted toolbar position vs per-session — default per-origin.
- Whether `/mac-doctor` and future tools reuse the same plugin manifest (intended).
- Chromium install size/time on first plugin install (surface progress).
