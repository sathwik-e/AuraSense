import Foundation

/// Simulated BLE Scanner for unit testing and deterministic scenario validation.
public final class MockBLEScanner: BLEScannerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _radioState: RadioState
    private var _authorizationStatus: AuthorizationStatus
    private var _isScanning: Bool = false
    private var _isMonitoringRequested: Bool = false

    public weak var delegate: (any BLEScannerDelegate)?

    public var radioState: RadioState {
        lock.lock()
        defer { lock.unlock() }
        return _radioState
    }

    public var authorizationStatus: AuthorizationStatus {
        lock.lock()
        defer { lock.unlock() }
        return _authorizationStatus
    }

    public var isScanning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isScanning
    }

    public var isMonitoringRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isMonitoringRequested
    }

    public init(
        initialRadioState: RadioState = .poweredOn,
        initialAuthorization: AuthorizationStatus = .allowedAlways
    ) {
        self._radioState = initialRadioState
        self._authorizationStatus = initialAuthorization
    }

    public func startScanning(serviceUUIDs: [String]? = nil) throws {
        lock.lock()
        defer { lock.unlock() }

        // Finding 17: Validate authorization before recording monitoring intent
        guard _authorizationStatus.isAuthorized else {
            _isMonitoringRequested = false
            throw BLEScannerError.unauthorized(_authorizationStatus)
        }

        _isMonitoringRequested = true

        guard _radioState == .poweredOn else {
            throw BLEScannerError.radioNotPoweredOn(_radioState)
        }
        _isScanning = true
    }

    public func stopScanning() {
        lock.lock()
        defer { lock.unlock() }
        _isMonitoringRequested = false
        _isScanning = false
    }

    // MARK: - Simulation Control

    public func simulateRadioStateChange(_ newState: RadioState) {
        lock.lock()
        _radioState = newState
        if newState == .poweredOn {
            if _isMonitoringRequested && _authorizationStatus.isAuthorized {
                _isScanning = true
            }
        } else {
            _isScanning = false
        }
        lock.unlock()
        delegate?.scannerDidChangeRadioState(newState)
    }

    public func simulateAuthorizationChange(_ newStatus: AuthorizationStatus) {
        lock.lock()
        _authorizationStatus = newStatus
        if !newStatus.isAuthorized {
            _isMonitoringRequested = false
            _isScanning = false
        }
        lock.unlock()
    }

    public func simulatePeripheralDiscovery(
        id: UUID = UUID(),
        name: String? = "Simulated Device",
        rssi: Int = -65,
        services: [String] = [],
        timestamp: Date = Date()
    ) -> DiscoveredPeripheral {
        let ad = AdvertisementData(
            localName: name,
            serviceUUIDs: services,
            manufacturerDataHex: "4c000215",
            txPowerLevel: 0,
            isConnectable: true
        )
        let peripheral = DiscoveredPeripheral(
            id: id,
            name: name,
            latestRSSI: rssi,
            firstSeen: timestamp,
            lastSeen: timestamp,
            advertisementCount: 1,
            latestAdvertisement: ad,
            rssiHistory: [RSSIReading(rssi: rssi, timestamp: timestamp)]
        )

        delegate?.scannerDidDiscover(peripheral: peripheral)
        return peripheral
    }

    public func simulateRSSIUpdate(peripheralID: UUID, rssi: Int, timestamp: Date = Date()) {
        delegate?.scannerDidUpdateRSSI(peripheralID: peripheralID, rssi: rssi, timestamp: timestamp)
    }
}
