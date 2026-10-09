import AppKit

@MainActor
final class AuraSenseDashboardWindowController: NSWindowController, NSWindowDelegate {
    private let diagnostics: DiagnosticsManager
    private let scanner: any BLEScannerProtocol
    private let settingsStore: any SettingsStoreProtocol
    private let launchAtLoginManager: any LaunchAtLoginProtocol
    private let onSetupPhone: () -> Void
    private let onClose: () -> Void
    private let statusLabel = NSTextField(labelWithString: "Starting…")
    private let detailLabel = NSTextField(labelWithString: "Connecting to Bluetooth")
    private let deviceLabel = NSTextField(labelWithString: "No iPhone selected")
    private let signalLabel = NSTextField(labelWithString: "Choose a trusted device to begin")
    private let radioLabel = NSTextField(labelWithString: "Bluetooth: Starting")
    private let lockToggle = NSButton(checkboxWithTitle: "Lock this Mac when my iPhone leaves", target: nil, action: nil)
    private let wakeToggle = NSButton(checkboxWithTitle: "Wake the display when my iPhone returns", target: nil, action: nil)
    private let launchToggle = NSButton(checkboxWithTitle: "Open AuraSense at login", target: nil, action: nil)
    private let nearThresholdSlider = NSSlider(value: -60, minValue: -85, maxValue: -40, target: nil, action: nil)
    private let farThresholdSlider = NSSlider(value: -75, minValue: -100, maxValue: -45, target: nil, action: nil)
    private let farDwellSlider = NSSlider(value: 10, minValue: 1, maxValue: 30, target: nil, action: nil)
    private let countdownSlider = NSSlider(value: 5, minValue: 3, maxValue: 30, target: nil, action: nil)
    private let signalLossSlider = NSSlider(value: 15, minValue: 5, maxValue: 120, target: nil, action: nil)
    private let peripheralStack = NSStackView()
    private let warningLabel = NSTextField(wrappingLabelWithString: "Bluetooth signal is an estimate, not proof of identity or distance. AuraSense can lock the screen; it cannot unlock a macOS session.")
    private var refreshTimer: Timer?

    init(
        diagnostics: DiagnosticsManager,
        scanner: any BLEScannerProtocol,
        settingsStore: any SettingsStoreProtocol,
        launchAtLoginManager: any LaunchAtLoginProtocol,
        onSetupPhone: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.diagnostics = diagnostics
        self.scanner = scanner
        self.settingsStore = settingsStore
        self.launchAtLoginManager = launchAtLoginManager
        self.onSetupPhone = onSetupPhone
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AuraSense"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 520)
        super.init(window: window)
        window.delegate = self
        buildInterface()
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        onClose()
    }

    func refresh() {
        let snapshot = diagnostics.snapshot(from: scanner)
        statusLabel.stringValue = snapshot.proximityState.displayLabel
        detailLabel.stringValue = statusDetail(for: snapshot.proximityState)
        statusLabel.textColor = stateColor(for: snapshot.proximityState)
        if let candidate = snapshot.candidate {
            deviceLabel.stringValue = candidate.name
            signalLabel.stringValue = snapshot.smoothedRSSI.map { "\(Int($0.rounded())) dBm · ID \(candidate.id.uuidString.prefix(8))" } ?? "Waiting for a fresh Bluetooth signal"
        } else {
            deviceLabel.stringValue = "No iPhone selected"
            signalLabel.stringValue = "Choose your iPhone to enable proximity monitoring"
        }
        radioLabel.stringValue = "Bluetooth: \(snapshot.radioState.rawValue) · \(snapshot.isScanning ? "Scanning" : "Not scanning") · \(snapshot.authorizationStatus.rawValue)"
        let settings = settingsStore.currentSettings
        lockToggle.state = settings.isAutoLockEnabled ? .on : .off
        lockToggle.isEnabled = snapshot.candidate != nil && diagnostics.policyEngine.actionProvider.isLockSupported
        wakeToggle.state = settings.isAutoWakeEnabled ? .on : .off
        launchToggle.state = launchAtLoginManager.isEnabled ? .on : .off
        nearThresholdSlider.doubleValue = settings.nearGateRSSI
        farThresholdSlider.doubleValue = settings.farGateRSSI
        farDwellSlider.doubleValue = settings.farDwellDuration
        countdownSlider.doubleValue = Double(settings.countdownDuration)
        signalLossSlider.doubleValue = settings.signalLossTimeout
        updateSliderValueLabels(settings: settings)
        updatePeripherals(snapshot.peripherals, selected: snapshot.candidate?.id)
    }

