import Foundation
import Combine

/// E46-S6 — main-thread hang watchdog. A background probe pings the main thread
/// once a second and waits on a semaphore; if the main thread can't service the
/// ping within `timeout`, it's wedged (the beachball). While it's wedged we
/// capture a `sample` of our OWN process — exactly the artifact the 2026-06-14
/// freeze never produced — then notify when the main thread recovers.
///
/// Phase 1 = detect + self-document + surface. A genuinely safe *restart* of a
/// hung GUI only becomes possible once the daemon owns the agents (E46 Phase 2),
/// so here we don't kill anything — we make the hang visible and forensic.
@MainActor
final class MainThreadWatchdog: ObservableObject {
    static let shared = MainThreadWatchdog()

    /// Human-readable note about the most recent hang (for the menu / health UI).
    @Published private(set) var lastHang = ""

    private static let timeout: TimeInterval = 3      // a 3s main-thread block = a real hang
    private static let probeInterval: TimeInterval = 1
    private let queue = DispatchQueue(label: "bw.watchdog", qos: .utility)
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        queue.async { [weak self] in self?.loop() }
    }

    nonisolated private func loop() {
        let pid = ProcessInfo.processInfo.processIdentifier
        while true {
            let sem = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { sem.signal() } // serviced only when main is live
            if sem.wait(timeout: .now() + Self.timeout) == .timedOut {
                // Main thread is wedged. Capture forensics now (sample reads the
                // process externally, so it works even while main is frozen).
                let started = Date()
                let report = Self.captureSample(pid: pid)
                sem.wait() // blocks until main finally runs our ping = recovered
                let seconds = Date().timeIntervalSince(started) + Self.timeout
                let msg = String(format: "recovered from a %.1fs main-thread hang — sample: %@",
                                 seconds, report ?? "(capture failed)")
                ShellExec.notify(title: "Buildwright watchdog", body: msg)
                Task { @MainActor [weak self] in self?.lastHang = msg }
            }
            Thread.sleep(forTimeInterval: Self.probeInterval)
        }
    }

    /// `sample <pid>` to a Buildwright-owned reports dir. Runs off-main.
    nonisolated static func captureSample(pid: Int32) -> String? {
        let dir = Config.stateDirectory.appendingPathComponent("hang-reports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = stampFormatter.string(from: Date())
        let file = dir.appendingPathComponent("hang-\(stamp).txt")
        let r = ShellExec.run(["sample", "\(pid)", "2", "-file", file.path])
        return r.ok ? file.path : nil
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
