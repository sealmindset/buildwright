import SwiftUI

/// The AI build sequence: ordered epic cards with effort, rationale, and
/// dependency chips. Start buttons go through the normal pane flow — and
/// therefore the safety gate, so starting items top-to-bottom queues them
/// linearly by itself.
struct BacklogPlanView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var planner: BacklogPlanner
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Build Sequence", systemImage: "wand.and.stars")
                    .font(.title3.weight(.semibold))
                if let plan = planner.plan {
                    Text("generated \(ageString(from: plan.generatedAt, to: app.now)) ago")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                switch planner.state {
                case .running(let since):
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("planning… \(ageString(from: since, to: app.now))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .idle, .failed:
                    Button(planner.plan == nil ? "Plan Backlog" : "Re-plan") { planner.runPlan() }
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            if case .failed(let why) = planner.state {
                Label(why, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal).padding(.top, 8)
            }

            if let plan = planner.plan {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(plan.epics.enumerated()), id: \.element.id) { (idx, epic) in
                            PlannedEpicCard(rank: idx + 1, epic: epic)
                        }
                        Text("Sequence: dependencies first, then leverage, effort as tiebreaker — not the priority field. Starting items in order queues them through the safety gate automatically.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                    }
                    .padding()
                }
            } else if case .running = planner.state {
                Spacer()
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Claude is reading the board and design docs…")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 36)).foregroundStyle(.tertiary)
                    Text("No plan yet").font(.title3).foregroundStyle(.secondary)
                    Text("Claude reads your whole board — including design docs — and orders the work by what must come first to build the next thing.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                    Button("Plan Backlog") { planner.runPlan() }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 420, idealHeight: 600)
    }
}

private struct PlannedEpicCard: View {
    @EnvironmentObject var app: AppState
    let rank: Int
    let epic: BacklogPlan.PlannedEpic

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("#\(rank)")
                    .font(.system(.callout, design: .monospaced).weight(.bold))
                    .foregroundStyle(.secondary)
                Text(epic.id).font(.callout.monospaced())
                Text(epic.title).font(.callout.weight(.medium)).lineLimit(1)
                EffortBadge(effort: epic.effort)
                Spacer()
                startButton(itemID: epic.id)
            }
            Text(epic.reason)
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if let deps = epic.dependsOn, !deps.isEmpty {
                    Label(deps.joined(separator: ", "), systemImage: "arrow.turn.down.right")
                        .help("Depends on")
                }
                if let unblocks = epic.unblocks, !unblocks.isEmpty {
                    Label(unblocks.joined(separator: ", "), systemImage: "key")
                        .help("Unblocks")
                }
            }
            .font(.caption2).foregroundStyle(.tertiary)

            ForEach(epic.nextStories ?? []) { story in
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Text(story.id).font(.caption.monospaced())
                    Text(story.title).font(.caption).lineLimit(1)
                    EffortBadge(effort: story.effort)
                    Text("— \(story.reason)")
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    Spacer()
                    startButton(itemID: story.id)
                }
                .padding(.leading, 18)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
    }

    @ViewBuilder
    private func startButton(itemID: String) -> some View {
        if let item = app.backlogItem(byID: itemID) {
            Button {
                app.startBacklogItem(item)
            } label: {
                Image(systemName: "play.fill").font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Start in a Claude pane (queues behind working panes automatically)")
        }
    }
}

private struct EffortBadge: View {
    let effort: String

    private var color: Color {
        switch effort.uppercased() {
        case "S": return .green
        case "M": return .orange
        default: return .red
        }
    }

    var body: some View {
        Text(effort.uppercased())
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
            .help("Estimated effort: S ≤ half day · M 1–3 days · L ≥ a week")
    }
}
