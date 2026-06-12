import Foundation

/// One tmux control-mode connection (`tmux -C attach-session`) per workspace
/// session — the iTerm2 integration model. tmux still owns every process
/// (sessions survive quit/crash/reboot, iPad attaches as a normal client),
/// but pane CONTENT streams to the app as `%output` notifications and is
/// rendered into native SwiftTerm buffers: native scrollback, selection,
/// search. No grouped display sessions, no screen-scraped attach clients.
///
/// Protocol (verified against tmux 3.6b, see `man tmux` CONTROL MODE):
///  - We write commands terminated by `\n` to stdin.
///  - Every command produces exactly one `%begin … %end|%error` block on
///    stdout, in FIFO order. The initial attach also emits one unsolicited
///    block before any command of ours (dropped when nothing is pending).
///  - Notifications (`%output`, `%window-close`, …) arrive between blocks,
///    never inside one.
///  - `%output` escapes non-printable bytes and backslash as octal `\ooo`.
@MainActor
final class TmuxControlClient {

    enum Event {
        case output(paneID: String, bytes: [UInt8])
        case windowClose(windowID: String)
        case windowRenamed(windowID: String, name: String)
        /// tmux resized a window (any cause — our own refresh-client, another
        /// client, server events). Carries the new size so views can detect
        /// drift between what they render and what tmux believes.
        case layoutChange(windowID: String, cols: Int, rows: Int)
        case exited
    }

    let sessionName: String
    var onEvent: ((Event) -> Void)?

    private(set) var isAlive = false

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()

    /// Completions for in-flight commands, FIFO-matched to %begin/%end blocks.
    private var pending: [((ok: Bool, output: String)) -> Void] = []
    /// Non-nil while inside a %begin block: collected payload lines.
    private var blockLines: [String]?
    private var blockIsError = false
    /// Partial line carried between reads.
    private var readRemainder = Data()

    init(sessionName: String) {
        self.sessionName = sessionName
    }

    // MARK: Connection

