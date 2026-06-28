import SwiftUI

// MARK: - Graph model

/// One node in the backlog map: an epic, story, task, breakfix, or spike.
private struct GraphNode: Identifiable {
    let id: String          // itemID
    let item: BacklogItem
    var depth: Int = 0
    var pos: CGPoint = .zero
}

private enum EdgeKind { case parent, depends }

private struct GraphEdge: Identifiable {
    let id: String
    let from: String        // source itemID (the thing that must come first)
    let to: String          // target itemID (the dependent / child)
    let kind: EdgeKind
}

/// A filter set local to the map popup — richer than the sidebar's filters
/// (adds type, effort, and the parallel-candidate dimension).
private struct GraphFilters: Equatable {
    var statuses: Set<String> = []
    var types: Set<String> = []
    var priorities: Set<String> = []
    var sizes: Set<String> = []
    var parallelOnly = false
    var staleOnly = false
    var supersededOnly = false
    var showDone = false
    var search = ""
}

/// Open items untouched for this many days read as "stale" — the Scrum Master's
/// cue that the board has drifted from reality.
private let staleDays = 14

private struct GraphLayout {
    var nodes: [GraphNode] = []
    var edges: [GraphEdge] = []
    var size: CGSize = .zero
    var posByID: [String: CGPoint] = [:]
}

// Layout constants.
private let nodeW: CGFloat = 184
private let nodeH: CGFloat = 68
private let colSpacing: CGFloat = 244
private let rowSpacing: CGFloat = 92
private let margin: CGFloat = 48

// MARK: - The popup

