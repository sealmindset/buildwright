import Testing
import Foundation
@testable import Buildwright

/// Hermetic tests for the reconciliation engine: canned verdict JSON in,
/// asserting verdict parsing, auto-apply-vs-flag classification, the board
/// mutation + provenance write against a TEMP dir, and nextSafeGap selection.
/// NO git/sync, NO live `claude -p`, NO docai/prod access.
@MainActor
struct ReconcilerTests {

    // MARK: Temp board

    private func makeTempBoard() throws -> (dir: URL, store: BacklogStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bw-reconcile-\(UUID().uuidString)", isDirectory: true)
        let items = dir.appendingPathComponent("items", isDirectory: true)
        let epicDir = items.appendingPathComponent("EPIC-20-mercury", isDirectory: true)
        try FileManager.default.createDirectory(
            at: epicDir.appendingPathComponent("stories"), withIntermediateDirectories: true)
        let epic = """
        ---
        id: E20
        title: Mercury Agent
        type: epic
        status: ready
        category: agents
        priority: P1
        created: 2026-06-01
        updated: 2026-06-10
        ---

        The Mercury agent epic.
        """
        try epic.write(to: epicDir.appendingPathComponent("epic.md"), atomically: true, encoding: .utf8)
        setenv("BUILDWRIGHT_BACKLOG_DIR", dir.path, 1)
        let store = BacklogStore()
        store.reload()
        return (dir, store)
    }

    // MARK: Parsing

    @Test func parsesVerdictsEnvelope() throws {
        let json = """
        {"items":[
          {"item":"E20","verdict":"built","confidence":0.92,
           "evidence":{"code":["src/lib/agents/mercury.ts:1"],"tests":["test-smoke.mjs:40"],"live":["docai.vlf.legal/agents/mercury"]},
           "gaps":[],
           "proposed_action":{"kind":"mark_done","to_status":"done","dup_of":"","why":"full ladder green"}}
        ]}
        """
        let verdicts = try #require(Reconciler.parseVerdicts(fromResultText: json))
        #expect(verdicts.count == 1)
        let v = verdicts[0]
        #expect(v.item == "E20")
        #expect(v.verdict == "built")
        #expect(v.confidence == 0.92)
        #expect(v.evidence.code == ["src/lib/agents/mercury.ts:1"])
        #expect(v.proposed_action.kind == "mark_done")
    }

    @Test func parsesVerdictsWithSurroundingProse() throws {
        let text = "Here is the audit:\n```json\n{\"items\":[{\"item\":\"E21\",\"verdict\":\"not-built\",\"confidence\":0.7,\"evidence\":{},\"proposed_action\":{\"kind\":\"none\",\"why\":\"nothing in code\"}}]}\n```\nDone."
        let verdicts = try #require(Reconciler.parseVerdicts(fromResultText: text))
        #expect(verdicts.count == 1)
        #expect(verdicts[0].item == "E21")
        #expect(verdicts[0].verdict == "not-built")
    }

    // MARK: Classification (auto-apply vs flag)

    private func verdict(_ item: String, _ v: String, _ conf: Double,
                         kind: String, toStatus: String? = nil, dupOf: String? = nil,
                         code: [String] = [], tests: [String] = [], live: [String] = []) -> ReconcileVerdict {
        ReconcileVerdict(
            item: item, verdict: v, confidence: conf,
            evidence: .init(code: code, tests: tests, live: live),
            gaps: nil,
            proposed_action: .init(kind: kind, to_status: toStatus, dup_of: dupOf, why: "why"))
    }

    @Test func builtWithFullLadderAndHighConfidenceAutoApplies() {
        let v = verdict("E20", "built", 0.9, kind: "mark_done",
                        code: ["a.ts:1"], tests: ["t.mjs:1"], live: ["url"])
        #expect(v.hasFullLadder)
        #expect(v.isAutoApplicable)
    }

    @Test func markDoneWithoutFullLadderIsFlagged() {
        // High confidence but missing the live rung → never auto-done.
        let v = verdict("E20", "built", 0.95, kind: "mark_done",
                        code: ["a.ts:1"], tests: ["t.mjs:1"], live: [])
        #expect(!v.hasFullLadder)
        #expect(!v.isAutoApplicable)
    }

    @Test func lowConfidenceIsFlagged() {
        let v = verdict("E20", "built", 0.6, kind: "mark_done",
                        code: ["a.ts:1"], tests: ["t.mjs:1"], live: ["url"])
        #expect(!v.isAutoApplicable)
    }

    @Test func restatusReversibleAutoApplies() {
        let v = verdict("E20", "partial", 0.85, kind: "restatus", toStatus: "in-progress",
                        code: ["a.ts:1"])
        #expect(v.isAutoApplicable)
    }

    @Test func closeDupReversibleAutoApplies() {
        let v = verdict("E20", "built", 0.9, kind: "close_dup", dupOf: "E10")
        #expect(v.isAutoApplicable)
    }

    @Test func splitAndNoneNeverAutoApply() {
        let split = verdict("E20", "partial", 0.99, kind: "split")
        let none = verdict("E20", "built", 0.99, kind: "none")
        #expect(!split.isAutoApplicable)
        #expect(!none.isAutoApplicable)
    }

