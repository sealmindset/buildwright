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
    /// Browser panes: current URL.
    var url: String?

    init(id: UUID = UUID(), kind: PaneKind, title: String, tmuxWindowID: String? = nil, directory: String, url: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.tmuxWindowID = tmuxWindowID
        self.directory = directory
        self.url = url
    }

    /// Short id used in tmux names, env vars and status files.
    var shortID: String { String(id.uuidString.prefix(8)).lowercased() }
}
