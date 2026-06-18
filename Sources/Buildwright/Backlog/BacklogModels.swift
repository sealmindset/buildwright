import Foundation

/// One backlog item: an epic or a story. Mirrors the /backlog skill's
/// markdown-with-frontmatter format exactly.
struct BacklogItem: Identifiable, Equatable {
    var id: String { itemID }
    var itemID: String          // "E04" or "E04-S2"
    var title: String
    var type: String            // "epic" | "story" | "task" | "breakfix" | "spike"
    var size: String            // "XS" | "S" | "M" | "L" | "XL" or "" (t-shirt sizing)
    var status: String          // backlog/designing/ready/in-progress/blocked/done
    var category: String
    var priority: String        // P1/P2/P3 or ""
    var parent: String          // epic id for stories
    var created: String
    var updated: String
    var body: String            // markdown after frontmatter
    var fileURL: URL
    var designURL: URL?         // epics: design.md when present
    var extraFrontmatter: [(String, String)] = [] // preserve unknown keys in order

    var isEpic: Bool { type == "epic" }
    var isDone: Bool { status == "done" || status == "closed" }

    static func == (lhs: BacklogItem, rhs: BacklogItem) -> Bool {
        lhs.itemID == rhs.itemID && lhs.title == rhs.title && lhs.type == rhs.type
            && lhs.size == rhs.size
            && lhs.status == rhs.status && lhs.category == rhs.category
            && lhs.priority == rhs.priority && lhs.parent == rhs.parent
            && lhs.created == rhs.created && lhs.updated == rhs.updated
            && lhs.body == rhs.body && lhs.fileURL == rhs.fileURL
            && lhs.designURL == rhs.designURL
            && lhs.extraFrontmatter.elementsEqual(rhs.extraFrontmatter, by: { $0.0 == $1.0 && $0.1 == $1.1 })
    }

    static let allStatuses = ["backlog", "designing", "ready", "in-progress", "blocked", "done"]
}

struct BacklogEpic: Identifiable, Equatable {
    var id: String { epic.itemID }
    var epic: BacklogItem
    var stories: [BacklogItem]
    var directory: URL

    /// Stories visible given filters; epic-level done filtering happens upstream.
    func filteredStories(_ filters: BacklogFilters) -> [BacklogItem] {
        stories.filter { story in
            if !filters.showDone && story.isDone { return false }
            if !filters.statuses.isEmpty && !filters.statuses.contains(story.status) { return false }
            return true
        }
    }
}

enum Frontmatter {
    /// Parse a markdown file with YAML-ish frontmatter (the simple key: value
    /// subset the /backlog skill writes). Returns (fields-in-order, body).
    static func parse(_ content: String) -> (fields: [(String, String)], body: String) {
        let lines = content.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return ([], content)
        }
        var fields: [(String, String)] = []
        var i = 1
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                let body = lines[(i + 1)...].joined(separator: "\n")
                return (fields, body)
            }
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if !key.isEmpty { fields.append((key, value)) }
            }
            i += 1
        }
        return ([], content) // no closing --- : treat whole file as body
    }

    /// Serialize back, preserving field order.
    static func serialize(fields: [(String, String)], body: String) -> String {
        var out = "---\n"
        for (k, v) in fields {
            out += "\(k): \(v)\n"
        }
        out += "---\n"
        out += body
        return out
    }
}
