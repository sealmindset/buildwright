import SwiftUI

/// Quick capture (⌥⌘I from anywhere): one line, return, done. The thought
/// lands in the board's Inbox epic — no epic decision at capture time,
/// because that decision is exactly what kills capture. Grooming triages.
struct CaptureSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Capture a thought", systemImage: "tray.and.arrow.down")
                .font(.headline)
            TextField("Idea, bug, follow-up… return to file it", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit {
                    app.captureThought(text)
                    dismiss()
                }
            Text("Files into the board's Inbox for triage — no epic decision needed now. Esc to cancel.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 440)
        .onAppear { focused = true }
    }
}
