import SwiftUI

/// Menu-bar presence: see who needs you even when Buildwright is hidden
/// behind the corp-job world. The icon carries the waiting count; the menu
/// lists every waiting pane (oldest first) and jumps straight to it.
struct AttentionMenuBarContent: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        if app.attentionQueue.isEmpty {
            if app.workingCount > 0 {
                Text("● \(app.workingCount) working — nothing needs you")
            } else {
                Text("All quiet")
            }
        } else {
            ForEach(app.attentionQueue) { entry in
                Button {
                    app.jump(to: entry)
                } label: {
                    Text("\(glyph(entry.status.state)) \(entry.workspaceName) · \(entry.pane.title) — \(label(entry.status.state)) \(ageString(from: entry.status.since, to: app.now))")
                }
            }
            Divider()
            Button("Jump to Next (⌘J in app)") { app.jumpToNextAttention() }
        }
        Divider()
        Button("Open Buildwright") {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func glyph(_ s: ClaudeStatus) -> String {
        switch s {
        case .needsInput: return "◉"
        case .done: return "✓"
        case .working: return "●"
        case .none: return ""
        }
    }

    private func label(_ s: ClaudeStatus) -> String {
        switch s {
        case .needsInput: return "needs you ·"
        case .done: return "done ·"
        default: return ""
        }
    }
}

struct AttentionMenuBarLabel: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        if app.needsInputCount > 0 {
            // Attention needed: show the count loudly.
            Text("◉ \(app.needsInputCount)")
        } else if app.doneCount > 0 {
            Text("✓ \(app.doneCount)")
        } else if app.workingCount > 0 {
            Image(systemName: "circle.dotted.circle")
        } else {
            Image(systemName: "rectangle.split.3x1")
        }
    }
}
