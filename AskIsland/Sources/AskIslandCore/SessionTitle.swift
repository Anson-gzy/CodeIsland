import Foundation

/// The human name of the agent session a request comes from, as the agent's own UI shows it.
public enum SessionTitle {
    /// Claude Code keeps the session's title in its transcript as `{"type":"custom-title","customTitle":…}`
    /// lines, rewritten whenever it changes; the last one wins. Transcripts grow to many MB, so read backwards
    /// in chunks and stop at the first match.
    public static func claude(transcriptPath: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        let chunk: UInt64 = 256 * 1024
        let marker = Data("\"custom-title\"".utf8)
        var end = size
        var carry = Data()  // a line split across chunk borders
        while end > 0 {
            let start = end > chunk ? end - chunk : 0
            try? handle.seek(toOffset: start)
            var data = (try? handle.read(upToCount: Int(end - start))) ?? Data()
            data.append(carry)
            // Keep the partial first line for the next (earlier) chunk.
            let firstNewline = start > 0 ? data.firstIndex(of: 0x0A) : nil
            let body = firstNewline.map { data[data.index(after: $0)...] } ?? data[...]
            carry = firstNewline.map { Data(data[..<$0]) } ?? Data()
            for line in body.split(separator: 0x0A).reversed() where line.range(of: marker) != nil {
                if let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                   obj["type"] as? String == "custom-title",
                   let title = (obj["customTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !title.isEmpty {
                    return title
                }
            }
            end = start
        }
        return nil
    }

    /// Finds the transcript `~/.claude/projects/<project>/<sessionId>.jsonl` (for a CLI call made from a
    /// Claude Code shell, which knows only `CLAUDE_CODE_SESSION_ID`).
    public static func claude(sessionId: String, home: String = NSHomeDirectory()) -> String? {
        guard !sessionId.isEmpty, !sessionId.contains("/") else { return nil }
        let projects = (home as NSString).appendingPathComponent(".claude/projects")
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: projects) else { return nil }
        for dir in dirs {
            let path = (projects as NSString).appendingPathComponent("\(dir)/\(sessionId).jsonl")
            if FileManager.default.fileExists(atPath: path) { return claude(transcriptPath: path) }
        }
        return nil
    }
}
