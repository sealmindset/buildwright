import SwiftUI

/// ⌘K — type three letters, hit return, be there. Indexes panes, workspaces,
/// tabs, backlog stories, and app actions.
struct PaletteItem: Identifiable {
    let id: String
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    /// Lower is better; nil means filtered out.
    func score(query: String) -> Int? {
        if query.isEmpty { return 3 }
        let q = query.lowercased()
        let t = title.lowercased()
        let s = subtitle.lowercased()
        if t.hasPrefix(q) { return 0 }
        if t.contains(q) { return 1 }
        if s.contains(q) { return 2 }
        // Initials/word-prefix match: "e4" hits "E04", "nb" hits "New Browser".
        let words = (t + " " + s).split(separator: " ")
        if words.contains(where: { $0.hasPrefix(q) }) { return 2 }
        return nil
    }
}

struct CommandPaletteView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Jump to pane, workspace, backlog item, or action…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($fieldFocused)
                    .onSubmit { execute(at: selection) }
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { (idx, item) in
                            row(item, selected: idx == selection)
                                .id(idx)
                                .onTapGesture { execute(at: idx) }
                        }
                        if filtered.isEmpty {
                            Text("No matches")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .padding(20)
                        }
                    }
                    .padding(6)
                }
                .frame(height: 320)
                .onChange(of: selection) { _, newValue in
                    proxy.scrollTo(newValue, anchor: nil)
                }
            }
        }
        .frame(width: 560)
        .onAppear { fieldFocused = true }
        .onChange(of: query) { _, _ in selection = 0 }
        .onKeyPress(.downArrow) {
            if selection < filtered.count - 1 { selection += 1 }
            return .handled
        }
        .onKeyPress(.upArrow) {
            if selection > 0 { selection -= 1 }
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .font(.system(size: 12))
                .foregroundStyle(selected ? Color.white : .secondary)
                .frame(width: 18)
            Text(item.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? Color.white : .primary)
                .lineLimit(1)
            Spacer()
            Text(item.subtitle)
                .font(.system(size: 11))
                .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary.opacity(0.6))
                .lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(selected ? Color.accentColor : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    private func execute(at index: Int) {
        guard filtered.indices.contains(index) else { return }
        let item = filtered[index]
        dismiss()
        // Run after the sheet closes so focus lands where the action puts it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { item.action() }
    }

    private var filtered: [PaletteItem] {
        allItems
            .compactMap { item -> (PaletteItem, Int)? in
                guard let s = item.score(query: query) else { return nil }
                return (item, s)
            }
            .sorted { a, b in a.1 == b.1 ? a.0.title < b.0.title : a.1 < b.1 }
            .prefix(30)
            .map { $0.0 }
    }

    private var allItems: [PaletteItem] {
        var items: [PaletteItem] = []

        // Panes — jump anywhere.
        for ws in app.workspaces {
            for tab in ws.tabs {
                for pane in tab.panes {
                    let status = app.paneStatuses[pane.shortID]
                    let badge: String
                    switch status?.state {
                    case .needsInput: badge = "◉ needs you · "
                    case .done: badge = "✓ done · "
                    case .working: badge = "● working · "
                    default: badge = ""
                    }
                    items.append(PaletteItem(
                        id: "pane-\(pane.id)",
                        icon: pane.kind == .claude ? "sparkle" : pane.kind == .shell ? "terminal" : "globe",
                        title: pane.title,
                        subtitle: "\(badge)\(ws.name) · \(tab.name)",
                        action: { app.jump(to: AppState.AttentionEntry(
                            workspaceID: ws.id, workspaceName: ws.name,
                            tabID: tab.id, pane: pane,
                            status: status ?? PaneStatus(state: .none, since: Date()))) }
                    ))
                }
            }
        }

        // Workspaces.
        for (idx, ws) in app.workspaces.enumerated() {
            items.append(PaletteItem(
                id: "ws-\(ws.id)", icon: "folder",
                title: "Switch to \(ws.name)",
                subtitle: idx < 9 ? "workspace · ⌘⌥\(idx + 1)" : "workspace",
                action: { app.switchWorkspace(ws.id) }
            ))
        }

        // Bookmarks — the active workspace's own plus the shared set.
        if let ws = app.activeWorkspace {
            for bm in ws.bookmarks ?? [] {
                items.append(PaletteItem(
                    id: "bm-\(bm.id)", icon: "bookmark",
                    title: bm.title,
                    subtitle: "bookmark · \(ws.name)",
                    action: { app.openBookmark(bm) }
                ))
            }
        }
        for bm in app.sharedBookmarks {
            items.append(PaletteItem(
                id: "bm-shared-\(bm.id)", icon: "bookmark",
                title: bm.title,
                subtitle: "bookmark · shared",
                action: { app.openBookmark(bm) }
            ))
        }

        // Backlog stories — Start in a Claude pane.
        for group in app.backlog.epics where !group.epic.isDone {
            for story in group.stories where !story.isDone {
                items.append(PaletteItem(
                    id: "bl-\(story.itemID)", icon: "play.fill",
                    title: "Start \(story.itemID)",
                    subtitle: story.title,
                    action: { app.startBacklogItem(story) }
                ))
            }
        }

        // Actions.
        let actions: [(String, String, String, () -> Void)] = [
            ("act-claude", "sparkle", "New Claude pane", { app.addPane(kind: .claude) }),
            ("act-shell", "terminal", "New shell pane", { app.addPane(kind: .shell) }),
            ("act-browser", "globe", "New browser pane", { app.addPane(kind: .browser) }),
            ("act-breakfix", "wrench.adjustable", "New Breakfix pane", { app.addBreakfixPane() }),
            ("act-feature", "wand.and.stars", "New Feature pane", { app.addFeaturePane() }),
            ("act-tab", "plus.rectangle", "New tab", { app.addTab() }),
            ("act-ws", "folder.badge.plus", "New workspace", { app.showNewWorkspaceSheet = true }),
            ("act-cvr", "record.circle", "CVR recording session", { app.showCVRSheet = true }),
            ("act-capture", "sparkle.magnifyingglass", "Capture to backlog", { app.showScrumCapture = true }),
            ("act-reconcile", "checklist.checked", "Reconcile board ↔ code (AI)", { app.showReconcileSheet = true }),
            ("act-sidebar", "sidebar.left", "Toggle backlog sidebar", { app.sidebarVisible.toggle(); app.persist() }),
            ("act-jump", "bolt.fill", "Jump to next needing you", { app.jumpToNextAttention() })
        ]
        for (id, icon, title, action) in actions {
            items.append(PaletteItem(id: id, icon: icon, title: title, subtitle: "action", action: action))
        }
        return items
    }
}
