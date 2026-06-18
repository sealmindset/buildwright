import Foundation

/// One per-item verdict from a grounded reconciliation audit — the engine's
/// view of "is this board item actually built in the code?" Mirrors the
/// shared contract with the /backlog skill EXACTLY (strict JSON in, this out).
struct ReconcileVerdict: Codable, Equatable, Identifiable {
    var item: String            // board item id (E20, E20-S3)
    var verdict: String         // built | partial | not-built | unknown
    var confidence: Double       // 0.0…1.0
    var evidence: Evidence
    var gaps: [String]?
    var proposed_action: ProposedAction

    var id: String { item }

    struct Evidence: Codable, Equatable {
        var code: [String]?     // file:line refs in the target repo
        var tests: [String]?
        var live: [String]?
    }

    /// What the audit proposes doing to the board for this item.
    struct ProposedAction: Codable, Equatable {
        var kind: String        // mark_done | close_dup | restatus | split | none
        var to_status: String?  // restatus: target status
        var dup_of: String?     // close_dup: the surviving item
        var why: String         // one line
    }

    // MARK: Classification (the auto-apply contract)

    /// BUILT requires the FULL ladder: code ✓ AND tests ✓ AND live ✓.
    var hasFullLadder: Bool {
        !(evidence.code ?? []).isEmpty
            && !(evidence.tests ?? []).isEmpty
            && !(evidence.live ?? []).isEmpty
    }

    /// Reversible + non-harmful board mutations. A `split` mints new stories
    /// and a mark_done with an incomplete ladder is never auto-applied — those
    /// stay flagged for a human. `none` is nothing to do.
    var isReversibleAction: Bool {
        switch proposed_action.kind {
        case "restatus", "close_dup": return true
        case "mark_done": return verdict == "built" && hasFullLadder
        default: return false   // split, none, unknown kinds → flag
        }
    }

    /// Auto-apply only when the model is confident AND the action is safe to
    /// reverse AND (for done) the full verification ladder is satisfied.
    /// Everything else is flagged for accept/reject — never silently applied.
    var isAutoApplicable: Bool {
        guard confidence >= 0.8 else { return false }
        guard proposed_action.kind != "none" else { return false }
        return isReversibleAction
    }

    var verdictLabel: String {
        switch verdict {
        case "built": return "BUILT"
        case "partial": return "PARTIAL"
        case "not-built": return "NOT BUILT"
        default: return "UNKNOWN"
        }
    }
}

/// The outcome of one applied reconciliation — enough to render it and to UNDO
/// it (restore the prior status, re-open a closed dup). Statuses are captured
/// before the mutation so undo is exact.
struct ReconcileApplication: Codable, Equatable, Identifiable {
    var item: String
    var kind: String            // mark_done | close_dup | restatus
    var priorStatus: String     // what to restore on undo
    var newStatus: String       // what we set
    var why: String
    var appliedAt: Date
    var id: String { item }
}

/// The persisted report: every verdict from the last audit, the ids the user
/// rejected (kept hidden across re-runs, like the groomer), and the
/// applications still undo-able.
struct ReconcileReport: Codable, Equatable {
    var generatedAt: Date
    var verdicts: [ReconcileVerdict]
    var rejectedIDs: [String]?
    var applied: [ReconcileApplication]?
}

/// The code-grounded reconciliation + dispatch engine — the "AI Scrum Master"
/// that audits the backlog board against the REAL target codebase (default
/// ~/Documents/GitHub/docai) to find what's already built, auto-reconciles the
/// board for high-confidence reversible findings, flags the rest for a human,
/// and can dispatch the next parallel-safe build.
///
/// Headless plumbing mirrors BacklogGroomer/ScrumMaster: `claude -p` with
/// Read,Glob,Grep,Bash and cwd = the TARGET repo (not the board), a JSON
/// envelope parsed for `result` / `total_cost_usd` / `is_error`, off-main then
/// hop back. Every board write + git sync is gated behind `syncEnabled` so the
/// unit tests stay hermetic (no git, no network, no live `claude -p`, no docai/
/// prod access).
@MainActor
final class Reconciler: ObservableObject {

    enum State: Equatable {
        case idle
        case running(since: Date)
        case failed(String)
    }

