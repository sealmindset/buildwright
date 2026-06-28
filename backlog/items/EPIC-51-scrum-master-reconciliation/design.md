# E51 Design — AI Scrum Master Reconciliation Contract

> **Status:** in-progress · **Author:** rvance + Claude · **Date:** 2026-06-18
> This is the authoritative contract for both the backlog skill (reader/writer) and any implementing side (e.g. Buildwright Swift) that must consume or produce the same JSON.

---

## 1. Problem & context

The backlog is a living document. As Claude Code sessions build features across docai, stories can sit `in-progress` or `ready` long after the code is actually shipped, or they can say `backlog` when the feature is already partially implemented. A solo developer running many concurrent sessions cannot manually audit every item against the real codebase.

Without grounding:
- "Done" items linger open → noise, inflated count, wasted triage.
- "Open" items get re-implemented → wasted effort.
- "dispatch" starts the wrong thing.

**Reconcile** closes this gap by running a code-grounded verification ladder per item and auto-applying high-confidence verdicts. **Dispatch** uses the clean board to start the next real unit of work autonomously.

---

## 2. Goals / Non-goals

**Goals:**
- Ground every open backlog item against docai source code, test suite, and live prod.
- Emit a structured verdict per item with confidence + evidence + gaps.
- Auto-apply reversible, high-confidence verdicts; flag the rest.
- Append auditable provenance to every reconciled card.
- Dispatch the next parallel-safe item autonomously after reconciling.

**Non-goals:**
- Writing to the target repo (docai) — read-only always.
- Running the full test suite on every reconcile (too heavy; presence + CI signal is acceptable for tests rung).
- Reconciling non-docai repos in v1 (configurable later).
- Bypassing the green-gate or harm-gate from the Standing prompt preamble.

---

## 3. Design principles