    // MARK: Board mutation + provenance (temp dir, no sync)

    @Test func mutateBoardSetsStatusAndWritesProvenance() throws {
        let (dir, store) = try makeTempBoard()
        defer { try? FileManager.default.removeItem(at: dir); unsetenv("BUILDWRIGHT_BACKLOG_DIR") }

        let item = try #require(store.epics.first?.epic)
        #expect(item.status == "ready")

        let v = verdict("E20", "built", 0.9, kind: "mark_done",
                        code: ["src/lib/agents/mercury.ts:1"],
                        tests: ["test-smoke.mjs:40"], live: ["docai.vlf.legal/agents/mercury"])
        Reconciler.mutateBoard(item: item, verdict: v, newStatus: "done", store: store)

        store.reload()
        let reloaded = try #require(store.epics.first?.epic)
        #expect(reloaded.status == "done")
        // Provenance block per the contract.
        #expect(reloaded.body.contains("## Reconciliation ("))
        #expect(reloaded.body.contains("verdict: built · confidence: 0.90 · via: code+tests+live"))
        #expect(reloaded.body.contains("action: marked done — undo available"))
        #expect(reloaded.body.contains("src/lib/agents/mercury.ts:1"))
    }

    @Test func provenanceBlockReflectsCloseDup() {
        let v = verdict("E20", "built", 0.88, kind: "close_dup", dupOf: "E10")
        let block = Reconciler.provenanceBlock(verdict: v, newStatus: "done", today: "2026-06-18")
        #expect(block.contains("## Reconciliation (2026-06-18)"))
        #expect(block.contains("closed as duplicate of E10"))
    }

    // MARK: nextSafeGap selection

    /// Build a synthetic board: E20 (P1, ready), E21 (P2, ready), E22 (P3, in-progress).
    private func syntheticEpics() -> [BacklogEpic] {
        func epic(_ id: String, _ status: String, _ priority: String) -> BacklogEpic {
            let item = BacklogItem(itemID: id, title: id, type: "epic", size: "",
                                   status: status, category: "agents", priority: priority,
                                   parent: "", created: "", updated: "", body: "",
                                   fileURL: URL(fileURLWithPath: "/tmp/\(id).md"))
            return BacklogEpic(epic: item, stories: [], directory: URL(fileURLWithPath: "/tmp/\(id)"))
        }
        return [epic("E20", "ready", "P1"),
                epic("E21", "ready", "P2"),
                epic("E22", "in-progress", "P3")]
    }

    @Test func nextSafeGapPicksHighestPriorityUnblockedGap() {
        let epics = syntheticEpics()
        let verdicts = [
            verdict("E20", "not-built", 0.6, kind: "none"),
            verdict("E21", "partial", 0.6, kind: "none"),
        ]
        let gap = Reconciler.computeNextSafeGap(verdicts: verdicts, epics: epics, plan: nil)
        #expect(gap?.itemID == "E20")   // P1 beats P2
    }

    @Test func nextSafeGapSkipsItemsWithUnfinishedDependency() {
        let epics = syntheticEpics()
        // E20 (P1) depends on E22 which is in-progress (not done) → must skip to E21.
        let plan = BacklogPlan(
            generatedAt: Date(),
            epics: [BacklogPlan.PlannedEpic(id: "E20", title: "E20", effort: "M", reason: "",
                                            dependsOn: ["E22"], unblocks: nil, conflictsWith: nil, nextStories: nil)],
            parallelSafe: nil)
        let verdicts = [
            verdict("E20", "not-built", 0.6, kind: "none"),
            verdict("E21", "not-built", 0.6, kind: "none"),
        ]
        let gap = Reconciler.computeNextSafeGap(verdicts: verdicts, epics: epics, plan: plan)
        #expect(gap?.itemID == "E21")
    }

    @Test func nextSafeGapSkipsConflictWithInProgress() {
        let epics = syntheticEpics()  // E22 is in-progress
        // E20 conflicts with E22 (in progress) → skip to E21.
        let plan = BacklogPlan(
            generatedAt: Date(),
            epics: [BacklogPlan.PlannedEpic(id: "E20", title: "E20", effort: "M", reason: "",
                                            dependsOn: nil, unblocks: nil, conflictsWith: ["E22"], nextStories: nil)],
            parallelSafe: nil)
        let verdicts = [
            verdict("E20", "partial", 0.6, kind: "none"),
            verdict("E21", "partial", 0.6, kind: "none"),
        ]
        let gap = Reconciler.computeNextSafeGap(verdicts: verdicts, epics: epics, plan: plan)
        #expect(gap?.itemID == "E21")
    }

    @Test func nextSafeGapIgnoresBuiltAndDoneItems() {
        let epics = syntheticEpics()
        let verdicts = [
            verdict("E20", "built", 0.95, kind: "mark_done",
                    code: ["a"], tests: ["t"], live: ["l"]),    // built → not a gap
            verdict("E22", "not-built", 0.6, kind: "none"),     // in-progress → excluded
        ]
        let gap = Reconciler.computeNextSafeGap(verdicts: verdicts, epics: epics, plan: nil)
        #expect(gap == nil)
    }
}
