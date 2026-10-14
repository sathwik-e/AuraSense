import SwiftUI
import AppKit

/// Custom-vibe AuraSense Installer & First-Run Setup Assistant window.
/// Includes one-click /Applications installation, Accessibility & BLE permissions,
/// Keychain password setup, and the 10-Second Desk Signal Calibration Scanner.
public struct InstallerWindowView: View {
    @ObservedObject var engine = BLEProximityEngine.shared
    @ObservedObject var lockController = MacLockUnlockController.shared
    @Environment(\.dismiss) private var dismiss

    @AuraState private var currentStep: Int = 0
    @AuraState private var isInstallingToApplications: Bool = false
    @AuraState private var installProgress: Double = 0.0
    @AuraState private var installStatusMessage: String = ""
    @AuraState private var isInstalledInApplications: Bool = false
    @AuraState private var quickPassword: String = ""
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
                                    AuraTheme.cyanGlow.opacity(0.28 - Double(index) * 0.05),
                                    AuraTheme.indigoGlow.opacity(0.22 - Double(index) * 0.04),
                                    AuraTheme.emeraldGlow.opacity(0.14)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                        .frame(
                            width: CGFloat(220 + index * 130),
                            height: CGFloat(220 + index * 130)
                        )
                        .scaleEffect(ringPulse ? 1.04 : 0.96)
                        .animation(
                            .easeInOut(duration: 2.8 + Double(index) * 0.4).repeatForever(autoreverses: true),
                            value: ringPulse
                        )
                }
            }
            .offset(y: -40)

            VStack(spacing: 20) {
                heroHeader
                stepIndicatorPills

                Group {
                    switch currentStep {
                    case 0:
                        installToApplicationsStepCard
                    case 1:
                        permissionsStepCard
                    default:
                        keychainAndTenSecondDeskCalibrationStepCard
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                footerNavigationBar
            }
            .padding(26)
        }
        .frame(width: 700, height: 560)
        .preferredColorScheme(.dark)
        .onAppear {
            ringPulse = true
            checkApplicationsFolderStatus()
            if let existing = KeychainManager.shared.retrievePassword() {
                quickPassword = existing
                savedPasswordSuccess = !existing.isEmpty
            }
        }
    }

    // MARK: - Hero Header

    private var heroHeader: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [AuraTheme.cyanGlow.opacity(0.45), AuraTheme.indigoGlow.opacity(0.20), .clear],
                            center: .center,
                            startRadius: 4,
                            endRadius: 36
                        )
                    )
                    .frame(width: 64, height: 64)

                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AuraTheme.auraLinearGradient)
                    .frame(width: 52, height: 52)
                    .shadow(color: AuraTheme.cyanGlow.opacity(0.45), radius: 12)

                Image(systemName: "lock.open.rotation")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("AuraSense Setup & 10s Desk Calibration")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    AuraStatusPill(
                        title: "v1.2 Menu Bar",
                        symbol: "menubar.rectangle",
                        color: AuraTheme.cyanGlow
                    )
                }
                Text("Lives quietly in your Menu Bar • Wakes external monitors • Auto-calibrates desk RSSI in 10 seconds")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.72))
            }
            Spacer()
        }
    }

    // MARK: - Step Indicator Pills

    private var stepIndicatorPills: some View {
        HStack(spacing: 12) {
            stepBadge(index: 0, title: "1. Install App Bundle", icon: "square.and.arrow.down.on.square.fill")
            stepBadge(index: 1, title: "2. Accessibility & Monitor", icon: "hand.raised.shield.fill")
            stepBadge(index: 2, title: "3. 10s Desk Calibration", icon: "scope")
        }
    }

    private func stepBadge(index: Int, title: String, icon: String) -> some View {
        let isActive = (currentStep == index)
        let isCompleted = (currentStep > index)
        let tint: Color = isCompleted ? AuraTheme.emeraldGlow : (isActive ? AuraTheme.cyanGlow : .white.opacity(0.45))

        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                currentStep = index
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isCompleted ? "checkmark.circle.fill" : icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isActive ? tint.opacity(0.16) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isActive ? tint.opacity(0.6) : Color.white.opacity(0.10), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 0: Install to Applications

    private var installToApplicationsStepCard: some View {
        AuraGlassCard(padding: 22, borderColor: AuraTheme.cyanGlow.opacity(0.35)) {
            VStack(spacing: 18) {
                HStack(spacing: 28) {
                    VStack(spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(AuraTheme.auraLinearGradient)
                                .frame(width: 72, height: 72)
                                .shadow(color: AuraTheme.cyanGlow.opacity(0.4), radius: 14)
                            Image(systemName: "sensor.tag.radiowaves.forward.fill")
                                .font(.system(size: 30, weight: .bold))
                                .foregroundStyle(.white)
                        }
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
                        Text(isInstalledInApplications ? "Installed in /Applications" : "One-Click or Drag in DMG")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(Color.blue.opacity(0.22))
                                .frame(width: 72, height: 72)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .strokeBorder(Color.blue.opacity(0.55), lineWidth: 1.5)
                                )
                            Image(systemName: "folder.fill.badge.gearshape")
                                .font(.system(size: 30, weight: .semibold))
                                .foregroundStyle(Color(red: 0.35, green: 0.68, blue: 1.0))
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
                    Text("When you close the AuraSense window, its Dock icon automatically disappears so it lives quietly in your macOS Menu Bar.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 500)
                }

                HStack(spacing: 14) {
                    Button {
                        performCopyToApplications()
                    } label: {
                        Label(
                            isInstalledInApplications ? "Reinstall to /Applications" : "Install to /Applications Now",
                            systemImage: isInstalledInApplications ? "checkmark.circle.fill" : "arrow.down.app.fill"
                        )
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isInstalledInApplications ? AuraTheme.emeraldGlow : AuraTheme.indigoGlow)
                    .disabled(isInstallingToApplications)

                    Button {
                        NSWorkspace.shared.selectFile("/Applications/AuraSense.app", inFileViewerRootedAtPath: "/Applications")
                    } label: {
                        Label("Reveal /Applications", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Step 1: Accessibility & External Monitor Wake

    private var permissionsStepCard: some View {
        AuraGlassCard(padding: 20, borderColor: AuraTheme.indigoGlow.opacity(0.35)) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Grant Accessibility & External Monitor Wake Permissions")
                    .font(.system(size: 16, weight: .bold, design: .rounded))

                HStack(spacing: 14) {
                    Image(systemName: lockController.isAccessibilityTrusted ? "checkmark.shield.fill" : "lock.shield.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(lockController.isAccessibilityTrusted ? AuraTheme.emeraldGlow : AuraTheme.amberGlow)
                        .frame(width: 38)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("Accessibility Permission (Auto-Unlock & ⌃⌥⌘Space Instant Fill)")
                                .font(.system(size: 13.5, weight: .semibold))
                            AuraStatusPill(
                                title: lockController.isAccessibilityTrusted ? "Trusted" : "Not Granted Yet",
                                symbol: lockController.isAccessibilityTrusted ? "checkmark" : "hand.raised.fill",
                                color: lockController.isAccessibilityTrusted ? AuraTheme.emeraldGlow : .orange
                            )
                        }
                        Text("Enables lock screen password typing, external monitor input wake pulses, and global ⌃⌥⌘Space instant fill.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(lockController.isAccessibilityTrusted ? "Verified" : "Grant Permission…") {
                        lockController.openAccessibilitySettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(lockController.isAccessibilityTrusted ? AuraTheme.emeraldGlow : AuraTheme.indigoGlow)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))

                HStack(spacing: 14) {
                    Image(systemName: "display.2")
                        .font(.system(size: 24))
                        .foregroundStyle(AuraTheme.cyanGlow)
                        .frame(width: 38)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("External Monitor DisplayPort / HDMI Input Wake")
                                .font(.system(size: 13.5, weight: .semibold))
                            AuraStatusPill(
                                title: lockController.hasExternalMonitorConnected
                                    ? "External Monitor Detected (\(lockController.connectedDisplayCount))"
                                    : "Ready for External Monitor",
                                symbol: "bolt.horizontal.fill",
                                color: AuraTheme.cyanGlow
                            )
                        }
                        Text("Sends active IODisplayWrangler, caffeinate, and framebuffer wake signals so external monitors wake and switch input automatically.")
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

    // MARK: - Step 2: Keychain & 10-Second Desk Signal Calibration

    private var keychainAndTenSecondDeskCalibrationStepCard: some View {
        AuraGlassCard(padding: 20, borderColor: AuraTheme.emeraldGlow.opacity(0.35)) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Save Password & Run 10-Second Desk Signal Calibration")
                    .font(.system(size: 16, weight: .bold, design: .rounded))

                // Keychain Input Row
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("macOS Login Password (Encrypted in Keychain)", systemImage: "key.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                        Spacer()
                        if savedPasswordSuccess {
                            AuraStatusPill(title: "Saved in Keychain", symbol: "checkmark.circle.fill", color: AuraTheme.emeraldGlow)
                        }
                    }

                    HStack(spacing: 10) {
                        SecureField("Enter your Mac login password for auto-unlock…", text: $quickPassword)
                            .textFieldStyle(.roundedBorder)

                        Button("Save to Keychain") {
                            try? KeychainManager.shared.savePassword(quickPassword)
                            savedPasswordSuccess = KeychainManager.shared.hasStoredPassword()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AuraTheme.emeraldGlow)
                        .disabled(quickPassword.isEmpty)
                    }
                }

                Divider()

                // 10-Second Desk Signal Calibration Box
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("10-Second Desk Signal Calibration & Auto-Optimizer", systemImage: "scope")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(AuraTheme.cyanGlow)
                        Spacer()
                        if engine.hasNotedDeskRSSI {
                            AuraStatusPill(
                                title: "Noted Desk Signal: \(engine.notedDeskRSSI) dBm (±\(String(format: "%.1f", engine.notedDeskJitterDB)) dB)",
                                symbol: "checkmark.seal.fill",
                                color: AuraTheme.emeraldGlow
                            )
                        }
                    }

                    Text(engine.deskCalibrationSummary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    if engine.isCalibratingDeskSignal {
                        ProgressView(value: engine.deskCalibrationProgress, total: 1.0)
                            .tint(AuraTheme.cyanGlow)
                        HStack {
                            Text("Keep your device on the desk… (\(engine.deskCalibrationSamplesCollected) samples)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(AuraTheme.cyanGlow)
                            Spacer()
                            Text("\(engine.deskCalibrationRemainingSeconds)s left")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                    } else {
                        HStack(spacing: 12) {
                            Button {
                                engine.startTenSecondDeskCalibration()
                            } label: {
                                Label("Place Device on Desk & Scan for 10s", systemImage: "waveform.badge.magnifyingglass")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(AuraTheme.cyanGlow)

                            if let strongest = engine.discoveredDevices.first, engine.selectedDeviceID.isEmpty {
                                Button("Bind \(strongest.name)") {
                                    engine.bindDevice(strongest)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
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
                engine.hasCompletedOnboarding = true
                onComplete?()
                dismiss()
                DockVisibilityManager.shared.evaluateDockPolicy()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.trailing, 8)

            if currentStep < 2 {
                Button {
                    withAnimation { currentStep += 1 }
                } label: {
                    Label("Continue", systemImage: "arrow.right")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(AuraTheme.cyanGlow)
            } else {
                Button {
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

    private func checkApplicationsFolderStatus() {
        let destPath = "/Applications/AuraSense.app"
        isInstalledInApplications = FileManager.default.fileExists(atPath: destPath)
    }

    private func performCopyToApplications() {
        let bundlePath = Bundle.main.bundlePath
        let destPath = "/Applications/AuraSense.app"

        isInstallingToApplications = true
        installProgress = 0.25
        installStatusMessage = "Preparing AuraSense.app bundle…"

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            installProgress = 0.65
            installStatusMessage = "Installing to /Applications/AuraSense.app…"

            do {
                let fm = FileManager.default
                if bundlePath.hasSuffix(".app") && bundlePath != destPath {
                    if fm.fileExists(atPath: destPath) {
                        try fm.removeItem(atPath: destPath)
                    }
                    try fm.copyItem(atPath: bundlePath, toPath: destPath)
                }
                installProgress = 1.0
                installStatusMessage = "Successfully installed AuraSense to /Applications!"
                isInstalledInApplications = true
                engine.appendLog(
                    kind: .systemState,
                    title: "Installed AuraSense to /Applications",
                    detail: "Bundle copied to /Applications/AuraSense.app."
                )
            } catch {
                installProgress = 1.0
                installStatusMessage = "Ready! You can also drag AuraSense.app to Applications in Finder."
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                isInstallingToApplications = false
            }
        }
    }
}
