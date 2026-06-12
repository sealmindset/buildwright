import Foundation

/// One grooming finding with a concrete, accept-or-reject action.
/// Like drift, grooming only ever SUGGESTS — accepting applies the change,
/// rejecting hides it across runs (rejections persist in .groom.json).
struct GroomSuggestion: Codable, Equatable, Identifiable {
    var kind: String        // duplicate | stale | acceptance | oversize | assign
    var item: String        // the item the finding is about
    var note: String        // one-line why
    var of: String?         // duplicate: the item that survives
    var epic: String?       // assign: target epic for an inbox story
    var criteria: [String]? // acceptance: proposed acceptance criteria
    var split: [String]?    // oversize: proposed replacement story titles
    var id: String { "\(kind):\(item)" }

    var kindLabel: String {
        switch kind {
        case "duplicate": return "DUPE"
        case "stale": return "STALE"
        case "acceptance": return "CRITERIA"
        case "oversize": return "SPLIT"
        case "assign": return "ASSIGN"
        default: return kind.uppercased()
        }
    }

    /// What clicking Accept will do, spelled out before the click.
    var acceptDescription: String {
        switch kind {
        case "duplicate": return "Close \(item) as a duplicate of \(of ?? "?")"
        case "stale": return "Move \(item) back to backlog"
        case "acceptance": return "Append the proposed acceptance criteria to \(item)"
        case "oversize": return "Create \(split?.count ?? 0) replacement stories and close \(item)"
        case "assign": return "Move \(item) into \(epic ?? "?")"
        default: return "Apply"
        }
    }
}

struct GroomReport: Codable, Equatable {
    var generatedAt: Date
    var suggestions: [GroomSuggestion]
    var rejectedIDs: [String]?
}

/// Weekly + on-demand board hygiene: headless Claude Code reads the board
/// (read-only tools) and flags duplicates, stale items, stories without
/// acceptance criteria, oversized stories, and inbox thoughts that belong
/// under a real epic. Results land as an accept/reject triage list — the
/// app never applies a finding on its own.
@MainActor
final class BacklogGroomer: ObservableObject {

    enum State: Equatable {
        case idle
        case running(since: Date)
        case failed(String)
    }

    @Published var state: State = .idle
    @Published var report: GroomReport?
    var onCost: ((Double) -> Void)?

    var reportFile: URL { Config.backlogDirectory.appendingPathComponent(".groom.json") }

    /// Suggestions still on the table: not yet accepted, not rejected.
    var openSuggestions: [GroomSuggestion] {
        guard let report else { return [] }
        let rejected = Set(report.rejectedIDs ?? [])
        return report.suggestions.filter { !rejected.contains($0.id) }
    }

    func loadSavedReport() {
        guard let data = try? Data(contentsOf: reportFile) else { return }
        report = try? Self.decoder.decode(GroomReport.self, from: data)
    }

    /// Weekly cadence, checked at launch. A first-ever run counts as due.
    func autoGroomIfDue() {
        if case .running = state { return }
        if let report, Date().timeIntervalSince(report.generatedAt) < 7 * 86400 { return }
        runGroom(notifyFailure: false)
    }

    private var notifyFailure = true

