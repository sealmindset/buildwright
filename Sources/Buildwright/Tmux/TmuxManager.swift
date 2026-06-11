import Foundation

/// Orchestrates the mapping: workspace ⇄ tmux session, pane ⇄ tmux window.
/// The app never owns the processes — tmux does. Quit, crash, reboot:
/// sessions live on and the app reattaches on next launch.
@MainActor
final class TmuxManager {
    static let shared = TmuxManager()
    let client = TmuxClient()

    /// Make sure the workspace's tmux session exists. Returns true if it was
    /// freshly created (no windows to reattach).
    @discardableResult
    func ensureWorkspaceSession(_ workspace: Workspace) -> Bool {
        let session = workspace.tmuxSessionName
        if client.hasSession(session) {
            client.applyMobileDefaults(session: session)
            client.applyStatusBar(session: session, statusDir: Config.claudeStatusDirectory.path)
            return false
        }
        // A session must have at least one window; create a placeholder shell
        // window that the first real pane will replace or sit beside.
        _ = client.createSession(
            name: session,
            cwd: workspace.baseRepo,
            windowName: "shell",
            command: nil,
            environment: [:]
        )
        client.applyStatusBar(session: session, statusDir: Config.claudeStatusDirectory.path)
        return true
    }

    /// Command line for a pane's process.
    func paneCommand(for kind: PaneKind, prompt: String? = nil) -> String? {
        switch kind {
        case .shell:
            return nil // tmux default-shell (the user's login shell, zsh on macOS)
        case .claude:
            if let prompt {
                // Single-quote the prompt for the shell, escaping embedded quotes.
                let q = prompt.replacingOccurrences(of: "'", with: "'\\''")
                return "claude '\(q)'"
            }
            return "claude"
        case .browser:
            return nil // browser panes have no tmux window
        }
    }

    /// Create the tmux window for a new pane. Returns the tmux window id.
    func createWindow(for pane: Pane, in workspace: Workspace, prompt: String? = nil) -> String? {
        let session = workspace.tmuxSessionName
        ensureWorkspaceSession(workspace)
        var env: [String: String] = [:]
        if pane.kind == .claude {
            env["BUILDWRIGHT_PANE_ID"] = pane.shortID
            env["BUILDWRIGHT_PANE_TITLE"] = pane.title
        }
        return client.createWindow(
            session: session,
            cwd: pane.directory,
            windowName: pane.title,
            command: paneCommand(for: pane.kind, prompt: prompt),
            environment: env
        )
    }

    func destroyWindow(for pane: Pane, in workspace: Workspace) {
        guard let windowID = pane.tmuxWindowID else { return }
        client.killWindow(id: windowID)
        let grouped = TmuxClient.groupedSessionName(
            workspaceSession: workspace.tmuxSessionName, paneShortID: pane.shortID)
        if client.hasSession(grouped) {
            client.killSession(name: grouped)
        }
        // Clean up the status file so stale state never lingers.
        let statusFile = Config.claudeStatusDirectory
            .appendingPathComponent("\(pane.shortID).status")
        try? FileManager.default.removeItem(at: statusFile)
        try? FileManager.default.removeItem(
            at: Config.claudeStatusDirectory.appendingPathComponent("\(pane.shortID).json"))
    }

    /// The argv the terminal view runs to DISPLAY a pane: attach to a hidden
    /// grouped session focused on this pane's window.
    func attachCommand(for pane: Pane, in workspace: Workspace) -> [String]? {
        guard let windowID = pane.tmuxWindowID else { return nil }
        // Self-healing: if the workspace session is gone (server restart,
        // manual kill), grouping against it would create a stray session
        // with a literal "=name" group. Recreate the session first.
        ensureWorkspaceSession(workspace)
        let grouped = client.ensureGroupedSession(
            workspaceSession: workspace.tmuxSessionName,
            paneShortID: pane.shortID,
            windowID: windowID
        )
        return ["tmux", "attach-session", "-t", "=\(grouped)"]
    }

    /// On launch: reconcile saved panes with the live tmux server. Returns the
    /// set of pane IDs whose tmux windows are gone (process exited / killed).
    func reconcile(workspace: Workspace) -> Set<UUID> {
        let session = workspace.tmuxSessionName
        guard client.hasSession(session) else {
            // Whole session gone: every terminal pane is dead.
            var dead = Set<UUID>()
            for tab in workspace.tabs {
                for pane in tab.panes where pane.kind != .browser {
                    dead.insert(pane.id)
                }
            }
            return dead
        }
        client.applyMobileDefaults(session: session)
        client.applyStatusBar(session: session, statusDir: Config.claudeStatusDirectory.path)
        let liveWindowIDs = Set(client.listWindows(session: session).map { $0.id })
        var dead = Set<UUID>()
        for tab in workspace.tabs {
            for pane in tab.panes where pane.kind != .browser {
                if let wid = pane.tmuxWindowID, liveWindowIDs.contains(wid) { continue }
                dead.insert(pane.id)
            }
        }
        return dead
    }

    func tmuxAvailable() -> Bool {
        ShellExec.run(["tmux", "-V"]).ok
    }
}
