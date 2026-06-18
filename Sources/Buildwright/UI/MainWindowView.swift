import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        HSplitView {
            if app.sidebarVisible {
                BacklogSidebarView(store: app.backlog, planner: app.planner, groomer: app.groomer)
                    .frame(minWidth: 230, idealWidth: 280, maxWidth: 420)
            }
            mainArea
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 560)
        .alert("Agent is working", isPresented: Binding(
            get: { app.paneCloseConfirm != nil },
            set: { if !$0 { app.paneCloseConfirm = nil } }
        ), presenting: app.paneCloseConfirm) { _ in
            Button("Close anyway", role: .destructive) { app.confirmPendingClose() }
            Button("Cancel", role: .cancel) { app.paneCloseConfirm = nil }
        } message: { req in
            Text("“\(req.title)” has a task in progress. Close and end it? The transcript persists — you can resume later with `claude --resume`.")
        }
        .sheet(isPresented: $app.showNewWorkspaceSheet) {
            NewWorkspaceSheet()
        }
        .sheet(isPresented: $app.showCVRSheet) {
            CVRLaunchSheet()
        }
        .sheet(isPresented: $app.showPalette) {
            CommandPaletteView()
        }
        .sheet(isPresented: $app.showMissionControl) {
            MissionControlView()
        }
        .sheet(isPresented: $app.showTeeUpSheet) {
            TeeUpSheet()
        }
        .sheet(isPresented: $app.showPlanSheet) {
            BacklogPlanView(planner: app.planner)
        }
        .sheet(isPresented: $app.showCapture) {
            CaptureSheet()
        }
        .sheet(isPresented: $app.showScrumCapture) {
            ScrumCaptureSheet(intake: app.captureIntake)
        }
        .sheet(isPresented: $app.showGroomSheet) {
            BacklogGroomView(groomer: app.groomer)
        }
        .sheet(isPresented: $app.showBacklogGraph) {
            BacklogGraphView(store: app.backlog).environmentObject(app)
        }
        .sheet(isPresented: $app.showReconcileSheet) {
            ReconcileView(reconciler: app.reconciler)
        }
    }

    private var mainArea: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if let notice = app.reentryNotice {
                ReentryStrip(notice: notice)
            }
            if let ws = app.activeWorkspace, let tab = ws.activeTab, let layout = tab.layout {
                // Zoom: render just the zoomed pane instead of the split tree.
                let node: LayoutNode = {
                    if let z = app.zoomedPaneID, layout.contains(z) { return .pane(z) }
                    return layout
                }()
                LayoutView(node: node, tab: tab, workspace: ws, path: [])
                    .padding(3)
                    .background(Color(NSColor.windowBackgroundColor))
            } else {
                emptyState
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { app.sidebarVisible.toggle() }
                app.persist()
            } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.borderless)
            .help("Toggle backlog sidebar (⌘1)")

            Button { app.showBacklogGraph = true } label: {
                Image(systemName: "point.3.connected.trianglepath.dotted")
            }
            .buttonStyle(.borderless)
            .help("Backlog Map — visual dependency/flow view with filters (⇧⌘M)")

            WorkspaceSwitcher()

            Divider().frame(height: 16)

            TabBar()

            Spacer()

            if app.broadcastMode {
                Button { app.toggleBroadcast() } label: {
                    Label("BROADCAST", systemImage: "dot.radiowaves.left.and.right")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.red, in: Capsule())
                .help("Keystrokes go to EVERY terminal pane in this tab — click to disarm (⌃⌘B)")
            }
            if app.zoomedPaneID != nil {
                Button { app.toggleZoom() } label: {
                    Label("zoomed", systemImage: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 9, weight: .medium))
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.blue.opacity(0.15), in: Capsule())
                .help("Pane is zoomed — click to restore the split layout (⌘↩)")
            }

            Menu {
                Button("Claude pane — split right  ⌘N") { app.addPane(kind: .claude, axis: .horizontal) }
                Button("Claude pane — split down") { app.addPane(kind: .claude, axis: .vertical) }
                Divider()
                Button("🔧 Breakfix pane (guarded fix workflow)") { app.addBreakfixPane() }
                Button("✨ Feature pane (guarded feature workflow)") { app.addFeaturePane() }
                Divider()
                Button("⏭ Tee up next…  ⌥⌘T") { app.showTeeUpSheet = true }
                Button("💬 Chat pane (backlog ideas)") { app.addChatPane() }
                Button("±  Diff review pane  ⇧⌘G") { app.addPane(kind: .diff) }
                Divider()
                Button("Shell pane — split right  ⌘D") { app.addPane(kind: .shell, axis: .horizontal) }
                Button("Shell pane — split down  ⇧⌘D") { app.addPane(kind: .shell, axis: .vertical) }
                Divider()
                Button("Browser pane — right") { app.addPane(kind: .browser, axis: .horizontal) }
                Button("Browser pane — left side") { app.addBrowserDocked(side: .left) }
                Button("Browser pane — right side") { app.addBrowserDocked(side: .right) }
                Divider()
                Button("CVR recording session…") { app.showCVRSheet = true }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Add a pane")
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(.bar)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.split.3x1")
                .font(.system(size: 40)).foregroundStyle(.tertiary)
            Text("No panes yet").font(.title3).foregroundStyle(.secondary)
            HStack {
                Button("New Claude pane") { app.addPane(kind: .claude) }
                    .buttonStyle(.borderedProminent)
                Button("New shell") { app.addPane(kind: .shell) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

/// "While you were away" — the 15 minutes of mental reconstruction after a
/// corp↔startup switch, compressed into one line you can read in 3 seconds.
struct ReentryStrip: View {
    @EnvironmentObject var app: AppState
    let notice: AppState.ReentryNotice

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("While you were away from \(notice.workspaceName) (\(ageString(from: notice.awaySince, to: app.now))):")
                    .font(.system(size: 11, weight: .semibold))
                if let item = notice.backlogItemID {
                    Text("You were working on \(item)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                ForEach(notice.lines, id: \.self) { line in
                    Text("• \(line)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if app.needsInputCount > 0 {
                Button("Jump to next ⌘J") { app.jumpToNextAttention(); app.dismissReentry() }
                    .font(.system(size: 11))
            }
            Button {
                app.dismissReentry()
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(.quaternary), alignment: .bottom)
    }
}

struct WorkspaceSwitcher: View {
    @EnvironmentObject var app: AppState
    @State private var confirmDelete: Workspace?

    var body: some View {
        Menu {
            ForEach(app.workspaces) { ws in
                Button {
                    app.switchWorkspace(ws.id)
                } label: {
                    HStack {
                        if ws.id == app.activeWorkspace?.id { Image(systemName: "checkmark") }
                        Text(ws.name)
                    }
                }
            }
            Divider()
            Button("New workspace…") { app.showNewWorkspaceSheet = true }
            if let ws = app.activeWorkspace {
                Button("Delete “\(ws.name)”…", role: .destructive) { confirmDelete = ws }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                Text(app.activeWorkspace?.name ?? "—")
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .confirmationDialog(
            "Delete workspace “\(confirmDelete?.name ?? "")”?",
            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })
        ) {
            Button("Delete and kill tmux sessions", role: .destructive) {
                if let ws = confirmDelete { app.deleteWorkspace(ws.id, killSessions: true) }
                confirmDelete = nil
            }
            Button("Delete (keep tmux sessions alive)") {
                if let ws = confirmDelete { app.deleteWorkspace(ws.id, killSessions: false) }
                confirmDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: {
            Text("“Keep sessions alive” leaves everything running in tmux — you can still attach from any terminal.")
        }
    }
}

struct TabBar: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        HStack(spacing: 2) {
            if let ws = app.activeWorkspace {
                ForEach(ws.tabs) { tab in
                    let active = tab.id == (ws.activeTabID ?? ws.tabs.first?.id)
                    HStack(spacing: 4) {
                        Text(tab.name)
                            .font(.system(size: 11, weight: active ? .semibold : .regular))
                        if ws.tabs.count > 1 {
                            Button {
                                app.closeTab(tab.id)
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 7))
                            }
                            .buttonStyle(.borderless)
                            .opacity(active ? 1 : 0.4)
                        }
                    }
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(active ? Color.accentColor.opacity(0.18) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                    .onTapGesture { app.selectTab(tab.id) }
                }
            }
            Button { app.addTab() } label: {
                Image(systemName: "plus").font(.system(size: 9))
            }
            .buttonStyle(.borderless)
            .help("New tab (⌘T)")
        }
    }
}

struct NewWorkspaceSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var baseRepo = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Workspace").font(.title3).bold()
            Text("A workspace is one project: its own tmux session, tabs, panes, and backlog filters. New panes open in the base folder.")
                .font(.caption).foregroundStyle(.secondary)

            TextField("Name (e.g. docai)", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                TextField("Base folder", text: $baseRepo)
                    .textFieldStyle(.roundedBorder)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.directoryURL = Config.home.appendingPathComponent("Documents/GitHub")
                    if panel.runModal() == .OK, let url = panel.url {
                        baseRepo = url.path
                        if name.isEmpty { name = url.lastPathComponent }
                    }
                }
            }

            HStack {
                Spacer()
                if !app.workspaces.isEmpty {
                    Button("Cancel") { dismiss() }
                }
                Button("Create") {
                    app.createWorkspace(name: name, baseRepo: baseRepo)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || baseRepo.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled(app.workspaces.isEmpty)
    }
}
