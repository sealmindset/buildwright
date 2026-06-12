import SwiftUI

/// Grooming triage: every AI finding is a card with the exact action Accept
/// would take. Nothing applies without a click; Reject hides the finding
/// across future grooming runs.
struct BacklogGroomView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var groomer: BacklogGroomer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
            footer
        }
        .padding(16)
        .frame(width: 560, height: 480)
    }

    private var header: some View {
        HStack {
            Image(systemName: "stethoscope")
                .foregroundStyle(.teal)
            Text("Board Grooming").font(.title3).bold()
            Spacer()
            if let report = groomer.report {
                Text("last run \(ageString(from: report.generatedAt, to: app.now)) ago")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button {
                groomer.runGroom()
            } label: {
                if case .running = groomer.state {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("grooming…")
                    }
                } else {
                    Label("Groom Now", systemImage: "arrow.clockwise")
                }
            }
            .disabled({ if case .running = groomer.state { return true } else { return false } }())
        }
    }

    @ViewBuilder
    private var content: some View {
        if case .failed(let why) = groomer.state {
            Label(why, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
        let open = groomer.openSuggestions
        if open.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 32)).foregroundStyle(.green.opacity(0.6))
                Text(groomer.report == nil
                     ? "No grooming run yet — runs weekly, or click Groom Now."
                     : "Nothing to triage — the board is clean.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(open) { s in
                        suggestionCard(s)
                    }
                }
            }
        }
    }

    private func suggestionCard(_ s: GroomSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(s.kindLabel)
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(kindColor(s.kind).opacity(0.18))
                    .foregroundStyle(kindColor(s.kind))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                Text(s.item)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                if let title = app.backlogItem(byID: s.item)?.title {
                    Text(title).font(.system(size: 11))
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Accept") { app.applyGroomSuggestion(s) }
                    .controlSize(.small)
                    .help(s.acceptDescription)
                Button("Reject") { groomer.reject(s) }
                    .controlSize(.small)
                    .help("Hide this finding — it stays hidden in future runs")
            }
            Text(s.note)
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let criteria = s.criteria, !criteria.isEmpty {
                detailLines(criteria, prefix: "☐")
            }
            if let split = s.split, !split.isEmpty {
                detailLines(split, prefix: "→")
            }
            Text(s.acceptDescription)
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func detailLines(_ lines: [String], prefix: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(lines, id: \.self) { line in
                Text("\(prefix) \(line)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 4)
    }

    private func kindColor(_ kind: String) -> Color {
        switch kind {
        case "duplicate": return .red
        case "stale": return .orange
        case "acceptance": return .blue
        case "oversize": return .purple
        case "assign": return .teal
        default: return .gray
        }
    }

    private var footer: some View {
        HStack {
            Text("Accept applies the change (with a history line on the item). The board is never changed automatically.")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }
}
