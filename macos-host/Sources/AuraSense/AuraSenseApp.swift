import SwiftUI
import AppKit
import Combine
import ServiceManagement

/// How this process was launched. The DMG's "Install AuraSense.app" bundle
/// (`com.aurasense.mac.installer`) only copies AuraSense.app into /Applications and hands off to it;
/// it must never bind devices, request permissions, store the Keychain password or run protection.
public enum AuraLaunchMode {
    public static let installerBundleIdentifier = "com.aurasense.mac.installer"

    public static let isInstallerBundle: Bool = {
        Bundle.main.bundleIdentifier == installerBundleIdentifier ||
        CommandLine.arguments.contains("--installer") ||
        Bundle.main.bundlePath.lowercased().contains("install aurasense")
    }()

    /// `/Applications/AuraSense.app --setup` (launched by the installer) opens the Guided Setup.
    public static let requestedGuidedSetup: Bool = CommandLine.arguments.contains("--setup")
}

/// Manages macOS Dock icon visibility (`NSApplication.ActivationPolicy`).
/// When the main Dashboard or Guided Setup window is open, AuraSense uses `.regular` policy;
/// when all standard windows are closed, it switches to `.accessory` so the Dock icon disappears
/// and AuraSense lives quietly in the macOS Menu Bar with its Eclipse + Proximity Orbit icon.
@MainActor
public final class DockVisibilityManager: ObservableObject {
    public static let shared = DockVisibilityManager()

    @AppStorage("aurasense.hideDockWhenWindowClosed") public var hideDockWhenWindowClosed: Bool = true {
        didSet {
            evaluateDockPolicy(closingWindow: nil)
        }
    }

    private init() {}

    public func showAppInForeground() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        for window in NSApplication.shared.windows
        where isStandardAppWindow(window) && (window.isVisible || window.isMiniaturized) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }
    }

    public func hideFromDockImmediately() {
        for window in NSApplication.shared.windows where isStandardAppWindow(window) {
            window.close()
        }
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    public func evaluateDockPolicy(closingWindow: NSWindow? = nil) {
        guard hideDockWhenWindowClosed else {
            NSApplication.shared.setActivationPolicy(.regular)
            return
        }

        let remainingVisibleWindows = NSApplication.shared.windows.filter { win in
            if let closing = closingWindow, win == closing {
                return false
            }
            return win.isVisible && isStandardAppWindow(win)
        }

        if remainingVisibleWindows.isEmpty {
            NSApplication.shared.setActivationPolicy(.accessory)
        } else {
            NSApplication.shared.setActivationPolicy(.regular)
        }
    }

    private func isStandardAppWindow(_ window: NSWindow) -> Bool {
        let className = NSStringFromClass(type(of: window))
        if className.contains("StatusBar") || className.contains("MenuBar") || className.contains("Popover") {
            return false
        }
        if window.level != .normal {
            return false
        }
        return window.styleMask.contains(.titled) || window.styleMask.contains(.closable)
    }
}

/// Lets AppKit code (hand-off notifications, the agent launch path) open SwiftUI windows.
@MainActor
public final class WindowRouter {
    public static let shared = WindowRouter()
    public var openWindowAction: OpenWindowAction?
    /// True when launchd relaunched AuraSense quietly; the auto-opened dashboard is closed on appear.
    public var suppressInitialWindow = false
    /// Set when launched with `--setup`; consumed once by the dashboard to open Guided Setup.
    private var pendingGuidedSetupRequest = AuraLaunchMode.requestedGuidedSetup

    private init() {}

    /// Persisted when a `--setup` launch hands off to another AuraSense instance (launchd agent or
    /// an already-running copy) so that instance opens Guided Setup instead of losing the request.
    public static let pendingGuidedSetupDefaultsKey = "aurasense.pendingGuidedSetup"

    /// Returns true (once) if this launch, or a launch that handed off to us, asked for Guided Setup.
    public func consumeGuidedSetupRequest() -> Bool {
        let persisted = UserDefaults.standard.bool(forKey: Self.pendingGuidedSetupDefaultsKey)
        defer {
            pendingGuidedSetupRequest = false
            UserDefaults.standard.removeObject(forKey: Self.pendingGuidedSetupDefaultsKey)
        }
        return pendingGuidedSetupRequest || persisted
    }

    /// Called from views that have an `openWindow` environment value.
    public func register(_ action: OpenWindowAction) {
        openWindowAction = action
    }

    /// Returns true (once) if the window that just appeared should close immediately.
    public func consumeInitialWindowSuppression() -> Bool {
        defer { suppressInitialWindow = false }
        return suppressInitialWindow
    }

