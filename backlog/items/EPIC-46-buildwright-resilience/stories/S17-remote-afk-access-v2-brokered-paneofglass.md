---
id:        E46-S17
title:     Remote/AFK access v2 — buildwrightd-brokered client + aggregate pane-of-glass
type:      story
status:    ready
category:  buildwright
priority:  P2
parent:    E46
created:   2026-06-15
updated:   2026-06-15
---

# Remote/AFK access v2 — daemon-brokered remote client

The real "one pane of glass from my iPad." `buildwrightd` (E46 Phase 2) brokers an
authenticated remote client: a native-feeling remote surface that resolves the sizing
tension and, eventually, multiplexes across all per-workspace servers into one view.

## Goal — the outcome we want
A secure remote client (iPad/web) that connects through the daemon and gives a clean
remote experience — per-workspace first, then an **aggregate view across all
workspaces** at once.

## Who it's for / the pain
rvance — beyond raw SSH attach (v1, S16): a polished, secure, single remote surface to
supervise every workspace's agents while AFK, without per-server SSH gymnastics.

## Constraints — must-haves, limits, non-negotiables
- **Depends on buildwrightd** (E46-S7/S8) — the daemon is the broker/multiplexer.
- **Auth:** strong remote auth (device tokens / mTLS / SSO); local-only by default with
  explicit opt-in for remote; never an open port without auth.
- **Sizing resolved by brokering:** daemon can give each client its own size or a
  read-only mirror — no fighting the local control client.
- **Aggregate later:** start per-workspace through the daemon, then multiplex across the
  per-workspace tmux servers into one pane-of-glass.
- Reuse the resilience guarantees (governor/flow-control apply to remote streams too).

## Definition of done
- Remote client connects through buildwrightd (authenticated), drives a workspace's
  panes with correct sizing (no control-client conflict).
- Aggregate mode: one remote view spans all workspaces/servers.
- Security review of the remote surface (auth, exposure, transport) passes.

## Open questions
- Client form: native iPad app vs. responsive web (ties to E41 mobile work?).
- Transport/auth choice (mTLS vs token vs SSO); relay vs direct (Tailscale).
