import Testing
import Foundation
@testable import AuraSenseCore

struct LifecyclePowerTests {

    @Test func testRadioTransitionsAndSleepWakeYieldSingleActiveScan() throws {
        let scanner = MockBLEScanner(initialRadioState: .poweredOn, initialAuthorization: .allowedAlways)
        let config = ProximityEngineConfig(nearDwellDuration: 0.1, farDwellDuration: 1.0)
        let proximityEngine = ProximityEngine(config: config)
        let coordinator = BluetoothRecoveryCoordinator(scanner: scanner, proximityEngine: proximityEngine)

        try scanner.startScanning()
        #expect(scanner.isScanning)

        // 1. Radio fails (.poweredOff)
        scanner.simulateRadioStateChange(.poweredOff)
        coordinator.handleRadioStateChange(.poweredOff)
        #expect(!scanner.isScanning)
        #expect(proximityEngine.currentState.isUnknown)

        // 2. Radio resetting
        scanner.simulateRadioStateChange(.resetting)
        coordinator.handleRadioStateChange(.resetting)
        #expect(!scanner.isScanning)
        #expect(proximityEngine.currentState.isUnknown)

        // 3. Radio recovers (.poweredOn)
        scanner.simulateRadioStateChange(.poweredOn)
        coordinator.handleRadioStateChange(.poweredOn)
        #expect(scanner.isScanning)
        // Must remain UNKNOWN until fresh evidence arrives
        #expect(proximityEngine.currentState.isUnknown)

        // 4. System Sleep
        coordinator.handleSystemSleep()
        #expect(!scanner.isScanning)
        #expect(proximityEngine.currentState.isUnknown)

        // 5. System Wake
        coordinator.handleSystemWake()
        #expect(scanner.isScanning)
        #expect(proximityEngine.currentState.isUnknown)
    }

    @Test func testDuplicateBurstHasBoundedWorkAndNoDuplicateActions() async throws {
        let mockProvider = MockActionProvider(isLockSupported: true)
        let policyEngine = PolicyEngine(actionProvider: mockProvider, isAutoLockEnabled: true)
        let candidateID = UUID()
        let candidate = CandidateDevice(id: candidateID, name: "Burst Candidate")
        let trustStore = InMemoryCandidateTrustStore()
        let proximityEngine = ProximityEngine()
        let diagnostics = DiagnosticsManager(
            maxEvents: 50,
            trustStore: trustStore,
            proximityEngine: proximityEngine,
            policyEngine: policyEngine
        )
        try diagnostics.registerCandidate(candidate)

        let scanner = MockBLEScanner(initialRadioState: .poweredOn, initialAuthorization: .allowedAlways)
        scanner.delegate = diagnostics

        let t0 = Date()
        // Simulate high-rate burst of 200 duplicate advertisements
        for i in 1...200 {
            _ = scanner.simulatePeripheralDiscovery(
                id: candidateID,
                name: "Burst Candidate",
                rssi: -50 - (i % 5),
                timestamp: t0.addingTimeInterval(Double(i) * 0.01)
            )
        }

        // Bounded registry: exactly 1 peripheral record
        #expect(diagnostics.registry.count == 1)

        // Bounded RSSI history: capped at 100 entries per peripheral
        let peripheral = diagnostics.registry.peripheral(for: candidateID)
        #expect(peripheral != nil)
        #expect(peripheral!.rssiHistory.count <= 100)

        // Bounded events ring buffer: capped at maxEvents (50)
        #expect(diagnostics.recentEvents().count <= 50)

        // No runaway or duplicated actions triggered
        #expect(policyEngine.locksExecutedCount == 0)
    }

    @Test func testProximityTicksInactiveWhenAsleepOrRadioOffOrNoCandidate() throws {
        let trustStore = InMemoryCandidateTrustStore()
        let diagnostics = DiagnosticsManager(trustStore: trustStore)

        // No candidate registered -> canProcessProximityTicks is FALSE
        #expect(!diagnostics.canProcessProximityTicks)

        // Register candidate -> canProcessProximityTicks becomes TRUE
        let candidate = CandidateDevice(id: UUID(), name: "iPhone")
        try diagnostics.registerCandidate(candidate)
        #expect(diagnostics.canProcessProximityTicks)

        // Radio state changes to poweredOff -> canProcessProximityTicks becomes FALSE
        diagnostics.scannerDidChangeRadioState(.poweredOff)
        #expect(!diagnostics.canProcessProximityTicks)

        // Radio recovers -> canProcessProximityTicks resumes TRUE
        diagnostics.scannerDidChangeRadioState(.poweredOn)
        #expect(diagnostics.canProcessProximityTicks)

        // Unregister candidate -> canProcessProximityTicks becomes FALSE
        try diagnostics.unregisterCandidate()
        #expect(!diagnostics.canProcessProximityTicks)
    }
}
