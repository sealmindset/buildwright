# Design: AI Scrum Master Intake (E50)

**Status:** in-progress · **Owner:** rvance + Claude · **Created:** 2026-06-18

---

## 1. Problem & context

Raw ideas, bug sightings, and feature notes arrive as unstructured text throughout the
day — mid-session, in Slack, in conversation. The current add flow (`/backlog story`,
`/backlog epic`, etc.) requires a clarifying-Q interview that is intentionally
thorough but too heavy for fleeting captures. Ideas get lost. This design adds a
zero-friction intake path: paste or type anything, the AI does the placement work.

The feature has two doors:
- **Skill side** (this design): `/backlog capture` and `/backlog undo` subcommands in
  `SKILL.md`; the triage engine contract; schema extensions; BOARD rendering updates.
- **Buildwright side** (future/parallel): a native hotkey or menu item that pipes
  selected pane text to `/backlog capture`, surfacing the one-line confirmation in a
  HUD. The JSON contract below is the integration point both sides must honor.

---

## 2. Goals / Non-goals

**Goals:**
- Zero-friction idea capture that is durably filed and immediately undoable.
- Correct placement (existing epic or new) without human triage.
- Schema extensions (`size`, `breakfix`, `spike`) that are backward-compatible.
- BOARD.md renders size chips and type markers compactly.

**Non-goals:**
- Replacing the deliberate `epic/story/task` add flow (that flow stays, with its
  clarifying questions).
- Auto-closing duplicates (the engine surfaces them; a human decides).
- Multi-level undo (one capture = one undo target).
- Buildwright native UI (that is a future door; this design covers the skill only).

---

## 3. Design principles

- **Tame inherent complexity, surface it.** The triage engine's reasoning is written
  into the Provenance block of every filed card — auditable, not a black box.
- **Augment, don't replace.** The deliberate add flow and its clarifying questions are
  unchanged. Capture is a fast-lane complement.
- **Human-gated where it matters; provenance everywhere.** The only gate is `undo`.
  Every auto-filed card carries the raw captured text and the triage reasoning verbatim.
- **Durability first.** Commit + push on every capture. If the machine dies, nothing is
  lost.
- **Conservative confidence.** New-epic creation is preferred over a weak fit.
  Threshold: confidence < 0.6 → mode "new". No silent mis-filing.

---

## 4. Schema extensions (backward-compatible)

### 4a. `size` field

```yaml
size: XS | S | M | L | XL   # optional; absent renders as "—"
```

Guidance by type:
| type      | typical size |
|-----------|-------------|
| epic      | L · XL      |
| story     | XS · S · M  |
| task      | XS · S      |
| breakfix  | XS · S      |
| spike     | S · M (timeboxed) |

Every existing item without `size` remains fully valid. The field is optional
throughout; BOARD.md renders "—" when absent.

### 4b. `type` extension

Extended from `epic | story | task` to:

```
type: epic | story | task | breakfix | spike
```

- **`breakfix`** — a defect or error report. Lives under an existing epic (the epic
  owning the broken surface). Uses story id scheme (`<EPIC>-S{n}`). Signals urgency;
  may be prioritized above ready stories.
- **`spike`** — a timeboxed investigation producing knowledge, not shippable code.
  Lives under an epic or standalone (rare). Output = a written finding / ADR / answer
  to an open question. Must have an explicit timebox in its body.

All existing items (`type: epic | story | task`) remain valid with no migration needed.

---

## 5. Architecture

```
/backlog capture <raw text>
        │
        ▼
  Board snapshot          ← read all epic.md files (id · title · category · status · first summary line)
        │
        ▼
  Triage engine           ← headless `claude -p`, read-only tools (Read, Glob, Grep), cwd = backlog dir
  (JSON contract below)
        │
        ▼
  Auto-apply result       ← write item file(s); create epic dir if mode="new"
        │
        ▼
  regen-board → sync      ← commit + push (durability)
        │
        ▼
  Slack notify            ← if webhook present (silent no-op if absent)
        │
        ▼
  One-line summary        ← "✓ Filed E49-S3 (breakfix, S) under Template Maker — /backlog undo to revert"
```

