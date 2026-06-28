# Buildwright Resilience — Self-Healing, Self-Governing Cockpit

**Status:** design (for review) · **Epic:** E46 · **Category:** buildwright · **Priority:** P1
**Date:** 2026-06-15 · derived from the 2026-06-14 desktop-freeze investigation.

---

## 1. Problem & context
Buildwright runs every terminal and every Claude agent under one roof (one app + one
tmux server, iTerm2 control-mode model). That single roof is also a single point of
failure: a memory leak, resource mismanagement, an output storm, or a main-thread
hang can self-DoS the whole machine — on 2026-06-14 it (most likely) wedged
WindowServer hard enough to freeze the desktop of a 128GB M4 Max, recoverable only
by force-quitting. A standing army of 26 ungoverned agents (10.7GB) had also
accumulated invisibly because nothing supervises agents while the GUI is closed.

For Buildwright to be a primary daily surface, resilience must be **designed in**:
self-governing (resource budgets + backpressure), self-preserving (shed load before
the cliff), and self-healing (recover from tmux death, main-thread hangs, and drift)
— and **provably so** (a chaos suite that gates releases).

**Architecture today (ground truth from memory; [reconcile] vs code before building):**
iTerm2 model — `tmux -C` headless; panes are native SwiftTerm buffers fed by `%output`;
the control client (in the GUI) is the sole sizing/render authority
(`window-size manual`, `aggressive-resize off`, `refresh-client -C`). tmux already
survives GUI death — **the fragile half is the GUI/render path**, which is exactly
where the freeze risk lives. That reframes the work: don't make tmux survivable
(it is); make the **GUI hang/leak/storm harmless and self-recovering**, and put a
**governor between agents and the renderer**.

## 2. Goals / Non-goals
**Goals**
- No agent/output/leak condition can freeze the desktop or self-DoS the machine.
- Resources are governed continuously, **even with the GUI closed**.
- The GUI can hang/crash/relaunch with **zero impact** on running agents.
- Faults (tmux death, main-thread hang, pane drift) **self-heal** without user action.
- Resilience is **proven** by an automated chaos suite that gates releases.

**Non-goals (scope stays "cockpit, bulletproofed")**
- No editor / file-tree / LSP / debugger. "Main AI IDE" = trust, not feature-parity.
- Not removing tmux (persistence + iPad/Blink remain essential).
- Not changing the agent UX except where resilience requires it.

## 3. Design principles (specialized)
- **The backend is the source of truth; the GUI is disposable.** Anything the user
  must not lose lives in the daemon/tmux, never only in GUI state.
- **Govern at the choke point.** All `%output` and all agent lifecycle flow through
  one governed path — backpressure and budgets are enforced there, not sprinkled.
- **Two tiers of self-defense.** Normal life = *warn-only* (user decides, per E44).
  Cliff = *automatic* shed-load (machine-preserving). Never blur the two.
- **Degrade pixels before processes.** Under pressure, sacrifice rendering first;
  pause idle work next; kill only the clearly-dead, last.
- **Make the hidden visible.** Continuous budget/health telemetry; alert *before* the
  cliff, not a post-mortem.
- **Prove it or it's not real.** Every resilience property has a chaos test that
  induces the failure and asserts recovery.

## 4. Architecture — `buildwrightd` supervisor + thin GUI client
```
  launchd (login agent)
     └── buildwrightd  ── owns ──►  per-workspace tmux servers (tmux -C, headless)
            │  · resource governor (two-tier)      └── Claude agents (panes)
            │  · per-pane flow control / backpressure
            │  · self-heal: tmux-death rebind, drift anneal
            │  · health/metrics publisher
            │  · agent lifecycle (spawn/reap/pause)
            ▼  (local socket / XPC: forwarded %output, input, resize, health)
   Buildwright.app (SwiftUI)  — thin renderer
            · subscribes to forwarded output → SwiftTerm views (off main thread)
            · main-thread watchdog · health panel · attach/reconnect + rehydrate
```
- **Transport:** local Unix-domain socket or XPC. Daemon multiplexes: runs the control
  clients, parses/governs `%output`, forwards a normalized stream to attached GUIs;
  GUI sends keystrokes + resize. `[reconcile]` exact IPC choice against the codebase.
- **Reconnect:** on GUI (re)launch it attaches and the daemon **rehydrates** each
  visible pane via `capture-pane` replay; off-screen panes hydrate lazily on focus
  (subsumes E44-S3). Live views **rebind** — no dead panes after a relaunch.
- **Lifecycle:** daemon is a **launchd login agent, always on** — governance never
  stops when the app closes (the gap that hid the 26-agent army). Stable code-signed
  so TCC/launchd trust persists across rebuilds (reuse the existing signing identity).
- **Topology:** **one tmux server per workspace** under the daemon. A garbled/wedged
  server affects only its workspace and is recycled independently.

