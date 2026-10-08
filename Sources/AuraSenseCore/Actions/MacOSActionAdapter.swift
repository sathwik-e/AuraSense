import Foundation
import Darwin
import IOKit.pwr_mgt

/// Native macOS Action Adapter executing supported system operations.
/// Supports both live execution and a dryRun verification mode.
public final class MacOSActionAdapter: ActionProviderProtocol, @unchecked Sendable {
    private let lock = NSLock()
    public var isDryRun: Bool
    public let inputSynthesizer: (any InputSynthesizerProtocol)?

    private var lastLockRequestTime: Date?
    private let minimumLockInterval: TimeInterval

    private var lastWakeRequestTime: Date?
    private let minimumWakeInterval: TimeInterval

    public var isLockSupported: Bool {
        return true
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
        inputSynthesizer: (any InputSynthesizerProtocol)? = nil
    ) {
        self.isDryRun = isDryRun
        self.minimumLockInterval = minimumLockInterval
        self.minimumWakeInterval = minimumWakeInterval
        self.inputSynthesizer = inputSynthesizer ?? MacOSInputSynthesizer(isDryRun: isDryRun)
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
        guard checkLockThrottleAndRecord() else {
            return .rejected(.requestLock, reason: "Lock request throttled by idempotency latch")
        }

        if isDryRun {
            return .executed(.requestLock, details: "Dry-run mode: Screen lock simulated without invoking OS API")
        }

        // 1. Primary mechanism: SACLockScreenImmediate via dynamic loader
        if let result = executeSACLock() {
            return result
        }

        // 2. Secondary fallback: pmset displaysleepnow
        if let result = executeDisplaySleepFallback() {
            return result
        }

        throw ActionError.executionFailed("No available macOS lock screen mechanism succeeded")
    }

    public func wakeDisplay() async throws -> ActionResult {
        guard checkWakeThrottleAndRecord() else {
            return .rejected(.wakeDisplay, reason: "Display wake request throttled by idempotency latch")
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

        // 3. Optional synthetic wake key to dismiss screensaver / activate password prompt
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

    // MARK: - Native Lock Implementation

    private func executeSACLock() -> ActionResult? {
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        guard let handle = dlopen(path, RTLD_LAZY) else {
            return nil
        }
        defer { dlclose(handle) }

        guard let sym = dlsym(handle, "SACLockScreenImmediate") else {
            return nil
        }

        typealias LockFunction = @convention(c) () -> Void
        let lockFunc = unsafeBitCast(sym, to: LockFunction.self)
        lockFunc()
        return .executed(.requestLock, details: "Invoked SACLockScreenImmediate successfully")
    }

    private func executeDisplaySleepFallback() -> ActionResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return .executed(.requestLock, details: "Invoked pmset displaysleepnow fallback")
            }
        } catch {
            return nil
        }
        return nil
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
