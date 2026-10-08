import Foundation

/// Two-stage signal processor:
/// 1. Rolling 5-sample median to reject isolated multipath/burst outliers.
/// 2. EWMA (Exponentially Weighted Moving Average) smoothing for stable distance proxy.
public final class RSSIFilter: @unchecked Sendable {
    private let lock = NSLock()
    private let config: ProximityEngineConfig

    private var sampleWindow: [RSSIReading] = []
    private var lastSampleTime: Date?
    private var smoothedRSSI: Double?
    private var totalSampleCount: Int = 0

    public init(config: ProximityEngineConfig = .default) {
        self.config = config
    }

    /// Adds a new RSSI reading and returns the current smoothed value, or nil if invalid.
    public func addSample(rssi: Int, timestamp: Date = Date()) -> Double? {
        lock.lock()
        defer { lock.unlock() }

        // Sanity check: Reject impossible RF anomalies (e.g., positive RSSI or below -120 dBm)
        guard rssi <= 0 && rssi >= -120 else {
            return smoothedRSSI
        }

        // Check if gap is too long; if so, reset EWMA memory
        if let last = lastSampleTime, timestamp.timeIntervalSince(last) > config.maxGapDuration {
            smoothedRSSI = nil
            sampleWindow.removeAll()
        }

        lastSampleTime = timestamp
        totalSampleCount += 1

        let reading = RSSIReading(rssi: rssi, timestamp: timestamp)
        sampleWindow.append(reading)

        // Maintain median window size
        if sampleWindow.count > config.medianWindowSize {
            sampleWindow.removeFirst(sampleWindow.count - config.medianWindowSize)
        }

        // Calculate median
        let medianValue = calculateMedian(samples: sampleWindow)

        // Calculate EWMA
        if let previous = smoothedRSSI {
            let alpha = config.ewmaAlpha
            let newSmoothed = (alpha * Double(medianValue)) + ((1.0 - alpha) * previous)
            smoothedRSSI = newSmoothed
        } else {
            smoothedRSSI = Double(medianValue)
        }

        return smoothedRSSI
    }

    /// Returns the current smoothed RSSI value.
    public var currentSmoothedRSSI: Double? {
        lock.lock()
        defer { lock.unlock() }
        return smoothedRSSI
    }

    /// Returns the number of admitted samples processed since last reset.
    public var sampleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalSampleCount
    }

    /// Resets all filter history and EWMA state.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        sampleWindow.removeAll()
        lastSampleTime = nil
        smoothedRSSI = nil
        totalSampleCount = 0
    }

    private func calculateMedian(samples: [RSSIReading]) -> Int {
        guard !samples.isEmpty else { return -100 }
        let sorted = samples.map { $0.rssi }.sorted()
        let count = sorted.count
        if count % 2 == 1 {
            return sorted[count / 2]
        } else {
            return (sorted[(count / 2) - 1] + sorted[count / 2]) / 2
        }
    }
}
