import SwiftUI
import Foundation

/// A plugin's manifest (`plugin.json` at the repo root). Only the fields
/// Buildwright needs are decoded; unknown keys (ui/settings/requires) are ignored.
struct PluginManifest: Codable {
    let name: String
    var displayName: String?
    var version: String?
    var repo: String?
    var description: String?
    /// Shell command run after clone to make the plugin runnable (e.g.
    /// "npm ci && npx playwright install chromium").
    var install: String?
    /// Shell command run on update (defaults to `git pull` if absent).
    var update: String?
    /// Relative path to the plugin's CLI entry (agent-callable), e.g. "bin/cvr.mjs".
    var cli: String?
    /// Named example invocations for the CLI.
    var commands: [String: String]?
}

struct InstalledPlugin: Identifiable {
    var id: String { manifest.name }
    let manifest: PluginManifest
    let path: URL
}

/// Buildwright's lightweight TOOL-plugin mechanism: install external tools from
/// GitHub by manifest, into ~/.buildwright/plugins/<name>/. This is for tools
/// Buildwright launches (CVR is the first) — NOT in-app/editor extensions.
@MainActor
final class PluginManager: ObservableObject {
    static let shared = PluginManager()

    @Published private(set) var plugins: [InstalledPlugin] = []
    @Published private(set) var busy = false
    @Published private(set) var lastLog = ""

    private init() { refresh() }

    /// Rescan the plugins directory and rebuild the installed list.
    func refresh() {
        let dir = Config.pluginsDirectory
        let subs = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var found: [InstalledPlugin] = []
        for sub in subs {
            let isDir = (try? sub.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir, let m = Self.readManifest(at: sub) else { continue }
            found.append(InstalledPlugin(manifest: m, path: sub))
        }
        plugins = found.sorted { $0.manifest.name < $1.manifest.name }
    }

    /// Install from a GitHub source ("owner/repo" or an https URL). Clones via
    /// `gh repo clone` (so private repos work with the user's gh auth), then runs
    /// the manifest's install step. Long-running (npm + browser download), so it
    /// runs off the main thread with output captured into `lastLog`.
    func install(source: String) {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !source.isEmpty else { return }
        let name = Self.deriveName(source)
        let pluginsDir = Config.pluginsDirectory
        let target = pluginsDir.appendingPathComponent(name)
        busy = true
        lastLog = "Installing \(name) from \(source)…\n"
        Task.detached(priority: .userInitiated) {
            try? FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: target) // clean (re)install
            let clone = ShellExec.run(["gh", "repo", "clone", source, target.path])
            var log = clone.stdout + clone.stderr
            guard clone.ok else {
                await self.finish(append: log + "\n✗ clone failed (is gh installed + authed?)", ok: false)
                return
            }
            guard let manifest = Self.readManifest(at: target) else {
                await self.finish(append: log + "\n✗ no valid plugin.json at repo root", ok: false)
                return
            }
            if let install = manifest.install, !install.isEmpty {
                let res = ShellExec.run(["bash", "-lc", install], cwd: target.path)
                log += "\n$ \(install)\n" + res.stdout + res.stderr
                guard res.ok else {
                    await self.finish(append: log + "\n✗ install step failed", ok: false)
                    return
                }
            }
            await self.finish(append: log + "\n✓ installed \(manifest.name) \(manifest.version ?? "")", ok: true)
        }
    }

    func update(_ plugin: InstalledPlugin) {
        guard !busy else { return }
        let target = plugin.path
        let cmd = plugin.manifest.update ?? "git pull"
        busy = true
        lastLog = "Updating \(plugin.manifest.name)…\n"
        Task.detached(priority: .userInitiated) {
            let res = ShellExec.run(["bash", "-lc", cmd], cwd: target.path)
            await self.finish(append: "$ \(cmd)\n" + res.stdout + res.stderr, ok: res.ok)
        }
    }

    func remove(_ plugin: InstalledPlugin) {
        try? FileManager.default.removeItem(at: plugin.path)
        refresh()
    }

    func plugin(named name: String) -> InstalledPlugin? {
        plugins.first { $0.manifest.name == name }
    }

    private func finish(append log: String, ok: Bool) {
        lastLog += log
        busy = false
        refresh()
    }

    // MARK: Helpers

    nonisolated static func readManifest(at dir: URL) -> PluginManifest? {
        let file = dir.appendingPathComponent("plugin.json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(PluginManifest.self, from: data)
    }

    /// Derive the install folder name from a source ("…/cvr.git" → "cvr").
    nonisolated static func deriveName(_ source: String) -> String {
        var s = source
        if s.hasSuffix(".git") { s.removeLast(4) }
        while s.hasSuffix("/") { s.removeLast() }
        return String(s.split(separator: "/").last ?? "plugin")
    }
}

/// Settings → Plugins tab: install from GitHub, list / update / remove.
struct PluginsView: View {
    @ObservedObject private var manager = PluginManager.shared
    @State private var source = ""

    var body: some View {
        Form {
            Section("Install a plugin from GitHub") {
                HStack {
                    TextField("owner/repo or https URL (e.g. sealmindset/cvr)", text: $source)
                        .textFieldStyle(.roundedBorder)
                    Button("Install") { manager.install(source: source) }
                        .disabled(manager.busy || source.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Clones to ~/.buildwright/plugins via your gh auth (works with private repos), then runs the plugin's install step.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Installed plugins") {
                if manager.plugins.isEmpty {
                    Text("No plugins installed.").foregroundStyle(.secondary)
                } else {
                    ForEach(manager.plugins) { p in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.manifest.displayName ?? p.manifest.name)
                                    .font(.system(size: 12, weight: .semibold))
                                Text((p.manifest.version.map { "v\($0)  " } ?? "") + p.path.path)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                if let d = p.manifest.description {
                                    Text(d).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Update") { manager.update(p) }.disabled(manager.busy)
                            Button(role: .destructive) { manager.remove(p) } label: { Text("Remove") }
                                .disabled(manager.busy)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if manager.busy || !manager.lastLog.isEmpty {
                Section(manager.busy ? "Working…" : "Last operation") {
                    if manager.busy { ProgressView() }
                    ScrollView {
                        Text(manager.lastLog)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 140)
                }
            }
        }
        .onAppear { manager.refresh() }
    }
}
