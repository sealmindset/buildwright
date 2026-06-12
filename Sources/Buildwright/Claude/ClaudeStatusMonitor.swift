import Foundation

/// Watches the status directory that bw-hook writes into and reports the
/// current status of every Claude pane.
final class ClaudeStatusMonitor {
    private let onChange: ([String: PaneStatus]) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var directoryFD: Int32 = -1
    private var timer: DispatchSourceTimer?

    init(onChange: @escaping ([String: PaneStatus]) -> Void) {
        self.onChange = onChange
    }

    func start() {
        Config.ensureDirectories()
        let path = Config.claudeStatusDirectory.path
        directoryFD = open(path, O_EVTONLY)
        if directoryFD >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: directoryFD, eventMask: [.write], queue: .global(qos: .utility))
            src.setEventHandler { [weak self] in self?.scan() }
            src.setCancelHandler { [directoryFD = self.directoryFD] in close(directoryFD) }
            src.resume()
            source = src
        }
        // Belt-and-braces periodic rescan (covers editors/atomic renames the
        // fs event may miss).
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 2, repeating: 5)
        t.setEventHandler { [weak self] in self?.scan() }
        t.resume()
        timer = t
        scan()
    }

    func stop() {
        source?.cancel()
        source = nil
        timer?.cancel()
        timer = nil
    }

    /// Transcript-tail cache: pane shortID → (transcript mtime, extracted
    /// text). Scans run every few seconds; only re-parse when the file moved.
    private var transcriptCache: [String: (mtime: Date, text: String?, tokens: Int?)] = [:]

    private func scan() {
        var result: [String: PaneStatus] = [:]
        let dir = Config.claudeStatusDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            onChange([:])
            return
        }
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pane = obj["pane"] as? String,
                  let state = obj["state"] as? String else { continue }
            let since: Date
            if let ts = obj["ts"] as? Double {
                since = Date(timeIntervalSince1970: ts)
            } else if let ts = obj["ts"] as? Int {
                since = Date(timeIntervalSince1970: Double(ts))
            } else {
                since = Date()
            }
            let info = transcriptInfo(for: pane, statusJSON: obj)
            let detail = (state == "needs-input" || state == "done")
                ? ((obj["detail"] as? String).flatMap { $0.isEmpty ? nil : TranscriptReader.condense($0) } ?? info.text)
                : nil
            switch state {
            case "working": result[pane] = PaneStatus(state: .working, since: since, contextTokens: info.tokens)
            case "needs-input": result[pane] = PaneStatus(state: .needsInput, since: since, detail: detail, contextTokens: info.tokens)
            case "done": result[pane] = PaneStatus(state: .done, since: since, detail: detail, contextTokens: info.tokens)
            default: break
            }
        }
        onChange(result)
    }

    /// Transcript tail (mtime-cached): last assistant text + context tokens.
    private func transcriptInfo(for pane: String, statusJSON: [String: Any]) -> (text: String?, tokens: Int?) {
        guard let transcript = statusJSON["transcript"] as? String, !transcript.isEmpty else { return (nil, nil) }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: transcript)[.modificationDate] as? Date)
            .flatMap { $0 } ?? .distantPast
        if let cached = transcriptCache[pane], cached.mtime == mtime {
            return (cached.text, cached.tokens)
        }
        let info = TranscriptReader.lastAssistantInfo(transcriptPath: transcript)
        transcriptCache[pane] = (mtime, info.text, info.contextTokens)
        return (info.text, info.contextTokens)
    }
}
