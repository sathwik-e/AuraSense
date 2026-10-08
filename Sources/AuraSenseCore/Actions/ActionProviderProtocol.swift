import Foundation

/// Interface for executing macOS system level actions per ARCHITECTURE.md.
public protocol ActionProviderProtocol: Sendable {
    /// Indicates whether screen locking is supported in this runtime environment.
    var isLockSupported: Bool { get }

    /// Indicates whether display wake is supported.
    var isWakeSupported: Bool { get }

    /// Indicates whether credential entry is supported and authorized.
    var isCredentialEntrySupported: Bool { get }

    /// Requests to lock the macOS screen.
    func requestLock() async throws -> ActionResult

    /// Requests to wake the display.
    func wakeDisplay() async throws -> ActionResult

    /// Requests credential entry into the verified login window (opt-in only per ARCHITECTURE.md).
    func requestCredentialEntry() async throws -> ActionResult

    /// Posts a user notification.
    func notify(title: String, message: String) async throws -> ActionResult

    /// Opens application settings.
    func openSettings() async throws -> ActionResult

    /// Explicit no-op.
    func noOp() -> ActionResult
}

/// Safe Action Provider for Phase 1 that guarantees no lock or unlock actions are performed.
public struct Phase1RestrictedActionProvider: ActionProviderProtocol {
    public init() {}

    public var isLockSupported: Bool {
        return false // Explicitly false in Phase 1
    }

    public var isWakeSupported: Bool {
        return false
    }

    public var isCredentialEntrySupported: Bool {
        return false
    }

    public func requestLock() async throws -> ActionResult {
        throw ActionError.phase1ConstraintViolation
    }

    public func wakeDisplay() async throws -> ActionResult {
        return .rejected(.wakeDisplay, reason: "Display wake not enabled in Phase 1.")
    }

    public func requestCredentialEntry() async throws -> ActionResult {
        throw ActionError.phase1ConstraintViolation
    }

    public func notify(title: String, message: String) async throws -> ActionResult {
        return .executed(.notify, details: "Notification logged: \(title) - \(message)")
    }

    public func openSettings() async throws -> ActionResult {
        return .rejected(.openSettings, reason: "Settings window not implemented in Phase 1.")
    }

    public func noOp() -> ActionResult {
        return .executed(.noOp, details: "Phase 1 safe no-op.")
    }
}
