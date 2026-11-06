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
    /// True while `typeCredential` is synthesizing keystrokes (mutual exclusion for all typing paths).
    private var isInjectingCredential = false
    /// Re-entrancy guard for `installToApplicationsFolder`.
    private var isInstalling = false

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

        let presentPrompt: @MainActor () -> Void = { [weak self] in
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

        // Reset at most once per build (a new CDHash can leave a stale TCC row behind). Resetting on
        // every prompt would delete the toggle the user is in the middle of granting.
        if resetStaleEntryIfNeeded && lastResetBuild != currentBuild,
           let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.set(currentBuild, forKey: "aurasense.lastTccResetBuild")
            DispatchQueue.global(qos: .userInitiated).async {
                Self.resetStaleAccessibilityTCCEntry(bundleID: bundleID)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { presentPrompt() }
                }
            }
        } else {
            presentPrompt()
        }
    }

    /// Runs `tccutil reset Accessibility <bundleID>` for this app only. Must be called off the main thread.
    private nonisolated static func resetStaleAccessibilityTCCEntry(bundleID: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        proc.arguments = ["reset", "Accessibility", bundleID]
        try? proc.run()
        proc.waitUntilExit()
    }

    public func openAccessibilitySettings() {
        promptForAccessibilityPermission(resetStaleEntryIfNeeded: false, openSettingsPane: true)
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

    /// Installs or updates `/Applications/AuraSense.app`. Only call this from an explicit user action
    /// (the installer bundle's Install button); it may ask for administrator rights.
    ///
    /// All Process work runs off the main actor. The install is skipped when the destination already has
    /// the same `CFBundleVersion` and a byte-identical executable (re-signing would change the CDHash and
    /// invalidate the Accessibility grant and Keychain ACL). The bundle is staged in a temporary folder,
    /// fixed up (bundle identifier, re-sign only when the Info.plist actually changed), then swapped in
    /// whole — never ditto-merged over an existing bundle.
    public func installToApplicationsFolder() async -> (Bool, String) {
        guard !isInstalling else {
            return (false, "An installation is already in progress.")
        }
        isInstalling = true
        defer { isInstalling = false }

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

        if (sourceAppPath as NSString).standardizingPath == (destPath as NSString).standardizingPath {
            return (true, "AuraSense is already installed in /Applications.")
        }

        lastActionSummary = "Installing AuraSense.app into /Applications…"
        let result = await Task.detached(priority: .userInitiated) {
            Self.performInstall(sourceAppPath: sourceAppPath, destPath: destPath)
        }.value

        lastActionSummary = result.0 ? "Installed AuraSense.app into /Applications" : "Install to /Applications failed"
        return result
    }

    @discardableResult
    private nonisolated static func runProcess(_ executable: String, _ arguments: [String]) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus
        } catch {
            return -1
        }
    }

    private nonisolated static func bundleInfo(atAppPath path: String) -> [String: Any]? {
        NSDictionary(contentsOfFile: (path as NSString).appendingPathComponent("Contents/Info.plist")) as? [String: Any]
    }

    private nonisolated static func executablePath(appPath: String, info: [String: Any]?) -> String {
        let name = info?["CFBundleExecutable"] as? String ?? "AuraSense"
        return (appPath as NSString).appendingPathComponent("Contents/MacOS/\(name)")
    }

    /// Rewrites installer-only identity values to the main app's. Returns true only if the plist changed.
    private nonisolated static func normalizeInstalledInfoPlist(atAppPath appPath: String) -> Bool {
        let plistPath = (appPath as NSString).appendingPathComponent("Contents/Info.plist")
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let data = FileManager.default.contents(atPath: plistPath),
              var plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: &format)) as? [String: Any] else {
            return false
        }
        var changed = false
        for (key, value) in plist {
            guard let str = value as? String else { continue }
            if str == "Install AuraSense" {
                plist[key] = "AuraSense"
                changed = true
            } else if str == "com.aurasense.mac.installer" {
                plist[key] = "com.aurasense.mac.app"
                changed = true
            }
        }
        guard changed,
              let out = try? PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0) else {
            return false
        }
        return FileManager.default.createFile(atPath: plistPath, contents: out)
    }

    private nonisolated static func performInstall(sourceAppPath: String, destPath: String) -> (Bool, String) {
        let fm = FileManager.default
        let destExecutable = "\(destPath)/Contents/MacOS/AuraSense"

        // Skip when the installed copy is already this exact build.
        let srcInfo = bundleInfo(atAppPath: sourceAppPath)
        if fm.fileExists(atPath: destExecutable),
           let destInfo = bundleInfo(atAppPath: destPath),
           let srcVersion = srcInfo?["CFBundleVersion"] as? String,
           srcVersion == destInfo["CFBundleVersion"] as? String,
           fm.contentsEqual(atPath: executablePath(appPath: sourceAppPath, info: srcInfo),
                            andPath: executablePath(appPath: destPath, info: destInfo)) {
            return (true, "AuraSense.app in /Applications is already up to date (build \(srcVersion)).")
        }

        // Stage a complete, fixed-up copy in a private temporary folder.
        let stagingDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("AuraSenseInstall-\(UUID().uuidString)")
        let stagedApp = (stagingDir as NSString).appendingPathComponent("AuraSense.app")
        defer { try? fm.removeItem(atPath: stagingDir) }
        do {
            try fm.createDirectory(atPath: stagingDir, withIntermediateDirectories: true)
        } catch {
            return (false, "Could not prepare a staging folder: \(error.localizedDescription)")
        }
        guard runProcess("/usr/bin/ditto", [sourceAppPath, stagedApp]) == 0,
              fm.fileExists(atPath: "\(stagedApp)/Contents/MacOS/AuraSense") else {
            return (false, "Could not copy AuraSense.app. Drag AuraSense.app into /Applications in Finder.")
        }
        runProcess("/usr/bin/xattr", ["-cr", stagedApp])
        if normalizeInstalledInfoPlist(atAppPath: stagedApp) {
            // Info.plist is sealed by the signature; re-sign only because it actually changed.
            runProcess("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", stagedApp])
        }
        let stagedExecutable = "\(stagedApp)/Contents/MacOS/AuraSense"
        let installedMatchesStaged: () -> Bool = {
            fm.fileExists(atPath: destExecutable) && fm.contentsEqual(atPath: stagedExecutable, andPath: destExecutable)
        }

        // Step 1: swap in without admin rights (copy next to the destination, then replace it whole).
        let tempDest = "/Applications/.AuraSense-install-\(UUID().uuidString).app"
        if runProcess("/usr/bin/ditto", [stagedApp, tempDest]) == 0 {
            var swapped = false
            if fm.fileExists(atPath: destPath) {
                swapped = (try? fm.replaceItemAt(URL(fileURLWithPath: destPath), withItemAt: URL(fileURLWithPath: tempDest))) != nil
            } else {
                swapped = (try? fm.moveItem(atPath: tempDest, toPath: destPath)) != nil
            }
            try? fm.removeItem(atPath: tempDest)
            if swapped && installedMatchesStaged() {
                runProcess("/usr/bin/xattr", ["-cr", destPath])
                return (true, "Installed AuraSense.app in /Applications.")
            }
        } else {
            try? fm.removeItem(atPath: tempDest)
        }

        // Step 2: /Applications needs admin rights. The staged path is passed as an argument
        // (`on run argv` + `quoted form of`), never spliced into the AppleScript source.
        let script = [
            "on run argv",
            "set src to item 1 of argv",
            "do shell script \"/bin/rm -rf /Applications/AuraSense.app && /usr/bin/ditto \" & quoted form of src & \" /Applications/AuraSense.app && /usr/bin/xattr -cr /Applications/AuraSense.app\" with administrator privileges",
            "end run"
        ]
        var osaArgs: [String] = []
        for line in script {
            osaArgs.append("-e")
            osaArgs.append(line)
        }
        osaArgs.append(stagedApp)
        runProcess("/usr/bin/osascript", osaArgs)

        if installedMatchesStaged() {
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
        // Online (not merely active) displays: includes sleeping and mirrored displays, so an external
        // monitor is still detected while the Mac is locked with its displays asleep.
        var displayCount: UInt32 = 0
        var onlineDisplays = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetOnlineDisplayList(16, &onlineDisplays, &displayCount) == .success else {
            return
        }

        let ids = Array(onlineDisplays.prefix(Int(displayCount)))
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
        // Only move the pointer when nobody is using the Mac (locked screen or sleeping display).
        let mayNudgePointer = refreshScreenLockState() || isDisplayAsleep

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

        if hasExternalMonitorConnected && sendMonitorInputSignal && mayNudgePointer {
            let bounds = externalDisplayBounds ?? CGRect(x: 400, y: 300, width: 1920, height: 1080)
            let targetPoint = CGPoint(x: bounds.midX, y: bounds.midY)
            let nudgePoint = CGPoint(x: bounds.midX + 1.0, y: bounds.midY)
            let originalPoint = CGEvent(source: nil)?.location
            let source = CGEventSource(stateID: .hidSystemState)
            if let move1 = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: nudgePoint, mouseButton: .left),
               let move2 = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: targetPoint, mouseButton: .left) {
                move1.post(tap: .cghidEventTap)
                move2.post(tap: .cghidEventTap)
            }
            // Put the pointer back where the user left it.
            if let originalPoint,
               let restore = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: originalPoint, mouseButton: .left) {
                restore.post(tap: .cghidEventTap)
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
            // CGSSessionScreenIsLocked is only present while locked; a missing key means unlocked.
            let screenLockedKey = (sessionDict["CGSSessionScreenIsLocked"] as? Bool) ?? false
            let offConsole = (sessionDict["kCGSSessionOnConsoleKey"] as? Bool) == false
            let locked = screenLockedKey || offConsole
            if isScreenLocked != locked {
                isScreenLocked = locked
            }
            return locked
        }
        // Only fall back to the cached value when the session dictionary is unavailable.
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

        let frameworkPath = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        if let handle = dlopen(frameworkPath, RTLD_NOW),
           let sym = dlsym(handle, "SACLockScreenImmediate") {
            typealias LockFunction = @convention(c) () -> Void
            let sacLock = unsafeBitCast(sym, to: LockFunction.self)
            sacLock()
            dlclose(handle)
            lastActionSummary = "Locked via SACLockScreenImmediate"
            confirmLockThenPlayChime(playChime: playChime)

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
            lastActionSummary = "Locked via Ctrl+Cmd+Q CGEvent"
            confirmLockThenPlayChime(playChime: playChime)

            if sleepDisplay || hasExternalMonitorConnected {
                putDisplayToSleepAfterDelay(seconds: 1.0)
            }
            return .lockedViaKeyboardShortcut
        }

        return .failed("Unable to invoke SACLockScreenImmediate or post CGEvent.")
    }

    /// Polls the real session state after a lock request; `isScreenLocked` is only set once macOS
    /// confirms it, and the lock sound plays only for a confirmed lock.
    private func confirmLockThenPlayChime(playChime: Bool) {
        Task { @MainActor [weak self] in
            for _ in 0..<14 {
                guard let self else { return }
                if self.refreshScreenLockState() {
                    if playChime {
                        UnlockSoundLibrary.shared.playLockSound()
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            self?.lastActionSummary = "Lock requested, but macOS did not confirm the screen locked"
        }
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
        /// Nothing was submitted (protected prompt open, focus not allowed, another fill running,
        /// modifier keys held). Not evidence that the stored password is wrong.
        case skipped(String)
        /// The password was submitted but macOS did not confirm the unlock.
        case failed(String)
    }

    /// Reads the Keychain password off the main actor. Automated paths pass `allowUserInteraction: false`
    /// so a Keychain ACL prompt (invisible on the lock screen) can never hang the app.
    private func readStoredPassword(allowUserInteraction: Bool) async -> String? {
        await Task.detached(priority: .userInitiated) {
            KeychainManager.shared.retrievePassword(allowUserInteraction: allowUserInteraction)
        }.value
    }

    public func unlockMac(forceTestInForeground: Bool = false, playChime: Bool = true) async -> UnlockResult {
        guard CredentialInjectionGuard.shared.mayInjectCredentials() else {
            lastActionSummary = "Unlock paused while a protected password prompt is open"
            return .skipped("A protected AuraSense password prompt is open.")
        }
        guard refreshAccessibilityStatus(prompt: false) else {
            lastActionSummary = "Unlock blocked: Accessibility permission missing"
            return .missingAccessibilityPermission
        }
        guard KeychainManager.shared.hasStoredPassword() else {
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

        // Not on the lock screen: keystrokes would go to the focused app, so the same focused-field
        // rules as Instant-Fill apply (secure field, not AuraSense itself).
        if !currentlyLocked {
            let decision = CredentialInjectionGuard.shared.focusedFieldInjectionDecision(requireSecureField: true)
            guard decision.allowed else {
                lastActionSummary = "Unlock test blocked: \(decision.reason)"
                return .skipped(decision.reason)
            }
        }

        guard let password = await readStoredPassword(allowUserInteraction: false), !password.isEmpty else {
            lastActionSummary = "Unlock blocked: Keychain password unavailable without a prompt"
            return .missingKeychainPassword
        }

        wakeDisplayAndSendMonitorInput()

        let settleMs = hasExternalMonitorConnected ? max(externalMonitorSettleMs, 420.0) : 400.0
        try? await Task.sleep(nanoseconds: UInt64(settleMs * 1_000_000))

        // The user may have unlocked by hand during the settle delay; never type onto a live desktop.
        if currentlyLocked && !refreshScreenLockState() {
            return .alreadyUnlocked
        }

        postKeyTap(virtualKey: CGKeyCode(kVK_Shift))
        try? await Task.sleep(nanoseconds: 180_000_000)

        if currentlyLocked && !refreshScreenLockState() {
            return .alreadyUnlocked
        }
        if !currentlyLocked {
            let decision = CredentialInjectionGuard.shared.focusedFieldInjectionDecision(requireSecureField: true)
            guard decision.allowed else {
                lastActionSummary = "Unlock test blocked: \(decision.reason)"
                return .skipped(decision.reason)
            }
        }

        guard await typeCredential(password, submitWithReturn: true) else {
            return .skipped("Password entry was aborted (protected prompt, modifier keys held, or another fill in progress).")
        }

        // Sound + animation play once macOS confirms the unlock (not merely on submit).
        UnlockCelebrationCoordinator.shared.expectAuraUnlock(
            deviceName: BLEProximityEngine.shared.trackedDevice?.name ?? BLEProximityEngine.shared.selectedDeviceName
        )

        lastActionSummary = hasExternalMonitorConnected
            ? "Sent External Monitor Display Input + Accessibility Unlock"
            : "Sent Accessibility Unlock sequence"

        guard currentlyLocked else {
            // Foreground test into a secure field: there is no lock state to confirm.
            return .unlockedSuccessfully
        }

        // Report success only once macOS confirms the session is unlocked (~2.5 s, polled every 150 ms).
        for _ in 0..<17 {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if !refreshScreenLockState() {
                lastActionSummary = "Unlocked via proximity (confirmed by macOS)"
                return .unlockedSuccessfully
            }
        }
        lastActionSummary = "Unlock attempt failed: screen still locked"
        // macOS can confirm a correct unlock a little late, so keep crediting AuraSense briefly,
        // but don't let a much later manual unlock be celebrated as "Unlocked by <device>".
        UnlockCelebrationCoordinator.shared.limitExpectedAuraUnlock(toSeconds: 4)
        return .failed("Screen still locked – stored password may be wrong")
    }

    // MARK: - Global Instant Fill Hotkeys

    public func registerGlobalInstantFillShortcuts() {
        if globalKeyMonitor == nil {
            globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                Task { @MainActor in
                    _ = self?.handleShortcutEvent(event)
                }
            }
        }
        if localKeyMonitor == nil {
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // Local monitors run on the main thread; consume the chord so no other handler
                // (e.g. a menu key equivalent) fires a second fill.
                let consumed = MainActor.assumeIsolated {
                    self?.handleShortcutEvent(event) ?? false
                }
                return consumed ? nil : event
            }
        }
    }

    /// Handles ⌃⌥⌘Space. Returns true when the event is one of AuraSense's chords
    /// (including key repeats, which are swallowed without re-triggering).
    @discardableResult
    private func handleShortcutEvent(_ event: NSEvent) -> Bool {
        guard enableGlobalInstantFillHotkey else { return false }
        guard !CredentialInjectionGuard.isAuraSenseSynthetic(event) else { return false }
        let requiredFlags: NSEvent.ModifierFlags = [.control, .option, .command]
        let activeFlags = event.modifierFlags.intersection([.control, .option, .command, .shift])
        guard activeFlags == requiredFlags else { return false }
        guard event.keyCode == 49 else { return false }
        guard !event.isARepeat else { return true }

        Task { @MainActor in
            _ = await self.instantFillActivePasswordField()
        }
        return true
    }

    /// For buttons/menu items inside AuraSense: hides AuraSense so focus returns to the previously
    /// active app's password field, then performs Instant-Fill there.
    public func instantFillAfterReturningFocus() async {
        NSApp.hide(nil)
        try? await Task.sleep(nanoseconds: 400_000_000)
        _ = await instantFillActivePasswordField()
    }

    @discardableResult
    public func instantFillActivePasswordField() async -> Bool {
        let decision = CredentialInjectionGuard.shared.focusedFieldInjectionDecision(requireSecureField: true)
        guard decision.allowed else {
            lastActionSummary = "Instant-Fill blocked: \(decision.reason)"
            return false
        }
        guard refreshAccessibilityStatus(prompt: false) else {
            lastActionSummary = "Instant-Fill blocked: Grant Accessibility permission"
            return false
        }
        guard let password = await readStoredPassword(allowUserInteraction: true), !password.isEmpty else {
            lastActionSummary = "Instant-Fill blocked: Save password in Keychain Vault first"
            return false
        }

        try? await Task.sleep(nanoseconds: 120_000_000)

        // Focus may have moved (e.g. a Keychain prompt appeared); re-check right before typing.
        let recheck = CredentialInjectionGuard.shared.focusedFieldInjectionDecision(requireSecureField: true)
        guard recheck.allowed else {
            lastActionSummary = "Instant-Fill blocked: \(recheck.reason)"
            return false
        }
        guard await typeCredential(password, submitWithReturn: true) else {
            lastActionSummary = "Instant-Fill aborted (protected prompt, modifier keys held, or another fill in progress)."
            return false
        }

        if BLEProximityEngine.shared.playSoundEffects {
            UnlockSoundLibrary.shared.play(id: "system:Pop")
        }

        lastActionSummary = "Instant-filled password via ⌃⌥⌘Space"
        BLEProximityEngine.shared.appendLog(
            kind: .unlocked,
            title: "Instant Password Fill Executed (⌃⌥⌘Space)",
            detail: "Typed Keychain password into active password prompt on demand."
        )
        return true
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

    /// The ONLY code allowed to synthesize password keystrokes (proximity unlock, Instant-Fill, the
    /// iPhone bridge, Continuity wake). Callers are responsible for the focus decision
    /// (`focusedFieldInjectionDecision`) except on the verified lock screen.
    ///
    /// Returns false, typing nothing further, if another fill is already in progress, physical modifier
    /// keys are still held after ~1 s, or a protected prompt opens before or during entry.
    @discardableResult
    public func typeCredential(_ password: String, submitWithReturn: Bool) async -> Bool {
        guard !isInjectingCredential else { return false }
        isInjectingCredential = true
        defer { isInjectingCredential = false }

        guard CredentialInjectionGuard.shared.mayInjectCredentials() else { return false }

        // Wait for the user to release the hotkey's modifiers so characters are not delivered as chords.
        let heldModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        var waitedMs = 0
        while !CGEventSource.flagsState(.hidSystemState).intersection(heldModifiers).isEmpty {
            guard waitedMs < 1_000 else {
                lastActionSummary = "Password entry aborted: release the modifier keys and try again"
                return false
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
            waitedMs += 50
        }

        let eventSource = CGEventSource(stateID: .hidSystemState)
        for scalar in password.utf16 {
            guard CredentialInjectionGuard.shared.mayInjectCredentials() else { return false }
            var utf16Char = scalar
            if let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true),
               let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false) {
                keyDown.keyboardSetUnicodeString(stringLength: 1, unicodeString: &utf16Char)
                keyUp.keyboardSetUnicodeString(stringLength: 1, unicodeString: &utf16Char)
                keyDown.flags = []
                keyUp.flags = []
                CredentialInjectionGuard.markSynthetic(keyDown)
                CredentialInjectionGuard.markSynthetic(keyUp)
                keyDown.post(tap: .cghidEventTap)
                keyUp.post(tap: .cghidEventTap)
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }

        if submitWithReturn {
            try? await Task.sleep(nanoseconds: 55_000_000)
            guard CredentialInjectionGuard.shared.mayInjectCredentials() else { return false }
            postKeyTap(virtualKey: CGKeyCode(kVK_Return))
        }
        return true
    }

    private func postKeyTap(virtualKey: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
           let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) {
            down.flags = flags
            up.flags = flags
            CredentialInjectionGuard.markSynthetic(down)
            CredentialInjectionGuard.markSynthetic(up)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }
}
