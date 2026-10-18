import Foundation
import SwiftUI
import AppKit
import ApplicationServices
import CoreGraphics
import IOKit
import IOKit.pwr_mgt
import Carbon.HIToolbox

/// Handles macOS Accessibility permission verification & re-prompting, `/Applications` installation,
/// screen lock state detection, external monitor DisplayPort/HDMI wake & input signaling,
/// immediate locking, and Keychain password entry.
@MainActor
public final class MacLockUnlockController: ObservableObject {
    public static let shared = MacLockUnlockController()

    @Published public private(set) var isAccessibilityTrusted: Bool = false
    @Published public private(set) var isScreenLocked: Bool = false
    @Published public private(set) var isDisplayAsleep: Bool = false
    @Published public private(set) var hasExternalMonitorConnected: Bool = false
    @Published public private(set) var connectedDisplayCount: Int = 1
    @Published public private(set) var isClamshellMode: Bool = false
    @Published public private(set) var lastActionSummary: String = "Ready"

    @AppStorage("aurasense.sendMonitorInputSignal") public var sendMonitorInputSignal: Bool = true
    @AppStorage("aurasense.externalMonitorSettleMs") public var externalMonitorSettleMs: Double = 650.0
    @AppStorage("aurasense.enableGlobalInstantFillHotkey") public var enableGlobalInstantFillHotkey: Bool = true

    private var permissionPollTimer: Timer?
    private var userActivityAssertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var externalDisplayBounds: CGRect?

    private init() {
        _ = refreshAccessibilityStatus(prompt: false)
        _ = refreshScreenLockState()
        refreshExternalMonitorTopology()
        registerSystemNotifications()
        startPermissionPolling()
    }

    // MARK: - Accessibility & Bluetooth Permission Prompting

