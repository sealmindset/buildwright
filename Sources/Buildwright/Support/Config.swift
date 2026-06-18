import Foundation

/// Central configuration. Every path and command is overridable via environment
/// variables so nothing is hardcoded into behavior.
enum Config {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Where Buildwright persists its own state (workspaces, layouts).
    static var stateDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["BUILDWRIGHT_STATE_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Buildwright", isDirectory: true)
    }

    /// Where bw-hook writes per-pane Claude status files.
    static var claudeStatusDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["BUILDWRIGHT_STATUS_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return home.appendingPathComponent(".local/state/buildwright/status", isDirectory: true)
    }

    /// Root of the /backlog skill's board.
    static var backlogDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["BUILDWRIGHT_BACKLOG_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return home.appendingPathComponent(".claude/backlog", isDirectory: true)
    }

    /// Claude Code user settings (for hook installation).
    static var claudeSettingsFile: URL {
        home.appendingPathComponent(".claude/settings.json")
    }

    static var tmuxBinary: String {
        ProcessInfo.processInfo.environment["BUILDWRIGHT_TMUX"] ?? "/usr/bin/env"
    }

    /// Default location of the CVR tool; configurable in Settings.
    static let defaultCVRPath = NSString(string: "~/Documents/GitHub/docai/tools/cvr").expandingTildeInPath

    /// Default target repo the reconciliation engine audits the board against;
    /// configurable in Settings so the engine generalizes to other repos.
    static let defaultDocaiPath = NSString(string: "~/Documents/GitHub/docai").expandingTildeInPath

    /// Where installed tool plugins are cloned (one subdirectory per plugin,
    /// each with a plugin.json manifest). See PluginManager.
    static var pluginsDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["BUILDWRIGHT_PLUGINS_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return home.appendingPathComponent(".buildwright/plugins", isDirectory: true)
    }

    /// Prefix for hidden per-pane grouped tmux sessions.
    static let groupedSessionPrefix = "_bw-"

    static func ensureDirectories() {
        for dir in [stateDirectory, claudeStatusDirectory] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
