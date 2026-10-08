import Foundation
import CoreGraphics

/// Represents the active macOS window server session state.
public struct SessionState: Sendable, Equatable, Codable {
    public let isScreenLocked: Bool
    public let isOnConsole: Bool
    public let isLoginDone: Bool
    public let username: String?

    public init(
        isScreenLocked: Bool = false,
        isOnConsole: Bool = true,
        isLoginDone: Bool = true,
        username: String? = nil
    ) {
        self.isScreenLocked = isScreenLocked
        self.isOnConsole = isOnConsole
        self.isLoginDone = isLoginDone
        self.username = username
    }
}

/// Protocol for querying macOS lock screen and session state.
public protocol LockScreenStateDetectorProtocol: Sendable {
    func currentSessionState() -> SessionState
}

/// Native macOS lock screen detector using CoreGraphics session dictionary.
public final class MacOSLockScreenStateDetector: LockScreenStateDetectorProtocol, @unchecked Sendable {
    public init() {}

    public func currentSessionState() -> SessionState {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return SessionState(isScreenLocked: false, isOnConsole: true, isLoginDone: true, username: nil)
        }

        // Keys per macOS CoreGraphics window server session dictionary:
        // "CGSSessionScreenIsLocked": 1 or true when locked
        // "kCGSSessionOnConsoleKey": 1 when on console
        // "kCGSessionLoginDoneKey": 1 when session login complete
        // "kCGSSessionUserNameKey": current username string
        let isLocked: Bool
        if let lockedNum = dict["CGSSessionScreenIsLocked"] as? NSNumber {
            isLocked = lockedNum.boolValue
        } else if let lockedBool = dict["CGSSessionScreenIsLocked"] as? Bool {
            isLocked = lockedBool
        } else {
            isLocked = false
        }

        let onConsole: Bool
        if let consoleNum = dict["kCGSSessionOnConsoleKey"] as? NSNumber {
            onConsole = consoleNum.boolValue
        } else {
            onConsole = true
        }

        let loginDone: Bool
        if let loginNum = dict["kCGSessionLoginDoneKey"] as? NSNumber {
            loginDone = loginNum.boolValue
        } else {
            loginDone = true
        }

        let username = dict["kCGSSessionUserNameKey"] as? String

        return SessionState(
            isScreenLocked: isLocked,
            isOnConsole: onConsole,
            isLoginDone: loginDone,
            username: username
        )
    }
}

/// Mock detector for unit testing session states.
public final class MockLockScreenStateDetector: LockScreenStateDetectorProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _state: SessionState

    public var state: SessionState {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _state
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _state = newValue
        }
    }

    public init(state: SessionState = SessionState()) {
        self._state = state
    }

    public func currentSessionState() -> SessionState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }
}

/// Supported authentication paths per Phase 6 security architecture.
public enum SupportedAuthenticationPath: String, Sendable, Codable {
    case nativeDisplayWakeBiometric = "Native Display Wake & Biometric/Touch ID Prompt"
    case nativeAppleWatchContinuity = "Native Apple Watch Auto Unlock (Continuity)"
    case plaintextPasswordInjectionProhibited = "Plaintext Password Injection (Prohibited)"
}

/// Coordinator enforcing Phase 6 security constraints for authentication and unlocking.
/// Guarantees zero plaintext password storage or injection.
public final class SecureAuthenticationCoordinator: @unchecked Sendable {
    public let detector: any LockScreenStateDetectorProtocol

    public init(detector: any LockScreenStateDetectorProtocol = MacOSLockScreenStateDetector()) {
        self.detector = detector
    }

    /// Evaluates the active unlock path for the current environment.
    public func evaluateUnlockPath() -> SupportedAuthenticationPath {
        return .nativeDisplayWakeBiometric
    }

    /// Validates whether a credential entry request is permissible.
    /// Strictly rejects all plaintext password injection attempts per Phase 6 requirements.
    public func validateCredentialEntryAttempt() throws {
        throw ActionError.actionDisabled(
            "Plaintext password storage and injection are strictly prohibited per Phase 6 security requirements. Use native Touch ID or Apple Watch Auto Unlock."
        )
    }
}
