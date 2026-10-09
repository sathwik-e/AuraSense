import Foundation
import AppKit

/// Menu bar controller managing the native status popover and proximity actions.
@MainActor
public final class MenuBarController: NSObject {
    public let statusItem: NSStatusItem
    public let diagnostics: DiagnosticsManager
    public let settingsStore: any SettingsStoreProtocol
    public let launchAtLoginManager: any LaunchAtLoginProtocol
    private let scanner: (any BLEScannerProtocol)?

    public let popover = NSPopover()
    private let popoverController: AuraSenseStatusPopoverViewController
    private var setupWindowController: DeviceSetupWindowController?
    private var dashboardWindowController: AuraSenseDashboardWindowController?

    public init(
        diagnostics: DiagnosticsManager,
        scanner: (any BLEScannerProtocol)? = nil,
        settingsStore: any SettingsStoreProtocol = FileSettingsStore(),
        launchAtLoginManager: any LaunchAtLoginProtocol = SMAppServiceLaunchAtLoginManager()
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.diagnostics = diagnostics
        self.scanner = scanner
        self.settingsStore = settingsStore
        self.launchAtLoginManager = launchAtLoginManager
        self.popoverController = AuraSenseStatusPopoverViewController()
        super.init()

        setupStatusItem()
        setupPopover()
        bindDiagnostics()
        updateStatus(state: diagnostics.proximityEngine.currentState)
    }

    /// Creates a compact phone-and-lock mark that reads as device security, not Wi-Fi.
    public static func createMenuBarTemplateImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let phone = NSBezierPath(roundedRect: NSRect(x: 2, y: 1, width: 10, height: 16), xRadius: 2, yRadius: 2)
            phone.lineWidth = 1.35
            phone.stroke()
            NSBezierPath(roundedRect: NSRect(x: 5, y: 14.4, width: 4, height: 0.7), xRadius: 0.35, yRadius: 0.35).fill()
            NSBezierPath(ovalIn: NSRect(x: 6.2, y: 2.3, width: 1.6, height: 1.6)).fill()

