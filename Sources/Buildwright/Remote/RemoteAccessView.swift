import SwiftUI

struct RemoteCheck: Identifiable {
    let id = UUID()
    let name: String
    let passed: Bool
    let detail: String
    let fix: String?
}

/// Settings panel that verifies the plumbing for iPad/Blink access and shows
/// copy-paste connection commands.
struct RemoteAccessView: View {
    @EnvironmentObject var app: AppState
    @State private var checks: [RemoteCheck] = []
    @State private var hostname = ""
    @State private var tailscaleHost: String?
    @State private var running = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Remote Access (iPad / Blink Shell)").font(.headline)
                    Spacer()
                    Button {
                        runChecks()
                    } label: {
                        Label("Re-check", systemImage: "arrow.clockwise")
                    }
                    .disabled(running)
                }

                Text("Attach to any workspace from Blink Shell on your iPad. Sessions are real tmux sessions, so everything keeps running whether or not this app is open.")
                    .font(.caption).foregroundStyle(.secondary)

                ForEach(checks) { check in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(check.passed ? .green : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(check.name).font(.system(size: 12, weight: .semibold))
                            Text(check.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                            if !check.passed, let fix = check.fix {
                                Text(fix)
                                    .font(.system(size: 11, design: .monospaced))
                                    .padding(6)
                                    .background(.quaternary.opacity(0.5))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }

                Divider()

                Text("Connect from Blink").font(.headline)
                connectBlock(title: "Same network (mosh — survives WiFi drops)",
                             command: "mosh \(connectHost) -- tmux attach -t \(exampleSession)")
                connectBlock(title: "Same network (plain ssh)",
                             command: "ssh \(connectHost) -t tmux attach -t \(exampleSession)")
                if let ts = tailscaleHost {
                    connectBlock(title: "Anywhere via Tailscale",
                                 command: "mosh \(NSUserName())@\(ts) -- tmux attach -t \(exampleSession)")
                }
                connectBlock(title: "Workspace picker (uses the bw helper)",
                             command: "ssh \(connectHost) -t '~/.local/bin/bw ls'")

                Text("Status glyphs in the tmux bar: ● working ◉ needs you ✓ done")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .onAppear { runChecks() }
    }

    private var exampleSession: String {
        app.activeWorkspace?.tmuxSessionName ?? "docai"
    }

    private var connectHost: String {
        "\(NSUserName())@\(hostname.isEmpty ? "your-mac.local" : hostname)"
    }

    private func connectBlock(title: String, command: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            HStack {
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy")
            }
            .padding(8)
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func runChecks() {
        running = true
        DispatchQueue.global(qos: .userInitiated).async {
            var results: [RemoteCheck] = []

            let host = ShellExec.run(["scutil", "--get", "LocalHostName"])
            let localHost = host.ok ? host.stdout.trimmingCharacters(in: .whitespacesAndNewlines) + ".local" : ""

            // 1. Remote Login (SSH server)
            let remoteLogin = ShellExec.run(["sh", "-c", "systemsetup -getremotelogin 2>/dev/null || echo unknown"])
            let sshOn = remoteLogin.stdout.lowercased().contains("on")
            let sshKnown = !remoteLogin.stdout.lowercased().contains("unknown") && remoteLogin.ok
            results.append(RemoteCheck(
                name: "Remote Login (SSH)",
                passed: sshOn,
                detail: sshOn ? "Your Mac accepts SSH connections."
                    : sshKnown ? "SSH is off — the iPad can't connect."
                    : "Couldn't determine (needs admin). Check System Settings → General → Sharing → Remote Login.",
                fix: sshOn ? nil : "System Settings → General → Sharing → turn on “Remote Login”"
            ))

            // 2. mosh
            let mosh = ShellExec.run(["sh", "-c", "command -v mosh-server"])
            results.append(RemoteCheck(
                name: "mosh (roaming connections)",
                passed: mosh.ok,
                detail: mosh.ok ? "mosh-server found — connections survive WiFi↔cellular switches."
                    : "Not installed. SSH still works; mosh adds resilience on the move.",
                fix: mosh.ok ? nil : "brew install mosh"
            ))

            // 3. tmux
            let tmux = ShellExec.run(["tmux", "-V"])
            results.append(RemoteCheck(
                name: "tmux",
                passed: tmux.ok,
                detail: tmux.ok ? tmux.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    : "tmux not found — Buildwright needs it for everything.",
                fix: tmux.ok ? nil : "brew install tmux"
            ))

            // 4. Tailscale
            let ts = ShellExec.run(["sh", "-c", "command -v tailscale >/dev/null && tailscale status --json 2>/dev/null | head -c 200"])
            var tsHost: String?
            if ts.ok && !ts.stdout.isEmpty {
                let dns = ShellExec.run(["sh", "-c", "tailscale status --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"Self\"][\"DNSName\"].rstrip(\".\"))' 2>/dev/null"])
                if dns.ok {
                    let name = dns.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { tsHost = name }
                }
            }
            results.append(RemoteCheck(
                name: "Tailscale (access from anywhere)",
                passed: tsHost != nil,
                detail: tsHost != nil ? "Connected — reach this Mac from any network as \(tsHost!)."
                    : "Optional. Without it, the iPad must be on the same network (or use port forwarding).",
                fix: tsHost != nil ? nil : "brew install --cask tailscale  (then sign in on Mac and iPad)"
            ))

            DispatchQueue.main.async {
                self.checks = results
                self.hostname = localHost
                self.tailscaleHost = tsHost
                self.running = false
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
            RemoteAccessView()
                .tabItem { Label("Remote Access", systemImage: "ipad.and.iphone") }
            templatesTab
                .tabItem { Label("Templates", systemImage: "wand.and.stars") }
            cvrTab
                .tabItem { Label("CVR", systemImage: "record.circle") }
            PluginsView()
                .tabItem { Label("Plugins", systemImage: "puzzlepiece.extension") }
        }
        .frame(width: 620, height: 480)
    }

    private var templatesTab: some View {
        Form {
            Section("Breakfix pane prompt") {
                TextEditor(text: Binding(
                    get: { app.breakfixPrompt },
                    set: { app.breakfixPrompt = $0; app.persist() }
                ))
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 130)
                Button("Reset to default") {
                    app.breakfixPrompt = AppState.defaultBreakfixPrompt
                    app.persist()
                }
            }
            Section("Chat pane prompt (backlog thinking partner)") {
                TextEditor(text: Binding(
                    get: { app.chatPrompt },
                    set: { app.chatPrompt = $0; app.persist() }
                ))
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 110)
                Button("Reset to default") {
                    app.chatPrompt = AppState.defaultChatPrompt
                    app.persist()
                }
            }
            Section("Feature pane prompt") {
                TextEditor(text: Binding(
                    get: { app.featurePrompt },
                    set: { app.featurePrompt = $0; app.persist() }
                ))
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 130)
                Button("Reset to default") {
                    app.featurePrompt = AppState.defaultFeaturePrompt
                    app.persist()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var generalTab: some View {
        Form {
            Section("Claude Code") {
                Picker("Model", selection: Binding(
                    get: { app.claudeModel },
                    set: { app.claudeModel = $0 }
                )) {
                    ForEach(AppState.modelChoices, id: \.id) { choice in
                        Text(choice.label).tag(choice.id)
                    }
                }
                .fixedSize()
                Text("Passed as --model to every claude invocation — new panes and the headless planner/groomer. Opus 4.8 is the safe default; Fable 5 is currently unavailable for headless runs. Existing panes keep the model they started with.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Skip permission prompts (--dangerously-skip-permissions)",
                       isOn: Binding(
                        get: { app.claudeSkipPermissions },
                        set: { app.claudeSkipPermissions = $0 }
                       ))
                Text("Applies to new Claude panes. Existing panes keep the mode they started with.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Workspace automation (\(app.activeWorkspace?.name ?? "—"))") {
                TextField("Test command (merge gate)", text: Binding(
                    get: { app.activeWorkspace?.testCommand ?? "" },
                    set: { v in if let id = app.activeWorkspace?.id { app.setTestCommand(v, forWorkspace: id) } }
                ))
                .font(.system(size: 11, design: .monospaced))
                TextField("Incident probe command (5-min cadence)", text: Binding(
                    get: { app.activeWorkspace?.incidentProbeCommand ?? "" },
                    set: { v in
                        if let wi = app.workspaces.firstIndex(where: { $0.id == app.activeWorkspace?.id }) {
                            app.workspaces[wi].incidentProbeCommand = v
                            app.persist()
                        }
                    }
                ))
                .font(.system(size: 11, design: .monospaced))
                TextField("Backlog category (sidebar scoping)", text: Binding(
                    get: { app.activeWorkspace?.backlogCategory ?? "" },
                    set: { v in
                        if let wi = app.workspaces.firstIndex(where: { $0.id == app.activeWorkspace?.id }) {
                            app.workspaces[wi].backlogCategory = v
                            app.persist()
                        }
                    }
                ))
                .font(.system(size: 11, design: .monospaced))
                Text("Tests run in the worktree before every merge (red = blocked, override available). The probe's non-empty output files a P1 breakfix item with the evidence attached. Backlog category: which board category this workspace claims (empty = the workspace name); the sidebar hides other workspaces' categories unless \"all\" is checked.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            PermissionsSection(permissions: app.permissions)
            Section("Backlog planning") {
                Toggle("Plan the backlog automatically at launch",
                       isOn: Binding(
                        get: { app.autoPlanOnLaunch },
                        set: { app.autoPlanOnLaunch = $0; app.persist() }
                       ))
                Text("Re-plans when the board changed since the last plan or the plan is older than a day. One headless Claude session per run; results appear in the sidebar's Up Next strip and ⇧⌘P.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Terminal") {
                LabeledContent("Font size") {
                    HStack {
                        Slider(value: Binding(
                            get: { app.terminalFontSize },
                            set: { app.terminalFontSize = $0 }
                        ), in: 9...22, step: 1)
                        .frame(width: 180)
                        Text("\(Int(app.terminalFontSize)) pt")
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                Text("Applies immediately to every terminal pane.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Browser") {
                Toggle("Open browser panes in private mode",
                       isOn: Binding(
                        get: { app.browserPrivateByDefault },
                        set: { app.browserPrivateByDefault = $0 }
                       ))
                Text("Private panes save no cookies, logins, or history — everything vanishes when the app quits. Applies to new panes; use the glasses button in a browser pane to switch an existing one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("State file") {
                    Text(Config.stateDirectory.path)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent("Backlog board") {
                    Text(Config.backlogDirectory.path)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent("Claude hooks") {
                    Text("Installed in ~/.claude/settings.json (bw-hook reports pane status; no-op outside Buildwright panes)")
                        .font(.system(size: 11))
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var cvrTab: some View {
        Form {
            Section("CVR tool location") {
                TextField("Path", text: Binding(
                    get: { app.cvrPath },
                    set: { app.cvrPath = $0; app.persist() }
                ))
                .font(.system(size: 11, design: .monospaced))
                Text(FileManager.default.fileExists(atPath: app.cvrPath + "/record.ts")
                     ? "✓ record.ts found"
                     : "record.ts not found at this path")
                    .font(.caption)
                    .foregroundStyle(FileManager.default.fileExists(atPath: app.cvrPath + "/record.ts") ? .green : .orange)
            }
            Section("Window docking") {
                Text("Auto-docking the Chromium window uses macOS Accessibility. The first time you use it, approve Buildwright in System Settings → Privacy & Security → Accessibility. If you skip it, CVR still records — the window just won't be tiled automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

/// "Pre-authorize before AFK": shows each privacy grant's status and a button
/// to trigger the prompt on your terms. macOS won't let the app self-approve
/// (by design) — these just surface and prime the prompts so nothing blocks
/// while you're away. Grants persist across updates only with a stable
/// signing identity (Scripts/make-signing-cert.sh).
struct PermissionsSection: View {
    @ObservedObject var permissions: PermissionsManager

    var body: some View {
        Section("Permissions (pre-authorize for AFK)") {
            row(title: "Automation (access data from other apps)",
                detail: "CVR window tiling + notifications send Apple Events to System Events.",
                state: permissions.automation,
                action: { permissions.primeAutomation() },
                openSettings: { permissions.openAutomationSettings() })

            row(title: "Accessibility",
                detail: "Positioning other apps' windows (CVR docking) goes through System Events.",
                state: permissions.accessibility,
                action: { permissions.primeAccessibility() },
                openSettings: { permissions.openAccessibilitySettings() })

            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Notifications").font(.system(size: 12, weight: .medium))
                    Text("AFK pings (needs-you / done / incident) deliver here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Send test") { permissions.sendTestNotification() }
                    .controlSize(.small)
                Button("Open Settings") { permissions.openNotificationSettings() }
                    .controlSize(.small)
            }

            HStack {
                Button("Re-check all") { permissions.refresh() }
                    .controlSize(.small)
                Spacer()
                Button("Prime all prompts now") {
                    permissions.primeAutomation()
                    permissions.primeAccessibility()
                }
                .controlSize(.small)
                .help("Trigger each prompt so you approve on your terms before going AFK")
            }
            Text("macOS won't let Buildwright approve its own prompts — that's the sandbox. These surface and trigger them so you decide. A one-time Allow persists across updates only when the app is signed with a stable identity (run Scripts/make-signing-cert.sh once); ad-hoc builds re-ask every update.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(title: String, detail: String, state: PermissionState,
                     action: @escaping () -> Void, openSettings: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 12, weight: .medium))
                    statusChip(state)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if state == .denied {
                Button("Open Settings", action: openSettings).controlSize(.small)
            } else if !state.ok {
                Button("Grant…", action: action).controlSize(.small)
            }
        }
    }

    private func statusChip(_ state: PermissionState) -> some View {
        let color: Color = state == .granted ? .green : (state == .denied ? .red : .orange)
        return Text(state.label)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}
