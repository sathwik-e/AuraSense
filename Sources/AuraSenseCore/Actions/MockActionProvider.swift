import Foundation

/// Simulated action provider for testing policy decisions and action gating
/// without triggering live macOS system events.
public final class MockActionProvider: ActionProviderProtocol, @unchecked Sendable {
    private let lock = NSLock()

    public var isLockSupported: Bool
    public var isWakeSupported: Bool
    public var isCredentialEntrySupported: Bool

    public var shouldSucceed: Bool
    public var onBeforeLock: (@Sendable () async -> Void)?
    public var nextLockResult: ActionResult?
    public var nextWakeResult: ActionResult?

    private var _lockCallCount: Int = 0
    private var _wakeCallCount: Int = 0
    private var _credentialCallCount: Int = 0
    private var _notifyCallCount: Int = 0

    public var lockCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _lockCallCount
    }

    public var wakeCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _wakeCallCount
    }

    public var credentialCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _credentialCallCount
    }

    public init(
        isLockSupported: Bool = true,
        isWakeSupported: Bool = true,
        isCredentialEntrySupported: Bool = false,
        shouldSucceed: Bool = true
    ) {
        self.isLockSupported = isLockSupported
        self.isWakeSupported = isWakeSupported
        self.isCredentialEntrySupported = isCredentialEntrySupported
        self.shouldSucceed = shouldSucceed
    }

    private func incrementLockCount() {
        lock.lock()
        defer { lock.unlock() }
        _lockCallCount += 1
    }

    private func incrementWakeCount() {
        lock.lock()
        defer { lock.unlock() }
        _wakeCallCount += 1
    }

    private func incrementCredentialCount() {
        lock.lock()
        defer { lock.unlock() }
        _credentialCallCount += 1
    }

    private func incrementNotifyCount() {
        lock.lock()
        defer { lock.unlock() }
        _notifyCallCount += 1
    }

    public func requestLock() async throws -> ActionResult {
        return try await requestLock(isValid: nil)
    }

    public func requestLock(isValid: (@Sendable () -> Bool)?) async throws -> ActionResult {
        if let hook = onBeforeLock {
            await hook()
        }

        if let check = isValid, !check() {
            return .rejected(.requestLock, reason: "Lock request invalidated before execution")
        }

        incrementLockCount()

        if let custom = nextLockResult {
            return custom
        }

        guard isLockSupported else {
            return .unsupported(.requestLock, reason: "Screen locking not supported")
        }
        guard shouldSucceed else {
            throw ActionError.executionFailed("Simulated lock failure")
        }
        return .executed(.requestLock, details: "Mock lock executed successfully")
    }

    public func wakeDisplay() async throws -> ActionResult {
        return try await wakeDisplay(isValid: nil)
    }

    public func wakeDisplay(isValid: (@Sendable () -> Bool)?) async throws -> ActionResult {
        if let check = isValid, !check() {
            return .rejected(.wakeDisplay, reason: "Display wake invalidated before execution")
        }

        incrementWakeCount()

        if let custom = nextWakeResult {
            return custom
        }

        guard isWakeSupported else {
            return .unsupported(.wakeDisplay, reason: "Display wake not supported")
        }
        return .executed(.wakeDisplay, details: "Mock wake executed successfully")
    }

    public func requestCredentialEntry() async throws -> ActionResult {
        incrementCredentialCount()

        guard isCredentialEntrySupported else {
            throw ActionError.actionDisabled("Credential entry not supported")
        }
        return .executed(.requestCredentialEntry, details: "Mock credential entered")
    }

    public func notify(title: String, message: String) async throws -> ActionResult {
        incrementNotifyCount()
        return .executed(.notify, details: "\(title): \(message)")
    }

    public func openSettings() async throws -> ActionResult {
        return .executed(.openSettings, details: "Mock open settings")
    }

    public func noOp() -> ActionResult {
        return .executed(.noOp, details: "Mock noOp")
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        _lockCallCount = 0
        _wakeCallCount = 0
        _credentialCallCount = 0
        _notifyCallCount = 0
    }
}
