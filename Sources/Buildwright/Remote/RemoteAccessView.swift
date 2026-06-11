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
            cvrTab
                .tabItem { Label("CVR", systemImage: "record.circle") }
        }
        .frame(width: 620, height: 480)
    }

    private var generalTab: some View {
        Form {
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
