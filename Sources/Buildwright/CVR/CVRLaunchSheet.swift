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

    private var cvrExists: Bool {
        FileManager.default.fileExists(atPath: app.cvrPath + "/record.ts")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("CVR Recording Session").font(.title3).bold()
            Text("Opens a real Chromium window with CVR capturing — drive it normally, then hit ✓ Finish in the browser.")
                .font(.caption).foregroundStyle(.secondary)

            if !cvrExists {
                Label("CVR not found at \(app.cvrPath) — set the path in Settings → CVR", systemImage: "exclamationmark.triangle")
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
        var cmd = "npx tsx record.ts --url \(shellQuote(url)) --label \(shellQuote(label)) --env \(shellQuote(env))"
        if !user.isEmpty { cmd += " --user \(shellQuote(user))" }
        // Run inside a shell pane so output (and the finish flow) is visible.
        app.addPane(kind: .shell, axis: .horizontal, directory: app.cvrPath,
                    title: "cvr: \(label)")
        // Type the command into the new pane via tmux send-keys.
        if let ws = app.activeWorkspace, let tab = ws.activeTab,
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
