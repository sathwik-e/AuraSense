import Foundation

/// Delegate receiving callbacks when Bluetooth state or discovered peripherals change.
public protocol BLEScannerDelegate: AnyObject, Sendable {
    func scannerDidChangeRadioState(_ state: RadioState)
    func scannerDidDiscover(peripheral: DiscoveredPeripheral)
    func scannerDidUpdateRSSI(peripheralID: UUID, rssi: Int, timestamp: Date)
    func scannerDidEncounterError(_ error: Error)
}

/// Errors originating from Bluetooth operations.
public enum BLEScannerError: LocalizedError, Sendable {
    case radioNotPoweredOn(RadioState)
    case unauthorized(AuthorizationStatus)
    case scannerAlreadyRunning
    case peripheralNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .radioNotPoweredOn(let state):
            return "Bluetooth radio is not ready (current state: \(state.description))."
        case .unauthorized(let status):
            return "Bluetooth access is unauthorized (current authorization: \(status.description))."
        case .scannerAlreadyRunning:
            return "Bluetooth scanner is already actively scanning."
        case .peripheralNotFound(let id):
            return "Bluetooth peripheral with ID \(id.uuidString) was not found."
        }
    }
}

/// Abstract contract for Bluetooth Low Energy scanning.
public protocol BLEScannerProtocol: AnyObject, Sendable {
    var radioState: RadioState { get }
    var authorizationStatus: AuthorizationStatus { get }
    var isScanning: Bool { get }
    var delegate: (any BLEScannerDelegate)? { get set }

    /// Starts scanning for nearby BLE peripherals.
    /// - Parameter serviceUUIDs: Optional list of CBUUID strings to filter by. If nil or empty, scans all available peripherals.
    func startScanning(serviceUUIDs: [String]?) throws

    /// Stops BLE scanning.
    func stopScanning()
}

public extension BLEScannerProtocol {
    func startScanning() throws {
        try startScanning(serviceUUIDs: nil)
    }
}
