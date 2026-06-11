import Foundation

/// Single source of truth for the companion scripts the app installs into
/// ~/.local/bin. The copies in the repo's Scripts/ directory mirror these.
enum EmbeddedScripts {

    static let bwHook = """
#!/bin/sh
# bw-hook — Claude Code hook helper for Buildwright.
# Called by Claude Code hooks (UserPromptSubmit / PreToolUse / Notification / Stop).
# Writes the pane's status where the Buildwright app and the tmux status bar
# can read it. No-ops instantly when not running inside a Buildwright pane.
#
# Usage: bw-hook <working|needs-input|done>

[ -n "$BUILDWRIGHT_PANE_ID" ] || exit 0

STATE="$1"
DIR="${BUILDWRIGHT_STATUS_DIR:-$HOME/.local/state/buildwright/status}"
mkdir -p "$DIR" 2>/dev/null || exit 0

TITLE="${BUILDWRIGHT_PANE_TITLE:-claude}"

case "$STATE" in
  working)     GLYPH="●" ;;
  needs-input) GLYPH="◉" ;;
  done)        GLYPH="✓" ;;
  *)           exit 0 ;;
esac

printf '{"pane":"%s","state":"%s","title":"%s","ts":%s}\\n' \\
  "$BUILDWRIGHT_PANE_ID" "$STATE" "$TITLE" "$(date +%s)" \\
  > "$DIR/$BUILDWRIGHT_PANE_ID.json"

printf '%s %s' "$GLYPH" "$TITLE" > "$DIR/$BUILDWRIGHT_PANE_ID.status"

exit 0
"""

    static let bw = """
#!/bin/sh
# bw — Buildwright companion CLI (designed for Blink Shell on iPad).
#
#   bw ls            list workspaces, their panes, and Claude status
#   bw <workspace>   attach to a workspace (all panes as tmux windows)
#   bw status        just the Claude status lines

DIR="${BUILDWRIGHT_STATUS_DIR:-$HOME/.local/state/buildwright/status}"

status_lines() {
  found=0
  for f in "$DIR"/*.status; do
    [ -e "$f" ] || continue
    found=1
    printf '  %s\\n' "$(cat "$f")"
  done
  [ "$found" = "1" ] || echo "  (no Claude sessions reporting)"
}

case "$1" in
  ls|"")
    echo "WORKSPACES"
    tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -v '^_bw-' | while read -r s; do
      printf '  %s\\n' "$s"
      tmux list-windows -t "=$s" -F '    #{window_index}: #{window_name}' 2>/dev/null
    done
    echo ""
    echo "CLAUDE STATUS   ● working  ◉ needs you  ✓ done"
    status_lines
    ;;
  status)
    status_lines
    ;;
  *)
    if [ -n "$TMUX" ]; then
      exec tmux switch-client -t "=$1"
    else
      exec tmux attach-session -t "=$1"
    fi
    ;;
esac
"""
}

/// Installs the bw companion CLI into ~/.local/bin.
enum BWCLIInstaller {
    static func installIfNeeded() {
        let binDir = Config.home.appendingPathComponent(".local/bin")
        try? FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let dest = binDir.appendingPathComponent("bw")
        if (try? String(contentsOf: dest, encoding: .utf8)) != EmbeddedScripts.bw {
            try? EmbeddedScripts.bw.write(to: dest, atomically: true, encoding: .utf8)
            _ = ShellExec.run(["chmod", "+x", dest.path])
        }
    }
}
