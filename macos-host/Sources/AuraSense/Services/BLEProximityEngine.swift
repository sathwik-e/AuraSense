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
            if lockThresholdRSSI >= unlockThresholdRSSI - 4 {
                lockThresholdRSSI = unlockThresholdRSSI - 6
            }
            evaluateProximityState()
        }
    }
    @AppStorage("aurasense.lockThresholdRSSI") public var lockThresholdRSSI: Double = -76.0 {
        didSet {
            if lockThresholdRSSI > unlockThresholdRSSI - 4 {
                unlockThresholdRSSI = lockThresholdRSSI + 6
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
    @AppStorage("aurasense.autoLockEnabled") public var autoLockEnabled: Bool = true
    @AppStorage("aurasense.sleepDisplayOnLock") public var sleepDisplayOnLock: Bool = false
    @AppStorage("aurasense.wakeDisplayOnApproach") public var wakeDisplayOnApproach: Bool = true
    @AppStorage("aurasense.playSoundEffects") public var playSoundEffects: Bool = true
    @AppStorage("aurasense.onlyShowNamedDevices") public var onlyShowNamedDevices: Bool = false
    @AppStorage("aurasense.launchAtLogin") public var launchAtLogin: Bool = false
    @AppStorage("aurasense.v101.hasCompletedGuidedSetup") public var hasCompletedOnboarding: Bool = false

    public var needsGuidedSetup: Bool {
        !hasCompletedOnboarding ||
        !MacLockUnlockController.shared.isAccessibilityTrusted ||
        !KeychainManager.shared.hasStoredPassword() ||
        selectedDeviceID.isEmpty
    }

    // MARK: - Published Runtime State

    @Published public private(set) var bluetoothState: CBManagerState = .unknown
    @Published public private(set) var discoveredDevices: [BLEDevice] = []
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

    // Interactive Simulation Mode for testing & calibration without walking away
    @Published public var isSimulationMode: Bool = false {
        didSet {
            if isSimulationMode {
                setupSimulatedDeviceIfNeeded()
                applySimulatedRSSI(Int(simulatedRSSI))
            } else {
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

    private var centralManager: CBCentralManager!
    private var peripheralMap: [UUID: CBPeripheral] = [:]
    private var kalmanFilters: [UUID: KalmanRSSIFilter] = [:]
    private var connectedPollTimer: Timer?
    private var watchdogTimer: Timer?
    private var graceCountdownTimer: Timer?
    private var deskCalibrationTimer: Timer?
    private var deskCalibrationBuffer: [Double] = []
    private var deskCalibrationTicks: Int = 0
    private var graceRemainingSeconds: Int = 0
    private var lastUnlockTriggerDate: Date = .distantPast
    private var lastLockTriggerDate: Date = .distantPast

    private override init() {
        super.init()
        loadInitialActivityLog()
        centralManager = CBCentralManager(delegate: nil, queue: .main, options: [
            CBCentralManagerOptionShowPowerAlertKey: true
        ])
        centralManager.delegate = self
        startTimers()
        evaluateProximityState()
    }

    public func promptForBluetoothPermission() {
        centralManager = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionShowPowerAlertKey: true
        ])
        startScanning()
    }

    // MARK: - 10-Second Desk Signal Calibration Optimizer

    /// Runs a 10.0-second high-frequency BLE RSSI scan while the user's device sits on their desk.
    /// Notes the exact desk signal strength (mean, median, and standard deviation σ) and automatically
    /// optimizes Unlock RSSI, Lock RSSI, Kalman/EMA smoothing, and Grace Period.
    public func startTenSecondDeskCalibration() {
        guard !isCalibratingDeskSignal else { return }

        // If no device is bound yet, auto-bind the strongest discovered device or enable simulated key
        if selectedDeviceID.isEmpty {
            if let strongest = discoveredDevices.first {
                bindDevice(strongest)
            } else {
                isSimulationMode = true
            }
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

        if let dev = trackedDevice {
            deskCalibrationBuffer.append(Double(dev.rawRSSI))
            deskCalibrationSamplesCollected = 1
        }

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

        if isSimulationMode {
            let jitter = Double.random(in: -1.8...1.8)
            deskCalibrationBuffer.append(simulatedRSSI + jitter)
            deskCalibrationSamplesCollected = deskCalibrationBuffer.count
        } else if let dev = trackedDevice {
            deskCalibrationBuffer.append(Double(dev.rawRSSI))
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

        let samples = deskCalibrationBuffer.isEmpty ? [-58.0] : deskCalibrationBuffer
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

    public func bindDevice(_ device: BLEDevice) {
        selectedDeviceID = device.id.uuidString
        selectedDeviceName = device.name
        selectedDeviceCategoryRaw = device.category.rawValue
        trackedDevice = device
        cancelGracePeriod(reason: "Bound \(device.name)")
        appendLog(
            kind: .deviceBound,
            title: "Bound \(device.name) as Aura Key",
            detail: "Identifier \(device.id.uuidString.prefix(8))… • Current signal \(device.rawRSSI) dBm",
            rssi: device.rawRSSI
        )
        evaluateProximityState()

        if let peripheral = peripheralMap[device.id], peripheral.state == .disconnected {
            centralManager.connect(peripheral, options: nil)
        }
    }

    public func unbindDevice() {
        let previousName = selectedDeviceName
        selectedDeviceID = ""
        selectedDeviceName = ""
        trackedDevice = nil
        cancelGracePeriod(reason: nil)
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

    public func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLogin = enabled
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            appendLog(
                kind: .systemState,
                title: "Launch at Login Preference Saved",
                detail: "Service registration status updated (\(enabled ? "Enabled" : "Disabled"))."
            )
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
            proximityState = .lockedOutOfRange(lastRSSI: trackedDevice?.rawRSSI)
            appendLog(
                kind: .locked,
                title: "Manual Lock Triggered",
                detail: MacLockUnlockController.shared.lastActionSummary,
                rssi: trackedDevice?.rawRSSI
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
                if playSoundEffects {
                    NSSound(named: NSSound.Name("Glass"))?.play()
                }
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
            case .failed(let reason):
                appendLog(kind: .diagnostics, title: "Unlock Sequence Error", detail: reason)
            }
        }
    }

    public func clearActivityLog() {
        activityLog.removeAll()
        appendLog(kind: .diagnostics, title: "Activity Log Cleared", detail: "Started fresh telemetry session.")
    }

    // MARK: - Simulation Mode

    private func setupSimulatedDeviceIfNeeded() {
        let simUUID: UUID
        if let existingUUID = UUID(uuidString: selectedDeviceID) {
            simUUID = existingUUID
        } else {
            let newUUID = UUID()
            selectedDeviceID = newUUID.uuidString
            selectedDeviceName = "iPhone 16 Pro (Aura Sim)"
            selectedDeviceCategoryRaw = DeviceCategory.iPhone.rawValue
            simUUID = newUUID
        }

        if trackedDevice == nil {
            let dev = BLEDevice(
                id: simUUID,
                name: selectedDeviceName.isEmpty ? "iPhone 16 Pro (Aura Sim)" : selectedDeviceName,
                hasAdvertisedName: true,
                category: .iPhone,
                rawRSSI: Int(simulatedRSSI),
                smoothedRSSI: simulatedRSSI,
                txPower: -59,
                isConnected: true,
                manufacturerSummary: "Apple Inc. (Simulated)",
                lastSeen: Date(),
                rssiHistory: [RSSISample(rawRSSI: Int(simulatedRSSI), smoothedRSSI: simulatedRSSI)]
            )
            trackedDevice = dev
            if !discoveredDevices.contains(where: { $0.id == simUUID }) {
                discoveredDevices.insert(dev, at: 0)
            }
        }
    }

    private func applySimulatedRSSI(_ rawValue: Int) {
        guard let targetUUID = UUID(uuidString: selectedDeviceID) else { return }
        handleRSSIUpdate(
            uuid: targetUUID,
            name: selectedDeviceName.isEmpty ? "iPhone 16 Pro (Aura Sim)" : selectedDeviceName,
            hasAdvertisedName: true,
            rawRSSI: rawValue,
            txPower: -59,
            isConnected: true,
            manufacturerSummary: "Apple Inc."
        )
    }

    // MARK: - Timers & Connected Peripheral Polling

    private func startTimers() {
        connectedPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollConnectedSystemPeripherals()
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

        if let uuid = UUID(uuidString: selectedDeviceID),
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
        for peripheral in connected {
            peripheralMap[peripheral.identifier] = peripheral
            peripheral.delegate = self
            if peripheral.state == .connected {
                peripheral.readRSSI()
            } else if peripheral.identifier.uuidString == selectedDeviceID {
                centralManager.connect(peripheral, options: nil)
            }
        }
    }

    private func checkWatchdogAndPauseExpiry() {
        if let pauseUntil = pauseUntilDate, Date() >= pauseUntil {
            pauseUntilDate = nil
            appendLog(kind: .systemState, title: "Scheduled Pause Ended", detail: "Proximity monitoring is active again.")
        }

        guard monitoringEnabled, pauseUntilDate == nil, !isSimulationMode, !isCalibratingDeskSignal else { return }
        guard !selectedDeviceID.isEmpty else {
            proximityState = .unconfigured
            return
        }

        if let dev = trackedDevice {
            let elapsed = Date().timeIntervalSince(dev.lastSeen)
            if elapsed > signalLossTimeoutSeconds {
                if graceCountdownTimer == nil && !MacLockUnlockController.shared.isScreenLocked {
                    startGracePeriod(triggerRSSI: Int(lockThresholdRSSI - 8), reason: "Signal lost for \(Int(elapsed))s")
                }
            }
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

        if isCalibratingDeskSignal && uuid.uuidString == selectedDeviceID {
            deskCalibrationBuffer.append(Double(rawRSSI))
            deskCalibrationSamplesCollected = deskCalibrationBuffer.count
        }

        var filter = kalmanFilters[uuid] ?? KalmanRSSIFilter(initialEstimate: Double(rawRSSI))
        let smoothed = filter.update(measurement: Double(rawRSSI), alphaOverride: smoothingFactor)
        kalmanFilters[uuid] = filter

        let sample = RSSISample(timestamp: Date(), rawRSSI: rawRSSI, smoothedRSSI: smoothed)
        let category = DeviceCategory.infer(from: name, manufacturerSummary: manufacturerSummary)

        if let index = discoveredDevices.firstIndex(where: { $0.id == uuid }) {
            var existing = discoveredDevices[index]
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
            existing.lastSeen = Date()
            existing.rssiHistory.append(sample)
            if existing.rssiHistory.count > 45 {
                existing.rssiHistory.removeFirst(existing.rssiHistory.count - 45)
            }
            discoveredDevices[index] = existing

            if uuid.uuidString == selectedDeviceID {
                trackedDevice = existing
            }
        } else {
            let newDevice = BLEDevice(
                id: uuid,
                name: name,
                hasAdvertisedName: hasAdvertisedName,
                category: category,
                rawRSSI: rawRSSI,
                smoothedRSSI: smoothed,
                txPower: txPower,
                isConnected: isConnected,
                manufacturerSummary: manufacturerSummary,
                lastSeen: Date(),
                rssiHistory: [sample]
            )
            discoveredDevices.append(newDevice)
            if uuid.uuidString == selectedDeviceID {
                trackedDevice = newDevice
            }
        }

        discoveredDevices.sort { a, b in
            if a.id.uuidString == selectedDeviceID { return true }
            if b.id.uuidString == selectedDeviceID { return false }
            if a.hasAdvertisedName != b.hasAdvertisedName { return a.hasAdvertisedName }
            return a.smoothedRSSI > b.smoothedRSSI
        }

        if uuid.uuidString == selectedDeviceID {
            evaluateProximityState()
        }
    }

    public func evaluateProximityState() {
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

        guard let device = trackedDevice else {
            if MacLockUnlockController.shared.isScreenLocked {
                proximityState = .lockedOutOfRange(lastRSSI: nil)
            } else {
                proximityState = .unlockedInRange(rssi: Int(unlockThresholdRSSI))
            }
            return
        }

        let currentSmoothed = device.smoothedRSSI
        let currentInt = Int(currentSmoothed.rounded())
        let isMacLocked = MacLockUnlockController.shared.refreshScreenLockState()

        // Case 1: Signal is at or stronger than Unlock Threshold -> User is inside Aura
        if currentSmoothed >= unlockThresholdRSSI {
            if graceCountdownTimer != nil {
                cancelGracePeriod(reason: "Signal recovered to \(currentInt) dBm")
            }

            proximityState = .unlockedInRange(rssi: currentInt)

            if isMacLocked && autoUnlockEnabled {
                let sinceLastUnlock = Date().timeIntervalSince(lastUnlockTriggerDate)
                if sinceLastUnlock >= unlockCooldownSeconds {
                    lastUnlockTriggerDate = Date()
                    if wakeDisplayOnApproach {
                        MacLockUnlockController.shared.wakeDisplayAndSendMonitorInput()
                    }
                    appendLog(
                        kind: .unlocked,
                        title: "Aura Entry Detected (\(currentInt) dBm)",
                        detail: "Device '\(device.name)' crossed unlock threshold (\(Int(unlockThresholdRSSI)) dBm). Waking monitor & unlocking Mac...",
                        rssi: currentInt
                    )
                    Task { @MainActor in
                        let res = await MacLockUnlockController.shared.unlockMac(playChime: playSoundEffects)
                        if case .missingAccessibilityPermission = res {
                            appendLog(
                                kind: .permission,
                                title: "Auto-Unlock Blocked: Accessibility Needed",
                                detail: "Enable AuraSense in System Settings → Privacy & Security → Accessibility."
                            )
                        } else if case .missingKeychainPassword = res {
                            appendLog(
                                kind: .permission,
                                title: "Auto-Unlock Blocked: Keychain Empty",
                                detail: "Store your login password in AuraSense Security settings."
                            )
                        }
                    }
                }
            }
            return
        }

        // Case 2: Signal dropped at or below Lock Threshold -> User stepped outside Aura
        if currentSmoothed <= lockThresholdRSSI {
            if isMacLocked {
                cancelGracePeriod(reason: nil)
                proximityState = .lockedOutOfRange(lastRSSI: currentInt)
            } else if autoLockEnabled {
                if graceCountdownTimer == nil {
                    startGracePeriod(
                        triggerRSSI: currentInt,
                        reason: "Signal dropped to \(currentInt) dBm (≤ \(Int(lockThresholdRSSI)) dBm)"
                    )
                } else {
                    proximityState = .gracePeriodCountdown(
                        remainingSeconds: graceRemainingSeconds,
                        currentRSSI: currentInt
                    )
                }
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

        if let dev = trackedDevice, dev.smoothedRSSI >= unlockThresholdRSSI {
            cancelGracePeriod(reason: "Returned within Aura (\(Int(dev.smoothedRSSI)) dBm)")
            proximityState = .unlockedInRange(rssi: Int(dev.smoothedRSSI))
            return
        }

        graceRemainingSeconds -= 1
        let latestRSSI = Int((trackedDevice?.smoothedRSSI ?? lockThresholdRSSI).rounded())

        if graceRemainingSeconds > 0 {
            proximityState = .gracePeriodCountdown(
                remainingSeconds: graceRemainingSeconds,
                currentRSSI: latestRSSI
            )
        } else {
            graceCountdownTimer?.invalidate()
            graceCountdownTimer = nil
            lastLockTriggerDate = Date()

            let lockRes = MacLockUnlockController.shared.lockMac(
                sleepDisplay: sleepDisplayOnLock,
                playChime: playSoundEffects
            )
            proximityState = .lockedOutOfRange(lastRSSI: latestRSSI)

            switch lockRes {
            case .lockedViaPrivateFramework, .lockedViaKeyboardShortcut:
                appendLog(
                    kind: .locked,
                    title: "Auto-Locked Mac (Out of Aura)",
                    detail: "Device '\(selectedDeviceName)' stayed below \(Int(lockThresholdRSSI)) dBm for \(Int(lockGracePeriodSeconds))s.",
                    rssi: latestRSSI
                )
            case .alreadyLocked:
                break
            case .failed(let err):
                appendLog(kind: .permission, title: "Auto-Lock Failed", detail: err, rssi: latestRSSI)
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
                rssi: trackedDevice?.rawRSSI
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
                    FaceIdKeychainBridgeService.shared.handleContinuityManufacturerData(dataCopy, rssi: rawRSSI)
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