- **Code is ground truth.** Design docs and memory can be stale. `grep`/`read` the actual source before asserting anything.
- **Evidence-first verdicts.** Every verdict is backed by `file:line` references, test names, and live signals — never by inference alone.
- **Conservative confidence.** BUILT requires all three rungs (code ✓ + tests ✓ + live ✓). Anything less is `partial`, `not-built`, or `unknown`. A false "done" is worse than a false "open."
- **Reversible-only auto-apply.** Auto-apply threshold 0.8 + must be reversible + must be non-harmful. Everything else goes to the human flag list.
- **Provenance everywhere.** Every auto-applied verdict leaves a dated reconciliation block on the card.
- **Dispatch is armed but controllable.** On by default (per rvance's standing choice); announces what it dispatches; easily disabled with a flag.

---

## 4. Architecture

```
/backlog reconcile [<id> | all]
        │
        ▼
  Build item list (open items from BOARD, or single id)
        │
        ▼
  For each item:
  ┌─────────────────────────────────────────────────────────┐
  │  Verification Ladder (headless claude -p subagent)      │
  │  tools: Read, Glob, Grep, Bash  cwd: ~/Documents/GitHub/docai │
  │                                                         │
  │  Rung 1 — CODE                                          │
  │    grep/read: agents (src/lib/agents/), routes          │
  │    (src/app/api/, src/app/(authenticated)/), models     │
  │    (prisma/migrations/), components (src/components/)   │
  │    Collect file:line evidence                           │
  │                                                         │
  │  Rung 2 — TESTS                                         │
  │    locate: vitest (tests/unit/, tests/integration/),    │
  │    playwright (tests/e2e/), test-smoke.mjs              │
  │    report: green/red if runnable; else presence + CI    │
  │                                                         │
  │  Rung 3 — LIVE                                          │
  │    HTTP probe / UI scrub / data check against           │
  │    https://docai.vlf.legal; mark unknown if not         │
  │    reachable or requires auth that can't be probed      │
  └─────────────────────────────────────────────────────────┘
        │
        ▼
  Engine returns strict JSON (see §6)
        │
        ▼
  Verdict engine:
    confidence ≥ 0.8 AND reversible AND non-harmful?
      YES → auto-apply: mutate board + append provenance block
      NO  → flag for human (print flag list at end)
        │
        ▼
  regen-board → sync (commit "reconcile: <summary>") → push
  Slack notify → print compact report
```

---

## 5. Complexity ladder

| Tier | What it does | When used |
|------|-------------|-----------|
| **0 — Fast** | Code rung only (grep for agent/route/model names). Sub-second per item. | `reconcile --fast` flag or when item has no test coverage and no live signal expected. |
| **1 — Standard** | All three rungs. Runs the full ladder. Default. | `reconcile` / `reconcile all` |
| **2 — Deep** | Standard + runs vitest headlessly + playwright smoke. Heavier, may be slow. | `reconcile --deep <id>` for a specific item before closing it. |

---

## 6. The Reconciliation JSON Contract

The ladder subagent returns **strict JSON only — no prose, no markdown fences**. One object per item, as a JSON array when batch:

```json
{
  "item": "E20",
  "verdict": "built|partial|not-built|unknown",
  "confidence": 0.85,
  "evidence": {
    "code": [
      "src/lib/agents/mercury.ts:1 — MercuryAgent class",
      "src/app/api/agents/mercury/route.ts:14 — POST handler"
    ],
    "tests": [
      "tests/unit/agents/mercury.test.ts — 12 passing (vitest)"
    ],
    "live": [
      "GET https://docai.vlf.legal/api/agents/mercury → 200",
      "UI: /agents/mercury page loads, extraction UI present"
    ]
  },
  "gaps": [
    "multi-page PDFs return 500 in live",
    "no e2e test for approval queue flow"
  ],
  "proposed_action": {
    "kind": "mark_done|close_dup|restatus|split|none",
    "to_status": "done",
    "dup_of": "",
    "why": "code complete, tests green, live working except edge case (gap logged)"
  }
}
```

### Verdict definitions

| Verdict | Criteria |
|---------|---------|
| `built` | Code ✓ AND tests ✓ AND live ✓ — all three rungs pass. |
| `partial` | Code ✓ but tests missing/red OR live failing/unknown. Item is partially done. |
| `not-built` | No meaningful code found for the described feature. |
| `unknown` | Insufficient signal to judge (e.g. item too vague, or live unreachable and tests absent). |

### Action kinds

| Kind | What it does | Reversible? |
|------|-------------|-------------|
| `mark_done` | Set `status: done` on the item. | Yes — undo with `/backlog undo` |
| `close_dup` | Set `status: done`, add `dup_of:` field. | Yes |
| `restatus` | Change status to `to_status` (e.g. `partial` → `in-progress`). | Yes |
| `split` | Flag only — splitting requires human to define sub-items. Never auto-applied. | N/A — always flagged |
| `none` | No change. | N/A |

### Auto-apply rules

Auto-apply executes when **all three** hold:
1. `confidence ≥ 0.8`
2. `proposed_action.kind` is `mark_done`, `close_dup`, or `restatus` (never `split`)
3. The action is non-harmful (does not delete history, does not affect live prod, is reversible via git)

If any condition fails → append item to the **human flag list** printed at the end of the run.

---

## 7. Provenance block (appended to card on auto-apply)

Appended as a new section at the end of the item's `epic.md` or story file:

```markdown
## Reconciliation (2026-06-18)
- verdict: built · confidence: 0.85 · via: code+tests+live
- evidence: src/lib/agents/mercury.ts:1, tests/unit/agents/mercury.test.ts (12 passing), GET /api/agents/mercury 200
- action: mark_done — undo available (`/backlog undo`)
```

The `updated:` frontmatter field is also bumped to today's date.

---

## 8. Optional frontmatter key: `reconciled`

Items that have been through at least one reconcile run may carry:

```yaml
reconciled: 2026-06-18
```

This key is **optional and backward-compatible** — omitting it is valid. It is added automatically on first auto-apply. It is used by `dispatch` to prefer items that have never been reconciled (so unreviewed items don't linger forever).

---

## 9. Compact report format

Printed at the end of every `reconcile` run:

```
Reconcile run — 2026-06-18 — 12 items checked

  built:     3  (auto-applied mark_done: E12-S2, E20, E28-S1)
  partial:   2  (flagged: E34-S6 [gaps: multi-page PDFs], E45-S3 [gaps: no e2e test])
  not-built: 5  (no action)
  unknown:   2  (flagged: E17-S1 [vague description], E42 [live unreachable])

Auto-applied: 3 actions  |  Flagged for human: 4 items
Commit: reconcile: 3 done, 2 partial, 2 unknown (12 items)
```

---

## 10. `/backlog dispatch` — autonomous "do the next thing"

After reconciling (or independently), dispatch picks the next item to start.

### Selection algorithm

1. Filter items to `status: not-built OR partial` (per reconcile verdict; falls back to `status: ready OR backlog` if reconcile hasn't run).
2. Exclude items with:
   - Unfinished `dependsOn` items (any listed `dependsOn` id not in status `done`)
   - A `conflictsWith` item currently `in-progress`
   - File-level conflicts with any currently `in-progress` item (check `evidence.code` path overlap when available)
3. Sort by priority (P1 → P2 → P3), then by `reconciled: null` first (unreviewed items preferred), then by `updated:` ascending (oldest first).
4. Pick the top item.

### Dispatch execution

1. **Announce:** print `Dispatching E34-S6 — <title> [category] P1 · not-built · confidence 0.82`.
2. **Run `start <id>`** — which prepends the Standing prompt preamble (clarify-first, build → 100%-green gate → harm-gate, no self-merge on harmful changes). All gates are fully in force.
3. Log: append a dispatch provenance line to the item card:
   ```markdown
   ## Dispatch (2026-06-18)
   - auto-dispatched by /backlog dispatch after reconcile
   - verdict at dispatch: not-built · confidence: 0.82
   ```
4. `sync` (commit "dispatch: started E34-S6").

### Dispatch safety rules

- **One item at a time.** A single dispatch run starts at most one item.
- **Armed by default** (per rvance's standing choice). Disable for a single run with `--dry-run` (prints the selected item but does not start it). Disable globally by setting `dispatch_armed: false` in `~/.claude/backlog/config.yml` (not yet implemented; noted for future).
- **Announces before acting.** The human sees what will be dispatched and can interrupt (Ctrl-C) before the `start` runs.
- **Never bypasses green-gate or harm-gate.** The Standing prompt preamble is always prepended in full — dispatch is just a hands-free way to call `start`.
- **Fully logged and reversible.** The dispatch provenance block is on the card; the board commit is in git history; `/backlog undo` reverts the last board mutation.

### Combined flow: `reconcile --dispatch`

Running `/backlog reconcile all --dispatch` (or `/backlog reconcile --dispatch`) does both steps in sequence:

1. Run full reconcile on all open items.
2. Print the compact report.
3. Run dispatch (selecting from the freshly-updated board).

---

## 11. Verification ladder — docai grounding map

Where to look for each class of backlog item in the docai codebase:

| Feature class | Code locations | Test locations | Live check |
|--------------|---------------|---------------|------------|
| Agent feature | `src/lib/agents/<name>.ts` | `tests/unit/agents/<name>.test.ts` | `/api/agents/<name>` HTTP probe |
| API route | `src/app/api/<path>/route.ts` | `tests/integration/<path>.test.ts` | HTTP GET/POST probe |
| UI page/feature | `src/app/(authenticated)/<path>/` | `tests/e2e/<name>.spec.ts` | Playwright scrub or GET page |
| DB model/migration | `prisma/migrations/<timestamp>_<name>/` | vitest DB tests | Prisma studio / row query |
| Component | `src/components/<name>.tsx` | vitest component tests | Visual inspection via page |
| Smoke / E2E | `test-smoke.mjs`, `tests/e2e/` | (is the test) | `node test-smoke.mjs` output |

---

## 12. `[reconcile]`-with-codebase markers

Integration points that must be confirmed against live code before the Buildwright side implements:

- `[reconcile]` The headless `claude -p` subagent invocation syntax — confirm the exact CLI flags and tool-permission args available in the version deployed.
- `[reconcile]` Live-probe authentication: docai routes behind OIDC require a session or API key. Confirm whether unauthenticated probes to public routes (health, login redirect) are sufficient or whether a service token is needed.
- `[reconcile]` vitest runner path: confirm `npx vitest run --reporter=json` works headlessly in the docai checkout (check `vitest.config.ts` for any environment setup).
- `[reconcile]` Git commit hook in `~/.claude/backlog` — confirm `sync` uses the same Co-Authored-By trailer format as existing commits.

---

## 13. Open questions

- Should the live rung use a stored session cookie, a service API key, or limit itself to public/unauthenticated endpoints only?
- Is `confidence` a fixed heuristic (rung count / 3) or a model-assigned float? Define the floor logic explicitly before implementation.
- Multi-repo: when should reconcile target `~/Documents/GitHub/buildwright` instead of docai? Proposal: a per-item `repo:` frontmatter key (default `docai`).
- Should `dispatch` respect a `max_parallel` setting (e.g. don't dispatch if N items are already `in-progress`)? Default suggestion: N=2.

---

## Risks

| Risk | Mitigation |
|------|-----------|
| False "done" hides real work | BUILT requires all three rungs + confidence ≥ 0.8; anything less is partial/unknown |
| Auto-apply mutates wrong item | Validate item id against directory listing before writing; dry-run flag available |
| Live probe causes side effects | Only safe read probes (HTTP GET, no POST/PUT/DELETE); authenticated endpoints marked `unknown` if no safe probe exists |
| Dispatch starts a harmful/high-impact item | Standing prompt preamble always prepended; harm-gate is inside `start`, not dispatch |
| Skill regression | New commands are additive only; existing command behavior unchanged |
