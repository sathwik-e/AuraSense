import Foundation
import CoreBluetooth
import SwiftUI
import ServiceManagement

/// Core Bluetooth Low Energy proximity engine that discovers nearby BLE peripherals,
/// tracks the bound Aura device's RSSI using a 1D Kalman + EMA filter, runs the 10-second
/// Desk Signal Calibration optimizer, and orchestrates automatic macOS locking, external
/// monitor input waking, and Accessibility unlocking.
@MainActor
public final class BLEProximityEngine: NSObject, ObservableObject {
    public static let shared = BLEProximityEngine()

    /// Minimum hysteresis deadband (dB) between the Unlock and Lock thresholds.
    public static let minimumHysteresisGapDB: Double = 6.0

    // MARK: - Persisted User Configuration

    @AppStorage("aurasense.monitoringEnabled") public var monitoringEnabled: Bool = true {
        didSet { evaluateProximityState() }
    }
    @AppStorage("aurasense.selectedDeviceID") public var selectedDeviceID: String = "" {
        didSet { evaluateProximityState() }
    }
    @AppStorage("aurasense.selectedDeviceName") public var selectedDeviceName: String = ""
    @AppStorage("aurasense.selectedDeviceCategory") public var selectedDeviceCategoryRaw: String = DeviceCategory.iPhone.rawValue

    @AppStorage("aurasense.unlockThresholdRSSI") public var unlockThresholdRSSI: Double = -62.0 {
        didSet {
            let minGap = Self.minimumHysteresisGapDB
            if lockThresholdRSSI > unlockThresholdRSSI - minGap {
                lockThresholdRSSI = unlockThresholdRSSI - minGap
            }
            evaluateProximityState()
        }
    }
    @AppStorage("aurasense.lockThresholdRSSI") public var lockThresholdRSSI: Double = -76.0 {
        didSet {
            let minGap = Self.minimumHysteresisGapDB
            if lockThresholdRSSI > unlockThresholdRSSI - minGap {
                unlockThresholdRSSI = lockThresholdRSSI + minGap
            }
            evaluateProximityState()
        }
    }
    @AppStorage("aurasense.notedDeskRSSI") public var notedDeskRSSI: Int = -56
    @AppStorage("aurasense.hasNotedDeskRSSI") public var hasNotedDeskRSSI: Bool = false
    @AppStorage("aurasense.notedDeskJitterDB") public var notedDeskJitterDB: Double = 2.1

    @AppStorage("aurasense.lockGracePeriodSeconds") public var lockGracePeriodSeconds: Double = 8.0
    @AppStorage("aurasense.unlockCooldownSeconds") public var unlockCooldownSeconds: Double = 5.0
    @AppStorage("aurasense.signalLossTimeoutSeconds") public var signalLossTimeoutSeconds: Double = 15.0
    @AppStorage("aurasense.smoothingFactor") public var smoothingFactor: Double = 0.32
    @AppStorage("aurasense.autoUnlockEnabled") public var autoUnlockEnabled: Bool = true
    @AppStorage("aurasense.autoLockEnabled") public var autoLockEnabled: Bool = true {
        didSet {
            if !autoLockEnabled {
                cancelGracePeriod(reason: "Auto-lock disabled")
            }
            evaluateProximityState()
        }
    }
    @AppStorage("aurasense.sleepDisplayOnLock") public var sleepDisplayOnLock: Bool = false
    @AppStorage("aurasense.wakeDisplayOnApproach") public var wakeDisplayOnApproach: Bool = true
    @AppStorage("aurasense.playSoundEffects") public var playSoundEffects: Bool = true
    @AppStorage("aurasense.onlyShowNamedDevices") public var onlyShowNamedDevices: Bool = false
    /// Mirrors `SMAppService.mainApp.status == .enabled`; only written by `syncLaunchAtLoginStatus()`.
    @AppStorage("aurasense.launchAtLogin") public var launchAtLogin: Bool = false
    @AppStorage("aurasense.v101.hasCompletedGuidedSetup") public var hasCompletedOnboarding: Bool = false

    /// True only when the bound (real, non-simulated) device has been heard within
    /// `signalLossTimeoutSeconds` and its smoothed signal is at or above the lock threshold.
    public var isBoundDevicePresent: Bool {
        guard let device = boundRecord, !boundSignalLost else { return false }
        return isFresh(device) && device.smoothedRSSI >= lockThresholdRSSI
    }

    // MARK: - Published Runtime State

    @Published public private(set) var bluetoothState: CBManagerState = .unknown
    @Published public private(set) var discoveredDevices: [BLEDevice] = []
    /// The device shown in the UI: the bound device, or the in-memory simulated device while Sim Mode is on.
    /// Lock/unlock decisions never read this; they use the real bound device record.
    @Published public private(set) var trackedDevice: BLEDevice?
    @Published public private(set) var proximityState: ProximityState = .unconfigured
    @Published public private(set) var activityLog: [ActivityLogEntry] = []
    @Published public private(set) var isScanning: Bool = false
    @Published public private(set) var pauseUntilDate: Date? = nil

    // MARK: - 10-Second Desk Signal Calibration State

    @Published public private(set) var isCalibratingDeskSignal: Bool = false
    @Published public private(set) var deskCalibrationProgress: Double = 0.0
    @Published public private(set) var deskCalibrationRemainingSeconds: Int = 10
    @Published public private(set) var deskCalibrationSamplesCollected: Int = 0
    @Published public private(set) var deskCalibrationSummary: String = "Place your device on the desk and run a 10-second scan to record its baseline dBm and auto-optimize thresholds."

    // Interactive Simulation Mode (visual preview only). The simulated device lives in memory,
    // is never persisted or bound, and never drives real lock/unlock or the presence gate.
    @Published public var isSimulationMode: Bool = false {
        didSet {
            guard isSimulationMode != oldValue else { return }
            if isSimulationMode {
                // Simulated RSSI must never feed a calibration that persists real thresholds.
                if isCalibratingDeskSignal {
                    cancelDeskCalibration()
                }
                setupSimulatedDeviceIfNeeded()
                applySimulatedRSSI(Int(simulatedRSSI))
                appendLog(
                    kind: .diagnostics,
                    title: "Simulation Preview On",
                    detail: "Simulated RSSI only moves the radar preview; real lock/unlock keeps following your bound device."
                )
            } else {
                teardownSimulatedDevice()
                evaluateProximityState()
            }
        }
    }
    @Published public var simulatedRSSI: Double = -54.0 {
        didSet {
            if isSimulationMode {
                applySimulatedRSSI(Int(simulatedRSSI))
            }
        }
    }

    // MARK: - Internal Properties

    private static let staleDeviceAgeSeconds: TimeInterval = 120
    private static let maxDiscoveredDevices = 100
    private static let deviceListPublishInterval: TimeInterval = 1.0
    private static let minimumCalibrationSamples = 10
    private static let maxConsecutiveUnlockFailures = 2

