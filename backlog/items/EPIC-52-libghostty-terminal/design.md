# Helm — design spec (agent-first orchestrator on libghostty)

> Greenfield. No code ported from Buildwright. Captures the 2026-06-19 interview.

## 1. Problem & context
Buildwright works but is buggy in too many places; the root is the SwiftTerm render layer, and a
solo dev can't out-engineer Ghostty there. Rather than retrofit, build **Helm** from scratch on
libghostty: a native macOS agent-orchestrator for running a fleet of Claude Code agents in parallel,
each isolated in a git worktree, shipped through GitHub — driven by the existing Scrum Master backlog.

## 2. The four pillars (product identity)
1. **Worktree isolation** — every agent gets its own `<repo>/.worktrees/<branch>`; no conflicts.
2. **Fully native** — libghostty engine, no Electron/web; performance you feel per keystroke.
3. **GitHub-native** — open PRs, watch CI, resolve conflicts, merge — without leaving Helm.
4. **50+ agents** — dozens of agents at once, each isolated, all under one roof.
**Helm's edge over off-the-shelf (Supacode):** it's yours + free, customizable, plugin-friendly
(CVR), backlog/Scrum-Master-driven, and adds tmux persistence + remote/iPad.

## 3. The spine (the closed loop everything serves)
`board item ▶ → fresh worktree + branch → agent runs under the standing ship preamble → 100% green
→ PR → harm-gate → merge → worktree pruned → item marked done`. The board picks the work; the
orchestrator runs and ships it. Free-prompt agents are a secondary entry into the same machinery.

## 4. Architecture
- **Stack:** Swift + SwiftPM, native macOS 26 (Tahoe), Apple Silicon. Design: polished-product.
- **Terminal:** `Lakr233/libghostty-spm` (pin 1.2.6), HOST_MANAGED byte-feed (`ghostty_surface_write_buffer`
  in; `receive_buffer`/`receive_resize` callbacks out; no PTY owned by the engine).
- **Session/persistence:** tmux **control mode** (`tmux -C`) — one session per agent; survives
  quit/crash/reboot; remote/iPad attaches as a normal client. tmux output `%output` → byte-feed.
- **Agent = Claude Code (deep):** status via Claude Code hooks, `claude -p`/`--resume`, cost tracking,
  the Scrum Master, and the standing ship gates all wired in. Abstraction left clean for later pluggability.
- **Multi-repo registry:** Helm knows a set of repos (docai/splashdown/helm/…); a board item's project
  resolves to its repo; the agent's worktree is created there. Agents fan out across repos concurrently.
- **GitHub:** gh CLI for actions now (PR create / checks / merge — uses existing auth, CI = Actions);
  REST/GraphQL layered later for live CI/conflict detail.

## 5. Scale design — how 50+ is safe (the "never freeze" guarantee)
- **Surfaces are pooled.** Only focused/visible panes get a live libghostty surface (~6); the other
  ~45 agents are **headless tmux sessions** doing real work with no render. Focus a tile → a surface
  attaches and replays instantly; blur → it detaches.
- Proven safe by E52-S1: 30 live surfaces @ ~11% CPU, ~1 ms main-thread stall, ~7 MB/surface; freeze
  doesn't reproduce because rendering is on-demand and VT parsing is off the main thread.
- Day-1 mitigations: off-screen/occluded surface suspension (`setSurfaceVisible(false)`), byte-feed
  backpressure for runaway-output panes, aggressive agent **reaping** (the BW1 freeze lesson), one
  shared terminal controller per window.
- **Home screen = Agent Grid:** a live status wall of all agents (tiles: branch · state · CI · diff);
  click a tile to focus its terminal/diff/PR. Attention surfacing layered on (which of the 50 need you).

## 6. Design language
Polished-product (Supacode-grade): native, panels with clear hierarchy, status color, keyboard-first,
fast and intentional — approachable but pro. Real mockups via the design skill before M1 UI.

## 7. Milestones (sequenced; each shippable + daily-drivable — this is how we get "everything" without bloat)
- **M0 — Foundation.** Helm app skeleton (SwiftPM + libghostty), one libghostty pane backed by tmux
  control-mode with persistence, pooled-surface attach/detach core. *Daily-drivable as a terminal you trust.*
- **M1 — Agents + worktree isolation.** Claude agent abstraction (hooks/status), spawn → worktree +
  branch + tmux session + pane; Agent Grid; multi-repo registry; reaping/lifecycle. *Run many isolated agents.*
- **M2 — Board-driven loop.** Backlog sidebar + Start (runs items under the ship preamble), ⌘⇧N capture,
  attention/status surfacing. *The Scrum Master drives the fleet.*
- **M3 — GitHub-native ship.** green → PR (gh) → CI watch → harm-gate → merge → worktree cleanup →
  mark item done; in-app PR/CI/conflict/merge. *The full closed loop.*
- **M4 — Parity + extras.** remote/iPad, browser panes, CVR + plugin system, dashboards (Finish Line /
  Backlog Map / Mission Control), re-entry niceties. *Helm is the full daily driver.*

## 8. What we deliberately do NOT do
- No code ported from Buildwright (concepts only).
- No third-party harness dependency (Supacode) — independence is the point.
- No always-live 50 surfaces (freeze path); no big-bang "everything at once" release.

## 9. Risks
- libghostty fork pinned at 1.2.6 (single maintainer) — pin exactly; revalidate render model on bumps.
- 50+ scale is the hardest pillar — reaping + suspension + pooling must be excellent from M1, not bolted on.
- GitHub-native conflict/merge UI (M3) is deep — gh-first keeps M3 tractable; API detail later.
- Scope is large — milestones gate it; each must be rock-solid before the next.

## 10. [reconcile] markers
- [reconcile] Confirm tmux control-mode events Helm needs for status/attention against real tmux.
- [reconcile] Confirm Claude Code hook payloads still drive per-agent state at fleet scale.
- [reconcile] Pin/validate libghostty-spm API surface (write_buffer, callbacks, occlusion) at build time.
