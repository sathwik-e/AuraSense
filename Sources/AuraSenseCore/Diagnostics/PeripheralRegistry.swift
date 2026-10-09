import Foundation

/// Liveness indicator of a discovered peripheral based on time elapsed since last advertisement.
public enum PeripheralLiveness: String, Sendable, Codable {
    case active = "Active"
    case stale = "Stale"
    case lost = "Lost"
}

/// Diagnostic snapshot of a tracked peripheral.
public struct PeripheralDiagnosticsRecord: Sendable, Identifiable, Codable {
    public let id: UUID
    public let name: String?
    public let latestRSSI: Int
    public let averageRSSI: Double
    public let minRSSI: Int
    public let maxRSSI: Int
    public let firstSeen: Date
    public let lastSeen: Date
    public let secondsSinceLastSeen: Double
    public let packetCount: Int
    public let liveness: PeripheralLiveness
    public let serviceUUIDs: [String]
    public let isConnectable: Bool

    public init(from peripheral: DiscoveredPeripheral, referenceDate: Date = Date()) {
        self.id = peripheral.id
        self.name = peripheral.name
        self.latestRSSI = peripheral.latestRSSI
        self.averageRSSI = peripheral.averageRSSI

        let rssiValues = peripheral.rssiHistory.map { $0.rssi }
        self.minRSSI = rssiValues.min() ?? peripheral.latestRSSI
        self.maxRSSI = rssiValues.max() ?? peripheral.latestRSSI

        self.firstSeen = peripheral.firstSeen
        self.lastSeen = peripheral.lastSeen
        let elapsed = max(0, referenceDate.timeIntervalSince(peripheral.lastSeen))
        self.secondsSinceLastSeen = (elapsed * 10).rounded() / 10

        if elapsed < 10.0 {
            self.liveness = .active
        } else if elapsed < 30.0 {
            self.liveness = .stale
        } else {
            self.liveness = .lost
        }

        self.packetCount = peripheral.advertisementCount
        self.serviceUUIDs = peripheral.latestAdvertisement.serviceUUIDs
        self.isConnectable = peripheral.latestAdvertisement.isConnectable
    }
}

/// Thread-safe registry that stores and analyzes discovered BLE peripherals.
public final class PeripheralRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var peripherals: [UUID: DiscoveredPeripheral] = [:]

    public init() {}

    /// Registers or updates a discovered peripheral.
    public func registerOrUpdate(_ discovered: DiscoveredPeripheral) {
        lock.lock()
        defer { lock.unlock() }

        if var existing = peripherals[discovered.id] {
            existing.recordReading(
                rssi: discovered.latestRSSI,
                timestamp: discovered.lastSeen,
                advertisement: discovered.latestAdvertisement
            )
            peripherals[discovered.id] = existing
        } else {
            peripherals[discovered.id] = discovered
        }
    }

    /// Updates only the RSSI and timestamp for an existing or new peripheral.
    public func updateRSSI(peripheralID: UUID, rssi: Int, timestamp: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }

        if var existing = peripherals[peripheralID] {
            existing.recordReading(rssi: rssi, timestamp: timestamp, advertisement: nil)
            peripherals[peripheralID] = existing
        } else {
            let newPeripheral = DiscoveredPeripheral(
                id: peripheralID,
                name: nil,
                latestRSSI: rssi,
                firstSeen: timestamp,
                lastSeen: timestamp,
                advertisementCount: 1,
                latestAdvertisement: AdvertisementData(),
                rssiHistory: [RSSIReading(rssi: rssi, timestamp: timestamp)]
            )
            peripherals[peripheralID] = newPeripheral
        }
    }

    /// Returns a specific peripheral if registered.
    public func peripheral(for id: UUID) -> DiscoveredPeripheral? {
        lock.lock()
        defer { lock.unlock() }
        return peripherals[id]
    }

    /// Returns all registered peripherals.
    public func allPeripherals() -> [DiscoveredPeripheral] {
        lock.lock()
        defer { lock.unlock() }
        return Array(peripherals.values)
    }

    /// Returns only active peripherals seen within the specified timeout window (default: 15 seconds).
    /// Used for authoritative identity ambiguity checks to ignore disappeared devices.
    public func activePeripherals(timeout: TimeInterval = 15.0, referenceDate: Date = Date()) -> [DiscoveredPeripheral] {
        lock.lock()
        defer { lock.unlock() }
        return peripherals.values.filter { peripheral in
            referenceDate.timeIntervalSince(peripheral.lastSeen) <= timeout
        }
    }

    /// Purges stale peripherals that have not been seen for longer than the specified threshold.
    @discardableResult
    public func purgeStalePeripherals(olderThan: TimeInterval = 60.0, referenceDate: Date = Date()) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let initialCount = peripherals.count
        peripherals = peripherals.filter { _, p in
            referenceDate.timeIntervalSince(p.lastSeen) <= olderThan
        }
        return initialCount - peripherals.count
    }

    /// Total count of registered peripherals.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return peripherals.count
    }

    /// Generates diagnostic records for all peripherals sorted by strongest RSSI.
    public func diagnosticsRecords(referenceDate: Date = Date()) -> [PeripheralDiagnosticsRecord] {
        lock.lock()
        let items = Array(peripherals.values)
        lock.unlock()

        return items
            .map { PeripheralDiagnosticsRecord(from: $0, referenceDate: referenceDate) }
            .sorted { $0.latestRSSI > $1.latestRSSI }
    }

    /// Resets all registered peripherals.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        peripherals.removeAll()
    }
}
