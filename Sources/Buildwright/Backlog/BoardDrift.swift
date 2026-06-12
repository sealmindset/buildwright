import Foundation

/// One board↔reality mismatch and the status change that would fix it.
/// Drift is only ever SUGGESTED — the user applies or dismisses; the app
/// never changes the board on its own.
struct DriftSuggestion: Identifiable, Equatable {
    var itemID: String
    var current: String      // board status now
    var suggested: String    // proposed status
    var reason: String       // the observed reality, one line
    var id: String { "\(itemID)→\(suggested)" }
}

/// Pure drift detection: the board's statuses vs. what the panes are
/// actually doing. Pure function of its inputs so it can run on every
/// status tick without side effects.
enum BoardDrift {
    /// What detection needs to know about one Claude pane. Backlog-started
    /// panes carry the item id as their title — that's the join key.
    struct PaneSignal {
        var title: String
        var isQueued: Bool
        var state: ClaudeStatus?
        var since: Date?
    }

    static func detect(epics: [BacklogEpic], panes: [PaneSignal],
                       mergedItemIDs: Set<String>, now: Date) -> [DriftSuggestion] {
        var items: [String: BacklogItem] = [:]
        for group in epics {
            items[group.epic.itemID] = group.epic
            for s in group.stories { items[s.itemID] = s }
        }
        var out: [DriftSuggestion] = []
        var seen = Set<String>()
        func suggest(_ item: BacklogItem, _ to: String, _ reason: String) {
            let key = "\(item.itemID)→\(to)"
            guard !seen.contains(key), item.status != to else { return }
            seen.insert(key)
            out.append(DriftSuggestion(itemID: item.itemID, current: item.status,
                                       suggested: to, reason: reason))
        }

        for pane in panes {
            guard let item = items[pane.title], !item.isDone,
                  let since = pane.since else { continue }
            let age = now.timeIntervalSince(since)
            // Working ≥4 min with the board not saying so. The /backlog
            // skill normally flips the status in the session's first
            // minute — the grace period means a chip here is real drift,
            // not a session that hasn't gotten to it yet.
            if pane.state == .working, age > 240, item.status != "in-progress" {
                suggest(item, "in-progress",
                        "a pane has been working on it for \(ageString(from: since, to: now))")
            }
            // Finished ≥10 min ago and nobody closed the loop on the board.
            if pane.state == .done, age > 600 {
                suggest(item, "done",
                        "its pane finished \(ageString(from: since, to: now)) ago")
            }
        }

        // Branch landed in the base = the strongest done signal there is.
        for itemID in mergedItemIDs.sorted() {
            if let item = items[itemID], !item.isDone {
                suggest(item, "done", "its branch was merged into the base branch")
            }
        }

        // In progress on the board but no session anywhere — an epic counts
        // its stories' panes (E36 is covered by a pane titled E36-S2).
        for group in epics {
            var inProgress: [BacklogItem] = group.epic.status == "in-progress" ? [group.epic] : []
            inProgress += group.stories.filter { $0.status == "in-progress" }
            for item in inProgress {
                let covered = panes.contains {
                    $0.title == item.itemID
                        || (item.isEpic && $0.title.hasPrefix(item.itemID + "-"))
                }
                if !covered {
                    suggest(item, "ready", "in progress on the board, but no pane has a session on it")
                }
            }
        }

        return Array(out.prefix(5))
    }
}
