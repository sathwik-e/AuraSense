import Foundation
import CoreBluetooth

/// Production BLE Scanner backed by Apple's CoreBluetooth framework.
public final class CoreBluetoothScanner: NSObject, BLEScannerProtocol, @unchecked Sendable {
    private let queue: DispatchQueue
    private var centralManager: CBCentralManager?
    private let lock = NSLock()

    private var _radioState: RadioState = .unknown
    private var _isScanning: Bool = false
    private var _autoStartWhenReady: Bool = false
    private var _targetServiceUUIDs: [CBUUID]?

    public weak var delegate: (any BLEScannerDelegate)?

    public var radioState: RadioState {
        lock.lock()
        defer { lock.unlock() }
        return _radioState
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

    public init(queue: DispatchQueue = DispatchQueue(label: "com.aurasense.ble.scanner", qos: .userInitiated)) {
        self.queue = queue
        super.init()
        self.centralManager = CBCentralManager(
            delegate: self,
            queue: self.queue,
            options: [CBCentralManagerOptionShowPowerAlertKey: false]
        )
    }

    public func startScanning(serviceUUIDs: [String]? = nil) throws {
        lock.lock()
        defer { lock.unlock() }

        let mappedUUIDs: [CBUUID]? = serviceUUIDs?.compactMap {
            UUID(uuidString: $0) != nil || $0.count == 4 ? CBUUID(string: $0) : nil
        }
        self._targetServiceUUIDs = mappedUUIDs

        if _radioState == .poweredOn {
            self.beginScanUnderLock()
        } else if _radioState == .unauthorized {
            throw BLEScannerError.unauthorized(authorizationStatus)
        } else {
            // Radio state not ready yet (e.g. initial .unknown or .resetting). Flag auto-start when poweredOn.
            _autoStartWhenReady = true
        }
    }

    public func stopScanning() {
        lock.lock()
        defer { lock.unlock() }
        _autoStartWhenReady = false
        if _isScanning {
            centralManager?.stopScan()
            _isScanning = false
        }
    }

    private func beginScanUnderLock() {
        guard let central = centralManager, central.state == .poweredOn else { return }
        let options: [String: Any] = [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ]
        central.scanForPeripherals(withServices: _targetServiceUUIDs, options: options)
        _isScanning = true
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
        if newState == .poweredOn && _autoStartWhenReady && !_isScanning {
            beginScanUnderLock()
        } else if newState != .poweredOn && _isScanning {
            _isScanning = false
        }
        lock.unlock()

        delegate?.scannerDidChangeRadioState(newState)
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        let rssiValue = RSSI.intValue
        // Reject invalid/zero/dummy RSSI readings
        guard rssiValue != 127 else { return }

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
