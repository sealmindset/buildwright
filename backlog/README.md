# Buildwright Backlog

The Buildwright project's own Epic→Story→Task board — **separate from the docai backlog**
(`~/.claude/backlog`). Driven by the same `/backlog` skill, scoped to this board via the
`.project` marker (`buildwright`). Buildwright the app reads this dir via
`Config.backlogDirectory` (default points here; override with `BUILDWRIGHT_BACKLOG_DIR`).

- **IDs:** new items use the **`BW-NN`** prefix. The six grandfathered epics keep their
  original `E-NN` ids (E44/E46/E48/E50/E51/E52) so history + references still resolve.
- docai and Buildwright must never share a board — see the docai board's `.project` marker.
