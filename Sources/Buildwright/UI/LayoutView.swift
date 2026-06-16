import SwiftUI

/// Recursively renders the split-pane tree with draggable dividers.
struct LayoutView: View {
    @EnvironmentObject var app: AppState
    let node: LayoutNode
    let tab: Tab
    let workspace: Workspace
    /// Path of child indices from the layout root to this node (for resize).
    let path: [Int]

    // A roomy 12pt gutter is the grab zone; the visible line inside stays
    // slim until hovered (see DividerHandle).
    private let dividerThickness: CGFloat = 12

    var body: some View {
        switch node {
        case .pane(let paneID):
            if let pane = tab.pane(paneID) {
                PaneContainerView(pane: pane, tab: tab, workspace: workspace)
            } else {
                Color.clear
            }
        case .split(let axis, let children, let fractions):
            GeometryReader { geo in
                let totalExtent = axis == .horizontal ? geo.size.width : geo.size.height
                let usable = max(totalExtent - dividerThickness * CGFloat(children.count - 1), 0)
                splitBody(axis: axis, children: children, fractions: fractions, usable: usable, totalExtent: totalExtent)
            }
        }
    }

    @ViewBuilder
    private func splitBody(axis: SplitAxis, children: [LayoutNode], fractions: [Double],
                           usable: CGFloat, totalExtent: CGFloat) -> some View {
        let content = ForEach(Array(children.enumerated()), id: \.offset) { (idx, child) in
            let size = usable * CGFloat(fractions.indices.contains(idx) ? fractions[idx] : 1.0 / Double(children.count))
            Group {
                if axis == .horizontal {
                    LayoutView(node: child, tab: tab, workspace: workspace, path: path + [idx])
                        .frame(width: max(size, 40))
                } else {
                    LayoutView(node: child, tab: tab, workspace: workspace, path: path + [idx])
                        .frame(height: max(size, 40))
                }
            }
            if idx < children.count - 1 {
                DividerHandle(
                    axis: axis,
                    onDrag: { delta in
                        let fraction = Double(delta / max(totalExtent, 1))
                        app.resizeLayout(tabID: tab.id, splitPath: path, dividerIndex: idx, delta: fraction)
                    },
                    onEqualize: {
                        app.equalizeDivider(tabID: tab.id, splitPath: path, dividerIndex: idx)
                    }
                )
            }
        }
        if axis == .horizontal {
            HStack(spacing: 0) { content }
        } else {
            VStack(spacing: 0) { content }
        }
    }
}

/// The grab gutter between two panes. The whole 12pt zone is draggable (so
/// it's easy to catch), but the visible mark stays a slim line until you
/// hover — then it thickens and shows a grip so it's obviously grabbable.
/// Double-click evens out the two neighbours.
struct DividerHandle: View {
    let axis: SplitAxis
    let onDrag: (CGFloat) -> Void
    let onEqualize: () -> Void
    @State private var hovering = false
    @State private var dragging = false
    @State private var lastDelta: CGFloat = 0

    private var active: Bool { hovering || dragging }

    var body: some View {
        ZStack {
            // Invisible grab zone: the full gutter, always hit-testable.
            Color.clear.contentShape(Rectangle())
            // Visible line — slim normally, thicker + tinted when active.
            RoundedRectangle(cornerRadius: 1)
                .fill(active ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.14))
                .frame(width: axis == .horizontal ? (active ? 4 : 1.5) : nil,
                       height: axis == .vertical ? (active ? 4 : 1.5) : nil)
            // Grip dots, revealed on hover/drag.
            if active { grip }
        }
        .frame(width: axis == .horizontal ? 12 : nil,
               height: axis == .vertical ? 12 : nil)
        .onHover { h in
            hovering = h
            if h { (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() }
            else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    dragging = true
                    let delta = axis == .horizontal ? value.translation.width : value.translation.height
                    let inc = delta - lastDelta // incremental: subtract what we already applied
                    lastDelta = delta
                    onDrag(inc)
                }
                .onEnded { _ in lastDelta = 0; dragging = false }
        )
        .onTapGesture(count: 2) { onEqualize() }
        .help("Drag to resize · double-click to even out")
    }

    /// Three dots along the divider — a column for a left/right split, a row
    /// for a top/bottom split.
    @ViewBuilder
    private var grip: some View {
        let dots = ForEach(0..<3, id: \.self) { _ in
            Circle().fill(Color.white.opacity(0.9)).frame(width: 2.5, height: 2.5)
        }
        Group {
            if axis == .horizontal {
                VStack(spacing: 2.5) { dots }
            } else {
                HStack(spacing: 2.5) { dots }
            }
        }
    }
}

