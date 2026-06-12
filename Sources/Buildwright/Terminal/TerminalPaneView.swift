import SwiftUI
import SwiftTerm
import AppKit

/// Native terminal view for ONE tmux window, fed by the workspace's
/// control-mode connection (see TmuxControlClient). The view owns its buffer,
/// so scrollback, trackpad scrolling, selection, copy, and Cmd+F find are all
/// native — tmux only owns the process.
///
/// Startup sequencing: output that arrives before the capture-pane history
/// reply is DROPPED, not buffered. The control connection serializes events,
/// so any %output emitted before the capture's %end is, by construction, also
/// contained in the capture itself — dropping it avoids duplicate lines, and
/// nothing after the %end can be missed.
final class ControlModeTerminalView: TerminalView, TerminalViewDelegate {
    let paneID: String
    let windowID: String
    let sessionName: String
    private(set) weak var control: TmuxControlClient?
    private var awaitingHistory = true
    /// Watchdog: when the in-flight replay started. A replay stuck past the
    /// watchdog window means dropped output forever — heal by refreshing.
    private var replayStartedAt = Date()

    var replayStuckSeconds: TimeInterval? {
        awaitingHistory ? Date().timeIntervalSince(replayStartedAt) : nil
    }

    /// Size reconciliation state: what we last told tmux, what tmux last
    /// reported, and when. SwiftUI layout churn can swallow a trailing
    /// sizeChanged, leaving tmux a couple of columns wide of reality —
    /// every full-width TUI line then wraps. The cache's reconciler timer
    /// converges any drift within seconds.
    private var lastSentCols = 0
    private var lastSentRows = 0
    private var tmuxCols: Int?
    private var tmuxRows: Int?
    private var lastTmuxResizeAt = Date.distantPast

    func noteTmuxSize(cols: Int, rows: Int) {
        tmuxCols = cols
        tmuxRows = rows
        lastTmuxResizeAt = Date()
    }

    /// Push the view's real size to tmux when anything drifted. External
    /// clients (iPad) win while they're actively resizing — we only reclaim
    /// after 10s of layout silence so we never fight a live remote session.
    /// Detached views (tab switched away, mid-teardown) never drive sizes:
    /// their frames pass through garbage during SwiftUI animations.
    func reconcileSize() {
        guard window != nil else { return }
        guard control?.isAlive == true, !awaitingHistory else { return }
        let t = getTerminal()
        guard t.cols > 1, t.rows > 1 else { return }
        let viewChanged = t.cols != lastSentCols || t.rows != lastSentRows
        let tmuxDrifted = (tmuxCols != nil && (tmuxCols != t.cols || tmuxRows != t.rows))
            && Date().timeIntervalSince(lastTmuxResizeAt) > 10
        guard viewChanged || tmuxDrifted else { return }
        sendSize(cols: t.cols, rows: t.rows)
    }

    private func sendSize(cols: Int, rows: Int) {
        lastSentCols = cols
        lastSentRows = rows
        control?.setWindowSize(windowID: windowID, cols: cols, rows: rows)
    }