            let lockBody = NSBezierPath(roundedRect: NSRect(x: 10, y: 2, width: 7, height: 6), xRadius: 1.2, yRadius: 1.2)
            lockBody.fill()
            let shackle = NSBezierPath()
            shackle.lineWidth = 1.25
            shackle.appendArc(withCenter: NSPoint(x: 13.5, y: 8), radius: 2.15, startAngle: 0, endAngle: 180)
            shackle.stroke()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: 13, y: 4.5, width: 1, height: 1)).fill()

            return true
        }
        image.isTemplate = true
        return image
    }

    private func setupStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = Self.createMenuBarTemplateImage()
        button.imagePosition = .imageLeading
        button.title = ""
        button.toolTip = "AuraSense — iPhone proximity and screen lock"
        button.target = self
        button.action = #selector(togglePopover)
    }

    private func setupPopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 340, height: 470)
        popover.contentViewController = popoverController
        popoverController.onSetupPhone = { [weak self] in self?.openDeviceSetup() }
        popoverController.onToggleAutoLock = { [weak self] _ in self?.toggleAutoLock() }
        popoverController.onToggleAutoWake = { [weak self] _ in self?.toggleAutoWake() }
        popoverController.onToggleLaunchAtLogin = { [weak self] _ in self?.toggleLaunchAtLogin() }
        popoverController.onLockNow = { [weak self] in self?.handleLockNow() }
        popoverController.onCancelCountdown = { [weak self] in self?.handleCancelCountdown() }
        popoverController.onCopyDiagnostics = { [weak self] in self?.handleCopyDiagnostics() }
        popoverController.onOpenDashboard = { [weak self] in self?.showDashboard() }
        popoverController.onQuit = { [weak self] in self?.handleQuit() }
    }

    @objc private func togglePopover() {
        showPopover()
    }

    public func showPopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            refreshPopover()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    public func presentDeviceSetup() {
        openDeviceSetup()
    }

    public func showDashboard() {
        guard let scanner else {
            diagnostics.log(level: .error, category: "UI", message: "Cannot open dashboard without an active Bluetooth scanner")
            return
        }
        if dashboardWindowController == nil {
            dashboardWindowController = AuraSenseDashboardWindowController(
                diagnostics: diagnostics,
                scanner: scanner,
                settingsStore: settingsStore,
                launchAtLoginManager: launchAtLoginManager,
                onSetupPhone: { [weak self] in self?.openDeviceSetup() },
                onClose: { NSApp.setActivationPolicy(.accessory) }
            )
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        dashboardWindowController?.showWindow(nil)
        dashboardWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    private func refreshPopover() {
        let candidate = diagnostics.trustStore.registeredCandidate
        let recentRSSI = candidate.flatMap { selected in
            diagnostics.registry.peripheral(for: selected.id).flatMap { peripheral in
                Date().timeIntervalSince(peripheral.lastSeen) <= 15 ? peripheral.latestRSSI : nil
            }
        }
        let settings = settingsStore.currentSettings
        popoverController.update(
            state: diagnostics.proximityEngine.currentState,
            candidate: candidate,
            rssi: recentRSSI,
            autoLock: settings.isAutoLockEnabled,
            autoWake: settings.isAutoWakeEnabled,
            launchAtLogin: launchAtLoginManager.isEnabled,
            canLock: diagnostics.policyEngine.actionProvider.isLockSupported
        )
        dashboardWindowController?.refresh()
    }

    @objc private func openDeviceSetup() {
        if setupWindowController == nil {
            setupWindowController = DeviceSetupWindowController(diagnostics: diagnostics, scanner: scanner) { [weak self] in
                guard let self else { return }
                NSApp.setActivationPolicy(.accessory)
                self.updateStatus(state: self.diagnostics.proximityEngine.currentState)
            }
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        setupWindowController?.showWindow(nil)
        setupWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    private func bindDiagnostics() {
        diagnostics.proximityEngine.onStateTransition = { [weak self] oldState, newState, reason in
            Task { @MainActor [weak self] in
                self?.updateStatus(state: newState)
            }
        }

        diagnostics.proximityEngine.onCountdownTick = { [weak self] remaining in
            Task { @MainActor [weak self] in
                self?.updateCountdown(secondsRemaining: remaining)
            }
        }
    }

    public func updateStatus(state: ProximityState) {
        if let button = statusItem.button {
            switch state {
            case .near:
                button.title = ""
                button.toolTip = "AuraSense: In Range (NEAR)"
                button.setAccessibilityLabel("AuraSense: In Range (NEAR)")

            case .countdown(let sec):
                button.title = " ⏳ \(sec)s"
                button.toolTip = "AuraSense: Departure countdown (\(sec)s)"
                button.setAccessibilityLabel("AuraSense: Departure Countdown, \(sec) seconds remaining")

            case .far:
                button.title = ""
                button.toolTip = "AuraSense: Out of Range (FAR)"
                button.setAccessibilityLabel("AuraSense: Out of Range (FAR)")

            case .unknown(let reason):
                button.title = ""
                button.toolTip = "AuraSense: Unknown (\(reason))"
                button.setAccessibilityLabel("AuraSense: Unknown State, \(reason)")

            default:
                button.title = ""
                button.toolTip = "AuraSense"
                button.setAccessibilityLabel("AuraSense")
            }
        }

        refreshPopover()
    }

    public func updateCountdown(secondsRemaining: Int) {
        if let button = statusItem.button {
            button.title = " ⏳ \(secondsRemaining)s"
            button.setAccessibilityLabel("AuraSense: Departure Countdown, \(secondsRemaining) seconds remaining")
        }
        refreshPopover()
    }

    // MARK: - Actions

    @objc private func handleCancelCountdown() {
        diagnostics.proximityEngine.userCancelCountdown()
        updateStatus(state: diagnostics.proximityEngine.currentState)
    }

    @objc private func handleForgetCandidate() {
        do {
            try diagnostics.unregisterCandidate()
            updateStatus(state: diagnostics.proximityEngine.currentState)
        } catch {
            diagnostics.log(level: .error, category: "UI.Trust", message: "Failed to forget trusted iPhone: \(error.localizedDescription)")
        }
    }

    @objc private func toggleAutoLock() {
        do {
            var settings = settingsStore.currentSettings
            settings.isAutoLockEnabled.toggle()
            try settingsStore.save(settings: settings)
            diagnostics.policyEngine.isAutoLockEnabled = settings.isAutoLockEnabled
            refreshPopover()
            diagnostics.log(level: .info, category: "UI.Settings", message: "Auto-Lock set to \(settings.isAutoLockEnabled)")
        } catch {
            diagnostics.log(level: .error, category: "UI.Settings", message: "Failed to persist Auto-Lock: \(error.localizedDescription)")
        }
    }

    @objc private func toggleAutoWake() {
        do {
            var settings = settingsStore.currentSettings
            settings.isAutoWakeEnabled.toggle()
            try settingsStore.save(settings: settings)
            diagnostics.policyEngine.isAutoWakeEnabled = settings.isAutoWakeEnabled
            refreshPopover()
            diagnostics.log(level: .info, category: "UI.Settings", message: "Auto-Wake set to \(settings.isAutoWakeEnabled)")
        } catch {
            diagnostics.log(level: .error, category: "UI.Settings", message: "Failed to persist Auto-Wake: \(error.localizedDescription)")
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            let current = launchAtLoginManager.isEnabled
            try launchAtLoginManager.setEnabled(!current)
            refreshPopover()
            diagnostics.log(level: .info, category: "UI.Settings", message: "Launch at Login set to \(launchAtLoginManager.isEnabled)")
        } catch {
            diagnostics.log(level: .error, category: "UI.Settings", message: "Failed to update Launch at Login: \(error.localizedDescription)")
        }
    }

    @objc private func handleLockNow() {
        Task {
            do {
                let result = try await diagnostics.policyEngine.actionProvider.requestLock()
                diagnostics.log(level: .info, category: "Policy.Action", message: "Manual lock request: \(result)")
            } catch {
                diagnostics.log(level: .error, category: "Policy.Action", message: "Manual lock request failed: \(error.localizedDescription)")
            }
        }
    }

    @objc private func handleCopyDiagnostics() {
        let records = diagnostics.registry.diagnosticsRecords()
        let snapshot = DiagnosticsSnapshot(
            radioState: .poweredOn,
            authorizationStatus: .allowedAlways,
            isScanning: true,
            candidate: diagnostics.trustStore.registeredCandidate,
            proximityState: diagnostics.proximityEngine.currentState,
            smoothedRSSI: diagnostics.proximityEngine.filter.currentSmoothedRSSI,
            isAutoLockEnabled: diagnostics.policyEngine.isAutoLockEnabled,
            locksExecutedCount: diagnostics.policyEngine.locksExecutedCount,
            isAutoWakeEnabled: diagnostics.policyEngine.isAutoWakeEnabled,
            wakesExecutedCount: diagnostics.policyEngine.wakesExecutedCount,
            sessionState: diagnostics.authCoordinator.detector.currentSessionState(),
            authPath: diagnostics.authCoordinator.evaluateUnlockPath(),
            gateAdmittedCount: diagnostics.gate.admittedCount,
            gateBlockedCount: diagnostics.gate.blockedCount,
            gateAmbiguityCount: diagnostics.gate.ambiguityCount,
            peripherals: records,
            recentEvents: diagnostics.recentEvents()
        )

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(snapshot.formattedReport, forType: .string)
    }

    @objc private func handleQuit() {
        NSApplication.shared.terminate(nil)
    }
}
