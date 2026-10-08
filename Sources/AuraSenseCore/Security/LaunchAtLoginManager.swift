import Foundation
import ServiceManagement

/// Protocol defining macOS launch-at-login control.
public protocol LaunchAtLoginProtocol: Sendable {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

/// Native macOS 13+ launch-at-login manager using ServiceManagement SMAppService.
public final class SMAppServiceLaunchAtLoginManager: LaunchAtLoginProtocol, @unchecked Sendable {
    public init() {}

    public var isEnabled: Bool {
        return SMAppService.mainApp.status == .enabled
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        }
    }
}

/// Mock launch-at-login manager for unit testing.
public final class MockLaunchAtLoginManager: LaunchAtLoginProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _isEnabled: Bool

    public var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isEnabled
    }

    public init(initialEnabled: Bool = false) {
        self._isEnabled = initialEnabled
    }

    public func setEnabled(_ enabled: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        _isEnabled = enabled
    }
}
