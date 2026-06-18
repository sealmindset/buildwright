import Foundation

/// The structured verdict an "AI Scrum Master" triage run returns for one
/// captured thought. Mirrors the shared contract with the /backlog skill
/// EXACTLY — strict JSON in, this struct out.
struct TriageVerdict: Codable, Equatable {
    var type: String            // epic | story | task | breakfix | spike
    var size: String            // XS | S | M | L | XL
    var title: String           // short imperative title
    var category: String        // best-fit category
    var priority: String        // P1 | P2 | P3
    var placement: Placement
    var new_epic: NewEpic?
    var acceptance: [String]?
    var dedup: Dedup?
    var open_questions: [String]?

    struct Placement: Codable, Equatable {
        var mode: String        // existing | new
        var epic: String?       // existing: target epic id (E49)
        var confidence: Double?
        var why: String?
    }
    struct NewEpic: Codable, Equatable {
        var slug: String?
        var title: String?
        var category: String?
    }
    struct Dedup: Codable, Equatable {
        var duplicate_of: String?
        var confidence: Double?
    }
}

/// The outcome of one successful capture+file: enough to render the success
/// toast and to undo the write (delete what landed, regenerate, re-sync).
struct CaptureResult: Equatable {
    var itemID: String          // the filed item's id (E49-S3 or E51 for a new epic)
    var type: String
    var size: String
    var homeTitle: String       // the epic title it lives under, for the toast
    var verdict: TriageVerdict
    /// Files/dirs created by this capture, in deletion order (deepest first).
    /// Undo removes exactly these.
    var createdPaths: [URL]
}

/// The "AI Scrum Master intake": a captured thought goes in, headless Claude
/// (read-only tools) triages it against the live board, and the result is
/// auto-filed as a real backlog item — typed, sized, placed under the
/// best-fit epic (or a brand-new one). One Undo reverses the whole write.
///
/// Headless plumbing mirrors ScrumMaster/BacklogGroomer: `claude -p` with
/// Read,Glob,Grep, cwd = the board dir, JSON envelope parsed for `result` /
/// `total_cost_usd` / `is_error`, off-main then hop back.
@MainActor
final class CaptureIntake: ObservableObject {

    enum Phase: Equatable {
        case idle
        case thinking
        case filed(CaptureResult)
        case failed(String)
    }

    @Published var phase: Phase = .idle
    /// Cost callback, wired like the other AI engines.
    var onCost: ((Double) -> Void)?
    /// Model id for `claude --model` (empty = Claude Code default).
    var model = ""
    /// Builds the CURRENT BOARD snapshot — injected by AppState so capture and
    /// the rest of the app share one view of the board.
    var boardSnapshot: () -> String = { "" }

    private let store: BacklogStore
    /// Production paths run `sync` (git add/commit/push of the board). Tests
    /// flip this off so nothing touches git or the network.
    private let syncEnabled: Bool

    init(store: BacklogStore, syncEnabled: Bool = true) {
        self.store = store
        self.syncEnabled = syncEnabled
    }

    /// True while a triage run is in flight (drives the spinner).
    var isThinking: Bool { phase == .thinking }