    private var centralManager: CBCentralManager!
    private var peripheralMap: [UUID: CBPeripheral] = [:]
    private var kalmanFilters: [UUID: KalmanRSSIFilter] = [:]
    /// Source of truth for discovered devices; `discoveredDevices` is a throttled, sorted snapshot.
    private var deviceStore: [UUID: BLEDevice] = [:]
    private var deviceListDirty = false
    private var lastDeviceListPublish: Date = .distantPast
    private var connectedPollTimer: Timer?
    private var watchdogTimer: Timer?
    private var graceCountdownTimer: Timer?
    private var deskCalibrationTimer: Timer?
    private var deskCalibrationBuffer: [Double] = []
    private var deskCalibrationTicks: Int = 0
    private var graceRemainingSeconds: Int = 0
    private var lastUnlockTriggerDate: Date = .distantPast
    private var lastAutoLockDate: Date = .distantPast
    private var lastManualLockDate: Date = .distantPast
    private let engineStartDate = Date()

    /// Set when the bound device has not been heard for `signalLossTimeoutSeconds`; cleared on the next real reading.
    private var boundSignalLost = false
    /// False after a manual lock: auto-unlock waits until the bound device has left (≤ lock threshold or signal loss).
    private var autoUnlockArmed = true
    /// False after an auto-lock: no further auto-lock until the bound device has returned (≥ unlock threshold).
    private var autoLockArmed = true
    private var unlockAttemptInFlight = false
    private var consecutiveUnlockFailures = 0
    private var autoUnlockSuspended = false
    private var nextUnlockAllowedDate: Date = .distantPast
    /// Suppresses the `selectedDeviceID` didSet evaluation while a bind/unbind is being applied.
    private var isApplyingBinding = false
    /// Authoritative trusted-device binding (Keychain-backed). UserDefaults is restored from this
    /// whenever it is changed outside the password-gated bind/unbind flow.
    private var trustedRecord: TrustedDeviceRecord?

    private var simulatedDeviceID: UUID?
    private var simulatedDevice: BLEDevice?
    private var notificationObservers: [NSObjectProtocol] = []

    private override init() {
        super.init()
        loadInitialActivityLog()
        centralManager = CBCentralManager(delegate: nil, queue: .main, options: [
            CBCentralManagerOptionShowPowerAlertKey: true
        ])
        centralManager.delegate = self
        loadTrustedBinding()
        syncLaunchAtLoginStatus()
        observeSystemNotifications()
        startTimers()
        evaluateProximityState()
    }

    // MARK: - Tamper-Resistant Binding

    private func loadTrustedBinding() {
        if let record = TrustedDeviceRecordStore.load() {
            trustedRecord = record
        } else if UUID(uuidString: selectedDeviceID) != nil {
            // Upgrade from a version without the Keychain record: adopt the existing binding.
            let record = TrustedDeviceRecord(id: selectedDeviceID, name: selectedDeviceName, category: selectedDeviceCategoryRaw)
            trustedRecord = record
            TrustedDeviceRecordStore.save(record)
        } else {
            trustedRecord = nil
        }
        enforceTrustedBinding()
    }

    /// Restores UserDefaults from the authoritative record if something outside AuraSense changed
    /// it (e.g. `defaults write/delete`), so the trusted device can't be swapped without the Mac password.
    private func enforceTrustedBinding() {
        let expectedID = trustedRecord?.id ?? ""
        guard selectedDeviceID != expectedID else { return }
        let tamperedValue = selectedDeviceID
        isApplyingBinding = true
        selectedDeviceID = expectedID
        selectedDeviceName = trustedRecord?.name ?? ""
        if let category = trustedRecord?.category {
            selectedDeviceCategoryRaw = category
        }
        isApplyingBinding = false
        refreshTrackedDevice()
        appendLog(
            kind: .permission,
            title: "Trusted Device Setting Restored",
            detail: "The saved trusted device was changed outside AuraSense (to “\(tamperedValue.isEmpty ? "none" : String(tamperedValue.prefix(8)) + "…")”). It was restored; changing it requires your Mac password."
        )
    }

    /// The CBCentralManager created in `init` already triggers the system Bluetooth prompt.
    /// Recreating it would orphan known peripherals and pending connections, so this only
    /// (re)starts scanning when Bluetooth is available.
    public func promptForBluetoothPermission() {
        if centralManager.state == .poweredOn {
            startScanning()
            reacquireBoundPeripheral()
        } else {
            appendLog(
                kind: .permission,
                title: "Bluetooth Not Ready",
                detail: "\(bluetoothStateDescription). Allow AuraSense under System Settings → Privacy & Security → Bluetooth."
            )
        }
    }

