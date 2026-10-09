import Testing
import Foundation
@testable import AuraSenseCore

struct ActionExecutorTests {

    @Test func testMockActionBlockedBeforeSideEffectCancelledByNearReturn() async throws {
        let mockProvider = MockActionProvider(isLockSupported: true, shouldSucceed: true)
        let policyEngine = PolicyEngine(actionProvider: mockProvider, isAutoLockEnabled: true)
        let candidate = CandidateDevice(id: UUID(), name: "iPhone")
        let trustStore = InMemoryCandidateTrustStore()
        let config = ProximityEngineConfig(nearDwellDuration: 0.1, farDwellDuration: 0.2, countdownDuration: 5)
        let proximityEngine = ProximityEngine(config: config)
        let diagnostics = DiagnosticsManager(
            trustStore: trustStore,
            proximityEngine: proximityEngine,
            policyEngine: policyEngine
        )
        try diagnostics.registerCandidate(candidate)
        diagnostics.proximityEngine.updateScannerHealth(isHealthy: true)

        let start = Date()
        // Establish NEAR
        diagnostics.proximityEngine.processSample(rssi: -50, timestamp: start)
        diagnostics.proximityEngine.processSample(rssi: -50, timestamp: start.addingTimeInterval(0.2))
        #expect(diagnostics.proximityEngine.currentState.isNear)

        // Install suspension hook in mock provider that simulates candidate return BEFORE lock side effect
        mockProvider.onBeforeLock = {
            // While lock request is pending, candidate returns to NEAR!
            diagnostics.proximityEngine.processSample(rssi: -50, timestamp: start.addingTimeInterval(3.0))
            diagnostics.proximityEngine.processSample(rssi: -50, timestamp: start.addingTimeInterval(3.2))
        }

        // Trigger FAR
        diagnostics.proximityEngine.processSample(rssi: -85, timestamp: start.addingTimeInterval(1.0))
        diagnostics.proximityEngine.processSample(rssi: -85, timestamp: start.addingTimeInterval(1.5))
        diagnostics.proximityEngine.tick(currentTime: start.addingTimeInterval(1.5)) // countdown
        diagnostics.proximityEngine.tick(currentTime: start.addingTimeInterval(7.0)) // FAR

        // Allow async tasks to settle
        try await Task.sleep(nanoseconds: 50_000_000)

        // Lock should have been cancelled before side effect because state transitioned back to NEAR
        #expect(mockProvider.lockCallCount == 0)
        #expect(policyEngine.locksExecutedCount == 0)
    }

    @Test func testMockActionBlockedBeforeSideEffectCancelledByUnknown() async throws {
        let mockProvider = MockActionProvider(isLockSupported: true, shouldSucceed: true)
        let policyEngine = PolicyEngine(actionProvider: mockProvider, isAutoLockEnabled: true)
        let candidate = CandidateDevice(id: UUID(), name: "iPhone")
        let trustStore = InMemoryCandidateTrustStore()
        let config = ProximityEngineConfig(nearDwellDuration: 0.1, farDwellDuration: 0.2, countdownDuration: 5)
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

        // Install hook that drops scanner health / triggers UNKNOWN
        mockProvider.onBeforeLock = {
            diagnostics.proximityEngine.updateScannerHealth(isHealthy: false, reason: "Bluetooth turned off")
        }

        // Trigger FAR
        diagnostics.proximityEngine.processSample(rssi: -85, timestamp: start.addingTimeInterval(1.0))
        diagnostics.proximityEngine.processSample(rssi: -85, timestamp: start.addingTimeInterval(1.5))
        diagnostics.proximityEngine.tick(currentTime: start.addingTimeInterval(1.5))
        diagnostics.proximityEngine.tick(currentTime: start.addingTimeInterval(7.0))

        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(mockProvider.lockCallCount == 0)
        #expect(policyEngine.locksExecutedCount == 0)
    }

