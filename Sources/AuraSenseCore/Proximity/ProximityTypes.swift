import Foundation

/// Primary proximity states for presence evaluation.
public enum ProximityState: String, Sendable, Codable {
    case near = "NEAR"
    case far = "FAR"
    case unknown = "UNKNOWN"
}

/// Metadata describing proximity transitions and confidence.
public struct ProximityEvaluation: Sendable, Codable, Equatable {
    public let state: ProximityState
    public let smoothedRSSI: Double?
    public let sampleCount: Int
    public let confidence: Double
    public let reason: String
    public let timestamp: Date

    public init(
        state: ProximityState = .unknown,
        smoothedRSSI: Double? = nil,
        sampleCount: Int = 0,
        confidence: Double = 0.0,
        reason: String = "Initial state",
        timestamp: Date = Date()
    ) {
        self.state = state
        self.smoothedRSSI = smoothedRSSI
        self.sampleCount = sampleCount
        self.confidence = confidence
        self.reason = reason
        self.timestamp = timestamp
    }
}
