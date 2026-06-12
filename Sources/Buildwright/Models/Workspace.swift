import Foundation

struct Tab: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var layout: LayoutNode?
    var panes: [Pane]
    var focusedPaneID: UUID?

    init(id: UUID = UUID(), name: String, layout: LayoutNode? = nil, panes: [Pane] = [], focusedPaneID: UUID? = nil) {
        self.id = id
        self.name = name
        self.layout = layout
        self.panes = panes
        self.focusedPaneID = focusedPaneID
    }

    func pane(_ id: UUID) -> Pane? { panes.first { $0.id == id } }
}

/// A saved page. Lives either on a workspace (per-project) or in the app-wide
/// shared list that shows up in every workspace.
struct Bookmark: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var url: String

    init(id: UUID = UUID(), title: String, url: String) {
        self.id = id
        self.title = title
        self.url = url
    }
}

/// Per-workspace backlog filter state (the whole board is always available;
/// each workspace remembers its own view of it).
struct BacklogFilters: Codable, Equatable {
    var showDone: Bool = false
    var statuses: Set<String> = []      // empty = all (except done unless showDone)
    var categories: Set<String> = []    // empty = all
    var priorities: Set<String> = []    // empty = all
    var searchText: String = ""

    init() {}
}

struct Workspace: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    /// Base repo/directory: where new panes and Started backlog items launch.
    var baseRepo: String
    var tabs: [Tab]
    var activeTabID: UUID?
    var backlogFilters: BacklogFilters
    /// Context snapshot for "while you were away" re-entry. All optional so
    /// old state files keep decoding.
    var lastSeenAt: Date?
    var lastSnapshot: [String: PaneStatus]?   // pane shortID -> status at leave
    var activeBacklogItemID: String?          // last Started backlog item
    /// Per-project bookmarks. Optional so old state files keep decoding.
    var bookmarks: [Bookmark]?

    init(id: UUID = UUID(), name: String, baseRepo: String, tabs: [Tab] = [], activeTabID: UUID? = nil, backlogFilters: BacklogFilters = BacklogFilters()) {
        self.id = id
        self.name = name
        self.baseRepo = baseRepo
        self.tabs = tabs
        self.activeTabID = activeTabID
        self.backlogFilters = backlogFilters
        self.lastSeenAt = nil
        self.lastSnapshot = nil
        self.activeBacklogItemID = nil
        self.bookmarks = nil
    }

    /// All Claude panes (shortID + title) across this workspace's tabs.
    var claudePanes: [(shortID: String, title: String)] {
        tabs.flatMap { tab in
            tab.panes.filter { $0.kind == .claude }.map { ($0.shortID, $0.title) }
        }
    }

    /// Command that runs this project's test suite (merge gate). nil = ask
    /// at first merge; empty string = gate explicitly disabled.
    var testCommand: String?
    /// Shell command probed every 5 min; non-empty stdout files a breakfix
    /// backlog item with the output as evidence. nil/empty = off.
    var incidentProbeCommand: String?

    /// tmux session name == sanitized workspace name, so iPad attach is just
    /// `tmux attach -t <name>`. tmux forbids ':' and '.' in session names.
    var tmuxSessionName: String {
        let sanitized = name
            .lowercased()
            .map { ch -> Character in
                if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" { return ch }
                return "-"
            }
        let s = String(sanitized).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return s.isEmpty ? "workspace" : s
    }

    var activeTab: Tab? {
        tabs.first { $0.id == activeTabID } ?? tabs.first
    }
}
