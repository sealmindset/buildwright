import Foundation

/// Pulls the last assistant message out of a Claude Code transcript (JSONL,
/// one event per line). Used to answer "what does this pane need?" / "what
/// did it just finish?" without the user switching to it.
enum TranscriptReader {

    /// How much of the file tail to inspect. Transcripts grow large; the last
    /// assistant text is always near the end.
    private static let tailBytes = 256 * 1024

    /// Last assistant text in the transcript, single-line, trimmed.
    /// Returns nil when the file is unreadable or contains no assistant text.
    static func lastAssistantText(transcriptPath: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd() else { return nil }

        // Walk lines from the end; first complete assistant text wins.
        let lines = data.split(separator: UInt8(ascii: "\n"))
        for line in lines.reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            let text = content
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: " ")
            let cleaned = condense(text)
            if !cleaned.isEmpty { return cleaned }
        }
        return nil
    }

    /// Collapse to a single readable line capped for status UI.
    static func condense(_ text: String, limit: Int = 280) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard oneLine.count > limit else { return oneLine }
        return String(oneLine.prefix(limit)) + "…"
    }
}
