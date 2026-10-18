import SwiftUI
import AppKit
import CoreBluetooth

/// Comprehensive 4-Step Guided Setup & Permissions Assistant for AuraSense v1.0.
/// Automatically installs AuraSense.app to `/Applications`, prompts for Accessibility and Bluetooth
/// permissions, guides the user through selecting their Bluetooth device and running the 10-second
/// desk calibration scan, and saves their Mac login password in the Keychain.
public struct InstallerWindowView: View {
    @ObservedObject var engine = BLEProximityEngine.shared
    @ObservedObject var lockController = MacLockUnlockController.shared
    @ObservedObject var bridge = FaceIdKeychainBridgeService.shared
    @Environment(\.dismiss) private var dismiss

    @AuraState private var currentStep: Int = 0
    @AuraState private var isInstallingToApplications: Bool = false
    @AuraState private var installProgress: Double = 0.0
    @AuraState private var installStatusMessage: String = ""
    @AuraState private var isInstalledInApplications: Bool = false
    @AuraState private var quickPassword: String = ""
    @AuraState private var showPasswordPlain: Bool = false
    @AuraState private var savedPasswordSuccess: Bool = KeychainManager.shared.hasStoredPassword()
    @AuraState private var ringPulse: Bool = false

    public var onComplete: (() -> Void)?

    public init(onComplete: (() -> Void)? = nil) {
        self.onComplete = onComplete
    }

