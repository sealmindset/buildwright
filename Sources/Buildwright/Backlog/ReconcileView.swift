import SwiftUI

/// The reconciliation cockpit: audit the board against the real code, then
/// triage. High-confidence reversible findings are auto-applied (shown with
/// Undo); everything else is flagged for Accept/Reject. A Dispatch control
/// arms the engine to start the next parallel-safe gap.
struct ReconcileView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var reconciler: Reconciler
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            repoBar
            dispatchBar
            Divider()
            content
            footer
        }
        .padding(16)
        .frame(width: 620, height: 580)
    }

    private var repoBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Text("Target repo")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            TextField("~/Documents/GitHub/docai", text: Binding(
                get: { app.docaiPath },
                set: { app.docaiPath = $0; app.persist() }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11, design: .monospaced))
            .help("The codebase the audit runs against (cwd of the grounded claude run)")
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "checklist.checked")
                .foregroundStyle(.teal)
            Text("Reconcile Board ↔ Code").font(.title3).bold()
            Spacer()
            if let report = reconciler.report {
                Text("last run \(ageString(from: report.generatedAt, to: app.now)) ago")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button {
                reconciler.runReconcile()
            } label: {
                if case .running = reconciler.state {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("auditing…")
                    }
                } else {
                    Label("Reconcile Now", systemImage: "arrow.clockwise")
                }
            }
            .disabled({ if case .running = reconciler.state { return true } else { return false } }())
        }
    }

    private var dispatchBar: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { reconciler.armed },
                set: { app.setReconcileArmed($0) }
            )) {
                Label("Dispatch armed", systemImage: "bolt.fill")
                    .font(.system(size: 11, weight: .medium))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("When armed, a reconcile run starts the next parallel-safe gap")

            Spacer()

            if let id = reconciler.dispatched {
                HStack(spacing: 6) {
                    Text("next gap: \(id)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Button {
                        reconciler.dispatch()
                    } label: {
                        Label("Start", systemImage: "play.fill")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small).tint(.teal)
                }
            } else {
                Text("no safe gap right now")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var content: some View {
        if case .failed(let why) = reconciler.state {
            Label(why, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
        let auto = reconciler.autoAppliedVerdicts
        let flagged = reconciler.flaggedVerdicts
        if auto.isEmpty && flagged.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 32)).foregroundStyle(.green.opacity(0.6))
                Text(reconciler.report == nil
                     ? "No reconcile run yet — click Reconcile Now to audit the board against \(URL(fileURLWithPath: app.docaiPath).lastPathComponent)."
                     : "Board matches the code — nothing to triage.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !auto.isEmpty {
                        sectionLabel("Auto-applied (\(auto.count)) — high confidence, reversible")
                        ForEach(auto) { v in autoCard(v) }
                    }
                    if !flagged.isEmpty {
                        sectionLabel("Flagged (\(flagged.count)) — your call")
                        ForEach(flagged) { v in flaggedCard(v) }
                    }
                }
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold)).kerning(0.5)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }

    /// A flagged verdict the user can accept/reject.
    private func flaggedCard(_ v: ReconcileVerdict) -> some View {
        cardShell(v) {
            HStack(spacing: 6) {
                Button("Accept") { app.acceptReconcile(v) }
                    .controlSize(.small)
                    .help(actionDescription(v))
                Button("Reject") { app.rejectReconcile(v) }
                    .controlSize(.small)
                    .help("Hide this finding — it stays hidden in future runs")
            }
        }
    }

    /// An auto-applied verdict, shown read-only with Undo.
    private func autoCard(_ v: ReconcileVerdict) -> some View {
        cardShell(v) {
            if let app0 = reconciler.report?.applied?.first(where: { $0.item == v.item }) {
                Button {
                    app.undoReconcile(app0)
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 10))
                }
                .controlSize(.small)
                .help("Restore \(v.item) to \(app0.priorStatus)")
            }
        }
    }

    @ViewBuilder
    private func cardShell<Controls: View>(_ v: ReconcileVerdict,
                                           @ViewBuilder controls: () -> Controls) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(v.verdictLabel)
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(verdictColor(v.verdict).opacity(0.18))
                    .foregroundStyle(verdictColor(v.verdict))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                Text(v.item)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                if let title = app.backlogItem(byID: v.item)?.title {
                    Text(title).font(.system(size: 11))
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                Text(String(format: "%.0f%%", v.confidence * 100))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                controls()
            }
            Text(v.proposed_action.why)
                .font(.system(size: 11)).foregroundStyle(.secondary)
            evidenceLine("code", v.evidence.code)
            evidenceLine("tests", v.evidence.tests)
            evidenceLine("live", v.evidence.live)
            if let gaps = v.gaps, !gaps.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(gaps, id: \.self) { g in
                        Text("gap: \(g)")
                            .font(.system(size: 10)).foregroundStyle(.orange.opacity(0.9))
                    }
                }
            }
            Text(actionDescription(v))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func evidenceLine(_ label: String, _ refs: [String]?) -> some View {
        if let refs, !refs.isEmpty {
            Text("\(label): \(refs.prefix(3).joined(separator: ", "))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func actionDescription(_ v: ReconcileVerdict) -> String {
        switch v.proposed_action.kind {
        case "mark_done": return "Mark \(v.item) done"
        case "close_dup": return "Close \(v.item) as a duplicate of \(v.proposed_action.dup_of ?? "?")"
        case "restatus": return "Re-status \(v.item) to \(v.proposed_action.to_status ?? "?")"
        case "split": return "Split \(v.item) (manual — review before applying)"
        default: return "No change"
        }
    }

    private func verdictColor(_ verdict: String) -> Color {
        switch verdict {
        case "built": return .green
        case "partial": return .orange
        case "not-built": return .red
        default: return .gray
        }
    }

    private var footer: some View {
        HStack {
            Text("BUILT needs code + tests + live. Only high-confidence reversible findings auto-apply; the rest wait for you. Nothing is destroyed — every change has Undo.")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }
}
