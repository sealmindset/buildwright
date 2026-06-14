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
/// What a pane renders at vs. what tmux thinks the window is. When these
/// disagree, Claude draws for one size and SwiftTerm lays out at another —
/// the scramble. `tmux*` is nil until tmux reports a size.
struct PaneSizeInfo: Equatable {
    var viewCols: Int
    var viewRows: Int
    var tmuxCols: Int?
    var tmuxRows: Int?

    /// True only when we positively know tmux disagrees with the view.
    var drifted: Bool {
        guard let tc = tmuxCols, let tr = tmuxRows else { return false }
        return tc != viewCols || tr != viewRows
    }
    var viewLabel: String { "\(viewCols)×\(viewRows)" }
    var tmuxLabel: String { tmuxCols.map { "\($0)×\(tmuxRows ?? 0)" } ?? "—" }
}

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

    /// Live size snapshot for the header readout: what THIS view renders vs.
    /// what tmux last told us the window is. When they disagree, full-screen
    /// TUIs (Claude's pickers) scramble — now visible instead of mysterious.
    var sizeInfo: PaneSizeInfo {
        let t = getTerminal()
        return PaneSizeInfo(viewCols: t.cols, viewRows: t.rows,
                            tmuxCols: tmuxCols, tmuxRows: tmuxRows)
    }

    /// Assert the view's real size to tmux NOW, bypassing the replay guard.
    /// Called the moment the pane attaches so tmux reflows the pane to the
    /// width we actually display BEFORE content is captured/redrawn — the
    /// root fix for wrong-width replay snapshots that scramble pickers.
    func assertSizeNow() {
        guard window != nil, control?.isAlive == true else { return }
        let t = getTerminal()
        guard t.cols > 1, t.rows > 1 else { return }
        sendSize(cols: t.cols, rows: t.rows)
    }

    /// Debounced clean rebuild from tmux truth. Scheduled after a pane appears
    /// or a resize settles, so whatever transient garble a resize/reflow left
    /// is replaced by a correct-width snapshot ~⅓s later — no user action.
    private var pendingCleanRedraw: DispatchWorkItem?
    func scheduleCleanRedraw(after seconds: Double = 0.3) {
        pendingCleanRedraw?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.window != nil, self.control?.isAlive == true,
                  !self.awaitingHistory else { return }
            self.refreshFromTmux()
        }
        pendingCleanRedraw = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Force this pane back into agreement: push the real view size to tmux
    /// and rebuild the display from tmux truth (clears any scrambled frame).
    /// Wired to the header's size chip so you can fix drift in one click.
    func forceResync() {
        guard window != nil, control?.isAlive == true else { return }
        lastSentCols = 0; lastSentRows = 0 // defeat the "already sent" guard
        let t = getTerminal()
        if t.cols > 1, t.rows > 1 { sendSize(cols: t.cols, rows: t.rows) }
        refreshFromTmux()
    }

    /// Push the view's real size to tmux when anything drifted. Under
    /// `window-size manual` with one control client, THIS app is the sole
    /// size authority, so we reclaim drift fast (3s) rather than the old 10s
    /// courtesy — a window left at a stale size is exactly what scrambles a
    /// full-screen picker, and there's no other client to fight.
    /// Detached views (tab switched away, mid-teardown) never drive sizes:
    /// their frames pass through garbage during SwiftUI animations.
    func reconcileSize() {
        guard window != nil else { return }
        // Keep size synced even mid-replay: a pane that stalled in replay
        // (e.g. exited mid-capture) must not freeze tmux at a stale/garbage
        // size forever — that was how a glitch 519 could stick.
        guard control?.isAlive == true else { return }
        let t = getTerminal()
        guard t.cols > 1, t.rows > 1 else { return }
        let viewChanged = t.cols != lastSentCols || t.rows != lastSentRows
        let tmuxDrifted = (tmuxCols != nil && (tmuxCols != t.cols || tmuxRows != t.rows))
            && Date().timeIntervalSince(lastTmuxResizeAt) > 3
        guard viewChanged || tmuxDrifted else { return }
        sendSize(cols: t.cols, rows: t.rows)
    }

    private func sendSize(cols: Int, rows: Int) {
        // A pane can't be larger than the window it lives in. SwiftUI layout
        // churn / teardown frames have produced absurd sizes (519 cols — wider
        // than any screen), which tmux then renders at, wrapping every line
        // into the scramble. Clamp to what the window physically holds, using
        // the real cell size, so a glitch frame can never poison tmux.
        let (c, r) = Self.clamp(cols: cols, rows: rows, toWindowOf: self, font: font)
        guard c > 1, r > 1 else { return }
        lastSentCols = c
        lastSentRows = r
        control?.setWindowSize(windowID: windowID, cols: c, rows: r)
    }

    /// Cap (cols,rows) to the host window's content capacity (falls back to the
    /// main screen when detached). Generous +2 slack so a legitimately
    /// full-window pane is never trimmed; only garbage frames get clamped.
    static func clamp(cols: Int, rows: Int, toWindowOf view: NSView, font: NSFont) -> (Int, Int) {
        let cw = max(3, ("W" as NSString).size(withAttributes: [.font: font]).width)
        let ch = max(6, font.boundingRectForFont.height)
        let bound = view.window?.contentLayoutRect.size
            ?? NSScreen.main?.frame.size
            ?? CGSize(width: 1440, height: 900)
        let maxCols = max(20, Int(bound.width / cw) + 2)
        let maxRows = max(8, Int(bound.height / ch) + 2)
        return (min(cols, maxCols), min(rows, maxRows))
    }

    init(frame: CGRect, paneID: String, windowID: String, control: TmuxControlClient) {
        self.paneID = paneID
        self.windowID = windowID
        self.sessionName = control.sessionName
        self.control = control
        super.init(frame: frame)
        terminalDelegate = self
        // Drag a file (image, doc, anything) onto the pane → its path is
        // typed in, the way Terminal.app does it. Claude Code reads image
        // paths directly, so this is the "attach a screenshot" gesture.
        // Append rather than replace so SwiftTerm's own drag types survive.
        registerForDraggedTypes(registeredDraggedTypes + [.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Drag-and-drop file paths

    private func draggedFileURLs(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggedFileURLs(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggedFileURLs(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        draggedFileURLs(sender).isEmpty ? super.prepareForDragOperation(sender) : true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = draggedFileURLs(sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        // Space-separated, each shell-escaped — matches Terminal.app and lets
        // the running program (Claude Code, a shell) parse multiple paths.
        let text = urls.map { Self.shellEscape($0.path) }.joined(separator: " ") + " "
        control?.sendKeys(paneID: paneID, bytes: Array(text.utf8))
        window?.makeFirstResponder(self)
        return true
    }

    /// Backslash-escape the characters a shell or @-path parser would choke
    /// on, so paths with spaces/parens drop in usable. Plain paths pass
    /// through untouched.
    static func shellEscape(_ path: String) -> String {
        let special = Set(" \t\n\"'\\()[]{}<>|&;*?$`!#~")
        var out = ""
        out.reserveCapacity(path.count)
        for ch in path {
            if special.contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

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

    /// Activity tracking for idle-convergence (below).
    private(set) var lastOutputAt = Date()
    private var convergedSinceIdle = false

    func deliver(bytes: [UInt8]) {
        guard !awaitingHistory else { return } // contained in pending capture
        lastOutputAt = Date()
        convergedSinceIdle = false
        feed(byteArray: bytes[...])
    }

    /// Once a pane has been quiet for a few seconds, rebuild its display from
    /// tmux's buffer (the proven source of truth). Live in-place redraws can
    /// leave a few stale cells in SwiftTerm that tmux's own buffer doesn't
    /// have (the residual fragments after Claude's spinners/rules); a quiet
    /// pane has nothing streaming, so this snaps it back to truth invisibly.
    /// Fires at most once per idle period — no repeated refreshing.
    func convergeIfIdle() {
        guard window != nil, control?.isAlive == true, !awaitingHistory,
              !convergedSinceIdle,
              Date().timeIntervalSince(lastOutputAt) > 4 else { return }
        convergedSinceIdle = true
        refreshFromTmux()
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
        // Surface the new size immediately (don't wait for the 2s tick).
        TerminalViewCache.shared.refreshSizeInfo()
        // After the resize settles, rebuild clean: a full-screen picker that
        // reflowed at the old width gets repainted at the new one.
        scheduleCleanRedraw()
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

    /// Pane UUID → live size (view vs tmux), for the header readout. Lets you
    /// SEE size drift the moment it happens instead of guessing at scramble.
    @Published private(set) var paneSizeInfo: [UUID: PaneSizeInfo] = [:]

    /// Rebuild the size readout from every live view. Cheap (a handful of
    /// panes); called on the reconcile tick and right after a resize.
    func refreshSizeInfo() {
        var info: [UUID: PaneSizeInfo] = [:]
        for (id, view) in views { info[id] = view.sizeInfo }
        if info != paneSizeInfo { paneSizeInfo = info }
    }

    /// Force one pane back into size agreement (header chip action).
    func resyncSize(_ paneID: UUID) {
        views[paneID]?.forceResync()
        refreshSizeInfo()
    }

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
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in
                let cache = TerminalViewCache.shared
                for view in cache.views.values {
                    view.reconcileSize()
                    view.convergeIfIdle()
                }
                cache.refreshSizeInfo()
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
            // Now attached with the real frame: assert that size to tmux at
            // once (so the pane is the width we display BEFORE anything is
            // captured/drawn), then rebuild clean once the frame settles.
            DispatchQueue.main.async {
                tv.assertSizeNow()
                tv.scheduleCleanRedraw(after: 0.35)
            }
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
