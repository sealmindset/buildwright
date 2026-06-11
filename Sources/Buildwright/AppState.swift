import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var workspaces: [Workspace] = []
    @Published var activeWorkspaceID: UUID?
    @Published var sidebarVisible: Bool = true
    @Published var cvrPath: String = Config.defaultCVRPath
    @Published var claudeStatuses: [String: ClaudeStatus] = [:] // pane shortID -> status
    @Published var showNewWorkspaceSheet = false
    @Published var showCVRSheet = false

    let tmux = TmuxManager.shared
    let backlog = BacklogStore()
    private var statusMonitor: ClaudeStatusMonitor?

    var activeWorkspace: Workspace? {
        get { workspaces.first { $0.id == activeWorkspaceID } ?? workspaces.first }
    }

    var activeWorkspaceIndex: Int? {
        workspaces.firstIndex { $0.id == (activeWorkspaceID ?? workspaces.first?.id) }
    }

    // MARK: Lifecycle

    func bootstrap() {
        Config.ensureDirectories()
        HooksInstaller.installIfNeeded()
        BWCLIInstaller.installIfNeeded()

        if let saved = StateStore.shared.load() {
            workspaces = saved.workspaces
            activeWorkspaceID = saved.activeWorkspaceID ?? saved.workspaces.first?.id
            if let path = saved.cvrPath { cvrPath = path }
            sidebarVisible = saved.sidebarVisible ?? true
        }
        // Remove leftover display helpers from a previous run before any
        // pane attaches (they'll be recreated fresh on demand).
        tmux.client.cleanupStaleGroupedSessions()
        if workspaces.isEmpty {
            showNewWorkspaceSheet = true
        } else {
            reconcileAll()
        }
        backlog.startWatching()
        let monitor = ClaudeStatusMonitor { [weak self] statuses in
            Task { @MainActor in self?.applyStatuses(statuses) }
        }
        monitor.start()
        statusMonitor = monitor
    }

    private func reconcileAll() {
        for i in workspaces.indices {
            let dead = tmux.reconcile(workspace: workspaces[i])
            guard !dead.isEmpty else { continue }
            for t in workspaces[i].tabs.indices {
                let deadInTab = workspaces[i].tabs[t].panes.filter { dead.contains($0.id) }.map(\.id)
                for paneID in deadInTab {
                    workspaces[i].tabs[t].layout = workspaces[i].tabs[t].layout?.removing(paneID)
                    workspaces[i].tabs[t].panes.removeAll { $0.id == paneID }
                }
            }
        }
        persist()
    }

    func persist() {
        StateStore.shared.save(AppPersistedState(
            workspaces: workspaces,
            activeWorkspaceID: activeWorkspaceID,
            cvrPath: cvrPath,
            sidebarVisible: sidebarVisible
        ))
    }

    private func applyStatuses(_ statuses: [String: ClaudeStatus]) {
        let previous = claudeStatuses
        claudeStatuses = statuses
        // Notify when an unfocused pane flips to needsInput or done.
        guard let ws = activeWorkspace, let tab = ws.activeTab else { return }
        let focusedShortID = tab.focusedPaneID.flatMap { tab.pane($0)?.shortID }
        for (shortID, status) in statuses {
            guard previous[shortID] != status, shortID != focusedShortID else { continue }
            guard let title = paneTitle(forShortID: shortID) else { continue }
            switch status {
            case .needsInput:
                ShellExec.notify(title: "Claude needs you", body: "\(title) is waiting for your input")
            case .done:
                ShellExec.notify(title: "Claude finished", body: "\(title) is done")
            default: break
            }
        }
    }

    private func paneTitle(forShortID shortID: String) -> String? {
        for ws in workspaces {
            for tab in ws.tabs {
                if let pane = tab.panes.first(where: { $0.shortID == shortID }) {
                    return "\(ws.name) · \(pane.title)"
                }
            }
        }
        return nil
    }

    // MARK: Workspace management

    func createWorkspace(name: String, baseRepo: String) {
        var ws = Workspace(name: name, baseRepo: baseRepo)
        let tab = Tab(name: "main")
        ws.tabs = [tab]
        ws.activeTabID = tab.id
        workspaces.append(ws)
        activeWorkspaceID = ws.id
        tmux.ensureWorkspaceSession(ws)
        // Start with one Claude pane in the base repo — the typical first move.
        addPane(kind: .claude)
        persist()
    }

    func deleteWorkspace(_ id: UUID, killSessions: Bool) {
        guard let ws = workspaces.first(where: { $0.id == id }) else { return }
        if killSessions {
            for tab in ws.tabs {
                for pane in tab.panes where pane.kind != .browser {
                    tmux.destroyWindow(for: pane, in: ws)
                }
            }
            tmux.client.killSession(name: ws.tmuxSessionName)
        }
        workspaces.removeAll { $0.id == id }
        if activeWorkspaceID == id { activeWorkspaceID = workspaces.first?.id }
        persist()
    }

    func switchWorkspace(_ id: UUID) {
        activeWorkspaceID = id
        if let ws = activeWorkspace {
            tmux.ensureWorkspaceSession(ws)
        }
        persist()
    }

    // MARK: Tab management

    func addTab() {
        guard let wi = activeWorkspaceIndex else { return }
        let tab = Tab(name: "tab \(workspaces[wi].tabs.count + 1)")
        workspaces[wi].tabs.append(tab)
        workspaces[wi].activeTabID = tab.id
        persist()
    }

    func closeTab(_ tabID: UUID) {
        guard let wi = activeWorkspaceIndex,
              let ti = workspaces[wi].tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let ws = workspaces[wi]
        for pane in workspaces[wi].tabs[ti].panes where pane.kind != .browser {
            tmux.destroyWindow(for: pane, in: ws)
        }
        workspaces[wi].tabs.remove(at: ti)
        if workspaces[wi].tabs.isEmpty {
            let tab = Tab(name: "main")
            workspaces[wi].tabs = [tab]
        }
        if workspaces[wi].activeTabID == tabID {
            workspaces[wi].activeTabID = workspaces[wi].tabs.first?.id
        }
        persist()
    }

    func selectTab(_ tabID: UUID) {
        guard let wi = activeWorkspaceIndex else { return }
        workspaces[wi].activeTabID = tabID
        persist()
    }

    // MARK: Pane management

    /// Add a pane. If a pane is focused it splits beside it along `axis`;
    /// otherwise it fills the tab or splits the whole layout.
    func addPane(kind: PaneKind, axis: SplitAxis = .horizontal, directory: String? = nil,
                 title: String? = nil, prompt: String? = nil, url: String? = nil) {
        guard let wi = activeWorkspaceIndex else { return }
        let ws = workspaces[wi]
        guard let ti = ws.tabs.firstIndex(where: { $0.id == (ws.activeTabID ?? ws.tabs.first?.id) }) else { return }

        let dir = directory ?? ws.baseRepo
        let defaultTitle: String
        switch kind {
        case .claude: defaultTitle = "claude"
        case .shell: defaultTitle = "shell"
        case .browser: defaultTitle = "browser"
        }
        var pane = Pane(kind: kind, title: title ?? defaultTitle, directory: dir,
                        url: kind == .browser ? (url ?? "https://docs.anthropic.com") : nil)

        if kind != .browser {
            guard let windowID = tmux.createWindow(for: pane, in: ws, prompt: prompt) else {
                ShellExec.notify(title: "Buildwright", body: "Could not create tmux window — is tmux installed?")
                return
            }
            pane.tmuxWindowID = windowID
        }

        workspaces[wi].tabs[ti].panes.append(pane)
        if let layout = workspaces[wi].tabs[ti].layout,
           let target = workspaces[wi].tabs[ti].focusedPaneID, layout.contains(target) {
            workspaces[wi].tabs[ti].layout = layout.splitting(target: target, with: pane.id, axis: axis)
        } else if let layout = workspaces[wi].tabs[ti].layout {
            // No focus: append at top level.
            if case .split(let a, var children, var fractions) = layout, a == axis {
                children.append(.pane(pane.id))
                let share = 1.0 / Double(children.count)
                fractions = Array(repeating: share, count: children.count)
                workspaces[wi].tabs[ti].layout = .split(axis: a, children: children, fractions: fractions)
            } else {
                workspaces[wi].tabs[ti].layout = .split(axis: axis, children: [layout, .pane(pane.id)], fractions: [0.5, 0.5])
            }
        } else {
            workspaces[wi].tabs[ti].layout = .pane(pane.id)
        }
        workspaces[wi].tabs[ti].focusedPaneID = pane.id
        persist()
    }

    enum DockSide { case left, right }

    /// Dock a browser pane to the far left or right of the whole tab layout
    /// (a 30% column), regardless of current focus.
    func addBrowserDocked(side: DockSide, url: String? = nil) {
        guard let wi = activeWorkspaceIndex else { return }
        let ws = workspaces[wi]
        guard let ti = ws.tabs.firstIndex(where: { $0.id == (ws.activeTabID ?? ws.tabs.first?.id) }) else { return }
        let pane = Pane(kind: .browser, title: "browser", directory: ws.baseRepo,
                        url: url ?? "https://docs.anthropic.com")
        workspaces[wi].tabs[ti].panes.append(pane)
        if let layout = workspaces[wi].tabs[ti].layout {
            let children: [LayoutNode] = side == .left ? [.pane(pane.id), layout] : [layout, .pane(pane.id)]
            let fractions: [Double] = side == .left ? [0.3, 0.7] : [0.7, 0.3]
            workspaces[wi].tabs[ti].layout = .split(axis: .horizontal, children: children, fractions: fractions)
        } else {
            workspaces[wi].tabs[ti].layout = .pane(pane.id)
        }
        workspaces[wi].tabs[ti].focusedPaneID = pane.id
        persist()
    }

    func closePane(_ paneID: UUID) {
        guard let wi = activeWorkspaceIndex else { return }
        let ws = workspaces[wi]
        for ti in workspaces[wi].tabs.indices {
            guard let pane = workspaces[wi].tabs[ti].panes.first(where: { $0.id == paneID }) else { continue }
            if pane.kind != .browser {
                tmux.destroyWindow(for: pane, in: ws)
                claudeStatuses.removeValue(forKey: pane.shortID)
            }
            workspaces[wi].tabs[ti].layout = workspaces[wi].tabs[ti].layout?.removing(paneID)
            workspaces[wi].tabs[ti].panes.removeAll { $0.id == paneID }
            if workspaces[wi].tabs[ti].focusedPaneID == paneID {
                workspaces[wi].tabs[ti].focusedPaneID = workspaces[wi].tabs[ti].panes.first?.id
            }
        }
        persist()
    }

    func focusPane(_ paneID: UUID) {
        guard let wi = activeWorkspaceIndex else { return }
        let ws = workspaces[wi]
        guard let ti = workspaces[wi].tabs.firstIndex(where: { $0.id == (ws.activeTabID ?? ws.tabs.first?.id) }) else { return }
        workspaces[wi].tabs[ti].focusedPaneID = paneID
    }

    func resizeLayout(tabID: UUID, splitPath: [Int], dividerIndex: Int, delta: Double) {
        guard let wi = activeWorkspaceIndex,
              let ti = workspaces[wi].tabs.firstIndex(where: { $0.id == tabID }),
              let layout = workspaces[wi].tabs[ti].layout else { return }
        workspaces[wi].tabs[ti].layout = layout.resizing(splitPath: splitPath, dividerIndex: dividerIndex, delta: delta)
        persist()
    }

    func updateBrowserURL(paneID: UUID, url: String) {
        guard let wi = activeWorkspaceIndex else { return }
        for ti in workspaces[wi].tabs.indices {
            if let pi = workspaces[wi].tabs[ti].panes.firstIndex(where: { $0.id == paneID }) {
                workspaces[wi].tabs[ti].panes[pi].url = url
            }
        }
        persist()
    }

    // MARK: Backlog → Claude

    /// The killer feature: spawn a Claude pane preloaded with a backlog item.
    func startBacklogItem(_ item: BacklogItem) {
        let prompt = "/backlog start \(item.itemID)"
        addPane(kind: .claude, title: item.itemID, prompt: prompt)
    }

    // MARK: Backlog filters (per workspace)

    var activeFilters: BacklogFilters {
        get { activeWorkspace?.backlogFilters ?? BacklogFilters() }
    }

    func updateFilters(_ transform: (inout BacklogFilters) -> Void) {
        guard let wi = activeWorkspaceIndex else { return }
        transform(&workspaces[wi].backlogFilters)
        persist()
    }
}
