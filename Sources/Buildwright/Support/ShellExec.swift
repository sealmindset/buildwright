import Foundation

struct ShellResult {
    let status: Int32
    let stdout: String
    let stderr: String
    var ok: Bool { status == 0 }
}

enum ShellExec {
    /// Run a command synchronously and capture output. Used for short tmux/system
    /// queries, never for long-lived processes (those run inside terminal panes).
    @discardableResult
    static func run(_ arguments: [String], cwd: String? = nil, environment: [String: String]? = nil) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = ProcessInfo.processInfo.environment
        if let environment {
            for (k, v) in environment { env[k] = v }
        }
        // Ensure Homebrew + user paths are visible when launched from Finder.
        let extraPaths = "/opt/homebrew/bin:/usr/local/bin:\(Config.home.path)/.local/bin"
        env["PATH"] = "\(env["PATH"] ?? "/usr/bin:/bin"):\(extraPaths)"
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Wait via semaphore, NOT waitUntilExit(): waitUntilExit spins the
        // current run loop, which re-enters AppKit's display cycle when called
        // mid-layout (e.g. from makeNSView) and crashes (pc=0 in UpdateCycle).
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }

        do {
            try process.run()
        } catch {
            return ShellResult(status: -1, stdout: "", stderr: "failed to launch: \(error.localizedDescription)")
        }
        // Drain BOTH pipes concurrently: reading them sequentially deadlocks
        // when a process fills the unread pipe's buffer (~64KB) and blocks.
        var errData = Data()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            errDone.signal()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        errDone.wait()
        done.wait()
        return ShellResult(
            status: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    /// Fire-and-forget asynchronous run (used for notifications, hooks, CVR launch).
    static func runDetached(_ arguments: [String], cwd: String? = nil) {
        DispatchQueue.global(qos: .utility).async {
            _ = run(arguments, cwd: cwd)
        }
    }

    /// Post a macOS notification. osascript works from a bare SPM executable
    /// (no bundle/entitlements required), unlike UNUserNotificationCenter.
    static func notify(title: String, body: String) {
        let esc: (String) -> String = { $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        runDetached(["osascript", "-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\" sound name \"Glass\""])
    }
}
