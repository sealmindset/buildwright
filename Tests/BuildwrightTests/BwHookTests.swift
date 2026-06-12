import Testing
import Foundation
@testable import Buildwright

/// Runs the embedded bw-hook script against real Claude Code hook payload
/// shapes and checks the status JSON it writes. Regression: Stop payloads
/// carry the closing text in `last_assistant_message` (the transcript no
/// longer holds assistant messages), and dropping it left every "finished"
/// notification with an empty, useless body.
struct BwHookTests {

    private func runHook(state: String, payload: String) throws -> [String: Any] {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bwhook-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let script = tmp.appendingPathComponent("bw-hook")
        try EmbeddedScripts.bwHook.write(to: script, atomically: true, encoding: .utf8)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = [script.path, state]
        var env = ProcessInfo.processInfo.environment
        env["BUILDWRIGHT_PANE_ID"] = "testpane"
        env["BUILDWRIGHT_PANE_TITLE"] = "E42-S2"
        env["BUILDWRIGHT_STATUS_DIR"] = tmp.path
        proc.environment = env
        let stdin = Pipe()
        proc.standardInput = stdin
        try proc.run()
        stdin.fileHandleForWriting.write(Data(payload.utf8))
        try stdin.fileHandleForWriting.close()
        proc.waitUntilExit()

        let data = try Data(contentsOf: tmp.appendingPathComponent("testpane.json"))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try #require(obj)
    }

    @Test func stopPayloadLiftsLastAssistantMessage() throws {
        let status = try runHook(state: "done", payload: """
        {"session_id":"abc","transcript_path":"/tmp/t.jsonl","cwd":"/x","permission_mode":"default","hook_event_name":"Stop","last_assistant_message":"E42-S2 is done — nightly reconcile shipped and verified."}
        """)
        #expect(status["state"] as? String == "done")
        #expect(status["title"] as? String == "E42-S2")
        #expect(status["detail"] as? String == "E42-S2 is done — nightly reconcile shipped and verified.")
        #expect(status["transcript"] as? String == "/tmp/t.jsonl")
    }

    @Test func notificationMessageStillWins() throws {
        let status = try runHook(state: "needs-input", payload: """
        {"session_id":"abc","transcript_path":"/tmp/t.jsonl","hook_event_name":"Notification","message":"Claude needs your permission to use Bash"}
        """)
        #expect(status["detail"] as? String == "Claude needs your permission to use Bash")
    }

    @Test func emptyPayloadStaysValidJSON() throws {
        let status = try runHook(state: "done", payload: "{}")
        #expect(status["state"] as? String == "done")
        #expect(status["detail"] as? String == "")
    }

    /// The repo's Scripts/bw-hook is documented as a mirror of the embedded
    /// script; keep them from drifting (modulo the reference-copy header).
    @Test func scriptsCopyMirrorsEmbedded() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)   // .../Tests/BuildwrightTests/BwHookTests.swift
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fileText = try String(contentsOf: repoRoot.appendingPathComponent("Scripts/bw-hook"), encoding: .utf8)
        func lines(_ s: String) -> [String] {
            var out = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                .filter { !$0.hasPrefix("# Reference copy") }
            while out.last?.isEmpty == true { out.removeLast() }
            return out
        }
        #expect(lines(fileText) == lines(EmbeddedScripts.bwHook))
    }
}