## 5. Resource governor (two-tier, RAM-derived)
- **Signals:** native macOS memory-pressure dispatch source
  (`DISPATCH_SOURCE_TYPE_MEMORYPRESSURE`: normal/warn/critical) **plus** Buildwright's
  own footprint (sum of agent RSS + render memory via `proc_pid_rusage`/libproc).
- **Budgets auto-derived from physical RAM** (overridable in Settings): e.g. warn at a
  configurable % of total / agent-RSS soft cap; cliff at memory-pressure *critical* or
  a hard footprint cap. Tuned to the machine, not hard-coded. `[reconcile]` exact %.
- **Tier 1 — Amber / warn-only (normal life, = E44-S2):** health panel turns amber,
  pre-cliff alert, one-click "reap stale". **Never auto-kills.**
- **Tier 2 — Red / cliff (emergency circuit-breaker):** auto shed-load via the
  degradation ladder (§6). Logged + surfaced; reversible steps preferred.

## 6. Degradation ladder ("pixels before processes")
On Tier-2 pressure, in order, stopping as soon as pressure clears:
1. **Shed rendering** — stop drawing off-screen/background panes; drop excess
   scrollback; coalesce/throttle draws.
2. **Throttle output** — tighten per-pane flow-control budgets (more aggressive pause).
3. **Pause idle agents** — suspend idle agents to reclaim memory (reversible).
4. **Reap clearly-dead** — last resort: reap exited/zombie/own-verified-stale agents
   (transcripts persist → `claude --resume`; confirm anything ambiguous).

## 7. Per-pane flow control (backpressure)
The output-storm fix. Enable control-mode flow control; give each pane a **render/byte
budget**. A pane whose unrendered backlog exceeds budget is **paused** (`%pause`/
`refresh-client` flow-control API `[reconcile]`) and **resumed** when the renderer
drains it. A runaway agent throttles itself instead of drowning the UI.

## 8. Self-healing behaviors (all four, v1)
- **Auto-rebind after tmux death:** daemon detects control-client EOF / server gone →
  respawns the server, re-attaches, re-maps windows→views, `capture-pane` replay to
  rehydrate. (Closes a known v1 gap.)
- **Main-thread hang watchdog:** a watchdog thread pings main every N ms; K misses ⇒
  hung → capture a self-`sample` (freeze-probe style), show a "recovering…" state, and
  (daemon model) make a GUI restart safe & agent-preserving.
- **Render off main thread:** ingest/parse `%output` and update the terminal model on a
  background queue; commit draws coalesced at display refresh. **A storm can no longer
  starve the UI/WindowServer** — this is the root-cause fix for 2026-06-14.
- **Auto-resync drifted panes:** generalize the existing size reconciler into a periodic
  "anneal to tmux truth" — detect any desync (size, garble, stale) and self-correct.

## 9. Observability — health panel + pre-cliff alerts
Daemon publishes continuous metrics (total + per-agent memory, CPU, agent count,
render lag/backpressure state, server health). GUI shows a **live health panel** with
budget gauges and **warns before the cliff**, each warning carrying a one-click
remediation (reap stale, pause idle, recycle a workspace server). The reactive
`/mac-doctor` freeze-probe remains the external forensic tool (complementary).

## 10. Trust — chaos suite as a release gate
A failure-induction + recovery-assertion harness, run in CI; **no release ships unless
it's green** (wire into `bundle.sh`/CI). Failure modes:
- Spawn 50 agents fast ⇒ governor warns, then caps/sheds; no freeze.
- Flood `%output` (huge/continuous) ⇒ flow control pauses; main-thread watchdog never
  trips past threshold; draw rate bounded.
- `kill -9` the tmux server ⇒ auto-rebind; views recover; agents reattach.
- Wedge main thread (debug-only inject) ⇒ watchdog detects + self-samples.
- Memory balloon ⇒ pressure→critical ⇒ ladder runs; no jetsam of other apps.
`[reconcile]`: swift-testing module is unavailable on the local default toolchain —
the harness must run via a plain `swift run` target or XCTest, not swift-testing.

## 11. Phasing → stories (minimum lovable loop = Phase 1, the safety net)
**Phase 1 — Safety net, IN-PROCESS (ship in days; protection first):**
- S1 Render off main thread + coalesced draws — the storm root-cause fix.
- S2 Per-pane flow control / backpressure (render budget; pause/continue).
- S3 Resource governor core (memory-pressure source + footprint sampling; amber warn,
      folds in E44-S2 census).
- S4 Emergency circuit-breaker + degradation ladder.
- S5 Reap-on-pane-close (= E44-S1) + agent census/health surface (= E44-S2).
- S6 Main-thread hang watchdog (detect + self-sample + "recovering" UI).

**Phase 2 — Daemon extraction:**
- S7 `buildwrightd` skeleton + launchd login agent + signing + lifecycle.
- S8 Move tmux control client(s) into the daemon; GUI attaches over socket; forward
      output/input/resize.
- S9 Per-workspace tmux servers under the daemon (+ recycle a bad one).
- S10 GUI reconnect + `capture-pane` rehydration + live-view rebind (subsumes E44-S3).
- S11 Move governor + flow control + circuit-breaker into the daemon (always-on).