    @Test func testPolicyEngineCountersAndRetryBehavior() async throws {
        let mockProvider = MockActionProvider(isLockSupported: true)
        let policyEngine = PolicyEngine(actionProvider: mockProvider, isAutoLockEnabled: true)

        // 1. Mock returns .rejected
        mockProvider.nextLockResult = .rejected(.requestLock, reason: "System busy")
        let result1 = await policyEngine.handleStateTransition(from: .countdown(secondsRemaining: 0), to: .far(dwellDuration: 10), reason: "Departed")
        #expect(result1 == .rejected(.requestLock, reason: "System busy"))
        #expect(policyEngine.locksExecutedCount == 0)
        #expect(policyEngine.locksRejectedCount == 1)

        // Since it was rejected, a subsequent valid transition is eligible to retry (latch was NOT engaged)
        mockProvider.nextLockResult = .unsupported(.requestLock, reason: "Session locked")
        let result2 = await policyEngine.handleStateTransition(from: .countdown(secondsRemaining: 0), to: .far(dwellDuration: 10), reason: "Retry departure")
        #expect(result2 == .unsupported(.requestLock, reason: "Session locked"))
        #expect(policyEngine.locksExecutedCount == 0)
        #expect(policyEngine.locksUnsupportedCount == 1)

        // Now mock returns .executed
        mockProvider.nextLockResult = nil // restores default executed
        let result3 = await policyEngine.handleStateTransition(from: .countdown(secondsRemaining: 0), to: .far(dwellDuration: 10), reason: "Successful retry")
        #expect(policyEngine.locksExecutedCount == 1)
        if case .executed = result3 {
            // Success
        } else {
            Issue.record("Expected .executed result")
        }

        // Now that it was executed, a duplicate transition is suppressed by idempotency
        let result4 = await policyEngine.handleStateTransition(from: .countdown(secondsRemaining: 0), to: .far(dwellDuration: 10), reason: "Duplicate")
        #expect(policyEngine.locksExecutedCount == 1)
        #expect(policyEngine.locksSuppressedCount == 1)
        if case .rejected(let action, let reason) = result4 {
            #expect(action == .requestLock)
            #expect(reason.contains("already locked"))
        } else {
            Issue.record("Expected suppressed rejection")
        }
    }

    @Test func testRapidStateFlappingCancelsSupersededTasksAndDoesNotAccumulate() async throws {
        // Finding 20: Rapid state flapping must cancel superseded pending tasks
        let mockProvider = MockActionProvider(isLockSupported: true, shouldSucceed: true)
        let policyEngine = PolicyEngine(actionProvider: mockProvider, isAutoLockEnabled: true, isAutoWakeEnabled: true)
        let candidate = CandidateDevice(id: UUID(), name: "iPhone")
        let trustStore = InMemoryCandidateTrustStore()
        let config = ProximityEngineConfig(nearDwellDuration: 0.05, farDwellDuration: 0.05, countdownDuration: 1)
        let proximityEngine = ProximityEngine(config: config)
        let diagnostics = DiagnosticsManager(
            trustStore: trustStore,
            proximityEngine: proximityEngine,
            policyEngine: policyEngine
        )
        try diagnostics.registerCandidate(candidate)
        diagnostics.proximityEngine.updateScannerHealth(isHealthy: true)

        let start = Date()

        // Flap state rapidly 5 times between NEAR and FAR
        for i in 0..<5 {
            let offset = Double(i) * 0.1
            // NEAR
            diagnostics.proximityEngine.processSample(rssi: -50, timestamp: start.addingTimeInterval(offset))
            diagnostics.proximityEngine.processSample(rssi: -50, timestamp: start.addingTimeInterval(offset + 0.06))

            // FAR
            diagnostics.proximityEngine.processSample(rssi: -85, timestamp: start.addingTimeInterval(offset + 0.07))
            diagnostics.proximityEngine.processSample(rssi: -85, timestamp: start.addingTimeInterval(offset + 0.08))
        }

        // Final settle: end at NEAR
        diagnostics.proximityEngine.processSample(rssi: -50, timestamp: start.addingTimeInterval(1.0))
        diagnostics.proximityEngine.processSample(rssi: -50, timestamp: start.addingTimeInterval(1.1))

        // Allow async tasks to settle
        try await Task.sleep(nanoseconds: 100_000_000)

        // Lock should NEVER have been executed since the intermediate FAR states were immediately superseded by NEAR
        #expect(mockProvider.lockCallCount == 0)
        #expect(policyEngine.locksExecutedCount == 0)
    }
}
