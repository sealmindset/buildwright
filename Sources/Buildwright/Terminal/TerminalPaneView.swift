import SwiftUI
import SwiftTerm
import AppKit

/// Cache of live terminal views keyed by pane id. Terminal views (and their
/// attached tmux client processes) must survive SwiftUI view churn — tab
/// switches, layout edits — and die only when the pane is actually closed.
@MainActor
final class TerminalViewCache {
    static let shared = TerminalViewCache()
    private var views: [UUID: LocalProcessTerminalView] = [:]

    func view(for pane: Pane, in workspace: Workspace) -> LocalProcessTerminalView? {
        if let existing = views[pane.id] { return existing }
        guard let argv = TmuxManager.shared.attachCommand(for: pane, in: workspace) else { return nil }

        let tv = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
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
