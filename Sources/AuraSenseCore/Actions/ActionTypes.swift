import Foundation

/// Actions that can be performed on the macOS session.
public enum SecurityAction: String, Sendable, Codable {
    case lockScreen = "Lock Screen"
    case wakeDisplay = "Wake Display"
    case notify = "Notify"
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
            return "Phase 1 Constraint Enforced: Locking and unlocking the Mac is strictly prohibited."
        case .actionDisabled(let reason):
            return "Action is disabled: \(reason)"
        case .unauthorized(let reason):
            return "Action is unauthorized: \(reason)"
        case .executionFailed(let reason):
            return "Action execution failed: \(reason)"
        }
    }
}