/// Pane chrome: a slim header (icon, title, Claude status, close) above the content.
struct PaneContainerView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var termCache = TerminalViewCache.shared
    let pane: Pane
    let tab: Tab
    let workspace: Workspace

    private var isFocused: Bool { tab.focusedPaneID == pane.id }
    private var paneStatus: PaneStatus? { app.paneStatuses[pane.shortID] }
    private var claudeStatus: ClaudeStatus { paneStatus?.state ?? .none }
    private var runState: PaneRunState? {
        pane.isTerminal ? termCache.runStates[pane.id] : nil
    }

    /// Live size readout: what this pane renders at, and — when tmux disagrees
    /// — what tmux thinks, in red with a one-click resync. Makes the drift
    /// that scrambles full-screen pickers visible instead of mysterious.
    @ViewBuilder
    private var sizeChip: some View {
        if let info = termCache.paneSizeInfo[pane.id] {
            if info.drifted {
                Button {
                    termCache.resyncSize(pane.id)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 8, weight: .bold))
                        Text("\(info.viewLabel)≠\(info.tmuxLabel)")
                            .font(.system(size: 9, design: .monospaced))
                    }
                    .foregroundStyle(.red)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.red.opacity(0.15))
                    .clipShape(Capsule())
                }
                .buttonStyle(.borderless)
                .help("Size drift — Claude is drawing for \(info.tmuxLabel) but this pane is \(info.viewLabel). Click to resync and rebuild.")
            } else {
                Text(info.viewLabel)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .help("Pane size (columns × rows) — matches tmux")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .overlay {
                    if let runState {
                        PaneStateOverlay(pane: pane, state: runState)
                    }
                }
        }
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isFocused ? Color.accentColor.opacity(0.8) : Color.black.opacity(0.2),
                        lineWidth: isFocused ? 1.5 : 1)
        )
        .padding(1)
    }

    private var kindIcon: String {
        switch pane.kind {
        case .claude: return "sparkle"
        case .shell: return "terminal"
        case .browser: return "globe"
        case .diff: return "plus.forwardslash.minus"
        }
    }

    private var statusColor: Color {
        switch claudeStatus {
        case .working: return .blue
        case .needsInput: return .orange
        case .done: return .green
        case .none: return .clear
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: kindIcon)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(pane.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isFocused ? .primary : .secondary)
                .lineLimit(1)
            if let branch = pane.worktreeBranch {
                Text("⎇ \(branch)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.purple.opacity(0.12))
                    .clipShape(Capsule())
                    .help("Isolated git worktree — removed on close if clean, branch kept")
            }
            if pane.isQueued {
                Text("on deck")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
            }
            if pane.kind == .claude && claudeStatus != .none {
                HStack(spacing: 3) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(statusLabel)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(statusColor.opacity(0.12))
                .clipShape(Capsule())
            }
            Spacer()
            if claudeStatus == .done, let item = app.backlogItem(forPane: pane), !item.isDone {
                Button {
                    app.markPaneItemDone(pane)
                } label: {
                    Label("mark \(item.itemID) done", systemImage: "checkmark.circle")
                        .font(.system(size: 9, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.green)
                .help("Claude finished — mark this backlog item done")
            }
            if pane.isTerminal {
                sizeChip
                Button {
                    app.addDiffPane(reviewing: pane)
                } label: {
                    Image(systemName: "plus.forwardslash.minus")
                        .font(.system(size: 9))
                }
                .buttonStyle(.borderless)
                .help("Review diff — what changed in this pane's folder")
            }
            Text(shortDirectory)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.head)
            Button {
                app.requestClosePane(pane.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.borderless)
            .help("Close pane (kills this tmux window)")
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(.bar)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            app.focusPane(pane.id)
            app.toggleZoom()
        }
        .onTapGesture { app.focusPane(pane.id) }
    }

    private var statusLabel: String {
        let base: String
        switch claudeStatus {
        case .working: base = "working"
        case .needsInput: base = "needs you"
        case .done: base = "done"
        case .none: return ""
        }
        var suffix = ""
        if let tokens = paneStatus?.contextTokens { suffix = " · \(tokenString(tokens))" }
        // Age matters: "needs you · 25m" is a different signal than "· 10s".
        if let since = paneStatus?.since, claudeStatus != .working {
            return "\(base) · \(ageString(from: since, to: app.now))\(suffix)"
        }
        return base + suffix
    }

    private var shortDirectory: String {
        let home = Config.home.path
        return pane.directory.hasPrefix(home)
            ? "~" + pane.directory.dropFirst(home.count)
            : pane.directory
    }

    @ViewBuilder
    private var content: some View {
        switch pane.kind {
        case .browser:
            BrowserPaneView(pane: pane)
        case .diff:
            DiffPaneView(pane: pane)
        case .claude, .shell:
            if pane.isQueued {
                QueuedPaneView(pane: pane)
            } else {
                TerminalPaneView(pane: pane, workspace: workspace) {
                    app.focusPane(pane.id)
                }
                // New tmux window (e.g. pane restart) ⇒ fresh NSView.
                .id(pane.tmuxWindowID)
            }
        }
    }
}

/// Overlay for a pane whose process or connection ended — actionable, and
/// never injected into the terminal buffer (that corrupts live TUIs).
struct PaneStateOverlay: View {
    @EnvironmentObject var app: AppState
    let pane: Pane
    let state: PaneRunState

    var body: some View {
        HStack(spacing: 8) {
            switch state {
            case .reconnecting:
                ProgressView().controlSize(.mini)
                Text("reconnecting…").font(.caption).foregroundStyle(.secondary)
            case .exited, .lost, .running:
                Image(systemName: "moon.zzz").font(.caption).foregroundStyle(.tertiary)
                Text(state == .lost ? "connection lost" : "process exited")
                    .font(.caption).foregroundStyle(.secondary)
                // Verifies against tmux first: a live session is never
                // touched — false alarms just clear and resync.
                Button("Restart") { app.restartPane(pane.id) }
                    .controlSize(.mini)
                    .help("Checks tmux first — if the session is actually alive, this only clears the banner and resyncs the display")
                Button("Close") {
                    app.requestClosePane(pane.id)
                }
                .controlSize(.mini)
            }
            Button {
                TerminalViewCache.shared.dismissState(pane.id)
            } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.borderless)
            .help("Dismiss — this pane is fine")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(10)
        .allowsHitTesting(true)
    }
}

/// Placeholder for an on-deck pane: shows what it's waiting for, the teed-up
/// prompt, and the two escape hatches (start now / isolate in a worktree).
struct QueuedPaneView: View {
    @EnvironmentObject var app: AppState
    let pane: Pane

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "hourglass")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            if let gate = app.gateTitle(for: pane) {
                Text("On deck — starts when “\(gate)” finishes")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("On deck")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let prompt = pane.queuedPrompt, !prompt.isEmpty {
                Text(TranscriptReader.condense(prompt, limit: 200))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            HStack {
                Button("Start Now") { app.startQueuedPane(pane.id) }
                Button("Run in Worktree Instead") { app.startQueuedPaneInWorktree(pane.id) }
                    .help("Isolated checkout + branch — safe to run alongside the working pane")
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.6))
        .onTapGesture { app.focusPane(pane.id) }
    }
}
