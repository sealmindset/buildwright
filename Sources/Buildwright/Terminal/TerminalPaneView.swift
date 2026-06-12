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

    init(frame: CGRect, paneID: String, windowID: String, control: TmuxControlClient) {
        self.paneID = paneID
        self.windowID = windowID
        self.control = control
        super.init(frame: frame)
        terminalDelegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// History (capture-pane -e) replayed into the fresh buffer; afterwards
    /// live %output flows directly.
    func completeReplay(history: String?) {
        if let history, !history.isEmpty {
            feed(text: history.replacingOccurrences(of: "\n", with: "\r\n"))
        }
        awaitingHistory = false
        // Tell tmux the real size this client displays the window at —
        // full-screen apps redraw on the resulting SIGWINCH.
        let t = getTerminal()
        control?.setWindowSize(windowID: windowID, cols: t.cols, rows: t.rows)
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
        control?.setWindowSize(windowID: windowID, cols: newCols, rows: newRows)
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

    private init() {}

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

        control.capturePane(paneID: tmuxPaneID) { [weak tv] history in
            tv?.completeReplay(history: history)
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
