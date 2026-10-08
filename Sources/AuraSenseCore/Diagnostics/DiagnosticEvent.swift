import Foundation

/// Severity level of diagnostic events.
public enum DiagnosticLevel: String, Sendable, Codable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"
}

/// A structured diagnostic event for observability and troubleshooting.
public struct DiagnosticEvent: Sendable, Identifiable, Codable {
    public let id: UUID
    public let timestamp: Date
    public let level: DiagnosticLevel
    public let category: String
    public let message: String
    public let metadata: [String: String]

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: DiagnosticLevel = .info,
        category: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.metadata = metadata
    }

    public var formattedTimestamp: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        return formatter.string(from: timestamp)
    }

    public var logLine: String {
        let metaString = metadata.isEmpty ? "" : " " + metadata.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        return "[\(formattedTimestamp)] [\(level.rawValue)] [\(category)] \(message)\(metaString)"
    }
}