    private func buildInterface() {
        guard let window, let content = window.contentView else { return }
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scrollView)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 30, bottom: 28, right: 30)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = stack
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor)
        ])

        let headerIcon = NSImageView(image: NSImage(systemSymbolName: "iphone.and.lock", accessibilityDescription: "AuraSense") ?? NSImage())
        headerIcon.contentTintColor = .controlAccentColor
        headerIcon.widthAnchor.constraint(equalToConstant: 36).isActive = true
        headerIcon.heightAnchor.constraint(equalToConstant: 42).isActive = true
        let title = NSTextField(labelWithString: "AuraSense")
        title.font = .systemFont(ofSize: 25, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Your Mac’s proximity and screen-lock controls")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        let titleGroup = verticalStack([title, subtitle], spacing: 3)
        let header = NSStackView(views: [headerIcon, titleGroup])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 14
        stack.addArrangedSubview(header)

        statusLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = .secondaryLabelColor
        radioLabel.font = .systemFont(ofSize: 12)
        radioLabel.textColor = .secondaryLabelColor
        let statusCard = card(title: "PROXIMITY STATUS", symbol: "dot.radiowaves.left.and.right", content: [statusLabel, detailLabel, radioLabel])
        stack.addArrangedSubview(statusCard)

        deviceLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        signalLabel.font = .systemFont(ofSize: 12)
        signalLabel.textColor = .secondaryLabelColor
        let phoneIcon = NSImageView(image: NSImage(systemSymbolName: "iphone", accessibilityDescription: "Selected iPhone") ?? NSImage())
        phoneIcon.contentTintColor = .controlAccentColor
        phoneIcon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        phoneIcon.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let phoneInfo = verticalStack([deviceLabel, signalLabel], spacing: 4)
        let phoneRow = NSStackView(views: [phoneIcon, phoneInfo])
        phoneRow.orientation = .horizontal
        phoneRow.alignment = .centerY
        phoneRow.spacing = 12
        let setup = NSButton(title: "Choose iPhone…", target: self, action: #selector(openSetup))
        setup.bezelStyle = .rounded
        let deviceCard = card(title: "TRUSTED DEVICE", symbol: "iphone", content: [phoneRow, setup])
        stack.addArrangedSubview(deviceCard)

        for toggle in [lockToggle, wakeToggle, launchToggle] {
            toggle.target = self
            toggle.action = #selector(settingChanged(_:))
        }
        let proximitySliders: [(NSSlider, Int)] = [
            (nearThresholdSlider, 1),
            (farThresholdSlider, 2),
            (farDwellSlider, 3),
            (countdownSlider, 4),
            (signalLossSlider, 5)
        ]
        for (slider, tag) in proximitySliders {
            slider.target = self
            slider.action = #selector(proximitySettingChanged(_:))
            slider.tag = tag
            slider.isContinuous = false
        }
        let thresholdRows = [
            settingRow("Near gate", value: "", slider: nearThresholdSlider, id: 1),
            settingRow("Far gate", value: "", slider: farThresholdSlider, id: 2),
            settingRow("Departure dwell", value: "", slider: farDwellSlider, id: 3),
            settingRow("Lock countdown", value: "", slider: countdownSlider, id: 4),
            settingRow("Signal-loss timeout", value: "", slider: signalLossSlider, id: 5)
        ]
        warningLabel.font = .systemFont(ofSize: 11)
        warningLabel.textColor = .secondaryLabelColor
        warningLabel.stringValue = "Near/far gates maintain hysteresis. Signal loss waits its own timeout; settings changes reset proximity evidence. BLE is not an authentication factor, and AuraSense cannot unlock a macOS session."
        let preferences = card(title: "AUTOMATION & PROXIMITY", symbol: "slider.horizontal.3", content: [lockToggle, wakeToggle, launchToggle] + thresholdRows + [warningLabel])
        stack.addArrangedSubview(preferences)

        peripheralStack.orientation = .vertical
        peripheralStack.alignment = .leading
        peripheralStack.spacing = 8
        let scanButton = NSButton(title: "Scan again", target: self, action: #selector(scanAgain))
        scanButton.bezelStyle = .rounded
        let nearby = card(title: "NEARBY BLUETOOTH DEVICES", symbol: "dot.radiowaves.left.and.right", content: [peripheralStack, scanButton])
        stack.addArrangedSubview(nearby)

        let lockNow = NSButton(title: "Lock Screen Now", target: self, action: #selector(lockNow))
        lockNow.bezelStyle = .rounded
        lockNow.keyEquivalent = "l"
        let copy = NSButton(title: "Copy Diagnostics", target: self, action: #selector(copyDiagnostics))
        copy.bezelStyle = .rounded
        let actions = NSStackView(views: [lockNow, copy])
        actions.orientation = .horizontal
        actions.spacing = 8
        stack.addArrangedSubview(actions)

        for item in [statusCard, deviceCard, preferences, nearby] {
            item.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -60).isActive = true
        }
    }

    private func card(title: String, symbol: String, content: [NSView]) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        container.layer?.cornerRadius = 12
        let headingIcon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        headingIcon.contentTintColor = .secondaryLabelColor
        headingIcon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        headingIcon.heightAnchor.constraint(equalToConstant: 14).isActive = true
        let headingLabel = NSTextField(labelWithString: title)
        headingLabel.font = .systemFont(ofSize: 10, weight: .bold)
        headingLabel.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [headingIcon, headingLabel])
        heading.orientation = .horizontal
        heading.spacing = 7
        let body = verticalStack(content, spacing: 10)
        let inner = verticalStack([heading, body], spacing: 12)
        inner.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            inner.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            inner.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            inner.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16)
        ])
        return container
    }

    private func verticalStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func settingRow(_ title: String, value: String, slider: NSSlider, id: Int) -> NSView {
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 12)
        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        valueLabel.alignment = .right
        valueLabel.identifier = NSUserInterfaceItemIdentifier("proximity-setting-\(id)")
        let labels = NSStackView(views: [name, valueLabel])
        labels.orientation = .horizontal
        labels.distribution = .fill
        labels.widthAnchor.constraint(equalToConstant: 560).isActive = true
        valueLabel.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let row = verticalStack([labels, slider], spacing: 2)
        slider.widthAnchor.constraint(equalToConstant: 560).isActive = true
        return row
    }

    private func updateSliderValueLabels(settings: UserSettings) {
        let values: [(Int, String)] = [
            (1, "\(Int(settings.nearGateRSSI)) dBm"),
            (2, "\(Int(settings.farGateRSSI)) dBm"),
            (3, "\(Int(settings.farDwellDuration)) sec"),
            (4, "\(settings.countdownDuration) sec"),
            (5, "\(Int(settings.signalLossTimeout)) sec")
        ]
        for (id, value) in values {
            if let label = findView(in: window?.contentView, identifier: "proximity-setting-\(id)") as? NSTextField {
                label.stringValue = value
            }
        }
    }

    private func findView(in view: NSView?, identifier: String) -> NSView? {
        guard let view else { return nil }
        if view.identifier?.rawValue == identifier { return view }
        for child in view.subviews {
            if let found = findView(in: child, identifier: identifier) { return found }
        }
        return nil
    }

    private func updatePeripherals(_ records: [PeripheralDiagnosticsRecord], selected: UUID?) {
        peripheralStack.arrangedSubviews.forEach { view in
            peripheralStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let visible = records.sorted { $0.lastSeen > $1.lastSeen }.prefix(5)
        if visible.isEmpty {
            peripheralStack.addArrangedSubview(NSTextField(labelWithString: "No Bluetooth devices discovered yet"))
            return
        }
        for device in visible {
            let displayName = device.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Unnamed device"
            let selectedMark = device.id == selected ? " · Selected" : ""
            let row = NSTextField(labelWithString: "\(displayName)    \(device.latestRSSI) dBm    \(device.liveness.rawValue)\(selectedMark)")
            row.font = .systemFont(ofSize: 12)
            row.textColor = device.id == selected ? .controlAccentColor : .labelColor
            peripheralStack.addArrangedSubview(row)
        }
    }

    private func statusDetail(for state: ProximityState) -> String {
        switch state {
        case .near(let rssi): "Selected iPhone is nearby · \(Int(rssi.rounded())) dBm"
        case .countdown(let seconds): "Screen locks in \(seconds) seconds unless the iPhone returns"
        case .far: "Selected iPhone has remained out of range"
        case .unknown(let reason): reason
        default: "Proximity monitoring status"
        }
    }

    private func stateColor(for state: ProximityState) -> NSColor {
        switch state {
        case .near: .systemGreen
        case .countdown: .systemOrange
        case .far: .systemRed
        default: .secondaryLabelColor
        }
    }

    @objc private func openSetup() { onSetupPhone() }

    @objc private func settingChanged(_ sender: NSButton) {
        do {
            var settings = settingsStore.currentSettings
            switch sender {
            case lockToggle:
                settings.isAutoLockEnabled = sender.state == .on
                try settingsStore.save(settings: settings)
                diagnostics.policyEngine.isAutoLockEnabled = settings.isAutoLockEnabled
            case wakeToggle:
                settings.isAutoWakeEnabled = sender.state == .on
                try settingsStore.save(settings: settings)
                diagnostics.policyEngine.isAutoWakeEnabled = settings.isAutoWakeEnabled
            case launchToggle:
                try launchAtLoginManager.setEnabled(sender.state == .on)
            default:
                return
            }
            refresh()
        } catch {
            NSSound.beep()
            refresh()
        }
    }

    @objc private func proximitySettingChanged(_ sender: NSSlider) {
        let oldSettings = settingsStore.currentSettings
        var settings = oldSettings
        switch sender.tag {
        case 1:
            settings.nearGateRSSI = sender.doubleValue.rounded()
            if settings.nearGateRSSI - settings.farGateRSSI < 3 {
                settings.farGateRSSI = settings.nearGateRSSI - 3
            }
        case 2:
            settings.farGateRSSI = max(sender.doubleValue.rounded(), -88)
            if settings.nearGateRSSI - settings.farGateRSSI < 3 {
                settings.nearGateRSSI = settings.farGateRSSI + 3
            }
        case 3:
            settings.farDwellDuration = sender.doubleValue.rounded()
        case 4:
            settings.countdownDuration = Int(sender.doubleValue.rounded())
        case 5:
            settings.signalLossTimeout = sender.doubleValue.rounded()
        default:
            return
        }

        var configuration = diagnostics.proximityEngine.config
        configuration.nearGateRSSI = settings.nearGateRSSI
        configuration.farGateRSSI = settings.farGateRSSI
        configuration.farDwellDuration = settings.farDwellDuration
        configuration.countdownDuration = settings.countdownDuration
        configuration.staleTimeout = settings.signalLossTimeout
        configuration.maxGapDuration = max(15, settings.signalLossTimeout)
        guard settings.hasValidProximitySettings, configuration.isValid,
              diagnostics.proximityEngine.updateConfiguration(configuration) else {
            refresh()
            NSSound.beep()
            return
        }

        do {
            try settingsStore.save(settings: settings)
            diagnostics.log(level: .info, category: "UI.Settings", message: "Updated live proximity configuration")
            refresh()
        } catch {
            var previousConfiguration = configuration
            previousConfiguration.nearGateRSSI = oldSettings.nearGateRSSI
            previousConfiguration.farGateRSSI = oldSettings.farGateRSSI
            previousConfiguration.farDwellDuration = oldSettings.farDwellDuration
            previousConfiguration.countdownDuration = oldSettings.countdownDuration
            previousConfiguration.staleTimeout = oldSettings.signalLossTimeout
            previousConfiguration.maxGapDuration = max(15, oldSettings.signalLossTimeout)
            _ = diagnostics.proximityEngine.updateConfiguration(previousConfiguration)
            diagnostics.log(level: .error, category: "UI.Settings", message: "Could not save proximity configuration: \(error.localizedDescription)")
            refresh()
        }
    }

    @objc private func scanAgain() {
        scanner.stopScanning()
        do {
            try scanner.startScanning(serviceUUIDs: nil)
        } catch {
            diagnostics.log(level: .error, category: "UI.Bluetooth", message: "Dashboard scan request failed: \(error.localizedDescription)")
        }
        refresh()
    }

    @objc private func lockNow() {
        Task {
            do {
                let result = try await diagnostics.policyEngine.actionProvider.requestLock()
                diagnostics.log(level: .info, category: "Policy.Action", message: "Manual lock request: \(result)")
            } catch {
                diagnostics.log(level: .error, category: "Policy.Action", message: "Manual lock request failed: \(error.localizedDescription)")
            }
        }
    }

    @objc private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics.snapshot(from: scanner).formattedReport, forType: .string)
    }
}