/// An elegant, filterable dependency/flow map of the whole backlog —
/// epics, stories, tasks, breakfix — launched from the toolbar (⇧⌘M).
struct BacklogGraphView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var store: BacklogStore
    @Environment(\.dismiss) private var dismiss

    @State private var f = GraphFilters()
    @State private var zoom: CGFloat = 1.0
    @State private var detailItem: BacklogItem?

    private let types = ["epic", "story", "task", "breakfix", "spike"]
    private let sizes = ["XS", "S", "M", "L", "XL"]
    private let priorities = ["P1", "P2", "P3"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            Divider()
            graphArea
            Divider()
            legend
        }
        .frame(minWidth: 920, idealWidth: 1240, minHeight: 600, idealHeight: 820)
        .sheet(item: $detailItem) { item in
            BacklogDetailView(store: store, item: item, epicGroup: group(for: item))
                .environmentObject(app)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .foregroundStyle(.purple)
            Text("Backlog Map").font(.headline)
            Text("\(visibleCount) shown")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            // Board-hygiene pulse: the Scrum Master's at-a-glance read.
            HStack(spacing: 8) {
                countChip(inProgressCount, "in-progress", .blue)
                countChip(staleCount, "stale", .orange)
                countChip(supersededCount, "superseded", .pink)
            }
            .padding(.leading, 4)
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "minus.magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                Slider(value: $zoom, in: 0.4...1.6).frame(width: 120)
                Image(systemName: "plus.magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    // MARK: Filter bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
                TextField("Search…", text: $f.search)
                    .textFieldStyle(.plain).font(.system(size: 11)).frame(width: 130)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.quaternary.opacity(0.5)).clipShape(RoundedRectangle(cornerRadius: 6))

            filterMenu("Status", BacklogItem.allStatuses, $f.statuses)
            filterMenu("Type", types, $f.types)
            filterMenu("Priority", priorities, $f.priorities)
            filterMenu("Effort", sizes, $f.sizes)

            Toggle(isOn: $f.parallelOnly) {
                Label("Parallel-ready", systemImage: "arrow.triangle.branch").font(.system(size: 10))
            }
            .toggleStyle(.button).controlSize(.small)
            .help("Show only items that can start now without colliding with active work")

            Toggle(isOn: $f.staleOnly) {
                Label("Stale", systemImage: "clock.badge.exclamationmark").font(.system(size: 10))
            }
            .toggleStyle(.button).controlSize(.small)
            .help("Show only open items untouched for \(staleDays)+ days")

            Toggle(isOn: $f.supersededOnly) {
                Label("Superseded", systemImage: "arrow.uturn.forward").font(.system(size: 10))
            }
            .toggleStyle(.button).controlSize(.small)
            .help("Show only items marked no-longer-required (superseded_by another item)")

            Toggle("done", isOn: $f.showDone).toggleStyle(.checkbox).font(.system(size: 10))
                .help("Include completed items")

            Spacer()
            if f != GraphFilters() {
                Button("Clear") { f = GraphFilters() }.controlSize(.small)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func filterMenu(_ title: String, _ options: [String], _ selection: Binding<Set<String>>) -> some View {
        Menu {
            ForEach(options, id: \.self) { opt in
                Button {
                    if selection.wrappedValue.contains(opt) { selection.wrappedValue.remove(opt) }
                    else { selection.wrappedValue.insert(opt) }
                } label: {
                    HStack {
                        if selection.wrappedValue.contains(opt) { Image(systemName: "checkmark") }
                        Text(opt)
                    }
                }
            }
            if !selection.wrappedValue.isEmpty {
                Divider()
                Button("Clear \(title)") { selection.wrappedValue = [] }
            }
        } label: {
            HStack(spacing: 3) {
                Text(title).font(.system(size: 10))
                if !selection.wrappedValue.isEmpty {
                    Text("\(selection.wrappedValue.count)")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 3)
                        .background(Color.accentColor.opacity(0.25)).clipShape(Capsule())
                }
            }
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    // MARK: Graph

    private var graphArea: some View {
        let layout = makeLayout()
        return Group {
            if layout.nodes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text("No items match these filters").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.textBackgroundColor).opacity(0.4))
            } else {
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        Canvas { ctx, _ in
                            for edge in layout.edges {
                                guard let a = layout.posByID[edge.from],
                                      let b = layout.posByID[edge.to] else { continue }
                                drawEdge(ctx, from: a, to: b, kind: edge.kind)
                            }
                        }
                        .frame(width: layout.size.width, height: layout.size.height)

                        ForEach(layout.nodes) { node in
                            nodeCard(node)
                                .frame(width: nodeW, height: nodeH)
                                .position(node.pos)
                        }
                    }
                    .frame(width: layout.size.width, height: layout.size.height)
                    .scaleEffect(zoom, anchor: .topLeading)
                    .frame(width: layout.size.width * zoom, height: layout.size.height * zoom, alignment: .topLeading)
                    .padding(margin / 2)
                }
                .background(Color(NSColor.textBackgroundColor).opacity(0.4))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func drawEdge(_ ctx: GraphicsContext, from a: CGPoint, to b: CGPoint, kind: EdgeKind) {
        let p0 = CGPoint(x: a.x + nodeW / 2, y: a.y)
        let p1 = CGPoint(x: b.x - nodeW / 2, y: b.y)
        let midX = (p0.x + p1.x) / 2
        var path = Path()
        path.move(to: p0)
        path.addCurve(to: p1,
                      control1: CGPoint(x: midX, y: p0.y),
                      control2: CGPoint(x: midX, y: p1.y))
        let color: Color = kind == .depends ? .orange : .secondary
        let style = StrokeStyle(lineWidth: kind == .depends ? 1.8 : 1.0,
                                dash: kind == .depends ? [] : [3, 3])
        ctx.stroke(path, with: .color(color.opacity(kind == .depends ? 0.7 : 0.32)), style: style)
        if kind == .depends {
            // small arrowhead at the target
            let ah = 6.0
            var head = Path()
            head.move(to: CGPoint(x: p1.x, y: p1.y))
            head.addLine(to: CGPoint(x: p1.x - ah, y: p1.y - ah * 0.7))
            head.addLine(to: CGPoint(x: p1.x - ah, y: p1.y + ah * 0.7))
            head.closeSubpath()
            ctx.fill(head, with: .color(.orange.opacity(0.7)))
        }
    }

    // MARK: Node card

    @ViewBuilder
    private func nodeCard(_ node: GraphNode) -> some View {
        let item = node.item
        let startable = startableIDs.contains(item.itemID)
        let parallel = parallelIDs.contains(item.itemID)
        let stale = isStale(item)
        let superseded = supersededBy(item)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                StatusDot(item: item)
                Text(item.itemID)
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .lineLimit(1)
                if stale {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.orange)
                        .help("Stale — untouched \(daysSince(item.updated) ?? staleDays) days. Update status or close it.")
                }
                Spacer(minLength: 2)
                if parallel {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.green)
                        .help("Parallel-ready — can start now without colliding with active work")
                }
                PriorityBadge(priority: item.priority)
            }
            Text(item.title)
                .font(.system(size: 10.5)).lineLimit(2)
                .strikethrough(superseded != nil, color: .pink)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                TypeBadge(type: item.type)
                if !item.size.isEmpty { EffortBadge(size: item.size) }
                if let by = superseded {
                    Text("→ \(by)")
                        .font(.system(size: 8, weight: .semibold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.pink.opacity(0.16)).foregroundStyle(.pink)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .help("No longer required — superseded by \(by)")
                }
                Spacer()
                if startable {
                    Button { app.startBacklogItem(item) } label: {
                        Image(systemName: "play.fill").font(.system(size: 8))
                    }
                    .buttonStyle(.borderless).foregroundStyle(.green)
                    .help("Start in a Claude pane")
                }
            }
        }
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(borderColor(startable: startable, stale: stale, superseded: superseded != nil, item: item),
                              lineWidth: startable || stale ? 2 : 1)
        )
        .opacity(item.isDone || superseded != nil ? 0.5 : 1)
        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        .contentShape(Rectangle())
        .onTapGesture { detailItem = item }
        .contextMenu { nodeMenu(item, startable: startable) }
        .help(item.title)
    }

    @ViewBuilder
    private func nodeMenu(_ item: BacklogItem, startable: Bool) -> some View {
        if startable {
            Button("Start in Claude pane") { app.startBacklogItem(item) }
            Divider()
        }
        Button("Details…") { detailItem = item }
        Menu("Set status") {
            ForEach(BacklogItem.allStatuses, id: \.self) { s in
                Button {
                    store.setStatus(item, to: s)
                } label: {
                    HStack {
                        if item.status == s { Image(systemName: "checkmark") }
                        Text(s)
                    }
                }
            }
        }
        if !item.isDone {
            Divider()
            Button("Mark done — no longer required") {
                store.appendHistory(item, "closed — no longer required")
                store.setStatus(item, to: "done")
            }
        }
    }

    private func borderColor(startable: Bool, stale: Bool, superseded: Bool, item: BacklogItem) -> Color {
        if superseded { return .pink.opacity(0.6) }
        if startable { return .green.opacity(0.9) }
        if stale { return .orange.opacity(0.8) }
        return item.statusColor.opacity(0.55)
    }

    // MARK: Legend

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(color: .green, text: "can start now", filled: false, ring: true)
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 9)).foregroundStyle(.green)
                Text("parallel-ready").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Image(systemName: "clock.badge.exclamationmark").font(.system(size: 9)).foregroundStyle(.orange)
                Text("stale").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Image(systemName: "arrow.uturn.forward").font(.system(size: 9)).foregroundStyle(.pink)
                Text("superseded").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Divider().frame(height: 12)
            edgeLegend(color: .orange, dashed: false, text: "depends on")
            edgeLegend(color: .secondary, dashed: true, text: "epic → child")
            Spacer()
            Text("click a card to edit · ▶ to start · right-click for status")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    private func legendItem(color: Color, text: String, filled: Bool, ring: Bool) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(color, lineWidth: 2).frame(width: 14, height: 10)
            Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func edgeLegend(color: Color, dashed: Bool, text: String) -> some View {
        HStack(spacing: 4) {
            Canvas { ctx, size in
                var p = Path()
                p.move(to: CGPoint(x: 0, y: size.height / 2))
                p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                ctx.stroke(p, with: .color(color.opacity(0.7)),
                           style: StrokeStyle(lineWidth: dashed ? 1 : 1.8, dash: dashed ? [3, 3] : []))
            }
            .frame(width: 22, height: 8)
            Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    // MARK: - Derivation helpers

    private var allItems: [BacklogItem] {
        store.epics.flatMap { [$0.epic] + $0.stories }
    }

    private var itemByID: [String: BacklogItem] {
        Dictionary(allItems.map { ($0.itemID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func daysSince(_ ymd: String) -> Int? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        guard let d = fmt.date(from: ymd.trimmingCharacters(in: .whitespaces)) else { return nil }
        return Calendar.current.dateComponents([.day], from: d, to: Date()).day
    }

    /// Open (not done) and untouched for staleDays+ — the board has gone quiet on it.
    private func isStale(_ item: BacklogItem) -> Bool {
        guard !item.isDone, let days = daysSince(item.updated) else { return false }
        return days >= staleDays
    }

    /// Read a `superseded_by:` frontmatter key (set by the Scrum Master when a
    /// later story solved this one). Surfacing-only — never inferred here.
    private func supersededBy(_ item: BacklogItem) -> String? {
        let keys: Set<String> = ["superseded_by", "superseded-by", "supersededby", "supersedes_by"]
        guard let raw = item.extraFrontmatter.first(where: { keys.contains($0.0.lowercased()) })?.1 else { return nil }
        let s = raw.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }

    private var inProgressCount: Int { allItems.filter { $0.status == "in-progress" }.count }
    private var staleCount: Int { allItems.filter(isStale).count }
    private var supersededCount: Int { allItems.filter { supersededBy($0) != nil && !$0.isDone }.count }

    @ViewBuilder
    private func countChip(_ n: Int, _ label: String, _ color: Color) -> some View {
        if n > 0 {
            Text("\(n) \(label)")
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(color.opacity(0.15)).foregroundStyle(color)
                .clipShape(Capsule())
        }
    }

    private func dependsIDs(_ item: BacklogItem) -> [String] {
        guard let raw = item.extraFrontmatter.first(where: { $0.0.lowercased() == "depends" })?.1 else { return [] }
        return raw.split(whereSeparator: { $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func effectiveCategory(_ item: BacklogItem) -> String {
        if !item.category.isEmpty { return item.category }
        return itemByID[item.parent]?.category ?? ""
    }

    /// Startable now: a non-epic in ready/backlog whose dependencies are all
    /// done and whose parent epic isn't blocked.
    private var startableIDs: Set<String> {
        let map = itemByID
        var out = Set<String>()
        for item in allItems where !item.isEpic {
            guard item.status == "ready" || item.status == "backlog" else { continue }
            let depsClear = dependsIDs(item).allSatisfy { map[$0]?.isDone ?? true }
            guard depsClear else { continue }
            if let parent = map[item.parent], parent.status == "blocked" { continue }
            out.insert(item.itemID)
        }
        return out
    }

    /// Parallel-ready: startable AND its category isn't already claimed by an
    /// in-progress item (so a fresh agent won't trample active work).
    private var parallelIDs: Set<String> {
        let inProgressCats = Set(allItems.filter { $0.status == "in-progress" }.map { effectiveCategory($0) })
        return Set(startableIDs.filter { id in
            guard let item = itemByID[id] else { return false }
            let cat = effectiveCategory(item)
            return cat.isEmpty || !inProgressCats.contains(cat)
        })
    }

    private func group(for item: BacklogItem) -> BacklogEpic? {
        store.epics.first { $0.epic.itemID == item.itemID || $0.epic.itemID == item.parent }
    }

    private func passes(_ item: BacklogItem) -> Bool {
        if !f.showDone && item.isDone { return false }
        if !f.statuses.isEmpty && !f.statuses.contains(item.status) { return false }
        if !f.types.isEmpty && !f.types.contains(item.type) { return false }
        if !f.sizes.isEmpty && !f.sizes.contains(item.size) { return false }
        if !f.priorities.isEmpty {
            let pri = item.priority.isEmpty ? (itemByID[item.parent]?.priority ?? "") : item.priority
            if !f.priorities.contains(pri) { return false }
        }
        if f.parallelOnly && !parallelIDs.contains(item.itemID) { return false }
        if f.staleOnly && !isStale(item) { return false }
        if f.supersededOnly && supersededBy(item) == nil { return false }
        if !f.search.isEmpty {
            let q = f.search.lowercased()
            if !item.itemID.lowercased().contains(q) && !item.title.lowercased().contains(q) { return false }
        }
        return true
    }

    private var visibleCount: Int { allItems.filter(passes).count }

    // MARK: - Layout (layered, left → right by dependency depth)

    private func makeLayout() -> GraphLayout {
        let visible = allItems.filter(passes)
        let visibleIDs = Set(visible.map { $0.itemID })
        guard !visible.isEmpty else { return GraphLayout() }

        var edges: [GraphEdge] = []
        for item in visible {
            if !item.isEpic, visibleIDs.contains(item.parent) {
                edges.append(GraphEdge(id: "p-\(item.parent)-\(item.itemID)",
                                       from: item.parent, to: item.itemID, kind: .parent))
            }
            for dep in dependsIDs(item) where visibleIDs.contains(dep) {
                edges.append(GraphEdge(id: "d-\(dep)-\(item.itemID)",
                                       from: dep, to: item.itemID, kind: .depends))
            }
        }

        // Longest-path depth over the visible DAG (cycle-safe via memo guard).
        var incoming: [String: [String]] = [:]
        for e in edges { incoming[e.to, default: []].append(e.from) }
        var depthMemo: [String: Int] = [:]
        var inProgress = Set<String>()
        func depth(_ id: String) -> Int {
            if let d = depthMemo[id] { return d }
            if inProgress.contains(id) { return 0 }   // break cycles defensively
            inProgress.insert(id)
            var best = 0
            for src in incoming[id] ?? [] { best = max(best, depth(src) + 1) }
            inProgress.remove(id)
            depthMemo[id] = best
            return best
        }

        var nodes = visible.map { GraphNode(id: $0.itemID, item: $0, depth: depth($0.itemID)) }

        // Column buckets; stable ordering within a column for readability.
        var byDepth: [Int: [GraphNode]] = [:]
        for n in nodes { byDepth[n.depth, default: []].append(n) }
        var posByID: [String: CGPoint] = [:]
        var maxRows = 0
        let maxDepth = byDepth.keys.max() ?? 0
        for d in 0...maxDepth {
            let col = (byDepth[d] ?? []).sorted {
                let ai = $0.item, bi = $1.item
                let ae = ai.isEpic ? ai.itemID : ai.parent
                let be = bi.isEpic ? bi.itemID : bi.parent
                if ae != be { return ae.localizedStandardCompare(be) == .orderedAscending }
                return ai.itemID.localizedStandardCompare(bi.itemID) == .orderedAscending
            }
            for (row, n) in col.enumerated() {
                let x = margin + CGFloat(d) * colSpacing + nodeW / 2
                let y = margin + CGFloat(row) * rowSpacing + nodeH / 2
                posByID[n.id] = CGPoint(x: x, y: y)
            }
            maxRows = max(maxRows, col.count)
        }
        for i in nodes.indices { nodes[i].pos = posByID[nodes[i].id] ?? .zero }

        let width = margin * 2 + CGFloat(maxDepth + 1) * colSpacing
        let height = margin * 2 + CGFloat(max(maxRows, 1)) * rowSpacing
        return GraphLayout(nodes: nodes, edges: edges, size: CGSize(width: width, height: height), posByID: posByID)
    }
}

// MARK: - Small badges

struct TypeBadge: View {
    let type: String
    private var color: Color {
        switch type {
        case "epic": return .purple
        case "breakfix": return .red
        case "spike": return .teal
        case "task": return .blue
        default: return .gray   // story
        }
    }
    var body: some View {
        Text(type)
            .font(.system(size: 8, weight: .semibold))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(color.opacity(0.16))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

private struct EffortBadge: View {
    let size: String
    var body: some View {
        Text(size)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(.secondary.opacity(0.15))
            .foregroundStyle(.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .help("Effort: \(size)")
    }
}
