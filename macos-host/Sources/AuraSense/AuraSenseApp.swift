import SwiftUI
import AppKit

/// Manages macOS Dock icon visibility (`NSApplication.ActivationPolicy`).
/// When the main Dashboard or Installer window is open, AuraSense uses `.regular` policy;
/// as soon as the window is closed, it switches to `.accessory` so the Dock icon disappears
/// and AuraSense lives quietly in the macOS Menu Bar with just a clean icon.
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
        // Ensure FaceIdKeychainBridgeService starts listening on port 8765 immediately
        _ = FaceIdKeychainBridgeService.shared
        MacLockUnlockController.shared.registerGlobalInstantFillShortcuts()

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

        if BLEProximityEngine.shared.hasCompletedOnboarding && DockVisibilityManager.shared.hideDockWhenWindowClosed {
            NSApplication.shared.setActivationPolicy(.accessory)
        } else {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
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

                Divider()

                Button("Instant-Fill Active Password Prompt (⌃⌥⌘Space)") {
                    Task { @MainActor in
                        _ = await lockController.instantFillActivePasswordField()
                    }
                }
                .keyboardShortcut(" ", modifiers: [.control, .option, .command])

                Button("Copy Password for 4s Transient Paste (⌃⌥⌘V)") {
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

        Window("AuraSense Installer & Setup", id: "installer-wizard") {
            InstallerWindowView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        // Clean icon-only MenuBarExtra item in the macOS Menu Bar
        MenuBarExtra("AuraSense", systemImage: menuBarSymbolName) {
            MenuBarPopoverView()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SecuritySettingsView()
                .frame(width: 680, height: 560)
        }
    }

    private var menuBarSymbolName: String {
        if engine.isCalibratingDeskSignal {
            return "dot.radiowaves.up.forward"
        }
        if !engine.monitoringEnabled || engine.pauseUntilDate != nil {
            return "pause.circle"
        }
        switch engine.proximityState {
        case .unlockedInRange:
            return "sensor.tag.radiowaves.forward.fill"
        case .gracePeriodCountdown:
            return "timer"
        case .lockedOutOfRange:
            return "lock.shield.fill"
        case .paused:
            return "pause.circle"
        case .unconfigured:
            return "sensor.tag.radiowaves.forward"
        }
    }
}
