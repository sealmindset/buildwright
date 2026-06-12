import Foundation
import SwiftUI
import AppKit
import Combine

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
    let planner = BacklogPlanner()
    @Published var showPlanSheet = false
    @Published var autoPlanOnLaunch = true
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
        StateStore.shared.backupOnce() // known-good copy from before this session
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
            terminalFontSize = saved.terminalFontSize ?? 13
            layoutTemplates = saved.layoutTemplates ?? []
            if let p = saved.chatPrompt, !p.isEmpty { chatPrompt = p }
            autoPlanOnLaunch = saved.autoPlanOnLaunch ?? true
            aiSpendUSD = saved.aiSpendUSD ?? 0
            aiSpendMonth = saved.aiSpendMonth ?? ""
            // DECISIONS.md era: upgrade an unmodified chat prompt in place.
            if saved.chatPrompt == AppState.legacyChatPrompt { chatPrompt = AppState.defaultChatPrompt }
        }
        planner.onCost = { [weak self] usd in self?.recordAISpend(usd) }
        TerminalViewCache.shared.applyFontSize(CGFloat(terminalFontSize))
        // System-wide ⌥⌘B → app forward + Mission Control.
        NotificationCenter.default.addObserver(forName: .bwSummon, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showMissionControl = true }
        }
        tmux.claudeSkipPermissions = claudeSkipPermissions
        // Legacy sweep: remove hidden `_bw-` helper sessions left behind by
        // pre-control-mode builds (current design never creates them).
        tmux.client.cleanupStaleGroupedSessions()
        if workspaces.isEmpty {
            showNewWorkspaceSheet = true
        } else {
            reconcileAll()
        }
        backlog.startWatching()
        planner.loadSavedPlan()
        startHealthLoop()
        startBoardWatcher()
        startIncidentProbe()
        // Proactive: re-plan when the board changed or the plan is stale,
        // a few seconds after launch so it never competes with reattach.
        if autoPlanOnLaunch {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self.planner.autoPlanIfStale()
            }
        }
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

    /// Launch reconcile runs N tmux CLI calls per workspace — off the main
    /// thread (it used to beachball launch with many panes), results applied
    /// back on the main actor.
    private func reconcileAll() {
        let snapshot = workspaces
        Task.detached(priority: .userInitiated) { [weak self] in
            let client = TmuxClient()
            var deadByWorkspace: [UUID: Set<UUID>] = [:]
            for ws in snapshot {
                let dead = TmuxManager.computeDeadPanes(workspace: ws, client: client)
                if !dead.isEmpty { deadByWorkspace[ws.id] = dead }
            }
            let result = deadByWorkspace
            await MainActor.run { [weak self] in self?.applyReconcile(result) }
        }
    }

    private func applyReconcile(_ deadByWorkspace: [UUID: Set<UUID>]) {
        guard !deadByWorkspace.isEmpty else { return }
        for i in workspaces.indices {
            guard let dead = deadByWorkspace[workspaces[i].id] else { continue }
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
            browserPrivateByDefault: browserPrivateByDefault,
            terminalFontSize: terminalFontSize,
            layoutTemplates: layoutTemplates,
            chatPrompt: chatPrompt,
            autoPlanOnLaunch: autoPlanOnLaunch,
            aiSpendUSD: aiSpendUSD,
            aiSpendMonth: aiSpendMonth
        ))
    }

    private func applyStatuses(_ statuses: [String: PaneStatus]) {
        let previous = paneStatuses
        paneStatuses = statuses
        now = Date()
        if previous != statuses {
            snapshotActiveWorkspace()
            persist()
            releaseQueuedPanes() // a gate may just have finished
        }
        // Notify when an unfocused pane flips to needsInput or done.
        guard let ws = activeWorkspace, let tab = ws.activeTab else { return }
        let focusedShortID = tab.focusedPaneID.flatMap { tab.pane($0)?.shortID }
        for (shortID, status) in statuses {
            guard previous[shortID]?.state != status.state, shortID != focusedShortID else { continue }
            guard let title = paneTitle(forShortID: shortID) else { continue }
            if status.state == .needsInput || status.state == .done {
                checkpointIfWorktree(shortID)
            }
            switch status.state {
            case .needsInput:
                let what = status.detail ?? "is waiting for your input"
                ShellExec.notify(title: "\(title) needs you", body: what)
            case .done:
                let what = status.detail ?? "is done"
                ShellExec.notify(title: "\(title) finished", body: what)
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
            let detail = after.detail.map { ": \(TranscriptReader.condense($0, limit: 120))" } ?? ""
            switch after.state {
            case .done:
                lines.append("“\(title)” finished (\(ageString(from: after.since, to: now)) ago)\(detail)")
            case .needsInput:
                lines.append("“\(title)” is waiting on you (\(ageString(from: after.since, to: now)))\(detail)")
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
        jump(workspaceID: entry.workspaceID, tabID: entry.tabID, paneID: entry.pane.id)
    }

    func jump(workspaceID: UUID, tabID: UUID, paneID: UUID) {
        disarmTransientModes() // same contract as every other navigation
        if activeWorkspaceID != workspaceID {
            switchWorkspace(workspaceID)
        }
        if let wi = activeWorkspaceIndex {
            workspaces[wi].activeTabID = tabID
            if let ti = workspaces[wi].tabs.firstIndex(where: { $0.id == tabID }) {
                workspaces[wi].tabs[ti].focusedPaneID = paneID
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        persist()
    }

    // MARK: Mission control

    @Published var showMissionControl = false

    struct OverviewEntry: Identifiable {
        var id: UUID { pane.id }
        let workspaceID: UUID
        let workspaceName: String
        let tabID: UUID
        let tabName: String
        let pane: Pane
        let status: PaneStatus?
    }

    /// Every terminal pane in every workspace, grouped by workspace and
    /// sorted by urgency — who needs you first, then who's working, then
    /// the rest. Browser/diff panes are omitted (nothing to monitor).
    var missionControlGroups: [(workspaceName: String, entries: [OverviewEntry])] {
        func urgency(_ e: OverviewEntry) -> Int {
            if e.pane.isQueued { return 3 }
            switch e.status?.state {
            case .needsInput: return 0
            case .working: return 1
            case .done: return 2
            default: return 4
            }
        }
        return workspaces.map { ws in
            var entries: [OverviewEntry] = []
            for tab in ws.tabs {
                for pane in tab.panes where pane.isTerminal {
                    entries.append(OverviewEntry(
                        workspaceID: ws.id, workspaceName: ws.name,
                        tabID: tab.id, tabName: tab.name,
                        pane: pane, status: paneStatuses[pane.shortID]))
                }
            }
            entries.sort { a, b in
                let (ua, ub) = (urgency(a), urgency(b))
                if ua != ub { return ua < ub }
                return (a.status?.since ?? .distantFuture) < (b.status?.since ?? .distantFuture)
            }
            return (workspaceName: ws.name, entries: entries)
        }
        .filter { !$0.entries.isEmpty }
    }

    // MARK: Pane zoom

    /// Temporarily show only this pane in its tab. Transient by design —
    /// never persisted, cleared on tab/workspace switches.
    @Published var zoomedPaneID: UUID?

    func toggleZoom() {
        guard let ws = activeWorkspace, let tab = ws.activeTab else { return }
        if let z = zoomedPaneID, tab.panes.contains(where: { $0.id == z }) {
            zoomedPaneID = nil
        } else {
            zoomedPaneID = tab.focusedPaneID
        }
    }

    // MARK: Broadcast input

    /// Mirror keystrokes to every terminal pane in the active tab (e.g. the
    /// same /command to several Claude sessions). Auto-disarms on tab or
    /// workspace switch — broadcast into the wrong tab is a disaster.
    @Published var broadcastMode = false

    func toggleBroadcast() {
        broadcastMode.toggle()
        syncBroadcastTargets()
    }

    func disarmTransientModes() {
        zoomedPaneID = nil
        broadcastMode = false
        syncBroadcastTargets()
    }

    private func syncBroadcastTargets() {
        guard broadcastMode, let ws = activeWorkspace, let tab = ws.activeTab else {
            TerminalViewCache.shared.broadcastTargets = []
            return
        }
        TerminalViewCache.shared.broadcastTargets =
            Set(tab.panes.filter { $0.isTerminal }.map(\.id))
    }

    // MARK: Terminal appearance

    @Published var terminalFontSize: Double = 13 {
        didSet {
            guard oldValue != terminalFontSize else { return }
            TerminalViewCache.shared.applyFontSize(CGFloat(terminalFontSize))
            persist()
        }
    }

    // MARK: Layout templates

    @Published var layoutTemplates: [LayoutTemplate] = []

    /// Snapshot the active tab's structure (pane kinds + dirs, not instances).
    /// Worktree panes are templated as plain Claude panes in the base repo.
    func saveCurrentTabAsTemplate(named name: String) {
        guard let ws = activeWorkspace, let tab = ws.activeTab, let layout = tab.layout else { return }
        func convert(_ node: LayoutNode) -> TemplateNode? {
            switch node {
            case .pane(let id):
                guard let pane = tab.pane(id) else { return nil }
                let dir = (pane.directory == ws.baseRepo || pane.worktreeBranch != nil) ? nil : pane.directory
                return .pane(kind: pane.kind, directory: dir,
                             url: pane.kind == .browser ? pane.url : nil)
            case .split(let axis, let children, let fractions):
                let kids = children.compactMap(convert)
                guard !kids.isEmpty else { return nil }
                let fracs = kids.count == children.count
                    ? fractions
                    : Array(repeating: 1.0 / Double(kids.count), count: kids.count)
                return kids.count == 1 ? kids[0] : .split(axis: axis, children: kids, fractions: fracs)
            }
        }
        guard let root = convert(layout) else { return }
        layoutTemplates.removeAll { $0.name == name }
        layoutTemplates.append(LayoutTemplate(name: name, node: root))
        persist()
    }

    func deleteTemplate(_ name: String) {
        layoutTemplates.removeAll { $0.name == name }
        persist()
    }

    /// Open a new tab and populate it from a template.
    func newTab(fromTemplate template: LayoutTemplate) {
        guard let wi = activeWorkspaceIndex else { return }
        let ws = workspaces[wi]
        var tab = Tab(name: template.name)
        func build(_ node: TemplateNode) -> LayoutNode? {
            switch node {
            case .pane(let kind, let directory, let url):
                let dir = directory ?? ws.baseRepo
                let title: String
                switch kind {
                case .claude: title = "claude"
                case .shell: title = "shell"
                case .browser: title = "browser"
                case .diff: title = "diff"
                }
                var pane = Pane(kind: kind, title: title, directory: dir,
                                url: kind == .browser ? (url ?? "https://docs.anthropic.com") : nil)
                if kind == .browser {
                    pane.browserPrivate = browserPrivateByDefault
                } else if pane.isTerminal {
                    guard let windowID = tmux.createWindow(for: pane, in: ws) else { return nil }
                    pane.tmuxWindowID = windowID
                }
                tab.panes.append(pane)
                return .pane(pane.id)
            case .split(let axis, let children, let fractions):
                let kids = children.compactMap(build)
                guard !kids.isEmpty else { return nil }
                if kids.count == 1 { return kids[0] }
                let fracs = kids.count == children.count
                    ? fractions
                    : Array(repeating: 1.0 / Double(kids.count), count: kids.count)
                return .split(axis: axis, children: kids, fractions: fracs)
            }
        }
        guard let layout = build(template.node) else {
            ShellExec.notify(title: "Buildwright", body: "Could not create panes from template — is tmux running?")
            return
        }
        tab.layout = layout
        tab.focusedPaneID = tab.panes.first?.id
        workspaces[wi].tabs.append(tab)
        workspaces[wi].activeTabID = tab.id
        persist()
    }

    /// "Save Tab Layout as Template…" — NSAlert keeps this dependency-free.
    func promptSaveTemplate() {
        let alert = NSAlert()
        alert.messageText = "Save Tab Layout as Template"
        alert.informativeText = "The current tab's pane arrangement (kinds and folders) will be reusable from Workspace → New Tab from Template."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 230, height: 24))
        field.placeholderString = "Template name"
        field.stringValue = activeWorkspace?.activeTab?.name ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        saveCurrentTabAsTemplate(named: name)
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
                for pane in tab.panes where pane.isTerminal {
                    tmux.destroyWindow(for: pane, in: ws)
                }
            }
            tmux.client.killSession(name: ws.tmuxSessionName)
        }
        // Tear down cached views + the control connection, or ghost views
        // keep streaming a deleted workspace's output forever.
        for tab in ws.tabs {
            for pane in tab.panes { TerminalViewCache.shared.remove(pane.id) }
        }
        tmux.dropSession(ws.tmuxSessionName)
        workspaces.removeAll { $0.id == id }
        if activeWorkspaceID == id { activeWorkspaceID = workspaces.first?.id }
        persist()
    }

    func switchWorkspace(_ id: UUID) {
        snapshotActiveWorkspace() // record the world we're leaving
        disarmTransientModes()
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
        for pane in workspaces[wi].tabs[ti].panes {
            if pane.isTerminal { tmux.destroyWindow(for: pane, in: ws) }
            TerminalViewCache.shared.remove(pane.id) // no ghost views
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
        disarmTransientModes()
        workspaces[wi].activeTabID = tabID
        persist()
    }

    // MARK: Pane management

    /// Add a pane. If a pane is focused it splits beside it along `axis`;
    /// otherwise it fills the tab or splits the whole layout.
    func addPane(kind: PaneKind, axis: SplitAxis = .horizontal, directory: String? = nil,
                 title: String? = nil, prompt: String? = nil, url: String? = nil,
                 worktree: Bool = false, gateEpicID: String? = nil) {
        guard let wi = activeWorkspaceIndex else { return }
        let ws = workspaces[wi]
        guard let ti = ws.tabs.firstIndex(where: { $0.id == (ws.activeTabID ?? ws.tabs.first?.id) }) else { return }

        var dir = directory ?? ws.baseRepo
        var worktreeBranch: String?
        if worktree && kind == .claude {
            let slug = GitWorktree.slug(from: title ?? prompt ?? "agent")
            guard let wt = GitWorktree.create(repo: ws.baseRepo, slug: slug) else {
                ShellExec.notify(title: "Buildwright",
                                 body: "Could not create worktree — is \(ws.baseRepo) a git repo?")
                return
            }
            dir = wt.path
            worktreeBranch = wt.branch
        }
        let defaultTitle: String
        switch kind {
        case .claude: defaultTitle = worktreeBranch.map { String($0.dropFirst(3)) } ?? "claude"
        case .shell: defaultTitle = "shell"
        case .browser: defaultTitle = "browser"
        case .diff: defaultTitle = "diff"
        }
        var pane = Pane(kind: kind, title: title ?? defaultTitle, directory: dir,
                        url: kind == .browser ? (url ?? "https://docs.anthropic.com") : nil)
        pane.worktreeBranch = worktreeBranch
        if kind == .browser { pane.browserPrivate = browserPrivateByDefault }

        // Epic collision gate: the plan says this epic must not run while
        // another (in-progress) epic touches the same functionality.
        if kind == .claude, let gateEpicID {
            pane.gateEpicID = gateEpicID
            pane.queuedPrompt = prompt
        }
        // Safety gate (linear-preferred): a Claude pane opening in a folder
        // where another Claude pane is actively working goes ON DECK instead
        // of starting — two agents must never share a working tree. The
        // placeholder offers Start Now / worktree escape hatches.
        else if kind == .claude, worktreeBranch == nil,
           let gate = workingClaudePane(inDirectory: dir, of: ws) {
            pane.gatePaneID = gate.id
            pane.queuedPrompt = prompt
        } else if pane.isTerminal {
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

    // MARK: On-deck queue (linear-preferred workflow)

    @Published var showTeeUpSheet = false

    /// The Claude pane currently WORKING in this directory, if any — the
    /// thing a new same-folder pane must wait for.
    func workingClaudePane(inDirectory dir: String, of ws: Workspace) -> Pane? {
        for tab in ws.tabs {
            for pane in tab.panes
            where pane.kind == .claude && pane.directory == dir && !pane.isQueued {
                if paneStatuses[pane.shortID]?.state == .working { return pane }
            }
        }
        return nil
    }

    /// Start queued panes whose gate finished or disappeared. Called on every
    /// status change and after pane closes — covers app relaunch too (the
    /// first status scan triggers it).
    func releaseQueuedPanes() {
        for wi in workspaces.indices {
            for ti in workspaces[wi].tabs.indices {
                for pane in workspaces[wi].tabs[ti].panes where pane.isQueued {
                    if let epicGate = pane.gateEpicID {
                        // Epic collision gate: released when the blocking
                        // epic is done (or vanished from the board).
                        let epic = backlog.epics.first { $0.epic.itemID == epicGate }?.epic
                        if epic == nil || epic!.isDone {
                            startQueuedPane(pane.id)
                        }
                        continue
                    }
                    guard let gateID = pane.gatePaneID else { continue }
                    let gate = workspaces[wi].tabs.lazy
                        .flatMap(\.panes).first { $0.id == gateID }
                    let gateDone = gate.map { paneStatuses[$0.shortID]?.state == .done } ?? true
                    if gate == nil || gateDone {
                        startQueuedPane(pane.id)
                    }
                }
            }
        }
    }

    /// Launch an on-deck pane now (gate released, or the user said so).
    func startQueuedPane(_ paneID: UUID) {
        for wi in workspaces.indices {
            let ws = workspaces[wi]
            for ti in workspaces[wi].tabs.indices {
                guard let pi = workspaces[wi].tabs[ti].panes.firstIndex(where: { $0.id == paneID }),
                      workspaces[wi].tabs[ti].panes[pi].isQueued else { continue }
                var pane = workspaces[wi].tabs[ti].panes[pi]
                guard let windowID = tmux.createWindow(for: pane, in: ws, prompt: pane.queuedPrompt) else {
                    ShellExec.notify(title: "Buildwright", body: "Could not start on-deck pane — is tmux running?")
                    return
                }
                pane.tmuxWindowID = windowID
                pane.gatePaneID = nil
                pane.gateEpicID = nil
                pane.queuedPrompt = nil
                workspaces[wi].tabs[ti].panes[pi] = pane
                ShellExec.notify(title: "On deck pane started", body: "“\(pane.title)” in \(ws.name) is now running")
                persist()
                return
            }
        }
    }

    /// Escape hatch: run an on-deck pane NOW in its own worktree (parallel-safe).
    func startQueuedPaneInWorktree(_ paneID: UUID) {
        for wi in workspaces.indices {
            let ws = workspaces[wi]
            for ti in workspaces[wi].tabs.indices {
                guard let pi = workspaces[wi].tabs[ti].panes.firstIndex(where: { $0.id == paneID }),
                      workspaces[wi].tabs[ti].panes[pi].isQueued else { continue }
                var pane = workspaces[wi].tabs[ti].panes[pi]
                let slug = GitWorktree.slug(from: pane.queuedPrompt ?? pane.title)
                guard let wt = GitWorktree.create(repo: ws.baseRepo, slug: slug) else {
                    ShellExec.notify(title: "Buildwright", body: "Could not create worktree — is \(ws.baseRepo) a git repo?")
                    return
                }
                pane.directory = wt.path
                pane.worktreeBranch = wt.branch
                pane.gatePaneID = nil // gates no longer apply; isolated now
                pane.gateEpicID = nil
                workspaces[wi].tabs[ti].panes[pi] = pane
                startQueuedPaneNow(wi: wi, ti: ti, paneID: paneID)
                return
            }
        }
    }

    private func startQueuedPaneNow(wi: Int, ti: Int, paneID: UUID) {
        guard let pi = workspaces[wi].tabs[ti].panes.firstIndex(where: { $0.id == paneID }) else { return }
        var pane = workspaces[wi].tabs[ti].panes[pi]
        let ws = workspaces[wi]
        guard let windowID = tmux.createWindow(for: pane, in: ws, prompt: pane.queuedPrompt) else { return }
        pane.tmuxWindowID = windowID
        pane.queuedPrompt = nil
        workspaces[wi].tabs[ti].panes[pi] = pane
        persist()
    }

    /// Title of the pane an on-deck pane is waiting on (for the placeholder).
    func gateTitle(for pane: Pane) -> String? {
        if let epicID = pane.gateEpicID { return "epic \(epicID)" }
        guard let gateID = pane.gatePaneID else { return nil }
        for ws in workspaces {
            for tab in ws.tabs {
                if let gate = tab.panes.first(where: { $0.id == gateID }) { return gate.title }
            }
        }
        return nil
    }

    // MARK: Epic completion → reassess

    /// Board statuses from the previous observation, for transition detection.
    private var lastEpicStatuses: [String: String] = [:]
    private var boardObserver: AnyCancellable?

    func startBoardWatcher() {
        boardObserver = backlog.$epics
            .receive(on: DispatchQueue.main)
            .sink { [weak self] groups in
                guard let self else { return }
                let current = Dictionary(uniqueKeysWithValues: groups.map { ($0.epic.itemID, $0.epic.status) })
                defer { self.lastEpicStatuses = current }
                // First observation is a baseline, not a transition.
                guard !self.lastEpicStatuses.isEmpty else { return }
                // Any board change can release an epic collision gate.
                self.releaseQueuedPanes()
                // Epic completed → reassess the plan with a loose-ends hunt.
                for (id, status) in current
                where (status == "done" || status == "closed")
                    && self.lastEpicStatuses[id] != nil
                    && self.lastEpicStatuses[id] != status {
                    ShellExec.notify(title: "\(id) complete",
                                     body: "Reassessing the build sequence and checking for loose ends…")
                    self.planner.runPlan(notifyFailure: false, looseEndsFor: id)
                    break // one re-plan covers simultaneous completions
                }
            }
    }

    // MARK: Chat pane (always parallel-safe)

    static let legacyChatPrompt = """
    You are a thinking partner, not an implementer. We're going to talk through ideas — \
    new features, fixes, architecture, priorities. Push back on weak ideas, ask clarifying \
    questions, and explore trade-offs honestly.

    When we settle on something worth doing, file it in the backlog board in the current \
    directory as markdown, following the existing Epic → Story → Task conventions you find \
    here. Do NOT write code and do NOT touch any other repository — your only output is \
    conversation and backlog entries.
    """

    static let defaultChatPrompt = legacyChatPrompt + """
    \n\nWhen we make a significant decision (architecture, workflow, technology, scope), \
    append it to DECISIONS.md in this directory: one paragraph with context, the choice, \
    why, and the alternatives we rejected.
    """

    @Published var chatPrompt: String = AppState.defaultChatPrompt

    /// Chat panes live in the backlog directory: discussion in, backlog items
    /// out, zero contact with code — safe alongside anything.
    func addChatPane() {
        addPane(kind: .claude, directory: Config.backlogDirectory.path,
                title: "chat", prompt: chatPrompt)
    }

    // MARK: AI-feature spend (planner/review runs; pane sessions show their own)

    @Published private(set) var aiSpendUSD: Double = 0
    private var aiSpendMonth = ""

    func recordAISpend(_ usd: Double) {
        let month = String(ISO8601DateFormatter().string(from: Date()).prefix(7))
        if month != aiSpendMonth { aiSpendMonth = month; aiSpendUSD = 0 }
        aiSpendUSD += usd
        persist()
    }

    // MARK: Worktree checkpoints (bus-factor insurance)

    private var lastCheckpointAt: [UUID: Date] = [:]

    /// Pane paused (done / needs-you) in a worktree: push the work off this
    /// machine. Throttled; failures land in the heal log, not your face.
    private func checkpointIfWorktree(_ shortID: String) {
        for ws in workspaces {
            for tab in ws.tabs {
                for pane in tab.panes
                where pane.shortID == shortID && pane.worktreeBranch != nil {
                    let last = lastCheckpointAt[pane.id] ?? .distantPast
                    guard Date().timeIntervalSince(last) > 600 else { return }
                    lastCheckpointAt[pane.id] = Date()
                    let dir = pane.directory
                    let title = pane.title
                    Task.detached(priority: .utility) { [weak self] in
                        let result = GitWorktree.checkpoint(dir: dir)
                        if let result {
                            await MainActor.run { [weak self] in
                                self?.recordHeal(["checkpoint “\(title)”: \(result)"])
                            }
                        }
                    }
                    return
                }
            }
        }
    }

    // MARK: Production incident probe

    private var lastProbeOutput: [UUID: String] = [:]

    func startIncidentProbe() {
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runIncidentProbes() }
        }
    }

    private func runIncidentProbes() {
        for ws in workspaces {
            guard let cmd = ws.incidentProbeCommand, !cmd.isEmpty else { continue }
            let wsID = ws.id, wsName = ws.name, repo = ws.baseRepo
            Task.detached(priority: .utility) { [weak self] in
                let result = ShellExec.run(["sh", "-c", cmd], cwd: repo)
                let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                guard result.ok, !output.isEmpty else { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // Same evidence as last time = same incident; don't refile.
                    guard self.lastProbeOutput[wsID] != output else { return }
                    self.lastProbeOutput[wsID] = output
                    self.backlog.createEpic(
                        title: "Breakfix: production incident (\(wsName))",
                        category: "breakfix", priority: "P1",
                        body: "Filed automatically by the incident probe.\n\nEvidence:\n```\n\(TranscriptReader.condense(output, limit: 2000))\n```")
                    ShellExec.notify(title: "Production incident — breakfix filed",
                                     body: TranscriptReader.condense(output, limit: 120))
                }
            }
        }
    }

    // MARK: Annealing (self-healing) loop

    /// Every repair the app performed on itself, newest last — shown in the
    /// diagnostics snapshot so healing never silently masks a bug.
    @Published private(set) var healLog: [String] = []
    private var healPassCount = 0

    private func recordHeal(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        healLog.append(contentsOf: lines.map { "\(stamp) \($0)" })
        if healLog.count > 50 { healLog.removeFirst(healLog.count - 50) }
    }

    func startHealthLoop() {
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.healthPass() }
        }
    }

    /// One annealing pass: each check heals toward verifiable ground truth
    /// (tmux, the filesystem) — never toward the app's last write, which is
    /// how self-healing turns into bug-masking.
    private func healthPass() {
        healPassCount += 1
        var healed: [String] = []
        healed += tmux.healthCheck()
        healed += TerminalViewCache.shared.watchdogSweep()
        healed += repairModelInvariants()
        if healPassCount % 15 == 0 { // ~every 5 minutes
            healed += pruneOrphanStatusFiles()
        }
        runtimeWindowSweep()
        recordHeal(healed)
    }

    /// Pure-model invariants: every pane in its tab's layout, no layout
    /// nodes for missing panes, focus and active-tab pointers valid.
    private func repairModelInvariants() -> [String] {
        var healed: [String] = []
        for wi in workspaces.indices {
            if let active = workspaces[wi].activeTabID,
               !workspaces[wi].tabs.contains(where: { $0.id == active }) {
                workspaces[wi].activeTabID = workspaces[wi].tabs.first?.id
                healed.append("\(workspaces[wi].name): active tab pointed nowhere — reset")
            }
            for ti in workspaces[wi].tabs.indices {
                let tab = workspaces[wi].tabs[ti]
                let paneIDs = Set(tab.panes.map(\.id))
                if let layout = tab.layout {
                    for orphan in layout.paneIDs where !paneIDs.contains(orphan) {
                        workspaces[wi].tabs[ti].layout = workspaces[wi].tabs[ti].layout?.removing(orphan)
                        healed.append("\(workspaces[wi].name)/\(tab.name): layout node for missing pane — removed")
                    }
                }
                let inLayout = Set(workspaces[wi].tabs[ti].layout?.paneIDs ?? [])
                for pane in tab.panes where !inLayout.contains(pane.id) {
                    if let layout = workspaces[wi].tabs[ti].layout {
                        workspaces[wi].tabs[ti].layout = .split(
                            axis: .horizontal, children: [layout, .pane(pane.id)], fractions: [0.7, 0.3])
                    } else {
                        workspaces[wi].tabs[ti].layout = .pane(pane.id)
                    }
                    healed.append("\(workspaces[wi].name)/\(tab.name): pane “\(pane.title)” was invisible — re-added to layout")
                }
                if let focus = workspaces[wi].tabs[ti].focusedPaneID, !paneIDs.contains(focus) {
                    workspaces[wi].tabs[ti].focusedPaneID = tab.panes.first?.id
                    healed.append("\(workspaces[wi].name)/\(tab.name): focus pointed at missing pane — reset")
                }
            }
        }
        if !healed.isEmpty { persist() }
        return healed
    }

    /// Windows that vanished without a %window-close (missed event, sleep
    /// gap): give the pane its exited overlay instead of a silent zombie.
    private func runtimeWindowSweep() {
        let snapshot = workspaces
        Task.detached(priority: .utility) {
            let client = TmuxClient()
            var liveByWorkspace: [UUID: Set<String>] = [:]
            for ws in snapshot {
                let live = Set(client.listWindows(session: ws.tmuxSessionName).map { $0.id })
                // Empty = session gone or CLI error; the control-client exit
                // path owns that case. Only act on positive knowledge.
                if !live.isEmpty { liveByWorkspace[ws.id] = live }
            }
            let result = liveByWorkspace
            await MainActor.run { [weak self] in
                guard let self else { return }
                var healed: [String] = []
                for ws in self.workspaces {
                    guard let live = result[ws.id] else { continue }
                    var suspects: [Pane] = []
                    // Falsely-latched exited panes whose window is in the
                    // live set heal in the other direction.
                    var falselyExited: [Pane] = []
                    for tab in ws.tabs {
                        for pane in tab.panes where pane.isTerminal && !pane.isQueued {
                            guard let wid = pane.tmuxWindowID else { continue }
                            if live.contains(wid) {
                                if TerminalViewCache.shared.runStates[pane.id] == .exited {
                                    falselyExited.append(pane)
                                }
                            } else if TerminalViewCache.shared.runStates[pane.id] == nil,
                                      TerminalViewCache.shared.contains(pane.id) {
                                suspects.append(pane)
                            }
                        }
                    }
                    for pane in falselyExited {
                        TerminalViewCache.shared.clearExitedIfAlive(pane.id)
                        healed.append("\(ws.name): “\(pane.title)” marked exited but window is alive — cleared")
                    }
                    guard !suspects.isEmpty else { continue }
                    // Re-verify against a FRESH listing: the background
                    // snapshot races pane restarts (a window created after
                    // the snapshot must not be declared dead).
                    let fresh = Set(self.tmux.client.listWindows(session: ws.tmuxSessionName).map { $0.id })
                    guard !fresh.isEmpty else { continue }
                    for pane in suspects where !fresh.contains(pane.tmuxWindowID ?? "") {
                        TerminalViewCache.shared.markExited(pane.id)
                        healed.append("\(ws.name): window for “\(pane.title)” gone without close event — marked exited")
                    }
                }
                self.recordHeal(healed)
            }
        }
    }

    /// Status files whose pane no longer exists keep inflating the menu-bar
    /// counts forever; sweep the stale ones.
    private func pruneOrphanStatusFiles() -> [String] {
        var healed: [String] = []
        let known = Set(workspaces.flatMap { $0.tabs.flatMap { $0.panes.map(\.shortID) } })
        let dir = Config.claudeStatusDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        for file in files {
            let shortID = file.deletingPathExtension().lastPathComponent
            guard !known.contains(shortID) else { continue }
            let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            guard Date().timeIntervalSince(mtime) > 3600 else { continue } // grace for races
            try? FileManager.default.removeItem(at: file)
            healed.append("orphan status file \(file.lastPathComponent) — removed")
        }
        return healed
    }

    /// Panic button: rebuild the focused pane's display from tmux truth.
    func refreshFocusedPane() {
        guard let ws = activeWorkspace, let tab = ws.activeTab,
              let focus = tab.focusedPaneID else { return }
        TerminalViewCache.shared.refreshPane(focus)
    }

    /// One-paste debugging: app + tmux + per-pane size truth on the
    /// clipboard, for reporting display issues without a screenshot hunt.
    func copyDiagnostics() {
        var lines: [String] = []
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        lines.append("Buildwright \(version) · \(Date())")
        lines.append(ShellExec.run(["tmux", "-V"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        lines.append("--- clients ---")
        lines.append(ShellExec.run(["tmux", "list-clients", "-F",
            "#{client_name} session=#{client_session} ctrl=#{client_control_mode} #{client_width}x#{client_height}"]).stdout)
        for ws in workspaces {
            lines.append("--- windows: \(ws.tmuxSessionName) ---")
            lines.append(ShellExec.run(["tmux", "list-windows", "-t", "=\(ws.tmuxSessionName)",
                "-F", "#{window_id} #{window_name} #{window_width}x#{window_height}"]).stdout)
        }
        lines.append("--- views ---")
        lines.append(contentsOf: TerminalViewCache.shared.diagnosticLines())
        lines.append("font=\(terminalFontSize) workspaces=\(workspaces.count) statuses=\(paneStatuses.count)")
        if !healLog.isEmpty {
            lines.append("--- self-healing log (newest last) ---")
            lines.append(contentsOf: healLog.suffix(20))
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        ShellExec.notify(title: "Diagnostics copied", body: "Paste into Claude Code to report an issue")
    }

    /// Bring a dead pane back: same kind, folder, and title, fresh tmux
    /// window (claude restarts interactive — its session context is gone
    /// with the process, but `claude --continue` is one keystroke away).
    func restartPane(_ paneID: UUID) {
        for wi in workspaces.indices {
            let ws = workspaces[wi]
            for ti in workspaces[wi].tabs.indices {
                guard let pi = workspaces[wi].tabs[ti].panes.firstIndex(where: { $0.id == paneID }) else { continue }
                var pane = workspaces[wi].tabs[ti].panes[pi]
                guard pane.isTerminal else { return }
                // Ground truth FIRST: if the window is actually alive, the
                // overlay was a false alarm — clear it and resync the
                // display. NEVER recreate over a live session (that orphans
                // the user's running work).
                if let wid = pane.tmuxWindowID,
                   tmux.client.listWindows(session: ws.tmuxSessionName)
                       .contains(where: { $0.id == wid }) {
                    TerminalViewCache.shared.dismissState(paneID)
                    TerminalViewCache.shared.refreshPane(paneID)
                    ShellExec.notify(title: "False alarm", body: "“\(pane.title)” is alive — display resynced, session untouched")
                    return
                }
                TerminalViewCache.shared.remove(paneID)
                // Stale status from the previous life ("done · 3h") must not
                // carry over to the fresh process.
                paneStatuses.removeValue(forKey: pane.shortID)
                try? FileManager.default.removeItem(
                    at: Config.claudeStatusDirectory.appendingPathComponent("\(pane.shortID).status"))
                try? FileManager.default.removeItem(
                    at: Config.claudeStatusDirectory.appendingPathComponent("\(pane.shortID).json"))
                guard let windowID = tmux.createWindow(for: pane, in: ws) else {
                    ShellExec.notify(title: "Buildwright", body: "Could not restart pane — is tmux running?")
                    return
                }
                pane.tmuxWindowID = windowID
                workspaces[wi].tabs[ti].panes[pi] = pane
                persist()
                return
            }
        }
    }

    func setTestCommand(_ cmd: String, forWorkspace id: UUID) {
        guard let wi = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[wi].testCommand = cmd
        persist()
    }

    /// Open a read-only diff pane beside a terminal pane, reviewing that
    /// pane's folder (the worktree → review → merge loop).
    func addDiffPane(reviewing pane: Pane) {
        focusPane(pane.id) // split lands beside the reviewed pane
        addPane(kind: .diff, directory: pane.directory,
                title: "diff: \(pane.title)")
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
            if pane.isTerminal {
                tmux.destroyWindow(for: pane, in: ws)
                paneStatuses.removeValue(forKey: pane.shortID)
            }
            if let branch = pane.worktreeBranch {
                let removed = GitWorktree.removeIfClean(repo: ws.baseRepo, path: pane.directory)
                ShellExec.notify(title: "Buildwright", body: removed
                    ? "Worktree removed — branch \(branch) kept"
                    : "Worktree kept (uncommitted changes): \(pane.directory)")
            }
            workspaces[wi].tabs[ti].layout = workspaces[wi].tabs[ti].layout?.removing(paneID)
            workspaces[wi].tabs[ti].panes.removeAll { $0.id == paneID }
            if workspaces[wi].tabs[ti].focusedPaneID == paneID {
                workspaces[wi].tabs[ti].focusedPaneID = workspaces[wi].tabs[ti].panes.first?.id
            }
        }
        if zoomedPaneID == paneID { zoomedPaneID = nil }
        syncBroadcastTargets()
        persist()
        releaseQueuedPanes() // closing a gate pane releases its queue
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

    /// The killer feature: spawn a Claude pane preloaded with a backlog item —
    /// routed by the sequenced-epic policy:
    ///  - target epic COLLIDES with an in-progress epic → on deck behind that
    ///    epic (starts when it's marked done)
    ///  - another epic is in progress but non-colliding, and the base folder
    ///    is busy → isolated worktree (parallel-safe cross-checking)
    ///  - otherwise → normal start (folder gate still applies)
    func startBacklogItem(_ item: BacklogItem) {
        let prompt = "/backlog start \(item.itemID)"
        let epicID = epicID(of: item)
        // Linear-first: with work already in progress, parallel needs three
        // proofs — no collision, on the plan's parallel-safe whitelist, and
        // a free lane (one max; your review attention is the bottleneck).
        if let blocker = activeCollidingEpic(for: epicID) {
            addPane(kind: .claude, title: item.itemID, prompt: prompt, gateEpicID: blocker)
            ShellExec.notify(title: "\(item.itemID) on deck",
                             body: "Collides with \(blocker) (same functionality) — starts when \(blocker) is done")
        } else if let ws = activeWorkspace,
                  hasActiveEpic(besides: epicID),
                  workingClaudePane(inDirectory: ws.baseRepo, of: ws) != nil {
            if !isParallelSafe(item) {
                let blocker = primaryActiveEpic(besides: epicID) ?? "the active epic"
                addPane(kind: .claude, title: item.itemID, prompt: prompt, gateEpicID: primaryActiveEpic(besides: epicID))
                ShellExec.notify(title: "\(item.itemID) on deck",
                                 body: "Not on the parallel-safe list — linear first; starts when \(blocker) is done")
            } else if parallelLaneCount(in: ws) >= 1 {
                let blocker = primaryActiveEpic(besides: epicID) ?? "the active epic"
                addPane(kind: .claude, title: item.itemID, prompt: prompt, gateEpicID: primaryActiveEpic(besides: epicID))
                ShellExec.notify(title: "\(item.itemID) on deck",
                                 body: "Parallel lane busy (one at a time) — starts when \(blocker) is done")
            } else {
                addPane(kind: .claude, title: item.itemID, prompt: prompt, worktree: true)
            }
        } else {
            addPane(kind: .claude, title: item.itemID, prompt: prompt)
        }
        if let wi = activeWorkspaceIndex {
            workspaces[wi].activeBacklogItemID = item.itemID
            persist()
        }
    }

    /// Is this item on the plan's parallel-safe whitelist (itself, or — for
    /// a story — listed via its exact id)?
    private func isParallelSafe(_ item: BacklogItem) -> Bool {
        guard let list = planner.plan?.parallelSafe else { return false }
        return list.contains { $0.id == item.itemID }
    }

    /// The in-progress epic earliest in plan order — what linear-first work
    /// waits behind.
    private func primaryActiveEpic(besides epicID: String) -> String? {
        let active = activeEpicIDs.subtracting([epicID])
        guard !active.isEmpty else { return nil }
        if let plan = planner.plan,
           let first = plan.epics.first(where: { active.contains($0.id) }) {
            return first.id
        }
        return active.sorted().first
    }

    /// Worktree-isolated claude panes currently running in this workspace —
    /// the parallel lanes in use.
    private func parallelLaneCount(in ws: Workspace) -> Int {
        var count = 0
        for tab in ws.tabs {
            for pane in tab.panes
            where pane.kind == .claude && pane.worktreeBranch != nil
                && pane.tmuxWindowID != nil
                && TerminalViewCache.shared.runStates[pane.id] == nil {
                count += 1
            }
        }
        return count
    }

    // MARK: Sequenced-epic policy

    private func epicID(of item: BacklogItem) -> String {
        item.isEpic ? item.itemID : (item.parent.isEmpty ? item.itemID : item.parent)
    }

    /// Epics currently in progress on the board (directly, or via a story).
    private var activeEpicIDs: Set<String> {
        var active = Set<String>()
        for group in backlog.epics {
            if group.epic.status == "in-progress" { active.insert(group.epic.itemID) }
            if group.stories.contains(where: { $0.status == "in-progress" }) {
                active.insert(group.epic.itemID)
            }
        }
        return active
    }

    private func hasActiveEpic(besides epicID: String) -> Bool {
        !activeEpicIDs.subtracting([epicID]).isEmpty
    }

    /// First in-progress epic the plan says must not run concurrently with
    /// the target (checked in both directions). No plan = no collision info
    /// (the folder gate still protects files).
    private func activeCollidingEpic(for epicID: String) -> String? {
        guard let plan = planner.plan else { return nil }
        let active = activeEpicIDs.subtracting([epicID])
        guard !active.isEmpty else { return nil }
        for epic in plan.epics {
            let conflicts = Set(epic.conflictsWith ?? [])
            if epic.id == epicID, let hit = active.first(where: { conflicts.contains($0) }) {
                return hit
            }
            if active.contains(epic.id), conflicts.contains(epicID) {
                return epic.id
            }
        }
        return nil
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

    /// Find any board item by id ("EPIC-20" or "EPIC-20-S1") — used by the
    /// AI plan panel's start buttons.
    func backlogItem(byID id: String) -> BacklogItem? {
        for group in backlog.epics {
            if group.epic.itemID == id { return group.epic }
            if let story = group.stories.first(where: { $0.itemID == id }) { return story }
        }
        return nil
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
