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
            setup()
            refresh()
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
        baseBranch = GitDiff.defaultBranch(repo: repoForBase)
        currentBranch = GitDiff.currentBranch(dir: pane.directory)
        // Worktree panes exist to be reviewed against base; default there.
        if pane.worktreeBranch != nil || isReviewingWorktreeDir { mode = .branch }
    }

    /// The base repo whose default branch we compare against: for a worktree
    /// directory that's still the main checkout's branches (shared .git).
    private var repoForBase: String { pane.directory }

    private var isReviewingWorktreeDir: Bool {
        currentBranch?.hasPrefix("bw/") == true
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

    private func confirmMerge(branch: String) {
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
