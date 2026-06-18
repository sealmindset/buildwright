import Testing
import Foundation
@testable import Buildwright

/// Exercises the capture file-writing path against a THROWAWAY temp directory.
/// No `claude -p`, no git, no network — just: canned triage JSON → files on
/// disk, asserting frontmatter (type/size) and the Provenance/Understanding
/// body match the shared contract.
@MainActor
struct CaptureIntakeTests {

    /// A fresh temp board with one existing epic (E49) and one story under it.
    private func makeTempBoard() throws -> (dir: URL, store: BacklogStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bw-capture-\(UUID().uuidString)", isDirectory: true)
        let items = dir.appendingPathComponent("items", isDirectory: true)
        let epicDir = items.appendingPathComponent("EPIC-49-template-maker", isDirectory: true)
        try FileManager.default.createDirectory(
            at: epicDir.appendingPathComponent("stories"), withIntermediateDirectories: true)
        let epic = """
        ---
        id: E49
        title: Template Maker
        type: epic
        status: in-progress
        category: tools
        priority: P2
        created: 2026-06-01
        updated: 2026-06-10
        ---

        The template-authoring epic.
        """
        try epic.write(to: epicDir.appendingPathComponent("epic.md"), atomically: true, encoding: .utf8)
        let s1 = """
        ---
        id: E49-S1
        title: First story
        type: story
        parent: E49
        status: done
        created: 2026-06-01
        updated: 2026-06-02
        ---

        body
        """
        try s1.write(to: epicDir.appendingPathComponent("stories/S1-first.md"),
                     atomically: true, encoding: .utf8)
        setenv("BUILDWRIGHT_BACKLOG_DIR", dir.path, 1)
        let store = BacklogStore()
        store.reload()
        return (dir, store)
    }

    private func decode(_ json: String) throws -> TriageVerdict {
        try #require(CaptureIntake.parseVerdict(fromResultText: json))
    }

    @Test func filesUnderExistingEpicWithFrontmatterAndProvenance() throws {
        let (dir, store) = try makeTempBoard()
        defer { try? FileManager.default.removeItem(at: dir); unsetenv("BUILDWRIGHT_BACKLOG_DIR") }

        let json = """
        {
          "type": "breakfix",
          "size": "S",
          "title": "Fix template export crash",
          "category": "tools",
          "priority": "P1",
          "placement": { "mode": "existing", "epic": "E49", "confidence": 0.88, "why": "exporting is a Template Maker concern" },
          "acceptance": ["Export no longer crashes", "A regression test covers the empty-template case"],
          "dedup": { "duplicate_of": "E49-S1", "confidence": 0.3 },
          "open_questions": ["Which export formats are affected?"]
        }
        """
        let verdict = try decode(json)
        let result = try CaptureIntake.fileItem(
            verdict: verdict,
            raw: "the template export crashes when the template is empty\nsecond line of context",
            today: "2026-06-18", store: store)

        // Filed as the next story under E49 (S1 exists → S2).
        #expect(result.itemID == "E49-S2")
        #expect(result.type == "breakfix")
        #expect(result.size == "S")
        #expect(result.homeTitle == "Template Maker")
        #expect(result.createdPaths.count == 1)

        let file = try #require(result.createdPaths.first)
        let content = try String(contentsOf: file, encoding: .utf8)
        let (fields, body) = Frontmatter.parse(content)
        var fm: [String: String] = [:]
        for (k, v) in fields { fm[k] = v }
        #expect(fm["id"] == "E49-S2")
        #expect(fm["type"] == "breakfix")
        #expect(fm["size"] == "S")          // the new schema field round-trips
        #expect(fm["parent"] == "E49")
        #expect(fm["status"] == "backlog")
        #expect(fm["priority"] == "P1")
        #expect(fm["title"] == "Fix template export crash")

        // Understanding template present.
        #expect(body.contains("## Understanding"))
        #expect(body.contains("Definition of done"))
        #expect(body.contains("Export no longer crashes"))
        #expect(body.contains("Which export formats are affected?"))

        // Provenance block: verbatim capture + Scrum Master triage.
        #expect(body.contains("## Captured"))
        #expect(body.contains("> the template export crashes when the template is empty"))
        #expect(body.contains("> second line of context"))
        #expect(body.contains("_via Buildwright quick-capture · 2026-06-18_"))
        #expect(body.contains("## Scrum Master triage"))
        #expect(body.contains("type: breakfix · size: S"))
        #expect(body.contains("E49"))
        // dedup is advisory and shown, not auto-closed.
        #expect(body.contains("possible duplicate of E49-S1"))

        // The store reloads it with the new schema intact.
        store.reload()
        let filed = store.epics.first { $0.epic.itemID == "E49" }?
            .stories.first { $0.itemID == "E49-S2" }
        let loaded = try #require(filed)
        #expect(loaded.type == "breakfix")
        #expect(loaded.size == "S")
    }

