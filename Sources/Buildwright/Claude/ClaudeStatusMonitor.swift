import Foundation

/// Watches the status directory that bw-hook writes into and reports the
/// current status of every Claude pane.
final class ClaudeStatusMonitor {
    private let onChange: ([String: ClaudeStatus]) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var directoryFD: Int32 = -1
    private var timer: DispatchSourceTimer?

    init(onChange: @escaping ([String: ClaudeStatus]) -> Void) {
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

    private func scan() {
        var result: [String: ClaudeStatus] = [:]
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
            switch state {
            case "working": result[pane] = .working
            case "needs-input": result[pane] = .needsInput
            case "done": result[pane] = .done
            default: break
            }
        }
        onChange(result)
    }
}