    public var body: some View {
        ZStack {
            AuraTheme.deepMidnight
                .ignoresSafeArea()

            ZStack {
                ForEach(0..<4, id: \.self) { index in
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    AuraTheme.cyanGlow.opacity(0.22 - Double(index) * 0.04),
                                    AuraTheme.indigoGlow.opacity(0.18 - Double(index) * 0.03)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.3
                        )
                        .frame(
                            width: CGFloat(240 + index * 135),
                            height: CGFloat(240 + index * 135)
                        )
                        .scaleEffect(ringPulse ? 1.03 : 0.97)
                        .animation(
                            .easeInOut(duration: 2.8 + Double(index) * 0.4).repeatForever(autoreverses: true),
                            value: ringPulse
                        )
                }
            }
            .offset(y: -40)

            VStack(spacing: 18) {
                heroHeader
                stepIndicatorPills

                Group {
                    switch currentStep {
                    case 0:
                        installToApplicationsStepCard
                    case 1:
                        permissionsStepCard
                    case 2:
                        deviceAndTenSecondCalibrationStepCard
                    default:
                        passwordAndAutoFillStepCard
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                footerNavigationBar
            }
            .padding(24)
        }
        .frame(width: 760, height: 590)
        .preferredColorScheme(.dark)
        .onAppear {
            ringPulse = true
            isInstalledInApplications = lockController.isInstalledInApplications
            if !isInstalledInApplications || !lockController.isRunningFromApplications {
                performCopyToApplications()
            }
            if let existing = KeychainManager.shared.retrievePassword(), !existing.isEmpty {
                quickPassword = existing
                savedPasswordSuccess = true
            }
            engine.startScanning()
        }
        .onChange(of: currentStep) { _, newStep in
            if newStep == 1 {
                if !lockController.refreshAccessibilityStatus(prompt: false) {
                    lockController.promptForAccessibilityPermission(resetStaleEntryIfNeeded: true, openSettingsPane: true)
                }
                engine.promptForBluetoothPermission()
            } else if newStep == 2 {
                engine.startScanning()
            }
        }
    }

    // MARK: - Hero Header

    private var heroHeader: some View {
        HStack(spacing: 16) {
            AuraEclipseLogoView(size: 54)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    AuraBrandWordmarkView(size: 19, tracking: 3.4)
                    AuraStatusPill(
                        title: "v1.0 Guided Setup",
                        symbol: "checkmark.shield.fill",
                        color: AuraTheme.cyanGlow
                    )
                }
                Text("Step-by-step installation, permissions, 10s desk signal calibration, and password setup")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.74))
            }
            Spacer()
        }
    }

    // MARK: - 4-Step Indicator Pills

    private var stepIndicatorPills: some View {
        HStack(spacing: 10) {
            stepBadge(
                index: 0,
                title: "1. Install App",
                icon: "square.and.arrow.down.on.square.fill",
                done: isInstalledInApplications
            )
            stepBadge(
                index: 1,
                title: "2. Permissions",
                icon: "hand.raised.shield.fill",
                done: lockController.isAccessibilityTrusted && engine.bluetoothState == .poweredOn
            )
            stepBadge(
                index: 2,
                title: "3. Device & 10s Scan",
                icon: "scope",
                done: !engine.selectedDeviceID.isEmpty && engine.hasNotedDeskRSSI
            )
            stepBadge(
                index: 3,
                title: "4. Password & iPhone",
                icon: "key.fill",
                done: savedPasswordSuccess
            )
        }
    }

    private func stepBadge(index: Int, title: String, icon: String, done: Bool) -> some View {
        let isActive = (currentStep == index)
        let tint: Color = done ? AuraTheme.emeraldGlow : (isActive ? AuraTheme.cyanGlow : .white.opacity(0.50))

        return Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                currentStep = index
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: done ? "checkmark.circle.fill" : icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isActive ? tint.opacity(0.18) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isActive ? tint.opacity(0.65) : Color.white.opacity(0.10), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 0: Install to /Applications

    private var installToApplicationsStepCard: some View {
        AuraGlassCard(padding: 22, borderColor: AuraTheme.cyanGlow.opacity(0.35)) {
            VStack(spacing: 18) {
                HStack(spacing: 28) {
                    VStack(spacing: 8) {
                        AuraEclipseLogoView(size: 70)
                        Text("AuraSense.app")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                    }

                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            ForEach(0..<5, id: \.self) { i in
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(AuraTheme.cyanGlow.opacity(0.35 + Double(i) * 0.15))
                            }
                        }
                        Text(isInstalledInApplications ? "Installed in /Applications" : "Installing to /Applications")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(isInstalledInApplications ? AuraTheme.emeraldGlow : .secondary)
                    }

                    VStack(spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(Color.blue.opacity(0.18))
                                .frame(width: 70, height: 70)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .strokeBorder(AuraTheme.cyanGlow.opacity(0.55), lineWidth: 1.5)
                                )
                            Image(systemName: "folder.fill")
                                .font(.system(size: 30, weight: .semibold))
                                .foregroundStyle(AuraTheme.cyanGlow)
                        }
                        Text("/Applications")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                    }
                }

                if isInstallingToApplications {
                    VStack(spacing: 8) {
                        ProgressView(value: installProgress, total: 1.0)
                            .tint(AuraTheme.cyanGlow)
                            .frame(maxWidth: 360)
                        Text(installStatusMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    VStack(spacing: 6) {
                        AuraStatusPill(
                            title: isInstalledInApplications
                                ? "AuraSense.app is installed in /Applications"
                                : "Click Install below to copy AuraSense.app to /Applications",
                            symbol: isInstalledInApplications ? "checkmark.circle.fill" : "arrow.down.app.fill",
                            color: isInstalledInApplications ? AuraTheme.emeraldGlow : AuraTheme.amberGlow
                        )
                        Text("Once setup is complete, closing the window removes AuraSense from the Dock so it lives quietly in your macOS Menu Bar.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 520)
                    }
                }

                HStack(spacing: 14) {
                    Button {
                        performCopyToApplications()
                    } label: {
                        Label(
                            isInstalledInApplications ? "Reinstall / Update in /Applications" : "Install to /Applications Now",
                            systemImage: isInstalledInApplications ? "arrow.clockwise.circle.fill" : "arrow.down.app.fill"
                        )
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isInstalledInApplications ? AuraTheme.emeraldGlow : AuraTheme.indigoGlow)
                    .disabled(isInstallingToApplications)

                    Button {
                        if FileManager.default.fileExists(atPath: "/Applications/AuraSense.app") {
                            NSWorkspace.shared.selectFile("/Applications/AuraSense.app", inFileViewerRootedAtPath: "/Applications")
                        } else {
                            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
                        }
                    } label: {
                        Label("Show in /Applications", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Step 1: Required Permissions (Accessibility & Bluetooth)

    private var permissionsStepCard: some View {
        AuraGlassCard(padding: 20, borderColor: AuraTheme.indigoGlow.opacity(0.35)) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Step 2: Grant Required macOS Permissions")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                        Text("AuraSense needs Accessibility to enter your password on unlock and Bluetooth to measure your device signal.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                // 1. Accessibility Permission Row
                HStack(spacing: 14) {
                    Image(systemName: lockController.isAccessibilityTrusted ? "checkmark.shield.fill" : "hand.raised.shield.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(lockController.isAccessibilityTrusted ? AuraTheme.emeraldGlow : AuraTheme.amberGlow)
                        .frame(width: 36)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text("1. Accessibility Permission (Required)")
                                .font(.system(size: 13.5, weight: .semibold))
                            AuraStatusPill(
                                title: lockController.isAccessibilityTrusted ? "Granted" : "Action Required",
                                symbol: lockController.isAccessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                color: lockController.isAccessibilityTrusted ? AuraTheme.emeraldGlow : AuraTheme.amberGlow
                            )
                        }
                        Text("Click 'Prompt Permission' below, then enable the toggle next to AuraSense in System Settings > Privacy & Security > Accessibility.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 6) {
                        Button {
                            lockController.promptForAccessibilityPermission(resetStaleEntryIfNeeded: true, openSettingsPane: true)
                        } label: {
                            Label(
                                lockController.isAccessibilityTrusted ? "Granted (Re-Verify)" : "Prompt Permission…",
                                systemImage: "hand.raised.fill"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(lockController.isAccessibilityTrusted ? AuraTheme.emeraldGlow : AuraTheme.indigoGlow)
                        .controlSize(.small)

                        if !lockController.isAccessibilityTrusted {
                            Button("Check Status") {
                                _ = lockController.refreshAccessibilityStatus(prompt: true)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))

                // 2. Bluetooth Permission Row
                let btReady = (engine.bluetoothState == .poweredOn)
                HStack(spacing: 14) {
                    Image(systemName: btReady ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 24))
                        .foregroundStyle(btReady ? AuraTheme.emeraldGlow : AuraTheme.amberGlow)
                        .frame(width: 36)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text("2. Bluetooth Permission (Required)")
                                .font(.system(size: 13.5, weight: .semibold))
                            AuraStatusPill(
                                title: btReady ? "Powered On & Scanning" : engine.bluetoothStateDescription,
                                symbol: btReady ? "checkmark.circle.fill" : "bolt.horizontal.fill",
                                color: btReady ? AuraTheme.emeraldGlow : AuraTheme.amberGlow
                            )
                        }
                        Text("Allows AuraSense to scan nearby BLE devices and measure real-time RSSI distance.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(btReady ? "Scanning Active" : "Prompt Bluetooth…") {
                        lockController.openBluetoothSettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(btReady ? AuraTheme.emeraldGlow : AuraTheme.cyanGlow)
                    .controlSize(.small)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))

                // 3. External Monitor Input Wake Row
                HStack(spacing: 14) {
                    Image(systemName: "display.2")
                        .font(.system(size: 22))
                        .foregroundStyle(AuraTheme.cyanGlow)
                        .frame(width: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("3. External Monitor Display Input Wake")
                            .font(.system(size: 13.5, weight: .semibold))
                        Text("Automatically wakes DisplayPort, HDMI, and USB-C monitors before entering your password.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Toggle("", isOn: $lockController.sendMonitorInputSignal)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Step 2: Select BLE Device & 10-Second Desk Calibration

    private var deviceAndTenSecondCalibrationStepCard: some View {
        AuraGlassCard(padding: 18, borderColor: AuraTheme.cyanGlow.opacity(0.35)) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Step 3: Select Your Bluetooth Device & Run 10s Desk Scan")
                            .font(.system(size: 15.5, weight: .bold, design: .rounded))
                        Text("Pick your iPhone, Apple Watch, or BLE device below, place it on your desk, and run the 10-second scan.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !engine.selectedDeviceName.isEmpty {
                        AuraStatusPill(
                            title: "Bound: \(engine.selectedDeviceName)",
                            symbol: "checkmark.circle.fill",
                            color: AuraTheme.emeraldGlow
                        )
                    }
                }

                // Live Discovered Devices Picker List
                ScrollView {
                    VStack(spacing: 6) {
                        if engine.discoveredDevices.isEmpty {
                            HStack(spacing: 10) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Scanning for nearby Bluetooth devices… Make sure Bluetooth is on or click 'Use Simulated iPhone' to test.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Use Simulated iPhone") {
                                    engine.isSimulationMode = true
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(10)
                        } else {
                            ForEach(engine.discoveredDevices.prefix(6)) { dev in
                                let isBound = (dev.id.uuidString == engine.selectedDeviceID)
                                HStack(spacing: 10) {
                                    Image(systemName: dev.category.symbolName)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(isBound ? AuraTheme.emeraldGlow : AuraTheme.cyanGlow)
                                        .frame(width: 24)

                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(dev.name)
                                            .font(.system(size: 12.5, weight: .semibold))
                                            .lineLimit(1)
                                        Text("\(Int(dev.smoothedRSSI.rounded())) dBm • \(dev.formattedDistance)")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    SignalBarsView(bars: dev.signalQualityBars, tint: isBound ? AuraTheme.emeraldGlow : AuraTheme.cyanGlow)

                                    Button(isBound ? "Selected" : "Select") {
                                        engine.bindDevice(dev)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(isBound ? AuraTheme.emeraldGlow : AuraTheme.indigoGlow)
                                    .controlSize(.small)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(isBound ? AuraTheme.emeraldGlow.opacity(0.12) : Color.white.opacity(0.04))
                                )
                            }
                        }
                    }
                }
                .frame(height: 150)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.22)))

                // 10-Second Desk Signal Calibration Box
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("10-Second Desk Signal Calibration", systemImage: "scope")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(AuraTheme.cyanGlow)
                        Spacer()
                        if engine.hasNotedDeskRSSI {
                            AuraStatusPill(
                                title: "Calibrated: \(engine.notedDeskRSSI) dBm (Unlock ≥ \(Int(engine.unlockThresholdRSSI)) dBm / Lock ≤ \(Int(engine.lockThresholdRSSI)) dBm)",
                                symbol: "checkmark.seal.fill",
                                color: AuraTheme.emeraldGlow
                            )
                        }
                    }

                    if engine.isCalibratingDeskSignal {
                        ProgressView(value: engine.deskCalibrationProgress, total: 1.0)
                            .tint(AuraTheme.cyanGlow)
                        HStack {
                            Text("Sampling desk signal strength… Keep your device on your desk (\(engine.deskCalibrationSamplesCollected) samples)")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(AuraTheme.cyanGlow)
                            Spacer()
                            Text("\(engine.deskCalibrationRemainingSeconds)s remaining")
                                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        }
                    } else {
                        HStack {
                            Text(engine.deskCalibrationSummary)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                engine.startTenSecondDeskCalibration()
                            } label: {
                                Label(
                                    engine.hasNotedDeskRSSI ? "Re-Scan Desk Signal (10s)" : "Start 10s Desk Signal Scan",
                                    systemImage: "waveform.badge.magnifyingglass"
                                )
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(AuraTheme.cyanGlow)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Step 3: Save Mac Password & iPhone Instant Auto-Fill

    private var passwordAndAutoFillStepCard: some View {
        AuraGlassCard(padding: 20, borderColor: AuraTheme.emeraldGlow.opacity(0.35)) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Step 4: Save Mac Login Password & iPhone Instant Auto-Fill")
                    .font(.system(size: 16, weight: .bold, design: .rounded))

                // 1. Keychain Password Box
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Mac Login Password (Encrypted in macOS Keychain)", systemImage: "key.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        AuraStatusPill(
                            title: savedPasswordSuccess ? "Saved in Keychain" : "Required for Auto-Unlock",
                            symbol: savedPasswordSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                            color: savedPasswordSuccess ? AuraTheme.emeraldGlow : AuraTheme.amberGlow
                        )
                    }

                    HStack(spacing: 10) {
                        Group {
                            if showPasswordPlain {
                                TextField("Enter your Mac login password…", text: $quickPassword)
                            } else {
                                SecureField("Enter your Mac login password…", text: $quickPassword)
                            }
                        }
                        .textFieldStyle(.roundedBorder)

                        Button {
                            showPasswordPlain.toggle()
                        } label: {
                            Image(systemName: showPasswordPlain ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            try? KeychainManager.shared.savePassword(quickPassword)
                            savedPasswordSuccess = KeychainManager.shared.hasStoredPassword()
                        } label: {
                            Label("Save Password", systemImage: "checkmark.shield.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AuraTheme.emeraldGlow)
                        .disabled(quickPassword.isEmpty)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))

                // 2. Simple iPhone Instant Browser Auto-Fill Box
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Instant iPhone Browser Auto-Fill URL", systemImage: "iphone.radiowaves.left.and.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(AuraTheme.cyanGlow)
                        Spacer()
                        Button("Copy URL") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(bridge.shortcutWebhookURL, forType: .string)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("Open in Browser") {
                            if let url = URL(string: bridge.shortcutWebhookURL) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AuraTheme.indigoGlow)
                        .controlSize(.small)
                    }

                    Text(bridge.shortcutWebhookURL)
                        .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(AuraTheme.emeraldGlow)
                        .textSelection(.enabled)

                    Text("1. Open this URL in Safari on your iPhone — your Mac password auto-fills as soon as the page opens.\n2. Tap Share > Add to Home Screen in Safari for one-tap access anytime.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Footer Navigation Bar

    private var footerNavigationBar: some View {
        HStack {
            if currentStep > 0 {
                Button("Back") {
                    withAnimation { currentStep -= 1 }
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            Button("Finish & Live in Menu Bar") {
                if !quickPassword.isEmpty {
                    try? KeychainManager.shared.savePassword(quickPassword)
                }
                engine.hasCompletedOnboarding = true
                onComplete?()
                dismiss()
                DockVisibilityManager.shared.evaluateDockPolicy()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.trailing, 8)

            if currentStep < 3 {
                Button {
                    withAnimation { currentStep += 1 }
                } label: {
                    Label("Next Step", systemImage: "arrow.right")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(AuraTheme.cyanGlow)
            } else {
                Button {
                    if !quickPassword.isEmpty {
                        try? KeychainManager.shared.savePassword(quickPassword)
                    }
                    engine.hasCompletedOnboarding = true
                    onComplete?()
                    dismiss()
                } label: {
                    Label("Complete Setup", systemImage: "checkmark.seal.fill")
                        .padding(.horizontal, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(AuraTheme.emeraldGlow)
            }
        }
    }

    // MARK: - Installation Helper

    private func performCopyToApplications() {
        isInstallingToApplications = true
        installProgress = 0.35
        installStatusMessage = "Installing AuraSense.app to /Applications…"

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let (ok, message) = lockController.installToApplicationsFolder()
            installProgress = 1.0
            installStatusMessage = message
            isInstalledInApplications = ok || lockController.isInstalledInApplications
            if isInstalledInApplications {
                engine.appendLog(
                    kind: .systemState,
                    title: "Installed AuraSense.app in /Applications",
                    detail: message
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                isInstallingToApplications = false
            }
        }
    }
}
