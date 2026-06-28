---
id:        E46-S16
title:     Remote/AFK access v1 — harden + document SSH+tmux per-workspace attach
type:      story
status:    ready
category:  buildwright
priority:  P2
parent:    E46
created:   2026-06-15
updated:   2026-06-15
---

# Remote/AFK access v1 — lean SSH+tmux attach

The near-term remote path: reach a workspace's terminals from iPad/Blink today via
SSH → `tmux attach` to that workspace's server. No custom client — make the existing
architectural path real, secure, and documented. (v2 = the daemon-brokered pane-of-
glass, E46-S17.)

## Goal — the outcome we want
From an iPad (Blink) or any SSH client, attach to a chosen workspace's tmux server and
see + drive **all** its panes (however many), reliably and securely.

## Who it's for / the pain
rvance — wants AFK access to long-running agents while away from the M4 Max. Persistence
+ iPad were "essential/planned" from day one; this turns the latent capability on.

## Constraints — must-haves, limits, non-negotiables
- **Per-workspace** = one tmux server (one socket) per workspace; document how to list
  + pick the right server/socket to attach. Aggregate cross-workspace view is v2 (S17).
- **Security:** SSH key auth only; recommend Tailscale/VPN over exposing anything to the
  public internet; never expose the tmux socket directly. Document the safe setup.
- **Sizing tension:** the GUI is sole sizing authority (`window-size manual`). Define +
  document remote-attach behavior (accept GUI-driven size / detach GUI / read-only) so a
  remote client doesn't fight the control client. `[reconcile]` actual multi-client behavior.
- Don't regress the local control-mode model; remote attach is additive.

## Definition of done
- A written runbook: from Blink/SSH, connect → attach to workspace X's server → operate
  every pane; verified live on an actual iPad/phone session.
- Documented socket/server naming so the right workspace is reachable unambiguously.
- Security guidance (keys + Tailscale) captured; no public socket exposure.

## Open questions
- Remote-attach sizing policy (co-equal vs read-only vs GUI-detach) — pick + document.
- Whether v1 ships standalone now or waits to ride alongside the daemon work.
