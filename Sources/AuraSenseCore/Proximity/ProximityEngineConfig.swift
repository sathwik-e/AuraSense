import Foundation

/// Configuration parameters for the Proximity Engine.
/// Thresholds and dwell times derived from ARCHITECTURE.md experimental guidelines.
public struct ProximityEngineConfig: Sendable, Codable, Equatable {
    /// Upper RSSI threshold (dBm) required to enter NEAR state (e.g. -60 dBm).
    public var nearGateRSSI: Double

    /// Lower RSSI threshold (dBm) below which departure dwell begins (e.g. -75 dBm).
    public var farGateRSSI: Double

    /// Duration in seconds signal must remain continuously above nearGateRSSI before transitioning to NEAR.
    public var nearDwellDuration: TimeInterval

    /// Duration in seconds signal must remain below farGateRSSI or absent before initiating countdown.
    public var farDwellDuration: TimeInterval

    /// Duration in seconds of the visible, cancellable departure countdown (default: 5 seconds per ARCHITECTURE.md).
    public var countdownDuration: Int

    /// Maximum time elapsed without any candidate packets before considering evidence stale.
    public var staleTimeout: TimeInterval

    /// Window size for rolling median filtering (default: 5 samples).
    public var medianWindowSize: Int

    /// Smoothing factor for Exponentially Weighted Moving Average (EWMA, default: 0.30).
    public var ewmaAlpha: Double

    /// Maximum gap in seconds between packets before EWMA filter resets instead of smoothing across a long absence.
    public var maxGapDuration: TimeInterval

    public init(
        nearGateRSSI: Double = -60.0,
        farGateRSSI: Double = -75.0,
        nearDwellDuration: TimeInterval = 3.0,
        farDwellDuration: TimeInterval = 10.0,
        countdownDuration: Int = 5,
        staleTimeout: TimeInterval = 15.0,
        medianWindowSize: Int = 5,
        ewmaAlpha: Double = 0.30,
        maxGapDuration: TimeInterval = 15.0
    ) {
        self.nearGateRSSI = nearGateRSSI
        self.farGateRSSI = farGateRSSI
        self.nearDwellDuration = nearDwellDuration
        self.farDwellDuration = farDwellDuration
        self.countdownDuration = countdownDuration
        self.staleTimeout = staleTimeout
        self.medianWindowSize = medianWindowSize
        self.ewmaAlpha = ewmaAlpha
        self.maxGapDuration = maxGapDuration
    }

    /// Default production configuration.
    public static let `default` = ProximityEngineConfig()
}
