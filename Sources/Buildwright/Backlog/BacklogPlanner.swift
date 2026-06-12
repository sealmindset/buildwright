import Foundation

/// AI build sequence over the backlog board: what to do first, second, third —
/// ordered by dependency feasibility and leverage with effort as tiebreaker,
/// NOT by the priority field. Every placement carries a one-line reason so
/// the human can veto it.
struct BacklogPlan: Codable, Equatable {
    var generatedAt: Date
    var epics: [PlannedEpic]

    struct PlannedEpic: Codable, Equatable, Identifiable {
        var id: String          // epic itemID, e.g. "EPIC-20"
        var title: String
        var effort: String      // S | M | L
        var reason: String
        var dependsOn: [String]?
        var unblocks: [String]?
        var nextStories: [PlannedStory]?
    }

    struct PlannedStory: Codable, Equatable, Identifiable {
        var id: String          // story itemID
        var title: String
        var effort: String
        var reason: String
    }
}

/// Runs headless Claude Code (`claude -p`) in the backlog directory to
/// produce a BacklogPlan. The agent reads the board itself (Read/Glob/Grep
/// only — it cannot write or run commands); the app parses the JSON, writes
/// the human-readable PLAN.md, and keeps .plan.json for reload.
@MainActor
final class BacklogPlanner: ObservableObject {

    enum State: Equatable {
        case idle
        case running(since: Date)
        case failed(String)
    }

    @Published var state: State = .idle
    @Published var plan: BacklogPlan?

    var planJSONFile: URL { Config.backlogDirectory.appendingPathComponent(".plan.json") }
    var planMarkdownFile: URL { Config.backlogDirectory.appendingPathComponent("PLAN.md") }

    func loadSavedPlan() {
        guard let data = try? Data(contentsOf: planJSONFile) else { return }
        plan = try? Self.decoder.decode(BacklogPlan.self, from: data)
    }

    /// Proactive planning: re-plan automatically when the board changed since
    /// the last plan, or the plan is older than a day. Called once at launch
    /// (after loadSavedPlan) so the sequence is simply THERE when you sit
    /// down — no wand-clicking required.
    func autoPlanIfStale() {
        if case .running = state { return }
        guard let plan else { runPlan(); return }
        let age = Date().timeIntervalSince(plan.generatedAt)
        if age > 24 * 3600 || boardChanged(since: plan.generatedAt) {
            runPlan()
        }
    }

    /// Newest mtime under BOARD.md and items/ — deliberately NOT the whole
    /// backlog dir, because PLAN.md/.plan.json are written right after
    /// planning and would make every plan look instantly stale.
    private func boardChanged(since: Date) -> Bool {
        let fm = FileManager.default
        var newest = Date.distantPast
        var paths = [Config.backlogDirectory.appendingPathComponent("BOARD.md")]
        let items = Config.backlogDirectory.appendingPathComponent("items")
        if let found = fm.enumerator(at: items, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let url as URL in found { paths.append(url) }
        }
        for url in paths {
            if let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                newest = max(newest, mtime)
            }
        }
        return newest > since
    }

    /// Kick off a planning run (30–90s, fully in the background).
    func runPlan() {
        if case .running = state { return } // one at a time
        state = .running(since: Date())
        let prompt = Self.planningPrompt
        let cwd = Config.backlogDirectory.path
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
        guard result.ok else {
            let why = result.stderr.isEmpty ? "claude exited \(result.status) — is Claude Code installed and logged in?" : result.stderr
            state = .failed(TranscriptReader.condense(why, limit: 200))
            ShellExec.notify(title: "Backlog plan failed", body: "Open the Plan panel for details")
            return
        }
        guard let epics = Self.parsePlanEpics(fromCLIOutput: result.stdout), !epics.isEmpty else {
            state = .failed("Could not parse a plan from Claude's reply — try re-planning")
            ShellExec.notify(title: "Backlog plan failed", body: "Reply was not valid plan JSON")
            return
        }
        let newPlan = BacklogPlan(generatedAt: Date(), epics: epics)
        plan = newPlan
        state = .idle
        save(newPlan)
        ShellExec.notify(title: "Backlog plan ready",
                         body: "First up: \(epics[0].id) — \(epics[0].title)")
    }

    // MARK: Parsing

    /// `claude -p --output-format json` wraps the reply in an envelope:
    /// {"type":"result","result":"<text>",...}. The text should be our plan
    /// JSON, possibly wrapped in markdown fences despite instructions.
    static func parsePlanEpics(fromCLIOutput stdout: String) -> [BacklogPlan.PlannedEpic]? {
        guard let envelope = try? JSONSerialization.jsonObject(
                with: Data(stdout.utf8)) as? [String: Any],
              let text = envelope["result"] as? String else { return nil }
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else { return nil }
        let json = String(text[start...end])
        struct Payload: Codable { var epics: [BacklogPlan.PlannedEpic] }
        return (try? decoder.decode(Payload.self, from: Data(json.utf8)))?.epics
    }

    // MARK: Persistence

    private func save(_ plan: BacklogPlan) {
        if let data = try? Self.encoder.encode(plan) {
            try? data.write(to: planJSONFile, options: .atomic)
        }
        try? Self.markdown(for: plan).write(to: planMarkdownFile, atomically: true, encoding: .utf8)
    }

    static func markdown(for plan: BacklogPlan) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        var out = "# Build Sequence (AI-generated)\n\nGenerated \(fmt.string(from: plan.generatedAt)) by Buildwright. "
        out += "Ordered by dependency feasibility → leverage → effort; not by priority field.\n"
        for (i, epic) in plan.epics.enumerated() {
            out += "\n\(i + 1). **\(epic.id) — \(epic.title)** (\(epic.effort)) — \(epic.reason)\n"
            if let deps = epic.dependsOn, !deps.isEmpty {
                out += "   - depends on: \(deps.joined(separator: ", "))\n"
            }
            if let unblocks = epic.unblocks, !unblocks.isEmpty {
                out += "   - unblocks: \(unblocks.joined(separator: ", "))\n"
            }
            for story in epic.nextStories ?? [] {
                out += "   - next: \(story.id) \(story.title) (\(story.effort)) — \(story.reason)\n"
            }
        }
        return out
    }

    // MARK: Prompt

    static let planningPrompt = """
    You are the strategic planner for this backlog board (the current directory). \
    Read BOARD.md and the items/ tree — including each epic's design.md where present — \
    then produce a build sequence: what to work on first, second, third.

    Ordering rules, in priority order:
    1. Foundations first: anything other items need must come before them (dependency feasibility).
    2. Leverage: among currently feasible items, prefer what unblocks the most downstream work.
    3. Effort tiebreaker: small independent quick wins may jump ahead between big rocks.
    Do NOT order by the priority field; treat it only as a weak hint of importance. \
    Exclude items whose status is done. Include at most 8 epics. For each epic list up to \
    2 concrete next stories (use EXISTING story ids only; omit nextStories if none exist).

    Effort scale: S = half a day or less, M = 1-3 days, L = a week or more.

    Reply with ONLY a JSON object — no markdown fences, no commentary before or after:
    {"epics":[{"id":"EPIC-XX","title":"...","effort":"S","reason":"one line: why this position", \
    "dependsOn":["EPIC-YY"],"unblocks":["EPIC-ZZ"], \
    "nextStories":[{"id":"EPIC-XX-S1","title":"...","effort":"S","reason":"one line"}]}]}
    """

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
