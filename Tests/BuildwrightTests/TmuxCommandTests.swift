import Testing
import Foundation
@testable import Buildwright

struct TmuxCommandTests {

    @Test func commandConstruction() {
        #expect(TmuxClient.command(["list-sessions"]) == ["tmux", "list-sessions"])
    }

    @Test func controlModeOutputUnescaping() {
        // tmux %output escapes non-printables and backslash as octal \ooo.
        #expect(TmuxControlClient.unescapeOctal("hello") == Array("hello".utf8))
        #expect(TmuxControlClient.unescapeOctal("\\033[1m") == [0x1B, 0x5B, 0x31, 0x6D])
        #expect(TmuxControlClient.unescapeOctal("a\\134b") == Array("a\\b".utf8))
        #expect(TmuxControlClient.unescapeOctal("\\015\\012") == [0x0D, 0x0A])
        // Trailing lone backslash must not crash or be swallowed.
        #expect(TmuxControlClient.unescapeOctal("x\\") == Array("x\\".utf8))
    }

    @Test func workspaceSessionNameSanitization() {
        #expect(Workspace(name: "docai", baseRepo: "/tmp").tmuxSessionName == "docai")
        #expect(Workspace(name: "My Project!", baseRepo: "/tmp").tmuxSessionName == "my-project")
        #expect(Workspace(name: "a.b:c", baseRepo: "/tmp").tmuxSessionName == "a-b-c")
        #expect(Workspace(name: "???", baseRepo: "/tmp").tmuxSessionName == "workspace")
    }

    @Test @MainActor func claudePromptQuoting() {
        let mgr = TmuxManager.shared
        let saved = mgr.claudeSkipPermissions
        defer { mgr.claudeSkipPermissions = saved }

        mgr.claudeSkipPermissions = true
        #expect(mgr.paneCommand(for: .claude) == "claude --dangerously-skip-permissions")
        let cmd = mgr.paneCommand(for: .claude, prompt: "/backlog start E04-S2")
        #expect(cmd == "claude --dangerously-skip-permissions '/backlog start E04-S2'")
        let tricky = mgr.paneCommand(for: .claude, prompt: "it's tricky")
        #expect(tricky == "claude --dangerously-skip-permissions 'it'\\''s tricky'")

        mgr.claudeSkipPermissions = false
        #expect(mgr.paneCommand(for: .claude) == "claude")
        #expect(mgr.paneCommand(for: .claude, prompt: "hi") == "claude 'hi'")
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
