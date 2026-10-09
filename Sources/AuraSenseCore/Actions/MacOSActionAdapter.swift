import Foundation
import Darwin
import IOKit.pwr_mgt

public protocol MacOSScreenLockMechanismProtocol: Sendable {
    var isAvailable: Bool { get }
    var isSessionLocked: Bool { get }
    func lockSession() throws -> Bool
}

public final class PrivateLoginFrameworkScreenLocker: MacOSScreenLockMechanismProtocol, @unchecked Sendable {
    private typealias LockFunction = @convention(c) () -> Int32
    private let frameworkHandle: UnsafeMutableRawPointer?
    private let lockFunction: LockFunction?
    private let isLockedProvider: @Sendable () -> Bool

    public var isAvailable: Bool { lockFunction != nil }
    public var isSessionLocked: Bool { isLockedProvider() }

    public init(isLockedProvider: @escaping @Sendable () -> Bool = {
        MacOSLockScreenStateDetector().currentSessionState().isScreenLocked
    }) {
        let frameworkPath = "/System/Library/PrivateFrameworks/login.framework/login"
        let handle = dlopen(frameworkPath, RTLD_NOW | RTLD_LOCAL)
        self.frameworkHandle = handle
        self.isLockedProvider = isLockedProvider
        if let handle, let symbol = dlsym(handle, "SACLockScreenImmediate") {
            self.lockFunction = unsafeBitCast(symbol, to: LockFunction.self)
        } else {
            self.lockFunction = nil
        }
    }

    public func lockSession() throws -> Bool {
        guard let lockFunction else {
            throw ActionError.executionFailed("macOS private screen-lock entry point is unavailable")
        }
        let status = lockFunction()
        guard status == 0 else {
            throw ActionError.executionFailed("SACLockScreenImmediate returned status \(status)")
        }
        for _ in 0..<10 {
            if isSessionLocked { return true }
            usleep(100_000)
        }
        return isSessionLocked
    }
}

/// Native macOS Action Adapter executing supported system operations.
/// Supports both live execution and a dryRun verification mode.
public final class MacOSActionAdapter: ActionProviderProtocol, @unchecked Sendable {
    private let lock = NSLock()
    public var isDryRun: Bool
    public let inputSynthesizer: (any InputSynthesizerProtocol)?
    private let screenLocker: any MacOSScreenLockMechanismProtocol

    private var lastLockRequestTime: Date?
    private let minimumLockInterval: TimeInterval

    private var lastWakeRequestTime: Date?
    private let minimumWakeInterval: TimeInterval

    public var isLockSupported: Bool {
        return screenLocker.isAvailable
    }

    public var isWakeSupported: Bool {
        return true
    }

    public var isCredentialEntrySupported: Bool {
        return false // Research and security evaluation reserved for Phase 6
    }

    public init(
        isDryRun: Bool = false,
        minimumLockInterval: TimeInterval = 3.0,
        minimumWakeInterval: TimeInterval = 3.0,
        inputSynthesizer: (any InputSynthesizerProtocol)? = nil,
        screenLocker: any MacOSScreenLockMechanismProtocol = PrivateLoginFrameworkScreenLocker()
    ) {
        self.isDryRun = isDryRun
        self.minimumLockInterval = minimumLockInterval
        self.minimumWakeInterval = minimumWakeInterval
        self.inputSynthesizer = inputSynthesizer ?? MacOSInputSynthesizer(isDryRun: isDryRun)
        self.screenLocker = screenLocker
    }

