import Foundation

/// Installs the Claude Code hooks that report pane status to Buildwright.
/// Merges into ~/.claude/settings.json non-destructively: existing hooks and
/// unknown keys are preserved; our entries are identified by "bw-hook" and
/// inserted only when missing. The hook itself no-ops outside Buildwright
/// panes (no BUILDWRIGHT_PANE_ID), so it never affects normal Claude usage.
enum HooksInstaller {

    static var hookBinary: String {
        Config.home.appendingPathComponent(".local/bin/bw-hook").path
    }

    /// Hook events → bw-hook state argument.
    static let events: [(event: String, state: String)] = [
        ("UserPromptSubmit", "working"),
        ("PreToolUse", "working"),
        ("Notification", "needs-input"),
        ("Stop", "done")
    ]

    static func installIfNeeded() {
        installHookScript()
        mergeSettings()
    }

    private static func installHookScript() {
        let binDir = Config.home.appendingPathComponent(".local/bin")
        try? FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let dest = URL(fileURLWithPath: hookBinary)
        let content = EmbeddedScripts.bwHook
        if (try? String(contentsOf: dest, encoding: .utf8)) != content {
            try? content.write(to: dest, atomically: true, encoding: .utf8)
            _ = ShellExec.run(["chmod", "+x", dest.path])
        }
    }

    private static func mergeSettings() {
        let file = Config.claudeSettingsFile
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: file),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = obj
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var changed = false

        for (event, state) in events {
            var entries = hooks[event] as? [[String: Any]] ?? []
            let command = "\(hookBinary) \(state)"
            let alreadyInstalled = entries.contains { entry in
                guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
                return inner.contains { ($0["command"] as? String)?.contains("bw-hook") == true }
            }
            if !alreadyInstalled {
                entries.append([
                    "hooks": [["type": "command", "command": command]]
                ])
                hooks[event] = entries
                changed = true
            }
        }

        guard changed else { return }
        root["hooks"] = hooks
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: file, options: .atomic)
        } catch {
            NSLog("Buildwright: could not update Claude settings: \(error)")
        }
    }
}
