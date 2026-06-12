import SwiftUI

// MARK: - Status styling

extension BacklogItem {
    var statusColor: Color {
        switch status {
        case "in-progress": return .blue
        case "ready": return .green
        case "blocked": return .red
        case "designing": return .purple
        case "done", "closed": return .secondary.opacity(0.5)
        default: return .orange // backlog
        }
    }
}

struct PriorityBadge: View {
    let priority: String
    var body: some View {
        if !priority.isEmpty {
            Text(priority)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background((priority == "P1" ? Color.red : priority == "P2" ? Color.orange : Color.gray).opacity(0.18))
                .foregroundStyle(priority == "P1" ? Color.red : priority == "P2" ? Color.orange : Color.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }
}

struct StatusDot: View {
    let item: BacklogItem
    var body: some View {
        Circle().fill(item.statusColor).frame(width: 7, height: 7)
            .help(item.status)
    }
}

// MARK: - Sidebar

struct BacklogSidebarView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var store: BacklogStore
    @State private var expandedEpics: Set<String> = []
    @State private var detailItem: BacklogItem?
    @State private var detailEpicGroup: BacklogEpic?
    @State private var showNewEpic = false

    var filters: BacklogFilters { app.activeFilters }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            Divider()
            list
        }
        .frame(minWidth: 230)
        .background(.background.secondary)
        .sheet(item: $detailItem) { item in
            BacklogDetailView(store: store, item: item, epicGroup: detailEpicGroup)
                .environmentObject(app)
        }
        .sheet(isPresented: $showNewEpic) {
            NewEpicSheet(store: store)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "list.bullet.rectangle")
                .foregroundStyle(.secondary)
            Text("BACKLOG")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .kerning(1)
            Spacer()
            Button { app.showPlanSheet = true } label: {
                Image(systemName: "wand.and.stars")
            }
            .buttonStyle(.borderless)
            .help("AI build sequence — what to work on first and why (⇧⌘P)")
            Button { showNewEpic = true } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New epic")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private var filterBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
                TextField("Search…", text: Binding(
                    get: { filters.searchText },
                    set: { v in app.updateFilters { $0.searchText = v } }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 11))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 6) {
                filterMenu(title: "Status", options: BacklogItem.allStatuses,
                           selection: filters.statuses) { v in
                    app.updateFilters { f in toggle(&f.statuses, v) }
                }
                filterMenu(title: "Category", options: store.allCategories,
                           selection: filters.categories) { v in
                    app.updateFilters { f in toggle(&f.categories, v) }
                }
                filterMenu(title: "Priority", options: store.allPriorities,
                           selection: filters.priorities) { v in
                    app.updateFilters { f in toggle(&f.priorities, v) }
                }
                Spacer()
                Toggle(isOn: Binding(
                    get: { filters.showDone },
                    set: { v in app.updateFilters { $0.showDone = v } }
                )) {
                    Text("done").font(.system(size: 10))
                }
                .toggleStyle(.checkbox)
                .help("Show closed epics")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func toggle(_ set: inout Set<String>, _ value: String) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
    }

    private func filterMenu(title: String, options: [String], selection: Set<String>,
                            action: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    action(option)
                } label: {
                    HStack {
                        if selection.contains(option) { Image(systemName: "checkmark") }
                        Text(option)
                    }
                }
            }
        } label: {
            HStack(spacing: 2) {
                Text(title).font(.system(size: 10))
                if !selection.isEmpty {
                    Text("\(selection.count)")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 3)
                        .background(Color.accentColor.opacity(0.25))
                        .clipShape(Capsule())
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(store.filteredEpics(filters)) { group in
                    epicRow(group)
                    if expandedEpics.contains(group.id) {
                        ForEach(group.filteredStories(filters)) { story in
                            storyRow(story, group: group)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func epicRow(_ group: BacklogEpic) -> some View {
        HStack(spacing: 6) {
            Button {
                if expandedEpics.contains(group.id) { expandedEpics.remove(group.id) }
                else { expandedEpics.insert(group.id) }
            } label: {
                Image(systemName: expandedEpics.contains(group.id) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
            }
            .buttonStyle(.plain)

            StatusDot(item: group.epic)
            Text(group.epic.itemID)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(group.epic.isDone ? .secondary : .primary)
            Text(group.epic.title)
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(group.epic.isDone ? .secondary : .primary)
            Spacer(minLength: 4)
            PriorityBadge(priority: group.epic.priority)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { detailEpicGroup = group; detailItem = group.epic }
        .contextMenu { itemMenu(group.epic, group: group) }
        .help(group.epic.title)
    }

    private func storyRow(_ story: BacklogItem, group: BacklogEpic) -> some View {
        HStack(spacing: 6) {
            Spacer().frame(width: 16)
            StatusDot(item: story)
            Text(storyLabel(story))
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(story.isDone ? .secondary : .primary)
            Text(story.title)
                .font(.system(size: 10.5))
                .lineLimit(1)
                .foregroundStyle(story.isDone ? .secondary : .primary)
            Spacer(minLength: 4)
            if !story.isDone {
                Button {
                    app.startBacklogItem(story)
                } label: {
                    Image(systemName: "play.fill").font(.system(size: 8))
                }
                .buttonStyle(.borderless)
                .help("Start in a new Claude pane")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { detailEpicGroup = group; detailItem = story }
        .contextMenu { itemMenu(story, group: group) }
        .help(story.title)
    }

    private func storyLabel(_ story: BacklogItem) -> String {
        if let range = story.itemID.range(of: "-") {
            return String(story.itemID[range.upperBound...])
        }
        return story.itemID
    }

    @ViewBuilder
    private func itemMenu(_ item: BacklogItem, group: BacklogEpic) -> some View {
        if !item.isEpic && !item.isDone {
            Button("Start in Claude pane") { app.startBacklogItem(item) }
            Divider()
        }
        Button("Details…") { detailEpicGroup = group; detailItem = item }
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
        if item.isEpic {
            Button("New story…") { detailEpicGroup = group; detailItem = item }
        }
    }
}

// MARK: - Detail / edit sheet

struct BacklogDetailView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var store: BacklogStore
    @Environment(\.dismiss) private var dismiss

    let item: BacklogItem
    let epicGroup: BacklogEpic?

    @State private var editedTitle: String = ""
    @State private var editedPriority: String = ""
    @State private var editedBody: String = ""
    @State private var editedStatus: String = ""
    @State private var showNewStory = false
    @State private var designText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                StatusDot(item: item)
                Text(item.itemID).font(.system(.title3, design: .monospaced)).bold()
                PriorityBadge(priority: editedPriority)
                Spacer()
                if !item.isEpic && !item.isDone {
                    Button {
                        app.startBacklogItem(item)
                        dismiss()
                    } label: {
                        Label("Start in Claude pane", systemImage: "play.fill")
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }

            TextField("Title", text: $editedTitle)
                .font(.title3)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 12) {
                Picker("Status", selection: $editedStatus) {
                    ForEach(BacklogItem.allStatuses, id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
                Picker("Priority", selection: $editedPriority) {
                    Text("—").tag("")
                    ForEach(["P1", "P2", "P3"], id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
                if !item.category.isEmpty {
                    Label(item.category, systemImage: "tag")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if item.isEpic {
                    Button("New story…") { showNewStory = true }
                }
            }

            TextEditor(text: $editedBody)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            if let designText {
                DisclosureGroup("design.md") {
                    ScrollView {
                        Text(designText)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 200)
                }
            }

            HStack {
                Text(item.fileURL.path)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.head)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    if editedStatus != item.status {
                        store.setStatus(item, to: editedStatus)
                    }
                    store.updateTitleAndBody(item, title: editedTitle, priority: editedPriority, body: editedBody)
                    dismiss()
                }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 640, height: 560)
        .onAppear {
            editedTitle = item.title
            editedPriority = item.priority
            editedBody = item.body
            editedStatus = item.status
            if let designURL = item.designURL {
                designText = try? String(contentsOf: designURL, encoding: .utf8)
            }
        }
        .sheet(isPresented: $showNewStory) {
            if let epicGroup {
                NewStorySheet(store: store, group: epicGroup)
            }
        }
    }
}

// MARK: - Create sheets

struct NewEpicSheet: View {
    @ObservedObject var store: BacklogStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var category = ""
    @State private var priority = "P2"
    @State private var body_ = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Epic").font(.title3).bold()
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            HStack {
                TextField("Category (e.g. docai-agents)", text: $category).textFieldStyle(.roundedBorder)
                Picker("Priority", selection: $priority) {
                    ForEach(["P1", "P2", "P3"], id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
            }
            TextEditor(text: $body_)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    store.createEpic(title: title, category: category, priority: priority, body: body_)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

struct NewStorySheet: View {
    @ObservedObject var store: BacklogStore
    let group: BacklogEpic
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var body_ = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Story in \(group.epic.itemID)").font(.title3).bold()
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            TextEditor(text: $body_)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    store.createStory(in: group, title: title, body: body_)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
