import Foundation
import SwiftUI

// MARK: - Device Category & Classification

public enum DeviceCategory: String, Codable, CaseIterable, Identifiable {
    case iPhone = "iPhone"
    case appleWatch = "Apple Watch"
    case airPods = "AirPods / Audio"
    case iPad = "iPad"
    case mac = "Mac"
    case securityKey = "Security Key / Tag"
    case genericBLE = "BLE Peripheral"

    public var id: String { rawValue }

    public var symbolName: String {
        switch self {
        case .iPhone: return "iphone.gen3"
        case .appleWatch: return "applewatch"
        case .airPods: return "airpodspro"
        case .iPad: return "ipad"
        case .mac: return "laptopcomputer"
        case .securityKey: return "sensor.tag.radiowaves.forward.fill"
        case .genericBLE: return "wave.3.right.circle.fill"
        }
    }

    public var accentColor: Color {
        switch self {
        case .iPhone: return Color(red: 0.25, green: 0.62, blue: 1.0)
        case .appleWatch: return Color(red: 0.18, green: 0.85, blue: 0.68)
        case .airPods: return Color(red: 0.58, green: 0.45, blue: 1.0)
        case .iPad: return Color(red: 0.40, green: 0.55, blue: 0.98)
        case .mac: return Color(red: 0.55, green: 0.72, blue: 0.95)
        case .securityKey: return Color(red: 1.0, green: 0.65, blue: 0.22)
        case .genericBLE: return Color(red: 0.52, green: 0.60, blue: 0.75)
        }
    }

    public static func infer(from name: String, manufacturerSummary: String? = nil) -> DeviceCategory {
        let lower = name.lowercased()
        if lower.contains("iphone") {
            return .iPhone
        } else if lower.contains("watch") {
            return .appleWatch
        } else if lower.contains("airpod") || lower.contains("beats") || lower.contains("buds") || lower.contains("headphone") {
            return .airPods
        } else if lower.contains("ipad") {
            return .iPad
        } else if lower.contains("macbook") || lower.contains("imac") || lower.contains("mac ") {
            return .mac
        } else if lower.contains("tag") || lower.contains("key") || lower.contains("tile") || lower.contains("yubi") || lower.contains("beacon") {
            return .securityKey
        }
        if let mfg = manufacturerSummary?.lowercased(), mfg.contains("apple") {
            return .iPhone
        }
        return .genericBLE
    }
}

// MARK: - RSSI Sample & Signal Filtering

public struct RSSISample: Identifiable, Equatable {
    public let id = UUID()
    public let timestamp: Date
    public let rawRSSI: Int
    public let smoothedRSSI: Double

    public init(timestamp: Date = Date(), rawRSSI: Int, smoothedRSSI: Double) {
        self.timestamp = timestamp
        self.rawRSSI = rawRSSI
        self.smoothedRSSI = smoothedRSSI
    }
}

/// 1D Kalman + Exponential Moving Average filter to smooth noisy Bluetooth RSSI readings
/// and prevent rapid lock/unlock oscillation when sitting near the boundary.
public struct KalmanRSSIFilter {
    private var estimate: Double
    private var errorCovariance: Double
    public var processNoise: Double
    public var measurementNoise: Double

    public init(initialEstimate: Double = -65.0, processNoise: Double = 1.2, measurementNoise: Double = 6.5) {
        self.estimate = initialEstimate
        self.errorCovariance = 4.0
        self.processNoise = processNoise
        self.measurementNoise = measurementNoise
    }

    public mutating func update(measurement: Double, alphaOverride: Double? = nil) -> Double {
        // Prediction step
        let predictedError = errorCovariance + processNoise
        // Kalman gain
        let kalmanGain = predictedError / (predictedError + measurementNoise)
        let kalmanEstimate = estimate + kalmanGain * (measurement - estimate)
        errorCovariance = (1.0 - kalmanGain) * predictedError

        if let alpha = alphaOverride {
            let clampedAlpha = min(max(alpha, 0.05), 0.95)
            estimate = (clampedAlpha * measurement) + ((1.0 - clampedAlpha) * kalmanEstimate)
        } else {
            estimate = kalmanEstimate
        }
        return estimate
    }

