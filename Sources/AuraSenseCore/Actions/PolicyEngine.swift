import Foundation

/// Action policy engine evaluating proximity transitions and executing authorized system actions.
/// Strictly enforces opt-in, idempotency, serialized execution, and accurate telemetry per ARCHITECTURE.md.
public final class PolicyEngine: @unchecked Sendable {
    private let lock = NSLock()
    public let actionProvider: any ActionProviderProtocol

    // User policy configuration
    public var isAutoLockEnabled: Bool
    public var isAutoWakeEnabled: Bool
    public var lockOnUnknown: Bool

    // Idempotency latches
    private var hasLockedForCurrentDeparture: Bool = false
    private var hasWokenForCurrentArrival: Bool = false

    // Telemetry - Locks
    private var _lockAttemptsCount: Int = 0
    private var _locksExecutedCount: Int = 0
    private var _locksRejectedCount: Int = 0
    private var _locksUnsupportedCount: Int = 0
    private var _locksSuppressedCount: Int = 0

    // Telemetry - Wakes
    private var _wakeAttemptsCount: Int = 0
    private var _wakesExecutedCount: Int = 0
    private var _wakesRejectedCount: Int = 0
    private var _wakesUnsupportedCount: Int = 0
    private var _wakesSuppressedCount: Int = 0

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

    public var locksRejectedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _locksRejectedCount
    }

    public var locksUnsupportedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _locksUnsupportedCount
    }

    public var locksSuppressedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _locksSuppressedCount
    }

    public var wakeAttemptsCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _wakeAttemptsCount
    }

    public var wakesExecutedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _wakesExecutedCount
    }

    public var wakesRejectedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _wakesRejectedCount
    }

    public var wakesUnsupportedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _wakesUnsupportedCount
    }

    public var wakesSuppressedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _wakesSuppressedCount
    }

    public var onPolicyDecision: (@Sendable (SecurityAction, ActionResult) -> Void)?

    private enum PolicyTransitionDecision {
        case none
        case lock
        case wake
        case rejected(SecurityAction, String)
    }

    public init(
        actionProvider: any ActionProviderProtocol,
        isAutoLockEnabled: Bool = false,
        isAutoWakeEnabled: Bool = true,
        lockOnUnknown: Bool = false
    ) {
        self.actionProvider = actionProvider
        self.isAutoLockEnabled = isAutoLockEnabled
        self.isAutoWakeEnabled = isAutoWakeEnabled
        self.lockOnUnknown = lockOnUnknown
    }

    /// Evaluates state machine transitions and dispatches actions if authorized.
    @discardableResult
    public func handleStateTransition(
        from oldState: ProximityState,
        to newState: ProximityState,
        reason: String,
        generation: Int64? = nil,
        isValid: (@Sendable () -> Bool)? = nil
    ) async -> ActionResult? {
        let decision = evaluateTransitionSync(oldState: oldState, newState: newState)

        switch decision {
        case .none:
            return nil

        case .rejected(let action, let reasonText):
            let result = ActionResult.rejected(action, reason: reasonText)
            recordActionOutcome(action: action, result: result)
            onPolicyDecision?(action, result)
            return result

        case .lock:
            do {
                let result = try await actionProvider.requestLock(isValid: isValid)
                recordActionOutcome(action: .requestLock, result: result)
                onPolicyDecision?(.requestLock, result)
                return result
            } catch {
                let result = ActionResult.rejected(.requestLock, reason: "Lock request execution failed: \(error.localizedDescription)")
                recordActionOutcome(action: .requestLock, result: result)
                onPolicyDecision?(.requestLock, result)
                return result
            }

        case .wake:
            do {
                let result = try await actionProvider.wakeDisplay(isValid: isValid)
                recordActionOutcome(action: .wakeDisplay, result: result)
                onPolicyDecision?(.wakeDisplay, result)
                return result
            } catch {
                let result = ActionResult.rejected(.wakeDisplay, reason: "Display wake execution failed: \(error.localizedDescription)")
                recordActionOutcome(action: .wakeDisplay, result: result)
                onPolicyDecision?(.wakeDisplay, result)
                return result
            }
        }
    }

    private func evaluateTransitionSync(
        oldState: ProximityState,
        newState: ProximityState
    ) -> PolicyTransitionDecision {
        lock.lock()
        defer { lock.unlock() }

        // 1. If entering NEAR: evaluate display wake policy
        if newState.isNear {
            hasLockedForCurrentDeparture = false

            if !oldState.isNear && !hasWokenForCurrentArrival {
                guard isAutoWakeEnabled else {
                    _wakesSuppressedCount += 1
                    return .rejected(.wakeDisplay, "Auto-wake is disabled by user policy")
                }
                _wakeAttemptsCount += 1
                // Reserve latch BEFORE suspension to prevent concurrent admission race (Finding 15)
                hasWokenForCurrentArrival = true
                return .wake
            }
            return .none
        }

        // 2. If entering FAR: evaluate lock policy
        if newState.isFar {
            hasWokenForCurrentArrival = false

            guard isAutoLockEnabled else {
                _locksSuppressedCount += 1
                return .rejected(.requestLock, "Auto-lock is disabled by user policy")
            }

            guard !hasLockedForCurrentDeparture else {
                _locksSuppressedCount += 1
                return .rejected(.requestLock, "Lock request suppressed: already locked for this departure (idempotent)")
            }

            _lockAttemptsCount += 1
            // Reserve latch BEFORE suspension to prevent concurrent admission race (Finding 15)
            hasLockedForCurrentDeparture = true
            return .lock
        }

        // 3. If entering UNKNOWN:
        if newState.isUnknown {
            hasWokenForCurrentArrival = false

            if lockOnUnknown && isAutoLockEnabled && !hasLockedForCurrentDeparture {
                _lockAttemptsCount += 1
                hasLockedForCurrentDeparture = true  // Reserve before suspension
                return .lock
            }
            return .none
        }

        return .none
    }

    private func recordActionOutcome(action: SecurityAction, result: ActionResult) {
        lock.lock()
        defer { lock.unlock() }

        switch action {
        case .requestLock:
            switch result {
            case .executed:
                _locksExecutedCount += 1
                hasLockedForCurrentDeparture = true   // Committed — departure is locked
            case .rejected:
                _locksRejectedCount += 1
                hasLockedForCurrentDeparture = false  // Release reservation — allow retry
            case .unsupported:
                _locksUnsupportedCount += 1
                hasLockedForCurrentDeparture = false  // Release reservation — lock unsupported
            }

        case .wakeDisplay:
            switch result {
            case .executed:
                _wakesExecutedCount += 1
                hasWokenForCurrentArrival = true      // Committed — arrival is awoken
            case .rejected:
                _wakesRejectedCount += 1
                hasWokenForCurrentArrival = false     // Release reservation — allow retry
            case .unsupported:
                _wakesUnsupportedCount += 1
                hasWokenForCurrentArrival = false     // Release reservation
            }

        default:
            break
        }
    }

    /// Resets policy latches and metrics.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        hasLockedForCurrentDeparture = false
        hasWokenForCurrentArrival = false
        _lockAttemptsCount = 0
        _locksExecutedCount = 0
        _locksRejectedCount = 0
        _locksUnsupportedCount = 0
        _locksSuppressedCount = 0
        _wakeAttemptsCount = 0
        _wakesExecutedCount = 0
        _wakesRejectedCount = 0
        _wakesUnsupportedCount = 0
        _wakesSuppressedCount = 0
    }
}
