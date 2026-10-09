import Foundation
import AppKit

/// Menu bar controller managing the native macOS status item, compact icon mark,
/// hierarchical menu, cancellable countdowns, and user preference toggles.
@MainActor
public final class MenuBarController: NSObject, NSMenuDelegate {
    public let statusItem: NSStatusItem
    public let diagnostics: DiagnosticsManager
    public let settingsStore: any SettingsStoreProtocol
    public let launchAtLoginManager: any LaunchAtLoginProtocol

    private var statusMenuItem: NSMenuItem?
    private var reasonMenuItem: NSMenuItem?
    private var candidateMenuItem: NSMenuItem?
    private var verificationMenuItem: NSMenuItem?
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
        updateStatus(state: diagnostics.proximityEngine.currentState)
    }

    /// Creates a monochrome vector template icon derived from the radio wave motif.
    public static func createMenuBarTemplateImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let center = NSPoint(x: 9, y: 3)
            let strokeColor = NSColor.black
            strokeColor.setStroke()

            // Transmitter base point
            let dotRect = NSRect(x: 7.5, y: 2, width: 3, height: 3)
            let dot = NSBezierPath(ovalIn: dotRect)
            strokeColor.setFill()
            dot.fill()

            // Inner radio wave arc
            let arc1 = NSBezierPath()
            arc1.lineWidth = 1.3
            arc1.appendArc(withCenter: center, radius: 5.5, startAngle: 35, endAngle: 145)
            arc1.stroke()

            // Mid radio wave arc
            let arc2 = NSBezierPath()
            arc2.lineWidth = 1.3
            arc2.appendArc(withCenter: center, radius: 9.5, startAngle: 40, endAngle: 140)
            arc2.stroke()

            // Outer radio wave arc
            let arc3 = NSBezierPath()
            arc3.lineWidth = 1.3
            arc3.appendArc(withCenter: center, radius: 13.5, startAngle: 45, endAngle: 135)
            arc3.stroke()

            return true
        }
        image.isTemplate = true
        return image
    }

    private func setupStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = Self.createMenuBarTemplateImage()
        button.imagePosition = .imageLeading
        button.title = "" // Icon-first and compact by default
        button.toolTip = "AuraSense Proximity Agent"
    }

    public func setupMenu() {
        let menu = NSMenu()
        menu.delegate = self

        // 1. Proximity State Header
        let status = NSMenuItem(title: "Status: UNKNOWN", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        self.statusMenuItem = status

        let reason = NSMenuItem(title: "Reason: Initializing", action: nil, keyEquivalent: "")
        reason.isEnabled = false
        reason.isHidden = true
        menu.addItem(reason)
        self.reasonMenuItem = reason

        // 2. Candidate Information & Security Boundaries
        let candidate = NSMenuItem(title: "Candidate: None enrolled", action: nil, keyEquivalent: "")
        candidate.isEnabled = false
        menu.addItem(candidate)
        self.candidateMenuItem = candidate

        let verification = NSMenuItem(title: "Security: Local UUID match (Not cryptographically verified)", action: nil, keyEquivalent: "")
        verification.isEnabled = false
        menu.addItem(verification)
        self.verificationMenuItem = verification

        menu.addItem(NSMenuItem.separator())

        // 3. Prominent Cancellable Departure Countdown Action
        let cancelCountdown = NSMenuItem(
            title: "Cancel Departure Countdown (I'm Here)",
            action: #selector(handleCancelCountdown),
            keyEquivalent: "c"
        )
        cancelCountdown.target = self
        cancelCountdown.isHidden = true
        menu.addItem(cancelCountdown)
        self.cancelCountdownMenuItem = cancelCountdown

        // 4. User Preference Toggles
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

        // 5. System Quick Actions
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

        // 6. Application Termination
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

        statusMenuItem?.title = "Status: \(state.displayLabel)"

        if case .unknown(let reason) = state {
            reasonMenuItem?.isHidden = false
            reasonMenuItem?.title = "Reason: \(reason)"
        } else {
            reasonMenuItem?.isHidden = true
        }

        if let candidate = diagnostics.trustStore.registeredCandidate {
            candidateMenuItem?.title = "Candidate: \(candidate.name)"
            verificationMenuItem?.isHidden = false
        } else {
            candidateMenuItem?.title = "Candidate: None enrolled (All blocked)"
            verificationMenuItem?.isHidden = true
        }

        if state.isCountdown {
            cancelCountdownMenuItem?.isHidden = false
        } else {
            cancelCountdownMenuItem?.isHidden = true
        }
    }

    public func updateCountdown(secondsRemaining: Int) {
        if let button = statusItem.button {
            button.title = " ⏳ \(secondsRemaining)s"
            button.setAccessibilityLabel("AuraSense: Departure Countdown, \(secondsRemaining) seconds remaining")
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
        do {
            var settings = settingsStore.currentSettings
            settings.isAutoLockEnabled.toggle()
            try settingsStore.save(settings: settings)
            diagnostics.policyEngine.isAutoLockEnabled = settings.isAutoLockEnabled
            autoLockMenuItem?.state = settings.isAutoLockEnabled ? .on : .off
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
            autoWakeMenuItem?.state = settings.isAutoWakeEnabled ? .on : .off
            diagnostics.log(level: .info, category: "UI.Settings", message: "Auto-Wake set to \(settings.isAutoWakeEnabled)")
        } catch {
            diagnostics.log(level: .error, category: "UI.Settings", message: "Failed to persist Auto-Wake: \(error.localizedDescription)")
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            let current = launchAtLoginManager.isEnabled
            try launchAtLoginManager.setEnabled(!current)
            launchLoginMenuItem?.state = launchAtLoginManager.isEnabled ? .on : .off
            diagnostics.log(level: .info, category: "UI.Settings", message: "Launch at Login set to \(launchAtLoginManager.isEnabled)")
        } catch {
            diagnostics.log(level: .error, category: "UI.Settings", message: "Failed to update Launch at Login: \(error.localizedDescription)")
        }
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