    public mutating func reset(to value: Double) {
        estimate = value
        errorCovariance = 4.0
    }
}

// MARK: - Discovered BLE Device Model

public struct BLEDevice: Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var hasAdvertisedName: Bool
    public var category: DeviceCategory
    public var rawRSSI: Int
    public var smoothedRSSI: Double
    public var txPower: Int?
    public var isConnected: Bool
    public var manufacturerSummary: String?
    public var lastSeen: Date
    public var rssiHistory: [RSSISample]

    public init(
        id: UUID,
        name: String,
        hasAdvertisedName: Bool,
        category: DeviceCategory,
        rawRSSI: Int,
        smoothedRSSI: Double,
        txPower: Int? = nil,
        isConnected: Bool = false,
        manufacturerSummary: String? = nil,
        lastSeen: Date = Date(),
        rssiHistory: [RSSISample] = []
    ) {
        self.id = id
        self.name = name
        self.hasAdvertisedName = hasAdvertisedName
        self.category = category
        self.rawRSSI = rawRSSI
        self.smoothedRSSI = smoothedRSSI
        self.txPower = txPower
        self.isConnected = isConnected
        self.manufacturerSummary = manufacturerSummary
        self.lastSeen = lastSeen
        self.rssiHistory = rssiHistory
    }

    /// Approximate distance in meters using log-distance path loss model.
    public var estimatedDistanceMeters: Double {
        let referencePower = Double(txPower ?? -59)
        let rssi = min(max(smoothedRSSI, -100.0), -25.0)
        let pathLossExponent = 2.2
        let distance = pow(10.0, (referencePower - rssi) / (10.0 * pathLossExponent))
        return min(max(distance, 0.1), 25.0)
    }

    public var formattedDistance: String {
        let d = estimatedDistanceMeters
        if d < 1.0 {
            return String(format: "%.1f m (Immediate)", d)
        } else if d < 3.5 {
            return String(format: "%.1f m (Near)", d)
        } else {
            return String(format: "%.1f m (Far)", d)
        }
    }

    public var signalQualityBars: Int {
        switch smoothedRSSI {
        case -58...0: return 4
        case -68 ..< -58: return 3
        case -78 ..< -68: return 2
        default: return 1
        }
    }
}

// MARK: - Proximity Engine State

public enum ProximityState: Equatable {
    case unconfigured
    case paused(reason: String)
    case unlockedInRange(rssi: Int)
    case gracePeriodCountdown(remainingSeconds: Int, currentRSSI: Int)
    case lockedOutOfRange(lastRSSI: Int?)

    public var title: String {
        switch self {
        case .unconfigured:
            return "No Aura Device Bound"
        case .paused(let reason):
            return "Protection Paused (\(reason))"
        case .unlockedInRange:
            return "Within Aura • Unlocked"
        case .gracePeriodCountdown(let remaining, _):
            return "Leaving Aura • Locking in \(remaining)s"
        case .lockedOutOfRange:
            return "Outside Aura • Mac Locked"
        }
    }

    public var subtitle: String {
        switch self {
        case .unconfigured:
            return "Select an iPhone, Apple Watch, or BLE key in Devices to activate proximity security."
        case .paused(let reason):
            return "Automatic locking and unlocking is suspended: \(reason)."
        case .unlockedInRange(let rssi):
            return "Signal strong at \(rssi) dBm. Your Mac remains unlocked while you are nearby."
        case .gracePeriodCountdown(let remaining, let rssi):
            return "Signal dropped to \(rssi) dBm. Waiting \(remaining)s before locking your Mac."
        case .lockedOutOfRange(let lastRSSI):
            if let rssi = lastRSSI {
                return "Signal at \(rssi) dBm is below threshold. Approaching will automatically wake and unlock."
            } else {
                return "Device signal lost. Approaching with your device will wake and unlock your Mac."
            }
        }
    }

