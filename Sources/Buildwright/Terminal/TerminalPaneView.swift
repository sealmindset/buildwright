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
    private(set) weak var control: TmuxControlClient?
    private var awaitingHistory = true

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
    func reconcileSize() {
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
        self.control = control
        super.init(frame: frame)
        terminalDelegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Reconstruct the pane the way iTerm2 does: scrollback history pushed
    /// fully above the viewport, then the visible screen drawn row-by-row
    /// from home, then the cursor placed where tmux says it is. Anything
    /// less desyncs the cursor and the next TUI repaint overstrikes rows.
    func completeReplay(history: String?, screen: String?) {
        let t = getTerminal()
        if let history, !history.isEmpty {
            feed(text: history.replacingOccurrences(of: "\n", with: "\r\n"))
            // Scroll history fully into scrollback so the screen redraw
            // below can't erase its tail.
            feed(text: String(repeating: "\r\n", count: t.rows))
        }
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

    func showNotice(_ message: String) {
        feed(text: "\r\n\u{1b}[2m── \(message) ──\u{1b}[0m\r\n")
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
@MainActor
final class TerminalViewCache {
    static let shared = TerminalViewCache()
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

        // Ordered on the single control connection: history → screen →
        // cursor. Output is dropped until the screen capture lands (it's
        // contained in the captures by protocol ordering), then streams live.
        control.captureHistory(paneID: tmuxPaneID) { [weak tv, weak control] history in
            control?.captureScreen(paneID: tmuxPaneID) { screen in
                tv?.completeReplay(history: history, screen: screen)
                control?.cursorPosition(paneID: tmuxPaneID) { position in
                    if let position { tv?.placeCursor(x: position.x, y: position.y) }
                }
            }
        }
        return tv
    }

    // MARK: Control-event routing (called by TmuxManager)

    func deliver(paneID: String, bytes: [UInt8]) {
        guard let id = paneIDToView[paneID], let view = views[id] else { return }
        view.deliver(bytes: bytes)
    }

    func windowClosed(windowID: String) {
        guard let id = windowIDToView[windowID], let view = views[id] else { return }
        view.showNotice("process exited")
    }

    func controlClientExited(session: String) {
        // Server (or our connection) is gone; views go stale. AppState
        // recreates the connection on next use; mark what we have.
        for view in views.values where view.control == nil || view.control?.isAlive == false {
            view.showNotice("tmux connection lost")
        }
    }

    func remove(_ paneID: UUID) {
        guard let view = views.removeValue(forKey: paneID) else { return }
        paneIDToView.removeValue(forKey: view.paneID)
        windowIDToView.removeValue(forKey: view.windowID)
    }

    func contains(_ paneID: UUID) -> Bool { views[paneID] != nil }

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
