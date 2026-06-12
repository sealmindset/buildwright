import Foundation

/// AI build sequence over the backlog board: what to do first, second, third —
/// ordered by dependency feasibility and leverage with effort as tiebreaker,
/// NOT by the priority field. Every placement carries a one-line reason so
/// the human can veto it.
struct BacklogPlan: Codable, Equatable {
    var generatedAt: Date
    var epics: [PlannedEpic]
    /// The whitelist: the ONLY items allowed to run alongside the active
    /// epic. Parallel must be absolutely safe AND save real time toward
    /// finishing the current epic — the burden of proof is on parallelism.
    /// Empty means "linear is the play right now".
    var parallelSafe: [ParallelItem]?

    struct ParallelItem: Codable, Equatable, Identifiable {
        var id: String          // story or small-epic itemID
        var title: String
        var effort: String      // S | M (never L)
        var safeBecause: String // why it cannot collide with the active epic
        var saves: String       // the time it buys toward epic completion
    }

    struct PlannedEpic: Codable, Equatable, Identifiable {
        var id: String          // epic itemID, e.g. "EPIC-20"
        var title: String
        var effort: String      // S | M | L
        var reason: String
        var dependsOn: [String]?
        var unblocks: [String]?
        /// Epics that must NOT run concurrently with this one — they touch
        /// the same functionality and would oppose or collide. (Mere overlap
        /// is fine: that's cross-checking.) Drives the epic collision gate.
        var conflictsWith: [String]?
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
    /// Reports the dollar cost of each headless run (AI-spend tracking).
    var onCost: ((Double) -> Void)?

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
        guard let plan else { runPlan(notifyFailure: false); return }
        let age = Date().timeIntervalSince(plan.generatedAt)
        if age > 24 * 3600 || boardChanged(since: plan.generatedAt) {
            runPlan(notifyFailure: false)
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

    /// Failure toasts only for runs the user asked for — an auto-plan that
    /// can't run (claude missing, logged out) shouldn't nag at every launch.
    private var notifyFailure = true

    /// Kick off a planning run (30–90s, fully in the background).
    /// `looseEndsFor`: an epic that just completed — the planner explicitly
    /// hunts for unfinished stories/TODOs it left behind before sequencing.
    func runPlan(notifyFailure: Bool = true, looseEndsFor completedEpic: String? = nil) {
        if case .running = state { return } // one at a time
        self.notifyFailure = notifyFailure
        state = .running(since: Date())
        var prompt = Self.planningPrompt
        if let completedEpic {
            prompt += """
            \n\nIMPORTANT: epic \(completedEpic) was JUST completed. Before sequencing, \
            examine it for loose ends — stories still open under it, follow-up work named \
            in its design doc or story notes, anything it promised but deferred. Check this \
            DEFINITION OF DONE explicitly: tests green in CI; security review done; docs \
            updated; deployed/promoted through the release lane. Anything unmet is a loose \
            end. Surface loose ends first (as nextStories of the epic that owns them, or as \
            the top item) with reason "loose end from \(completedEpic)".
            """
        }
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
        if let envelope = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
           let cost = envelope["total_cost_usd"] as? Double {
            onCost?(cost)
        }
        guard result.ok else {
            let why = result.stderr.isEmpty ? "claude exited \(result.status) — is Claude Code installed and logged in?" : result.stderr
            state = .failed(TranscriptReader.condense(why, limit: 200))
            if notifyFailure {
                ShellExec.notify(title: "Backlog plan failed", body: "Open the Plan panel for details")
            }
            return
        }
        guard let parsed = Self.parsePlanPayload(fromCLIOutput: result.stdout), !parsed.epics.isEmpty else {
            state = .failed("Could not parse a plan from Claude's reply — try re-planning")
            if notifyFailure {
                ShellExec.notify(title: "Backlog plan failed", body: "Reply was not valid plan JSON")
            }
            return
        }
        let newPlan = BacklogPlan(generatedAt: Date(), epics: parsed.epics, parallelSafe: parsed.parallelSafe)
        plan = newPlan
        state = .idle
        save(newPlan)
        let parallelNote = (parsed.parallelSafe?.isEmpty ?? true)
            ? "linear is the play"
            : "parallel-safe: \(parsed.parallelSafe!.map(\.id).joined(separator: ", "))"
        ShellExec.notify(title: "Backlog plan ready",
                         body: "First up: \(parsed.epics[0].id) — \(parsed.epics[0].title) · \(parallelNote)")
    }

    // MARK: Parsing

    struct PlanPayload: Codable {
        var epics: [BacklogPlan.PlannedEpic]
        var parallelSafe: [BacklogPlan.ParallelItem]?
    }

    /// `claude -p --output-format json` wraps the reply in an envelope:
    /// {"type":"result","result":"<text>",...}. The text should be our plan
    /// JSON, possibly wrapped in markdown fences despite instructions.
    static func parsePlanPayload(fromCLIOutput stdout: String) -> PlanPayload? {
        guard let envelope = try? JSONSerialization.jsonObject(
                with: Data(stdout.utf8)) as? [String: Any],
              let text = envelope["result"] as? String else { return nil }
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else { return nil }
        let json = String(text[start...end])
        return try? decoder.decode(PlanPayload.self, from: Data(json.utf8))
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
            if let conflicts = epic.conflictsWith, !conflicts.isEmpty {
                out += "   - must not run concurrently with: \(conflicts.joined(separator: ", "))\n"
            }
            for story in epic.nextStories ?? [] {
                out += "   - next: \(story.id) \(story.title) (\(story.effort)) — \(story.reason)\n"
            }
        }
        out += "\n## Safe to run in parallel with #1\n\n"
        if let parallel = plan.parallelSafe, !parallel.isEmpty {
            for item in parallel {
                out += "- **\(item.id) \(item.title)** (\(item.effort)) — safe: \(item.safeBecause) · saves: \(item.saves)\n"
            }
        } else {
            out += "Nothing — linear is the play right now.\n"
        }
        return out
    }

