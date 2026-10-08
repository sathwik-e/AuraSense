import Foundation
import CoreGraphics
import ApplicationServices

/// Protocol defining safe input synthesis operations on macOS.
public protocol InputSynthesizerProtocol: Sendable {
    /// Indicates whether Accessibility permissions (TCC) are granted for synthetic input.
    var isAccessibilityAuthorized: Bool { get }

    /// Prompts the user to grant Accessibility permissions if not already granted.
    func promptAccessibilityAuthorizationIfNeeded() -> Bool

    /// Sends a safe non-destructive key press (e.g. Space or Shift) to dismiss the screensaver
    /// or awaken the login screen password prompt without injecting credentials.
    func sendWakeKey() async throws -> ActionResult
}

/// Native macOS input synthesizer using CoreGraphics and Accessibility.
public final class MacOSInputSynthesizer: InputSynthesizerProtocol, @unchecked Sendable {
    public var isDryRun: Bool

    // Virtual key codes for macOS:
    // 0x31 = Space bar
    // 0x38 = Left Shift
    // 0x35 = Escape
    private let wakeVirtualKeyCode: CGKeyCode

    public var isAccessibilityAuthorized: Bool {
        return AXIsProcessTrusted()
    }

    public init(isDryRun: Bool = false, wakeVirtualKeyCode: CGKeyCode = 0x31) {
        self.isDryRun = isDryRun
        self.wakeVirtualKeyCode = wakeVirtualKeyCode
    }

    public func promptAccessibilityAuthorizationIfNeeded() -> Bool {
        if AXIsProcessTrusted() {
            return true
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public func sendWakeKey() async throws -> ActionResult {
        if isDryRun {
            return .executed(.wakeDisplay, details: "Dry-run mode: Synthesized wake key simulated (keyCode: \(wakeVirtualKeyCode))")
        }

        guard isAccessibilityAuthorized else {
            return .rejected(
                .wakeDisplay,
                reason: "Input synthesis blocked: macOS Accessibility permission is not granted"
            )
        }

        // Post key down followed by key up
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: wakeVirtualKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: wakeVirtualKeyCode, keyDown: false) else {
            throw ActionError.executionFailed("Failed to create CGEvent for wake key")
        }

        keyDown.post(tap: .cghidEventTap)
        // Brief interval between keydown and keyup
        try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
        keyUp.post(tap: .cghidEventTap)

        return .executed(.wakeDisplay, details: "Synthesized wake key dispatched to cghidEventTap")
    }
}

/// Mock input synthesizer for testing.
public final class MockInputSynthesizer: InputSynthesizerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    public var isAccessibilityAuthorized: Bool
    private var _wakeKeyCallCount: Int = 0

    public var wakeKeyCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _wakeKeyCallCount
    }

    public init(isAccessibilityAuthorized: Bool = true) {
        self.isAccessibilityAuthorized = isAccessibilityAuthorized
    }

    private func incrementCallCount() {
        lock.lock()
        defer { lock.unlock() }
        _wakeKeyCallCount += 1
    }

    public func promptAccessibilityAuthorizationIfNeeded() -> Bool {
        return isAccessibilityAuthorized
    }

    public func sendWakeKey() async throws -> ActionResult {
        incrementCallCount()
        guard isAccessibilityAuthorized else {
            return .rejected(.wakeDisplay, reason: "Mock: Accessibility permission denied")
        }
        return .executed(.wakeDisplay, details: "Mock wake key synthesized successfully")
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        _wakeKeyCallCount = 0
    }
}
