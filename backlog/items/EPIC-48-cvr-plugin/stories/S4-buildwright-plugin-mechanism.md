---
id:        E48-S4
title:     Buildwright plugin mechanism (manifest install-from-GitHub)
type:      story
status:    done
category:  buildwright
priority:  P2
parent:    E48
created:   2026-06-15
updated:   2026-06-15
---

# Buildwright plugin mechanism

Buildwright's first plugin system: install/manage external tool plugins from GitHub via
a lightweight manifest. CVR is the first consumer (wired in S5).

## Goal
Install a plugin from a GitHub URL; it registers and appears in Settings → Plugins
(list / update / remove).

## Constraints
- Scope = TOOL plugins (external tools Buildwright launches), NOT in-app/editor plugins.
  This is a deliberate, scoped reversal of the old cockpit "no plugin system" anti-goal.
- `plugin.json` schema: name, repo, version, install cmd, launch cmd/CLI, optional ui
  hook, settings keys.
- Plugins clone to `~/.buildwright/plugins/<name>/`.
- Install flow: clone (gh auth for PRIVATE repos — confirm token vs deploy key) → run
  install → register manifest. Surface install progress (Chromium download is slow).
- Settings → Plugins: install-from-URL, list, update (git pull + reinstall), remove.
- `[reconcile]`: Settings UI lives in RemoteAccessView; Config for plugin dir; ShellExec
  for clone/install.

## Definition of done
- Install sealmindset/cvr from its URL → cloned, installed, registered.
- Update + remove work; state survives relaunch; private-repo auth path documented.

## Result (2026-06-15) — built + pipeline live-verified (branch bw/e48-cvr-plugin)
New `PluginManager` (Plugins/PluginManager.swift): manifest model (PluginManifest),
install-from-GitHub via `gh repo clone` (private-repo friendly) + manifest `install`
step run with `bash -lc` off the main thread (captured output), refresh/update/remove,
scanning ~/.buildwright/plugins. `Config.pluginsDirectory` added. Settings → Plugins
tab (PluginsView) wired into SettingsView TabView. Builds clean off main.
Live-verified the exact pipeline install() runs (gh clone → npm ci + chromium →
manifest decode name=cvr/v0.1.0/cli=bin/cvr.mjs) → **CVR now installed at
~/.buildwright/plugins/cvr**, which refresh() lists. Pending: in-app visual smoke of the
tab (needs GUI). Auth uses the user's gh keyring (no deploy key needed).