    private func observeSystemNotifications() {
        let center = NotificationCenter.default
        notificationObservers.append(center.addObserver(
            forName: KeychainManager.passwordDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.resetAutoUnlockFailures(reason: "Stored password changed")
            }
        })
        notificationObservers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.syncLaunchAtLoginStatus()
            }
        })
    }

    // MARK: - 10-Second Desk Signal Calibration Optimizer

    /// Runs a 10.0-second high-frequency BLE RSSI scan while the user's device sits on their desk.
    /// Notes the exact desk signal strength (mean, median, and standard deviation σ) and automatically
    /// optimizes Unlock RSSI, Lock RSSI, Kalman/EMA smoothing, and Grace Period.
    public func startTenSecondDeskCalibration() {
        guard !isCalibratingDeskSignal else { return }
        // Simulated RSSI must never overwrite the real, persisted thresholds.
        guard !isSimulationMode else {
            deskCalibrationSummary = "Turn off Sim Mode first: calibration needs real readings from your device."
            return
        }

        // Calibration never binds anything: the trusted device must be chosen explicitly.
        guard !selectedDeviceID.isEmpty else {
            deskCalibrationSummary = "Bind your device first: choose your iPhone or Apple Watch in Devices, then run the desk calibration."
            appendLog(
                kind: .diagnostics,
                title: "Desk Calibration Needs a Bound Device",
                detail: "No trusted device is bound. Bind your device in Devices before calibrating."
            )
            return
        }

        startScanning()
        deskCalibrationTimer?.invalidate()
        deskCalibrationBuffer.removeAll()
        deskCalibrationTicks = 0
        deskCalibrationSamplesCollected = 0
        deskCalibrationProgress = 0.0
        deskCalibrationRemainingSeconds = 10
        isCalibratingDeskSignal = true
        deskCalibrationSummary = "Scanning desk signal strength (10s)… Keep your device resting in its normal desk spot."

        appendLog(
            kind: .diagnostics,
            title: "Started 10-Second Desk Signal Calibration",
            detail: "Sampling BLE RSSI on desk to record baseline dBm and optimize lock/unlock hysteresis."
        )

        // 40 ticks * 0.25s = 10.0 seconds total
        deskCalibrationTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickTenSecondDeskCalibration()
            }
        }
    }

    public func cancelDeskCalibration() {
        deskCalibrationTimer?.invalidate()
        deskCalibrationTimer = nil
        isCalibratingDeskSignal = false
        deskCalibrationProgress = 0.0
        deskCalibrationSummary = "Desk calibration cancelled."
    }

    private func tickTenSecondDeskCalibration() {
        deskCalibrationTicks += 1
        let totalTicks = 40
        deskCalibrationProgress = min(Double(deskCalibrationTicks) / Double(totalTicks), 1.0)
        deskCalibrationRemainingSeconds = max(Int(ceil(Double(totalTicks - deskCalibrationTicks) * 0.25)), 0)

        // Actively poll connected peripheral RSSI on every 0.25s tick
        pollConnectedSystemPeripherals()

        // Real samples are collected only in handleRSSIUpdate (fresh readings from the bound device).
        if isSimulationMode {
            let jitter = Double.random(in: -1.8...1.8)
            deskCalibrationBuffer.append(simulatedRSSI + jitter)
            deskCalibrationSamplesCollected = deskCalibrationBuffer.count
        }

        if deskCalibrationTicks >= totalTicks {
            finishTenSecondDeskCalibration()
        }
    }

    private func finishTenSecondDeskCalibration() {
        deskCalibrationTimer?.invalidate()
        deskCalibrationTimer = nil
        isCalibratingDeskSignal = false
        deskCalibrationProgress = 1.0
        deskCalibrationRemainingSeconds = 0

        let samples = deskCalibrationBuffer
        guard samples.count >= Self.minimumCalibrationSamples else {
            let name = selectedDeviceName.isEmpty ? "your bound device" : selectedDeviceName
            deskCalibrationSummary = "Calibration failed: no signal from \(name) (\(samples.count) samples). Settings were not changed."
            appendLog(
                kind: .diagnostics,
                title: "Desk Calibration Failed",
                detail: "Only \(samples.count) readings from \(name) in 10s (need \(Self.minimumCalibrationSamples)). Make sure Bluetooth is on and the device is nearby, then retry."
            )
            evaluateProximityState()
            return
        }

        let sorted = samples.sorted()
        let count = Double(samples.count)
        let mean = samples.reduce(0.0, +) / count
        let median = sorted[sorted.count / 2]
        let variance = samples.map { pow($0 - mean, 2) }.reduce(0.0, +) / max(count - 1.0, 1.0)
        let stdDev = max(sqrt(variance), 1.0)

        let baselineInt = Int(median.rounded())
        notedDeskRSSI = baselineInt
        hasNotedDeskRSSI = true
        notedDeskJitterDB = (stdDev * 10.0).rounded() / 10.0

        // Compute optimal Unlock & Lock thresholds based on noted desk baseline and multipath noise σ:
        // - Unlock Threshold: 5 dB (or 1.8σ) below desk median so placing the device anywhere on the desk unlocks reliably
        // - Lock Threshold: 13 dB (or 3.5σ) below Unlock Threshold so sitting at the desk never false-locks
        let unlockMargin = min(max(1.8 * stdDev, 4.0), 8.0)
        let hysteresisGap = min(max(3.5 * stdDev, 11.0), 18.0)

        let optimizedUnlock = min(max((median - unlockMargin).rounded(), -80.0), -42.0)
        let optimizedLock = min(max((optimizedUnlock - hysteresisGap).rounded(), -94.0), optimizedUnlock - 8.0)

        unlockThresholdRSSI = optimizedUnlock
        lockThresholdRSSI = optimizedLock

        // Optimize Kalman/EMA smoothing & Grace Period based on measured desk wireless jitter
        if stdDev > 3.8 {
            smoothingFactor = 0.22
            lockGracePeriodSeconds = 10.0
        } else if stdDev > 2.2 {
            smoothingFactor = 0.30
            lockGracePeriodSeconds = 8.0
        } else {
            smoothingFactor = 0.38
            lockGracePeriodSeconds = 6.0
        }

        if playSoundEffects {
            NSSound(named: NSSound.Name("Glass"))?.play()
        }

        deskCalibrationSummary = String(
            format: "Noted Desk Signal: %d dBm (±%.1f dB) • Optimized Unlock ≥ %d dBm, Lock ≤ %d dBm, α = %.2f",
            baselineInt,
            notedDeskJitterDB,
            Int(optimizedUnlock),
            Int(optimizedLock),
            smoothingFactor
        )

        appendLog(
            kind: .diagnostics,
            title: "10s Desk Calibration Complete (\(baselineInt) dBm)",
            detail: deskCalibrationSummary,
            rssi: baselineInt
        )
        evaluateProximityState()
    }

    // MARK: - Public Controls

    public var bluetoothStateDescription: String {
        switch bluetoothState {
        case .poweredOn: return "Powered On & Scanning"
        case .poweredOff: return "Bluetooth Powered Off"
        case .unauthorized: return "Bluetooth Permission Denied"
        case .unsupported: return "Bluetooth LE Unsupported"
        case .resetting: return "Resetting Bluetooth Controller"
        case .unknown: return "Initializing CoreBluetooth..."
        @unknown default: return "Ready"
        }
    }

    public func startScanning() {
        guard centralManager.state == .poweredOn else { return }
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        isScanning = true
        pollConnectedSystemPeripherals()
    }

    public func stopScanning() {
        guard centralManager.state == .poweredOn else { return }
        centralManager.stopScan()
        isScanning = false
    }

    /// Binds `device` as the trusted key. Replacing an already-bound device requires the
    /// user's Mac password (typed by hand: AuraSense's own autofill is disabled for that prompt).
    public func bindDevice(_ device: BLEDevice, completion: ((Bool) -> Void)? = nil) {
        if let simID = simulatedDeviceID, device.id == simID {
            appendLog(
                kind: .permission,
                title: "Simulated Device Cannot Be Bound",
                detail: "The Sim Mode preview device is not a real key. Bind your iPhone or Apple Watch instead."
            )
            completion?(false)
            return
        }
        guard device.id.uuidString != selectedDeviceID else {
            completion?(true)
            return
        }
        guard trustedRecord != nil || !selectedDeviceID.isEmpty else {
            commitBind(device)
            completion?(true)
            return
        }
        let currentName = selectedDeviceName.isEmpty ? "the current device" : selectedDeviceName
        MacPasswordAuthorizer.shared.authorize(.changeTrustedDevice(from: currentName, to: device.name)) { [weak self] granted in
            guard let self else { return }
            if granted {
                self.commitBind(device)
            } else {
                self.appendLog(
                    kind: .permission,
                    title: "Trusted Device Change Cancelled",
                    detail: "Mac password was not verified; \(currentName) remains the trusted device."
                )
            }
            completion?(granted)
        }
    }

    private func commitBind(_ device: BLEDevice) {
        let previousUUID = boundUUID

        isApplyingBinding = true
        isSimulationMode = false
        if let old = previousUUID, old != device.id {
            releasePeripheral(old)
        }
        if deviceStore[device.id] == nil {
            deviceStore[device.id] = device
        }
        selectedDeviceID = device.id.uuidString
        selectedDeviceName = device.name
        selectedDeviceCategoryRaw = device.category.rawValue
        let record = TrustedDeviceRecord(id: device.id.uuidString, name: device.name, category: device.category.rawValue)
        trustedRecord = record
        if !TrustedDeviceRecordStore.save(record) {
            appendLog(
                kind: .permission,
                title: "Trusted Device Record Not Saved",
                detail: "AuraSense couldn't write the tamper-resistant Keychain record; the binding still applies for this session."
            )
        }
        isApplyingBinding = false

        boundSignalLost = false
        autoUnlockArmed = true
        autoLockArmed = true
        lastAutoLockDate = .distantPast
        resetAutoUnlockFailures(reason: "Bound \(device.name)")
        cancelGracePeriod(reason: "Bound \(device.name)")
        refreshTrackedDevice()
        deviceListDirty = true
        publishDiscoveredDevices(force: true)

        appendLog(
            kind: .deviceBound,
            title: "Bound \(device.name) as Aura Key",
            detail: "Identifier \(device.id.uuidString.prefix(8))… • Current signal \(device.rawRSSI) dBm",
            rssi: device.rawRSSI
        )
        evaluateProximityState()
        reacquireBoundPeripheral()
    }

    /// Removes the trusted device after the user's Mac password is verified.
    public func unbindDevice(completion: ((Bool) -> Void)? = nil) {
        guard !selectedDeviceID.isEmpty else {
            completion?(true)
            return
        }
        let name = selectedDeviceName.isEmpty ? "the current device" : selectedDeviceName
        MacPasswordAuthorizer.shared.authorize(.unbindTrustedDevice(name: name)) { [weak self] granted in
            guard let self else { return }
            if granted {
                self.commitUnbind()
            } else {
                self.appendLog(
                    kind: .permission,
                    title: "Trusted Device Removal Cancelled",
                    detail: "Mac password was not verified; \(name) remains the trusted device."
                )
            }
            completion?(granted)
        }
    }

    private func commitUnbind() {
        let previousName = selectedDeviceName
        let previousUUID = boundUUID

        isApplyingBinding = true
        isSimulationMode = false
        cancelGracePeriod(reason: nil)
        selectedDeviceID = ""
        selectedDeviceName = ""
        trustedRecord = nil
        TrustedDeviceRecordStore.clear()
        isApplyingBinding = false

        if let old = previousUUID {
            releasePeripheral(old)
        }
        boundSignalLost = false
        autoUnlockArmed = true
        autoLockArmed = true
        consecutiveUnlockFailures = 0
        autoUnlockSuspended = false
        nextUnlockAllowedDate = .distantPast
        refreshTrackedDevice()
        deviceListDirty = true
        publishDiscoveredDevices(force: true)
        proximityState = .unconfigured
        if !previousName.isEmpty {
            appendLog(
                kind: .deviceBound,
                title: "Unbound \(previousName)",
                detail: "Proximity lock/unlock paused until a new device is selected."
            )
        }
    }

    public func applyPreset(_ preset: ProximityPreset) {
        guard preset != .custom else { return }
        unlockThresholdRSSI = preset.unlockRSSI
        lockThresholdRSSI = preset.lockRSSI
        lockGracePeriodSeconds = preset.gracePeriod
        appendLog(
            kind: .diagnostics,
            title: "Applied '\(preset.rawValue)' Preset",
            detail: "Unlock ≥ \(Int(preset.unlockRSSI)) dBm • Lock ≤ \(Int(preset.lockRSSI)) dBm • Grace \(Int(preset.gracePeriod))s"
        )
    }

    public func pauseMonitoring(forMinutes minutes: Int) {
        let resumeDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
        pauseUntilDate = resumeDate
        cancelGracePeriod(reason: nil)
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        proximityState = .paused(reason: "Until \(formatter.string(from: resumeDate))")
        appendLog(
            kind: .systemState,
            title: "Paused Aura Protection for \(minutes)m",
            detail: "Will automatically resume at \(formatter.string(from: resumeDate))."
        )
    }

    public func resumeMonitoring() {
        pauseUntilDate = nil
        evaluateProximityState()
        appendLog(
            kind: .systemState,
            title: "Resumed Aura Protection",
            detail: "Active BLE proximity monitoring restored."
        )
    }

    /// Registers/unregisters AuraSense as a login item. `launchAtLogin` always reflects the
    /// real `SMAppService.mainApp.status` afterwards, and failures are reported in the log.
    public func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            syncLaunchAtLoginStatus()
            if enabled && service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
                appendLog(
                    kind: .permission,
                    title: "Launch at Login Needs Approval",
                    detail: "Allow AuraSense in System Settings → General → Login Items."
                )
            } else {
                appendLog(
                    kind: .systemState,
                    title: launchAtLogin ? "Launch at Login Enabled" : "Launch at Login Disabled",
                    detail: "Login item status: \(Self.describe(service.status))."
                )
            }
        } catch {
            syncLaunchAtLoginStatus()
            if enabled && service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
            appendLog(
                kind: .permission,
                title: enabled ? "Could Not Enable Launch at Login" : "Could Not Disable Launch at Login",
                detail: "\(error.localizedDescription) • Login item status: \(Self.describe(service.status))."
            )
        }
    }

    /// Re-reads the login item status (it can change in System Settings or via BackgroundPersistenceManager).
    public func syncLaunchAtLoginStatus() {
        let enabled = (SMAppService.mainApp.status == .enabled)
        if launchAtLogin != enabled {
            launchAtLogin = enabled
        }
    }

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "Enabled"
        case .notRegistered: return "Not Registered"
        case .requiresApproval: return "Requires Approval"
        case .notFound: return "Not Found (install AuraSense in /Applications)"
        @unknown default: return "Unknown"
        }
    }

    // MARK: - Manual & Diagnostic Test Actions

    public func triggerManualLock() {
        let result = MacLockUnlockController.shared.lockMac(
            sleepDisplay: sleepDisplayOnLock,
            playChime: playSoundEffects
        )
        switch result {
        case .lockedViaPrivateFramework, .lockedViaKeyboardShortcut:
            // Do not undo a deliberate lock while the device is still nearby: auto-unlock
            // re-arms only after the bound device has left the Aura.
            autoUnlockArmed = false
            lastManualLockDate = Date()
            cancelGracePeriod(reason: nil)
            proximityState = .lockedOutOfRange(lastRSSI: boundSignalLost ? nil : boundRecord?.rawRSSI)
            appendLog(
                kind: .locked,
                title: "Manual Lock Triggered",
                detail: MacLockUnlockController.shared.lastActionSummary + " Auto-unlock resumes after your device leaves and returns.",
                rssi: boundRecord?.rawRSSI
            )
        case .alreadyLocked:
            appendLog(kind: .diagnostics, title: "Mac Already Locked", detail: "Session was already in locked state.")
        case .failed(let err):
            appendLog(kind: .permission, title: "Lock Action Blocked", detail: err)
        }
    }

    public func triggerTestUnlockSequence() {
        Task { @MainActor in
            let result = await MacLockUnlockController.shared.unlockMac(
                forceTestInForeground: false,
                playChime: playSoundEffects
            )
            switch result {
            case .unlockedSuccessfully:
                appendLog(
                    kind: .unlocked,
                    title: "Accessibility Unlock & Monitor Input Sent",
                    detail: "Woke display/external monitor input and submitted Keychain credentials.",
                    rssi: trackedDevice?.rawRSSI
                )
            case .alreadyUnlocked:
                MacLockUnlockController.shared.wakeDisplayAndSendMonitorInput()
                // Preview what a real unlock looks and sounds like.
                UnlockCelebrationCoordinator.shared.celebrate(deviceName: trackedDevice?.name ?? selectedDeviceName)
                appendLog(
                    kind: .diagnostics,
                    title: "Unlock & Monitor Wake Pipeline Verified",
                    detail: MacLockUnlockController.shared.lastActionSummary,
                    rssi: trackedDevice?.rawRSSI
                )
            case .missingAccessibilityPermission:
                appendLog(
                    kind: .permission,
                    title: "Accessibility Permission Required",
                    detail: "Grant AuraSense access in System Settings → Privacy & Security → Accessibility."
                )
            case .missingKeychainPassword:
                appendLog(
                    kind: .permission,
                    title: "Keychain Password Required",
                    detail: "Save your macOS login password in Security & Keychain settings to enable auto-unlock."
                )
            case .skipped(let reason):
                appendLog(kind: .diagnostics, title: "Unlock Sequence Skipped", detail: reason)
            case .failed(let reason):
                appendLog(kind: .diagnostics, title: "Unlock Sequence Error", detail: reason)
            }
        }
    }

    public func clearActivityLog() {
        activityLog.removeAll()
        appendLog(kind: .diagnostics, title: "Activity Log Cleared", detail: "Started fresh telemetry session.")
    }

    // MARK: - Simulation Mode (in-memory preview only)

    private func setupSimulatedDeviceIfNeeded() {
        let simUUID = simulatedDeviceID ?? UUID()
        simulatedDeviceID = simUUID
        guard simulatedDevice == nil else { return }
        let simRSSI = Int(simulatedRSSI)
        kalmanFilters[simUUID] = KalmanRSSIFilter(initialEstimate: simulatedRSSI)
        simulatedDevice = BLEDevice(
            id: simUUID,
            name: "iPhone (Aura Sim Preview)",
            hasAdvertisedName: true,
            category: .iPhone,
            rawRSSI: simRSSI,
            smoothedRSSI: simulatedRSSI,
            txPower: -59,
            isConnected: true,
            manufacturerSummary: "Simulated",
            lastSeen: Date(),
            rssiHistory: [RSSISample(rawRSSI: simRSSI, smoothedRSSI: simulatedRSSI)]
        )
        refreshTrackedDevice()
    }

    private func teardownSimulatedDevice() {
        if let simID = simulatedDeviceID {
            kalmanFilters[simID] = nil
        }
        simulatedDevice = nil
        simulatedDeviceID = nil
        refreshTrackedDevice()
    }

    private func applySimulatedRSSI(_ rawValue: Int) {
        guard let simID = simulatedDeviceID, var dev = simulatedDevice else { return }
        var filter = kalmanFilters[simID] ?? KalmanRSSIFilter(initialEstimate: Double(rawValue))
        let smoothed = filter.update(measurement: Double(rawValue), alphaOverride: smoothingFactor)
        kalmanFilters[simID] = filter
        dev.rawRSSI = rawValue
        dev.smoothedRSSI = smoothed
        dev.lastSeen = Date()
        dev.rssiHistory.append(RSSISample(rawRSSI: rawValue, smoothedRSSI: smoothed))
        if dev.rssiHistory.count > 45 {
            dev.rssiHistory.removeFirst(dev.rssiHistory.count - 45)
        }
        simulatedDevice = dev
        refreshTrackedDevice()
    }

    // MARK: - Bound Device Helpers

    private var boundUUID: UUID? {
        UUID(uuidString: selectedDeviceID)
    }

    /// The real bound device's latest record (never the simulated device).
    private var boundRecord: BLEDevice? {
        guard let uuid = boundUUID else { return nil }
        return deviceStore[uuid]
    }

    private func isFresh(_ device: BLEDevice) -> Bool {
        Date().timeIntervalSince(device.lastSeen) < signalLossTimeoutSeconds
    }

    private func refreshTrackedDevice() {
        if isSimulationMode, let sim = simulatedDevice {
            trackedDevice = sim
        } else {
            trackedDevice = boundRecord
        }
    }

    /// Drops AuraSense's own connection to a device that is no longer trusted.
    private func releasePeripheral(_ uuid: UUID) {
        if let peripheral = peripheralMap[uuid],
           centralManager.state == .poweredOn,
           peripheral.state != .disconnected {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        kalmanFilters[uuid] = nil
    }

    /// Re-acquires the bound peripheral by identifier (it may not advertise under a name after launch)
    /// and keeps a pending connection so RSSI can be read as soon as it is reachable.
    private func reacquireBoundPeripheral() {
        guard centralManager.state == .poweredOn, let uuid = boundUUID else { return }
        let peripheral = peripheralMap[uuid] ?? centralManager.retrievePeripherals(withIdentifiers: [uuid]).first
        guard let peripheral else { return }
        peripheralMap[uuid] = peripheral
        peripheral.delegate = self
        if peripheral.state == .disconnected {
            centralManager.connect(peripheral, options: nil)
        }
    }

    private func resetAutoUnlockFailures(reason: String) {
        let wasSuspended = autoUnlockSuspended
        consecutiveUnlockFailures = 0
        autoUnlockSuspended = false
        nextUnlockAllowedDate = .distantPast
        if wasSuspended {
            appendLog(
                kind: .systemState,
                title: "Auto-Unlock Re-enabled",
                detail: "\(reason). AuraSense will try unlocking again when your device is in range."
            )
            evaluateProximityState()
        }
    }

    // MARK: - Device List Maintenance

    private func publishDiscoveredDevices(force: Bool) {
        guard deviceListDirty else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastDeviceListPublish) >= Self.deviceListPublishInterval else { return }
        lastDeviceListPublish = now
        deviceListDirty = false
        let bound = boundUUID
        discoveredDevices = deviceStore.values.sorted { a, b in
            if a.id == bound { return true }
            if b.id == bound { return false }
            if a.hasAdvertisedName != b.hasAdvertisedName { return a.hasAdvertisedName }
            if a.smoothedRSSI != b.smoothedRSSI { return a.smoothedRSSI > b.smoothedRSSI }
            return a.id.uuidString < b.id.uuidString
        }
    }

    /// Removes devices not heard for a while (BLE addresses rotate) and caps the list size.
    /// The bound device is always kept.
    private func pruneStaleDevices() {
        let now = Date()
        let bound = boundUUID
        var removed: [UUID] = []

        for (id, dev) in deviceStore where id != bound && now.timeIntervalSince(dev.lastSeen) > Self.staleDeviceAgeSeconds {
            removed.append(id)
        }
        for id in removed { deviceStore[id] = nil }

        if deviceStore.count > Self.maxDiscoveredDevices {
            let overflow = deviceStore.count - Self.maxDiscoveredDevices
            let oldest = deviceStore.values
                .filter { $0.id != bound }
                .sorted { $0.lastSeen < $1.lastSeen }
                .prefix(overflow)
                .map(\.id)
            for id in oldest { deviceStore[id] = nil }
            removed.append(contentsOf: oldest)
        }

        for id in removed {
            peripheralMap[id] = nil
            kalmanFilters[id] = nil
        }
        for id in Array(peripheralMap.keys) where id != bound && deviceStore[id] == nil {
            peripheralMap[id] = nil
        }
        for id in Array(kalmanFilters.keys) where id != bound && id != simulatedDeviceID && deviceStore[id] == nil {
            kalmanFilters[id] = nil
        }

        if !removed.isEmpty {
            deviceListDirty = true
        }
    }

    // MARK: - Timers & Connected Peripheral Polling

    private func startTimers() {
        connectedPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollConnectedSystemPeripherals()
                self?.publishDiscoveredDevices(force: false)
            }
        }

        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkWatchdogAndPauseExpiry()
            }
        }
    }

    private func pollConnectedSystemPeripherals() {
        guard centralManager.state == .poweredOn else { return }

        if let uuid = boundUUID,
           let peripheral = peripheralMap[uuid] {
            if peripheral.state == .connected {
                peripheral.readRSSI()
            }
        }

        let serviceUUIDs = [
            CBUUID(string: "180F"),
            CBUUID(string: "180A"),
            CBUUID(string: "1800"),
            CBUUID(string: "180D"),
            CBUUID(string: "FE9F")
        ]
        let connected = centralManager.retrieveConnectedPeripherals(withServices: serviceUUIDs)
        let bound = boundUUID
        for peripheral in connected {
            peripheralMap[peripheral.identifier] = peripheral
            peripheral.delegate = self
            if peripheral.state == .connected {
                peripheral.readRSSI()
            } else if peripheral.identifier == bound {
                centralManager.connect(peripheral, options: nil)
            }
        }
    }

    private func checkWatchdogAndPauseExpiry() {
        pruneStaleDevices()
        publishDiscoveredDevices(force: false)

        if let pauseUntil = pauseUntilDate, Date() >= pauseUntil {
            pauseUntilDate = nil
            appendLog(kind: .systemState, title: "Scheduled Pause Ended", detail: "Proximity monitoring is active again.")
            evaluateProximityState()
        }

        guard let uuid = boundUUID else {
            if monitoringEnabled && pauseUntilDate == nil {
                proximityState = .unconfigured
            }
            return
        }

        // Signal loss uses the last real reading, or the engine start if the device has not been seen since launch.
        let lastSeen = deviceStore[uuid]?.lastSeen ?? engineStartDate
        let elapsed = Date().timeIntervalSince(lastSeen)
        guard elapsed > signalLossTimeoutSeconds else { return }

        if !boundSignalLost {
            boundSignalLost = true
            // The device has left: a manual lock no longer blocks auto-unlock on its return.
            autoUnlockArmed = true
            let floor = lockThresholdRSSI - 10
            if var record = deviceStore[uuid] {
                record.smoothedRSSI = floor
                deviceStore[uuid] = record
                kalmanFilters[uuid]?.reset(to: floor)
                deviceListDirty = true
                refreshTrackedDevice()
            }
            let name = selectedDeviceName.isEmpty ? "the bound device" : selectedDeviceName
            appendLog(
                kind: .systemState,
                title: "Bound Device Signal Lost",
                detail: deviceStore[uuid] == nil
                    ? "\(name) has not been detected for \(Int(elapsed))s since AuraSense started."
                    : "No signal from \(name) for \(Int(elapsed))s."
            )
        }

        guard monitoringEnabled, pauseUntilDate == nil, !isCalibratingDeskSignal else { return }
        guard graceCountdownTimer == nil else { return }

        let isLocked = MacLockUnlockController.shared.refreshScreenLockState()
        if autoLockEnabled && autoLockArmed && !isLocked {
            startGracePeriod(triggerRSSI: Int(lockThresholdRSSI - 8), reason: "Signal lost for \(Int(elapsed))s")
        } else {
            evaluateProximityState()
        }
    }

    // MARK: - RSSI Processing & Hysteresis State Machine

    private func handleRSSIUpdate(
        uuid: UUID,
        name: String,
        hasAdvertisedName: Bool,
        rawRSSI: Int,
        txPower: Int?,
        isConnected: Bool,
        manufacturerSummary: String?
    ) {
        guard rawRSSI < 0 && rawRSSI > -115 else { return }
        let isBound = (uuid == boundUUID)

        if isCalibratingDeskSignal && isBound && !isSimulationMode {
            deskCalibrationBuffer.append(Double(rawRSSI))
            deskCalibrationSamplesCollected = deskCalibrationBuffer.count
        }

        var filter = kalmanFilters[uuid] ?? KalmanRSSIFilter(initialEstimate: Double(rawRSSI))
        let smoothed = filter.update(measurement: Double(rawRSSI), alphaOverride: smoothingFactor)
        kalmanFilters[uuid] = filter

        let now = Date()
        let sample = RSSISample(timestamp: now, rawRSSI: rawRSSI, smoothedRSSI: smoothed)
        let category = DeviceCategory.infer(from: name, manufacturerSummary: manufacturerSummary)
        let isNew: Bool

        if var existing = deviceStore[uuid] {
            isNew = false
            if hasAdvertisedName || existing.name.hasPrefix("BLE Device") {
                existing.name = name
                existing.hasAdvertisedName = existing.hasAdvertisedName || hasAdvertisedName
                existing.category = category
            }
            existing.rawRSSI = rawRSSI
            existing.smoothedRSSI = smoothed
            if let txPower = txPower { existing.txPower = txPower }
            existing.isConnected = isConnected
            if let mfg = manufacturerSummary { existing.manufacturerSummary = mfg }
            existing.lastSeen = now
            existing.rssiHistory.append(sample)
            if existing.rssiHistory.count > 45 {
                existing.rssiHistory.removeFirst(existing.rssiHistory.count - 45)
            }
            deviceStore[uuid] = existing
        } else {
            isNew = true
            deviceStore[uuid] = BLEDevice(
                id: uuid,
                name: name,
                hasAdvertisedName: hasAdvertisedName,
                category: category,
                rawRSSI: rawRSSI,
                smoothedRSSI: smoothed,
                txPower: txPower,
                isConnected: isConnected,
                manufacturerSummary: manufacturerSummary,
                lastSeen: now,
                rssiHistory: [sample]
            )
        }
        deviceListDirty = true

        if isNew && deviceStore.count > Self.maxDiscoveredDevices {
            pruneStaleDevices()
        }
        publishDiscoveredDevices(force: isNew && discoveredDevices.isEmpty)

        if isBound {
            boundSignalLost = false
            refreshTrackedDevice()
            evaluateProximityState()
        }
    }

    public func evaluateProximityState() {
        guard !isApplyingBinding else { return }
        enforceTrustedBinding()

        if let pauseUntil = pauseUntilDate, Date() < pauseUntil {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            proximityState = .paused(reason: "Until \(formatter.string(from: pauseUntil))")
            return
        }

        guard monitoringEnabled else {
            cancelGracePeriod(reason: nil)
            proximityState = .paused(reason: "Disabled by user")
            return
        }

        guard !selectedDeviceID.isEmpty else {
            cancelGracePeriod(reason: nil)
            proximityState = .unconfigured
            return
        }

        let deviceName = selectedDeviceName.isEmpty ? "your device" : selectedDeviceName

        guard let device = boundRecord else {
            // Not seen since launch: never claim it is in range. The watchdog starts the
            // signal-loss grace period after `signalLossTimeoutSeconds`.
            if graceCountdownTimer != nil { return }
            if MacLockUnlockController.shared.isScreenLocked {
                proximityState = .lockedOutOfRange(lastRSSI: nil)
            } else {
                proximityState = .paused(reason: "Searching for \(deviceName)…")
            }
            return
        }

        let fresh = isFresh(device) && !boundSignalLost
        let currentSmoothed = device.smoothedRSSI
        let currentInt = Int(currentSmoothed.rounded())
        let isMacLocked = MacLockUnlockController.shared.refreshScreenLockState()
        if fresh && !isMacLocked && currentSmoothed > lockThresholdRSSI {
            // Present (even in the hysteresis deadband) with the Mac unlocked: re-arm so the next
            // departure auto-locks again. Otherwise a return with the phone in a pocket (deadband)
            // followed by a manual unlock would leave auto-lock disarmed.
            autoLockArmed = true
        }
        if !isMacLocked && !autoUnlockArmed && Date().timeIntervalSince(lastManualLockDate) > 5 {
            // The user unlocked by hand after a manual lock; later (e.g. idle) locks may auto-unlock again.
            autoUnlockArmed = true
        }

        // Case 1: Signal is at or stronger than Unlock Threshold -> User is inside Aura
        if currentSmoothed >= unlockThresholdRSSI {
            if graceCountdownTimer != nil {
                cancelGracePeriod(reason: "Signal recovered to \(currentInt) dBm")
            }
            if fresh {
                // The user is back: the next departure may auto-lock again.
                autoLockArmed = true
            }

            guard isMacLocked else {
                proximityState = .unlockedInRange(rssi: currentInt)
                return
            }

            if !autoUnlockEnabled {
                proximityState = .paused(reason: "Auto-unlock is off")
            } else if autoUnlockSuspended {
                proximityState = .paused(reason: "Auto-unlock stopped: stored password was rejected")
            } else if !autoUnlockArmed {
                proximityState = .paused(reason: "Locked manually – auto-unlock resumes after \(deviceName) leaves")
            } else {
                proximityState = .unlockedInRange(rssi: currentInt)
                let now = Date()
                if fresh,
                   !unlockAttemptInFlight,
                   now >= nextUnlockAllowedDate,
                   now.timeIntervalSince(lastUnlockTriggerDate) >= unlockCooldownSeconds {
                    attemptAutoUnlock(deviceName: device.name, rssi: currentInt)
                }
            }
            return
        }

        // Case 2: Signal dropped at or below Lock Threshold -> User stepped outside Aura
        if currentSmoothed <= lockThresholdRSSI {
            // The device has left: a manual lock no longer blocks auto-unlock on its return.
            autoUnlockArmed = true
            let shownRSSI: Int? = boundSignalLost ? nil : currentInt
            let justAutoLocked = Date().timeIntervalSince(lastAutoLockDate) < 5

            if isMacLocked || justAutoLocked {
                cancelGracePeriod(reason: nil)
                proximityState = .lockedOutOfRange(lastRSSI: shownRSSI)
            } else if graceCountdownTimer != nil {
                proximityState = .gracePeriodCountdown(
                    remainingSeconds: graceRemainingSeconds,
                    currentRSSI: currentInt
                )
            } else if autoLockEnabled && autoLockArmed {
                startGracePeriod(
                    triggerRSSI: currentInt,
                    reason: boundSignalLost
                        ? "Signal lost from \(deviceName)"
                        : "Signal dropped to \(currentInt) dBm (≤ \(Int(lockThresholdRSSI)) dBm)"
                )
            } else if autoLockEnabled {
                proximityState = .paused(reason: "Auto-lock resumes when \(deviceName) returns")
            } else {
                proximityState = .paused(reason: "Auto-lock is off")
            }
            return
        }

        // Case 3: Signal is in the Hysteresis Deadband between Lock and Unlock thresholds
        if graceCountdownTimer != nil {
            proximityState = .gracePeriodCountdown(
                remainingSeconds: graceRemainingSeconds,
                currentRSSI: currentInt
            )
        } else if isMacLocked {
            proximityState = .lockedOutOfRange(lastRSSI: currentInt)
        } else {
            proximityState = .unlockedInRange(rssi: currentInt)
        }
    }

    // MARK: - Auto-Unlock Attempts

    private func attemptAutoUnlock(deviceName: String, rssi: Int) {
        unlockAttemptInFlight = true
        lastUnlockTriggerDate = Date()
        if wakeDisplayOnApproach {
            MacLockUnlockController.shared.wakeDisplayAndSendMonitorInput()
        }
        appendLog(
            kind: .unlocked,
            title: "Aura Entry Detected (\(rssi) dBm)",
            detail: "Device '\(deviceName)' crossed unlock threshold (\(Int(unlockThresholdRSSI)) dBm). Waking monitor & unlocking Mac...",
            rssi: rssi
        )
        Task { @MainActor in
            let result = await MacLockUnlockController.shared.unlockMac(playChime: self.playSoundEffects)
            self.unlockAttemptInFlight = false
            self.handleAutoUnlockResult(result)
        }
    }

    private func handleAutoUnlockResult(_ result: MacLockUnlockController.UnlockResult) {
        switch result {
        case .unlockedSuccessfully, .alreadyUnlocked:
            consecutiveUnlockFailures = 0
            nextUnlockAllowedDate = .distantPast
        case .missingAccessibilityPermission:
            nextUnlockAllowedDate = Date().addingTimeInterval(30)
            appendLog(
                kind: .permission,
                title: "Auto-Unlock Blocked: Accessibility Needed",
                detail: "Enable AuraSense in System Settings → Privacy & Security → Accessibility."
            )
        case .missingKeychainPassword:
            nextUnlockAllowedDate = Date().addingTimeInterval(30)
            appendLog(
                kind: .permission,
                title: "Auto-Unlock Blocked: Keychain Empty",
                detail: "Store your login password in AuraSense Security settings."
            )
        case .skipped(let reason):
            // Nothing was typed; retry soon without counting it against the password.
            nextUnlockAllowedDate = Date().addingTimeInterval(5)
            appendLog(kind: .diagnostics, title: "Auto-Unlock Skipped", detail: reason)
        case .failed(let reason):
            // macOS can confirm a correct unlock late; re-check before blaming the password.
            unlockAttemptInFlight = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self.unlockAttemptInFlight = false
                if MacLockUnlockController.shared.refreshScreenLockState() {
                    self.recordRejectedPassword(reason: reason)
                } else {
                    self.consecutiveUnlockFailures = 0
                    self.nextUnlockAllowedDate = .distantPast
                }
                self.evaluateProximityState()
            }
            return
        }
        evaluateProximityState()
    }

    private func recordRejectedPassword(reason: String) {
        consecutiveUnlockFailures += 1
        if consecutiveUnlockFailures >= Self.maxConsecutiveUnlockFailures {
            autoUnlockSuspended = true
            appendLog(
                kind: .permission,
                title: "Auto-Unlock Stopped: Stored Password Rejected",
                detail: "\(reason). The Mac stayed locked after \(consecutiveUnlockFailures) attempts, so AuraSense will not type it again. Re-save your macOS login password in Security & Keychain settings (or re-bind your device) to resume."
            )
        } else {
            nextUnlockAllowedDate = Date().addingTimeInterval(30)
            appendLog(
                kind: .permission,
                title: "Auto-Unlock Failed (Attempt \(consecutiveUnlockFailures) of \(Self.maxConsecutiveUnlockFailures))",
                detail: "\(reason). Retrying once in 30s."
            )
        }
    }

    // MARK: - Grace Period Countdown

    private func startGracePeriod(triggerRSSI: Int, reason: String) {
        graceCountdownTimer?.invalidate()
        graceRemainingSeconds = max(Int(lockGracePeriodSeconds.rounded()), 1)
        proximityState = .gracePeriodCountdown(
            remainingSeconds: graceRemainingSeconds,
            currentRSSI: triggerRSSI
        )

        appendLog(
            kind: .graceStarted,
            title: "Departure Grace Timer Started (\(graceRemainingSeconds)s)",
            detail: reason,
            rssi: triggerRSSI
        )

        graceCountdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickGracePeriod()
            }
        }
    }

    private func tickGracePeriod() {
        guard let currentTimer = graceCountdownTimer, currentTimer.isValid else { return }

        guard autoLockEnabled, monitoringEnabled, pauseUntilDate == nil, boundUUID != nil else {
            cancelGracePeriod(reason: autoLockEnabled ? nil : "Auto-lock disabled")
            evaluateProximityState()
            return
        }

        // Only a fresh, real reading counts as "returned"; a stale strong value must not cancel the lock.
        if let dev = boundRecord, !boundSignalLost, isFresh(dev), dev.smoothedRSSI >= unlockThresholdRSSI {
            cancelGracePeriod(reason: "Returned within Aura (\(Int(dev.smoothedRSSI)) dBm)")
            evaluateProximityState()
            return
        }

        graceRemainingSeconds -= 1
        let latestRSSI = Int((boundRecord?.smoothedRSSI ?? lockThresholdRSSI).rounded())

        if graceRemainingSeconds > 0 {
            proximityState = .gracePeriodCountdown(
                remainingSeconds: graceRemainingSeconds,
                currentRSSI: latestRSSI
            )
        } else {
            graceCountdownTimer?.invalidate()
            graceCountdownTimer = nil

            let lockRes = MacLockUnlockController.shared.lockMac(
                sleepDisplay: sleepDisplayOnLock,
                playChime: playSoundEffects
            )
            let shownRSSI: Int? = (boundSignalLost || boundRecord == nil) ? nil : latestRSSI

            switch lockRes {
            case .lockedViaPrivateFramework, .lockedViaKeyboardShortcut:
                // Lock once per departure: no further auto-lock until the device returns.
                autoLockArmed = false
                lastAutoLockDate = Date()
                proximityState = .lockedOutOfRange(lastRSSI: shownRSSI)
                appendLog(
                    kind: .locked,
                    title: "Auto-Locked Mac (Out of Aura)",
                    detail: "Device '\(selectedDeviceName)' stayed below \(Int(lockThresholdRSSI)) dBm for \(Int(lockGracePeriodSeconds))s.",
                    rssi: shownRSSI
                )
            case .alreadyLocked:
                autoLockArmed = false
                lastAutoLockDate = Date()
                proximityState = .lockedOutOfRange(lastRSSI: shownRSSI)
            case .failed(let err):
                appendLog(kind: .permission, title: "Auto-Lock Failed", detail: err, rssi: shownRSSI)
                evaluateProximityState()
            }
        }
    }

    private func cancelGracePeriod(reason: String?) {
        let hadTimer = (graceCountdownTimer != nil)
        graceCountdownTimer?.invalidate()
        graceCountdownTimer = nil
        graceRemainingSeconds = 0

        if hadTimer, let reason = reason {
            appendLog(
                kind: .graceCancelled,
                title: "Lock Countdown Cancelled",
                detail: reason,
                rssi: boundRecord?.rawRSSI
            )
        }
    }

    // MARK: - Activity Logging

    public func appendLog(kind: ActivityLogEntry.EventKind, title: String, detail: String, rssi: Int? = nil) {
        let entry = ActivityLogEntry(kind: kind, title: title, detail: detail, rssi: rssi)
        activityLog.insert(entry, at: 0)
        if activityLog.count > 200 {
            activityLog.removeLast(activityLog.count - 200)
        }
    }

    private func loadInitialActivityLog() {
        activityLog = [
            ActivityLogEntry(
                timestamp: Date(),
                kind: .systemState,
                title: "AuraSense Engine Initialized",
                detail: "Menu-bar proximity radar, 10s desk calibration, and external monitor wake active."
            )
        ]
    }
}

