import Foundation

/// Persistent diagnostic file logger writing timestamped events to disk.
/// Automatically creates log directory and rotates when file exceeds maximum size.
public final class FileLogger: @unchecked Sendable {
    private let lock = NSLock()
    public let logFileURL: URL
    private let maxFileSize: Int64
    private let dateFormatter: ISO8601DateFormatter

    public init(
        logDirectory: URL? = nil,
        fileName: String = "aurasense.log",
        maxFileSize: Int64 = 5 * 1024 * 1024 // 5 MB
    ) {
        self.maxFileSize = maxFileSize
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.dateFormatter = formatter

        let baseDir = logDirectory ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs")
            .appendingPathComponent("AuraSense")
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AuraSenseLogs")

        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        self.logFileURL = baseDir.appendingPathComponent(fileName)
    }

    /// Logs a diagnostic event to the log file.
    public func log(event: DiagnosticEvent) {
        lock.lock()
        defer { lock.unlock() }

        rotateIfNeeded()

        let timeStr = dateFormatter.string(from: event.timestamp)
        let line = "[\(timeStr)] [\(event.level.rawValue.uppercased())] [\(event.category)] \(event.message)\n"

        guard let data = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: logFileURL.path) {
            if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                try? fileHandle.close()
            }
        } else {
            try? data.write(to: logFileURL, options: .atomic)
        }
    }

    /// Reads recent log entries up to maxLines.
    public func readRecentLogs(maxLines: Int = 100) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        guard let content = try? String(contentsOf: logFileURL, encoding: .utf8) else {
            return []
        }

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        if lines.count <= maxLines {
            return lines
        }
        return Array(lines.suffix(maxLines))
    }

    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let size = attrs[.size] as? Int64,
              size >= maxFileSize else {
            return
        }

        let archiveURL = logFileURL.deletingPathExtension().appendingPathExtension("old.log")
        try? FileManager.default.removeItem(at: archiveURL)
        try? FileManager.default.moveItem(at: logFileURL, to: archiveURL)
    }
}