The triage engine is invoked via `claude -p` (or equivalent headless call) with:
- read-only tools only: `Read`, `Glob`, `Grep`
- working directory = `~/.claude/backlog`
- a structured prompt containing the board snapshot + raw text + today's date

---

## 6. THE CANONICAL CONTRACT

> **This section is the integration contract.** Both the skill side and any future
> Buildwright integration must implement exactly this JSON shape.

### Triage engine invocation

**Mode:** headless `claude -p` with read-only tools (`Read`, `Glob`, `Grep`), cwd = the backlog dir.

**Input given to the model:**

```
CURRENT BOARD snapshot: every epic  id · title · [category] · status  (+ short summary when cheap).
The raw captured text.
Today's date.
```

**Output — strict JSON only, no prose, no fences:**

```json
{
  "type": "epic|story|task|breakfix|spike",
  "size": "XS|S|M|L|XL",
  "title": "short imperative title",
  "category": "best-fit category string",
  "priority": "P1|P2|P3",
  "placement": { "mode": "existing|new", "epic": "E49", "confidence": 0.82, "why": "one line" },
  "new_epic": { "slug": "kebab-slug", "title": "Title Case", "category": "..." },
  "acceptance": ["testable criterion", "..."],
  "dedup": { "duplicate_of": "E49-S2", "confidence": 0.4 },
  "open_questions": ["..."]
}
```

**Rules:**

- `placement.mode == "existing"` → file as a child of `epic` with next id `<EPIC>-S{n}`.
- `placement.mode == "new"` → emit `new_epic`; create the epic dir + `epic.md`, then
  file the item under it (unless the captured thing is itself epic-scale, in which case
  the new epic IS the item; no separate story is filed).
- **New-epic authority:** if no existing epic fits with confidence ≥ 0.6, choose
  mode "new". Autonomous new-epic creation is desired — do not force a weak fit.
- `dedup` is advisory only — never auto-close a possible duplicate; surface it in the
  provenance block and open_questions of the filed card.
- Be conservative on sizing; timebox spikes.
- `new_epic` is required when `placement.mode == "new"`; omit when `mode == "existing"`.
- `dedup` is optional; omit entirely if no near-duplicate is found.
- `open_questions` is optional; omit if none.

### Provenance block

Appended to every auto-filed card body (after the Understanding template):

```markdown
## Captured
> <raw captured text, verbatim>
_via /backlog capture · <YYYY-MM-DD>_

## Scrum Master triage
- type: <t> · size: <s> · placement: <epic> (confidence <c>)
- reasoning: <one line from placement.why>
```

---

## 7. `/backlog capture` flow (detailed)

1. **Build board snapshot.** For every `items/*/epic.md`, read frontmatter + first
   meaningful body line. Assemble: `E49 · Template Maker · [Template Maker] · backlog — …`.
2. **Invoke triage engine.** Pass snapshot + raw text + today's date. Wait for strict
   JSON response.
3. **Parse + validate.** Confirm required fields (`type`, `size`, `title`, `placement`)
   are present. If the engine returns malformed output, surface the error and abort
   (do not write a broken card).
4. **Auto-apply (no approval gate — intentional).** Determine target path:
   - `mode == "existing"`: `items/<EPIC-dir>/stories/<next-id>-<slug>.md`
   - `mode == "new"`: create `items/EPIC-NN-<slug>/` (next NN by scanning existing
     dirs), write `epic.md` with appropriate frontmatter, then write the item as
     `epic.md` if epic-scale, or as a story under it.
