import AppKit

@MainActor
final class AuraSenseStatusPopoverViewController: NSViewController {
    var onSetupPhone: (() -> Void)?
    var onToggleAutoLock: ((Bool) -> Void)?
    var onToggleAutoWake: ((Bool) -> Void)?
    var onToggleLaunchAtLogin: ((Bool) -> Void)?
    var onLockNow: (() -> Void)?
    var onCancelCountdown: (() -> Void)?
    var onCopyDiagnostics: (() -> Void)?
    var onOpenDashboard: (() -> Void)?
    var onQuit: (() -> Void)?

    private let stateTitle = NSTextField(labelWithString: "Starting…")
    private let stateDetail = NSTextField(labelWithString: "Connecting to Bluetooth")
    private let phoneTitle = NSTextField(labelWithString: "No trusted iPhone")
    private let phoneDetail = NSTextField(labelWithString: "Choose your phone to begin")
    private let autoLockButton = NSButton(checkboxWithTitle: "Lock Mac when my phone leaves", target: nil, action: nil)
    private let autoWakeButton = NSButton(checkboxWithTitle: "Wake display when my phone returns", target: nil, action: nil)
    private let launchButton = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let lockButton = NSButton(title: "Lock Screen Now", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel countdown — I’m here", target: nil, action: nil)
    private let setupButton = NSButton(title: "Choose or change iPhone…", target: nil, action: nil)
    private let footerLabel = NSTextField(labelWithString: "Bluetooth proximity is an estimate. It cannot unlock macOS.")

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 430))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let appIcon = NSImageView()
        appIcon.image = NSImage(systemSymbolName: "iphone", accessibilityDescription: "iPhone")
        appIcon.contentTintColor = .controlAccentColor
        appIcon.setContentHuggingPriority(.required, for: .horizontal)
        appIcon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        appIcon.heightAnchor.constraint(equalToConstant: 34).isActive = true

        let brand = NSTextField(labelWithString: "AuraSense")
        brand.font = .systemFont(ofSize: 18, weight: .semibold)
        let caption = NSTextField(labelWithString: "IPHONE PROXIMITY")
        caption.font = .systemFont(ofSize: 9, weight: .bold)
        caption.textColor = .secondaryLabelColor
        let brandStack = NSStackView(views: [brand, caption])
        brandStack.orientation = .vertical
        brandStack.alignment = .leading
        brandStack.spacing = 1
        let header = NSStackView(views: [appIcon, brandStack])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10

        stateTitle.font = .systemFont(ofSize: 16, weight: .semibold)
        stateDetail.font = .systemFont(ofSize: 12)
        stateDetail.textColor = .secondaryLabelColor
        let stateCard = card(with: [stateTitle, stateDetail])

        phoneTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        phoneDetail.font = .systemFont(ofSize: 12)
        phoneDetail.textColor = .secondaryLabelColor
        let phoneCard = card(with: [phoneTitle, phoneDetail])

        setupButton.bezelStyle = .rounded
        setupButton.target = self
        setupButton.action = #selector(setupPhone)
        setupButton.keyEquivalent = "\r"

        autoLockButton.target = self
        autoLockButton.action = #selector(autoLockChanged)
        autoWakeButton.target = self
        autoWakeButton.action = #selector(autoWakeChanged)
        launchButton.target = self
        launchButton.action = #selector(launchChanged)

        lockButton.bezelStyle = .rounded
        lockButton.target = self
        lockButton.action = #selector(lockNow)
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelCountdown)
        cancelButton.isHidden = true

        let actionRow = NSStackView(views: [lockButton, cancelButton])
        actionRow.orientation = .horizontal
        actionRow.distribution = .fillEqually
        actionRow.spacing = 8

        let preferences = NSStackView(views: [autoLockButton, autoWakeButton, launchButton])
        preferences.orientation = .vertical
        preferences.alignment = .leading
        preferences.spacing = 6

        footerLabel.font = .systemFont(ofSize: 10)
        footerLabel.textColor = .tertiaryLabelColor
        footerLabel.maximumNumberOfLines = 2
        let diagnosticsButton = NSButton(title: "Copy Diagnostics", target: self, action: #selector(copyDiagnostics))
        diagnosticsButton.bezelStyle = .inline
        let dashboardButton = NSButton(title: "Open AuraSense…", target: self, action: #selector(openDashboard))
        dashboardButton.bezelStyle = .inline
        let quitButton = NSButton(title: "Quit", target: self, action: #selector(quit))
        quitButton.bezelStyle = .inline
        let footerButtons = NSStackView(views: [diagnosticsButton, dashboardButton, quitButton])
        footerButtons.orientation = .horizontal
        footerButtons.alignment = .centerY
        footerButtons.distribution = .equalSpacing
        let footerActions = NSStackView(views: [footerLabel, footerButtons])
        footerActions.orientation = .vertical
        footerActions.alignment = .leading
        footerActions.spacing = 6

        let stack = NSStackView(views: [header, stateCard, phoneCard, setupButton, actionRow, preferences, footerActions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 13
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -16),
            stateCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            phoneCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            setupButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actionRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            preferences.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footerActions.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        view = root
    }

    func update(
        state: ProximityState,
        candidate: CandidateDevice?,
        rssi: Int?,
        autoLock: Bool,
        autoWake: Bool,
        launchAtLogin: Bool,
        canLock: Bool
    ) {
        stateTitle.stringValue = state.displayLabel
        switch state {
        case .near(let value):
            stateDetail.stringValue = "Your selected phone is nearby · \(Int(value.rounded())) dBm"
        case .countdown(let seconds):
            stateDetail.stringValue = "Locking in \(seconds) seconds unless you return"
        case .far:
            stateDetail.stringValue = "Your selected phone is out of range"
        case .unknown(let reason):
            stateDetail.stringValue = reason
        default:
            stateDetail.stringValue = "Proximity monitoring status"
        }
        phoneTitle.stringValue = candidate?.name ?? "No trusted iPhone selected"
        if let candidate {
            phoneDetail.stringValue = "\(rssi.map { "\($0) dBm nearby" } ?? "Waiting for Bluetooth signal") · ID \(candidate.id.uuidString.prefix(8))"
        } else {
            phoneDetail.stringValue = "Set up an iPhone to enable proximity monitoring"
        }
        autoLockButton.state = autoLock ? .on : .off
        autoLockButton.isEnabled = canLock && candidate != nil
        autoWakeButton.state = autoWake ? .on : .off
        launchButton.state = launchAtLogin ? .on : .off
        lockButton.isEnabled = canLock
        cancelButton.isHidden = !state.isCountdown
        lockButton.isHidden = state.isCountdown
        setupButton.title = candidate == nil ? "Choose your iPhone…" : "Change trusted iPhone…"
    }

    private func card(with labels: [NSView]) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        container.layer?.cornerRadius = 10
        let stack = NSStackView(views: labels)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 11),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -11)
        ])
        return container
    }

    @objc private func setupPhone() { onSetupPhone?() }
    @objc private func autoLockChanged() { onToggleAutoLock?(autoLockButton.state == .on) }
    @objc private func autoWakeChanged() { onToggleAutoWake?(autoWakeButton.state == .on) }
    @objc private func launchChanged() { onToggleLaunchAtLogin?(launchButton.state == .on) }
    @objc private func lockNow() { onLockNow?() }
    @objc private func cancelCountdown() { onCancelCountdown?() }
    @objc private func copyDiagnostics() { onCopyDiagnostics?() }
    @objc private func openDashboard() { onOpenDashboard?() }
    @objc private func quit() { onQuit?() }
}
