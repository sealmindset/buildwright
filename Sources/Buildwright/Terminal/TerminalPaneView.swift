import SwiftUI
import SwiftTerm
import AppKit

/// Terminal view that forwards trackpad/mouse-wheel scrolling to tmux.
///
/// SwiftTerm's default scrollWheel only moves its local scrollback, which is
/// always empty here — tmux keeps the history server-side. When the app inside
/// the terminal has mouse reporting on (our tmux sessions always do: `mouse on`),
/// scrolls are forwarded as wheel events so tmux enters copy-mode and scrolls
/// its own history. SwiftTerm's scrollWheel is public-not-open, so the
/// forwarding is driven by a local event monitor (see TerminalViewCache) that
/// calls handleScroll and swallows the event when it was consumed.
final class TmuxTerminalView: LocalProcessTerminalView {
    private var wheelAccumulator: CGFloat = 0

    /// How many wheel events an accumulated scroll delta is worth. tmux scrolls
    /// 5 lines per wheel event, so ~3 lines of trackpad travel per event keeps
    /// finger distance roughly proportional to content movement.
    static func drainWheel(accumulator: CGFloat, step: CGFloat = 3) -> (events: Int, up: Bool, remainder: CGFloat) {
        let up = accumulator > 0
        let events = Int(abs(accumulator) / step)
        let remainder = accumulator - CGFloat(events) * step * (up ? 1 : -1)
        return (events, up, remainder)
    }

    /// Returns true when the event was forwarded to tmux (caller swallows it);
    /// false hands it back to SwiftTerm's local scrollback behavior.
    func handleScroll(_ event: NSEvent) -> Bool {
        let terminal = getTerminal()
        guard terminal.mouseMode != .off else { return false }
        guard event.deltaY != 0 else { return false }
        if event.hasPreciseScrollingDeltas {
            // Trackpad (including momentum): accumulate small deltas.
            wheelAccumulator += event.deltaY
            let drained = Self.drainWheel(accumulator: wheelAccumulator)
            wheelAccumulator = drained.remainder
            for _ in 0..<drained.events { sendWheel(up: drained.up, event: event) }
        } else {
            // Physical mouse wheel: one event per click, no dead zone.
            sendWheel(up: event.deltaY > 0, event: event)
        }
        return true
    }

    private func sendWheel(up: Bool, event: NSEvent) {
        let terminal = getTerminal()
        let flags = terminal.encodeButton(
            button: up ? 4 : 5, release: false,
            shift: event.modifierFlags.contains(.shift),
            meta: event.modifierFlags.contains(.option),
            control: event.modifierFlags.contains(.control))
        let point = convert(event.locationInWindow, from: nil)
        let col = max(0, min(terminal.cols - 1, Int(point.x / max(1, bounds.width) * CGFloat(terminal.cols))))
        let row = max(0, min(terminal.rows - 1, Int((bounds.height - point.y) / max(1, bounds.height) * CGFloat(terminal.rows))))
        terminal.sendEvent(buttonFlags: flags, x: col, y: row)
    }
}

/// Cache of live terminal views keyed by pane id. Terminal views (and their
/// attached tmux client processes) must survive SwiftUI view churn — tab
/// switches, layout edits — and die only when the pane is actually closed.
@MainActor
final class TerminalViewCache {
    static let shared = TerminalViewCache()
    private var views: [UUID: LocalProcessTerminalView] = [:]

    private init() {
        // Route scroll events over a terminal to tmux (SwiftTerm's own
        // scrollWheel can't be overridden — it's public, not open).
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let contentView = event.window?.contentView,
                  let hit = contentView.hitTest(event.locationInWindow) else { return event }
            var view: NSView? = hit
            while let v = view, !(v is TmuxTerminalView) { view = v.superview }
            guard let tv = view as? TmuxTerminalView else { return event }
            return tv.handleScroll(event) ? nil : event
        }
    }

    func view(for pane: Pane, in workspace: Workspace) -> LocalProcessTerminalView? {
        if let existing = views[pane.id] { return existing }
        guard let argv = TmuxManager.shared.attachCommand(for: pane, in: workspace) else { return nil }

        let tv = TmuxTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        tv.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        let extraPaths = "/opt/homebrew/bin:/usr/local/bin:\(Config.home.path)/.local/bin"
        env["PATH"] = "\(env["PATH"] ?? "/usr/bin:/bin"):\(extraPaths)"
        let envArray = env.map { "\($0.key)=\($0.value)" }

        tv.startProcess(
            executable: "/usr/bin/env",
            args: argv,
            environment: envArray,
            execName: nil
        )
        views[pane.id] = tv
        return tv
    }

    func remove(_ paneID: UUID) {
        views.removeValue(forKey: paneID)
    }

    func contains(_ paneID: UUID) -> Bool { views[paneID] != nil }
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
        if let tv = subviews.first(where: { $0 is LocalProcessTerminalView }) {
            window?.makeFirstResponder(tv)
        }
        super.mouseDown(with: event)
    }
}