    public var statusSymbol: String {
        switch self {
        case .unconfigured:
            return "sensor.tag.radiowaves.forward"
        case .paused:
            return "pause.circle.fill"
        case .unlockedInRange:
            return "lock.open.rotation"
        case .gracePeriodCountdown:
            return "timer"
        case .lockedOutOfRange:
            return "lock.shield.fill"
        }
    }

    public var badgeColor: Color {
        switch self {
        case .unconfigured:
            return .secondary
        case .paused:
            return .orange
        case .unlockedInRange:
            return Color(red: 0.16, green: 0.86, blue: 0.66)
        case .gracePeriodCountdown:
            return Color(red: 1.0, green: 0.72, blue: 0.20)
        case .lockedOutOfRange:
            return Color(red: 0.98, green: 0.34, blue: 0.44)
        }
    }
}

// MARK: - Presets & Activity Log

public enum ProximityPreset: String, CaseIterable, Identifiable {
    case deskTight = "Desk Focus (1.5m)"
    case standardOffice = "Standard Workspace (3m)"
    case studioRoom = "Studio / Room (5m)"
    case custom = "Custom Calibration"

    public var id: String { rawValue }

    public var unlockRSSI: Double {
        switch self {
        case .deskTight: return -56
        case .standardOffice: return -64
        case .studioRoom: return -70
        case .custom: return -64
        }
    }

    public var lockRSSI: Double {
        switch self {
        case .deskTight: return -68
        case .standardOffice: return -78
        case .studioRoom: return -85
        case .custom: return -78
        }
    }

    public var gracePeriod: Double {
        switch self {
        case .deskTight: return 5
        case .standardOffice: return 8
        case .studioRoom: return 12
        case .custom: return 8
        }
    }

    public var description: String {
        switch self {
        case .deskTight:
            return "Locks quickly as soon as you step away from your desk."
        case .standardOffice:
            return "Balanced hysteresis gap ideal for daily iPhone & Apple Watch use."
        case .studioRoom:
            return "Wider roaming radius so you can move around your room without locking."
        case .custom:
            return "Fine-tuned thresholds configured manually."
        }
    }
}

public struct ActivityLogEntry: Identifiable, Codable, Equatable {
    public enum EventKind: String, Codable, CaseIterable {
        case unlocked = "Unlocked"
        case locked = "Locked"
        case graceStarted = "Grace Timer"
        case graceCancelled = "Grace Cancelled"
        case deviceBound = "Device Bound"
        case permission = "Permissions"
        case systemState = "System Event"
        case diagnostics = "Diagnostics"

        public var symbol: String {
            switch self {
            case .unlocked: return "lock.open.fill"
            case .locked: return "lock.fill"
            case .graceStarted: return "clock.badge.exclamationmark.fill"
            case .graceCancelled: return "arrow.uturn.backward.circle.fill"
            case .deviceBound: return "link.circle.fill"
            case .permission: return "hand.raised.fill"
            case .systemState: return "macbook"
            case .diagnostics: return "waveform.path.ecg"
            }
        }

        public var tintColor: Color {
            switch self {
            case .unlocked: return Color(red: 0.16, green: 0.86, blue: 0.66)
            case .locked: return Color(red: 0.98, green: 0.34, blue: 0.44)
            case .graceStarted: return .orange
            case .graceCancelled: return .cyan
            case .deviceBound: return .indigo
            case .permission: return .purple
            case .systemState: return .blue
            case .diagnostics: return .secondary
            }
        }
    }

    public let id: UUID
    public let timestamp: Date
    public let kind: EventKind
    public let title: String
    public let detail: String
    public let rssi: Int?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: EventKind,
        title: String,
        detail: String,
        rssi: Int? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.title = title
        self.detail = detail
        self.rssi = rssi
    }
}