    func runGroom(notifyFailure: Bool = true) {
        if case .running = state { return }
        self.notifyFailure = notifyFailure
        state = .running(since: Date())
        let cwd = Config.backlogDirectory.path
        let prompt = Self.groomingPrompt(today: Self.todayString)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ShellExec.run(
                ["claude", "-p", prompt,
                 "--output-format", "json",
                 "--allowedTools", "Read,Glob,Grep"],
                cwd: cwd)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finish(result) }
            }
        }
    }

    private func finish(_ result: ShellResult) {
        if let envelope = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
           let cost = envelope["total_cost_usd"] as? Double {
            onCost?(cost)
        }
        guard result.ok else {
            let why = result.stderr.isEmpty ? "claude exited \(result.status) — is Claude Code installed and logged in?" : result.stderr
            state = .failed(TranscriptReader.condense(why, limit: 200))
            if notifyFailure {
                ShellExec.notify(title: "Backlog grooming failed", body: "Open the groom panel for details")
            }
            return
        }
        guard let suggestions = Self.parseSuggestions(fromCLIOutput: result.stdout) else {
            state = .failed("Could not parse grooming suggestions — try again")
            if notifyFailure {
                ShellExec.notify(title: "Backlog grooming failed", body: "Reply was not valid JSON")
            }
            return
        }
        // Rejections survive re-runs: the same finding re-suggested stays hidden.
        let carriedRejections = report?.rejectedIDs ?? []
        let newReport = GroomReport(generatedAt: Date(), suggestions: suggestions,
                                    rejectedIDs: carriedRejections)
        report = newReport
        state = .idle
        save()
        let open = openSuggestions.count
        ShellExec.notify(title: "Board grooming done",
                         body: open == 0 ? "Board is clean — nothing to triage"
                                         : "\(open) suggestion\(open == 1 ? "" : "s") to triage (⇧⌘P → Groom)")
    }

    /// Triage actions: drop a suggestion after the app applied it, or mark
    /// it rejected so re-runs keep it hidden.
    func remove(_ s: GroomSuggestion) {
        report?.suggestions.removeAll { $0.id == s.id }
        save()
    }

    func reject(_ s: GroomSuggestion) {
        guard report != nil else { return }
        var rejected = report?.rejectedIDs ?? []
        if !rejected.contains(s.id) { rejected.append(s.id) }
        report?.rejectedIDs = rejected
        save()
    }

    private func save() {
        guard let report else { return }
        if let data = try? Self.encoder.encode(report) {
            try? data.write(to: reportFile, options: .atomic)
        }
    }

    // MARK: Parsing

    static func parseSuggestions(fromCLIOutput stdout: String) -> [GroomSuggestion]? {
        guard let envelope = try? JSONSerialization.jsonObject(
                with: Data(stdout.utf8)) as? [String: Any],
              let text = envelope["result"] as? String else { return nil }
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else { return nil }
        struct Payload: Codable { var suggestions: [GroomSuggestion] }
        let json = String(text[start...end])
        return (try? decoder.decode(Payload.self, from: Data(json.utf8)))?.suggestions
    }

    // MARK: Prompt

    static var todayString: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    static func groomingPrompt(today: String) -> String {
        """
        You are the board groomer for this backlog (the current directory). Today is \(today). \
        Read BOARD.md and every item under items/ (epic.md and stories/*.md — frontmatter \
        has id/title/type/status/parent/updated). Find ONLY clear cases of:

        1. "duplicate" — two open items covering the same work. Flag the weaker one as \
        "item", the one that survives as "of".
        2. "stale" — items in ready/in-progress/blocked/designing whose updated date is \
        more than 30 days before today. (Ignore backlog and done items.)
        3. "acceptance" — stories in ready or in-progress whose body has no testable \
        acceptance criteria. Propose 2-4 concrete, checkable criteria in "criteria".
        4. "oversize" — stories bundling multiple unrelated concerns or clearly a week+ \
        of work. Propose 2-3 replacement story titles in "split".
        5. "assign" — stories under an epic titled "Inbox": pick the EXISTING epic each \
        belongs in ("epic" = its id, e.g. "E36"). Skip a story if no existing epic fits.

        Be conservative — when unsure, do not flag. At most 12 suggestions total. \
        Every "item"/"of"/"epic" value must be an EXISTING item id from the board.

        Reply with ONLY a JSON object — no markdown fences, no commentary:
        {"suggestions":[
        {"kind":"duplicate","item":"E12-S3","of":"E10-S1","note":"one line"},
        {"kind":"stale","item":"E08","note":"one line"},
        {"kind":"acceptance","item":"E14-S2","note":"one line","criteria":["...","..."]},
        {"kind":"oversize","item":"E15-S1","note":"one line","split":["title a","title b"]},
        {"kind":"assign","item":"E40-S2","epic":"E36","note":"one line"}]}
        """
    }

    // MARK: Coding

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