    /// Attach. Returns false if the process could not launch (no tmux).
    @discardableResult
    func connect() -> Bool {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux", "-C", "attach-session", "-t", "=\(sessionName)"]
        var env = ProcessInfo.processInfo.environment
        let extraPaths = "/opt/homebrew/bin:/usr/local/bin:\(Config.home.path)/.local/bin"
        env["PATH"] = "\(env["PATH"] ?? "/usr/bin:/bin"):\(extraPaths)"
        process.environment = env
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        // DispatchQueue.main (not Task) so chunks land strictly in arrival
        // order — out-of-order %output would corrupt the terminal stream.
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.ingest(data) }
            }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleExit() }
            }
        }
        do {
            try process.run()
        } catch {
            return false
        }
        isAlive = true
        return true
    }

    func disconnect() {
        guard isAlive else { return }
        send("detach-client")
    }

    private func handleExit() {
        guard isAlive else { return }
        isAlive = false
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        for completion in pending { completion((ok: false, output: "control client exited")) }
        pending.removeAll()
        onEvent?(.exited)
    }

    // MARK: Commands

    /// Send a tmux command over the control connection. The completion runs
    /// on the main actor when the matching %end/%error block arrives.
    func send(_ command: String, completion: (((ok: Bool, output: String)) -> Void)? = nil) {
        guard isAlive else {
            completion?((ok: false, output: "not connected"))
            return
        }
        pending.append(completion ?? { _ in })
        if let data = (command + "\n").data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }
    }

    /// Type bytes into a pane (`send-keys -H` takes hex bytes — no key-name
    /// lookup, no quoting hazards). Chunked to keep command lines short.
    func sendKeys(paneID: String, bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        for chunk in stride(from: 0, to: bytes.count, by: 128) {
            let slice = bytes[chunk..<min(chunk + 128, bytes.count)]
            let hex = slice.map { String(format: "%02x", $0) }.joined(separator: " ")
            send("send-keys -H -t \(paneID) \(hex)")
        }
    }

    /// Set the size tmux gives a window for THIS client. Per-window sizing is
    /// a control-mode feature: `refresh-client -C @id:WxH` (tmux ≥ 3.2).
    func setWindowSize(windowID: String, cols: Int, rows: Int) {
        guard cols > 1, rows > 1 else { return }
        send("refresh-client -C \(windowID):\(cols)x\(rows)")
    }

    /// Scrollback ABOVE the visible screen (with colors), for replay into a
    /// fresh native buffer. -E -1 stops at the last history line.
    func captureHistory(paneID: String, lines: Int = 5000, completion: @escaping (String?) -> Void) {
        send("capture-pane -peqJ -t \(paneID) -S -\(lines) -E -1") { result in
            completion(result.ok ? result.output : nil)
        }
    }

    /// The visible screen exactly as displayed: one line per row (no -J so
    /// rows map 1:1), with colors.
    func captureScreen(paneID: String, completion: @escaping (String?) -> Void) {
        send("capture-pane -peq -t \(paneID)") { result in
            completion(result.ok ? result.output : nil)
        }
    }

    /// Where tmux believes the pane's cursor is (col, row), zero-based.
    func cursorPosition(paneID: String, completion: @escaping ((x: Int, y: Int)?) -> Void) {
        send("display-message -p -t \(paneID) \"#{cursor_x} #{cursor_y}\"") { result in
            let parts = result.output
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: " ")
            guard result.ok, parts.count == 2,
                  let x = Int(parts[0]), let y = Int(parts[1]) else {
                completion(nil)
                return
            }
            completion((x: x, y: y))
        }
    }

    /// Terminal modes the application inside the pane has enabled — must be
    /// restored on reattach or arrow keys / mouse / alt-screen apps
    /// misbehave until their next full redraw.
    struct PaneModes {
        var alternateScreen = false
        var applicationCursorKeys = false
        var mouseAny = false
        var mouseButton = false
        var mouseStandard = false
        var mouseAll = false
        var mouseSGR = false
        var cursorVisible = true

        /// DECSET sequences recreating these modes in a fresh terminal.
        var restoreSequences: String {
            var out = ""
            if applicationCursorKeys { out += "\u{1b}[?1h" }
            if mouseAll { out += "\u{1b}[?1003h" }
            else if mouseButton { out += "\u{1b}[?1002h" }
            else if mouseStandard || mouseAny { out += "\u{1b}[?1000h" }
            if mouseSGR { out += "\u{1b}[?1006h" }
            if !cursorVisible { out += "\u{1b}[?25l" }
            // Bracketed paste isn't queryable in tmux formats; modern shells
            // and Claude Code all enable it, so restore unconditionally.
            out += "\u{1b}[?2004h"
            return out
        }
    }

    func paneModes(paneID: String, completion: @escaping (PaneModes?) -> Void) {
        let fmt = "#{alternate_on} #{keypad_cursor_flag} #{mouse_any_flag} #{mouse_button_flag} #{mouse_standard_flag} #{mouse_all_flag} #{mouse_sgr_flag} #{cursor_flag}"
        send("display-message -p -t \(paneID) \"\(fmt)\"") { result in
            let f = result.output
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: " ").map { $0 == "1" }
            guard result.ok, f.count == 8 else { completion(nil); return }
            completion(PaneModes(
                alternateScreen: f[0], applicationCursorKeys: f[1],
                mouseAny: f[2], mouseButton: f[3], mouseStandard: f[4],
                mouseAll: f[5], mouseSGR: f[6], cursorVisible: f[7]))
        }
    }

    /// First (and for Buildwright, only) pane id of a window, e.g. "@3" → "%7".
    func primaryPaneID(windowID: String, completion: @escaping (String?) -> Void) {
        send("list-panes -t \(windowID) -F \"#{pane_id}\"") { result in
            let id = result.output.split(separator: "\n").first.map(String.init)
            completion(result.ok ? id : nil)
        }
    }

    // MARK: Protocol parsing

    private func ingest(_ data: Data) {
        guard !data.isEmpty else { return }
        readRemainder.append(data)
        while let nl = readRemainder.firstIndex(of: 0x0A) {
            let lineData = readRemainder.subdata(in: readRemainder.startIndex..<nl)
            readRemainder.removeSubrange(readRemainder.startIndex...nl)
            var line = String(decoding: lineData, as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            parseLine(line)
        }
    }

    private func parseLine(_ line: String) {
        if blockLines != nil {
            // Inside a command block: only %end/%error terminate it
            // (notifications never appear inside a block).
            if line.hasPrefix("%end ") || line.hasPrefix("%error ") {
                let output = blockLines!.joined(separator: "\n")
                let isError = line.hasPrefix("%error ")
                blockLines = nil
                if pending.isEmpty { return } // unsolicited block (initial attach greeting)
                let completion = pending.removeFirst()
                completion((ok: !isError, output: output))
            } else {
                blockLines!.append(line)
            }
            return
        }
        if line.hasPrefix("%begin ") {
            blockLines = []
            return
        }
        parseNotification(line)
    }

    private func parseNotification(_ line: String) {
        if line.hasPrefix("%output ") {
            let rest = line.dropFirst("%output ".count)
            guard let space = rest.firstIndex(of: " ") else { return }
            let paneID = String(rest[..<space])
            let value = rest[rest.index(after: space)...]
            onEvent?(.output(paneID: paneID, bytes: Self.unescapeOctal(value)))
        } else if line.hasPrefix("%window-close ") {
            // NOT %unlinked-window-close: that fires for windows in OTHER
            // sessions on the server (e.g. killing legacy helper sessions
            // that shared our windows) — treating it as a close injected
            // "process exited" notices into live panes.
            if let id = line.split(separator: " ").last {
                onEvent?(.windowClose(windowID: String(id)))
            }
        } else if line.hasPrefix("%window-renamed ") {
            let parts = line.split(separator: " ", maxSplits: 2)
            if parts.count == 3 {
                onEvent?(.windowRenamed(windowID: String(parts[1]), name: String(parts[2])))
            }
        } else if line.hasPrefix("%layout-change ") {
            // "%layout-change @id <layout> <visible-layout> <flags>" where
            // layout = "checksum,WxH,X,Y,...".
            let parts = line.split(separator: " ")
            if parts.count >= 3 {
                let layoutFields = parts[2].split(separator: ",")
                if layoutFields.count >= 2 {
                    let dims = layoutFields[1].split(separator: "x")
                    if dims.count == 2, let w = Int(dims[0]), let h = Int(dims[1]) {
                        onEvent?(.layoutChange(windowID: String(parts[1]), cols: w, rows: h))
                    }
                }
            }
        } else if line.hasPrefix("%exit") {
            // Termination handler does the cleanup; nothing to do here.
        }
        // Other notifications (%session-changed, %sessions-changed, …) are
        // intentionally ignored for now.
    }

    /// Decode tmux %output escaping: non-printables and backslash arrive as
    /// octal `\ooo`; everything else is literal UTF-8.
    static func unescapeOctal<S: StringProtocol>(_ value: S) -> [UInt8] {
        var out: [UInt8] = []
        let bytes = Array(value.utf8)
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "\\"), i + 3 < bytes.count,
               let d1 = octalDigit(bytes[i + 1]), let d2 = octalDigit(bytes[i + 2]), let d3 = octalDigit(bytes[i + 3]) {
                out.append(d1 << 6 | d2 << 3 | d3)
                i += 4
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return out
    }

    private static func octalDigit(_ byte: UInt8) -> UInt8? {
        (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(byte) ? byte - UInt8(ascii: "0") : nil
    }
}
