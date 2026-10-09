import Foundation
import CoreBluetooth

/// Production BLE Scanner backed by Apple's CoreBluetooth framework.
public final class CoreBluetoothScanner: NSObject, BLEScannerProtocol, @unchecked Sendable {
    private let queue: DispatchQueue
    private var centralManager: CBCentralManager?
    private let lock = NSLock()

    private var _radioState: RadioState = .unknown
    private var _isScanning: Bool = false
    private var _isMonitoringRequested: Bool = false
    private var _targetServiceUUIDs: [CBUUID]?
    private var radioStatePoll: DispatchSourceTimer?

    public weak var delegate: (any BLEScannerDelegate)?

    public var radioState: RadioState {
        lock.lock()
        defer { lock.unlock() }
        return _radioState
    }

    public var isMonitoringRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isMonitoringRequested
    }

    public var authorizationStatus: AuthorizationStatus {
        #if os(macOS)
        switch CBCentralManager.authorization {
        case .allowedAlways:
            return .allowedAlways
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
        #else
        return .allowedAlways
        #endif
    }

    public var isScanning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isScanning
    }

    public init(queue: DispatchQueue = .main) {
        self.queue = queue
        super.init()
    }

    public func startScanning(serviceUUIDs: [String]? = nil) throws {
        lock.lock()
        defer { lock.unlock() }

        if centralManager == nil {
            centralManager = CBCentralManager(
                delegate: self,
                queue: queue,
                options: [CBCentralManagerOptionShowPowerAlertKey: false]
            )
        }

        if let centralManager {
            switch centralManager.state {
            case .poweredOn: _radioState = .poweredOn
            case .poweredOff: _radioState = .poweredOff
            case .unauthorized: _radioState = .unauthorized
            case .unsupported: _radioState = .unsupported
            case .resetting: _radioState = .resetting
            case .unknown: _radioState = .unknown
            @unknown default: _radioState = .unknown
            }
        }

        // Validate authorization BEFORE setting monitoring intent (Finding 17)
        // Do not set requested state if we know it will be denied
        if _radioState == .unauthorized || authorizationStatus == .denied || authorizationStatus == .restricted {
            // Clear any stale intent — do not auto-start after a denied attempt
            _isMonitoringRequested = false
            throw BLEScannerError.unauthorized(authorizationStatus)
        }

        let mappedUUIDs: [CBUUID]? = serviceUUIDs?.compactMap {
            UUID(uuidString: $0) != nil || $0.count == 4 ? CBUUID(string: $0) : nil
        }
        self._targetServiceUUIDs = mappedUUIDs

        // Only set intent after authorization is confirmed/unknown
        self._isMonitoringRequested = true

        if _radioState == .poweredOn {
            if authorizationStatus.canScan || authorizationStatus == .notDetermined {
                self.beginScanUnderLock()
            } else {
                // Authorization check failed at this point — clear intent
                _isMonitoringRequested = false
                throw BLEScannerError.unauthorized(authorizationStatus)
            }
        } else if _radioState == .unknown || _radioState == .resetting {
            scheduleRadioStatePollUnderLock()
        }
        // For other radio states (unknown, resetting), intent is set and will start when powered on
    }

    public func stopScanning() {
        lock.lock()
        defer { lock.unlock() }
        _isMonitoringRequested = false
        radioStatePoll?.cancel()
        radioStatePoll = nil
        if _isScanning {
            centralManager?.stopScan()
            _isScanning = false
        }
    }

    private func beginScanUnderLock() {
        guard let central = centralManager, central.state == .poweredOn else { return }
        guard !_isScanning else { return }
        let options: [String: Any] = [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ]
        central.scanForPeripherals(withServices: _targetServiceUUIDs, options: options)
        _isScanning = true
    }

    private func scheduleRadioStatePollUnderLock() {
        guard radioStatePoll == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self._isMonitoringRequested, let central = self.centralManager else {
                self.radioStatePoll?.cancel()
                self.radioStatePoll = nil
                self.lock.unlock()
                return
            }

            let state: RadioState
            switch central.state {
            case .poweredOn: state = .poweredOn
            case .poweredOff: state = .poweredOff
            case .unauthorized: state = .unauthorized
            case .unsupported: state = .unsupported
            case .resetting: state = .resetting
            case .unknown: state = .unknown
            @unknown default: state = .unknown
            }
            let stateChanged = self._radioState != state
            self._radioState = state
            if state == .poweredOn && (self.authorizationStatus.canScan || self.authorizationStatus == .notDetermined) {
                self.beginScanUnderLock()
                self.radioStatePoll?.cancel()
                self.radioStatePoll = nil
            } else if state == .poweredOff || state == .unauthorized || state == .unsupported {
                self.radioStatePoll?.cancel()
                self.radioStatePoll = nil
            }
            self.lock.unlock()
            if stateChanged {
                self.delegate?.scannerDidChangeRadioState(state)
            }
        }
        radioStatePoll = timer
        timer.resume()
    }

    private func parseAdvertisement(from dict: [String: Any], peripheralName: String?) -> AdvertisementData {
        let localName = (dict[CBAdvertisementDataLocalNameKey] as? String) ?? peripheralName
        let rawUUIDs = dict[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let serviceUUIDStrings = rawUUIDs.map { $0.uuidString }

        let manufacturerDataHex: String?
        if let data = dict[CBAdvertisementDataManufacturerDataKey] as? Data {
            manufacturerDataHex = data.map { String(format: "%02x", $0) }.joined()
        } else {
            manufacturerDataHex = nil
        }

        let txPower = (dict[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue
        let isConnectable = (dict[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? false

        return AdvertisementData(
            localName: localName,
            serviceUUIDs: serviceUUIDStrings,
            manufacturerDataHex: manufacturerDataHex,
            txPowerLevel: txPower,
            isConnectable: isConnectable
        )
    }
}

// MARK: - CBCentralManagerDelegate
extension CoreBluetoothScanner: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let newState: RadioState
        switch central.state {
        case .poweredOn:
            newState = .poweredOn
        case .poweredOff:
            newState = .poweredOff
        case .unauthorized:
            newState = .unauthorized
        case .unsupported:
            newState = .unsupported
        case .resetting:
            newState = .resetting
        case .unknown:
            newState = .unknown
        @unknown default:
            newState = .unknown
        }

        lock.lock()
        _radioState = newState
        if newState == .poweredOn || newState == .poweredOff || newState == .unauthorized || newState == .unsupported {
            radioStatePoll?.cancel()
            radioStatePoll = nil
        }
        if newState == .unauthorized || authorizationStatus == .denied || authorizationStatus == .restricted {
            _isMonitoringRequested = false
            if _isScanning {
                central.stopScan()
                _isScanning = false
            }
        } else if newState == .poweredOn {
            if _isMonitoringRequested && !_isScanning &&
                (authorizationStatus.canScan || authorizationStatus == .notDetermined) {
                beginScanUnderLock()
            }
        } else {
            // Radio no longer poweredOn: explicitly stop scan on central
            if _isScanning {
                central.stopScan()
                _isScanning = false
            }
        }
        lock.unlock()

        delegate?.scannerDidChangeRadioState(newState)
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        let rssiValue = RSSI.intValue
        // Reject invalid/zero/dummy RSSI readings (-120 dBm to 0 dBm only)
        guard rssiValue >= -120 && rssiValue <= 0 else { return }

        let parsedAd = parseAdvertisement(from: advertisementData, peripheralName: peripheral.name)
        let now = Date()

        let discovered = DiscoveredPeripheral(
            id: peripheral.identifier,
            name: parsedAd.localName ?? peripheral.name,
            latestRSSI: rssiValue,
            firstSeen: now,
            lastSeen: now,
            advertisementCount: 1,
            latestAdvertisement: parsedAd,
            rssiHistory: [RSSIReading(rssi: rssiValue, timestamp: now)]
        )

        delegate?.scannerDidDiscover(peripheral: discovered)
    }
}
