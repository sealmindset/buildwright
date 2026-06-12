import SwiftUI

/// Recursively renders the split-pane tree with draggable dividers.
struct LayoutView: View {
    @EnvironmentObject var app: AppState
    let node: LayoutNode
    let tab: Tab
    let workspace: Workspace
    /// Path of child indices from the layout root to this node (for resize).
    let path: [Int]

    private let dividerThickness: CGFloat = 5

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
                DividerHandle(axis: axis) { delta in
                    let fraction = Double(delta / max(totalExtent, 1))
                    app.resizeLayout(tabID: tab.id, splitPath: path, dividerIndex: idx, delta: fraction)
                }
            }
        }
        if axis == .horizontal {
            HStack(spacing: 0) { content }
        } else {
            VStack(spacing: 0) { content }
        }
    }
}

struct DividerHandle: View {
    let axis: SplitAxis
    let onDrag: (CGFloat) -> Void
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(hovering ? Color.accentColor.opacity(0.5) : Color.black.opacity(0.25))
            .frame(width: axis == .horizontal ? 5 : nil,
                   height: axis == .vertical ? 5 : nil)
            .contentShape(Rectangle())
            .onHover { h in
                hovering = h
                if h {
                    (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let delta = axis == .horizontal ? value.translation.width : value.translation.height
                        // Deliver incremental deltas: subtract what we already applied.
                        let inc = delta - lastDelta
                        lastDelta = delta
                        onDrag(inc)
                    }
                    .onEnded { _ in lastDelta = 0 }
            )
    }

    @State private var lastDelta: CGFloat = 0
}

/// Pane chrome: a slim header (icon, title, Claude status, close) above the content.
struct PaneContainerView: View {
    @EnvironmentObject var app: AppState
    let pane: Pane
    let tab: Tab
    let workspace: Workspace

    private var isFocused: Bool { tab.focusedPaneID == pane.id }
    private var paneStatus: PaneStatus? { app.paneStatuses[pane.shortID] }
    private var claudeStatus: ClaudeStatus { paneStatus?.state ?? .none }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
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
            Text(shortDirectory)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.head)
            Button {
                TerminalViewCache.shared.remove(pane.id)
                WebViewCache.shared.remove(pane)
                app.closePane(pane.id)
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
        // Age matters: "needs you · 25m" is a different signal than "· 10s".
        if let since = paneStatus?.since, claudeStatus != .working {
            return "\(base) · \(ageString(from: since, to: app.now))"
        }
        return base
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
        case .claude, .shell:
            if pane.isQueued {
                QueuedPaneView(pane: pane)
            } else {
                TerminalPaneView(pane: pane, workspace: workspace) {
                    app.focusPane(pane.id)
                }
            }
        }
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
