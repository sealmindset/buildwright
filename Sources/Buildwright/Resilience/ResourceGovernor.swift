import Foundation
import Darwin
import Combine

/// E46-S3 — resource governor core. Continuously tracks two signals:
///  1. macOS memory pressure (DispatchSource: normal/warning/critical), and
///  2. Buildwright's OWNED-agent footprint (sum of phys_footprint over the
///     processes in our tmux sessions),
/// against RAM-derived budgets, and publishes a tier (green/amber/red) + census.
///
/// This is the WARN-ONLY tier of the two-tier policy (E44-S2 census lives here):
/// it never kills anything. The emergency circuit-breaker that auto-sheds load at
/// the cliff is E46-S4; the live health panel is E46-S14. The probe-equivalent
/// numbers are surfaced here so accumulation is visible before it becomes a freeze.
@MainActor
final class ResourceGovernor: ObservableObject {
    static let shared = ResourceGovernor()

    enum Tier: String { case green, amber, red }

    @Published private(set) var tier: Tier = .green
    /// "normal" | "warning" | "critical" — the macOS memory-pressure level.
    @Published private(set) var pressureLevel: String = "normal"
    @Published private(set) var agentCount = 0
    @Published private(set) var ownedFootprintBytes: UInt64 = 0
    /// Last circuit-breaker action (E46-S4), for the menu/health surface.
    @Published private(set) var lastAction = ""
    /// Set by AppState: reap clearly-dead panes at the cliff (S4 ladder rung 4).
    var onCliffReap: (() -> Void)?

    let physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory

    // Budgets as fractions of physical RAM (overridable in Settings later, E46
    // open question). On 128GB: amber ≈ 32GB owned footprint, red ≈ 64GB.
    var amberFootprintFraction = 0.25
    var redFootprintFraction = 0.50
    /// Standing-army guard (E44-S2): amber once we're carrying this many agents.
    var amberAgentCount = 12

    private var memSource: DispatchSourceMemoryPressure?
    private var timer: Timer?
    private let sampleQueue = DispatchQueue(label: "bw.governor.sample", qos: .utility)

    private init() {}

    /// Begin watching. Idempotent; call once at launch.
    func start() {
        guard memSource == nil else { return }
        let src = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let ev = src.data
            if ev.contains(.critical) { self.pressureLevel = "critical" }
            else if ev.contains(.warning) { self.pressureLevel = "warning" }
            else { self.pressureLevel = "normal" }
            self.recomputeTier()
        }
        src.resume()
        memSource = src

        let t = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            self?.sample()
        }
        t.tolerance = 1
        timer = t
        sample()
    }

    /// Sample owned-agent count + footprint off the main thread, then publish.
    private func sample() {
        let sessions = TmuxManager.shared.ownedSessionNames()
        sampleQueue.async { [weak self] in
            let pids = Self.agentPIDs(sessions: sessions)
            var footprint: UInt64 = 0
            for pid in pids { footprint &+= Self.physFootprint(pid: pid) }
            let count = pids.count
            Task { @MainActor in
                guard let self else { return }
                self.agentCount = count
                self.ownedFootprintBytes = footprint
                self.recomputeTier()
            }
        }
    }

    private func recomputeTier() {
        let phys = Double(physicalMemoryBytes)
        let fp = Double(ownedFootprintBytes)
        let new: Tier
        if pressureLevel == "critical" || fp > redFootprintFraction * phys {
            new = .red
        } else if pressureLevel == "warning"
                    || fp > amberFootprintFraction * phys
                    || agentCount >= amberAgentCount {
            new = .amber
        } else {
            new = .green
        }
        guard new != tier else { return }
        let was = tier
        tier = new
        // E46-S4 circuit-breaker: auto shed-load on the cliff, reverse on recovery.
        if new == .red, was != .red {
            lastAction = TerminalViewCache.shared.engageStress()
            onCliffReap?() // S4 rung 4: reap clearly-dead panes (reclaims their memory)
        } else if was == .red, new != .red {
            lastAction = TerminalViewCache.shared.relieveStress()
        }
    }

    // MARK: Census helpers (nonisolated — run off the main actor)

    /// PIDs of the top process in each pane of our tmux sessions (the agents).
    nonisolated static func agentPIDs(sessions: [String]) -> [Int32] {
        var pids: [Int32] = []
        for s in sessions {
            let r = ShellExec.run(["tmux", "list-panes", "-s", "-t", s, "-F", "#{pane_pid}"])
            guard r.ok else { continue }
            for line in r.stdout.split(separator: "\n") {
                if let p = Int32(line.trimmingCharacters(in: .whitespaces)) { pids.append(p) }
            }
        }
        return pids
    }

    /// A process's physical memory footprint (what Activity Monitor calls
    /// "Memory"), via libproc. Same-user processes only — our agents qualify.
    nonisolated static func physFootprint(pid: Int32) -> UInt64 {
        var info = rusage_info_current()
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reb in
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, reb)
            }
        }
        return rc == 0 ? info.ri_phys_footprint : 0
    }

    // MARK: Readouts

    var footprintGB: Double { Double(ownedFootprintBytes) / 1_073_741_824 }
    var physicalGB: Double { Double(physicalMemoryBytes) / 1_073_741_824 }

    /// One-line summary for diagnostics / a header chip.
    var summary: String {
        String(format: "%d agents · %.1f GB · pressure=%@ · %@",
               agentCount, footprintGB, pressureLevel, tier.rawValue)
    }
}