**Phase 3 — Self-heal + trust:**
- S12 Auto-rebind after tmux server death.
- S13 Auto-resync/anneal drifted panes (generalize the reconciler).
- S14 Live health panel + pre-cliff alerts + one-click remediations.
- S15 Chaos/load harness (all modes) + wire as a release gate.

**Remote / AFK access (spans phases):**
- S16 Remote/AFK v1 — harden + document lean SSH+tmux per-workspace attach (near-term).
- S17 Remote/AFK v2 — buildwrightd-brokered remote client + aggregate pane-of-glass.

## 12. `[reconcile]`-with-codebase markers
Confirm against real code before building: current `TmuxControlClient` ownership +
where it lives; the `%output`→SwiftTerm feed path + which thread; the size reconciler
(v0.30–0.33) to extend, not duplicate; exact tmux control-mode flow-control API
(`%pause`/`refresh-client`); IPC choice (socket vs XPC); signing/launchd packaging
(reuse `make-signing-cert.sh`); test runner constraints (no swift-testing locally).

## 13. Relationship to other items
- **Absorbs E44** (agent lifecycle): E44-S1→E46-S5, E44-S2→E46-S3/S5, E44-S3→E46-S10.
  Recommend folding E44 into E46 (or closing E44 as superseded).
- **/mac-doctor skill** = the external operator/forensics tool; E46's health panel =
  the in-app proactive surface. Share the reaper's owner-verify logic.

## 14. Isolation model — three layers + two shared substrates
The stack is layered: **Buildwright (GUI) ⇄ iTerm2-model control plane (tmux, one
server per workspace) ⇄ Terminal panes (agents)**. "Isolated workspace" means
different things at different layers — only some come from the per-workspace server.

**Three isolations you get:**
1. **Stability / blast-radius** (from per-workspace tmux server, this epic): a wedged,
   garbled, or storming server in Workspace A cannot scramble or freeze Workspace B;
   recycle one without touching the other. This is about crashes/storms, not knowledge.
2. **Knowledge / context** (intrinsic to Claude Code, already true): each `claude` is
   its own conversation, context window, and on-disk transcript. A Claude in one
   workspace has **zero awareness** of another. The shared subscription is just
   auth/account — **no shared memory between sessions**. Two sessions on one
   subscription are as mutually blind as two on separate accounts.
3. **Code / filesystem** (from distinct cwd/worktree, **NOT** tmux): isolation of what
   code each agent sees comes from each workspace pointing at a different directory/repo
   (+ worktrees). tmux does **not** sandbox the filesystem — two workspaces aimed at the
   same folder would collide regardless of separate servers. Safety rule stands: two
   agents never share a working tree.

**Two shared substrates (where A *can* influence B):**
- **Subscription quota / rate-limits:** all workspaces spend from one account; heavy use
  in A can throttle/rate-limit B. *Throughput* influence, not *information*.
- **Host CPU/RAM:** all servers share the one M4 Max; this is exactly what the E46
  governor manages so resource pressure in A can't freeze B or the desktop.
- (Shared global `~/.claude` config/memory/skills/MCP = shared *background house-rules*,
  not shared conversation; per-project CLAUDE.md/memory are **not** shared — they key off
  the directory.)

**Remote / AFK access:** tmux is the persistence backbone, so a workspace's terminals
live independently of the GUI and the whole session is reachable by **attaching to that
workspace's tmux server** — e.g. Blink/SSH → attach surfaces *every* pane in that
workspace, however many. One server = one workspace = all its terminals; reaching a
*different* workspace = attaching to a different server. Caveats: (a) iPad/Blink remote
is **planned, not yet a polished feature** — the SSH+tmux path exists architecturally;
(b) a plain remote client attaching to a `window-size manual` control-mode session
inherits the sole-sizing-authority tension; (c) "AFK" via the Slack bridge + TCC
pre-auth (E08 / v0.28) is a **separate** capability — *act* on the machine while away —
distinct from *remote terminal access*.

## Open questions / risks
- **Remote-attach behavior for AFK** — DECIDED 2026-06-15: phased. v1 = lean SSH+tmux
  per-workspace attach (E46-S16); v2 = `buildwrightd`-brokered remote client, per-
  workspace then aggregate pane-of-glass (E46-S17). Remaining sub-question: the exact
  v1 sizing policy under window-size-manual (co-equal vs read-only vs GUI-detach).
- Exact budget percentages + whether to expose a "performance vs. headroom" preset.
- IPC: XPC (native, entitlement-friendly) vs Unix socket (simpler, portable to a CLI).
- Pausing agents: tmux-level vs `SIGSTOP` — `[reconcile]` what Claude tolerates on resume.
- Daemon is a meaningful new surface (security/update/signing). Mitigated by reusing the
  stable signing identity and keeping the protocol local-only.
- Phase-2 control-client move is the riskiest refactor; Phase-1 logic is written to
  migrate cleanly into it.
