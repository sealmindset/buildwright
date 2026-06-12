import Foundation

/// Git worktree lifecycle for isolated Claude panes: each agent gets its own
/// checkout + branch (`bw/<slug>`) so parallel sessions never trample each
/// other's files, index, or build artifacts.
enum GitWorktree {

    /// Worktrees live beside the repo: `<parent>/<repo>-worktrees/<name>` —
    /// visible, conventional, and outside the main checkout.
    static func containerDir(repo: String) -> String {
        let repoURL = URL(fileURLWithPath: repo)
        return repoURL.deletingLastPathComponent()
            .appendingPathComponent(repoURL.lastPathComponent + "-worktrees").path
    }

    static func isGitRepo(_ path: String) -> Bool {
        ShellExec.run(["git", "-C", path, "rev-parse", "--is-inside-work-tree"]).ok
    }

    /// Create a worktree on a fresh branch from the repo's current HEAD.
    /// Returns nil when the repo isn't git or git refuses.
    static func create(repo: String, slug: String) -> (path: String, branch: String)? {
        guard isGitRepo(repo) else { return nil }
        let stamp = String(UUID().uuidString.prefix(4)).lowercased()
        let name = "\(slug)-\(stamp)"
        let branch = "bw/\(name)"
        let container = containerDir(repo: repo)
        let path = container + "/" + name
        try? FileManager.default.createDirectory(atPath: container, withIntermediateDirectories: true)
        let result = ShellExec.run(["git", "-C", repo, "worktree", "add", "-b", branch, path])
        return result.ok ? (path, branch) : nil
    }

    /// Remove a worktree only when it has no uncommitted changes; the branch
    /// is always kept (committed agent work stays mergeable). Returns true
    /// when the directory is gone afterwards.
    static func removeIfClean(repo: String, path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else {
            _ = ShellExec.run(["git", "-C", repo, "worktree", "prune"])
            return true
        }
        let dirty = ShellExec.run(["git", "-C", path, "status", "--porcelain"])
        guard dirty.ok, dirty.stdout.isEmpty else { return false }
        return ShellExec.run(["git", "-C", repo, "worktree", "remove", path]).ok
    }

    /// Checkpoint in-flight agent work off this machine: commit WIP if dirty,
    /// push the branch. Returns a description of what happened, nil if no-op.
    static func checkpoint(dir: String) -> String? {
        let dirty = ShellExec.run(["git", "-C", dir, "status", "--porcelain"])
        guard dirty.ok else { return nil }
        var actions: [String] = []
        if !dirty.stdout.isEmpty {
            _ = ShellExec.run(["git", "-C", dir, "add", "-A"])
            let commit = ShellExec.run(["git", "-C", dir, "commit", "--no-verify",
                                        "-m", "WIP checkpoint (Buildwright auto)"])
            if commit.ok { actions.append("committed WIP") }
        }
        let push = ShellExec.run(["git", "-C", dir, "push", "-u", "origin", "HEAD"])
        if push.ok { actions.append("pushed") }
        else if !actions.isEmpty { actions.append("push failed: \(TranscriptReader.condense(push.stderr, limit: 80))") }
        return actions.isEmpty ? nil : actions.joined(separator: ", ")
    }

    /// "Fix the login crash!" → "fix-the-login-crash" (branch/dir safe).
    static func slug(from text: String) -> String {
        var out = ""
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber { out.append(ch) }
            else if !out.hasSuffix("-") && !out.isEmpty { out.append("-") }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "agent" : String(trimmed.prefix(24))
    }
}
