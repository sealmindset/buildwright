import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running as a bare SPM executable: promote to a regular app so the
        // window comes to the front with a dock icon.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Our attach clients die with the app, leaving helper sessions
        // unattached — remove them. Workspace sessions are untouched and
        // keep running (that's the whole point).
        TmuxClient().cleanupStaleGroupedSessions()
    }
}

@main
struct BuildwrightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup("Buildwright") {
            MainWindowView()
                .environmentObject(app)
                .onAppear { app.bootstrap() }
        }
        .commands {
            CommandMenu("Panes") {
                Button("New Claude Pane (split right)") { app.addPane(kind: .claude, axis: .horizontal) }
                    .keyboardShortcut("n", modifiers: .command)
                Button("New Claude Pane (split down)") { app.addPane(kind: .claude, axis: .vertical) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("New Shell Pane (split right)") { app.addPane(kind: .shell, axis: .horizontal) }
                    .keyboardShortcut("d", modifiers: .command)
                Button("New Shell Pane (split down)") { app.addPane(kind: .shell, axis: .vertical) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
                Button("New Browser Pane") { app.addPane(kind: .browser, axis: .horizontal) }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Button("CVR Recording Session…") { app.showCVRSheet = true }
                Divider()
                Button("Close Focused Pane") {
                    if let ws = app.activeWorkspace, let tab = ws.activeTab, let focus = tab.focusedPaneID {
                        TerminalViewCache.shared.remove(focus)
                        WebViewCache.shared.remove(focus)
                        app.closePane(focus)
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            CommandMenu("Attention") {
                Button("Jump to Next Needing You") { app.jumpToNextAttention() }
                    .keyboardShortcut("j", modifiers: .command)
                Button("Command Palette…") { app.showPalette = true }
                    .keyboardShortcut("k", modifiers: .command)
            }
            CommandMenu("Focus") {
                Button("Focus Pane Left") { app.movePaneFocus(.left) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("Focus Pane Right") { app.movePaneFocus(.right) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("Focus Pane Up") { app.movePaneFocus(.up) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Focus Pane Down") { app.movePaneFocus(.down) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            }
            CommandMenu("Workspace") {
                Button("New Tab") { app.addTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Close Tab") {
                    if let ws = app.activeWorkspace, let tabID = ws.activeTabID {
                        app.closeTab(tabID)
                    }
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                Divider()
                Button("New Workspace…") { app.showNewWorkspaceSheet = true }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                Divider()
                ForEach(Array(app.workspaces.prefix(9).enumerated()), id: \.element.id) { (idx, ws) in
                    Button("Go to \(ws.name)") { app.switchWorkspace(at: idx) }
                        .keyboardShortcut(KeyEquivalent(Character("\(idx + 1)")), modifiers: [.command, .option])
                }
                Divider()
                Button("Toggle Backlog Sidebar") {
                    app.sidebarVisible.toggle()
                    app.persist()
                }
                .keyboardShortcut("1", modifiers: .command)
            }
        }
        Settings {
            SettingsView()
                .environmentObject(app)
        }
        MenuBarExtra {
            AttentionMenuBarContent()
                .environmentObject(app)
        } label: {
            AttentionMenuBarLabel()
                .environmentObject(app)
        }
    }
}
