import Foundation
import Darwin

/// Native macOS Action Adapter executing supported system operations.
/// Supports both live execution and a dryRun verification mode.
public final class MacOSActionAdapter: ActionProviderProtocol, @unchecked Sendable {
    private let lock = NSLock()
    public let isDryRun: Bool
    private var lastLockRequestTime: Date?
    private let minimumLockInterval: TimeInterval

    public var isLockSupported: Bool {
        return true
    }

    public var isWakeSupported: Bool {
        return false // Reserved for Phase 5
    }

    public var isCredentialEntrySupported: Bool {
        return false // Research/evaluation reserved for Phase 6
    }

    public init(isDryRun: Bool = false, minimumLockInterval: TimeInterval = 3.0) {
        self.isDryRun = isDryRun
        self.minimumLockInterval = minimumLockInterval
    }

    private func checkThrottleAndRecord() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        if let last = lastLockRequestTime, now.timeIntervalSince(last) < minimumLockInterval {
            return false
        }
        lastLockRequestTime = now
        return true
    }

    public func requestLock() async throws -> ActionResult {
        guard checkThrottleAndRecord() else {
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
        return .rejected(.wakeDisplay, reason: "Display wake not active in Phase 4 (reserved for Phase 5)")
    }

    public func requestCredentialEntry() async throws -> ActionResult {
        throw ActionError.actionDisabled("Credential entry is strictly disabled in Phase 4")
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
}
