import Foundation

/// Read-only git queries for the diff review pane. All calls shell out to
/// git and are safe to run repeatedly; nothing here mutates a repo except
/// the explicit, guarded merge.
enum GitDiff {

    enum Mode: String, CaseIterable, Identifiable {
        case uncommitted = "Uncommitted"
        case branch = "Branch vs base"
        var id: String { rawValue }
    }

    struct Line: Identifiable {
        let id: Int
        let kind: Kind
        let text: String

        enum Kind {
            case file      // diff --git header (we show the path)
            case hunk      // @@ … @@
            case addition
            case deletion
            case context
        }
    }

    /// The branch this repo merges into: origin/HEAD if known, else
    /// main/master, else current.
    static func defaultBranch(repo: String) -> String {
        let head = ShellExec.run(["git", "-C", repo, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"])
        if head.ok {
            let name = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if let slash = name.firstIndex(of: "/") {
                return String(name[name.index(after: slash)...])
            }
        }
        for candidate in ["main", "master"] where
            ShellExec.run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", candidate]).ok {
            return candidate
        }
        return "HEAD"
    }

    static func currentBranch(dir: String) -> String? {
        let result = ShellExec.run(["git", "-C", dir, "branch", "--show-current"])
        let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.ok && !name.isEmpty ? name : nil
    }

    /// Success/failure with human-readable strings either way.
    enum Outcome {
        case success(String)
        case failure(String)
    }

    /// Unified diff text for a mode, or a human-readable error.
    static func diff(dir: String, mode: Mode, base: String) -> Outcome {
        let args: [String]
        switch mode {
        case .uncommitted:
            args = ["git", "-C", dir, "diff", "HEAD"]
        case .branch:
            // Three-dot: changes on this branch since it diverged from base.
            args = ["git", "-C", dir, "diff", "\(base)...HEAD"]
        }
        let result = ShellExec.run(args)
        guard result.ok else {
            return .failure(result.stderr.isEmpty ? "git diff failed (\(result.status))" : result.stderr)
        }
        return .success(result.stdout)
    }

    /// Untracked files aren't in `git diff HEAD`; list them so the review
    /// is honest about what it can't show.
    static func untrackedFiles(dir: String) -> [String] {
        let result = ShellExec.run(["git", "-C", dir, "ls-files", "--others", "--exclude-standard"])
        guard result.ok else { return [] }
        return result.stdout.split(separator: "\n").map(String.init)
    }

    static func isClean(dir: String) -> Bool {
        let result = ShellExec.run(["git", "-C", dir, "status", "--porcelain"])
        return result.ok && result.stdout.isEmpty
    }

    /// Merge `branch` into the base branch of `repo` — the close of the
    /// worktree review loop. Guarded: refuses unless the base checkout is
    /// clean (a failed merge must not land on top of uncommitted work).
    static func mergeBranch(_ branch: String, intoBaseOf repo: String) -> Outcome {
        guard isClean(dir: repo) else {
            return .failure("Base checkout has uncommitted changes — commit or stash them first.")
        }
        let base = defaultBranch(repo: repo)
        // The merge must not hijack the user's checkout: remember where the
        // base repo was and put it back afterwards, success or failure.
        let original = currentBranch(dir: repo)
        let checkout = ShellExec.run(["git", "-C", repo, "checkout", base])
        guard checkout.ok else { return .failure("Could not checkout \(base): \(checkout.stderr)") }
        defer {
            if let original, original != base {
                _ = ShellExec.run(["git", "-C", repo, "checkout", original])
            }
        }
        let merge = ShellExec.run(["git", "-C", repo, "merge", "--no-ff", branch,
                                   "-m", "Merge \(branch) (Buildwright review)"])
        guard merge.ok else {
            _ = ShellExec.run(["git", "-C", repo, "merge", "--abort"])
            return .failure("Merge conflicts — aborted cleanly. Resolve by hand: git merge \(branch)")
        }
        let restored = (original != nil && original != base) ? " (your checkout stays on \(original!))" : ""
        return .success("Merged \(branch) into \(base)\(restored)")
    }

    /// Parse unified diff text into renderable lines. Capped: gigantic diffs
    /// would otherwise stall SwiftUI list diffing.
    static func parse(_ unified: String, limit: Int = 20_000) -> (lines: [Line], truncated: Bool, added: Int, removed: Int) {
        var lines: [Line] = []
        var added = 0, removed = 0
        var truncated = false
        for (i, raw) in unified.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if lines.count >= limit { truncated = true; break }
            let text = String(raw)
            let kind: Line.Kind
            if text.hasPrefix("diff --git") {
                kind = .file
            } else if text.hasPrefix("@@") {
                kind = .hunk
            } else if text.hasPrefix("+++") || text.hasPrefix("---")
                        || text.hasPrefix("index ") || text.hasPrefix("new file")
                        || text.hasPrefix("deleted file") || text.hasPrefix("similarity")
                        || text.hasPrefix("rename ") || text.hasPrefix("Binary files")
                        || text.hasPrefix("old mode") || text.hasPrefix("new mode") {
                continue // metadata noise; the file header is enough
            } else if text.hasPrefix("+") {
                kind = .addition; added += 1
            } else if text.hasPrefix("-") {
                kind = .deletion; removed += 1
            } else {
                kind = .context
            }
            lines.append(Line(id: i, kind: kind, text: displayText(text, kind: kind)))
        }
        return (lines, truncated, added, removed)
    }

    private static func displayText(_ text: String, kind: Line.Kind) -> String {
        switch kind {
        case .file:
            // "diff --git a/path b/path" → "path"
            if let range = text.range(of: " b/") {
                return String(text[range.upperBound...])
            }
            return text
        default:
            return text
        }
    }
}
