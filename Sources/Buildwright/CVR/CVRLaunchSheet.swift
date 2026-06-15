import SwiftUI
import AppKit

/// Launches a CVR recording session (the user's existing Playwright capture
/// tool) in a new shell pane, optionally docking the Chromium window beside
/// the IDE via AppleScript (requires Accessibility permission; degrades
/// gracefully if denied).
struct CVRLaunchSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var url = ""
    @State private var label = ""
    @State private var env = "production"
    @State private var user = ""
    @State private var dockSide = "right"
    @State private var autoDock = true

    /// Installed CVR plugin path (preferred — self-contained), if present.
    private var cvrPluginPath: String? { PluginManager.shared.plugin(named: "cvr")?.path.path }

    private var cvrExists: Bool {
        if let p = cvrPluginPath, FileManager.default.fileExists(atPath: p + "/src/record.ts") { return true }
        return FileManager.default.fileExists(atPath: app.cvrPath + "/record.ts") // legacy fallback
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("CVR Recording Session").font(.title3).bold()
            Text("Opens a real Chromium window with CVR capturing — drive it normally, then hit ✓ Finish in the browser.")
                .font(.caption).foregroundStyle(.secondary)

            if !cvrExists {
                Label("CVR not found — install the CVR plugin in Settings → Plugins (or set a path in Settings → CVR)", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }

            TextField("URL to record", text: $url).textFieldStyle(.roundedBorder)
            TextField("Label (e.g. efilemn-notice-of-appearance)", text: $label).textFieldStyle(.roundedBorder)
            HStack {
                Picker("Environment", selection: $env) {
                    Text("production").tag("production")
                    Text("staging").tag("staging")
                    Text("dev").tag("dev")
                }
                .fixedSize()
                TextField("User (optional)", text: $user).textFieldStyle(.roundedBorder)
            }
            HStack {
                Toggle("Dock Chromium window", isOn: $autoDock)
                Picker("", selection: $dockSide) {
                    Text("left of IDE").tag("left")
                    Text("right of IDE").tag("right")
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .disabled(!autoDock)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Start Recording") {
                    launch()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(url.isEmpty || label.isEmpty || !cvrExists)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func launch() {
        // Interlink: run CVR in the INITIATING workspace's context and write
        // captures into that workspace, so a recording belongs to the project
        // the calling terminal is in.
        let ws = app.activeWorkspace
        var initiatingDir = ws?.baseRepo ?? app.cvrPath
        if let tab = ws?.activeTab, let pid = tab.focusedPaneID,
           let p = tab.pane(pid), !p.directory.isEmpty {
            initiatingDir = p.directory
        }
        let capturesDir = initiatingDir + "/cvr-captures"

        // Prefer the installed, self-contained plugin (agent-callable CLI, abs
        // path so cwd can be the workspace); fall back to the legacy path.
        var cmd: String
        let paneDir: String
        if let plugin = cvrPluginPath {
            cmd = "node \(shellQuote(plugin + "/bin/cvr.mjs")) record"
            paneDir = initiatingDir
        } else {
            cmd = "npx tsx record.ts"
            paneDir = app.cvrPath
        }
        cmd += " --url \(shellQuote(url)) --label \(shellQuote(label)) --env \(shellQuote(env)) --captures-dir \(shellQuote(capturesDir))"
        if !user.isEmpty { cmd += " --user \(shellQuote(user))" }

        // Run inside a shell pane (in the workspace) so output + finish flow are
        // visible right where the work is — status streams back to the pane.
        app.addPane(kind: .shell, axis: .horizontal, directory: paneDir,
                    title: "cvr: \(label)")
        if let ws2 = app.activeWorkspace, let tab = ws2.activeTab,
           let paneID = tab.focusedPaneID, let pane = tab.pane(paneID),
           let windowID = pane.tmuxWindowID {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                _ = ShellExec.run(["tmux", "send-keys", "-t", windowID, cmd, "Enter"])
            }
        }
        if autoDock {
            CVRWindowDocker.dockChromiumWhenItAppears(side: dockSide)
        }
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum CVRWindowDocker {
    /// Poll for the Chromium window CVR launches and tile it beside the IDE.
    /// Uses System Events (Accessibility). If permission is denied, this
    /// silently does nothing — CVR still works, just un-docked.
    static func dockChromiumWhenItAppears(side: String) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let half = screen.width / 2
        let chromX = side == "left" ? screen.minX : screen.minX + half
        let ideX = side == "left" ? screen.minX + half : screen.minX

        // Move our own window first (we always can).
        DispatchQueue.main.async {
            if let window = NSApp.windows.first(where: { $0.isVisible }) {
                window.setFrame(NSRect(x: ideX, y: screen.minY, width: half, height: screen.height), display: true, animate: true)
            }
        }

        let script = """
        set tries to 0
        repeat
            set tries to tries + 1
            if tries > 60 then exit repeat
            tell application "System Events"
                set chromiumProcs to (every process whose name contains "Chromium")
                if (count of chromiumProcs) > 0 then
                    tell item 1 of chromiumProcs
                        if (count of windows) > 0 then
                            set position of window 1 to {\(Int(chromX)), \(Int(screen.minY))}
                            set size of window 1 to {\(Int(half)), \(Int(screen.height))}
                            exit repeat
                        end if
                    end tell
                end if
            end tell
            delay 1
        end repeat
        """
        ShellExec.runDetached(["osascript", "-e", script])
    }
}
