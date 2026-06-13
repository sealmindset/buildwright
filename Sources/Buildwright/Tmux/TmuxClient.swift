import Foundation

/// Thin wrapper over the tmux CLI on the DEFAULT socket, so sessions are
/// reachable from any terminal (`tmux attach -t docai`) — including Blink
/// Shell on the iPad via mosh.
struct TmuxClient {

    /// Build the argv for a tmux invocation. Centralized so tests can verify
    /// exact command construction.
    static func command(_ args: [String]) -> [String] {
        ["tmux"] + args
    }

    @discardableResult
    func run(_ args: [String]) -> ShellResult {
        ShellExec.run(TmuxClient.command(args))
    }

    // MARK: Queries

    func serverRunning() -> Bool {
        run(["has-session"]).status != 127 && run(["list-sessions"]).ok
    }

    func hasSession(_ name: String) -> Bool {
        run(["has-session", "-t", "=\(name)"]).ok
    }

    /// Returns [(windowID, windowName)] for a session.
    func listWindows(session: String) -> [(id: String, name: String)] {
        let result = run(["list-windows", "-t", "=\(session)", "-F", "#{window_id}\t#{window_name}"])
        guard result.ok else { return [] }
        return result.stdout.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count >= 1 else { return nil }
            return (id: parts[0], name: parts.count > 1 ? parts[1] : "")
        }
    }

    func listSessions() -> [String] {
        let result = run(["list-sessions", "-F", "#{session_name}"])
        guard result.ok else { return [] }
        return result.stdout.split(separator: "\n").map(String.init)
    }

    /// [(name, attachedClientCount)] for every session on the server.
    func listSessionsWithAttachCounts() -> [(name: String, attached: Int)] {
        let result = run(["list-sessions", "-F", "#{session_name}\t#{session_attached}"])
        guard result.ok else { return [] }
        return result.stdout.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t").map(String.init)
            guard parts.count == 2 else { return nil }
            return (name: parts[0], attached: Int(parts[1]) ?? 0)
        }
    }

    /// First pane id (e.g. "%7") of a window. Buildwright windows hold exactly
    /// one tmux pane — splits are app-side layout, each its own window.
    func primaryPaneID(windowID: String) -> String? {
        let result = run(["list-panes", "-t", windowID, "-F", "#{pane_id}"])
        guard result.ok else { return nil }
        return result.stdout.split(separator: "\n").first.map(String.init)
    }

    /// LEGACY migration: kill leftover `_bw-*` display sessions created by the
    /// pre-control-mode design (hidden grouped sessions per pane). Newer
    /// builds never create them; this only sweeps up after old versions.
    func cleanupStaleGroupedSessions() {
        for (name, attached) in listSessionsWithAttachCounts()
        where name.hasPrefix(Config.groupedSessionPrefix) && attached == 0 {
            killSession(name: name)
        }
    }

    // MARK: Session / window lifecycle

    /// Create a detached session for a workspace whose first window runs `command`.
    /// Returns the new window's id.
    @discardableResult
    func createSession(name: String, cwd: String, windowName: String, command: String?, environment: [String: String]) -> String? {
        var args = ["new-session", "-d", "-s", name, "-c", cwd, "-n", windowName, "-P", "-F", "#{window_id}"]
        for (k, v) in environment.sorted(by: { $0.key < $1.key }) {
            args.append(contentsOf: ["-e", "\(k)=\(v)"])
        }
        if let command { args.append(command) }
        let result = run(args)
        guard result.ok else { return nil }
        applyMobileDefaults(session: name)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Create a new window in an existing session. Returns the window id.
    func createWindow(session: String, cwd: String, windowName: String, command: String?, environment: [String: String]) -> String? {
        var args = ["new-window", "-d", "-t", "=\(session)", "-c", cwd, "-n", windowName, "-P", "-F", "#{window_id}"]
        for (k, v) in environment.sorted(by: { $0.key < $1.key }) {
            args.append(contentsOf: ["-e", "\(k)=\(v)"])
        }
        if let command { args.append(command) }
        let result = run(args)
        guard result.ok else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func killWindow(id: String) {
        run(["kill-window", "-t", id])
    }

    func killSession(name: String) {
        run(["kill-session", "-t", "=\(name)"])
    }

    func renameWindow(id: String, to name: String) {
        run(["rename-window", "-t", id, name])
    }

    // MARK: Options

    /// Mobile/iPad-friendly defaults applied per workspace session (not
    /// globally, so the user's own tmux setup is untouched).
    func applyMobileDefaults(session: String) {
        let t = "\(session):" // set-option needs "name:" form, not "=name"
        run(["set-option", "-t", t, "history-limit", "30000"])
        run(["set-option", "-t", t, "mouse", "on"])
        // The iTerm2 control-mode model: the control client is the SOLE
        // authority on each window's size, set per-window via
        // `refresh-client -C @id:WxH`. "latest" + aggressive-resize let tmux
        // re-size windows to whatever client last touched them, leaving our
        // SwiftTerm view a few columns off — every full-width TUI line then
        // wraps wrong and overstrikes (the recurring "format" garble).
        // "manual" freezes sizing to exactly what we push.
        run(["set-option", "-t", t, "window-size", "manual"])
        run(["set-option", "-t", t, "aggressive-resize", "off"])
        run(["set-option", "-t", t, "renumber-windows", "on"])
        run(["set-option", "-t", t, "set-titles", "on"])
        run(["set-option", "-t", t, "default-terminal", "tmux-256color"])
    }

    /// Show Claude status in the tmux status bar so the iPad sees the same
    /// at-a-glance info as the Mac app. Reads bw-hook status files.
    func applyStatusBar(session: String, statusDir: String) {
        let t = "\(session):" // set-option needs "name:" form, not "=name"
        let script = "for f in \(statusDir)/*.status; do [ -e \"$f\" ] || continue; cat \"$f\"; printf ' '; done"
        run(["set-option", "-t", t, "status-interval", "5"])
        run(["set-option", "-t", t, "status-right-length", "80"])
        run(["set-option", "-t", t, "status-right", "#(sh -c '\(script)') %H:%M"])
    }
}
