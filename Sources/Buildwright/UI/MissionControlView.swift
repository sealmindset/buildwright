import SwiftUI

/// Single pane of glass: every terminal pane in every workspace as a card —
/// status, how long it's been waiting, what it needs (from the transcript),
/// or its last line of output. Click any card to jump there.
struct MissionControlView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 280, maximum: 380), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Mission Control", systemImage: "rectangle.grid.2x2")
                    .font(.title3.weight(.semibold))
                Spacer()
                summary
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(app.missionControlGroups, id: \.workspaceName) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.workspaceName)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                                ForEach(group.entries) { entry in
                                    MissionControlCard(entry: entry, now: app.now)
                                        .onTapGesture {
                                            app.jump(workspaceID: entry.workspaceID,
                                                     tabID: entry.tabID,
                                                     paneID: entry.pane.id)
                                            dismiss()
                                        }
                                }
                            }
                        }
                    }
                    if app.missionControlGroups.isEmpty {
                        Text("No terminal panes yet — open a Claude or shell pane.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 700, idealWidth: 920, minHeight: 420, idealHeight: 620)
    }

    private var summary: some View {
        HStack(spacing: 12) {
            if app.workingCount > 0 {
                Text("● \(app.workingCount) working").foregroundStyle(.blue)
            }
            if app.needsInputCount > 0 {
                Text("◉ \(app.needsInputCount) need you").foregroundStyle(.orange)
            }
            if app.doneCount > 0 {
                Text("✓ \(app.doneCount) done").foregroundStyle(.green)
            }
        }
        .font(.callout.monospaced())
        .padding(.trailing, 8)
    }
}

struct MissionControlCard: View {
    @EnvironmentObject var app: AppState
    let entry: AppState.OverviewEntry
    let now: Date

    private var state: ClaudeStatus { entry.status?.state ?? .none }

    private var stateColor: Color {
        switch state {
        case .working: return .blue
        case .needsInput: return .orange
        case .done: return .green
        case .none: return .secondary.opacity(0.5)
        }
    }

    private var stateLine: String {
        if entry.pane.isQueued { return "on deck" }
        guard let status = entry.status else {
            return entry.pane.kind == .shell ? "shell" : "no signal"
        }
        let age = ageString(from: status.since, to: now)
        let tok = status.contextTokens.map { " · \(tokenString($0))" } ?? ""
        switch status.state {
        case .working: return "working · \(age)\(tok)"
        case .needsInput: return "needs you · \(age)\(tok)"
        case .done: return "done · \(age)\(tok)"
        case .none: return "idle"
        }
    }

    /// What to show in the card body: the teed-up prompt for on-deck panes,
    /// the transcript/notification detail when we have one, else the pane's
    /// last visible terminal line.
    private var bodyText: String? {
        if entry.pane.isQueued {
            return entry.pane.queuedPrompt.map { TranscriptReader.condense($0, limit: 160) } ?? "waiting for its gate pane"
        }
        if let detail = entry.status?.detail, !detail.isEmpty { return detail }
        return TerminalViewCache.shared.lastVisibleLine(for: entry.pane.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(stateColor).frame(width: 9, height: 9)
                Image(systemName: entry.pane.kind == .claude ? "sparkle" : "terminal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(entry.pane.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text(stateLine)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(state == .needsInput ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                Button {
                    app.requestClosePane(entry.pane.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Close this pane (kills its tmux window) — retire finished work without leaving mission control")
            }
            if let text = bodyText {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            } else {
                Text(" ").font(.caption).lineLimit(3, reservesSpace: true)
            }
            Text("\(entry.tabName) · \(abbreviate(entry.pane.directory))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(state == .needsInput ? Color.orange.opacity(0.6) : Color.secondary.opacity(0.2))
                )
        )
        .contentShape(Rectangle())
    }

    private func abbreviate(_ path: String) -> String {
        let home = Config.home.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
