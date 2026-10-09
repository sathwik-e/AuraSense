import Foundation

/// Coordinates Bluetooth failure detection and automatic recovery.
public final class BluetoothRecoveryCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    public let scanner: any BLEScannerProtocol
    public let proximityEngine: ProximityEngine
    public let actionExecutor: ActionExecutor?

    private var _lastRecoveryTime: Date?
    private var _recoveryAttemptsCount: Int = 0

    public var recoveryAttemptsCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _recoveryAttemptsCount
    }

    public var onRecoverySuccess: (@Sendable () -> Void)?
    public var onRadioInterruption: (@Sendable (RadioState) -> Void)?

    public init(
        scanner: any BLEScannerProtocol,
        proximityEngine: ProximityEngine,
        actionExecutor: ActionExecutor? = nil
    ) {
        self.scanner = scanner
        self.proximityEngine = proximityEngine
        self.actionExecutor = actionExecutor
    }

    /// Handles a radio state change and triggers automatic recovery when radio returns to poweredOn.
    public func handleRadioStateChange(_ newState: RadioState) {
        lock.lock()
        defer { lock.unlock() }

        if newState.isAvailable {
            // Radio recovered!
            _recoveryAttemptsCount += 1
            _lastRecoveryTime = Date()

            proximityEngine.filter.reset()
            proximityEngine.updateScannerHealth(isHealthy: true, reason: "Bluetooth radio recovered: \(newState.rawValue)")

            // Automatically restart scanning if permitted
            if scanner.authorizationStatus.canScan {
                try? scanner.startScanning(serviceUUIDs: nil)
            }
            onRecoverySuccess?()
        } else {
            // Radio interrupted / unavailable: cancel countdown and invalidate pending actions first (Finding 19)
            proximityEngine.cancelActiveCountdown(reason: "Bluetooth radio failure: \(newState.rawValue)")
            proximityEngine.updateScannerHealth(isHealthy: false, reason: "Bluetooth radio failure: \(newState.rawValue)")
            actionExecutor?.invalidate(reason: "Bluetooth radio failure: \(newState.rawValue)")
            onRadioInterruption?(newState)
        }
    }

    /// Handles system wake event by resetting stale signal memory and verifying scan continuity.
    public func handleSystemWake() {
        lock.lock()
        defer { lock.unlock() }

        proximityEngine.filter.reset()
        actionExecutor?.invalidate(reason: "System wake from sleep")
        if scanner.radioState.isAvailable && scanner.authorizationStatus.canScan {
            proximityEngine.updateScannerHealth(isHealthy: true, reason: "Recovery after system wake")
            try? scanner.startScanning(serviceUUIDs: nil)
        }
    }

    /// Handles system sleep event by cancelling active departure countdowns and marking health lost.
    public func handleSystemSleep() {
        lock.lock()
        defer { lock.unlock() }

        scanner.stopScanning()
        proximityEngine.cancelActiveCountdown(reason: "System entering sleep mode")
        proximityEngine.updateScannerHealth(isHealthy: false, reason: "System sleep")
        actionExecutor?.invalidate(reason: "System sleep")
    }
}
