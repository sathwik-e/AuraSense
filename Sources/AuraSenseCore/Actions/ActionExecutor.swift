import Foundation

/// Serialized policy action executor ensuring system actions are current-state-valid,
/// idempotent, and invalidated on state changes or health loss.
///
/// Uses a true async actor-owned permit (AsyncSerialPermit) so that at most one
/// lock or wake action runs at any time without holding an NSLock across an await.
/// Monotonic generation tokens prevent stale/delayed security actions per ARCHITECTURE.md.
public final class ActionExecutor: @unchecked Sendable {
    private let generationLock = NSLock()
    private var _currentGeneration: Int64 = 0

    /// Actor that serializes execution: only one action can hold the permit at a time.
    private let serialActor = ActionSerialActor()

    public var currentGeneration: Int64 {
        generationLock.lock()
        defer { generationLock.unlock() }
        return _currentGeneration
    }

    public init() {}

    /// Advances the generation token and returns the new monotonic generation.
    /// Must be called exactly once per state transition, before issuing the token.
    @discardableResult
    public func advanceGeneration(reason: String) -> Int64 {
        generationLock.lock()
        defer { generationLock.unlock() }
        _currentGeneration += 1
        return _currentGeneration
    }

    /// Explicitly invalidates pending actions when candidate or scanner health is lost.
    /// Does NOT advance the generation for transitions that themselves need a valid token
    /// (callers should use advanceGeneration for the transition, then decide whether to
    /// call invalidate for a different reason).
    public func invalidate(reason: String) {
        generationLock.lock()
        defer { generationLock.unlock() }
        _currentGeneration += 1
    }

    /// Verifies if a given generation token is still current and valid.
    public func isGenerationValid(_ generation: Int64) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation == _currentGeneration
    }

    /// Executes an action serially with pre-dispatch and in-flight generation validation.
    /// Only one action runs at a time (permit-based serialization via async actor).
    /// Stale actions are cancelled before reaching the OS side effect.
    public func executeSerialized(
        action: SecurityAction,
        generation: Int64,
        validate: @Sendable @escaping () -> Bool,
        perform: @Sendable @escaping (_ isValid: @Sendable @escaping () -> Bool) async throws -> ActionResult
    ) async -> ActionResult {
        // Pre-dispatch check before acquiring permit (Findings 19 & 20)
        guard !Task.isCancelled && isGenerationValid(generation) && validate() else {
            return .rejected(action, reason: "Action cancelled before dispatch: task cancelled, state, or generation changed")
        }

        // Live validation closure that can be polled at any suspension point
        let liveValidator: @Sendable () -> Bool = { [weak self] in
            guard !Task.isCancelled else { return false }
            guard let self = self else { return false }
            return self.isGenerationValid(generation) && validate()
        }

        // Acquire serial permit — suspends until previous action completes
        return await serialActor.runExclusive(action: action) {
            // Re-check immediately after acquiring permit (state may have changed while waiting)
            guard !Task.isCancelled && liveValidator() else {
                return .rejected(action, reason: "Action cancelled after acquiring permit: task cancelled, stale generation, or invalid state")
            }

            do {
                return try await perform(liveValidator)
            } catch {
                return .rejected(action, reason: "Action execution threw error: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Serial Permit Actor

/// Actor that serializes async action execution.
/// At most one task holds the permit at a time; others queue awaiting their turn.
private actor ActionSerialActor {
    private var isExecuting = false
    private var waitingContinuation: CheckedContinuation<Bool, Never>?

    func runExclusive(
        action: SecurityAction,
        body: @Sendable () async -> ActionResult
    ) async -> ActionResult {
        let acquired = await acquire()
        guard acquired else {
            return .rejected(action, reason: "Action superseded while waiting for the execution permit")
        }

        let result = await body()
        release()
        return result
    }

    private func acquire() async -> Bool {
        guard isExecuting else {
            isExecuting = true
            return true
        }

        waitingContinuation?.resume(returning: false)
        return await withCheckedContinuation { continuation in
            waitingContinuation = continuation
        }
    }

    private func release() {
        if let continuation = waitingContinuation {
            waitingContinuation = nil
            continuation.resume(returning: true)
        } else {
            isExecuting = false
        }
    }
}