    // MARK: Prompt

    static let planningPrompt = """
    You are the strategic planner for this backlog board (the current directory). \
    Read BOARD.md and the items/ tree — including each epic's design.md where present — \
    and DECISIONS.md if it exists (recorded decisions constrain the plan). \
    Then produce a build sequence: what to work on first, second, third.

    Ordering rules, in priority order:
    1. Foundations first: anything other items need must come before them (dependency feasibility).
    2. Leverage: among currently feasible items, prefer what unblocks the most downstream work.
    3. Effort tiebreaker: small independent quick wins may jump ahead between big rocks.
    Do NOT order by the priority field; treat it only as a weak hint of importance. \
    Exclude items whose status is done. Include at most 8 epics. For each epic list up to \
    2 concrete next stories (use EXISTING story ids only; omit nextStories if none exist).

    Effort scale: S = half a day or less, M = 1-3 days, L = a week or more.

    Also identify CONFLICTS: for each epic, list epics that must not run \
    CONCURRENTLY with it because they change the same functionality and would \
    oppose or collide (same subsystem, same schema, same config surface). \
    Mere topical overlap is NOT a conflict — overlapping work that cross-checks \
    itself is healthy. Be conservative: only flag real collisions.

    Finally, the PARALLEL-SAFE WHITELIST. The working rule is LINEAR FIRST: \
    parallel work is allowed only when it is absolutely safe AND saves real time \
    toward completing the #1 epic before the next one starts. List at most 3 items \
    (existing ids only) that may run alongside the #1 epic: independent stories \
    within that epic touching disjoint files/subsystems, or standalone S/M quick \
    wins with zero functional contact with it. S or M effort only — never L. For \
    each: safeBecause (why it cannot collide) and saves (the time it buys). When \
    in doubt, leave it OUT — an empty list ("linear is the play") is a good answer.

    Reply with ONLY a JSON object — no markdown fences, no commentary before or after:
    {"epics":[{"id":"EPIC-XX","title":"...","effort":"S","reason":"one line: why this position", \
    "dependsOn":["EPIC-YY"],"unblocks":["EPIC-ZZ"],"conflictsWith":["EPIC-WW"], \
    "nextStories":[{"id":"EPIC-XX-S1","title":"...","effort":"S","reason":"one line"}]}], \
    "parallelSafe":[{"id":"EPIC-QQ","title":"...","effort":"S", \
    "safeBecause":"one line","saves":"one line"}]}
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
