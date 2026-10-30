import Foundation

/// Appends timestamped entries to app.log. Commands log from background
/// tasks, so writes go through a serial queue.
enum Log {
    private static let queue = DispatchQueue(label: "dev.ate.mac.log")
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func append(_ url: URL, _ text: String) {
        queue.sync {
            var entry = "[\(formatter.string(from: Date()))] \(text)"
            if !entry.hasSuffix("\n") { entry += "\n" }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(entry.utf8))
                try? h.close()
            } else {
                try? Data(entry.utf8).write(to: url)
            }
        }
    }

    /// Indents command output under the entry that ran it.
    static func indent(_ output: String) -> String {
        output.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
            .map { "    \($0)" }
            .joined(separator: "\n")
    }

    static func duration(since start: Date) -> String {
        String(format: "%.1fs", Date().timeIntervalSince(start))
    }
}
