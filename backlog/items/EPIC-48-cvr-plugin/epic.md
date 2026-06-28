---
id:        E48
title:     CVR Plugin — self-contained recorder + Buildwright plugin mechanism
type:      epic
status:    done
category:  buildwright
priority:  P2
design:    design.md
created:   2026-06-15
updated:   2026-06-15
---

# CVR Plugin — self-contained recorder + Buildwright plugin mechanism

CVR's engine lives in docai (`tools/cvr`) and resolves Playwright from docai's
node_modules, so Buildwright can't run CVR on a machine without the full docai repo.
Extract CVR into a self-contained `github.com/sealmindset/cvr`, make it installable as
a Buildwright **plugin** (the first), interlinked with the launching workspace/terminal,
and move the on-page control toolbar out of the way (it currently sits bottom-right and
collides with site buttons). Full design in `design.md`.

## Goal
A standalone CVR repo that runs with zero docai dependency; Buildwright installs it as a
plugin from GitHub; CVR runs in the initiating pane's context with per-workspace output,
status back to the pane, and an agent-callable CLI; controls relocated top-center,
draggable + collapsible.

## Who it's for / the pain
rvance — wants Buildwright to stand alone on a new machine (CVR works without docai) and
the recorder's buttons to stop overlapping the websites being recorded.

## Constraints
- Self-contained: own package.json + pinned playwright/tsx + auto `playwright install chromium`.
- Augment, don't replace: keep the launcher UX; swap the hardcoded docai path for the plugin.
- Leave docai/tools/cvr as-is for now (reconcile later) — except S1's one-file UX fix.
- Plugin mechanism stays lightweight (manifest-based), CVR-first, reusable for future tools.
- Repo is PRIVATE; install via gh auth.
- On-page UI must never cover site nav (top or bottom) — top-center, draggable, collapsible, persisted.

## Definition of done
- Fresh clone of sealmindset/cvr installs + records with no docai present.
- Buildwright installs/updates/removes it as a plugin from GitHub.
- Launch uses initiating pane cwd; captures land per-workspace; status streams back; CLI works.
- Toolbar relocated + draggable/collapsible/persisted.

## Decisions (interview 2026-06-15)
Plugin = lightweight manifest mechanism (CVR first). Packaging = vendored deps + auto
browser install. Interlink = all four (pane-cwd, per-workspace output, status-to-pane,
agent CLI). Buttons = top-center, draggable + collapsible, persisted. Port scope =
generic engine + eFileMN drivers as /examples. Repo = create private + push. docai copy
= leave as-is. Sequence = button fix → repo port → plugin.

Stories: S1 button fix · S2 stand up repo · S3 prove self-contained · S4 plugin mechanism · S5 CVR integration + interlink.
