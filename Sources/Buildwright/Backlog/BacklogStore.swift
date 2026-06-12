import Foundation
import Combine

/// Reads, watches, and writes the /backlog skill's board at ~/.claude/backlog.
/// All writes use the exact same markdown frontmatter format so the skill and
/// Buildwright stay perfectly interchangeable.
@MainActor
final class BacklogStore: ObservableObject {
    @Published var epics: [BacklogEpic] = []
    @Published var lastError: String?

    private var watcher: DispatchSourceFileSystemObject?
    private var watchFD: Int32 = -1
    private var reloadTimer: Timer?

    var itemsDirectory: URL {
        Config.backlogDirectory.appendingPathComponent("items", isDirectory: true)
    }

    var boardFile: URL {
        Config.backlogDirectory.appendingPathComponent("BOARD.md")
    }

    var allCategories: [String] {
        Array(Set(epics.map { $0.epic.category }.filter { !$0.isEmpty })).sorted()
    }

    var allPriorities: [String] {
        Array(Set(epics.map { $0.epic.priority }.filter { !$0.isEmpty })).sorted()
    }

    // MARK: Loading

    func reload() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: itemsDirectory, includingPropertiesForKeys: nil) else {
            epics = []
            return
        }
        var loaded: [BacklogEpic] = []
        for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard dir.hasDirectoryPath || (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let epicFile = dir.appendingPathComponent("epic.md")
            guard let epicItem = loadItem(at: epicFile) else { continue }
            var epic = epicItem
            let designFile = dir.appendingPathComponent("design.md")
            if fm.fileExists(atPath: designFile.path) { epic.designURL = designFile }

            var stories: [BacklogItem] = []
            let storiesDir = dir.appendingPathComponent("stories")
            if let storyFiles = try? fm.contentsOfDirectory(at: storiesDir, includingPropertiesForKeys: nil) {
                for f in storyFiles.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
                where f.pathExtension == "md" {
                    if let story = loadItem(at: f) { stories.append(story) }
                }
            }
            loaded.append(BacklogEpic(epic: epic, stories: stories, directory: dir))
        }
        epics = loaded.sorted { $0.epic.itemID.localizedStandardCompare($1.epic.itemID) == .orderedAscending }
    }

    private func loadItem(at url: URL) -> BacklogItem? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let (fields, body) = Frontmatter.parse(content)
        guard !fields.isEmpty else { return nil }
        var dict: [String: String] = [:]
        for (k, v) in fields { dict[k] = v }
        let known = Set(["id", "title", "type", "status", "category", "priority", "parent", "created", "updated", "design"])
        return BacklogItem(
            itemID: dict["id"] ?? url.deletingPathExtension().lastPathComponent,
            title: dict["title"] ?? "",
            type: dict["type"] ?? (url.lastPathComponent == "epic.md" ? "epic" : "story"),
            status: dict["status"] ?? "backlog",
            category: dict["category"] ?? "",
            priority: dict["priority"] ?? "",
            parent: dict["parent"] ?? "",
            created: dict["created"] ?? "",
            updated: dict["updated"] ?? "",
            body: body,
            fileURL: url,
            designURL: nil,
            extraFrontmatter: fields.filter { !known.contains($0.0) }
        )
    }

    // MARK: Watching

    func startWatching() {
        reload()
        let path = itemsDirectory.path
        watchFD = open(path, O_EVTONLY)
        guard watchFD >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watchFD, eventMask: [.write, .rename], queue: .main)
        src.setEventHandler { [weak self] in self?.scheduleReload() }
        src.setCancelHandler { [fd = watchFD] in close(fd) }
        src.resume()
        watcher = src
        // Item edits happen in nested files; the top-level watch misses some.
        // A light periodic reload keeps the board fresh (cheap: ~100 files).
        reloadTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    private func scheduleReload() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self.reload()
        }
    }

    // MARK: Filtering

    func filteredEpics(_ filters: BacklogFilters) -> [BacklogEpic] {
        epics.filter { group in
            let epic = group.epic
            if !filters.showDone && epic.isDone { return false }
            if !filters.statuses.isEmpty && !filters.statuses.contains(epic.status) { return false }
            if !filters.categories.isEmpty && !filters.categories.contains(epic.category) { return false }
            if !filters.priorities.isEmpty && !filters.priorities.contains(epic.priority) { return false }
            if !filters.searchText.isEmpty {
                let q = filters.searchText.lowercased()
                let epicMatch = epic.itemID.lowercased().contains(q) || epic.title.lowercased().contains(q)
                let storyMatch = group.stories.contains {
                    $0.itemID.lowercased().contains(q) || $0.title.lowercased().contains(q)
                }
                if !epicMatch && !storyMatch { return false }
            }
            return true
        }
    }

    // MARK: Writing (format-compatible with the /backlog skill)

    private static var today: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    func setStatus(_ item: BacklogItem, to status: String) {
        guard let content = try? String(contentsOf: item.fileURL, encoding: .utf8) else { return }
        var (fields, body) = Frontmatter.parse(content)
        let old = fields.first { $0.0 == "status" }?.1 ?? "backlog"
        guard old != status else { return }
        Self.setField(&fields, "status", status)
        Self.setField(&fields, "updated", Self.today)
        body = Self.appendingHistory(to: body, line: "status \(old) → \(status)")
        write(fields: fields, body: body, to: item.fileURL)
    }

    /// Traceability: append one event line to the item's own markdown —
    /// the work history travels with the item, readable by anything.
    func appendHistory(_ item: BacklogItem, _ line: String) {
        guard let content = try? String(contentsOf: item.fileURL, encoding: .utf8) else { return }
        var (fields, body) = Frontmatter.parse(content)
        Self.setField(&fields, "updated", Self.today)
        body = Self.appendingHistory(to: body, line: line)
        write(fields: fields, body: body, to: item.fileURL)
    }

    nonisolated static func appendingHistory(to body: String, line: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var out = body
        while out.hasSuffix("\n") || out.hasSuffix(" ") { out.removeLast() }
        if !out.contains("\n## History") && !out.hasPrefix("## History") {
            out += "\n\n## History\n"
        }
        out += "\n- \(f.string(from: Date())) — \(line)\n"
        return out
    }

    func updateTitleAndBody(_ item: BacklogItem, title: String, priority: String, body: String) {
        guard let content = try? String(contentsOf: item.fileURL, encoding: .utf8) else { return }
        var (fields, _) = Frontmatter.parse(content)
        Self.setField(&fields, "title", title)
        if !priority.isEmpty || fields.contains(where: { $0.0 == "priority" }) {
            Self.setField(&fields, "priority", priority)
        }
        Self.setField(&fields, "updated", Self.today)
        write(fields: fields, body: body, to: item.fileURL)
    }

    private func write(fields: [(String, String)], body: String, to url: URL) {
        let out = Frontmatter.serialize(fields: fields, body: body)
        do {
            try out.write(to: url, atomically: true, encoding: .utf8)
            reload()
            regenerateBoard()
        } catch {
            lastError = "Could not save \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    nonisolated static func setField(_ fields: inout [(String, String)], _ key: String, _ value: String) {
        if let idx = fields.firstIndex(where: { $0.0 == key }) {
            fields[idx] = (key, value)
        } else {
            fields.append((key, value))
        }
    }

    // MARK: Creating items

    /// Next epic number across the board (E41 after E40).
    var nextEpicNumber: Int {
        let numbers = epics.compactMap { Int($0.epic.itemID.dropFirst()) }
        return (numbers.max() ?? 0) + 1
    }

    func createEpic(title: String, category: String, priority: String, body: String) {
        let n = nextEpicNumber
        let id = String(format: "E%02d", n)
        let slug = Self.slugify(title)
        let dir = itemsDirectory.appendingPathComponent(String(format: "EPIC-%02d-%@", n, slug), isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent("stories"), withIntermediateDirectories: true)
            let fields: [(String, String)] = [
                ("id", id), ("title", title), ("type", "epic"), ("status", "backlog"),
                ("category", category), ("priority", priority),
                ("created", Self.today), ("updated", Self.today)
            ]
            let content = Frontmatter.serialize(fields: fields, body: "\n" + body + "\n")
            try content.write(to: dir.appendingPathComponent("epic.md"), atomically: true, encoding: .utf8)
            reload()
            regenerateBoard()
        } catch {
            lastError = "Could not create epic: \(error.localizedDescription)"
        }
    }

    func createStory(in group: BacklogEpic, title: String, body: String) {
        let nums = group.stories.compactMap { item -> Int? in
            guard let range = item.itemID.range(of: "-S") else { return nil }
            return Int(item.itemID[range.upperBound...].prefix(while: { $0.isNumber }))
        }
        let n = (nums.max() ?? 0) + 1
        let id = "\(group.epic.itemID)-S\(n)"
        let slug = Self.slugify(title)
        let file = group.directory
            .appendingPathComponent("stories")
            .appendingPathComponent("S\(n)-\(slug).md")
        let fields: [(String, String)] = [
            ("id", id), ("title", title), ("type", "story"), ("parent", group.epic.itemID),
            ("status", "backlog"), ("created", Self.today), ("updated", Self.today)
        ]
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let content = Frontmatter.serialize(fields: fields, body: "\n" + body + "\n")
            try content.write(to: file, atomically: true, encoding: .utf8)
            reload()
            regenerateBoard()
        } catch {
            lastError = "Could not create story: \(error.localizedDescription)"
        }
    }

    nonisolated static func slugify(_ title: String) -> String {
        let lowered = title.lowercased()
        var out = ""
        for ch in lowered {
            if ch.isLetter || ch.isNumber { out.append(ch) }
            else if ch == " " || ch == "-" || ch == "_" { out.append("-") }
        }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(trimmed.prefix(40)).isEmpty ? "item" : String(trimmed.prefix(40))
    }

    // MARK: BOARD.md regeneration (same shape the skill maintains)

    func regenerateBoard() {
        let statusOrder = ["in-progress", "ready", "blocked", "designing", "backlog", "done"]
        var byStatus: [String: [BacklogEpic]] = [:]
        for group in epics {
            byStatus[group.epic.status, default: []].append(group)
        }
        var counts: [String] = []
        for s in statusOrder {
            if let c = byStatus[s]?.count, c > 0 { counts.append("\(s) \(c)") }
        }
        var out = "# BACKLOG BOARD\n\n**Epics:** " + counts.joined(separator: " · ") + "\n"
        for status in statusOrder {
            guard let groups = byStatus[status], !groups.isEmpty else { continue }
            out += "\n## \(status) (\(groups.count))\n"
            for group in groups {
                let e = group.epic
                let meta = [e.category.isEmpty ? nil : "[\(e.category)]", e.priority.isEmpty ? nil : e.priority]
                    .compactMap { $0 }.joined(separator: " ")
                out += "- **\(e.itemID)** · \(e.title)" + (meta.isEmpty ? "" : "  _\(meta)_") + "\n"
                for s in group.stories {
                    out += "    - \(s.itemID) · \(s.title) _(\(s.status))_\n"
                }
            }
        }
        try? out.write(to: boardFile, atomically: true, encoding: .utf8)
    }
}
