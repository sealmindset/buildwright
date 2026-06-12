import Foundation

/// Orchestrates the mapping: workspace ⇄ tmux session, pane ⇄ tmux window.
/// The app never owns the processes — tmux does. Quit, crash, reboot:
/// sessions live on and the app reattaches on next launch.
@MainActor
final class TmuxManager {
    static let shared = TmuxManager()
    let client = TmuxClient()

    /// One control-mode connection per workspace session (created lazily,
    /// recreated on demand if the server restarts).
    private var controlClients: [String: TmuxControlClient] = [:]

    /// Live control-mode connection for a workspace, creating session and
    /// connection as needed. Returns nil only when tmux is unavailable.
    func controlClient(for workspace: Workspace) -> TmuxControlClient? {
        let session = workspace.tmuxSessionName
        if let existing = controlClients[session], existing.isAlive { return existing }
        ensureWorkspaceSession(workspace)
        let control = TmuxControlClient(sessionName: session)
        control.onEvent = { [weak self] event in
            self?.handleControlEvent(event, session: session)
        }
        guard control.connect() else { return nil }
        controlClients[session] = control
        return control
    }

    private func handleControlEvent(_ event: TmuxControlClient.Event, session: String) {
        switch event {
        case .output(let paneID, let bytes):
            TerminalViewCache.shared.deliver(paneID: paneID, bytes: bytes)
        case .windowClose(let windowID):
            TerminalViewCache.shared.windowClosed(windowID: windowID)
        case .exited:
            controlClients[session] = nil
            TerminalViewCache.shared.controlClientExited(session: session)
        case .windowRenamed, .layoutChange:
            break
        }
    }

    /// Launch claude with --dangerously-skip-permissions (no approval prompts).
    /// On by default — Buildwright is a trusted single-user environment.
    /// Toggleable in Settings → General.
    var claudeSkipPermissions = true

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
            let base = claudeSkipPermissions ? "claude --dangerously-skip-permissions" : "claude"
            if let prompt {
                // Single-quote the prompt for the shell, escaping embedded quotes.
                let q = prompt.replacingOccurrences(of: "'", with: "'\\''")
                return "\(base) '\(q)'"
            }
            return base
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
        // Clean up the status file so stale state never lingers.
        let statusFile = Config.claudeStatusDirectory
            .appendingPathComponent("\(pane.shortID).status")
        try? FileManager.default.removeItem(at: statusFile)
        try? FileManager.default.removeItem(
            at: Config.claudeStatusDirectory.appendingPathComponent("\(pane.shortID).json"))
    }

    /// On launch: reconcile saved panes with the live tmux server. Returns the
    /// set of pane IDs whose tmux windows are gone (process exited / killed).
    func reconcile(workspace: Workspace) -> Set<UUID> {
        let session = workspace.tmuxSessionName
        guard client.hasSession(session) else {
            // Whole session gone: every terminal pane is dead. Queued panes
            // have no window yet by design — they are not dead.
            var dead = Set<UUID>()
            for tab in workspace.tabs {
                for pane in tab.panes where pane.kind != .browser && !pane.isQueued {
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
            for pane in tab.panes where pane.kind != .browser && !pane.isQueued {
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
