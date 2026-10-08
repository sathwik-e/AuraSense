import Foundation

/// Represents the status of the Bluetooth radio adapter.
public enum RadioState: String, Sendable, Codable, CustomStringConvertible {
    case unknown = "Unknown"
    case resetting = "Resetting"
    case unsupported = "Unsupported"
    case unauthorized = "Unauthorized"
    case poweredOff = "Powered Off"
    case poweredOn = "Powered On"

    public var description: String { rawValue }

    public var isAvailable: Bool {
        self == .poweredOn
    }
}

/// Represents the OS Bluetooth authorization status.
public enum AuthorizationStatus: String, Sendable, Codable, CustomStringConvertible {
    case notDetermined = "Not Determined"
    case restricted = "Restricted"
    case denied = "Denied"
    case allowedAlways = "Allowed Always"

    public var description: String { rawValue }

    public var isAuthorized: Bool {
        self == .allowedAlways
    }
}

/// A timestamped RSSI observation.
public struct RSSIReading: Sendable, Codable, Equatable {
    public let rssi: Int
    public let timestamp: Date

    public init(rssi: Int, timestamp: Date = Date()) {
        self.rssi = rssi
        self.timestamp = timestamp
    }
}

/// Parsed advertisement payload from a BLE peripheral.
public struct AdvertisementData: Sendable, Codable, Equatable {
    public let localName: String?
    public let serviceUUIDs: [String]
    public let manufacturerDataHex: String?
    public let txPowerLevel: Int?
    public let isConnectable: Bool

    public init(
        localName: String? = nil,
        serviceUUIDs: [String] = [],
        manufacturerDataHex: String? = nil,
        txPowerLevel: Int? = nil,
        isConnectable: Bool = false
    ) {
        self.localName = localName
        self.serviceUUIDs = serviceUUIDs
        self.manufacturerDataHex = manufacturerDataHex
        self.txPowerLevel = txPowerLevel
        self.isConnectable = isConnectable
    }
}

/// Model of a discovered Bluetooth Low Energy peripheral and its signal history.
public struct DiscoveredPeripheral: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public var name: String?
    public var latestRSSI: Int
    public var firstSeen: Date
    public var lastSeen: Date
    public var advertisementCount: Int
    public var latestAdvertisement: AdvertisementData
    public var rssiHistory: [RSSIReading]

    public init(
        id: UUID,
        name: String? = nil,
        latestRSSI: Int,
        firstSeen: Date = Date(),
        lastSeen: Date = Date(),
        advertisementCount: Int = 1,
        latestAdvertisement: AdvertisementData = AdvertisementData(),
        rssiHistory: [RSSIReading] = []
    ) {
        self.id = id
        self.name = name
        self.latestRSSI = latestRSSI
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.advertisementCount = advertisementCount
        self.latestAdvertisement = latestAdvertisement
        self.rssiHistory = rssiHistory.isEmpty ? [RSSIReading(rssi: latestRSSI, timestamp: lastSeen)] : rssiHistory
    }

    /// Appends a new RSSI reading and updates timestamps, capping history to `maxHistory` samples.
    public mutating func recordReading(rssi: Int, timestamp: Date, advertisement: AdvertisementData?, maxHistory: Int = 50) {
        self.latestRSSI = rssi
        self.lastSeen = timestamp
        self.advertisementCount += 1
        if let advertisement = advertisement {
            self.latestAdvertisement = advertisement
            if let newName = advertisement.localName, !newName.isEmpty {
                self.name = newName
            }
        }
        self.rssiHistory.append(RSSIReading(rssi: rssi, timestamp: timestamp))
        if self.rssiHistory.count > maxHistory {
            self.rssiHistory.removeFirst(self.rssiHistory.count - maxHistory)
        }
    }

    /// Recent average RSSI across recorded history.
    public var averageRSSI: Double {
        guard !rssiHistory.isEmpty else { return Double(latestRSSI) }
        let sum = rssiHistory.reduce(0) { $0 + $1.rssi }
        return Double(sum) / Double(rssiHistory.count)
    }

    /// Approximate packet rate in advertisements per second over the last observation window.
    public var packetRatePerSecond: Double {
        guard rssiHistory.count > 1,
              let firstTime = rssiHistory.first?.timestamp,
              let lastTime = rssiHistory.last?.timestamp else {
            return 0.0
        }
        let elapsed = lastTime.timeIntervalSince(firstTime)
        guard elapsed > 0.05 else { return 0.0 }
        return Double(rssiHistory.count - 1) / elapsed
    }
}