    init(frame: CGRect, paneID: String, windowID: String, control: TmuxControlClient) {
        self.paneID = paneID
        self.windowID = windowID
        self.sessionName = control.sessionName
        self.control = control
        super.init(frame: frame)
        terminalDelegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Point at a fresh control connection after a reconnect, wipe the stale
    /// buffer, and replay from tmux's current truth.
    func rebind(to newControl: TmuxControlClient) {
        control = newControl
        refreshFromTmux()
    }

    /// The panic button: wipe the local buffer and rebuild the pane from
    /// tmux's truth (history + screen + modes + cursor). Whatever display
    /// weirdness happened, this clears it without touching the process.
    func refreshFromTmux() {
        guard control?.isAlive == true else { return }
        awaitingHistory = true
        replayStartedAt = Date()
        getTerminal().resetToInitialState()
        TerminalViewCache.shared.startReplay(for: self)
    }

    /// Reconstruct the pane the way iTerm2 does: scrollback history pushed
    /// fully above the viewport, the application's terminal modes restored
    /// (alt screen, app cursor keys, mouse — or arrows misbehave after a
    /// reattach), then the visible screen drawn from home, then the cursor
    /// placed where tmux says it is.
    func completeReplay(history: String?, modes: TmuxControlClient.PaneModes?, screen: String?) {
        let t = getTerminal()
        if let history, !history.isEmpty {
            feed(text: history.replacingOccurrences(of: "\n", with: "\r\n"))
            // Scroll history fully into scrollback so the screen redraw
            // below can't erase its tail.
            feed(text: String(repeating: "\r\n", count: t.rows))
        }
        let modes = modes ?? TmuxControlClient.PaneModes()
        if modes.alternateScreen {
            feed(text: "\u{1b}[?1049h") // fresh alt screen; the capture IS its content
        }
        feed(text: modes.restoreSequences)
        if let screen, !screen.isEmpty {
            feed(text: "\u{1b}[H\u{1b}[2J") // home + clear viewport
            feed(text: screen.replacingOccurrences(of: "\n", with: "\r\n"))
        }
        awaitingHistory = false
        // Tell tmux the real size this client displays the window at —
        // full-screen apps redraw on the resulting SIGWINCH.
        sendSize(cols: t.cols, rows: t.rows)
    }

    /// Cursor restore (arrives just after replay; zero-based from tmux).
    func placeCursor(x: Int, y: Int) {
        feed(text: "\u{1b}[\(y + 1);\(x + 1)H")
    }

    func deliver(bytes: [UInt8]) {
        guard !awaitingHistory else { return } // contained in pending capture
        feed(byteArray: bytes[...])
    }

    /// Input bypassing broadcast fan-out (used BY the fan-out).
    func sendDirectly(bytes: [UInt8]) {
        control?.sendKeys(paneID: paneID, bytes: bytes)
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        if TerminalViewCache.shared.broadcast(from: self, bytes: bytes) { return }
        control?.sendKeys(paneID: paneID, bytes: bytes)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard !awaitingHistory else { return } // replay sends the final size
        // Detached or mid-animation frames produce garbage dimensions
        // (29-col slivers, 519-col doubles were observed live) — pushing
        // them resizes the real pty and corrupts every TUI in the pane.
        guard window != nil else { return }
        sendSize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func bell(source: TerminalView) { NSSound.beep() }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        if let str = String(data: content, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(str, forType: .string)
        }
    }
}

/// Cache of live terminal views keyed by pane id. Views must survive SwiftUI
/// view churn — tab switches, layout edits — and die only when the pane is
/// actually closed. Also routes control-mode %output to the right view.
/// Visible lifecycle state of a terminal pane, driving the SwiftUI overlay
/// (never injected into the terminal buffer — that corrupts live TUIs).
enum PaneRunState: Equatable {
    case running
    case exited        // tmux window closed (process ended)
    case reconnecting  // control connection dropped; retrying
    case lost          // reconnect failed; manual action needed
}

@MainActor
final class TerminalViewCache: ObservableObject {
    static let shared = TerminalViewCache()

    /// Pane UUID → lifecycle state; only non-running states are stored.
    @Published private(set) var runStates: [UUID: PaneRunState] = [:]

    private var views: [UUID: ControlModeTerminalView] = [:]
    private var paneIDToView: [String: UUID] = [:]   // tmux %pane-id → pane UUID
    private var windowIDToView: [String: UUID] = [:] // tmux @window-id → pane UUID

    /// Current terminal font size; applied to existing views on change.
    private var fontSize: CGFloat = 13

    /// Pane UUIDs receiving mirrored input while broadcast mode is armed
    /// (managed by AppState; empty = off).
    var broadcastTargets: Set<UUID> = []

