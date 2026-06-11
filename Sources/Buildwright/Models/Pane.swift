import Foundation

enum PaneKind: String, Codable {
    case claude
    case shell
    case browser
}

enum ClaudeStatus: String, Codable {
    case none      // not a claude pane / no signal yet
    case working
    case needsInput
    case done

    var symbol: String {
        switch self {
        case .none: return ""
        case .working: return "●"
        case .needsInput: return "◉"
        case .done: return "✓"
        }
    }
}

/// A Claude pane's current state plus when it entered that state — the
/// difference between "needs you · 10s" and "needs you · 25m" is the whole
/// point of attention management.
struct PaneStatus: Codable, Equatable {
    var state: ClaudeStatus
    var since: Date
}

func ageString(from since: Date, to now: Date = Date()) -> String {
    let s = Int(now.timeIntervalSince(since))
    if s < 0 { return "now" }
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}

/// One tab inside a browser pane.
struct BrowserTab: Identifiable, Codable, Equatable {
    let id: UUID
    var url: String?
    var title: String?

    init(id: UUID = UUID(), url: String? = nil, title: String? = nil) {
        self.id = id
        self.url = url
        self.title = title
    }
}

/// One pane in the layout. Terminal panes (claude/shell) map 1:1 to a tmux
/// window inside the workspace's tmux session. Browser panes are app-local.
struct Pane: Identifiable, Codable, Equatable {
    let id: UUID
    var kind: PaneKind
    var title: String
    /// tmux window id (e.g. "@3") inside the workspace session. nil for browser panes.
    var tmuxWindowID: String?
    /// Working directory the pane was started in.
    var directory: String
    /// Browser panes: the active tab's URL (kept in sync so pre-tab state
    /// files and any legacy readers keep working).
    var url: String?
    /// Browser panes: open tabs and which one is showing. Optional so state
    /// files from before tabs existed keep decoding (see normalizeBrowserTabs).
    var browserTabs: [BrowserTab]?
    var activeBrowserTabID: UUID?

    init(id: UUID = UUID(), kind: PaneKind, title: String, tmuxWindowID: String? = nil, directory: String, url: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.tmuxWindowID = tmuxWindowID
        self.directory = directory
        self.url = url
        if kind == .browser {
            let tab = BrowserTab(url: url)
            self.browserTabs = [tab]
            self.activeBrowserTabID = tab.id
        }
    }

    /// Short id used in tmux names, env vars and status files.
    var shortID: String { String(id.uuidString.prefix(8)).lowercased() }
}

// MARK: Browser tabs

extension Pane {
    var activeBrowserTab: BrowserTab? {
        let tabs = browserTabs ?? []
        return tabs.first { $0.id == activeBrowserTabID } ?? tabs.first
    }

    /// Pre-tab state files carry only `url` — give such a pane its one tab.
    mutating func normalizeBrowserTabs() {
        guard kind == .browser, (browserTabs ?? []).isEmpty else { return }
        let tab = BrowserTab(url: url)
        browserTabs = [tab]
        activeBrowserTabID = tab.id
    }

    @discardableResult
    mutating func addBrowserTab(url: String? = nil, activate: Bool = true) -> BrowserTab {
        let tab = BrowserTab(url: url)
        addBrowserTab(tab, activate: activate)
        return tab
    }

    mutating func addBrowserTab(_ tab: BrowserTab, activate: Bool = true) {
        var tabs = browserTabs ?? []
        tabs.append(tab)
        browserTabs = tabs
        if activate {
            activeBrowserTabID = tab.id
            url = tab.url
        }
    }

    /// Returns true when the last tab was closed (the caller closes the pane).
    @discardableResult
    mutating func closeBrowserTab(_ tabID: UUID) -> Bool {
        var tabs = browserTabs ?? []
        guard let i = tabs.firstIndex(where: { $0.id == tabID }) else { return tabs.isEmpty }
        tabs.remove(at: i)
        browserTabs = tabs
        if activeBrowserTabID == tabID {
            let neighbor = i < tabs.count ? tabs[i] : tabs.last
            activeBrowserTabID = neighbor?.id
            url = neighbor?.url
        }
        return tabs.isEmpty
    }

    mutating func selectBrowserTab(_ tabID: UUID) {
        guard let tabs = browserTabs, let tab = tabs.first(where: { $0.id == tabID }) else { return }
        activeBrowserTabID = tabID
        url = tab.url
    }

    mutating func updateBrowserTab(_ tabID: UUID, url newURL: String?, title newTitle: String?) {
        guard var tabs = browserTabs, let i = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        if let newURL, !newURL.isEmpty { tabs[i].url = newURL }
        if let newTitle, !newTitle.isEmpty { tabs[i].title = newTitle }
        browserTabs = tabs
        if activeBrowserTabID == tabID, let newURL, !newURL.isEmpty { url = newURL }
    }
}
