import SwiftUI
import AppKit

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
        for window in NSApplication.shared.windows where isStandardAppWindow(window) {
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

public final class AuraSenseAppDelegate: NSObject, NSApplicationDelegate {
    public func applicationDidFinishLaunching(_ notification: Notification) {
        _ = FaceIdKeychainBridgeService.shared
        MacLockUnlockController.shared.registerGlobalInstantFillShortcuts()

        // Automatically copy AuraSense.app to /Applications if launched from DMG or build directory
        if !MacLockUnlockController.shared.isRunningFromApplications {
            DispatchQueue.global(qos: .userInitiated).async {
                Task { @MainActor in
                    _ = MacLockUnlockController.shared.installToApplicationsFolder()
                }
            }
        }

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

        // Always bring the window to the front on launch and prompt for Accessibility if needed
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            Task { @MainActor in
                if !MacLockUnlockController.shared.refreshAccessibilityStatus(prompt: false) {
                    MacLockUnlockController.shared.promptForAccessibilityPermission(
                        resetStaleEntryIfNeeded: true,
                        openSettingsPane: false
                    )
                }
            }
        }
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            DockVisibilityManager.shared.showAppInForeground()
        }
        return true
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

@main
public struct AuraSenseApp: App {
    @NSApplicationDelegateAdaptor(AuraSenseAppDelegate.self) private var appDelegate
    @ObservedObject private var engine = BLEProximityEngine.shared
    @ObservedObject private var lockController = MacLockUnlockController.shared
    @ObservedObject private var dockManager = DockVisibilityManager.shared

    private var launchedAsInstaller: Bool {
        CommandLine.arguments.contains("--installer") ||
        Bundle.main.bundlePath.lowercased().contains("install aurasense")
    }

    public init() {}

    public var body: some Scene {
        WindowGroup("AuraSense", id: "main-dashboard") {
            if launchedAsInstaller {
                InstallerWindowView()
            } else {
                MainDashboardView()
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Aura Protection") {
                Toggle("Enable Proximity Monitoring", isOn: $engine.monitoringEnabled)
                    .keyboardShortcut("m", modifiers: [.command, .shift])

                Button("Start 10s Desk Signal Calibration") {
                    engine.startTenSecondDeskCalibration()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])

                Button("Prompt Accessibility Permission Again") {
                    lockController.promptForAccessibilityPermission(resetStaleEntryIfNeeded: true, openSettingsPane: true)
                }

                Divider()

                Button("Instant-Fill Active Password Prompt (⌃⌥⌘Space)") {
                    Task { @MainActor in
                        _ = await lockController.instantFillActivePasswordField()
                    }
                }
                .keyboardShortcut(" ", modifiers: [.control, .option, .command])

                Button("Copy Password for 4s Paste (⌃⌥⌘V)") {
                    lockController.copyPasswordTemporarilyForPaste()
                }
                .keyboardShortcut("v", modifiers: [.control, .option, .command])

                Divider()

                Button("Lock Mac Immediately") {
                    engine.triggerManualLock()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Button("Hide Window & Live in Menu Bar Only") {
                    dockManager.hideFromDockImmediately()
                }
                .keyboardShortcut("w", modifiers: [.command])
            }
        }

        Window("AuraSense Guided Setup", id: "installer-wizard") {
            InstallerWindowView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        // Custom Eclipse + Proximity Orbit MenuBarExtra icon
        MenuBarExtra {
            MenuBarPopoverView()
        } label: {
            Image(
                nsImage: AuraTheme.menuBarEclipseIcon(
                    state: engine.proximityState,
                    isCalibrating: engine.isCalibratingDeskSignal,
                    isPaused: !engine.monitoringEnabled || engine.pauseUntilDate != nil
                )
            )
            .accessibilityLabel("AuraSense")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SecuritySettingsView()
                .frame(width: 680, height: 560)
        }
    }
}
