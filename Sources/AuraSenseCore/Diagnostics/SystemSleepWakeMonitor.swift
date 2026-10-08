import Foundation
import AppKit

/// Protocol for monitoring system sleep and wake transitions.
public protocol SystemSleepWakeMonitorProtocol: Sendable {
    var isAsleep: Bool { get }
    func startMonitoring()
    func stopMonitoring()
}

/// Native macOS sleep and wake observer using NSWorkspace notifications.
public final class SystemSleepWakeMonitor: SystemSleepWakeMonitorProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _isAsleep: Bool = false
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    public var isAsleep: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isAsleep
    }

    public var onWillSleep: (@Sendable () -> Void)?
    public var onDidWake: (@Sendable () -> Void)?

    public init() {}

    deinit {
        stopMonitoring()
    }

    public func startMonitoring() {
        lock.lock()
        defer { lock.unlock() }

        guard sleepObserver == nil && wakeObserver == nil else { return }

        let center = NSWorkspace.shared.notificationCenter

        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.lock.lock()
            self._isAsleep = true
            self.lock.unlock()
            self.onWillSleep?()
        }

        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.lock.lock()
            self._isAsleep = false
            self.lock.unlock()
            self.onDidWake?()
        }
    }

    public func stopMonitoring() {
        lock.lock()
        defer { lock.unlock() }

        let center = NSWorkspace.shared.notificationCenter
        if let sleep = sleepObserver {
            center.removeObserver(sleep)
            sleepObserver = nil
        }
        if let wake = wakeObserver {
            center.removeObserver(wake)
            wakeObserver = nil
        }
    }
}

/// Mock sleep and wake monitor for unit testing.
public final class MockSleepWakeMonitor: SystemSleepWakeMonitorProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _isAsleep: Bool = false

    public var isAsleep: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isAsleep
    }

    public var onWillSleep: (@Sendable () -> Void)?
    public var onDidWake: (@Sendable () -> Void)?

    public init(initialAsleep: Bool = false) {
        self._isAsleep = initialAsleep
    }

    public func startMonitoring() {}
    public func stopMonitoring() {}

    public func simulateSleep() {
        lock.lock()
        _isAsleep = true
        lock.unlock()
        onWillSleep?()
    }

    public func simulateWake() {
        lock.lock()
        _isAsleep = false
        lock.unlock()
        onDidWake?()
    }
}
