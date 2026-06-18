import SwiftUI

// MARK: - Finish Line dashboard
//
// A live, dynamic burn-down of the whole board for the final push to
// production. Same tiering logic as the FINISH-LINE.md plan, but computed
// from BacklogStore in real time so it's never stale: Next 3 (the advice),
// then Blockers / In flight / Polish / Later, plus the daily inflow. The
// operator works whatever they judge important; the tiers + Next 3 keep the
// recommendation in view. Reuses the same interactions as the rest of the
// backlog UI (click → edit, ▶ → start a Claude pane, right-click → status).

private enum FinishScope: String, CaseIterable, Identifiable {
    case product = "Product"
    case cockpit = "Cockpit"
    case all = "All"
    var id: String { rawValue }
}

private enum Tier: String, CaseIterable, Identifiable {
    case blocker, inflight, polish, later
    var id: String { rawValue }
    var title: String {
        switch self {
        case .blocker: return "Blockers — P1"
        case .inflight: return "In flight — finish or park"
        case .polish: return "Polish — P2"
        case .later: return "Later — P3 / unprioritized"
        }
    }
    var subtitle: String {
        switch self {
        case .blocker: return "Clear these to call it production-ready. Epics are themes already moving; the bugs & ready stories are the real work."
        case .inflight: return "Already started. Finish it or consciously park it — half-done work is what eats your nights."
        case .polish: return "Real, not bleeding. Burn these by area in focused sessions, one epic at a time."
        case .later: return "Parked guilt-free. Pull up only when the rest is clear."
        }
    }
    var icon: String {
        switch self {
        case .blocker: return "exclamationmark.octagon.fill"
        case .inflight: return "bolt.fill"
        case .polish: return "paintbrush.fill"
        case .later: return "tray.full"
        }
    }
    var color: Color {
        switch self {
        case .blocker: return .red
        case .inflight: return .yellow
        case .polish: return .blue
        case .later: return .secondary
        }
    }
}