    @discardableResult
    public func refreshAccessibilityStatus(prompt: Bool = false) -> Bool {
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: prompt as CFBoolean] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if isAccessibilityTrusted != trusted {
            isAccessibilityTrusted = trusted
        }
        return trusted
    }

    /// Prompts the user for macOS Accessibility permission.
    /// When a new build is installed, macOS TCC can hold a stale CDHash entry from a previous build
    /// that prevents the native permission popup from appearing. Resetting the stale TCC entry via
    /// `tccutil reset Accessibility com.aurasense.mac.app` forces macOS to display a fresh system prompt.
    public func promptForAccessibilityPermission(resetStaleEntryIfNeeded: Bool = true, openSettingsPane: Bool = false) {
        if refreshAccessibilityStatus(prompt: false) {
            if openSettingsPane {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            return
        }

        let currentBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "101"
        let lastResetBuild = UserDefaults.standard.string(forKey: "aurasense.lastTccResetBuild") ?? ""

        if resetStaleEntryIfNeeded || lastResetBuild != currentBuild {
            UserDefaults.standard.set(currentBuild, forKey: "aurasense.lastTccResetBuild")
            resetStaleAccessibilityTCCEntries()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self = self else { return }
            _ = self.refreshAccessibilityStatus(prompt: true)
            if openSettingsPane {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func resetStaleAccessibilityTCCEntries() {
        let bundleIDs = ["com.aurasense.mac.app", "com.aurasense.mac.installer"]
        for id in bundleIDs {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            proc.arguments = ["reset", "Accessibility", id]
            try? proc.run()
            proc.waitUntilExit()
        }
    }

    public func openAccessibilitySettings() {
        promptForAccessibilityPermission(resetStaleEntryIfNeeded: true, openSettingsPane: true)
    }

    public func openBluetoothSettings() {
        BLEProximityEngine.shared.promptForBluetoothPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
            NSWorkspace.shared.open(url)
        }
    }

    public func openTouchIdAndAppleWatchSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Touch-ID-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Reliable Installation to /Applications/AuraSense.app

    public var isInstalledInApplications: Bool {
        FileManager.default.fileExists(atPath: "/Applications/AuraSense.app/Contents/MacOS/AuraSense")
    }

    public var isRunningFromApplications: Bool {
        Bundle.main.bundlePath == "/Applications/AuraSense.app"
    }

    /// Installs or updates `/Applications/AuraSense.app` using `/usr/bin/ditto`, strips quarantine flags,
    /// ensures the bundle identifier is `com.aurasense.mac.app`, and re-signs the bundle.
    @discardableResult
    public func installToApplicationsFolder() -> (Bool, String) {
        let destPath = "/Applications/AuraSense.app"
        let currentBundlePath = Bundle.main.bundlePath

        if currentBundlePath == destPath && isInstalledInApplications {
            return (true, "AuraSense is installed and running from /Applications/AuraSense.app.")
        }

        // Prefer sibling AuraSense.app if user launched "Install AuraSense.app" inside the DMG
        let parentDir = (currentBundlePath as NSString).deletingLastPathComponent
        let siblingAppPath = (parentDir as NSString).appendingPathComponent("AuraSense.app")
        let sourceAppPath: String
        if FileManager.default.fileExists(atPath: (siblingAppPath as NSString).appendingPathComponent("Contents/MacOS/AuraSense")) {
            sourceAppPath = siblingAppPath
        } else if currentBundlePath.hasSuffix(".app") {
            sourceAppPath = currentBundlePath
        } else {
            return (false, "Could not locate source .app bundle to copy.")
        }

        // Step 1: Try direct installation via /usr/bin/ditto
        let dittoProc = Process()
        dittoProc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        dittoProc.arguments = [sourceAppPath, destPath]
        do {
            try dittoProc.run()
            dittoProc.waitUntilExit()
        } catch {
            // Fall through to check status
        }

        // Ensure Info.plist in /Applications/AuraSense.app has the main app bundle identifier (not installer)
        let destPlistPath = "\(destPath)/Contents/Info.plist"
        if let plistText = try? String(contentsOfFile: destPlistPath, encoding: .utf8) {
            let fixedPlist = plistText
                .replacingOccurrences(of: "<string>Install AuraSense</string>", with: "<string>AuraSense</string>")
                .replacingOccurrences(of: "<string>com.aurasense.mac.installer</string>", with: "<string>com.aurasense.mac.app</string>")
            try? fixedPlist.write(toFile: destPlistPath, atomically: true, encoding: .utf8)
        }

        // Strip quarantine and ad-hoc sign /Applications/AuraSense.app
        let xattrProc = Process()
        xattrProc.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattrProc.arguments = ["-cr", destPath]
        try? xattrProc.run()
        xattrProc.waitUntilExit()

        let signProc = Process()
        signProc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signProc.arguments = ["--force", "--deep", "--sign", "-", destPath]
        try? signProc.run()
        signProc.waitUntilExit()

        if isInstalledInApplications {
            lastActionSummary = "Installed AuraSense.app into /Applications"
            return (true, "Installed AuraSense.app in /Applications.")
        }

        // Step 2: Fallback with administrator privileges via osascript if /Applications required admin rights
        let escapedSrc = sourceAppPath.replacingOccurrences(of: "'", with: "'\\''")
        let shellCmd = "/bin/rm -rf '/Applications/AuraSense.app' && /usr/bin/ditto '\(escapedSrc)' '/Applications/AuraSense.app' && /usr/bin/xattr -cr '/Applications/AuraSense.app' && /usr/bin/codesign --force --deep --sign - '/Applications/AuraSense.app'"
        let osaProc = Process()
        osaProc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osaProc.arguments = ["-e", "do shell script \"\(shellCmd)\" with administrator privileges"]
        try? osaProc.run()
        osaProc.waitUntilExit()

        if isInstalledInApplications {
            lastActionSummary = "Installed AuraSense.app into /Applications"
            return (true, "Installed AuraSense.app in /Applications.")
        }

        return (false, "Unable to copy to /Applications automatically. Drag AuraSense.app into /Applications in Finder.")
    }

    private func startPermissionPolling() {
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAccessibilityStatus(prompt: false)
                self?.refreshScreenLockState()
                self?.refreshExternalMonitorTopology()
            }
        }
    }

    // MARK: - External Monitor Topology & Display Input Signal

    public func refreshExternalMonitorTopology() {
        var displayCount: UInt32 = 0
        var activeDisplays = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(16, &activeDisplays, &displayCount) == .success else {
            return
        }

        let ids = Array(activeDisplays.prefix(Int(displayCount)))
        connectedDisplayCount = max(Int(displayCount), 1)

        var foundBuiltin = false
        var firstExternalBounds: CGRect? = nil

        for id in ids {
            if CGDisplayIsBuiltin(id) != 0 {
                foundBuiltin = true
            } else if firstExternalBounds == nil {
                firstExternalBounds = CGDisplayBounds(id)
            }
        }

        let extConnected = (firstExternalBounds != nil) || (displayCount > 1)
        hasExternalMonitorConnected = extConnected
        isClamshellMode = extConnected && !foundBuiltin
        externalDisplayBounds = firstExternalBounds
    }

    public func wakeDisplayAndSendMonitorInput() {
        refreshExternalMonitorTopology()

        let assertionName = "AuraSense Proximity & External Monitor Wake" as CFString
        IOPMAssertionDeclareUserActivity(
            assertionName,
            kIOPMUserActiveLocal,
            &userActivityAssertionID
        )

        let wrangler = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IODisplayWrangler")
        if wrangler != MACH_PORT_NULL {
            IORegistryEntrySetCFProperty(wrangler, "IORequestIdle" as CFString, kCFBooleanFalse)
            IOObjectRelease(wrangler)
        }

        if sendMonitorInputSignal {
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
                proc.arguments = ["-u", "-t", "2"]
                try? proc.run()
            }
        }

        if hasExternalMonitorConnected && sendMonitorInputSignal {
            let bounds = externalDisplayBounds ?? CGRect(x: 400, y: 300, width: 1920, height: 1080)
            let targetPoint = CGPoint(x: bounds.midX, y: bounds.midY)
            let nudgePoint = CGPoint(x: bounds.midX + 1.0, y: bounds.midY)
            let source = CGEventSource(stateID: .hidSystemState)
            if let move1 = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: nudgePoint, mouseButton: .left),
               let move2 = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: targetPoint, mouseButton: .left) {
                move1.post(tap: .cghidEventTap)
                move2.post(tap: .cghidEventTap)
            }
            lastActionSummary = "Woke Mac & sent active Display Input signal to external monitor"
        } else {
            lastActionSummary = "Woke display via IOKit user activity assertion"
        }

        isDisplayAsleep = false
    }

    public func wakeDisplay() {
        wakeDisplayAndSendMonitorInput()
    }

    // MARK: - Lock & Display State Observation

    private func registerSystemNotifications() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isScreenLocked = true
                self?.lastActionSummary = "macOS reported screen locked"
            }
        }

        dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isScreenLocked = false
                self?.lastActionSummary = "macOS reported screen unlocked"
            }
        }

        let wsnc = NSWorkspace.shared.notificationCenter
        wsnc.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isDisplayAsleep = true
            }
        }

        wsnc.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isDisplayAsleep = false
                self?.refreshScreenLockState()
                self?.refreshExternalMonitorTopology()
            }
        }
    }

    @discardableResult
    public func refreshScreenLockState() -> Bool {
        if let sessionDict = CGSessionCopyCurrentDictionary() as? [String: Any] {
            if let locked = sessionDict["CGSSessionScreenIsLocked"] as? Bool {
                isScreenLocked = locked
                return locked
            }
            if let onConsole = sessionDict["kCGSSessionOnConsoleKey"] as? Bool, !onConsole {
                isScreenLocked = true
                return true
            }
        }
        return isScreenLocked
    }

    // MARK: - Lock Execution

    public enum LockResult {
        case lockedViaPrivateFramework
        case lockedViaKeyboardShortcut
        case alreadyLocked
        case failed(String)
    }

    public func lockMac(sleepDisplay: Bool = false, playChime: Bool = true) -> LockResult {
        if refreshScreenLockState() {
            if sleepDisplay {
                putDisplayToSleepAfterDelay(seconds: 0.4)
            }
            return .alreadyLocked
        }

        if playChime {
            NSSound(named: NSSound.Name("Tink"))?.play()
        }

        let frameworkPath = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        if let handle = dlopen(frameworkPath, RTLD_NOW),
           let sym = dlsym(handle, "SACLockScreenImmediate") {
            typealias LockFunction = @convention(c) () -> Void
            let sacLock = unsafeBitCast(sym, to: LockFunction.self)
            sacLock()
            dlclose(handle)
            isScreenLocked = true
            lastActionSummary = "Locked via SACLockScreenImmediate"

            if sleepDisplay || hasExternalMonitorConnected {
                putDisplayToSleepAfterDelay(seconds: 1.0)
            }
            return .lockedViaPrivateFramework
        }

        guard refreshAccessibilityStatus(prompt: false) else {
            lastActionSummary = "Lock fallback requires Accessibility permission"
            return .failed("Accessibility permission required for keyboard shortcut fallback.")
        }

        let source = CGEventSource(stateID: .hidSystemState)
        let qKeyCode = CGKeyCode(kVK_ANSI_Q)
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: qKeyCode, keyDown: true),
           let keyUp = CGEvent(keyboardEventSource: source, virtualKey: qKeyCode, keyDown: false) {
            let flags: CGEventFlags = [.maskControl, .maskCommand]
            keyDown.flags = flags
            keyUp.flags = flags
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            isScreenLocked = true
            lastActionSummary = "Locked via Ctrl+Cmd+Q CGEvent"

            if sleepDisplay || hasExternalMonitorConnected {
                putDisplayToSleepAfterDelay(seconds: 1.0)
            }
            return .lockedViaKeyboardShortcut
        }

        return .failed("Unable to invoke SACLockScreenImmediate or post CGEvent.")
    }

    private func putDisplayToSleepAfterDelay(seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            let registryEntry = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IODisplayWrangler")
            if registryEntry != MACH_PORT_NULL {
                IORegistryEntrySetCFProperty(registryEntry, "IORequestIdle" as CFString, kCFBooleanTrue)
                IOObjectRelease(registryEntry)
            }
        }
    }

    // MARK: - Wake & Unlock Execution

    public enum UnlockResult {
        case unlockedSuccessfully
        case alreadyUnlocked
        case missingAccessibilityPermission
        case missingKeychainPassword
        case failed(String)
    }

    public func unlockMac(forceTestInForeground: Bool = false, playChime: Bool = true) async -> UnlockResult {
        guard refreshAccessibilityStatus(prompt: false) else {
            lastActionSummary = "Unlock blocked: Accessibility permission missing"
            return .missingAccessibilityPermission
        }

        guard let password = KeychainManager.shared.retrievePassword(), !password.isEmpty else {
            lastActionSummary = "Unlock blocked: No password in Keychain"
            return .missingKeychainPassword
        }

        let currentlyLocked = refreshScreenLockState()
        if !currentlyLocked && !forceTestInForeground {
            if isDisplayAsleep || hasExternalMonitorConnected {
                wakeDisplayAndSendMonitorInput()
            }
            return .alreadyUnlocked
        }

        wakeDisplayAndSendMonitorInput()

        let settleMs = hasExternalMonitorConnected ? max(externalMonitorSettleMs, 420.0) : 400.0
        try? await Task.sleep(nanoseconds: UInt64(settleMs * 1_000_000))

        postKeyTap(virtualKey: CGKeyCode(kVK_Shift))
        try? await Task.sleep(nanoseconds: 180_000_000)

        await typePasswordString(password, submitWithReturn: true)

        if playChime {
            NSSound(named: NSSound.Name("Glass"))?.play()
        }

        lastActionSummary = hasExternalMonitorConnected
            ? "Sent External Monitor Display Input + Accessibility Unlock"
            : "Sent Accessibility Unlock sequence"
        try? await Task.sleep(nanoseconds: 450_000_000)
        _ = refreshScreenLockState()
        return .unlockedSuccessfully
    }

    // MARK: - Global Instant Fill Hotkeys

    public func registerGlobalInstantFillShortcuts() {
        if globalKeyMonitor == nil {
            globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                Task { @MainActor in
                    self?.handleShortcutEvent(event)
                }
            }
        }
        if localKeyMonitor == nil {
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                Task { @MainActor in
                    self?.handleShortcutEvent(event)
                }
                return event
            }
        }
    }

    private func handleShortcutEvent(_ event: NSEvent) {
        guard enableGlobalInstantFillHotkey else { return }
        let requiredFlags: NSEvent.ModifierFlags = [.control, .option, .command]
        let activeFlags = event.modifierFlags.intersection([.control, .option, .command, .shift])
        guard activeFlags == requiredFlags else { return }

        if event.keyCode == 49 {
            Task { @MainActor in
                _ = await self.instantFillActivePasswordField()
            }
        } else if event.keyCode == 9 {
            self.copyPasswordTemporarilyForPaste()
        }
    }

    @discardableResult
    public func instantFillActivePasswordField() async -> Bool {
        guard refreshAccessibilityStatus(prompt: false) else {
            lastActionSummary = "Instant-Fill blocked: Grant Accessibility permission"
            return false
        }
        guard let password = KeychainManager.shared.retrievePassword(), !password.isEmpty else {
            lastActionSummary = "Instant-Fill blocked: Save password in Keychain Vault first"
            return false
        }

        try? await Task.sleep(nanoseconds: 120_000_000)
        await typePasswordString(password, submitWithReturn: true)

        if BLEProximityEngine.shared.playSoundEffects {
            NSSound(named: NSSound.Name("Pop"))?.play()
        }

        lastActionSummary = "Instant-filled password via ⌃⌥⌘Space"
        BLEProximityEngine.shared.appendLog(
            kind: .unlocked,
            title: "Instant Password Fill Executed (⌃⌥⌘Space)",
            detail: "Typed Keychain password into active password prompt on demand."
        )
        return true
    }

    public func copyPasswordTemporarilyForPaste() {
        guard let password = KeychainManager.shared.retrievePassword(), !password.isEmpty else {
            lastActionSummary = "No password saved in Keychain Vault"
            return
        }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(password, forType: .string)
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let changeCountSnapshot = pb.changeCount

        if BLEProximityEngine.shared.playSoundEffects {
            NSSound(named: NSSound.Name("Tink"))?.play()
        }

        lastActionSummary = "Password copied for 4s (Press ⌘V now — auto-wiping in 4s)"
        BLEProximityEngine.shared.appendLog(
            kind: .diagnostics,
            title: "Transient 4s Clipboard Assist Activated",
            detail: "Password placed on concealed clipboard for ⌘V paste; will auto-wipe in 4 seconds."
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            if NSPasteboard.general.changeCount == changeCountSnapshot {
                NSPasteboard.general.clearContents()
            }
            Task { @MainActor in
                self.lastActionSummary = "Clipboard automatically wiped for security"
            }
        }
    }

    public func optimizeLoginKeychainStayUnlocked() -> (Bool, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["set-keychain-settings"]
        let errPipe = Pipe()
        proc.standardError = errPipe

        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                lastActionSummary = "Optimized login.keychain-db to stay unlocked while Mac is unlocked"
                BLEProximityEngine.shared.appendLog(
                    kind: .systemState,
                    title: "Optimized macOS Login Keychain Settings",
                    detail: "Disabled repetitive inactivity/sleep re-locking on login.keychain-db while Mac is unlocked."
                )
                return (true, "Configured macOS login Keychain to stay unlocked while your Mac is unlocked.")
            } else {
                let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                let msg = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Non-zero status"
                return (false, "Keychain command note: \(msg)")
            }
        } catch {
            return (false, error.localizedDescription)
        }
    }

    private func typePasswordString(_ password: String, submitWithReturn: Bool) async {
        let eventSource = CGEventSource(stateID: .hidSystemState)
        for scalar in password.utf16 {
            var utf16Char = scalar
            if let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true),
               let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false) {
                keyDown.keyboardSetUnicodeString(stringLength: 1, unicodeString: &utf16Char)
                keyUp.keyboardSetUnicodeString(stringLength: 1, unicodeString: &utf16Char)
                keyDown.post(tap: .cghidEventTap)
                keyUp.post(tap: .cghidEventTap)
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }

        if submitWithReturn {
            try? await Task.sleep(nanoseconds: 55_000_000)
            postKeyTap(virtualKey: CGKeyCode(kVK_Return))
        }
    }

    private func postKeyTap(virtualKey: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
           let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) {
            down.flags = flags
            up.flags = flags
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }
}