// MARK: - CBCentralManagerDelegate & CBPeripheralDelegate

extension BLEProximityEngine: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor in
            self.bluetoothState = state
            if state == .poweredOn {
                self.startScanning()
                self.reacquireBoundPeripheral()
            } else {
                self.isScanning = false
            }
        }
    }

    nonisolated public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let uuid = peripheral.identifier
        let rawRSSI = RSSI.intValue
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let periphName = peripheral.name
        let txPower = (advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue

        var mfgSummary: String? = nil
        if let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, mfgData.count >= 2 {
            let companyID = UInt16(mfgData[0]) | (UInt16(mfgData[1]) << 8)
            if companyID == 0x004C {
                mfgSummary = "Apple Inc."
                let dataCopy = mfgData
                Task { @MainActor in
                    FaceIdKeychainBridgeService.shared.handleContinuityManufacturerData(dataCopy, rssi: rawRSSI, peripheralID: uuid)
                }
            } else if companyID == 0x0075 {
                mfgSummary = "Samsung"
            } else if companyID == 0x00E0 {
                mfgSummary = "Google"
            }
        }

        let resolvedName: String
        let hasName: Bool
        if let adv = advName, !adv.trimmingCharacters(in: .whitespaces).isEmpty {
            resolvedName = adv
            hasName = true
        } else if let pName = periphName, !pName.trimmingCharacters(in: .whitespaces).isEmpty {
            resolvedName = pName
            hasName = true
        } else if mfgSummary == "Apple Inc." {
            resolvedName = "Apple Continuity Device (\(uuid.uuidString.prefix(4)))"
            hasName = false
        } else {
            resolvedName = "BLE Device (\(uuid.uuidString.prefix(4)))"
            hasName = false
        }

        let isConnected = (peripheral.state == .connected)

        Task { @MainActor in
            self.peripheralMap[uuid] = peripheral
            peripheral.delegate = self
            self.handleRSSIUpdate(
                uuid: uuid,
                name: resolvedName,
                hasAdvertisedName: hasName,
                rawRSSI: rawRSSI,
                txPower: txPower,
                isConnected: isConnected,
                manufacturerSummary: mfgSummary
            )
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            peripheral.delegate = self
            peripheral.readRSSI()
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let uuid = peripheral.identifier
        Task { @MainActor in
            // Keep a pending connection to the bound device so it is re-acquired when it returns.
            guard uuid == self.boundUUID, self.centralManager.state == .poweredOn else { return }
            self.centralManager.connect(peripheral, options: nil)
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        let uuid = peripheral.identifier
        let rawRSSI = RSSI.intValue
        let name = peripheral.name ?? "Connected Device (\(uuid.uuidString.prefix(4)))"
        let hasName = (peripheral.name != nil && !(peripheral.name?.isEmpty ?? true))

        Task { @MainActor in
            self.handleRSSIUpdate(
                uuid: uuid,
                name: name,
                hasAdvertisedName: hasName,
                rawRSSI: rawRSSI,
                txPower: nil,
                isConnected: true,
                manufacturerSummary: "Apple Inc."
            )
        }
    }
}
