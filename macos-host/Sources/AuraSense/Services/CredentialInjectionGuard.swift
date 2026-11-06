import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
import Carbon.HIToolbox

/// Single choke point for every code path that can type, paste, or copy the stored
/// Keychain password (proximity auto-unlock, ⌃⌥⌘Space instant fill,
/// the iPhone HTTP bridge, and Continuity BLE wake).
///
/// While a protected prompt is on screen (for example the "change trusted device" Mac
/// password check), credential injection is refused so AuraSense can never fill in the
/// password that authorizes changes to its own security configuration.
@MainActor
public final class CredentialInjectionGuard {
    public static let shared = CredentialInjectionGuard()

    /// Value written into `kCGEventSourceUserData` on every keyboard event AuraSense synthesizes,
    /// so protected fields can recognize and drop them ("AURA" in ASCII).
    public nonisolated static let syntheticEventMarker: Int64 = 0x4155_5241

    private var protectedPromptDepth = 0
    private var transientClipboardChangeCount: Int?

    private init() {}

    /// True while a protected prompt is visible; injection paths must not run.
    public var isProtectedPromptActive: Bool { protectedPromptDepth > 0 }

    public func beginProtectedPrompt() {
        protectedPromptDepth += 1
        wipeTransientClipboardNow()
    }

    public func endProtectedPrompt() {
        protectedPromptDepth = max(0, protectedPromptDepth - 1)
    }

    /// Returns false when credentials must not be injected right now (a protected prompt is open).
    public func mayInjectCredentials() -> Bool {
        !isProtectedPromptActive
    }

    /// Bundle identifiers of system processes that host genuine password prompts
    /// (authorization dialogs, the login window, LocalAuthentication UI).
    private static let systemAuthPromptBundleIDs: Set<String> = [
        "com.apple.SecurityAgent",
        "com.apple.loginwindow",
        "com.apple.coreautha",
        "com.apple.LocalAuthentication.UIAgent",
        "com.apple.CoreAuthUI"
    ]

    /// Decides whether typing the stored password into the currently focused element is allowed.
    /// Used by every focused-field path (⌃⌥⌘Space instant fill, the iPhone bridge, Continuity wake).
    /// The lock-screen unlock path does not use this (keystrokes go to loginwindow); it only needs
    /// `mayInjectCredentials()`.
    ///
    /// Refuses while a protected prompt is open, while AuraSense itself is frontmost, and while the
    /// AX focused element belongs to AuraSense's own process. With `requireSecureField`, also requires
    /// that the focused element is an `AXSecureTextField`, or that Secure Event Input is on because a
    /// system authentication prompt (SecurityAgent and friends) has focus.
    public func focusedFieldInjectionDecision(requireSecureField: Bool) -> (allowed: Bool, reason: String) {
        guard !isProtectedPromptActive else {
            return (false, "A protected AuraSense password prompt is open. Type the password yourself.")
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        if NSApp?.isActive == true || NSWorkspace.shared.frontmostApplication?.processIdentifier == ownPID {
            return (false, "AuraSense is the frontmost app; switch to the password prompt first.")
        }

        var focusedElement: AXUIElement?
        let sysWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(sysWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
           let ref = focusedRef,
           CFGetTypeID(ref) == AXUIElementGetTypeID() {
            focusedElement = (ref as! AXUIElement)
        }

        var focusedPID: pid_t = 0
        if let element = focusedElement {
            if AXUIElementGetPid(element, &focusedPID) == .success, focusedPID == ownPID {
                return (false, "The focused field belongs to AuraSense itself.")
            }
        }

        guard requireSecureField else {
            return (true, "Allowed")
        }

        // Only genuine macOS system password prompts qualify. A secure text field in an ordinary
        // app is NOT enough: web pages expose <input type=password> as AXSecureTextField and page
        // script can read what is typed, which would disclose the Mac password.
        if let element = focusedElement, focusedPID != 0,
           let bundleID = NSRunningApplication(processIdentifier: focusedPID)?.bundleIdentifier,
           Self.systemAuthPromptBundleIDs.contains(bundleID) {
            var subroleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef) == .success,
               let subrole = subroleRef as? String,
               subrole == "AXSecureTextField" {
                return (true, "Focused element is a secure field in \(bundleID).")
            }
        }

        // System authorization dialogs often do not expose their field over AX, but they always
        // enable Secure Event Input. Secure Event Input alone is not enough when a readable,
        // non-secure element of an ordinary app has focus (e.g. Terminal's Secure Keyboard Entry).
        if IsSecureEventInputEnabled() {
            // No AX focus (common for SecurityAgent). Browsers and Electron apps can also hide AX
            // focus while a password field holds Secure Input, so require that a system auth
            // prompt window is actually on screen.
            if focusedElement == nil, Self.isSystemAuthPromptWindowOnScreen() {
                return (true, "Secure Event Input is active for a system password prompt.")
            }
            if focusedPID != 0,
               let bundleID = NSRunningApplication(processIdentifier: focusedPID)?.bundleIdentifier,
               Self.systemAuthPromptBundleIDs.contains(bundleID) {
                return (true, "Secure Event Input is active for \(bundleID).")
            }
        }

        return (false, "Only macOS system password prompts can be filled (not web pages or other apps).")
    }

    /// True if a window owned by a system authorization process (not loginwindow, which always
    /// owns windows) is on screen. Uses owner PIDs only, so no Screen Recording permission is needed.
    private static func isSystemAuthPromptWindowOnScreen() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let promptBundles = systemAuthPromptBundleIDs.subtracting(["com.apple.loginwindow"])
        var checked = Set<pid_t>()
        for info in windows {
            guard let pidNumber = info[kCGWindowOwnerPID as String] as? NSNumber else { continue }
            let pid = pid_t(pidNumber.int32Value)
            guard checked.insert(pid).inserted else { continue }
            if let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
               promptBundles.contains(bundleID) {
                return true
            }
        }
        return false
    }

    /// Remembers which pasteboard generation holds the transient password copy so it can be
    /// wiped early if a protected prompt opens before the 4-second timer fires.
    public func noteTransientClipboardCopy(changeCount: Int) {
        transientClipboardChangeCount = changeCount
    }

    public func clearTransientClipboardRecord(ifChangeCount changeCount: Int) {
        if transientClipboardChangeCount == changeCount {
            transientClipboardChangeCount = nil
        }
    }

    /// Clears the pasteboard immediately if it still holds AuraSense's transient password copy
    /// (called when a protected prompt opens and from `applicationWillTerminate`).
    public func wipeTransientClipboardNow() {
        guard let recorded = transientClipboardChangeCount else { return }
        if NSPasteboard.general.changeCount == recorded {
            NSPasteboard.general.clearContents()
        }
        transientClipboardChangeCount = nil
    }

    /// Stamps a synthesized event so it is identifiable as coming from AuraSense.
    public nonisolated static func markSynthetic(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
    }

    /// True if the event was synthesized by AuraSense (marker or originating PID matches).
    public nonisolated static func isAuraSenseSynthetic(_ event: NSEvent) -> Bool {
        guard let cg = event.cgEvent else { return false }
        if cg.getIntegerValueField(.eventSourceUserData) == syntheticEventMarker {
            return true
        }
        let sourcePID = cg.getIntegerValueField(.eventSourceUnixProcessID)
        return sourcePID != 0 && sourcePID == Int64(ProcessInfo.processInfo.processIdentifier)
    }
}
