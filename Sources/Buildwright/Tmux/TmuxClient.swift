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

    // MARK: Grouped display sessions

    /// Name of the hidden grouped session the app uses to display one window
    /// independently (multiple tmux clients on ONE session share the active
    /// window; grouped sessions share windows but keep independent focus).
    static func groupedSessionName(workspaceSession: String, paneShortID: String) -> String {
        "\(Config.groupedSessionPrefix)\(workspaceSession)-\(paneShortID)"
    }

    /// Ensure a grouped session exists targeting `windowID`, returning its name.
    func ensureGroupedSession(workspaceSession: String, paneShortID: String, windowID: String) -> String {
        let name = TmuxClient.groupedSessionName(workspaceSession: workspaceSession, paneShortID: paneShortID)
        if !hasSession(name) {
            run(["new-session", "-d", "-s", name, "-t", "=\(workspaceSession)"])
            // Helper sessions: no status bar (the app draws its own chrome),
            // self-destruct when their client detaches.
            // NOTE: set-option targets use the "name:" form — tmux 3.6 rejects
            // the "=name" exact-match prefix for set-option specifically.
            run(["set-option", "-t", "\(name):", "status", "off"])
            run(["set-option", "-t", "\(name):", "destroy-unattached", "on"])
        }
        run(["select-window", "-t", "\(name):\(windowID)"])
        return name
    }

    // MARK: Options

    /// Mobile/iPad-friendly defaults applied per workspace session (not
    /// globally, so the user's own tmux setup is untouched).
    func applyMobileDefaults(session: String) {
        let t = "\(session):" // see note in ensureGroupedSession re: set-option targets
        run(["set-option", "-t", t, "history-limit", "30000"])
        run(["set-option", "-t", t, "mouse", "on"])
        run(["set-option", "-t", t, "window-size", "latest"])
        run(["set-option", "-t", t, "aggressive-resize", "on"])
        run(["set-option", "-t", t, "renumber-windows", "on"])
        run(["set-option", "-t", t, "set-titles", "on"])
        run(["set-option", "-t", t, "default-terminal", "tmux-256color"])
    }

    /// Show Claude status in the tmux status bar so the iPad sees the same
    /// at-a-glance info as the Mac app. Reads bw-hook status files.
    func applyStatusBar(session: String, statusDir: String) {
        let t = "\(session):" // see note in ensureGroupedSession re: set-option targets
        let script = "for f in \(statusDir)/*.status; do [ -e \"$f\" ] || continue; cat \"$f\"; printf ' '; done"
        run(["set-option", "-t", t, "status-interval", "5"])
        run(["set-option", "-t", t, "status-right-length", "80"])
        run(["set-option", "-t", t, "status-right", "#(sh -c '\(script)') %H:%M"])
    }
}
