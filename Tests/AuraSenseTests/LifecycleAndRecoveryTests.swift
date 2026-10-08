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

    @Test func testSystemSleepWakeMonitorSimulation() {
        let monitor = MockSleepWakeMonitor(initialAsleep: false)
        #expect(!monitor.isAsleep)

        var sleepCalled = false
        var wakeCalled = false

        monitor.onWillSleep = { sleepCalled = true }
        monitor.onDidWake = { wakeCalled = true }

        monitor.simulateSleep()
        #expect(monitor.isAsleep)
        #expect(sleepCalled)

        monitor.simulateWake()
        #expect(!monitor.isAsleep)
        #expect(wakeCalled)
    }

    @Test func testBluetoothRecoveryCoordinatorOnRadioFailure() {
        let scanner = MockBLEScanner(initialRadioState: .poweredOn)
        let engine = ProximityEngine()
        let coordinator = BluetoothRecoveryCoordinator(scanner: scanner, proximityEngine: engine)

        var interruptionCalled = false
        coordinator.onRadioInterruption = { _ in interruptionCalled = true }

        // Simulate radio failure (poweredOff)
        coordinator.handleRadioStateChange(.poweredOff)
        #expect(interruptionCalled)
        #expect(engine.currentState.isUnknown)
    }

    @Test func testBluetoothRecoveryCoordinatorOnRadioRecovery() {
        let scanner = MockBLEScanner(initialRadioState: .poweredOff, initialAuthorization: .allowedAlways)
        let engine = ProximityEngine()
        let coordinator = BluetoothRecoveryCoordinator(scanner: scanner, proximityEngine: engine)

        var recoverySuccessCalled = false
        coordinator.onRecoverySuccess = { recoverySuccessCalled = true }

        // Simulate radio recovering to poweredOn
        scanner.simulateRadioStateChange(.poweredOn)
        coordinator.handleRadioStateChange(.poweredOn)
        #expect(recoverySuccessCalled)
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
}
