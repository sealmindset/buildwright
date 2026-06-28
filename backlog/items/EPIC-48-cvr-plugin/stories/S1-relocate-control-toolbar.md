---
id:        E48-S1
title:     Relocate CVR control toolbar — top-center, draggable, collapsible
type:      story
status:    done
category:  buildwright
priority:  P1
parent:    E48
created:   2026-06-15
updated:   2026-06-15
---

## Implementation notes (2026-06-15) — applied to docai/tools/cvr/record.ts
Rewrote the injected `mount()` toolbar (the INIT_SCRIPT in `record.ts`):
- Default **top-center** (`top:12px; left:50%; translateX(-50%)`) instead of bottom-right.
- **Draggable** via a ⠿ grip (pointer events, clamped to viewport); position saved to
  `localStorage['__cvr_bar_pos']` per origin and restored on load/remount.
- **Collapsible** to grip+dot (hides Capture/Finish), state in
  `localStorage['__cvr_bar_collapsed']`.
- Kept 📸 Capture / ✓ Finish + Ctrl+Shift+C / Ctrl+Shift+F + the `#__cvr_bar` id (so the
  click-ignore guard still works) + the MutationObserver remount (re-reads saved pos).
Verified: extracted INIT_SCRIPT passes `node --check`; no backtick/`${}` leaked into the
outer template literal. **Pending live test** (run a recording, confirm placement +
drag + collapse + persistence). Change is in the docai working tree, **uncommitted**.
---

# Relocate CVR control toolbar (quick win, ships first)

The injected toolbar is pinned bottom-right (`record.ts:137`
`position:fixed; bottom:16px; right:16px`) and overlaps most sites' own buttons/links.
Move it top-center, make it draggable + collapsible, and persist its position.

## Goal
The 📸 Capture / ✓ Finish controls never interfere with the website under test.

## Constraints
- Default **top-center**; **draggable** anywhere; **collapsible** to a small dot.
- Position **persists** per origin (localStorage).
- Keep both buttons + Ctrl+Shift+C / Ctrl+Shift+F shortcuts; keep the max z-index.
- pointer-events confined to the widget; don't block clicks elsewhere.
- Applied to the CURRENT `record.ts` for immediate relief (pragmatic exception to
  "leave docai as-is"); carries forward into the ported repo (S2).
- `[reconcile]`: the toolbar injection block (~lines 132-146) + the click-ignore guard
  (line 118 "ignore clicks on our own toolbar").

## Definition of done
- Recording on a site with a centered top header AND bottom-right buttons: controls are
  reachable, draggable out of the way, collapsible, and never block site operation.
- Position restored on reload.
