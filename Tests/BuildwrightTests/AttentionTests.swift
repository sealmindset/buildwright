import Testing
import Foundation
@testable import Buildwright

struct AttentionTests {

    @Test func ageFormatting() {
        let now = Date()
        #expect(ageString(from: now.addingTimeInterval(-5), to: now) == "5s")
        #expect(ageString(from: now.addingTimeInterval(-300), to: now) == "5m")
        #expect(ageString(from: now.addingTimeInterval(-7200), to: now) == "2h")
        #expect(ageString(from: now.addingTimeInterval(-200000), to: now) == "2d")
        #expect(ageString(from: now.addingTimeInterval(10), to: now) == "now")
    }

    @Test func reentryDiffReportsFinishedAndWaiting() {
        let now = Date()
        let snapshot: [String: PaneStatus] = [
            "aaaa": PaneStatus(state: .working, since: now.addingTimeInterval(-3600)),
            "bbbb": PaneStatus(state: .working, since: now.addingTimeInterval(-3600)),
            "cccc": PaneStatus(state: .done, since: now.addingTimeInterval(-3600))
        ]
        let current: [String: PaneStatus] = [
            "aaaa": PaneStatus(state: .done, since: now.addingTimeInterval(-600)),
            "bbbb": PaneStatus(state: .needsInput, since: now.addingTimeInterval(-1200)),
            "cccc": PaneStatus(state: .done, since: now.addingTimeInterval(-3600))
        ]
        let lines = AppState.reentryLines(
            snapshot: snapshot, current: current,
            panes: [("aaaa", "clerk"), ("bbbb", "E04-S2"), ("cccc", "vetting")],
            now: now
        )
        #expect(lines.count == 2, "unchanged panes should not be reported")
        #expect(lines.contains { $0.contains("clerk") && $0.contains("finished") })
        #expect(lines.contains { $0.contains("E04-S2") && $0.contains("waiting") })
    }

    @Test func reentryDiffReportsEndedPanes() {
        let now = Date()
        let snapshot = ["aaaa": PaneStatus(state: .working, since: now.addingTimeInterval(-100))]
        let lines = AppState.reentryLines(
            snapshot: snapshot, current: [:],
            panes: [("aaaa", "clerk")], now: now
        )
        #expect(lines == ["“clerk” ended while you were away"])
    }

    @Test func reentryDiffQuietWhenNothingChanged() {
        let now = Date()
        let same = ["aaaa": PaneStatus(state: .working, since: now.addingTimeInterval(-100))]
        let lines = AppState.reentryLines(
            snapshot: same, current: same,
            panes: [("aaaa", "clerk")], now: now
        )
        #expect(lines.isEmpty)
    }

    @Test func workspaceCodableBackwardCompatible() throws {
        // Old state files (v0.1.x) lack the snapshot fields — they must decode.
        let oldJSON = """
        {"id":"\(UUID().uuidString)","name":"docai","baseRepo":"/tmp","tabs":[],
         "backlogFilters":{"showDone":false,"statuses":[],"categories":[],"priorities":[],"searchText":""}}
        """
        let ws = try JSONDecoder().decode(Workspace.self, from: Data(oldJSON.utf8))
        #expect(ws.name == "docai")
        #expect(ws.lastSeenAt == nil)
        #expect(ws.lastSnapshot == nil)
        #expect(ws.activeBacklogItemID == nil)
    }
}
