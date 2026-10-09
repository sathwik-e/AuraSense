import Testing
import Foundation
@testable import AuraSenseCore

struct PolicyEngineTests {
    private final class TestScreenLockMechanism: MacOSScreenLockMechanismProtocol, @unchecked Sendable {
        let isAvailable: Bool
        var isSessionLocked: Bool
        var lockResult: Bool
        private(set) var lockCallCount = 0

        init(isAvailable: Bool = true, isSessionLocked: Bool = false, lockResult: Bool = true) {
            self.isAvailable = isAvailable
            self.isSessionLocked = isSessionLocked
            self.lockResult = lockResult
        }

        func lockSession() throws -> Bool {
            lockCallCount += 1
            isSessionLocked = lockResult
            return lockResult
        }
    }

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

    @Test func testConcurrentDepartureTransitionsReserveOnlyOneLock() async {
        let mockProvider = MockActionProvider(isLockSupported: true)
        let policy = PolicyEngine(actionProvider: mockProvider, isAutoLockEnabled: true)

        async let first = policy.handleStateTransition(
            from: .countdown(secondsRemaining: 0),
            to: .far(dwellDuration: 10),
            reason: "departure"
        )
        async let second = policy.handleStateTransition(
            from: .countdown(secondsRemaining: 0),
            to: .far(dwellDuration: 10),
            reason: "duplicate departure"
        )

        _ = await (first, second)
        #expect(mockProvider.lockCallCount == 1)
        #expect(policy.locksExecutedCount == 1)
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

    @Test func testReturnToNearResetsLatchAndTriggersWake() async {
        let mockAction = MockActionProvider(isLockSupported: true, isWakeSupported: true)
        let policy = PolicyEngine(actionProvider: mockAction, isAutoLockEnabled: true, isAutoWakeEnabled: true)

        // Departure 1
        _ = await policy.handleStateTransition(from: .near(smoothedRSSI: -50.0), to: .far(dwellDuration: 10.0), reason: "Departure 1")
        #expect(mockAction.lockCallCount == 1)

        // User returns to NEAR -> triggers wake and resets departure latch
        let nearResult = await policy.handleStateTransition(from: .far(dwellDuration: 10.0), to: .near(smoothedRSSI: -52.0), reason: "Return to Mac")
        #expect(nearResult != nil)
        #expect(mockAction.wakeCallCount == 1)
        #expect(policy.wakesExecutedCount == 1)

        if case .executed(let action, _) = nearResult {
            #expect(action == .wakeDisplay)
        } else {
            Issue.record("Expected wake display executed on return to NEAR")
        }

        // Departure 2 -> latch should allow new lock
        _ = await policy.handleStateTransition(from: .near(smoothedRSSI: -52.0), to: .far(dwellDuration: 10.0), reason: "Departure 2")
        #expect(mockAction.lockCallCount == 2)
        #expect(policy.locksExecutedCount == 2)
    }

    @Test func testAutoWakeDisabledSuppressesWake() async {
        let mockAction = MockActionProvider(isWakeSupported: true)
        let policy = PolicyEngine(actionProvider: mockAction, isAutoWakeEnabled: false)

        let result = await policy.handleStateTransition(
            from: .far(dwellDuration: 10.0),
            to: .near(smoothedRSSI: -50.0),
            reason: "Arrival"
        )

        #expect(result != nil)
        #expect(mockAction.wakeCallCount == 0)
        #expect(policy.wakesExecutedCount == 0)
        #expect(policy.wakesSuppressedCount == 1)

        if case .rejected(let action, let reason) = result {
            #expect(action == .wakeDisplay)
            #expect(reason.contains("disabled"))
        } else {
            Issue.record("Expected wakeDisplay rejection when auto-wake disabled")
        }
    }

    @Test func testWakeIdempotencyWithinNear() async {
        let mockAction = MockActionProvider(isWakeSupported: true)
        let policy = PolicyEngine(actionProvider: mockAction, isAutoWakeEnabled: true)

        // Initial transition to NEAR wakes display
        let first = await policy.handleStateTransition(
            from: .unknown(reason: "Start"),
            to: .near(smoothedRSSI: -55.0),
            reason: "First seen"
        )
        #expect(first != nil)
        #expect(mockAction.wakeCallCount == 1)
        #expect(policy.wakesExecutedCount == 1)

        // Subsequent sample updates while remaining in NEAR do NOT re-wake display
        let second = await policy.handleStateTransition(
            from: .near(smoothedRSSI: -55.0),
            to: .near(smoothedRSSI: -53.0),
            reason: "Sample update"
        )
        #expect(second == nil)
        #expect(mockAction.wakeCallCount == 1)
        #expect(policy.wakesExecutedCount == 1)
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
        let adapter = MacOSActionAdapter(
            isDryRun: true,
            minimumLockInterval: 2.0,
            minimumWakeInterval: 2.0,
            screenLocker: TestScreenLockMechanism()
        )
        #expect(adapter.isDryRun)
        #expect(adapter.isLockSupported)
        #expect(adapter.isWakeSupported)

        // Lock test: first lock succeeds in dry run
        let firstLock = try await adapter.requestLock()
        if case .executed(let action, let details) = firstLock {
            #expect(action == .requestLock)
            #expect(details.contains("Dry-run"))
        } else {
            Issue.record("Expected dry run lock execution")
        }

        // Lock throttle: immediate second lock rejected
        let secondLock = try await adapter.requestLock()
        if case .rejected(let action, let reason) = secondLock {
            #expect(action == .requestLock)
            #expect(reason.contains("throttled"))
        } else {
            Issue.record("Expected lock throttle rejection")
        }

        // Wake test: first wake succeeds in dry run
        let firstWake = try await adapter.wakeDisplay()
        if case .executed(let action, let details) = firstWake {
            #expect(action == .wakeDisplay)
            #expect(details.contains("Dry-run"))
        } else {
            Issue.record("Expected dry run wake execution")
        }

        // Wake throttle: immediate second wake rejected
        let secondWake = try await adapter.wakeDisplay()
        if case .rejected(let action, let reason) = secondWake {
            #expect(action == .wakeDisplay)
            #expect(reason.contains("throttled"))
        } else {
            Issue.record("Expected wake throttle rejection")
        }
    }

    @Test func testLiveLockMechanismExecutesAndVerifiesWithoutTouchingHost() async throws {
        let mechanism = TestScreenLockMechanism()
        let adapter = MacOSActionAdapter(isDryRun: false, screenLocker: mechanism)
        let result = try await adapter.requestLock()

        if case .executed(.requestLock, let details) = result {
            #expect(details.contains("verified"))
            #expect(mechanism.lockCallCount == 1)
        } else {
            Issue.record("Expected injected live lock mechanism to execute")
        }
    }

    @Test func testLiveLockReportsUnsupportedWhenMechanismUnavailable() async throws {
        let adapter = MacOSActionAdapter(
            isDryRun: false,
            screenLocker: TestScreenLockMechanism(isAvailable: false)
        )
        let result = try await adapter.requestLock()
        if case .unsupported(.requestLock, let reason) = result {
            #expect(reason.contains("unavailable"))
        } else {
            Issue.record("Expected unavailable lock mechanism to be reported")
        }
    }

    @Test func testAlreadyLockedSessionDoesNotIssueAnotherLock() async throws {
        let mechanism = TestScreenLockMechanism(isSessionLocked: true)
        let adapter = MacOSActionAdapter(isDryRun: false, screenLocker: mechanism)
        let result = try await adapter.requestLock()
        if case .executed(.requestLock, let details) = result {
            #expect(details.contains("already locked"))
            #expect(mechanism.lockCallCount == 0)
        } else {
            Issue.record("Expected already-locked session to be idempotent")
        }
    }

    @Test func testMacOSAdapterRejectsInvalidatedActionsBeforeSideEffects() async throws {
        let adapter = MacOSActionAdapter(isDryRun: false, screenLocker: TestScreenLockMechanism())

        let lockResult = try await adapter.requestLock(isValid: { false })
        let wakeResult = try await adapter.wakeDisplay(isValid: { false })

        if case .rejected(.requestLock, _) = lockResult {
            #expect(true)
        } else {
            Issue.record("Expected invalidated lock to be rejected before execution")
        }
        if case .rejected(.wakeDisplay, _) = wakeResult {
            #expect(true)
        } else {
            Issue.record("Expected invalidated wake to be rejected before execution")
        }
    }

    @Test func testMacOSInputSynthesizerDryRun() async throws {
        let synth = MacOSInputSynthesizer(isDryRun: true)
        #expect(synth.isDryRun)

        let result = try await synth.sendWakeKey()
        if case .executed(let action, let details) = result {
            #expect(action == .wakeDisplay)
            #expect(details.contains("Dry-run"))
        } else {
            Issue.record("Expected dry run synthesized key")
        }
    }

    @Test func testPhase5CredentialEntryRemainsDisabled() async {
        let adapter = MacOSActionAdapter(isDryRun: true)
        #expect(!adapter.isCredentialEntrySupported)

        do {
            _ = try await adapter.requestCredentialEntry()
            Issue.record("Expected credential entry to throw ActionError")
        } catch let error as ActionError {
            if case .actionDisabled(let reason) = error {
                #expect(reason.contains("Phase 5") || reason.contains("Phase 6"))
            } else {
                Issue.record("Expected ActionError.actionDisabled")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