    private func checkLockThrottleAndRecord() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        if let last = lastLockRequestTime, now.timeIntervalSince(last) < minimumLockInterval {
            return false
        }
        lastLockRequestTime = now
        return true
    }

    private func checkWakeThrottleAndRecord() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        if let last = lastWakeRequestTime, now.timeIntervalSince(last) < minimumWakeInterval {
            return false
        }
        lastWakeRequestTime = now
        return true
    }

    public func requestLock() async throws -> ActionResult {
        return try await requestLock(isValid: nil)
    }

    /// Concrete override: validates immediately before the irreversible OS lock call.
    /// A protocol-extension check-then-await is insufficient per ARCHITECTURE.md.
    public func requestLock(isValid: (@Sendable () -> Bool)?) async throws -> ActionResult {
        // Validate before throttle record so throttle window isn't consumed on cancellation
        if let check = isValid, !check() {
            return .rejected(.requestLock, reason: "Lock request invalidated before OS call")
        }

        guard checkLockThrottleAndRecord() else {
            return .rejected(.requestLock, reason: "Lock request throttled by idempotency latch")
        }

        // Final validation immediately before irreversible side effect
        if let check = isValid, !check() {
            return .rejected(.requestLock, reason: "Lock request invalidated at pre-OS-call gate")
        }

        if isDryRun {
            return .executed(.requestLock, details: "Dry-run mode: Screen lock simulated without invoking OS API")
        }

        guard screenLocker.isAvailable else {
            return .unsupported(.requestLock, reason: "The macOS screen-lock mechanism is unavailable on this system.")
        }
        if screenLocker.isSessionLocked {
            return .executed(.requestLock, details: "Session was already locked")
        }

        do {
            guard try screenLocker.lockSession() else {
                throw ActionError.executionFailed("Lock request returned success but macOS did not report a locked session")
            }
            return .executed(.requestLock, details: "macOS session lock was requested and verified")
        } catch {
            throw ActionError.executionFailed("macOS session lock failed: \(error.localizedDescription)")
        }
    }

    public func wakeDisplay() async throws -> ActionResult {
        return try await wakeDisplay(isValid: nil)
    }

    /// Concrete override: validates immediately before the irreversible OS wake call.
    public func wakeDisplay(isValid: (@Sendable () -> Bool)?) async throws -> ActionResult {
        if let check = isValid, !check() {
            return .rejected(.wakeDisplay, reason: "Display wake invalidated before OS call")
        }

        guard checkWakeThrottleAndRecord() else {
            return .rejected(.wakeDisplay, reason: "Display wake request throttled by idempotency latch")
        }

        // Final validation immediately before irreversible side effect
        if let check = isValid, !check() {
            return .rejected(.wakeDisplay, reason: "Display wake invalidated at pre-OS-call gate")
        }

        if isDryRun {
            _ = try? await inputSynthesizer?.sendWakeKey()
            return .executed(.wakeDisplay, details: "Dry-run mode: Display wake simulated without invoking OS API")
        }

        // 1. Primary native mechanism: IOPMAssertionDeclareUserActivity
        var wakeResult: ActionResult?
        if let result = executeNativeWake() {
            wakeResult = result
        } else if let result = executeCaffeinateFallback() {
            // 2. Secondary fallback: /usr/bin/caffeinate -u -t 2
            wakeResult = result
        }

        guard let confirmedWake = wakeResult else {
            throw ActionError.executionFailed("No available macOS display wake mechanism succeeded")
        }

        // 3. Optional synthetic wake key to dismiss screensaver / activate prompt
        if let synth = inputSynthesizer {
            _ = try? await synth.sendWakeKey()
        }

        return confirmedWake
    }

    public func requestCredentialEntry() async throws -> ActionResult {
        throw ActionError.actionDisabled("Credential entry is strictly disabled in Phase 5 (reserved for Phase 6 evaluation)")
    }

    public func notify(title: String, message: String) async throws -> ActionResult {
        return .executed(.notify, details: "\(title): \(message)")
    }

    public func openSettings() async throws -> ActionResult {
        return .rejected(.openSettings, reason: "Settings window reserved for Phase 7")
    }

    public func noOp() -> ActionResult {
        return .executed(.noOp, details: "macOS Action Adapter no-op")
    }

    // MARK: - Native Wake Implementation

    private func executeNativeWake() -> ActionResult? {
        var assertionID: IOPMAssertionID = 0
        let name = "AuraSense Proximity Display Wake" as CFString
        let ret = IOPMAssertionDeclareUserActivity(name, kIOPMUserActiveLocal, &assertionID)
        if ret == kIOReturnSuccess {
            return .executed(.wakeDisplay, details: "Invoked IOPMAssertionDeclareUserActivity (assertionID: \(assertionID))")
        }
        return nil
    }

    private func executeCaffeinateFallback() -> ActionResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-u", "-t", "2"]

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return .executed(.wakeDisplay, details: "Invoked /usr/bin/caffeinate -u -t 2 fallback")
            }
        } catch {
            return nil
        }
        return nil
    }
}