    /// Kick off a capture: triage the raw text, then auto-file. `keepOpen`
    /// only affects how the UI reacts to success — the engine work is the same.
    func capture(_ rawText: String) {
        let raw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, phase != .thinking else { return }
        phase = .thinking
        let snapshot = boardSnapshot()
        let today = Self.todayString
        let prompt = Self.triagePrompt(board: snapshot, captured: raw, today: today)
        let cwd = Config.backlogDirectory.path
        let model = self.model
        DispatchQueue.global(qos: .userInitiated).async {
            var args = ["claude", "-p", prompt, "--output-format", "json",
                        "--allowedTools", "Read,Glob,Grep"]
            if !model.isEmpty { args += ["--model", model] }
            let result = ShellExec.run(args, cwd: cwd)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finish(result, raw: raw, today: today) }
            }
        }
    }

    private func finish(_ result: ShellResult, raw: String, today: String) {
        let envelope = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        if let cost = envelope?["total_cost_usd"] as? Double { onCost?(cost) }

        if envelope?["is_error"] as? Bool == true,
           let msg = envelope?["result"] as? String, !msg.isEmpty {
            fail(TranscriptReader.condense(msg, limit: 220))
            return
        }
        guard result.ok else {
            let why = result.stderr.isEmpty
                ? "claude exited \(result.status) — is Claude Code installed and logged in?"
                : result.stderr
            fail(TranscriptReader.condense(why, limit: 200))
            return
        }
        guard let text = envelope?["result"] as? String,
              let verdict = Self.parseVerdict(fromResultText: text) else {
            fail("Couldn't read the triage reply — capture not filed. Try again.")
            return
        }
        // File on a fresh reload so ids/numbers reflect any concurrent change.
        store.reload()
        do {
            let outcome = try Self.fileItem(verdict: verdict, raw: raw, today: today, store: store)
            store.reload()
            store.regenerateBoard()
            if syncEnabled { Self.runSync() }
            phase = .filed(outcome)
            ShellExec.notify(title: "Filed \(outcome.itemID)",
                             body: "\(outcome.verdict.title) (\(outcome.type), \(outcome.size)) under \(outcome.homeTitle)")
        } catch {
            fail("Filing failed: \(error.localizedDescription)")
        }
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        ShellExec.notify(title: "Capture failed", body: TranscriptReader.condense(message, limit: 120))
    }

    /// Reverse the last capture: delete exactly what it wrote (item file, and
    /// the new epic dir if it minted one), regenerate the board, re-sync.
    func undo() {
        guard case .filed(let outcome) = phase else { return }
        let fm = FileManager.default
        for path in outcome.createdPaths {
            try? fm.removeItem(at: path)
        }
        store.reload()
        store.regenerateBoard()
        if syncEnabled { Self.runSync() }
        phase = .idle
        ShellExec.notify(title: "Undone", body: "Removed \(outcome.itemID)")
    }

    func dismiss() {
        if case .thinking = phase { return }
        phase = .idle
    }

    // MARK: Filing (pure — no git, no network; the unit-tested path)

    enum FileError: LocalizedError {
        case noBoardDirectory
        case writeFailed(String)
        var errorDescription: String? {
            switch self {
            case .noBoardDirectory: return "the board directory is missing"
            case .writeFailed(let s): return s
            }
        }
    }

    /// Turn a parsed verdict into files on disk under `Config.backlogDirectory`,
    /// via the same Frontmatter format the skill uses. Returns the result with
    /// the created paths so Undo can reverse it. Does NOT regenerate the board
    /// or sync — callers own that so tests stay hermetic.
    static func fileItem(verdict: TriageVerdict, raw: String, today: String,
                         store: BacklogStore) throws -> CaptureResult {
        let fm = FileManager.default
        let itemsDir = store.itemsDirectory
        try? fm.createDirectory(at: itemsDir, withIntermediateDirectories: true)

        let body = bodyMarkdown(verdict: verdict, raw: raw, today: today)
        let wantsNew = verdict.placement.mode == "new"

        if wantsNew {
            // Mint a fresh epic. If the captured item is itself epic-scale,
            // the epic IS the item; otherwise it's the home for a first story.
            let n = store.nextEpicNumber
            let epicID = String(format: "E%02d", n)
            let epicTitle = verdict.new_epic?.title?.nonEmpty ?? verdict.title
            let epicCategory = verdict.new_epic?.category?.nonEmpty ?? verdict.category
            let slug = verdict.new_epic?.slug?.nonEmpty ?? BacklogStore.slugify(epicTitle)
            let epicDir = itemsDir.appendingPathComponent(
                String(format: "EPIC-%02d-%@", n, slug), isDirectory: true)
            try createDir(epicDir.appendingPathComponent("stories"))

            if verdict.type == "epic" {
                // The capture is the epic itself.
                let fields: [(String, String)] = [
                    ("id", epicID), ("title", epicTitle), ("type", "epic"),
                    ("size", verdict.size), ("status", "backlog"),
                    ("category", epicCategory), ("priority", verdict.priority),
                    ("created", today), ("updated", today),
                ]
                let file = epicDir.appendingPathComponent("epic.md")
                try writeItem(fields: fields, body: body, to: file)
                return CaptureResult(itemID: epicID, type: "epic", size: verdict.size,
                                     homeTitle: epicTitle, verdict: verdict,
                                     createdPaths: [epicDir])
            }

            // New epic shell + the captured item as its first child (S1).
            let epicFields: [(String, String)] = [
                ("id", epicID), ("title", epicTitle), ("type", "epic"),
                ("status", "backlog"), ("category", epicCategory),
                ("priority", verdict.priority), ("created", today), ("updated", today),
            ]
            try writeItem(fields: epicFields,
                          body: "\nHome for related work. First item filed via Buildwright quick-capture.\n",
                          to: epicDir.appendingPathComponent("epic.md"))
            let childID = "\(epicID)-S1"
            let childFile = epicDir.appendingPathComponent("stories")
                .appendingPathComponent("S1-\(BacklogStore.slugify(verdict.title)).md")
            try writeItem(fields: childFields(id: childID, parent: epicID, verdict: verdict, today: today),
                          body: body, to: childFile)
            return CaptureResult(itemID: childID, type: verdict.type, size: verdict.size,
                                 homeTitle: epicTitle, verdict: verdict,
                                 createdPaths: [epicDir])
        }

        // mode == "existing": file a child under the named epic.
        guard let epicID = verdict.placement.epic?.nonEmpty,
              let group = store.epics.first(where: { $0.epic.itemID == epicID }) else {
            throw FileError.writeFailed("triage chose an existing epic that isn't on the board")
        }
        let n = nextStoryNumber(in: group)
        let childID = "\(epicID)-S\(n)"
        let childFile = group.directory.appendingPathComponent("stories")
            .appendingPathComponent("S\(n)-\(BacklogStore.slugify(verdict.title)).md")
        try createDir(childFile.deletingLastPathComponent())
        try writeItem(fields: childFields(id: childID, parent: epicID, verdict: verdict, today: today),
                      body: body, to: childFile)
        return CaptureResult(itemID: childID, type: verdict.type, size: verdict.size,
                             homeTitle: group.epic.title, verdict: verdict,
                             createdPaths: [childFile])
    }

    private static func childFields(id: String, parent: String, verdict: TriageVerdict,
                                    today: String) -> [(String, String)] {
        [
            ("id", id), ("title", verdict.title), ("type", verdict.type),
            ("size", verdict.size), ("parent", parent), ("status", "backlog"),
            ("category", verdict.category), ("priority", verdict.priority),
            ("created", today), ("updated", today),
        ]
    }

    private static func nextStoryNumber(in group: BacklogEpic) -> Int {
        let nums = group.stories.compactMap { item -> Int? in
            guard let range = item.itemID.range(of: "-S") else { return nil }
            return Int(item.itemID[range.upperBound...].prefix(while: { $0.isNumber }))
        }
        return (nums.max() ?? 0) + 1
    }

    private static func createDir(_ url: URL) throws {
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        catch { throw FileError.writeFailed(error.localizedDescription) }
    }

    private static func writeItem(fields: [(String, String)], body: String, to url: URL) throws {
        let content = Frontmatter.serialize(fields: fields, body: body)
        do { try content.write(to: url, atomically: true, encoding: .utf8) }
        catch { throw FileError.writeFailed(error.localizedDescription) }
    }

    // MARK: Body composition (Understanding template + Provenance block)

    /// The item body: the Understanding template, then the verbatim capture
    /// and the Scrum Master triage provenance — per the shared contract.
    static func bodyMarkdown(verdict: TriageVerdict, raw: String, today: String) -> String {
        var out = "\n## Understanding\n"
        out += "- **Goal:** \(verdict.title)\n"
        out += "- **Who it's for / the pain:** _to refine_\n"
        out += "- **Constraints:** _to refine_\n"
        out += "- **Definition of done:**\n"
        let dod = (verdict.acceptance ?? []).filter { !$0.isEmpty }
        if dod.isEmpty {
            out += "  - _to refine_\n"
        } else {
            for c in dod { out += "  - \(c)\n" }
        }
        out += "- **Open questions:**\n"
        let qs = (verdict.open_questions ?? []).filter { !$0.isEmpty }
        if qs.isEmpty {
            out += "  - _none captured_\n"
        } else {
            for q in qs { out += "  - \(q)\n" }
        }

        // Provenance: the raw text, verbatim, as a blockquote.
        out += "\n## Captured\n"
        for line in raw.components(separatedBy: "\n") {
            out += "> \(line)\n"
        }
        out += "_via Buildwright quick-capture · \(today)_\n"

        let conf = verdict.placement.confidence.map { String(format: "%.2f", $0) } ?? "—"
        let placement = verdict.placement.mode == "new"
            ? "new epic (\(verdict.new_epic?.title ?? verdict.title))"
            : (verdict.placement.epic ?? "?")
        out += "\n## Scrum Master triage\n"
        out += "- type: \(verdict.type) · size: \(verdict.size) · placement: \(placement) (confidence \(conf))\n"
        out += "- reasoning: \(verdict.placement.why ?? "—")\n"
        if let dedup = verdict.dedup, let of = dedup.duplicate_of?.nonEmpty {
            let dc = dedup.confidence.map { String(format: "%.2f", $0) } ?? "—"
            out += "- possible duplicate of \(of) (confidence \(dc)) — advisory, not auto-closed\n"
        }
        return out
    }

    // MARK: Parsing

    /// Extract the strict-JSON verdict from the model's `result` text. Tolerant
    /// of an accidental ```json fence or surrounding prose: takes the outermost
    /// { … } and decodes it.
    static func parseVerdict(fromResultText text: String) -> TriageVerdict? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"), start < end else { return nil }
        let json = String(text[start...end])
        return try? JSONDecoder().decode(TriageVerdict.self, from: Data(json.utf8))
    }

    // MARK: Sync (production only)

    /// Commit + push the board the way the skill's `sync` does. Fire-and-forget;
    /// the board's git state is the source of truth, so a transient failure
    /// just means the next sync catches up.
    private static func runSync() {
        let cwd = Config.backlogDirectory.path
        ShellExec.runDetached(["sh", "-c",
            "git add -A && git commit -m 'capture: file quick-captured item' && git push"],
            cwd: cwd)
    }

    // MARK: Prompt

    static var todayString: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    static func triagePrompt(board: String, captured: String, today: String) -> String {
        """
        You are the AI Scrum Master triaging ONE captured thought into this backlog board \
        (the current directory IS the board). Today is \(today). Use your Read/Glob/Grep \
        tools to open the relevant epic.md and story files under items/ before you rule — \
        the snapshot is a starting point, not the whole truth.

        CURRENT BOARD (epics):
        \(board.isEmpty ? "(snapshot unavailable — read items/ to learn the board)" : board)

        CAPTURED TEXT (verbatim):
        \"\"\"
        \(captured)
        \"\"\"

        Decide: the work TYPE (epic|story|task|breakfix|spike), a t-shirt SIZE \
        (XS|S|M|L|XL), a short imperative TITLE, the best-fit CATEGORY, a PRIORITY \
        (P1|P2|P3), and WHERE it belongs. Prefer filing under an EXISTING epic when one \
        fits with confidence >= 0.6. If none fits that well, choose mode "new" and propose \
        the new epic — autonomous new-epic creation is desired, do not force a poor fit. \
        Flag a likely duplicate as advisory only; never assume it will be closed.

        Reply with ONLY this JSON object — no markdown fences, no commentary:
        {
          "type": "epic|story|task|breakfix|spike",
          "size": "XS|S|M|L|XL",
          "title": "short imperative title",
          "category": "best-fit category",
          "priority": "P1|P2|P3",
          "placement": { "mode": "existing|new", "epic": "E49", "confidence": 0.82, "why": "one line" },
          "new_epic": { "slug": "kebab-slug", "title": "Title Case", "category": "..." },
          "acceptance": ["..."],
          "dedup": { "duplicate_of": "E49-S2", "confidence": 0.4 },
          "open_questions": ["..."]
        }
        For mode "existing" set placement.epic to the target epic id and omit new_epic \
        (or leave it null). For mode "new" fill new_epic. acceptance is 2-4 testable \
        criteria. Include dedup only when there is a plausible duplicate.
        """
    }
}

private extension String {
    /// nil when empty/whitespace, the trimmed string otherwise.
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
