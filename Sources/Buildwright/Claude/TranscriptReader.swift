import Foundation

/// Pulls the last assistant message out of a Claude Code transcript (JSONL,
/// one event per line). Used to answer "what does this pane need?" / "what
/// did it just finish?" without the user switching to it.
enum TranscriptReader {

    /// How much of the file tail to inspect. Transcripts grow large; the last
    /// assistant text is always near the end.
    private static let tailBytes = 256 * 1024

    static func lastAssistantText(transcriptPath: String) -> String? {
        lastAssistantInfo(transcriptPath: transcriptPath).text
    }

    /// Last assistant text + the session's current context size (input +
    /// cache tokens of the most recent usage record). One tail read.
    static func lastAssistantInfo(transcriptPath: String) -> (text: String?, contextTokens: Int?) {
        guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { return (nil, nil) }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return (nil, nil) }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd() else { return (nil, nil) }

        // Walk lines from the end; first assistant text and first usage win.
        var text: String?
        var tokens: Int?
        let lines = data.split(separator: UInt8(ascii: "\n"))
        for line in lines.reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any] else { continue }
            if tokens == nil, let usage = message["usage"] as? [String: Any] {
                let total = ["input_tokens", "cache_read_input_tokens",
                             "cache_creation_input_tokens", "output_tokens"]
                    .compactMap { usage[$0] as? Int }.reduce(0, +)
                if total > 0 { tokens = total }
            }
            if text == nil, let content = message["content"] as? [[String: Any]] {
                let joined = content
                    .filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }
                    .joined(separator: " ")
                let cleaned = condense(joined)
                if !cleaned.isEmpty { text = cleaned }
            }
            if text != nil && tokens != nil { break }
        }
        return (text, tokens)
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
