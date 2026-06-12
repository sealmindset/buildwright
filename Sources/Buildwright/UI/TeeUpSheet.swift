import SwiftUI

/// "Tee up the next thing": compose the prompt for the NEXT piece of work
/// while the current one runs. Linear by default — it goes on deck behind
/// the working pane and auto-starts when that finishes. The worktree toggle
/// makes it parallel-safe and immediate instead.
struct TeeUpSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var prompt = ""
    @State private var isolate = false

    private var gate: Pane? {
        guard !isolate, let ws = app.activeWorkspace else { return nil }
        return app.workingClaudePane(inDirectory: ws.baseRepo, of: ws)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tee Up Next").font(.title3.weight(.semibold))

            TextEditor(text: $prompt)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
                .overlay(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text("What should this Claude work on? (empty = interactive)")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8).padding(.leading, 6)
                            .allowsHitTesting(false)
                    }
                }

            Toggle("Run now in an isolated worktree (parallel-safe)", isOn: $isolate)

            HStack(spacing: 6) {
                Image(systemName: gate == nil ? "play.circle" : "hourglass")
                    .foregroundStyle(gate == nil ? .green : .orange)
                if let gate {
                    Text("Will go on deck behind “\(gate.title)” — starts automatically when it finishes.")
                } else if isolate {
                    Text("Starts immediately on its own branch; clean worktree removed on close.")
                } else {
                    Text("Nothing is working in this folder — starts immediately.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(gate == nil ? "Start" : "Tee Up") {
                    app.addPane(kind: .claude,
                                prompt: prompt.isEmpty ? nil : prompt,
                                worktree: isolate)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 460)
    }
}
