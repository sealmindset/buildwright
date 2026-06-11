import Foundation

struct AppPersistedState: Codable {
    var workspaces: [Workspace]
    var activeWorkspaceID: UUID?
    var cvrPath: String?
    var sidebarVisible: Bool?
    var breakfixPrompt: String?
    var featurePrompt: String?
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
