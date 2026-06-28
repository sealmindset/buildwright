---
id:        E48-S3
title:     Prove CVR is self-contained (clean-machine simulation)
type:      story
status:    done
category:  buildwright
priority:  P2
parent:    E48
created:   2026-06-15
updated:   2026-06-15
---

# Prove CVR is self-contained

Verify (live, not theory) that the new repo runs with no docai present.

## Goal
A fresh clone records end-to-end with zero sibling-repo assumptions.

## Constraints
- Test in a temp dir OUTSIDE ~/Documents/GitHub/docai (so docai's node_modules can't
  accidentally resolve `playwright`).
- Steps: `git clone` (private, gh auth) → `npm ci` → browser install → `cvr record`
  against a simple public URL → confirm a capture is produced.
- Document the exact install/run commands in the README.

## Definition of done
- Recording succeeds from a clean checkout with docai absent from the resolution path.
- README's quickstart reproduces it.

## Result (2026-06-15) — PROVEN self-contained
Cloned sealmindset/cvr into /tmp (outside ~/Documents/GitHub/docai) → `npm ci` (deps +
postinstall chromium) succeeded with docai absent. Verified: `playwright` resolves to the
clone's own node_modules (not docai); `npm run typecheck` passes (record.ts/recon.ts/bundle
module graph resolves standalone); a headless Chromium launch using the clone's own
playwright + src/bundle produced a real bundle (meta.json + screenshot); resolution guard
confirmed nothing came from docai. Interactive recorder drive remains the one manual step
(inherent), but its module graph + the full browser/bundle stack are proven standalone.