    @Published var state: State = .idle
    @Published var report: ReconcileReport?
    /// The item dispatch picked on the last run (if any) — surfaced in the UI.
    @Published var dispatched: String?

    var onCost: ((Double) -> Void)?
    /// Model id for `claude --model` (empty = Claude Code default).
    var model = ""
    /// Builds the CURRENT BOARD snapshot — injected by AppState.
    var boardSnapshot: () -> String = { "" }
    /// The configurable target-repo path the audit runs against (cwd).
    var targetRepoPath: () -> String = { Config.defaultDocaiPath }
    /// Hands the chosen gap to the existing start path (`/backlog start <id>`).
    var onDispatch: ((BacklogItem) -> Void)?
    /// Resolves an item id to the live board item (for dispatch + undo).
    var itemLookup: (String) -> BacklogItem? = { _ in nil }
    /// The live board, for nextSafeGap sequencing. Injected by AppState.
    var epicsSnapshot: () -> [BacklogEpic] = { [] }
    /// The build plan's deps/conflicts/parallel-safe whitelist, when present.
    var planSnapshot: () -> BacklogPlan? = { nil }

    /// Dispatch is OFF until armed. Persisted by AppState. When armed, a
    /// reconcile run will offer (and the user can fire) the next safe gap.
    @Published var armed = true

    private let store: BacklogStore
    /// Production paths run board writes + git sync; tests flip this off.
    private let syncEnabled: Bool

    init(store: BacklogStore, syncEnabled: Bool = true) {
        self.store = store
        self.syncEnabled = syncEnabled
    }

    var reportFile: URL { Config.backlogDirectory.appendingPathComponent(".reconcile.json") }

    /// Verdicts still on the table for the user: flagged (not auto-applied),
    /// not rejected, not already applied.
    var flaggedVerdicts: [ReconcileVerdict] {
        guard let report else { return [] }
        let rejected = Set(report.rejectedIDs ?? [])
        let appliedIDs = Set((report.applied ?? []).map(\.item))
        return report.verdicts.filter {
            !$0.isAutoApplicable && !rejected.contains($0.id) && !appliedIDs.contains($0.id)
                && $0.proposed_action.kind != "none"
        }
    }

    /// Verdicts the engine auto-applied this run (shown read-only, with undo).
    var autoAppliedVerdicts: [ReconcileVerdict] {
        guard let report else { return [] }
        let appliedIDs = Set((report.applied ?? []).map(\.item))
        return report.verdicts.filter { appliedIDs.contains($0.id) }
    }

    func loadSavedReport() {
        guard let data = try? Data(contentsOf: reportFile) else { return }
        report = try? Self.decoder.decode(ReconcileReport.self, from: data)
    }

    // MARK: Run