    public func showDashboard() {
        DockVisibilityManager.shared.showAppInForeground()
        let hasDashboard = NSApplication.shared.windows.contains { win in
            (win.isVisible || win.isMiniaturized) && win.level == .normal && win.styleMask.contains(.titled) && win.title == "AuraSense"
        }
        if !hasDashboard {
            openWindowAction?(id: "main-dashboard")
        }
    }
}

public final class AuraSenseAppDelegate: NSObject, NSApplicationDelegate {
    public func applicationWillFinishLaunching(_ notification: Notification) {
        // The installer bundle only copies the app; it never coordinates protection instances.
        if AuraLaunchMode.isInstallerBundle { return }
        MainActor.assumeIsolated {
            if AuraLaunchMode.requestedGuidedSetup {
                // Survives a hand-off below; consumed by whichever instance shows the UI.
                UserDefaults.standard.set(true, forKey: WindowRouter.pendingGuidedSetupDefaultsKey)
            }
            // Resolve duplicate/stale instances before any UI appears.
            if BackgroundPersistenceManager.shared.coordinateLaunch() == .exitHandedOff {
                exit(0)
            }
        }
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        if AuraLaunchMode.isInstallerBundle {
            // Installer: no relay server, shortcuts, LaunchAgent or permission prompts here —
            // all of that belongs to /Applications/AuraSense.app (com.aurasense.mac.app).
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        MainActor.assumeIsolated {
            let persistence = BackgroundPersistenceManager.shared
            persistence.startListening { openGuidedSetup in
                let router = WindowRouter.shared
                // Always consume the persisted flag so a handled request can't reopen Setup later.
                let persistedSetupRequest = router.consumeGuidedSetupRequest()
                if (openGuidedSetup || persistedSetupRequest), let open = router.openWindowAction {
                    // A `--setup` launch handed off to this running instance.
                    DockVisibilityManager.shared.showAppInForeground()
                    open(id: "installer-wizard")
                } else {
                    router.showDashboard()
                }
            }
            if persistence.keepRunningInBackground {
                persistence.installOrRefreshAgent(loadNow: false)
                // The LaunchAgent already starts AuraSense at login; avoid a second login item.
                if persistence.isAgentInstalled, SMAppService.mainApp.status == .enabled {
                    try? SMAppService.mainApp.unregister()
                }
            }
            _ = UnlockCelebrationCoordinator.shared
            _ = UnlockSoundLibrary.shared
        }

        _ = FaceIdKeychainBridgeService.shared
        MacLockUnlockController.shared.registerGlobalInstantFillShortcuts()

        // Ensure the application icon is explicitly loaded from Resources/AppIcon.icns or AppIcon.png
        if let icnsPath = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let appIcon = NSImage(contentsOfFile: icnsPath) {
            NSApplication.shared.applicationIconImage = appIcon
        } else if let pngPath = Bundle.main.path(forResource: "AppIcon", ofType: "png"),
                  let appIcon = NSImage(contentsOfFile: pngPath) {
            NSApplication.shared.applicationIconImage = appIcon
        }

        // Installing into /Applications only happens from the installer bundle or an explicit
        // button in Guided Setup — never automatically at launch.

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )

        let persistence = MainActor.assumeIsolated { BackgroundPersistenceManager.shared }
        let startQuietly = MainActor.assumeIsolated {
            persistence.launchedByAgent && !persistence.consumePendingShowDashboard()
        }
        if startQuietly {
            // Relaunched by launchd (login, force quit, crash): stay in the menu bar only.
            MainActor.assumeIsolated {
                WindowRouter.shared.suppressInitialWindow = true
                NSApplication.shared.setActivationPolicy(.accessory)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                Task { @MainActor in
                    // If the dashboard never appeared there is nothing to suppress later.
                    WindowRouter.shared.suppressInitialWindow = false
                }
            }
        } else {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            Task { @MainActor in
                if !MacLockUnlockController.shared.refreshAccessibilityStatus(prompt: false) {
                    MacLockUnlockController.shared.promptForAccessibilityPermission(
                        resetStaleEntryIfNeeded: false,
                        openSettingsPane: false
                    )
                }
            }
        }
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if AuraLaunchMode.isInstallerBundle { return .terminateNow }
        return MainActor.assumeIsolated {
            BackgroundPersistenceManager.shared.shouldTerminate()
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Never leave AuraSense's transient password copy on the pasteboard after exit.
            CredentialInjectionGuard.shared.wipeTransientClipboardNow()
        }
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if AuraLaunchMode.isInstallerBundle { return true }
        Task { @MainActor in
            // Reuse the existing dashboard instead of resurrecting closed Settings/Setup windows.
            WindowRouter.shared.showDashboard()
        }
        return false
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let className = NSStringFromClass(type(of: window))
        if !className.contains("StatusBar") && !className.contains("MenuBar") && window.level == .normal {
            Task { @MainActor in
                NSApplication.shared.setActivationPolicy(.regular)
            }
        }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        let closingWin = notification.object as? NSWindow
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            DockVisibilityManager.shared.evaluateDockPolicy(closingWindow: closingWin)
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

/// Re-publishes engine changes to the App scene (menu bar icon) without creating the BLE engine
/// in the installer bundle, where Bluetooth/Accessibility must never be requested.
@MainActor
public final class AuraSceneObserver: ObservableObject {
    public static let shared = AuraSceneObserver()
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        guard !AuraLaunchMode.isInstallerBundle else { return }
        BLEProximityEngine.shared.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }
}

/// "Aura Protection" menu items. The ⌃⌥⌘Space hotkey are handled only by the
/// global/local event monitor (registerGlobalInstantFillShortcuts), so these items carry no
/// `.keyboardShortcut` — otherwise one key press would fire two fills.
struct AuraProtectionCommandItems: View {
    @ObservedObject private var engine = BLEProximityEngine.shared
    @ObservedObject private var lockController = MacLockUnlockController.shared
    @ObservedObject private var dockManager = DockVisibilityManager.shared

