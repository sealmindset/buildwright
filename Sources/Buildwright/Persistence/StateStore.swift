import Foundation

struct AppPersistedState: Codable {
    var workspaces: [Workspace]
    var activeWorkspaceID: UUID?
    var cvrPath: String?
    var sidebarVisible: Bool?
    var breakfixPrompt: String?
    var featurePrompt: String?
    var claudeSkipPermissions: Bool?
    var sharedBookmarks: [Bookmark]?
    var browserPrivateByDefault: Bool?
    var terminalFontSize: Double?
    var layoutTemplates: [LayoutTemplate]?
    var chatPrompt: String?
    var autoPlanOnLaunch: Bool?
    var aiSpendUSD: Double?
    var aiSpendMonth: String?
    var dismissedDrift: [String]?
    var lastDigestDate: String?
}

/// JSON persistence in ~/Library/Application Support/Buildwright/state.json.
/// Writes are debounced and atomic.
final class StateStore {
    static let shared = StateStore()

    private var stateFile: URL {
        Config.stateDirectory.appendingPathComponent("state.json")
    }

    private let queue = DispatchQueue(label: "buildwright.statestore", qos: .utility)
    private var pendingWork: DispatchWorkItem?

    func load() -> AppPersistedState? {
        guard let data = try? Data(contentsOf: stateFile) else { return nil }
        return try? JSONDecoder().decode(AppPersistedState.self, from: data)
    }

    /// Once per launch: copy the last session's state aside before this
    /// session writes anything. If a write ever corrupts state.json, the
    /// layout/pane mapping is one file-copy away (tmux has the processes).
    func backupOnce() {
        let backup = Config.stateDirectory.appendingPathComponent("state-backup.json")
        guard FileManager.default.fileExists(atPath: stateFile.path) else { return }
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: stateFile, to: backup)
    }

    func save(_ state: AppPersistedState) {
        pendingWork?.cancel()
        let work = DispatchWorkItem { [stateFile] in
            do {
                Config.ensureDirectories()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(state)
                try data.write(to: stateFile, options: .atomic)
            } catch {
                NSLog("Buildwright: failed to save state: \(error)")
            }
        }
        pendingWork = work
        queue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}
