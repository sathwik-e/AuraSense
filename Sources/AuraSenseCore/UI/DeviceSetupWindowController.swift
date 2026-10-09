import AppKit

@MainActor
final class DeviceSetupWindowController: NSWindowController {
    private let diagnostics: DiagnosticsManager
    private let scanner: (any BLEScannerProtocol)?
    private let onCandidateChanged: () -> Void
    private let statusLabel = NSTextField(labelWithString: "")
    private let trustedLabel = NSTextField(labelWithString: "")
    private let scanButton = NSButton(title: "Scan again", target: nil, action: nil)
    private let titleLabel = NSTextField(labelWithString: "Keep your Mac close to you")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "Choose your iPhone from the devices AuraSense can currently see. Signal strength is an estimate, not a distance measurement.")
    private let sectionTitle = NSTextField(labelWithString: "NEARBY BLUETOOTH DEVICES")
    private let securityLabel = NSTextField(wrappingLabelWithString: "Security note: macOS provides AuraSense a local Bluetooth identifier, not cryptographic proof that a device belongs to you. Select only your own phone. AuraSense never uses this signal to unlock your Mac.")
    private var deviceRows: [NSButton] = []
    private var rowConstraints: [NSLayoutConstraint] = []
    private var refreshTimer: Timer?

    init(diagnostics: DiagnosticsManager, scanner: (any BLEScannerProtocol)? = nil, onCandidateChanged: @escaping () -> Void) {
        self.diagnostics = diagnostics
        self.scanner = scanner
        self.onCandidateChanged = onCandidateChanged
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 470),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AuraSense — iPhone Setup"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 500, height: 470)
        super.init(window: window)
        buildInterface()
        refreshDevices()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        refreshDevices()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDevices() }
        }
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        titleLabel.font = .systemFont(ofSize: 23, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor

        let statusCard = NSView()
        statusCard.wantsLayer = true
        statusCard.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        statusCard.layer?.cornerRadius = 10
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .labelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusCard.addSubview(statusLabel)

        scanButton.bezelStyle = .rounded
        scanButton.target = self
        scanButton.action = #selector(scanAgain)
        scanButton.translatesAutoresizingMaskIntoConstraints = false

        sectionTitle.font = .systemFont(ofSize: 11, weight: .bold)
        sectionTitle.textColor = .secondaryLabelColor
        trustedLabel.font = .systemFont(ofSize: 12)
        trustedLabel.textColor = .secondaryLabelColor
        trustedLabel.maximumNumberOfLines = 2
        securityLabel.font = .systemFont(ofSize: 11)
        securityLabel.textColor = .secondaryLabelColor

        for view in [titleLabel, subtitleLabel, statusCard, scanButton, sectionTitle, trustedLabel, securityLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            statusCard.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusCard.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            statusCard.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 14),
            statusLabel.leadingAnchor.constraint(equalTo: statusCard.leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(equalTo: statusCard.trailingAnchor, constant: -14),
            statusLabel.topAnchor.constraint(equalTo: statusCard.topAnchor, constant: 12),
            statusLabel.bottomAnchor.constraint(equalTo: statusCard.bottomAnchor, constant: -12),
            scanButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            scanButton.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            scanButton.topAnchor.constraint(equalTo: statusCard.bottomAnchor, constant: 10),
            scanButton.heightAnchor.constraint(equalToConstant: 32),
            sectionTitle.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            sectionTitle.topAnchor.constraint(equalTo: scanButton.bottomAnchor, constant: 14),
            trustedLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            trustedLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            securityLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            securityLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            securityLabel.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20)
        ])
    }

    private func refreshDevices() {
        let now = Date()
        let devices = diagnostics.registry.allPeripherals()
            .filter { now.timeIntervalSince($0.lastSeen) <= 300 }
            .sorted { $0.latestRSSI > $1.latestRSSI }
        let candidate = diagnostics.trustStore.registeredCandidate
        let radioStatus: String
        if let scanner {
            switch scanner.radioState {
            case .poweredOn where scanner.isScanning: radioStatus = "Scanning"
            case .poweredOn: radioStatus = "Bluetooth ready"
            case .unauthorized: radioStatus = "Bluetooth permission needed"
            case .poweredOff: radioStatus = "Bluetooth is off"
            default: radioStatus = "Bluetooth starting"
            }
        } else {
            radioStatus = diagnostics.proximityEngine.currentState.displayLabel
        }
        statusLabel.stringValue = "\(radioStatus)   ·   \(devices.count) nearby device\(devices.count == 1 ? "" : "s")"
        trustedLabel.stringValue = candidate.map { "Selected: \($0.name) · \($0.id.uuidString.prefix(8))" } ?? "No iPhone selected yet"

        NSLayoutConstraint.deactivate(rowConstraints)
        rowConstraints.removeAll()
        deviceRows.forEach { $0.removeFromSuperview() }
        deviceRows.removeAll()

        let rows: [(DiscoveredPeripheral?, String)]
        if devices.isEmpty {
            let message = scanner?.radioState == .poweredOn
                ? "Scanning nearby devices. Keep your iPhone close; it will appear here."
                : "No devices have been seen yet. Make sure Bluetooth is on, then scan again."
            rows = [(nil, message)]
        } else {
            rows = devices.prefix(6).map { ($0, "") }
        }

        var previousBottom = sectionTitle.bottomAnchor
        for (index, entry) in rows.enumerated() {
            let row = NSButton(title: "", target: self, action: #selector(selectDevice(_:)))
            row.bezelStyle = entry.0 == nil ? .regularSquare : .rounded
            row.alignment = .left
            row.font = .systemFont(ofSize: 13, weight: .medium)
            row.translatesAutoresizingMaskIntoConstraints = false
            if let device = entry.0 {
                let identifier = device.id.uuidString
                let name = device.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Unnamed device"
                let age = max(0, Int(now.timeIntervalSince(device.lastSeen)))
                let detail = age < 5 ? "Seen now" : "Seen \(age)s ago"
                row.title = "\(name)  ·  \(device.latestRSSI) dBm  ·  \(detail)  ·  ID \(identifier.prefix(8))"
                let symbol = name.localizedCaseInsensitiveContains("iphone") ? "iphone" : "dot.radiowaves.left.and.right"
                row.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Bluetooth device")
                row.imagePosition = .imageLeading
                row.contentTintColor = .controlAccentColor
                row.identifier = NSUserInterfaceItemIdentifier(identifier)
            } else {
                row.title = entry.1
                row.isEnabled = false
                row.bezelStyle = .regularSquare
            }
            window?.contentView?.addSubview(row)
            deviceRows.append(row)
            let top = row.topAnchor.constraint(equalTo: previousBottom, constant: index == 0 ? 10 : 6)
            let height = row.heightAnchor.constraint(equalToConstant: 48)
            let leading = row.leadingAnchor.constraint(equalTo: sectionTitle.leadingAnchor)
            let trailing = row.trailingAnchor.constraint(equalTo: window!.contentView!.trailingAnchor, constant: -24)
            rowConstraints.append(contentsOf: [top, height, leading, trailing])
            previousBottom = row.bottomAnchor
        }

        rowConstraints.append(contentsOf: [
            trustedLabel.topAnchor.constraint(equalTo: previousBottom, constant: 12),
            securityLabel.topAnchor.constraint(equalTo: trustedLabel.bottomAnchor, constant: 6)
        ])
        NSLayoutConstraint.activate(rowConstraints)

        let targetHeight = 470 + CGFloat(max(0, rows.count - 2)) * 52
        if let window, let contentHeight = window.contentView?.frame.height, abs(contentHeight - targetHeight) > 20 {
            let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
            window.setContentSize(NSSize(width: window.contentView?.frame.width ?? 540, height: targetHeight))
            window.setFrameTopLeftPoint(topLeft)
        }
    }

    @objc private func selectDevice(_ sender: NSButton) {
        guard let identifier = sender.identifier,
              let id = UUID(uuidString: identifier.rawValue),
              let peripheral = diagnostics.registry.peripheral(for: id) else { return }
        let name = peripheral.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Unnamed-\(id.uuidString.prefix(8))"
        do {
            try diagnostics.registerCandidate(CandidateDevice(
                id: id,
                name: name,
                serviceUUIDs: peripheral.latestAdvertisement.serviceUUIDs
            ))
            diagnostics.log(level: .warning, category: "UI.Trust", message: "User selected BLE candidate \(name) [\(id.uuidString)]; identity is not cryptographically verified")
            NSApp.setActivationPolicy(.accessory)
            onCandidateChanged()
            refreshDevices()
        } catch {
            statusLabel.stringValue = "Could not save selection: \(error.localizedDescription)"
        }
    }

    @objc private func scanAgain() {
        guard let scanner else {
            statusLabel.stringValue = "Bluetooth scanner is unavailable."
            return
        }
        scanner.stopScanning()
        do {
            try scanner.startScanning(serviceUUIDs: nil)
            statusLabel.stringValue = "Scanning nearby Bluetooth devices…"
        } catch {
            statusLabel.stringValue = "Could not scan: \(error.localizedDescription)"
        }
        refreshDevices()
    }
}
