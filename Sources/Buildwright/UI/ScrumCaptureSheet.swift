import SwiftUI

/// AI Scrum Master intake (⌘⇧N): drop a raw thought, hit return, and the
/// headless triage engine types it, sizes it, and files it under the right
/// epic — minting a new one when nothing fits. The headline UX: fast in,
/// one decision made for you, an Undo if it guessed wrong.
struct ScrumCaptureSheet: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var intake: CaptureIntake
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var keepOpen = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(size: 13))
                    .frame(minHeight: 120, maxHeight: 220)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                    .focused($focused)
                    .disabled(isBusy)
                    .onKeyPress(.return, phases: .down) { press in
                        // ⏎ files; ⇧⏎ / ⌥⏎ keep adding newlines.
                        guard !press.modifiers.contains(.shift),
                              !press.modifiers.contains(.option) else { return .ignored }
                        submit(keepOpen: false)
                        return .handled
                    }
                if text.isEmpty {
                    Text("What's on your mind? A bug, an idea, a follow-up…")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 14).padding(.leading, 12)
                        .allowsHitTesting(false)
                }
            }

            statusLine

            footer
        }
        .padding(16)
        .frame(width: 480)
        .onAppear { focused = true }
        .onChange(of: filedID) { _, id in
            // A successful file with keep-open: clear the field, stay ready.
            if id != nil && keepOpen { text = "" }
            else if id != nil { /* leave the result visible until dismissed */ }
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(.tint)
            Text("Capture to backlog")
                .font(.title3.weight(.semibold))
            Spacer()
            Text("AI picks type · size · home")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch intake.phase {
        case .thinking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Triaging against the board…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .filed(let result):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Filed ")
                    .font(.system(size: 13)) +
                Text("\(result.itemID)").font(.system(size: 13, weight: .semibold)) +
                Text(" (\(result.type), \(result.size)) under \(result.homeTitle)")
                    .font(.system(size: 13))
                Spacer()
                Button("Undo") { intake.undo() }
                    .controlSize(.small)
            }
            .padding(8)
            .background(.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        case .failed(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            .padding(8)
            .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        case .idle:
            EmptyView()
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle("Keep open after filing", isOn: $keepOpen)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .disabled(isBusy)
            Spacer()
            Button("Done") {
                intake.dismiss()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button("Capture & keep open") { submit(keepOpen: true) }
                .disabled(!canSubmit)
            Button("Capture") { submit(keepOpen: false) }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
        }
    }

    // MARK: Behavior

    private var isBusy: Bool { intake.isThinking }
    private var canSubmit: Bool {
        !isBusy && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var filedID: String? {
        if case .filed(let r) = intake.phase { return r.itemID }
        return nil
    }

    private func submit(keepOpen wantKeepOpen: Bool) {
        guard canSubmit else { return }
        keepOpen = wantKeepOpen || keepOpen
        intake.capture(text)
        if !keepOpen {
            // The field stays; the result toast appears in-line. Field is
            // cleared on success only when keep-open is set (see onChange).
        }
    }
}
