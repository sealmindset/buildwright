import Testing
import Foundation
@testable import Buildwright

struct TmuxCommandTests {

    @Test func commandConstruction() {
        #expect(TmuxClient.command(["list-sessions"]) == ["tmux", "list-sessions"])
    }

    @Test func groupedSessionNaming() {
        let name = TmuxClient.groupedSessionName(workspaceSession: "docai", paneShortID: "ab12cd34")
        #expect(name == "_bw-docai-ab12cd34")
        #expect(name.hasPrefix(Config.groupedSessionPrefix), "bw CLI filters on this prefix")
        #expect(!name.contains(":"), "tmux session names cannot contain ':'")
        #expect(!name.contains("."), "tmux session names cannot contain '.'")
    }

    @Test func workspaceSessionNameSanitization() {
        #expect(Workspace(name: "docai", baseRepo: "/tmp").tmuxSessionName == "docai")
        #expect(Workspace(name: "My Project!", baseRepo: "/tmp").tmuxSessionName == "my-project")
        #expect(Workspace(name: "a.b:c", baseRepo: "/tmp").tmuxSessionName == "a-b-c")
        #expect(Workspace(name: "???", baseRepo: "/tmp").tmuxSessionName == "workspace")
    }

    @Test @MainActor func claudePromptQuoting() {
        let cmd = TmuxManager.shared.paneCommand(for: .claude, prompt: "/backlog start E04-S2")
        #expect(cmd == "claude '/backlog start E04-S2'")
        let tricky = TmuxManager.shared.paneCommand(for: .claude, prompt: "it's tricky")
        #expect(tricky == "claude 'it'\\''s tricky'")
    }

    @Test @MainActor func shellPaneUsesDefaultShell() {
        #expect(TmuxManager.shared.paneCommand(for: .shell) == nil, "nil lets tmux use the user's login shell")
    }

    @Test func paneShortIDStable() {
        let pane = Pane(kind: .claude, title: "claude", directory: "/tmp")
        #expect(pane.shortID.count == 8)
        #expect(pane.shortID == pane.shortID.lowercased())
    }
}
