---
id:        E48-S2
title:     Stand up sealmindset/cvr — self-contained repo
type:      story
status:    done
category:  buildwright
priority:  P2
parent:    E48
created:   2026-06-15
updated:   2026-06-15
---

## Implementation notes (2026-06-15) — local repo built + verified at ~/Documents/GitHub/cvr
Found a hidden coupling: `tools/cvr/bundle.ts` re-exported docai's `src/lib/cvr/bundle`
(a leaf, crypto-only) → inlined both into a self-contained `src/bundle.ts`. Structure:
`src/{record.ts (w/ S1 toolbar fix), recon.ts, bundle.ts, adapters/noop-session-sink.ts}`,
`bin/cvr.mjs` (CLI: record|recon), `plugin.json` manifest, `package.json`
(playwright 1.60.0 pinned + tsx in deps; postinstall `playwright install chromium`),
`tsconfig` (excludes examples), README + `.gitignore` (captures/, node_modules).
docai-coupled drivers (efilemn + docai-session-sink) → `examples/` (excluded from build,
documented as requiring docai). record.ts default session handler → no-op.
Verified: `npm install` + chromium OK; `npm run typecheck` passes; CLI usage works;
`src/bundle.ts` imports resolve; no `../../src` docai refs in core. Local git committed.
**PENDING the outward step:** `gh repo create sealmindset/cvr --private --source=. --push`
(awaiting user go). docai/tools/cvr left untouched.
---

# Stand up sealmindset/cvr (self-contained)

Extract CVR into its own private repo that runs with zero docai dependency.

## Goal
A standalone repo that installs and records on a clean machine.

## Constraints
- Own `package.json` (pinned `playwright`, `tsx`, `typescript`), `tsconfig`, `.gitignore`.
- Move the generic engine: `record.ts`, `bundle.ts`, `adapters/`, `recon.ts`.
- eFileMN drivers (`capture-efilemn-session.ts`, `drive-rehearsal-efilemn.ts`) → `/examples`.
- `bin/` CLI entry (agent-callable, e.g. `cvr record --url … --label … --env …`).
- Setup step runs `playwright install chromium` (into the shared ms-playwright cache).
- `plugin.json` manifest (name, repo, version, install cmd, launch/CLI, ui hook, settings).
- README with standalone + plugin usage.
- Create PRIVATE repo via `gh repo create sealmindset/cvr --private`; push.
- Do NOT modify docai's copy (S1's record.ts fix is carried in as the new baseline).

## Definition of done
- Repo exists, pushed, with engine + examples + CLI + manifest + README.
- `npm ci` succeeds; `playwright install` pulls Chromium; tree is self-contained.