5. **Fill card body.** Write the Understanding template + Provenance block.
6. **`regen-board`** — rebuild BOARD.md.
7. **`sync`** — `git -C ~/.claude/backlog add -A && git commit -m "capture: <title>" && git push`.
8. **Slack notify** — `bin/slack-notify.sh raw ":inbox_tray: Captured <id> — <title> · <category> · <priority>"`. Silent no-op if webhook absent.
9. **Print one-line summary:**
   `✓ Filed E49-S3 (breakfix, S) under Template Maker — /backlog undo to revert`

---

## 8. `/backlog undo` flow

1. `git -C ~/.claude/backlog revert --no-edit HEAD` — creates a new revert commit
   (safe; never rewrites history).
2. **`regen-board`** — rebuild BOARD.md from reverted state.
3. **`sync`** — commit + push.
4. Print: `✓ Reverted last capture. Board synced.`

**Constraints:**
- Undo only targets the most recent `capture` commit. Running undo twice reverts the
  revert (standard git behavior), not the capture before last.
- Undo is always safe — it uses `git revert`, not `git reset --hard`.
- If the last commit was not a capture (e.g. a manual `sync`), undo will revert that
  commit. Document this limitation clearly.

---

## 9. BOARD.md rendering (updated `regen-board`)

Each item line format (unchanged spine, new chips):

```
- **E50** · AI Scrum Master Intake  _[Buildwright] P2_ `[L]`
    - E50-S1 · Some story  _(status)_ `[S]`
    - E50-S2 · ⚡ breakfix title  _(status)_ `[XS]`
    - E50-S3 · 🔬 spike title  _(status)_ `[S]`
```

Rules:
- **Size chip** `[XS]` / `[S]` / `[M]` / `[L]` / `[XL]` appended after the status
  parens. When `size` is absent, omit the chip entirely (no "—" in the BOARD line;
  "—" only in tabular views).
- **breakfix marker** `⚡` prepended to the title.
- **spike marker** `🔬` prepended to the title.
- Keep lines compact — one line per item, same as today.

---

## 10. Provenance & audit

- Every auto-filed card carries the raw captured text verbatim in the Provenance block.
- The triage engine's confidence and one-line reasoning are stored on the card.
- The git commit message for a capture is `capture: <title>` — easily identifiable in
  `git log`.
- `git revert` (undo) leaves a clear trail in git history.

---

## 11. Phasing → stories

Stories to be filed under E50 when ready to implement:

- **E50-S1** · Extend SKILL.md schema (`size`, `breakfix`, `spike`) + BOARD rendering
- **E50-S2** · Implement `/backlog capture` (triage engine invocation + auto-apply)
- **E50-S3** · Implement `/backlog undo`
- **E50-S4** · Integration test: capture a real item end-to-end, verify board + git log

---

## 12. `[reconcile]`-with-codebase markers

- `[reconcile]` Verify that `claude -p` (headless) is the right invocation for the
  triage engine on the target machine (vs. SDK call). Check availability and auth.
- `[reconcile]` Confirm `bin/slack-notify.sh` signature for a `raw` mrkdwn call
  (matches existing usage in `start`/`done`).
- `[reconcile]` Buildwright side must match the JSON contract in §6 exactly — no extra
  wrapper, no prose, no fences. Any schema evolution must be versioned.

---

## 13. Open questions

- Should the triage engine be given the full epic body (not just first line) for better
  placement? Pro: accuracy. Con: token cost. Current decision: first meaningful line
  only; revisit if placements are consistently wrong.
- What happens if two concurrent captures race? Each gets its own commit; git history is
  linear; board regen is idempotent. No locking needed at current scale.
- Should `capture` support `--epic E49` to force placement without triage? (Punted;
  add later if the engine's placements are frustrating.)

---

## Risks

- **Engine hallucination:** the triage engine may invent epic IDs. Mitigation: validate
  `placement.epic` against the actual directory listing before writing; abort if unknown.
- **Git history pollution:** many captures in a session create many commits. Acceptable
  — durability is the point; squash is always available later.
- **Token cost of board snapshot:** 49 epics × ~50 chars each ≈ 2.5K tokens per capture.
  Acceptable at current board size; cap at first 80 epics if it grows.
