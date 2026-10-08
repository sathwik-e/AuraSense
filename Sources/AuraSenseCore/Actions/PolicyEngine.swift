import Foundation

/// Action policy engine evaluating proximity transitions and executing authorized system actions.
/// Strictly enforces opt-in, idempotency, and fail-safe gates per ARCHITECTURE.md.
public final class PolicyEngine: @unchecked Sendable {
    private let lock = NSLock()
    public let actionProvider: any ActionProviderProtocol

    // User policy configuration
    public var isAutoLockEnabled: Bool
    public var lockOnUnknown: Bool

    // Idempotency latch: ensures only ONE lock request is emitted per departure cycle
    private var hasLockedForCurrentDeparture: Bool = false

    // Telemetry
    private var _lockAttemptsCount: Int = 0
    private var _locksExecutedCount: Int = 0
    private var _locksSuppressedCount: Int = 0

    public var lockAttemptsCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _lockAttemptsCount
    }

    public var locksExecutedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _locksExecutedCount
    }

    public var locksSuppressedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _locksSuppressedCount
    }

    public var onPolicyDecision: (@Sendable (SecurityAction, ActionResult) -> Void)?

    public init(
        actionProvider: any ActionProviderProtocol,
        isAutoLockEnabled: Bool = false,
        lockOnUnknown: Bool = false
    ) {
        self.actionProvider = actionProvider
        self.isAutoLockEnabled = isAutoLockEnabled
        self.lockOnUnknown = lockOnUnknown
    }

    /// Evaluates state machine transitions and dispatches actions if authorized.
    @discardableResult
    public func handleStateTransition(
        from oldState: ProximityState,
        to newState: ProximityState,
        reason: String
    ) async -> ActionResult? {
        let (shouldLock, rejectedResult) = evaluateTransitionSync(oldState: oldState, newState: newState)
        if let rejected = rejectedResult {
            onPolicyDecision?(.requestLock, rejected)
            return rejected
        }

        guard shouldLock else {
            return nil
        }

        do {
            let result = try await actionProvider.requestLock()
            recordExecutionSuccess()
            onPolicyDecision?(.requestLock, result)
            return result
        } catch {
            let result = ActionResult.rejected(.requestLock, reason: "Lock request execution failed: \(error.localizedDescription)")
            onPolicyDecision?(.requestLock, result)
            return result
        }
    }

    private func evaluateTransitionSync(
        oldState: ProximityState,
        newState: ProximityState
    ) -> (shouldLock: Bool, rejectedResult: ActionResult?) {
        lock.lock()
        defer { lock.unlock() }

        // 1. If returning to NEAR: reset the departure lock latch
        if newState.isNear {
            hasLockedForCurrentDeparture = false
            return (false, nil)
        }

        // 2. If entering FAR: evaluate lock policy
        if newState.isFar {
            guard isAutoLockEnabled else {
                _locksSuppressedCount += 1
                return (false, .rejected(.requestLock, reason: "Auto-lock is disabled by user policy"))
            }

            guard !hasLockedForCurrentDeparture else {
                _locksSuppressedCount += 1
                return (false, .rejected(.requestLock, reason: "Lock request suppressed: already locked for this departure (idempotent)"))
            }

            hasLockedForCurrentDeparture = true
            _lockAttemptsCount += 1
            return (true, nil)
        }

        // 3. If entering UNKNOWN:
        if newState.isUnknown {
            if lockOnUnknown && isAutoLockEnabled && !hasLockedForCurrentDeparture {
                hasLockedForCurrentDeparture = true
                _lockAttemptsCount += 1
                return (true, nil)
            } else {
                return (false, nil)
            }
        }

        return (false, nil)
    }

    private func recordExecutionSuccess() {
        lock.lock()
        defer { lock.unlock() }
        _locksExecutedCount += 1
    }

    /// Resets policy latches and metrics.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        hasLockedForCurrentDeparture = false
        _lockAttemptsCount = 0
        _locksExecutedCount = 0
        _locksSuppressedCount = 0
    }
}
