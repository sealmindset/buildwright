import SwiftUI

/// Read-only diff review pane: see what an agent changed without leaving the
/// cockpit. Two modes — uncommitted work, or everything on this branch since
/// it diverged from the base branch. For clean worktree branches, a guarded
/// merge closes the review loop.
struct DiffPaneView: View {
    @EnvironmentObject var app: AppState
    let pane: Pane

    @State private var mode: GitDiff.Mode = .uncommitted
    @State private var lines: [GitDiff.Line] = []
    @State private var truncated = false
    @State private var added = 0
    @State private var removed = 0
    @State private var untracked: [String] = []
    @State private var error: String?
    @State private var baseBranch = "main"
    @State private var currentBranch: String?
    @State private var loading = false
    @State private var refreshTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let error {
                Spacer()
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .padding()
                Spacer()
            } else if lines.isEmpty {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text(mode == .uncommitted ? "No uncommitted changes" : "No changes vs \(baseBranch)")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                diffBody
            }
            if !untracked.isEmpty && mode == .uncommitted {
                Divider()
                Text("untracked (not shown): \(untracked.joined(separator: ", "))")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .padding(6)
            }
        }
        .onAppear {
            setup() // refresh() runs when setup's git lookups land
            // Light auto-refresh while visible — agents keep editing.
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                Task { @MainActor in refresh() }
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $mode) {
                Text("Uncommitted").tag(GitDiff.Mode.uncommitted)
                Text("vs \(baseBranch)").tag(GitDiff.Mode.branch)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            .onChange(of: mode) { refresh() }

            if added + removed > 0 {
                Text("+\(added)").font(.caption.monospacedDigit()).foregroundStyle(.green)
                Text("−\(removed)").font(.caption.monospacedDigit()).foregroundStyle(.red)
            }
            if loading { ProgressView().controlSize(.small) }
            Spacer()
            if let branch = currentBranch, mode == .branch, branch != baseBranch {
                Button("Merge into \(baseBranch)…") { confirmMerge(branch: branch) }
                    .controlSize(.small)
                    .help("Guarded: refuses on uncommitted changes; aborts cleanly on conflicts")
            }
            Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh (auto-refreshes every 5s)")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
    }

    private var diffBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    DiffLineView(line: line)
                }
                if truncated {
                    Text("— diff truncated (very large) — use a shell pane for the rest —")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(8)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    private func setup() {
        // git calls off the main thread — the pane appears instantly.
        let dir = pane.directory
        let isWorktreePane = pane.worktreeBranch != nil
        DispatchQueue.global(qos: .userInitiated).async {
            let base = GitDiff.defaultBranch(repo: dir)
            let branch = GitDiff.currentBranch(dir: dir)
            DispatchQueue.main.async {
                baseBranch = base
                currentBranch = branch
                // Worktree panes exist to be reviewed against base.
                if isWorktreePane || branch?.hasPrefix("bw/") == true { mode = .branch }
                refresh()
            }
        }
    }

    private func refresh() {
        guard !loading else { return }
        loading = true
        let dir = pane.directory
        let mode = mode
        let base = baseBranch
        DispatchQueue.global(qos: .userInitiated).async {
            let result = GitDiff.diff(dir: dir, mode: mode, base: base)
            let untrackedNow = mode == .uncommitted ? GitDiff.untrackedFiles(dir: dir) : []
            let branchNow = GitDiff.currentBranch(dir: dir)
            DispatchQueue.main.async {
                loading = false
                currentBranch = branchNow
                switch result {
                case .success(let text):
                    let parsed = GitDiff.parse(text)
                    lines = parsed.lines
                    truncated = parsed.truncated
                    added = parsed.added
                    removed = parsed.removed
                    untracked = untrackedNow
                    error = nil
                case .failure(let why):
                    error = TranscriptReader.condense(why, limit: 200)
                }
            }
        }
    }

    /// Diffs touching these surfaces (or very large diffs) require the
    /// independent fresh-context review before merging.
    private var isRiskyDiff: Bool {
        if added + removed > 400 { return true }
        let riskyMarkers = ["prisma/", "migrations", "Dockerfile", "terraform",
                            ".env", "auth", "docker-compose", ".github/workflows"]
        return lines.contains { line in
            line.kind == .file && riskyMarkers.contains { line.text.localizedCaseInsensitiveContains($0) }
        }
    }

    @State private var gateBusy = false
    @State private var reviewApproved = false

    /// The merge gauntlet: tests must pass (hard gate, per-workspace command,
    /// asked once), risky diffs need the independent review, THEN merge.
    private func confirmMerge(branch: String) {
        guard !gateBusy, let ws = app.activeWorkspace else { return }
        var cmd = ws.testCommand
        if cmd == nil {
            cmd = promptForTestCommand()
            guard let entered = cmd else { return } // cancelled
            app.setTestCommand(entered, forWorkspace: ws.id)
        }
        if isRiskyDiff && !reviewApproved {
            runIndependentReview(branch: branch, thenTests: cmd ?? "")
            return
        }
        runTestsThenMerge(branch: branch, testCommand: cmd ?? "")
    }

    /// nil = cancelled; "" = user disabled the gate for this workspace.
    private func promptForTestCommand() -> String? {
        let alert = NSAlert()
        alert.messageText = "Test command for this project?"
        alert.informativeText = "Runs in the worktree before every merge; red tests block the merge. Leave empty to disable the gate for this workspace."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "e.g. npm test"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespaces)
    }

    private func runIndependentReview(branch: String, thenTests cmd: String) {
        gateBusy = true
        let dir = pane.directory
        let base = baseBranch
        ShellExec.notify(title: "Independent review running", body: "Fresh-context pass over \(branch) — risky surface detected")
        DispatchQueue.global(qos: .userInitiated).async {
            let prompt = """
            You are an independent reviewer with NO context from the implementation. \
            Run `git diff \(base)...HEAD` and review every change for bugs, security \
            issues, schema/config hazards, and unintended behavior. Reply ONLY with \
            JSON: {"verdict":"approve"|"concerns","notes":["one line each"]}
            """
            let result = ShellExec.run(
                ["claude", "-p", prompt, "--output-format", "json",
                 "--allowedTools", "Read,Glob,Grep,Bash(git diff:*),Bash(git log:*),Bash(git show:*)"],
                cwd: dir)
            DispatchQueue.main.async {
                gateBusy = false
                if let env = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any] {
                    if let cost = env["total_cost_usd"] as? Double { app.recordAISpend(cost) }
                    if let text = env["result"] as? String,
                       let s0 = text.firstIndex(of: "{"), let e0 = text.lastIndex(of: "}"),
                       let obj = try? JSONSerialization.jsonObject(with: Data(String(text[s0...e0]).utf8)) as? [String: Any] {
                        let verdict = obj["verdict"] as? String ?? "concerns"
                        let notes = (obj["notes"] as? [String]) ?? []
                        let alert = NSAlert()
                        alert.messageText = verdict == "approve"
                            ? "Independent review: approved"
                            : "Independent review: concerns"
                        alert.informativeText = notes.isEmpty ? "No notes." : notes.joined(separator: "\n")
                        alert.addButton(withTitle: verdict == "approve" ? "Continue to Tests" : "Merge Anyway Path")
                        alert.addButton(withTitle: "Cancel")
                        guard alert.runModal() == .alertFirstButtonReturn else { return }
                        reviewApproved = true
                        runTestsThenMerge(branch: branch, testCommand: cmd)
                        return
                    }
                }
                ShellExec.notify(title: "Review failed to run", body: "Merge blocked — try again or use Refresh")
            }
        }
    }

    private func runTestsThenMerge(branch: String, testCommand: String) {
        guard !testCommand.isEmpty else { performMerge(branch: branch); return }
        gateBusy = true
        let dir = pane.directory
        ShellExec.notify(title: "Running tests before merge", body: testCommand)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ShellExec.run(["sh", "-c", testCommand], cwd: dir)
            DispatchQueue.main.async {
                gateBusy = false
                if result.ok {
                    performMerge(branch: branch)
                } else {
                    let alert = NSAlert()
                    alert.messageText = "Tests failed — merge blocked"
                    alert.informativeText = TranscriptReader.condense(
                        result.stderr.isEmpty ? result.stdout.suffix(1000).description : result.stderr, limit: 600)
                    alert.addButton(withTitle: "Cancel")
                    alert.addButton(withTitle: "Merge Anyway (override)")
                    if alert.runModal() == .alertSecondButtonReturn {
                        performMerge(branch: branch)
                    }
                }
            }
        }
    }

    private func performMerge(branch: String) {
        let alert = NSAlert()
        alert.messageText = "Merge \(branch) into \(baseBranch)?"
        alert.informativeText = "Runs a --no-ff merge in the base checkout. Refuses if the base has uncommitted changes; aborts cleanly on conflicts. The worktree and branch are not deleted."
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let ws = app.activeWorkspace else { return }
        let repo = ws.baseRepo
        DispatchQueue.global(qos: .userInitiated).async {
            let result = GitDiff.mergeBranch(branch, intoBaseOf: repo)
            DispatchQueue.main.async {
                switch result {
                case .success(let message):
                    ShellExec.notify(title: "Merged", body: message)
                    refresh()
                case .failure(let why):
                    ShellExec.notify(title: "Merge not done", body: why)
                }
            }
        }
    }
}

private struct DiffLineView: View {
    let line: GitDiff.Line

    var body: some View {
        switch line.kind {
        case .file:
            Text(line.text)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.15))
                .padding(.top, 6)
        case .hunk:
            Text(line.text)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.cyan)
                .padding(.horizontal, 8).padding(.vertical, 1)
        case .addition:
            row(color: .green, background: Color.green.opacity(0.10))
        case .deletion:
            row(color: .red, background: Color.red.opacity(0.10))
        case .context:
            row(color: .primary, background: .clear)
        }
    }

    private func row(color: Color, background: Color) -> some View {
        Text(line.text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .textSelection(.enabled)
    }
}