struct BacklogFinishLineView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var store: BacklogStore
    @Environment(\.dismiss) private var dismiss

    @State private var scope: FinishScope = .product
    @State private var search = ""
    @State private var brianOnly = false
    @State private var detailItem: BacklogItem?
    @State private var collapsed: Set<String> = [Tier.later.rawValue]
    @State private var exportNote = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    nextThree
                    ForEach(Tier.allCases) { tier in
                        tierSection(tier)
                    }
                    inflow
                }
                .padding(16)
            }
        }
        .frame(minWidth: 780, idealWidth: 1000, minHeight: 600, idealHeight: 860)
        .sheet(item: $detailItem) { item in
            BacklogDetailView(store: store, item: item, epicGroup: group(for: item))
                .environmentObject(app)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "flag.checkered").foregroundStyle(.green)
            Text("Finish Line").font(.headline)
            Text("\(base.count) open").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                chip(tierItems(.blocker).count, "blockers", .red)
                chip(tierItems(.inflight).count, "in flight", .yellow)
                chip(brianCount, "Brian", .orange)
            }
            Spacer()
            if !exportNote.isEmpty {
                Text(exportNote).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Button {
                exportNote = exportMarkdown() ? "saved FINISH-LINE.md" : "export failed"
            } label: { Label("Export .md", systemImage: "square.and.arrow.up") }
                .controlSize(.small)
                .help("Write a shareable FINISH-LINE.md snapshot to the backlog folder")
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("", selection: $scope) {
                ForEach(FinishScope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).fixedSize()
            .help("Product = the legal app you're shipping · Cockpit = Buildwright itself")

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
                TextField("Search…", text: $search)
                    .textFieldStyle(.plain).font(.system(size: 11)).frame(width: 160)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.quaternary.opacity(0.5)).clipShape(RoundedRectangle(cornerRadius: 6))

            Toggle(isOn: $brianOnly) {
                Label("Brian only", systemImage: "person.fill").font(.system(size: 10))
            }
            .toggleStyle(.button).controlSize(.small)
            .help("Only items Brian flagged")

            Spacer()
            Text("click → edit · ▶ start · right-click → status")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    // MARK: Next 3

    private var nextThree: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.right.circle.fill").foregroundStyle(.green)
                Text("Next 3 — my recommendation").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("you can work anything below; this is just where I'd start")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            let picks = recommended
            if picks.isEmpty {
                Text("Nothing actionable in this scope — clear filters or switch scope.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ForEach(Array(picks.enumerated()), id: \.element.itemID) { idx, item in
                    HStack(spacing: 8) {
                        Text("\(idx + 1)")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.green.opacity(0.18)))
                            .foregroundStyle(.green)
                        itemRow(item, compact: true)
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.green.opacity(0.25)))
    }

    // MARK: Tier section

    @ViewBuilder
    private func tierSection(_ tier: Tier) -> some View {
        let items = tierItems(tier)
        let isCollapsed = collapsed.contains(tier.rawValue)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if isCollapsed { collapsed.remove(tier.rawValue) } else { collapsed.insert(tier.rawValue) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).frame(width: 10)
                    Image(systemName: tier.icon).foregroundStyle(tier.color)
                    Text(tier.title).font(.system(size: 13, weight: .semibold))
                    Text("\(items.count)")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(tier.color.opacity(0.15)).foregroundStyle(tier.color)
                        .clipShape(Capsule())
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !isCollapsed {
                Text(tier.subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .padding(.leading, 20).padding(.bottom, 2)
                if items.isEmpty {
                    Text("— none —").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.leading, 20)
                } else {
                    VStack(spacing: 4) {
                        ForEach(items, id: \.itemID) { itemRow($0) }
                    }
                }
            }
        }
    }

    // MARK: Item row

    @ViewBuilder
    private func itemRow(_ item: BacklogItem, compact: Bool = false) -> some View {
        let started = !item.isEpic && !item.isDone
        HStack(spacing: 8) {
            StatusDot(item: item)
            Text(item.itemID)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .frame(width: 92, alignment: .leading)
            if brian(item) {
                Image(systemName: "person.fill").font(.system(size: 8)).foregroundStyle(.orange)
                    .help("Brian flagged this")
            }
            Text(item.title).font(.system(size: 11)).lineLimit(1)
            Spacer(minLength: 6)
            if scope == .all {
                Text(isCockpit(item) ? "cockpit" : "product")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            TypeBadge(type: item.type)
            if !item.size.isEmpty { SizeBadge(size: item.size) }
            PriorityBadge(priority: item.priority)
            Text(ageLabel(item))
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                .frame(width: 38, alignment: .trailing)
                .help("Logged \(ageLabel(item)) ago")
            if !compact && item.status == "in-progress" {
                Button("Park") { store.setStatus(item, to: "backlog") }
                    .buttonStyle(.borderless).font(.system(size: 9)).foregroundStyle(.orange)
                    .help("Move out of in-progress so your 'started' count drops")
            }
            if started {
                Button { app.startBacklogItem(item) } label: {
                    Image(systemName: "play.fill").font(.system(size: 9))
                }
                .buttonStyle(.borderless).foregroundStyle(.green)
                .help("Start in a Claude pane")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor).opacity(compact ? 0 : 0.6)))
        .opacity(item.isDone ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture { detailItem = item }
        .contextMenu { rowMenu(item, started: started) }
        .help(item.title)
    }

    @ViewBuilder
    private func rowMenu(_ item: BacklogItem, started: Bool) -> some View {
        if started { Button("Start in Claude pane") { app.startBacklogItem(item) }; Divider() }
        Button("Details…") { detailItem = item }
        Menu("Set status") {
            ForEach(BacklogItem.allStatuses, id: \.self) { s in
                Button { store.setStatus(item, to: s) } label: {
                    HStack { if item.status == s { Image(systemName: "checkmark") }; Text(s) }
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

    // MARK: Inflow

    private var inflow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.down.fill").foregroundStyle(.purple)
                Text("Inflow — what landed when").font(.system(size: 13, weight: .semibold))
            }
            let byDay = Dictionary(grouping: base, by: { $0.created.isEmpty ? "—" : $0.created })
            ForEach(byDay.keys.sorted(by: >).prefix(8), id: \.self) { day in
                let rows = byDay[day] ?? []
                HStack(alignment: .top, spacing: 8) {
                    Text(dayLabel(day)).font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .frame(width: 76, alignment: .leading).foregroundStyle(.secondary)
                    Text("\(rows.count)").font(.system(size: 10, weight: .bold))
                        .frame(width: 22, alignment: .trailing)
                    Text(rows.map { $0.itemID }.joined(separator: "  "))
                        .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.05)))
    }

    // MARK: - Data

    private var allItems: [BacklogItem] { store.epics.flatMap { [$0.epic] + $0.stories } }

    /// Open items in the current scope, after search + Brian filters.
    private var base: [BacklogItem] {
        allItems.filter { item in
            if item.isDone { return false }
            switch scope {
            case .product: if isCockpit(item) { return false }
            case .cockpit: if !isCockpit(item) { return false }
            case .all: break
            }
            if brianOnly && !brian(item) { return false }
            if !search.isEmpty {
                let q = search.lowercased()
                if !item.itemID.lowercased().contains(q) && !item.title.lowercased().contains(q) { return false }
            }
            return true
        }
    }

    private func classify(_ item: BacklogItem) -> Tier {
        if priority(item) == "P1" { return .blocker }
        if item.status == "in-progress" { return .inflight }
        if priority(item) == "P2" { return .polish }
        return .later
    }

    private func tierItems(_ tier: Tier) -> [BacklogItem] {
        base.filter { classify($0) == tier }.sorted { a, b in
            if priority(a) != priority(b) { return priority(a) < priority(b) }
            return (ageDays(a) ?? -1) > (ageDays(b) ?? -1)   // oldest first — surface what's rotting
        }
    }

    /// My advice: today's P1 bugs and ready P1 stories first, then P1 work in
    /// progress to finish. Epics are themes, not single sittings — excluded.
    private var recommended: [BacklogItem] {
        base.filter { !$0.isEpic && priority($0) == "P1" }
            .sorted { a, b in
                let ra = recScore(a), rb = recScore(b)
                if ra != rb { return ra < rb }
                return (ageDays(a) ?? 0) < (ageDays(b) ?? 0)   // freshest bug first
            }
            .prefix(3).map { $0 }
    }

    private func recScore(_ item: BacklogItem) -> Int {
        let typeRank = item.type == "breakfix" ? 0 : 1
        let statusRank: Int
        switch item.status {
        case "ready": statusRank = 0
        case "backlog": statusRank = 1
        case "in-progress": statusRank = 2
        default: statusRank = 3
        }
        return typeRank * 10 + statusRank
    }

    private func group(for item: BacklogItem) -> BacklogEpic? {
        store.epics.first { $0.epic.itemID == item.itemID || $0.epic.itemID == item.parent }
    }

    // MARK: Derivations

    private func priority(_ item: BacklogItem) -> String {
        if !item.priority.isEmpty { return item.priority }
        // inherit the epic's priority so stories sort under their parent
        if let ep = allItems.first(where: { $0.itemID == item.parent }), !ep.priority.isEmpty { return ep.priority }
        return "P9"
    }

    private func brian(_ item: BacklogItem) -> Bool {
        (item.body + item.category + item.title).lowercased().contains("brian")
    }

    private func isCockpit(_ item: BacklogItem) -> Bool {
        let epicTitle = allItems.first(where: { $0.itemID == (item.isEpic ? item.itemID : item.parent) })?.title ?? ""
        return (item.category + epicTitle + item.title).lowercased().contains("buildwright")
    }

    private func ageDays(_ item: BacklogItem) -> Int? {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        guard let d = fmt.date(from: item.created.trimmingCharacters(in: .whitespaces)) else { return nil }
        return Calendar.current.dateComponents([.day], from: d, to: Date()).day
    }

    private func ageLabel(_ item: BacklogItem) -> String {
        guard let d = ageDays(item) else { return "—" }
        return d == 0 ? "today" : "\(d)d"
    }

    private func dayLabel(_ day: String) -> String {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        guard let d = fmt.date(from: day) else { return day }
        let days = Calendar.current.dateComponents([.day], from: d, to: Date()).day ?? 0
        if days == 0 { return "today" }
        if days == 1 { return "yesterday" }
        return day
    }

    private var brianCount: Int { base.filter(brian).count }

    @ViewBuilder
    private func chip(_ n: Int, _ label: String, _ color: Color) -> some View {
        if n > 0 {
            Text("\(n) \(label)").font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(color.opacity(0.15)).foregroundStyle(color).clipShape(Capsule())
        }
    }

    // MARK: Export

    private func exportMarkdown() -> Bool {
        var out = "# 🏁 Finish Line — \(scope.rawValue)\n"
        out += "> Generated \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)) · \(base.count) open\n\n"
        out += "## ▶ Next 3\n"
        for (i, it) in recommended.enumerated() {
            out += "\(i + 1). `\(it.itemID)` — \(it.title) · \(it.priority) · \(it.status)\n"
        }
        for tier in Tier.allCases {
            let rows = tierItems(tier)
            out += "\n## \(tier.title) (\(rows.count))\n"
            for it in rows {
                let b = brian(it) ? " · Brian" : ""
                out += "- `\(it.itemID)` [\(it.status)] \(it.priority) \(it.size) — \(it.title)\(b)\n"
            }
        }
        let url = Config.backlogDirectory.appendingPathComponent("FINISH-LINE.md")
        do { try out.write(to: url, atomically: true, encoding: .utf8); return true } catch { return false }
    }
}

private struct SizeBadge: View {
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