    var body: some View {
        Toggle("Enable Proximity Monitoring", isOn: $engine.monitoringEnabled)
            .keyboardShortcut("m", modifiers: [.command, .shift])

        Button("Start 10s Desk Signal Calibration") {
            engine.startTenSecondDeskCalibration()
        }
        .keyboardShortcut("k", modifiers: [.command, .shift])

        Button("Prompt Accessibility Permission Again") {
            lockController.promptForAccessibilityPermission(resetStaleEntryIfNeeded: false, openSettingsPane: true)
        }

        Divider()

        Button("Instant-Fill Active Password Prompt (⌃⌥⌘Space)") {
            Task { @MainActor in
                await lockController.instantFillAfterReturningFocus()
            }
        }

        Divider()

        Button("Lock Mac Immediately") {
            engine.triggerManualLock()
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])

        Button("Hide Window & Live in Menu Bar Only") {
            dockManager.hideFromDockImmediately()
        }
        .keyboardShortcut("w", modifiers: [.command])

        Divider()

        Button("Stop AuraSense Completely…") {
            BackgroundPersistenceManager.shared.requestStopCompletely()
        }
    }
}

@main
public struct AuraSenseApp: App {
    @NSApplicationDelegateAdaptor(AuraSenseAppDelegate.self) private var appDelegate
    @ObservedObject private var sceneObserver = AuraSceneObserver.shared

    private var launchedAsInstaller: Bool {
        AuraLaunchMode.isInstallerBundle
    }

    public init() {}

    public var body: some Scene {
        WindowGroup("AuraSense", id: "main-dashboard") {
            if launchedAsInstaller {
                InstallerBundleView()
            } else {
                MainDashboardView()
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Aura Protection") {
                if !launchedAsInstaller {
                    AuraProtectionCommandItems()
                }
            }
        }

        Window("AuraSense Guided Setup", id: "installer-wizard") {
            if launchedAsInstaller {
                InstallerBundleView()
            } else {
                InstallerWindowView()
            }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        // Uses MenuBarExtra with universal macOS Eclipse SF Symbols so the
        // menu bar icon is 100% guaranteed to appear on every macOS display without Assets.car.
        // The installer bundle shows no menu bar item.
        MenuBarExtra(isInserted: .constant(!launchedAsInstaller)) {
            MenuBarPopoverView()
        } label: {
            Image(systemName: menuBarEclipseSymbolName)
                .accessibilityLabel("AuraSense")
        }
        .menuBarExtraStyle(.window)

        Settings {
            if launchedAsInstaller {
                Text("Settings are available in AuraSense after installation.")
                    .padding(24)
            } else {
                SecuritySettingsView()
                    .frame(width: 680, height: 560)
            }
        }
    }

    /// Universal macOS SF Symbol representing the Eclipse + Proximity state in the Menu Bar.
    private var menuBarEclipseSymbolName: String {
        if launchedAsInstaller {
            return "moon.circle.fill"
        }
        let engine = BLEProximityEngine.shared
        if engine.isCalibratingDeskSignal {
            return "dot.radiowaves.left.and.right"
        }
        if !engine.monitoringEnabled || engine.pauseUntilDate != nil {
            return "pause.circle.fill"
        }
        switch engine.proximityState {
        case .unlockedInRange:
            return "moon.circle.fill"
        case .gracePeriodCountdown:
            return "moon.circle"
        case .lockedOutOfRange:
            return "lock.circle.fill"
        case .paused:
            return "pause.circle.fill"
        case .unconfigured:
            return "moon.circle.fill"
        }
    }
}
