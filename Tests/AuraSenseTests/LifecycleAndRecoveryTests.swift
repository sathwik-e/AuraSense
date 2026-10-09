import Testing
import Foundation
@testable import AuraSenseCore

struct LifecycleAndRecoveryTests {

    @Test func testFileLoggerWritesAndReadsEvents() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aurasense_test_logs_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logger = FileLogger(logDirectory: tempDir, fileName: "test.log")
        let event = DiagnosticEvent(level: .info, category: "Test", message: "Hello AuraSense Logging")
        logger.log(event: event)

        let lines = logger.readRecentLogs(maxLines: 10)
        #expect(!lines.isEmpty)
        #expect(lines.first?.contains("Hello AuraSense Logging") == true)
        #expect(lines.first?.contains("[INFO]") == true)
    }

    private final class SafeFlag: @unchecked Sendable {
        private var flag = false
        private let lock = NSLock()
        func set() {
            lock.lock()
            flag = true
            lock.unlock()
        }
        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return flag
        }
    }

    @Test func testSystemSleepWakeMonitorSimulation() {
        let monitor = MockSleepWakeMonitor(initialAsleep: false)
        #expect(!monitor.isAsleep)

        let sleepCalled = SafeFlag()
        let wakeCalled = SafeFlag()

        monitor.onWillSleep = { sleepCalled.set() }
        monitor.onDidWake = { wakeCalled.set() }

        monitor.simulateSleep()
        #expect(monitor.isAsleep)
        #expect(sleepCalled.isSet)

        monitor.simulateWake()
        #expect(!monitor.isAsleep)
        #expect(wakeCalled.isSet)
    }

    @Test func testBluetoothRecoveryCoordinatorOnRadioFailure() {
        let scanner = MockBLEScanner(initialRadioState: .poweredOn)
        let engine = ProximityEngine()
        let coordinator = BluetoothRecoveryCoordinator(scanner: scanner, proximityEngine: engine)

        let interruptionCalled = SafeFlag()
        coordinator.onRadioInterruption = { _ in interruptionCalled.set() }

        // Simulate radio failure (poweredOff)
        coordinator.handleRadioStateChange(.poweredOff)
        #expect(interruptionCalled.isSet)
        #expect(engine.currentState.isUnknown)
    }

    @Test func testBluetoothRecoveryCoordinatorOnRadioRecovery() {
        let scanner = MockBLEScanner(initialRadioState: .poweredOff, initialAuthorization: .allowedAlways)
        let engine = ProximityEngine()
        let coordinator = BluetoothRecoveryCoordinator(scanner: scanner, proximityEngine: engine)

        let recoverySuccessCalled = SafeFlag()
        coordinator.onRecoverySuccess = { recoverySuccessCalled.set() }

        // Simulate radio recovering to poweredOn
        scanner.simulateRadioStateChange(.poweredOn)
        coordinator.handleRadioStateChange(.poweredOn)
        #expect(recoverySuccessCalled.isSet)
        #expect(coordinator.recoveryAttemptsCount == 1)
        #expect(scanner.isScanning)
    }

    @Test func testLaunchAtLoginMock() throws {
        let manager = MockLaunchAtLoginManager(initialEnabled: false)
        #expect(!manager.isEnabled)

        try manager.setEnabled(true)
        #expect(manager.isEnabled)

        try manager.setEnabled(false)
        #expect(!manager.isEnabled)
    }

    @Test func testSystemSleepCancelsCountdownAndInvalidatesPendingActions() {
        // Finding 19: System sleep cancels active countdown, forces UNKNOWN, and invalidates pending actions
        let scanner = MockBLEScanner(initialRadioState: .poweredOn)
        let config = ProximityEngineConfig(nearDwellDuration: 0.1, farDwellDuration: 0.2, countdownDuration: 5)
        let engine = ProximityEngine(config: config)
        let executor = ActionExecutor()
        let coordinator = BluetoothRecoveryCoordinator(scanner: scanner, proximityEngine: engine, actionExecutor: executor)

        engine.updateScannerHealth(isHealthy: true)
        engine.updateCandidateAvailability(hasCandidate: true)

        let t0 = Date()
        // Establish NEAR
        engine.processSample(rssi: -50, timestamp: t0)
        engine.processSample(rssi: -50, timestamp: t0.addingTimeInterval(0.2))
        #expect(engine.currentState.isNear)

        // Enter COUNTDOWN
        engine.processSample(rssi: -85, timestamp: t0.addingTimeInterval(1.0))
        engine.processSample(rssi: -85, timestamp: t0.addingTimeInterval(1.5))
        engine.tick(currentTime: t0.addingTimeInterval(1.5))
        #expect(engine.currentState.isCountdown)

        let genBeforeSleep = executor.currentGeneration

        // System enters sleep
        coordinator.handleSystemSleep()

        // Countdown must be cancelled and state forced to UNKNOWN
        #expect(engine.currentState.isUnknown)
        #expect(!engine.currentState.isCountdown)

        // Pending action tokens must be invalidated
        #expect(executor.currentGeneration > genBeforeSleep)
        #expect(!executor.isGenerationValid(genBeforeSleep))

        // System wakes: state must remain UNKNOWN until fresh evidence arrives
        coordinator.handleSystemWake()
        #expect(engine.currentState.isUnknown)
    }
}