    func applyFontSize(_ size: CGFloat) {
        fontSize = size
        for view in views.values {
            view.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

    /// Fan input out to every broadcast target (source included). Returns
    /// false when broadcast is off or the source isn't armed — caller sends
    /// normally.
    func broadcast(from source: ControlModeTerminalView, bytes: [UInt8]) -> Bool {
        guard !broadcastTargets.isEmpty,
              let sourceUUID = paneIDToView[source.paneID],
              broadcastTargets.contains(sourceUUID) else { return false }
        for id in broadcastTargets {
            views[id]?.sendDirectly(bytes: bytes)
        }
        return true
    }

    private init() {
        // Size reconciler: converge tmux window sizes to what views actually
        // render. Catches resize events lost in SwiftUI layout churn (the
        // off-by-a-few-columns wrap bug) within seconds, forever.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in
                for view in TerminalViewCache.shared.views.values {
                    view.reconcileSize()
                }
            }
        }
    }

    /// tmux reported a window resize (%layout-change) — record it on the
    /// view so the reconciler can detect drift.
    func tmuxResized(windowID: String, cols: Int, rows: Int) {
        guard let id = windowIDToView[windowID], let view = views[id] else { return }
        view.noteTmuxSize(cols: cols, rows: rows)
    }

    func view(for pane: Pane, in workspace: Workspace) -> ControlModeTerminalView? {
        if let existing = views[pane.id] { return existing }
        guard let windowID = pane.tmuxWindowID,
              let control = TmuxManager.shared.controlClient(for: workspace),
              let tmuxPaneID = TmuxManager.shared.client.primaryPaneID(windowID: windowID)
        else { return nil }

        let tv = ControlModeTerminalView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300),
            paneID: tmuxPaneID, windowID: windowID, control: control)
        tv.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

        views[pane.id] = tv
        paneIDToView[tmuxPaneID] = pane.id
        windowIDToView[windowID] = pane.id
        runStates.removeValue(forKey: pane.id)

