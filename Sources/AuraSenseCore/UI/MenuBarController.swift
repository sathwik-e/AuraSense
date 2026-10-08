import Foundation
import AppKit

/// Menu bar controller managing the macOS status item, proximity indicators,
/// cancellable countdown actions, and user preference toggles.
@MainActor
public final class MenuBarController: NSObject, NSMenuDelegate {
    public let statusItem: NSStatusItem
    public let diagnostics: DiagnosticsManager
    public let settingsStore: any SettingsStoreProtocol
    public let launchAtLoginManager: any LaunchAtLoginProtocol

    private var statusMenuItem: NSMenuItem?
    private var candidateMenuItem: NSMenuItem?
    private var cancelCountdownMenuItem: NSMenuItem?
    private var autoLockMenuItem: NSMenuItem?
    private var autoWakeMenuItem: NSMenuItem?
    private var launchLoginMenuItem: NSMenuItem?

    public init(
        diagnostics: DiagnosticsManager,
        settingsStore: any SettingsStoreProtocol = FileSettingsStore(),
        launchAtLoginManager: any LaunchAtLoginProtocol = SMAppServiceLaunchAtLoginManager()
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.diagnostics = diagnostics
        self.settingsStore = settingsStore
        self.launchAtLoginManager = launchAtLoginManager
        super.init()

        setupStatusItem()
        setupMenu()
        bindDiagnostics()
    }

    private func setupStatusItem() {
        if let button = statusItem.button {
            button.title = "AuraSense"
            if let image = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: "AuraSense") {
                image.isTemplate = true
                button.image = image
                button.imagePosition = .imageLeading
            }
        }
    }

    public func setupMenu() {
        let menu = NSMenu()
        menu.delegate = self

        // 1. Proximity & Candidate Status Header
        let status = NSMenuItem(title: "Status: UNKNOWN", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        self.statusMenuItem = status

        let candidate = NSMenuItem(title: "Candidate: None", action: nil, keyEquivalent: "")
        candidate.isEnabled = false
        menu.addItem(candidate)
        self.candidateMenuItem = candidate

        // 2. Visible Cancellable Countdown Action
        let cancelCountdown = NSMenuItem(
            title: "Cancel Departure Countdown (I'm Here)",
            action: #selector(handleCancelCountdown),
            keyEquivalent: "c"
        )
        cancelCountdown.target = self
        cancelCountdown.isHidden = true
        menu.addItem(cancelCountdown)
        self.cancelCountdownMenuItem = cancelCountdown

        menu.addItem(NSMenuItem.separator())

        // 3. User Settings Toggles
        let settings = settingsStore.currentSettings

        let autoLock = NSMenuItem(
            title: "Auto-Lock on Departure",
            action: #selector(toggleAutoLock),
            keyEquivalent: "l"
        )
        autoLock.target = self
        autoLock.state = settings.isAutoLockEnabled ? .on : .off
        menu.addItem(autoLock)
        self.autoLockMenuItem = autoLock

        let autoWake = NSMenuItem(
            title: "Auto-Wake Display on Return",
            action: #selector(toggleAutoWake),
            keyEquivalent: "w"
        )
        autoWake.target = self
        autoWake.state = settings.isAutoWakeEnabled ? .on : .off
        menu.addItem(autoWake)
        self.autoWakeMenuItem = autoWake

        let launchLogin = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchLogin.target = self
        launchLogin.state = launchAtLoginManager.isEnabled ? .on : .off
        menu.addItem(launchLogin)
        self.launchLoginMenuItem = launchLogin

        menu.addItem(NSMenuItem.separator())

        // 4. Quick Actions
        let lockNow = NSMenuItem(title: "Lock Screen Now", action: #selector(handleLockNow), keyEquivalent: "")
        lockNow.target = self
        menu.addItem(lockNow)

        let wakeNow = NSMenuItem(title: "Wake Display Now", action: #selector(handleWakeNow), keyEquivalent: "")
        wakeNow.target = self
        menu.addItem(wakeNow)

        let copyDiag = NSMenuItem(title: "Copy Diagnostics Report", action: #selector(handleCopyDiagnostics), keyEquivalent: "d")
        copyDiag.target = self
        menu.addItem(copyDiag)

        menu.addItem(NSMenuItem.separator())

        // 5. Termination
        let quit = NSMenuItem(title: "Quit AuraSense", action: #selector(handleQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
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
                button.title = "AuraSense: NEAR"
            case .countdown(let sec):
                button.title = "AuraSense: ⏳ \(sec)s"
            case .far:
                button.title = "AuraSense: FAR"
            case .unknown:
                button.title = "AuraSense: UNKNOWN"
            default:
                button.title = "AuraSense"
            }
        }

        statusMenuItem?.title = "Status: \(state.displayLabel)"
        if let candidate = diagnostics.trustStore.registeredCandidate {
            candidateMenuItem?.title = "Candidate: \(candidate.name)"
        } else {
            candidateMenuItem?.title = "Candidate: None enrolled"
        }

        if state.isCountdown {
            cancelCountdownMenuItem?.isHidden = false
        } else {
            cancelCountdownMenuItem?.isHidden = true
        }
    }

    public func updateCountdown(secondsRemaining: Int) {
        if let button = statusItem.button {
            button.title = "AuraSense: ⏳ \(secondsRemaining)s"
        }
        cancelCountdownMenuItem?.isHidden = false
        cancelCountdownMenuItem?.title = "Cancel Departure Countdown (\(secondsRemaining)s left)"
    }

    // MARK: - Actions

    @objc private func handleCancelCountdown() {
        diagnostics.proximityEngine.userCancelCountdown()
        updateStatus(state: diagnostics.proximityEngine.currentState)
    }

    @objc private func toggleAutoLock() {
        var settings = settingsStore.currentSettings
        settings.isAutoLockEnabled.toggle()
        try? settingsStore.save(settings: settings)
        diagnostics.policyEngine.isAutoLockEnabled = settings.isAutoLockEnabled
        autoLockMenuItem?.state = settings.isAutoLockEnabled ? .on : .off
    }

    @objc private func toggleAutoWake() {
        var settings = settingsStore.currentSettings
        settings.isAutoWakeEnabled.toggle()
        try? settingsStore.save(settings: settings)
        diagnostics.policyEngine.isAutoWakeEnabled = settings.isAutoWakeEnabled
        autoWakeMenuItem?.state = settings.isAutoWakeEnabled ? .on : .off
    }

    @objc private func toggleLaunchAtLogin() {
        let current = launchAtLoginManager.isEnabled
        try? launchAtLoginManager.setEnabled(!current)
        launchLoginMenuItem?.state = launchAtLoginManager.isEnabled ? .on : .off
    }

    @objc private func handleLockNow() {
        Task {
            _ = try? await diagnostics.policyEngine.actionProvider.requestLock()
        }
    }

    @objc private func handleWakeNow() {
        Task {
            _ = try? await diagnostics.policyEngine.actionProvider.wakeDisplay()
        }
    }

    @objc private func handleCopyDiagnostics() {
        // Construct report and copy to general pasteboard
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
