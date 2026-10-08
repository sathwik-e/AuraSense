import Foundation

/// Actions that can be performed on the macOS session per ARCHITECTURE.md.
public enum SecurityAction: String, Sendable, Codable {
    case requestLock = "Request Lock"
    case wakeDisplay = "Wake Display"
    case requestCredentialEntry = "Request Credential Entry"
    case notify = "Notify"
    case openSettings = "Open Settings"
    case noOp = "No Operation"
}

/// Result returned from executing a security action.
public enum ActionResult: Sendable, Codable, Equatable {
    case executed(SecurityAction, details: String)
    case unsupported(SecurityAction, reason: String)
    case rejected(SecurityAction, reason: String)
}

/// Errors raised by action dispatching or policy violations.
public enum ActionError: LocalizedError, Sendable {
    case phase1ConstraintViolation
    case actionDisabled(String)
    case unauthorized(String)
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .phase1ConstraintViolation:
            return "Phase 1 Constraint Enforced: Locking, unlocking, and credential entry on the Mac are strictly prohibited."
        case .actionDisabled(let reason):
            return "Action is disabled: \(reason)"
        case .unauthorized(let reason):
            return "Action is unauthorized: \(reason)"
        case .executionFailed(let reason):
            return "Action execution failed: \(reason)"
        }
    }
}
