import Testing
import Foundation
@testable import AuraSenseCore

struct CandidateLifecycleTests {

    @Test func testUnregisterWhileNearForcesUnknownAndCancelsActions() async throws {
        let mockProvider = MockActionProvider(isLockSupported: true)
        let policyEngine = PolicyEngine(actionProvider: mockProvider, isAutoLockEnabled: true)
        let candidate = CandidateDevice(id: UUID(), name: "My iPhone")
        let trustStore = InMemoryCandidateTrustStore()
        let config = ProximityEngineConfig(nearDwellDuration: 0.1, farDwellDuration: 1.0, countdownDuration: 5, staleTimeout: 2.0)
        let proximityEngine = ProximityEngine(config: config)
        let diagnostics = DiagnosticsManager(
            trustStore: trustStore,
            proximityEngine: proximityEngine,
            policyEngine: policyEngine
        )
        try diagnostics.registerCandidate(candidate)
        diagnostics.proximityEngine.updateScannerHealth(isHealthy: true)

        let start = Date()
        diagnostics.proximityEngine.processSample(rssi: -50, timestamp: start)
        diagnostics.proximityEngine.processSample(rssi: -50, timestamp: start.addingTimeInterval(0.2))
        #expect(diagnostics.proximityEngine.currentState.isNear)

        // Unregister candidate while NEAR
        try diagnostics.unregisterCandidate()
        #expect(diagnostics.proximityEngine.currentState.isUnknown)

        // Advance time past stale and far thresholds
        diagnostics.proximityEngine.tick(currentTime: start.addingTimeInterval(5.0))
        diagnostics.proximityEngine.tick(currentTime: start.addingTimeInterval(15.0))

        try await Task.sleep(nanoseconds: 30_000_000)

        // Must remain UNKNOWN, zero locks
        #expect(diagnostics.proximityEngine.currentState.isUnknown)
        #expect(mockProvider.lockCallCount == 0)
        #expect(policyEngine.locksExecutedCount == 0)
    }

    @Test func testUnregisterWhileCountdownCancelsCountdownAndForcesUnknown() async throws {
        let mockProvider = MockActionProvider(isLockSupported: true)
        let policyEngine = PolicyEngine(actionProvider: mockProvider, isAutoLockEnabled: true)
        let candidate = CandidateDevice(id: UUID(), name: "My iPhone")
        let trustStore = InMemoryCandidateTrustStore()
        let config = ProximityEngineConfig(nearDwellDuration: 0.1, farDwellDuration: 0.5, countdownDuration: 5)
        let proximityEngine = ProximityEngine(config: config)
        let diagnostics = DiagnosticsManager(
            trustStore: trustStore,
            proximityEngine: proximityEngine,
            policyEngine: policyEngine
        )
        try diagnostics.registerCandidate(candidate)
        diagnostics.proximityEngine.updateScannerHealth(isHealthy: true)

        let start = Date()
        diagnostics.proximityEngine.processSample(rssi: -50, timestamp: start)
        diagnostics.proximityEngine.processSample(rssi: -50, timestamp: start.addingTimeInterval(0.2))
        #expect(diagnostics.proximityEngine.currentState.isNear)

        // Enter countdown
        diagnostics.proximityEngine.processSample(rssi: -85, timestamp: start.addingTimeInterval(1.0))
        diagnostics.proximityEngine.processSample(rssi: -85, timestamp: start.addingTimeInterval(2.0))
        diagnostics.proximityEngine.tick(currentTime: start.addingTimeInterval(2.0))
        #expect(diagnostics.proximityEngine.currentState.isCountdown)

        // Unregister candidate while countdown is active
        try diagnostics.unregisterCandidate()
        #expect(diagnostics.proximityEngine.currentState.isUnknown)

        // Advance past countdown expiry (e.g. t = 10s)
        diagnostics.proximityEngine.tick(currentTime: start.addingTimeInterval(10.0))

        try await Task.sleep(nanoseconds: 30_000_000)

        #expect(diagnostics.proximityEngine.currentState.isUnknown)
        #expect(mockProvider.lockCallCount == 0)
        #expect(policyEngine.locksExecutedCount == 0)
    }

    @Test func testAmbiguityRecoveryAfterPeerExpiration() throws {
        let candidateID = UUID()
        let candidate = CandidateDevice(id: candidateID, name: "Sathwik Phone")
        let trustStore = InMemoryCandidateTrustStore()
        let config = ProximityEngineConfig(nearDwellDuration: 0.1, farDwellDuration: 1.0, countdownDuration: 5)
        let proximityEngine = ProximityEngine(config: config)
        let diagnostics = DiagnosticsManager(trustStore: trustStore, proximityEngine: proximityEngine)
        try diagnostics.registerCandidate(candidate)

        let scanner = MockBLEScanner(initialRadioState: .poweredOn, initialAuthorization: .allowedAlways)
        scanner.delegate = diagnostics

        let t0 = Date()
        // 1. Discover valid candidate
        _ = scanner.simulatePeripheralDiscovery(id: candidateID, name: "Sathwik Phone", rssi: -55, timestamp: t0)
        #expect(diagnostics.gate.admittedCount == 1)

        // 2. Discover conflicting same-name peer (spoof attempt)
        let spoofID = UUID()
        _ = scanner.simulatePeripheralDiscovery(id: spoofID, name: "Sathwik Phone", rssi: -60, timestamp: t0)

        // Next candidate observation detects ambiguity and forces UNKNOWN
        _ = scanner.simulatePeripheralDiscovery(id: candidateID, name: "Sathwik Phone", rssi: -55, timestamp: t0.addingTimeInterval(0.5))
        #expect(diagnostics.gate.ambiguityCount >= 1)
        #expect(diagnostics.proximityEngine.currentState.isUnknown)

        // 3. Spoof disappears. Advance time past 15-second active timeout (t = 20s)
        let tFuture = t0.addingTimeInterval(20.0)

        // Candidate sends fresh observation at tFuture
        _ = scanner.simulatePeripheralDiscovery(id: candidateID, name: "Sathwik Phone", rssi: -52, timestamp: tFuture)

        // Ambiguity should now be cleared because the spoof peer expired from activePeripherals!
        // Scanner health recovers, candidate is admitted
        #expect(diagnostics.gate.admittedCount >= 2)

        // Submit second near sample within dwell to establish NEAR with fresh evidence
        _ = scanner.simulatePeripheralDiscovery(id: candidateID, name: "Sathwik Phone", rssi: -50, timestamp: tFuture.addingTimeInterval(0.2))
        #expect(diagnostics.proximityEngine.currentState.isNear)
    }
}