    @Test func mintsNewEpicWhenNothingFits() throws {
        let (dir, store) = try makeTempBoard()
        defer { try? FileManager.default.removeItem(at: dir); unsetenv("BUILDWRIGHT_BACKLOG_DIR") }

        let json = """
        {
          "type": "story",
          "size": "M",
          "title": "Add offline sync",
          "category": "sync",
          "priority": "P2",
          "placement": { "mode": "new", "confidence": 0.4, "why": "no existing epic covers sync" },
          "new_epic": { "slug": "offline-sync", "title": "Offline Sync", "category": "sync" },
          "acceptance": ["Edits queue while offline"]
        }
        """
        let verdict = try decode(json)
        let result = try CaptureIntake.fileItem(
            verdict: verdict, raw: "we should sync offline edits", today: "2026-06-18", store: store)

        // E49 exists → next epic is E50, child is E50-S1.
        #expect(result.itemID == "E50-S1")
        #expect(result.homeTitle == "Offline Sync")
        #expect(result.createdPaths.count == 1) // the whole new epic dir

        store.reload()
        let epic = try #require(store.epics.first { $0.epic.itemID == "E50" })
        #expect(epic.epic.title == "Offline Sync")
        let child = try #require(epic.stories.first { $0.itemID == "E50-S1" })
        #expect(child.type == "story")
        #expect(child.size == "M")

        // Undo deletes the whole epic dir.
        for path in result.createdPaths { try? FileManager.default.removeItem(at: path) }
        store.reload()
        #expect(store.epics.first { $0.epic.itemID == "E50" } == nil)
    }

    @Test func epicScaleCaptureBecomesTheEpicItself() throws {
        let (dir, store) = try makeTempBoard()
        defer { try? FileManager.default.removeItem(at: dir); unsetenv("BUILDWRIGHT_BACKLOG_DIR") }

        let json = """
        {
          "type": "epic",
          "size": "XL",
          "title": "Billing Revamp",
          "category": "billing",
          "priority": "P1",
          "placement": { "mode": "new", "confidence": 0.5, "why": "large, standalone" },
          "new_epic": { "slug": "billing-revamp", "title": "Billing Revamp", "category": "billing" }
        }
        """
        let verdict = try decode(json)
        let result = try CaptureIntake.fileItem(
            verdict: verdict, raw: "rebuild the billing system", today: "2026-06-18", store: store)

        #expect(result.itemID == "E50")
        #expect(result.type == "epic")
        store.reload()
        let epic = try #require(store.epics.first { $0.epic.itemID == "E50" })
        #expect(epic.epic.type == "epic")
        #expect(epic.epic.size == "XL")
        #expect(epic.stories.isEmpty)
    }

    @Test func parsesVerdictWithSurroundingProse() throws {
        // The model occasionally wraps the JSON; the parser must still find it.
        let text = "Here is the triage:\n```json\n{\"type\":\"task\",\"size\":\"XS\",\"title\":\"t\",\"category\":\"c\",\"priority\":\"P3\",\"placement\":{\"mode\":\"new\"}}\n```\nDone."
        let verdict = try #require(CaptureIntake.parseVerdict(fromResultText: text))
        #expect(verdict.type == "task")
        #expect(verdict.size == "XS")
        #expect(verdict.placement.mode == "new")
    }
}
