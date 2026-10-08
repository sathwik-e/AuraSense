import Foundation

/// Interface for executing macOS system level actions.
public protocol ActionProviderProtocol: Sendable {
    /// Indicates whether screen locking is supported in this runtime environment.
    var isLockSupported: Bool { get }

    /// Requests to lock the macOS screen.
    func lockScreen() async throws -> ActionResult

    /// Requests to wake the display.
    func wakeDisplay() async throws -> ActionResult
}

/// Safe Action Provider for Phase 1 that guarantees no lock or unlock actions are performed.
public struct Phase1RestrictedActionProvider: ActionProviderProtocol {
    public init() {}

    public var isLockSupported: Bool {
        return false // Explicitly false in Phase 1
    }

    public func lockScreen() async throws -> ActionResult {
        throw ActionError.phase1ConstraintViolation
    }

    public func wakeDisplay() async throws -> ActionResult {
        return .rejected(.wakeDisplay, reason: "Display wake not enabled in Phase 1")
    }
}
