import Foundation

/// Primary proximity states per ARCHITECTURE.md state machine.
public enum ProximityState: Sendable, Codable, Equatable {
    case unknown(reason: String)
    case near(smoothedRSSI: Double)
    case countdown(secondsRemaining: Int)
    case far(dwellDuration: TimeInterval)
    case authAttempt(attemptCount: Int)
    case unlocked

    public var displayLabel: String {
        switch self {
        case .unknown:
            return "UNKNOWN"
        case .near:
            return "NEAR"
        case .countdown(let sec):
            return "COUNTDOWN (\(sec)s)"
        case .far:
            return "FAR"
        case .authAttempt:
            return "AUTH_ATTEMPT"
        case .unlocked:
            return "UNLOCKED"
        }
    }

    public var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }

    public var isNear: Bool {
        if case .near = self { return true }
        return false
    }

    public var isCountdown: Bool {
        if case .countdown = self { return true }
        return false
    }

    public var isFar: Bool {
        if case .far = self { return true }
        return false
    }
}

/// Metadata describing proximity transitions, signal quality, and confidence.
public struct ProximityEvaluation: Sendable, Codable, Equatable {
    public let state: ProximityState
    public let smoothedRSSI: Double?
    public let rawRSSI: Int?
    public let sampleCount: Int
    public let confidence: Double
    public let reason: String
    public let timestamp: Date

    public init(
        state: ProximityState = .unknown(reason: "Initial startup state"),
        smoothedRSSI: Double? = nil,
        rawRSSI: Int? = nil,
        sampleCount: Int = 0,
        confidence: Double = 0.0,
        reason: String = "Initial state",
        timestamp: Date = Date()
    ) {
        self.state = state
        self.smoothedRSSI = smoothedRSSI
        self.rawRSSI = rawRSSI
        self.sampleCount = sampleCount
        self.confidence = confidence
        self.reason = reason
        self.timestamp = timestamp
    }
}