        startReplay(for: tv)
        return tv
    }

    /// Ordered on the single control connection: history → modes → screen →
    /// cursor. Output is dropped until the screen capture lands (it's
    /// contained in the captures by protocol ordering), then streams live.
    func startReplay(for tv: ControlModeTerminalView) {
        guard let control = tv.control else { return }
        let tmuxPaneID = tv.paneID
        control.captureHistory(paneID: tmuxPaneID) { [weak tv, weak control] history in
            control?.paneModes(paneID: tmuxPaneID) { modes in
                control?.captureScreen(paneID: tmuxPaneID) { screen in
                    tv?.completeReplay(history: history, modes: modes, screen: screen)
                    control?.cursorPosition(paneID: tmuxPaneID) { position in
                        if let position { tv?.placeCursor(x: position.x, y: position.y) }
                    }
                }
            }
        }
    }

    // MARK: Control-event routing (called by TmuxManager)

    func deliver(paneID: String, bytes: [UInt8]) {
        guard let id = paneIDToView[paneID], let view = views[id] else { return }
        // Output is proof of life: a pane wrongly latched as exited/lost
        // (restart/reconnect races) un-marks itself the moment it speaks.
        if runStates[id] == .exited || runStates[id] == .lost {
            runStates.removeValue(forKey: id)
        }
        view.deliver(bytes: bytes)
    }

    func windowClosed(windowID: String) {
        guard let id = windowIDToView[windowID] else { return }
        runStates[id] = .exited
    }

    /// Connection dropped: mark this session's panes reconnecting (the
    /// overlay shows it); TmuxManager drives the retry.
    func controlClientExited(session: String) {
        for (id, view) in views where view.sessionName == session {
            if runStates[id] != .exited { runStates[id] = .reconnecting }
        }
    }

    /// Reconnect succeeded: rebind surviving windows to the new connection
    /// and replay; windows that vanished with the old server are dead.
    func rebindSession(_ session: String, to control: TmuxControlClient, liveWindowIDs: Set<String>) {
        for (id, view) in views where view.sessionName == session {
            if liveWindowIDs.contains(view.windowID) {
                runStates.removeValue(forKey: id)
                view.rebind(to: control)
            } else {
                runStates[id] = .exited
            }
        }
    }

    /// Reconnect gave up: panes need a human.
    func sessionLost(_ session: String) {
        for (id, view) in views where view.sessionName == session {
            if runStates[id] == .reconnecting { runStates[id] = .lost }
        }
    }

    func remove(_ paneID: UUID) {
        runStates.removeValue(forKey: paneID)
        guard let view = views.removeValue(forKey: paneID) else { return }
        paneIDToView.removeValue(forKey: view.paneID)
        windowIDToView.removeValue(forKey: view.windowID)
    }

    func contains(_ paneID: UUID) -> Bool { views[paneID] != nil }

    func refreshPane(_ paneID: UUID) {
        views[paneID]?.refreshFromTmux()
    }

    func refreshAllPanes() {
        for view in views.values { view.refreshFromTmux() }
    }

    /// Annealing pass: replays stuck past the watchdog window restart from
    /// tmux truth; a wedged connection underneath is handled by the
    /// heartbeat (kill + reconnect), so this cannot loop forever silently.
    func watchdogSweep() -> [String] {
        var healed: [String] = []
        for (id, view) in views {
            if let stuck = view.replayStuckSeconds, stuck > 12 {
                healed.append("pane \(id.uuidString.prefix(8)) replay stalled \(Int(stuck))s — refreshing from tmux")
                view.refreshFromTmux()
            }
        }
        return healed
    }

    /// Runtime liveness: a window that vanished without a %window-close
    /// (missed event, sleep/wake gap) gets the exited overlay.
    func markExited(_ paneID: UUID) {
        if runStates[paneID] == nil { runStates[paneID] = .exited }
    }

    /// The reverse heal: a pane latched exited whose window is verifiably
    /// alive gets un-marked (used by the window sweep with a fresh listing).
    func clearExitedIfAlive(_ paneID: UUID) {
        if runStates[paneID] == .exited { runStates.removeValue(forKey: paneID) }
    }

    /// Human override: the user says this pane is fine — believe them.
    func dismissState(_ paneID: UUID) {
        runStates.removeValue(forKey: paneID)
    }

    /// One-paste debugging: everything I need to diagnose a display issue.
    func diagnosticLines() -> [String] {
        views.map { id, view in
            let t = view.getTerminal()
            return "pane \(id.uuidString.prefix(8)) win=\(view.windowID) tmuxPane=\(view.paneID) " +
                   "viewCols=\(t.cols)x\(t.rows) attached=\(view.window != nil) " +
                   "state=\(runStates[id].map(String.init(describing:)) ?? "running")"
        }.sorted()
    }

    /// Bottom-most non-empty line currently visible in a pane — mission
    /// control's fallback when there's no transcript detail to show.
    func lastVisibleLine(for paneID: UUID) -> String? {
        guard let view = views[paneID] else { return nil }
        let terminal = view.getTerminal()
        for row in stride(from: terminal.rows - 1, through: 0, by: -1) {
            guard let line = terminal.getLine(row: row) else { continue }
            let text = line.translateToString(trimRight: true)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return nil
    }
}

/// SwiftUI wrapper hosting the cached terminal view for a pane.
struct TerminalPaneView: NSViewRepresentable {
    let pane: Pane
    let workspace: Workspace
    let onFocus: () -> Void

    func makeNSView(context: Context) -> NSView {
        let container = FocusReportingView()
        container.onFocus = onFocus
        if let tv = TerminalViewCache.shared.view(for: pane, in: workspace) {
            tv.frame = container.bounds
            tv.autoresizingMask = [.width, .height]
            container.addSubview(tv)
            // Re-attached after a tab switch: push the real size once the
            // frame settles (detached resizes were deliberately ignored).
            DispatchQueue.main.async { tv.reconcileSize() }
        } else {
            let label = NSTextField(labelWithString: "tmux unavailable — install tmux and reopen this pane")
            label.frame = container.bounds
            container.addSubview(label)
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The terminal view is cached and self-managing; nothing to push down.
    }
}

/// Container that reports clicks so the app can track the focused pane, and
/// forwards first-responder status to the terminal.
final class FocusReportingView: NSView {
    var onFocus: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onFocus?()
        // Hand focus to the terminal subview.
        if let tv = subviews.first(where: { $0 is TerminalView }) {
            window?.makeFirstResponder(tv)
        }
        super.mouseDown(with: event)
    }
}
