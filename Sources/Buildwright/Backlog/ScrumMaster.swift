import Foundation

/// A proposed next step the SCRUM master surfaces with a verdict — rendered
/// as a one-click button in the chat. Only ever proposed when the
/// sequencing rules actually justify it.
struct SMAction: Equatable {
    var kind: String        // start | queue | reprioritize
    var item: String        // the item it's about (E04, E30-S2)
    var blocker: String?    // queue: the epic that must finish first
    var summary: String     // one-line rationale (logged when applied)
}

struct SMMessage: Identifiable, Equatable {
    enum Role { case you, master }
    let id = UUID()
    let role: Role
    var text: String
    var action: SMAction?
    var actionDone = false
}

/// The conversational SCRUM master: a multi-turn chat grounded in the board
/// and the saved build sequence. It reasons about what's safe to start, what
/// must finish first, and what can run in parallel — and pushes back when a
/// prioritization ask collides with the dependency graph. It does not write
/// code; its only outputs are advice and proposed actions.
///
/// Continuity uses `claude -p --resume <session_id>`: each turn re-enters the
/// same headless session, so the model keeps the conversation (verified
/// against the live CLI). A fresh board snapshot is prepended every turn so
/// answers track the current state even as panes finish.
@MainActor
final class ScrumMaster: ObservableObject {
    @Published private(set) var messages: [SMMessage] = []
    @Published private(set) var thinking = false
    @Published var lastError: String?

    private var sessionID: String?
    /// Model id for `claude --model` (kept in sync with the app setting).
    var model = ""
    var onCost: ((Double) -> Void)?
    /// Applies a confirmed action; set by AppState.
    var onAction: ((SMAction) -> Void)?

    func reset() {
        messages = []
        sessionID = nil
        lastError = nil
    }

