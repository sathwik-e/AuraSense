import Testing
import Foundation
@testable import AuraSenseCore

struct PolicyEngineTests {

    @Test func testAutoLockDisabledSuppressesLock() async {
        let mockAction = MockActionProvider(isLockSupported: true)
        let policy = PolicyEngine(actionProvider: mockAction, isAutoLockEnabled: false)

        let result = await policy.handleStateTransition(
            from: .near(smoothedRSSI: -50.0),
            to: .far(dwellDuration: 10.0),
            reason: "Departure detected"
        )

        #expect(result != nil)
        #expect(mockAction.lockCallCount == 0)
        #expect(policy.locksExecutedCount == 0)
        #expect(policy.locksSuppressedCount == 1)

        if case .rejected(let action, let reason) = result {
            #expect(action == .requestLock)
            #expect(reason.contains("disabled"))
        } else {
            Issue.record("Expected rejected action when auto-lock disabled")
        }
    }

    @Test func testAutoLockEnabledExecutesLock() async {
        let mockAction = MockActionProvider(isLockSupported: true)
        let policy = PolicyEngine(actionProvider: mockAction, isAutoLockEnabled: true)

        let result = await policy.handleStateTransition(
            from: .near(smoothedRSSI: -50.0),
            to: .far(dwellDuration: 10.0),
            reason: "Departure detected"
        )

        #expect(result != nil)
        #expect(mockAction.lockCallCount == 1)
        #expect(policy.locksExecutedCount == 1)
        #expect(policy.lockAttemptsCount == 1)
        #expect(policy.locksSuppressedCount == 0)

        if case .executed(let action, _) = result {
            #expect(action == .requestLock)
        } else {
            Issue.record("Expected executed action when auto-lock enabled")
        }
    }

    @Test func testIdempotencyLatchSuppressesRepeatedLocksInFar() async {
        let mockAction = MockActionProvider(isLockSupported: true)
        let policy = PolicyEngine(actionProvider: mockAction, isAutoLockEnabled: true)

        // First departure triggers lock
        _ = await policy.handleStateTransition(
            from: .near(smoothedRSSI: -50.0),
            to: .far(dwellDuration: 10.0),
            reason: "Departure 1"
        )
        #expect(mockAction.lockCallCount == 1)
        #expect(policy.locksExecutedCount == 1)

        // Second transition to FAR without NEAR return should be suppressed by latch
        let secondResult = await policy.handleStateTransition(
            from: .far(dwellDuration: 10.0),
            to: .far(dwellDuration: 15.0),
            reason: "Departure 2 repeated"
        )
        #expect(mockAction.lockCallCount == 1)
        #expect(policy.locksExecutedCount == 1)
        #expect(policy.locksSuppressedCount == 1)

        if case .rejected(let action, let reason) = secondResult {
            #expect(action == .requestLock)
            #expect(reason.contains("idempotent"))
        } else {
            Issue.record("Expected rejected action due to idempotency latch")
        }
    }

    @Test func testReturnToNearResetsLatch() async {
        let mockAction = MockActionProvider(isLockSupported: true)
        let policy = PolicyEngine(actionProvider: mockAction, isAutoLockEnabled: true)

        // Departure 1
        _ = await policy.handleStateTransition(from: .near(smoothedRSSI: -50.0), to: .far(dwellDuration: 10.0), reason: "Departure 1")
        #expect(mockAction.lockCallCount == 1)

        // User returns to NEAR -> latch resets
        let nearResult = await policy.handleStateTransition(from: .far(dwellDuration: 10.0), to: .near(smoothedRSSI: -52.0), reason: "Return to Mac")
        #expect(nearResult == nil)
        #expect(mockAction.lockCallCount == 1)

        // Departure 2 -> latch should allow new lock
        _ = await policy.handleStateTransition(from: .near(smoothedRSSI: -52.0), to: .far(dwellDuration: 10.0), reason: "Departure 2")
        #expect(mockAction.lockCallCount == 2)
        #expect(policy.locksExecutedCount == 2)
    }

    @Test func testUnknownStateDoesNotLockByDefault() async {
        let mockAction = MockActionProvider(isLockSupported: true)
        let policy = PolicyEngine(actionProvider: mockAction, isAutoLockEnabled: true, lockOnUnknown: false)

        let result = await policy.handleStateTransition(
            from: .near(smoothedRSSI: -50.0),
            to: .unknown(reason: "Bluetooth signal lost"),
            reason: "Temporary gap"
        )

        #expect(result == nil)
        #expect(mockAction.lockCallCount == 0)
        #expect(policy.locksExecutedCount == 0)
    }

    @Test func testUnknownStateLocksWhenOptedIn() async {
        let mockAction = MockActionProvider(isLockSupported: true)
        let policy = PolicyEngine(actionProvider: mockAction, isAutoLockEnabled: true, lockOnUnknown: true)

        let result = await policy.handleStateTransition(
            from: .near(smoothedRSSI: -50.0),
            to: .unknown(reason: "Immediate secure fail"),
            reason: "Strict security"
        )

        #expect(result != nil)
        #expect(mockAction.lockCallCount == 1)
        #expect(policy.locksExecutedCount == 1)
    }

    @Test func testMacOSActionAdapterDryRunAndThrottle() async throws {
        let adapter = MacOSActionAdapter(isDryRun: true, minimumLockInterval: 2.0)
        #expect(adapter.isDryRun)
        #expect(adapter.isLockSupported)
        #expect(!adapter.isWakeSupported) // reserved for Phase 5

        // First lock should succeed in dry run
        let firstResult = try await adapter.requestLock()
        if case .executed(let action, let details) = firstResult {
            #expect(action == .requestLock)
            #expect(details.contains("Dry-run"))
        } else {
            Issue.record("Expected dry run execution")
        }

        // Immediate second lock should be throttled
        let secondResult = try await adapter.requestLock()
        if case .rejected(let action, let reason) = secondResult {
            #expect(action == .requestLock)
            #expect(reason.contains("throttled"))
        } else {
            Issue.record("Expected throttle rejection")
        }
    }
}
