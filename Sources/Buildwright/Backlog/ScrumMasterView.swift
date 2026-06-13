import SwiftUI

/// The SCRUM master chat — lives in the bottom third of the backlog sidebar.
/// Ask about sequencing ("what's safe to work on in parallel?", "can we
/// prioritize E04?") and it answers from the board + build plan, proposing a
/// one-click action when the rules justify one.
struct ScrumMasterView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var master: ScrumMaster
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            inputBar
        }
        .background(.background.secondary)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.badge.shield.checkmark")
                .foregroundStyle(.teal)
            Text("SCRUM MASTER")
                .font(.system(size: 11, weight: .semibold)).kerning(1)
                .foregroundStyle(.secondary)
            Spacer()
            if master.thinking {
                ProgressView().controlSize(.mini)
            } else if !master.messages.isEmpty {
                Button { master.reset() } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Clear the conversation")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if master.messages.isEmpty && master.lastError == nil {
                        emptyHint
                    }
                    ForEach(master.messages) { msg in
                        messageRow(msg).id(msg.id)
                    }
                    if let err = master.lastError {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 10)).foregroundStyle(.orange)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(8)
            }
            .onChange(of: master.messages.count) { _, _ in
                if let last = master.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Ask about sequencing & priorities:")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            ForEach([
                "What can we safely work on in parallel right now?",
                "Can we prioritize E04?",
                "What has to finish before E04?"
            ], id: \.self) { ex in
                Button {
                    app.askScrumMaster(ex)
                } label: {
                    Text("“\(ex)”")
                        .font(.system(size: 10)).foregroundStyle(.teal)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func messageRow(_ msg: SMMessage) -> some View {
        if msg.role == .you {
            HStack {
                Spacer(minLength: 24)
                Text(msg.text)
                    .font(.system(size: 11))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Text(msg.text)
                    .font(.system(size: 11))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                if let action = msg.action {
                    actionButton(action, messageID: msg.id, done: msg.actionDone)
                }
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ action: SMAction, messageID: UUID, done: Bool) -> some View {
        if done {
            Label("Applied", systemImage: "checkmark.circle.fill")
                .font(.system(size: 10)).foregroundStyle(.green)
        } else {
            Button {
                master.applyAction(messageID: messageID)
            } label: {
                Label(actionLabel(action), systemImage: actionIcon(action))
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(action.kind == "queue" ? .orange : .teal)
            .help(action.summary)
        }
    }

    private func actionLabel(_ a: SMAction) -> String {
        switch a.kind {
        case "start": return "Start \(a.item)"
        case "queue": return a.blocker.map { "Queue \(a.item) behind \($0)" } ?? "Queue \(a.item)"
        case "reprioritize": return "Move \(a.item) up the plan"
        default: return a.item
        }
    }

    private func actionIcon(_ a: SMAction) -> String {
        switch a.kind {
        case "start": return "play.fill"
        case "queue": return "clock.badge"
        case "reprioritize": return "arrow.up.to.line"
        default: return "questionmark"
        }
    }

    private var inputBar: some View {
        HStack(spacing: 6) {
            TextField("Ask the SCRUM master…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .lineLimit(1...3)
                .onSubmit(send)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 18))
            }
            .buttonStyle(.borderless)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || master.thinking)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    private func send() {
        let q = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        app.askScrumMaster(q)
        draft = ""
    }
}