    func runReconcile(notifyFailure: Bool = true) {
        if case .running = state { return }
        self.notifyFailure = notifyFailure
        state = .running(since: Date())
        dispatched = nil
        let cwd = targetRepoPath()
        let prompt = Self.reconcilePrompt(board: boardSnapshot(), today: Self.todayString)
        let model = self.model
        DispatchQueue.global(qos: .userInitiated).async {
            var args = ["claude", "-p", prompt, "--output-format", "json",
                        "--allowedTools", "Read,Glob,Grep,Bash"]
            if !model.isEmpty { args += ["--model", model] }
            let result = ShellExec.run(args, cwd: cwd)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finish(result) }
            }
        }
    }

    private var notifyFailure = true

    private func finish(_ result: ShellResult) {
        let envelope = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        if let cost = envelope?["total_cost_usd"] as? Double { onCost?(cost) }
        if envelope?["is_error"] as? Bool == true,
           let msg = envelope?["result"] as? String, !msg.isEmpty {
            fail(TranscriptReader.condense(msg, limit: 240))
            return
        }
        guard result.ok else {
            let why = result.stderr.isEmpty
                ? "claude exited \(result.status) — is Claude Code installed and logged in?"
                : result.stderr
            fail(TranscriptReader.condense(why, limit: 200))
            return
        }
        guard let verdicts = Self.parseVerdicts(fromCLIOutput: result.stdout) else {
            fail("Could not parse the reconciliation reply — try again")
            return
        }
        // Carry rejections so a re-suggested finding stays hidden.
        let carriedRejections = report?.rejectedIDs ?? []
        var newReport = ReconcileReport(generatedAt: Date(), verdicts: verdicts,
                                        rejectedIDs: carriedRejections, applied: [])
        // Auto-apply the high-confidence reversible findings; the rest get flagged.
        var applied: [ReconcileApplication] = []
        for v in verdicts where v.isAutoApplicable {
            if let app = apply(v, auto: true) { applied.append(app) }
        }
        newReport.applied = applied
        report = newReport
        state = .idle
        save()

        let flagged = flaggedVerdicts.count
        var body = applied.isEmpty
            ? "\(flagged) finding\(flagged == 1 ? "" : "s") to triage"
            : "\(applied.count) auto-applied · \(flagged) to triage"
        // Offer/fire dispatch for the next safe gap.
        if let gap = nextSafeGap() {
            dispatched = gap.itemID
            body += " · next gap: \(gap.itemID)"
            if armed { dispatch() }
        }
        ShellExec.notify(title: "Board reconciled", body: body)
    }

    private func fail(_ message: String) {
        state = .failed(message)
        if notifyFailure {
            ShellExec.notify(title: "Reconcile failed", body: TranscriptReader.condense(message, limit: 120))
        }
    }

    // MARK: Apply / accept / reject / undo

    /// Accept a flagged verdict: apply its proposed action and record the
    /// application so it can be undone.
    func accept(_ v: ReconcileVerdict) {
        guard report != nil else { return }
        if let app = apply(v, auto: false) {
            report?.applied = (report?.applied ?? []) + [app]
            save()
        }
    }

    /// Reject a flagged verdict: hide it now and across future runs.
    func reject(_ v: ReconcileVerdict) {
        guard report != nil else { return }
        var rejected = report?.rejectedIDs ?? []
        if !rejected.contains(v.id) { rejected.append(v.id) }
        report?.rejectedIDs = rejected
        save()
    }

    /// Mutate the board for one verdict and write the Reconciliation provenance
    /// block. Returns the ReconcileApplication (with the prior status) for undo,
    /// or nil if the item is gone or the action isn't a board mutation.
    @discardableResult
    func apply(_ v: ReconcileVerdict, auto: Bool) -> ReconcileApplication? {
        guard syncEnabled || itemLookup(v.item) != nil else {
            // In hermetic tests, callers use the static board mutator directly.
            return nil
        }
        guard let item = itemLookup(v.item) else { return nil }
        let prior = item.status
        let newStatus: String
        switch v.proposed_action.kind {
        case "mark_done": newStatus = "done"
        case "close_dup": newStatus = "done"
        case "restatus": newStatus = v.proposed_action.to_status ?? prior
        default: return nil
        }
        guard newStatus != prior || v.proposed_action.kind == "close_dup" else { return nil }
        Self.mutateBoard(item: item, verdict: v, newStatus: newStatus, store: store)
        if syncEnabled { Self.runSync() }
        return ReconcileApplication(item: v.item, kind: v.proposed_action.kind,
                                    priorStatus: prior, newStatus: newStatus,
                                    why: v.proposed_action.why, appliedAt: Date())
    }

    /// Reverse an applied reconciliation: restore the prior status. The
    /// provenance block stays (it records that an undo happened).
    func undo(_ app: ReconcileApplication) {
        guard let item = itemLookup(app.item) else { return }
        store.setStatus(item, to: app.priorStatus)
        store.appendHistory(item, "reconciliation undone — restored to \(app.priorStatus)")
        if syncEnabled { Self.runSync() }
        report?.applied?.removeAll { $0.id == app.id }
        save()
    }

    private func save() {
        guard let report else { return }
        if let data = try? Self.encoder.encode(report) {
            try? data.write(to: reportFile, options: .atomic)
        }
    }

    // MARK: Board mutation (pure — no git/network; the unit-tested path)

    /// Set the new status and append the Reconciliation provenance block per
    /// the shared contract. Does NOT sync — callers own that so tests stay
    /// hermetic.
    static func mutateBoard(item: BacklogItem, verdict: ReconcileVerdict,
                            newStatus: String, store: BacklogStore) {
        store.setStatus(item, to: newStatus)
        store.appendSectionRaw(item, provenanceBlock(verdict: verdict, newStatus: newStatus,
                                                      today: todayString))
    }

    /// The provenance markdown appended to a reconciled card.
    static func provenanceBlock(verdict v: ReconcileVerdict, newStatus: String, today: String) -> String {
        let conf = String(format: "%.2f", v.confidence)
        let refs = ((v.evidence.code ?? []) + (v.evidence.tests ?? []) + (v.evidence.live ?? []))
            .prefix(4).joined(separator: ", ")
        let action: String
        switch v.proposed_action.kind {
        case "mark_done": action = "marked done"
        case "close_dup": action = "closed as duplicate of \(v.proposed_action.dup_of ?? "?")"
        case "restatus": action = "re-statused to \(newStatus)"
        default: action = v.proposed_action.kind
        }
        return """
        ## Reconciliation (\(today))
        - verdict: \(v.verdict) · confidence: \(conf) · via: code+tests+live
        - evidence: \(refs.isEmpty ? "—" : refs)
        - action: \(action) — undo available
        """
    }

    // MARK: Dispatch (next parallel-safe gap → existing start path)

    /// The next item to BUILD: a not-built/partial item that is parallel-safe
    /// (no unfinished dependsOn, no conflictsWith with in-progress work),
    /// highest priority first. Pure function of the report + board + plan so it
    /// is unit-testable. Returns nil when nothing is safe to start.
    func nextSafeGap() -> BacklogItem? {
        guard let report else { return nil }
        let epics = epicsSnapshot()
        return Self.computeNextSafeGap(verdicts: report.verdicts, epics: epics, plan: planSnapshot())
    }

    /// Pure gap selection: of the report's not-built/partial items that exist
    /// on the board and aren't done/in-progress, pick the highest-priority one
    /// whose epic has no unfinished hard dependency and does not conflict with
    /// any in-progress epic.
    static func computeNextSafeGap(verdicts: [ReconcileVerdict], epics: [BacklogEpic],
                                   plan: BacklogPlan?) -> BacklogItem? {
        // Index the board.
        var items: [String: BacklogItem] = [:]
        var epicOf: [String: String] = [:]   // any id → its epic id
        var epicStatus: [String: String] = [:]
        for g in epics {
            items[g.epic.itemID] = g.epic
            epicOf[g.epic.itemID] = g.epic.itemID
            epicStatus[g.epic.itemID] = g.epic.status
            for s in g.stories {
                items[s.itemID] = s
                epicOf[s.itemID] = g.epic.itemID
            }
        }
        // Epics in progress now (directly or via a story) — the conflict set.
        var inProgressEpics = Set<String>()
        for g in epics {
            if g.epic.status == "in-progress" { inProgressEpics.insert(g.epic.itemID) }
            if g.stories.contains(where: { $0.status == "in-progress" }) {
                inProgressEpics.insert(g.epic.itemID)
            }
        }
        // Plan lookups (deps/conflicts keyed by epic id).
        var deps: [String: [String]] = [:]
        var conflicts: [String: [String]] = [:]
        if let plan {
            for e in plan.epics {
                deps[e.id] = e.dependsOn ?? []
                conflicts[e.id] = e.conflictsWith ?? []
            }
        }
        func epicDone(_ id: String) -> Bool {
            (epicStatus[id] ?? "") == "done" || (epicStatus[id] ?? "") == "closed"
        }

        // Candidates: gaps that exist on the board and aren't already done/active.
        let candidates = verdicts.filter { v in
            (v.verdict == "not-built" || v.verdict == "partial")
        }.compactMap { v -> BacklogItem? in
            guard let item = items[v.item], !item.isDone, item.status != "in-progress" else { return nil }
            return item
        }

        // Keep only parallel-safe ones.
        let safe = candidates.filter { item in
            guard let eid = epicOf[item.itemID] else { return false }
            // No unfinished hard dependency.
            for dep in deps[eid] ?? [] where !epicDone(dep) { return false }
            // No conflict with anything in progress (either direction).
            for c in conflicts[eid] ?? [] where inProgressEpics.contains(c) { return false }
            for active in inProgressEpics where (conflicts[active] ?? []).contains(eid) { return false }
            // Don't dispatch into its own in-progress epic's conflict (already excluded by status).
            return true
        }

        // Highest priority first (P1 < P2 < P3 < none), then board order.
        return safe.sorted { a, b in
            let pa = priorityRank(a.priority), pb = priorityRank(b.priority)
            if pa != pb { return pa < pb }
            return a.itemID.localizedStandardCompare(b.itemID) == .orderedAscending
        }.first
    }

    private static func priorityRank(_ p: String) -> Int {
        switch p.uppercased() {
        case "P1": return 0
        case "P2": return 1
        case "P3": return 2
        default: return 3
        }
    }

    /// Fire dispatch for the current gap: hand it to the existing start path
    /// (`/backlog start <id>`, which carries the ship preamble → build →
    /// 100%-green gate → harm-gate). One at a time; reversible (it just opens a
    /// session). Announces what it started.
    func dispatch() {
        guard let id = dispatched, let item = itemLookup(id) else { return }
        onDispatch?(item)
        ShellExec.notify(title: "Dispatched \(item.itemID)",
                         body: "Started the next safe gap: \(TranscriptReader.condense(item.title, limit: 90))")
        dispatched = nil
    }

    // MARK: Parsing

    static func parseVerdicts(fromCLIOutput stdout: String) -> [ReconcileVerdict]? {
        guard let envelope = try? JSONSerialization.jsonObject(
                with: Data(stdout.utf8)) as? [String: Any],
              let text = envelope["result"] as? String else { return nil }
        return parseVerdicts(fromResultText: text)
    }

    /// Tolerant of an accidental ```json fence or surrounding prose: takes the
    /// outermost { … } and decodes the {"items":[…]} envelope.
    static func parseVerdicts(fromResultText text: String) -> [ReconcileVerdict]? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"), start < end else { return nil }
        struct Payload: Codable { var items: [ReconcileVerdict] }
        let json = String(text[start...end])
        return (try? decoder.decode(Payload.self, from: Data(json.utf8)))?.items
    }

    // MARK: Prompt

    static var todayString: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    static func reconcilePrompt(board: String, today: String) -> String {
        """
        You are the AI Scrum Master reconciling a software BACKLOG BOARD against the REAL \
        codebase in the CURRENT DIRECTORY (a Next.js + Prisma + TypeScript repo). Today is \
        \(today). For each OPEN board item below, determine whether it is actually built in \
        this code, and propose the board change that would make the board tell the truth.

        OPEN BOARD ITEMS (id · title · [category] · status):
        \(board.isEmpty ? "(snapshot unavailable)" : board)

        For EACH item run the VERIFICATION LADDER, gathering file:line evidence with your \
        Read/Glob/Grep/Bash tools:
        1. CODE — agents in src/lib/agents, API routes in src/app/api and \
        src/app/(authenticated), data models in prisma/migrations, components in \
        src/components. Collect concrete file:line refs.
        2. TESTS — are the relevant vitest/playwright/test-smoke.mjs tests present and green?
        3. LIVE — does the feature actually work end-to-end (HTTP/UI/data)?

        Verdict rules — be conservative, never over-claim:
        - "built" REQUIRES code ✓ AND tests ✓ AND live ✓. If any rung is missing, it is \
        "partial" (some code) or "not-built" (no real code) — NOT built.
        - "unknown" when you genuinely cannot tell. Confidence reflects how sure you are.
        - proposed_action: "mark_done" only for a full-ladder built item; "close_dup" when \
        the work is the same as another item (set dup_of); "restatus" to move it to the \
        status the evidence supports (set to_status); "split" when one item is really \
        several; "none" when the board is already right.

        Reply with ONLY this JSON object — no markdown fences, no commentary:
        {"items":[
          {"item":"E20","verdict":"built|partial|not-built|unknown","confidence":0.0,
           "evidence":{"code":["src/lib/agents/mercury.ts:1"],"tests":["..."],"live":["..."]},
           "gaps":["what's missing"],
           "proposed_action":{"kind":"mark_done|close_dup|restatus|split|none","to_status":"done","dup_of":"","why":"one line"}}
        ]}
        Every "item" must be an EXISTING id from the board above. Omit array fields you have \
        no evidence for (use [] — do not invent refs).
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

    // MARK: Sync (production only)

    private static func runSync() {
        let cwd = Config.backlogDirectory.path
        ShellExec.runDetached(["sh", "-c",
            "git add -A && git commit -m 'reconcile: board↔code' && git push"],
            cwd: cwd)
    }
}