    /// Ask a question. `context` is the live board+plan snapshot AppState
    /// builds — prepended so the model always sees current truth.
    func ask(_ question: String, context: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !thinking else { return }
        messages.append(SMMessage(role: .you, text: q))
        thinking = true
        lastError = nil

        let resume = sessionID
        let model = self.model
        let turn = "\(context)\n\nQUESTION FROM THE TEAM:\n\(q)"
        let cwd = Config.backlogDirectory.path
        DispatchQueue.global(qos: .userInitiated).async {
            var args = ["claude", "-p", turn, "--output-format", "json",
                        "--allowedTools", "Read,Glob,Grep",
                        "--append-system-prompt", Self.systemPrompt]
            if !model.isEmpty { args += ["--model", model] }
            if let resume { args += ["--resume", resume] }
            let result = ShellExec.run(args, cwd: cwd)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finish(result) }
            }
        }
    }

    private func finish(_ result: ShellResult) {
        thinking = false
        let env = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        if let cost = env?["total_cost_usd"] as? Double { onCost?(cost) }
        if let sid = env?["session_id"] as? String { sessionID = sid }

        // Model unavailable / API error: surface the real message.
        if env?["is_error"] as? Bool == true, let msg = env?["result"] as? String, !msg.isEmpty {
            lastError = TranscriptReader.condense(msg, limit: 200)
            return
        }
        guard result.ok, let text = env?["result"] as? String, !text.isEmpty else {
            lastError = result.stderr.isEmpty
                ? "The SCRUM master didn't reply — is Claude Code logged in?"
                : TranscriptReader.condense(result.stderr, limit: 200)
            return
        }
        let (prose, action) = Self.splitAction(text)
        messages.append(SMMessage(role: .master, text: prose, action: action))
    }

    /// Apply the action attached to a message, then mark it done so the
    /// button can't be clicked twice.
    func applyAction(messageID: UUID) {
        guard let i = messages.firstIndex(where: { $0.id == messageID }),
              let action = messages[i].action, !messages[i].actionDone else { return }
        onAction?(action)
        messages[i].actionDone = true
    }

    // MARK: Parsing

    /// Pull the trailing ```action {json}``` block (if any) out of the reply,
    /// returning the prose to show and the parsed action.
    static func splitAction(_ text: String) -> (prose: String, action: SMAction?) {
        guard let range = text.range(of: "```action", options: .caseInsensitive) else {
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }
        let prose = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let after = text[range.upperBound...]
        guard let braceStart = after.firstIndex(of: "{"),
              let braceEnd = after[braceStart...].firstIndex(of: "}") else { return (prose, nil) }
        let json = String(after[braceStart...braceEnd])
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let kind = obj["kind"] as? String, kind != "none",
              let item = obj["item"] as? String, !item.isEmpty else {
            return (prose, nil)
        }
        let action = SMAction(kind: kind, item: item,
                              blocker: (obj["blocker"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                              summary: obj["summary"] as? String ?? "")
        return (prose, action)
    }

    // MARK: System prompt

    static let systemPrompt = """
    You are the SCRUM master for this software backlog (the current directory is the board). \
    Your job is sequencing and prioritization ONLY — you never write code. You decide what is \
    safe to work on now, what must finish first, and what can run in parallel without risk.

    A fresh CURRENT BOARD STATE snapshot is prepended to each question: the build sequence in \
    order, each epic's status and story progress, dependsOn (hard prerequisites), conflictsWith \
    (must never run concurrently — same functionality would collide), the parallel-safe whitelist, \
    and which panes are working right now. Trust the snapshot for status, but it is NOT the whole \
    truth about dependencies. Use your Read/Glob/Grep tools to open the relevant item files under \
    items/ (epic.md, design.md, stories) and DECISIONS.md and actually READ what each item PRODUCES \
    and CONSUMES before you rule. A quick verdict from the fields alone is how you get it wrong.

    Reason about dependencies, don't just look them up:
    - The dependsOn/conflictsWith fields are a floor, not the full picture. Infer FUNCTIONAL and \
    QUALITY dependencies from what items do. If item A produces, generates, files, ships, or \
    exposes an output whose correctness rests on item B's quality gate, spec, schema, validation, \
    or data, then B must precede A even when no dependsOn link is recorded. Example shape: an epic \
    that FILES or PUBLISHES generated artifacts depends on the epic that VALIDATES the templates / \
    rules / data those artifacts are built from — shipping before that gate risks shipping garbage.
    - Weigh the cost of being wrong. Work that is externally visible and hard to reverse — filing \
    to courts or regulators, customer-facing releases, migrations, deploys — is high-stakes. For \
    those, be conservative: prefer finishing the upstream quality gate first, and say why. \
    Precision matters more than speed here.

    How to answer:
    - LINEAR FIRST. Parallel work is allowed only when it is absolutely safe AND saves real time \
    toward finishing the current focus. An item is parallel-safe only if it has no unfinished \
    prerequisite (formal OR functional/quality), does not conflict with in-progress work, and \
    touches files disjoint from active work.
    - A request to prioritize an item is an ASK, not a command — YOU decide. If it has unfinished \
    prerequisites or conflicts, say NO plainly and name exactly which epics/stories must finish \
    first and their status. Don't hedge.
    - If the right call hinges on something the board can't tell you — intent, risk tolerance, \
    whether a quality gate must precede a downstream step, what an item actually covers — ASK a \
    focused clarifying question instead of guessing. A good question beats a confident wrong \
    verdict. When you're asking, omit the action block.
    - Be concrete and brief. Always name the specific IDs and statuses you relied on, and when you \
    inferred a dependency from content, say so in one phrase ("E04 files generated docs; E30 \
    validates the templates they're built from").

    When — and only when — your verdict implies a concrete next step, end your reply with a fenced block:
    ```action
    {"kind":"start|queue|reprioritize|none","item":"E04","blocker":"E30","summary":"one line"}
    ```
    - start: the item is clear to begin now (no unfinished prerequisite, formal or functional; no live conflict).
    - queue: not safe yet — set blocker to the epic that must finish first; it auto-starts when that's done.
    - reprioritize: safe, and the team explicitly asked to move it up the build sequence.
    - none (or omit the block): discussion only, or you're asking a clarifying question.
    Propose only an action your reasoning actually justifies. One action per reply.
    """
}
