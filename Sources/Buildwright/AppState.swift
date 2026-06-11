import Foundation
import SwiftUI
import AppKit

@MainActor
final class AppState: ObservableObject {
    @Published var workspaces: [Workspace] = []
    @Published var activeWorkspaceID: UUID?
    @Published var sharedBookmarks: [Bookmark] = []
    @Published var sidebarVisible: Bool = true
    @Published var cvrPath: String = Config.defaultCVRPath
    @Published var paneStatuses: [String: PaneStatus] = [:] // pane shortID -> status+since
    @Published var now = Date() // ticker so status ages refresh
    @Published var showNewWorkspaceSheet = false
    @Published var showCVRSheet = false
    @Published var showPalette = false

    /// Convenience: just the state for a pane.
    func claudeState(_ shortID: String) -> ClaudeStatus {
        paneStatuses[shortID]?.state ?? .none
    }

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
            // Pre-0.4 state files predate browser tabs — seed one tab per browser pane.
            for wi in workspaces.indices {
                for ti in workspaces[wi].tabs.indices {
                    for pi in workspaces[wi].tabs[ti].panes.indices {
                        workspaces[wi].tabs[ti].panes[pi].normalizeBrowserTabs()
                    }
                }
            }
            activeWorkspaceID = saved.activeWorkspaceID ?? saved.workspaces.first?.id
            if let path = saved.cvrPath { cvrPath = path }
            sidebarVisible = saved.sidebarVisible ?? true
            if let p = saved.breakfixPrompt, !p.isEmpty { breakfixPrompt = p }
            if let p = saved.featurePrompt, !p.isEmpty { featurePrompt = p }
            claudeSkipPermissions = saved.claudeSkipPermissions ?? true
            sharedBookmarks = saved.sharedBookmarks ?? []
            browserPrivateByDefault = saved.browserPrivateByDefault ?? true
        }
        tmux.claudeSkipPermissions = claudeSkipPermissions
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
        // Refresh visible status ages twice a minute.
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        // Hooks keep writing while the app is closed, so after the first
        // status scan lands we can say what happened since last quit.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if let ws = self.activeWorkspace { self.showReentry(for: ws) }
        }
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
            sidebarVisible: sidebarVisible,
            breakfixPrompt: breakfixPrompt,
            featurePrompt: featurePrompt,
            claudeSkipPermissions: claudeSkipPermissions,
            sharedBookmarks: sharedBookmarks,
            browserPrivateByDefault: browserPrivateByDefault
        ))
    }

    private func applyStatuses(_ statuses: [String: PaneStatus]) {
        let previous = paneStatuses
        paneStatuses = statuses
        now = Date()
        if previous != statuses {
            snapshotActiveWorkspace()
            persist()
        }
        // Notify when an unfocused pane flips to needsInput or done.
        guard let ws = activeWorkspace, let tab = ws.activeTab else { return }
        let focusedShortID = tab.focusedPaneID.flatMap { tab.pane($0)?.shortID }
        for (shortID, status) in statuses {
            guard previous[shortID]?.state != status.state, shortID != focusedShortID else { continue }
            guard let title = paneTitle(forShortID: shortID) else { continue }
            switch status.state {
            case .needsInput:
                ShellExec.notify(title: "Claude needs you", body: "\(title) is waiting for your input")
            case .done:
                ShellExec.notify(title: "Claude finished", body: "\(title) is done")
            default: break
            }
        }
    }

    // MARK: Context snapshots & re-entry

    struct ReentryNotice: Equatable {
        var workspaceName: String
        var awaySince: Date
        var lines: [String]
        var backlogItemID: String?
    }

    @Published var reentryNotice: ReentryNotice?

    /// Pure diff: what changed for this workspace's Claude panes while away.
    nonisolated static func reentryLines(
        snapshot: [String: PaneStatus],
        current: [String: PaneStatus],
        panes: [(shortID: String, title: String)],
        now: Date
    ) -> [String] {
        var lines: [String] = []
        for (shortID, title) in panes {
            let before = snapshot[shortID]?.state
            guard let after = current[shortID] else {
                if before != nil && before != .done {
                    lines.append("“\(title)” ended while you were away")
                }
                continue
            }
            guard before != after.state else { continue }
            switch after.state {
            case .done:
                lines.append("“\(title)” finished (\(ageString(from: after.since, to: now)) ago)")
            case .needsInput:
                lines.append("“\(title)” is waiting on you (\(ageString(from: after.since, to: now)))")
            case .working:
                lines.append("“\(title)” is still working")
            case .none:
                break
            }
        }
        return lines
    }

    /// Record what the active workspace looked like right now (called when
    /// statuses change and when switching away).
    private func snapshotActiveWorkspace() {
        guard let wi = activeWorkspaceIndex else { return }
        var snap: [String: PaneStatus] = [:]
        for (shortID, _) in workspaces[wi].claudePanes {
            if let s = paneStatuses[shortID] { snap[shortID] = s }
        }
        if workspaces[wi].lastSnapshot != snap {
            workspaces[wi].lastSnapshot = snap
        }
        workspaces[wi].lastSeenAt = Date()
    }

    /// Build the "while you were away" strip for a workspace being entered.
    private func showReentry(for ws: Workspace) {
        guard let awaySince = ws.lastSeenAt,
              Date().timeIntervalSince(awaySince) > 120 else {
            reentryNotice = nil
            return
        }
        let lines = Self.reentryLines(
            snapshot: ws.lastSnapshot ?? [:],
            current: paneStatuses,
            panes: ws.claudePanes,
            now: now
        )
        if lines.isEmpty && ws.activeBacklogItemID == nil {
            reentryNotice = nil
            return
        }
        reentryNotice = ReentryNotice(
            workspaceName: ws.name,
            awaySince: awaySince,
            lines: lines,
            backlogItemID: ws.activeBacklogItemID
        )
    }

    func dismissReentry() { reentryNotice = nil }

    // MARK: Attention queue

    struct AttentionEntry: Identifiable {
        var id: UUID { pane.id }
        let workspaceID: UUID
        let workspaceName: String
        let tabID: UUID
        let pane: Pane
        let status: PaneStatus
    }

    /// Panes waiting on you, most urgent first: needs-input (oldest first),
    /// then done (oldest first). Working panes are excluded — they don't
    /// need attention yet.
    var attentionQueue: [AttentionEntry] {
        var entries: [AttentionEntry] = []
        for ws in workspaces {
            for tab in ws.tabs {
                for pane in tab.panes where pane.kind == .claude {
                    guard let status = paneStatuses[pane.shortID],
                          status.state == .needsInput || status.state == .done else { continue }
                    entries.append(AttentionEntry(
                        workspaceID: ws.id, workspaceName: ws.name,
                        tabID: tab.id, pane: pane, status: status))
                }
            }
        }
        return entries.sorted { a, b in
            if a.status.state != b.status.state {
                return a.status.state == .needsInput // needsInput outranks done
            }
            return a.status.since < b.status.since // oldest wait first
        }
    }

    var needsInputCount: Int { attentionQueue.filter { $0.status.state == .needsInput }.count }
    var doneCount: Int { attentionQueue.filter { $0.status.state == .done }.count }
    var workingCount: Int {
        paneStatuses.values.filter { $0.state == .working }.count
    }

    /// ⌘J — jump to the pane that has been waiting on you the longest.
    func jumpToNextAttention() {
        guard let entry = attentionQueue.first else { return }
        jump(to: entry)
    }

    func jump(to entry: AttentionEntry) {
        if activeWorkspaceID != entry.workspaceID {
            switchWorkspace(entry.workspaceID)
        }
        if let wi = activeWorkspaceIndex {
            workspaces[wi].activeTabID = entry.tabID
            if let ti = workspaces[wi].tabs.firstIndex(where: { $0.id == entry.tabID }) {
                workspaces[wi].tabs[ti].focusedPaneID = entry.pane.id
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        persist()
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
        snapshotActiveWorkspace() // record the world we're leaving
        activeWorkspaceID = id
        if let ws = activeWorkspace {
            tmux.ensureWorkspaceSession(ws)
            showReentry(for: ws)
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
        if kind == .browser { pane.browserPrivate = browserPrivateByDefault }

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
        var pane = Pane(kind: .browser, title: "browser", directory: ws.baseRepo,
                        url: url ?? "https://docs.anthropic.com")
        pane.browserPrivate = browserPrivateByDefault
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
                paneStatuses.removeValue(forKey: pane.shortID)
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

    /// ⌥⌘-arrows: move focus to the spatially nearest pane in a direction.
    func movePaneFocus(_ direction: FocusDirection) {
        guard let ws = activeWorkspace, let tab = ws.activeTab,
              let layout = tab.layout else { return }
        let from = tab.focusedPaneID ?? layout.paneIDs.first
        guard let from else { return }
        if let target = layout.neighbor(of: from, direction: direction) {
            focusPane(target)
        }
    }

    /// ⌘⌥1-9: switch workspace by position.
    func switchWorkspace(at index: Int) {
        guard workspaces.indices.contains(index) else { return }
        switchWorkspace(workspaces[index].id)
    }

    func resizeLayout(tabID: UUID, splitPath: [Int], dividerIndex: Int, delta: Double) {
        guard let wi = activeWorkspaceIndex,
              let ti = workspaces[wi].tabs.firstIndex(where: { $0.id == tabID }),
              let layout = workspaces[wi].tabs[ti].layout else { return }
        workspaces[wi].tabs[ti].layout = layout.resizing(splitPath: splitPath, dividerIndex: dividerIndex, delta: delta)
        persist()
    }

    // MARK: Browser tabs

    private func withPane(_ paneID: UUID, _ body: (inout Pane) -> Void) {
        for wi in workspaces.indices {
            for ti in workspaces[wi].tabs.indices {
                if let pi = workspaces[wi].tabs[ti].panes.firstIndex(where: { $0.id == paneID }) {
                    body(&workspaces[wi].tabs[ti].panes[pi])
                }
            }
        }
        persist()
    }

    @discardableResult
    func addBrowserTab(paneID: UUID, url: String? = nil, activate: Bool = true) -> BrowserTab {
        let tab = BrowserTab(url: url)
        withPane(paneID) { $0.addBrowserTab(tab, activate: activate) }
        return tab
    }

    /// Closing the last tab closes the whole pane (standard browser behavior).
    func closeBrowserTab(paneID: UUID, tabID: UUID) {
        var closedLast = false
        withPane(paneID) { closedLast = $0.closeBrowserTab(tabID) }
        WebViewCache.shared.removeTab(tabID)
        if closedLast { closePane(paneID) }
    }

    func selectBrowserTab(paneID: UUID, tabID: UUID) {
        withPane(paneID) { $0.selectBrowserTab(tabID) }
    }

    func updateBrowserTab(paneID: UUID, tabID: UUID, url: String?, title: String?) {
        withPane(paneID) { $0.updateBrowserTab(tabID, url: url, title: title) }
    }

    // MARK: Bookmarks

    /// The active workspace's own bookmarks (shared ones live in sharedBookmarks).
    var workspaceBookmarks: [Bookmark] { activeWorkspace?.bookmarks ?? [] }

    func isSharedBookmark(_ id: UUID) -> Bool {
        sharedBookmarks.contains { $0.id == id }
    }

    /// Exact-URL lookup in what the active workspace can see (own + shared).
    func bookmark(forURL url: String) -> Bookmark? {
        workspaceBookmarks.first { $0.url == url } ?? sharedBookmarks.first { $0.url == url }
    }

    /// Create or update a bookmark. Passing an existing id with a different
    /// `shared` value moves it between the workspace and the shared list.
    func saveBookmark(id: UUID? = nil, title: String, url: String, shared: Bool) {
        if let id {
            if shared, let i = sharedBookmarks.firstIndex(where: { $0.id == id }) {
                sharedBookmarks[i].title = title
                sharedBookmarks[i].url = url
                persist()
                return
            }
            if !shared, let wi = activeWorkspaceIndex,
               let i = (workspaces[wi].bookmarks ?? []).firstIndex(where: { $0.id == id }) {
                workspaces[wi].bookmarks?[i].title = title
                workspaces[wi].bookmarks?[i].url = url
                persist()
                return
            }
            removeBookmarkEverywhere(id) // scope changed: pull it out, re-add below
        }
        let bm = Bookmark(id: id ?? UUID(), title: title, url: url)
        if shared {
            sharedBookmarks.append(bm)
        } else if let wi = activeWorkspaceIndex {
            workspaces[wi].bookmarks = (workspaces[wi].bookmarks ?? []) + [bm]
        }
        persist()
    }

    func deleteBookmark(_ id: UUID) {
        removeBookmarkEverywhere(id)
        persist()
    }

    private func removeBookmarkEverywhere(_ id: UUID) {
        sharedBookmarks.removeAll { $0.id == id }
        for wi in workspaces.indices {
            workspaces[wi].bookmarks?.removeAll { $0.id == id }
        }
    }

    /// Open a bookmark in the focused (or any) browser pane's current tab —
    /// in a new tab when asked, or in a fresh browser pane when none exists.
    func openBookmark(_ bm: Bookmark, inNewTab: Bool = false) {
        guard let ws = activeWorkspace, let tab = ws.activeTab else { return }
        var target: Pane?
        if let f = tab.focusedPaneID, let p = tab.pane(f), p.kind == .browser { target = p }
        else { target = tab.panes.first { $0.kind == .browser } }
        guard let pane = target else {
            addPane(kind: .browser, url: bm.url)
            return
        }
        if inNewTab || pane.activeBrowserTab == nil {
            addBrowserTab(paneID: pane.id, url: bm.url)
        } else if let tabID = pane.activeBrowserTab?.id {
            updateBrowserTab(paneID: pane.id, tabID: tabID, url: bm.url, title: nil)
            if let wv = WebViewCache.shared.existing(tabID), let url = URL(string: bm.url) {
                wv.load(URLRequest(url: url))
            }
        }
        focusPane(pane.id)
    }

    // MARK: Backlog → Claude

    /// The killer feature: spawn a Claude pane preloaded with a backlog item.
    func startBacklogItem(_ item: BacklogItem) {
        let prompt = "/backlog start \(item.itemID)"
        addPane(kind: .claude, title: item.itemID, prompt: prompt)
        if let wi = activeWorkspaceIndex {
            workspaces[wi].activeBacklogItemID = item.itemID
            persist()
        }
    }

    // MARK: Ship templates (Breakfix / Feature)

    static let defaultBreakfixPrompt = """
    BREAKFIX MODE — minimal, shippable fix only. \
    1) Create a branch fix/<short-slug> from the default branch. \
    2) Reproduce the bug and capture evidence before changing anything. \
    3) Make the smallest fix that resolves it — no refactors, no unrelated changes. \
    4) Run the project's tests and verify the fix plus no regressions. \
    5) Summarize root cause and the exact change, then STOP before any deploy or merge. \
    Ask me for the bug description now.
    """

    static let defaultFeaturePrompt = """
    FEATURE MODE — add capability without destabilizing production. \
    1) Create a branch feat/<short-slug>. \
    2) Restate the request and list existing behavior that could be affected. \
    3) Implement with tests. \
    4) Run the full test suite and verify zero regressions. \
    5) Update CHANGELOG.md, then STOP and recommend saving the work (no deploys). \
    Ask me for the feature description now.
    """

    @Published var breakfixPrompt: String = AppState.defaultBreakfixPrompt
    @Published var featurePrompt: String = AppState.defaultFeaturePrompt

    /// Claude panes launch with --dangerously-skip-permissions when true.
    @Published var claudeSkipPermissions: Bool = true {
        didSet {
            tmux.claudeSkipPermissions = claudeSkipPermissions
            persist()
        }
    }

    /// New browser panes start as private sessions (nothing saved to disk).
    @Published var browserPrivateByDefault: Bool = true {
        didSet { persist() }
    }

    /// Flip one browser pane between private and persistent. Its web views are
    /// dropped so they recreate against the other data store (tabs reload).
    func toggleBrowserPrivacy(paneID: UUID) {
        let appDefault = browserPrivateByDefault
        var toggled: Pane?
        withPane(paneID) { pane in
            guard pane.kind == .browser else { return }
            pane.browserPrivate = !pane.isPrivateBrowsing(appDefault: appDefault)
            toggled = pane
        }
        if let pane = toggled { WebViewCache.shared.remove(pane) }
    }

    func addBreakfixPane() {
        addPane(kind: .claude, title: "breakfix", prompt: breakfixPrompt)
    }

    func addFeaturePane() {
        addPane(kind: .claude, title: "feature", prompt: featurePrompt)
    }

    /// Close the loop: a Started pane (title == backlog item id) whose Claude
    /// is done can mark its item done in one click.
    func backlogItem(forPane pane: Pane) -> BacklogItem? {
        guard pane.kind == .claude else { return nil }
        for group in backlog.epics {
            if group.epic.itemID == pane.title { return group.epic }
            if let story = group.stories.first(where: { $0.itemID == pane.title }) { return story }
        }
        return nil
    }

    func markPaneItemDone(_ pane: Pane) {
        guard let item = backlogItem(forPane: pane), !item.isDone else { return }
        backlog.setStatus(item, to: "done")
        if let wi = activeWorkspaceIndex, workspaces[wi].activeBacklogItemID == item.itemID {
            workspaces[wi].activeBacklogItemID = nil
            persist()
        }
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
