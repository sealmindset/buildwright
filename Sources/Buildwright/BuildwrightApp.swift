import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running as a bare SPM executable: promote to a regular app so the
        // window comes to the front with a dock icon.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        GlobalHotkey.register() // ⌥⌘B anywhere → summon + Mission Control
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Legacy sweep: pre-control-mode builds left hidden `_bw-` helper
        // sessions behind. Workspace sessions are untouched and keep
        // running (that's the whole point).
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
            // Standard Edit menu. SwiftTerm implements copy:/paste:/selectAll:
            // but does NOT handle ⌘C/⌘V in keyDown — it relies on these menu
            // items to route the shortcut to the focused terminal through the
            // responder chain. Without this menu, ⌘V did nothing in a pane.
            // `to: nil` dispatches to the first responder; AppKit auto-disables
            // an item the focused view can't handle (e.g. Cut in a terminal).
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                    .keyboardShortcut("x", modifiers: .command)
                Button("Copy") { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
                    .keyboardShortcut("c", modifiers: .command)
                Button("Paste") { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
                    .keyboardShortcut("v", modifiers: .command)
                Button("Select All") { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
                    .keyboardShortcut("a", modifiers: .command)
            }
            CommandMenu("Panes") {
                Button("New Claude Pane (split right)") { app.addPane(kind: .claude, axis: .horizontal) }
                    .keyboardShortcut("n", modifiers: .command)
                Button("New Claude Pane (split down)") { app.addPane(kind: .claude, axis: .vertical) }
                Button("New Claude Pane (isolated worktree)") { app.addPane(kind: .claude, worktree: true) }
                    .keyboardShortcut("n", modifiers: [.command, .control])
                Button("Tee Up Next…") { app.showTeeUpSheet = true }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                Button("New Chat Pane (backlog ideas)") { app.addChatPane() }
                Button("New Diff Review Pane") { app.addPane(kind: .diff) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
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
                        app.requestClosePane(focus)
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
                Divider()
                Button("Refresh Pane from tmux") { app.refreshFocusedPane() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Refresh All Panes") { TerminalViewCache.shared.refreshAllPanes() }
                Divider()
                Button("Zoom Focused Pane") { app.toggleZoom() }
                    .keyboardShortcut(.return, modifiers: .command)
                Button(app.broadcastMode ? "Disarm Broadcast Input" : "Broadcast Input to Tab") {
                    app.toggleBroadcast()
                }
                .keyboardShortcut("b", modifiers: [.command, .control])
            }
            CommandMenu("Attention") {
                Button("Jump to Next Needing You") { app.jumpToNextAttention() }
                    .keyboardShortcut("j", modifiers: .command)
                Button("Command Palette…") { app.showPalette = true }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Mission Control") { app.showMissionControl = true }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Plan Backlog (AI)…") { app.showPlanSheet = true }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Groom Backlog (AI)…") { app.showGroomSheet = true }
                Divider()
                Button("Copy Diagnostics Snapshot") { app.copyDiagnostics() }
                Button("Capture to Backlog (AI triage)…") { app.showScrumCapture = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Capture a Thought…") { app.showCapture = true }
                    .keyboardShortcut("i", modifiers: [.command, .option])
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
                Button("Save Tab Layout as Template…") { app.promptSaveTemplate() }
                Menu("New Tab from Template") {
                    ForEach(app.layoutTemplates) { template in
                        Button(template.name) { app.newTab(fromTemplate: template) }
                    }
                    if app.layoutTemplates.isEmpty {
                        Text("No templates saved yet")
                    }
                }
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
