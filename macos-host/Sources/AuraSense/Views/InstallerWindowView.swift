import SwiftUI
import AppKit

/// AuraSense v1.0 Setup Assistant window featuring the Neon Orbit Eclipse logo,
/// Λ U R Λ S E N S E typography, and simple 3-step setup instructions.
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
                                    AuraTheme.cyanGlow.opacity(0.24 - Double(index) * 0.05),
                                    AuraTheme.indigoGlow.opacity(0.20 - Double(index) * 0.04)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.4
                        )
                        .frame(
                            width: CGFloat(220 + index * 130),
                            height: CGFloat(220 + index * 130)
                        )
                        .scaleEffect(ringPulse ? 1.03 : 0.97)
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
        .frame(width: 700, height: 550)
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
            AuraEclipseLogoView(size: 56)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    AuraBrandWordmarkView(size: 20, tracking: 3.6)
                    AuraStatusPill(
                        title: "v1.0",
                        symbol: "moon.circle.fill",
                        color: AuraTheme.cyanGlow
                    )
                }
                Text("Menu Bar BLE Proximity Lock, External Monitor Wake & Instant Password Fill")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.74))
            }
            Spacer()
        }
    }

    // MARK: - Step Indicator Pills

    private var stepIndicatorPills: some View {
        HStack(spacing: 12) {
            stepBadge(index: 0, title: "1. Install App", icon: "square.and.arrow.down.on.square.fill")
            stepBadge(index: 1, title: "2. Grant Accessibility", icon: "hand.raised.shield.fill")
            stepBadge(index: 2, title: "3. Password & 10s Scan", icon: "scope")
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
                        AuraEclipseLogoView(size: 72)
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
                        Text(isInstalledInApplications ? "Installed in /Applications" : "Copy to /Applications")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(Color.blue.opacity(0.18))
                                .frame(width: 72, height: 72)
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
                    Text("Click Install below or drag AuraSense.app into Applications. Closing the window hides the Dock icon so AuraSense stays in your Menu Bar.")
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
                            isInstalledInApplications ? "Reinstall to /Applications" : "Install to /Applications",
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
                        Label("Open /Applications", systemImage: "folder")
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
                Text("Step 2: Enable Accessibility & Monitor Wake")
                    .font(.system(size: 16, weight: .bold, design: .rounded))

                HStack(spacing: 14) {
                    Image(systemName: lockController.isAccessibilityTrusted ? "checkmark.shield.fill" : "lock.shield.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(lockController.isAccessibilityTrusted ? AuraTheme.emeraldGlow : AuraTheme.amberGlow)
                        .frame(width: 38)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("Accessibility Permission")
                                .font(.system(size: 13.5, weight: .semibold))
                            AuraStatusPill(
                                title: lockController.isAccessibilityTrusted ? "Granted" : "Required",
                                symbol: lockController.isAccessibilityTrusted ? "checkmark" : "hand.raised.fill",
                                color: lockController.isAccessibilityTrusted ? AuraTheme.emeraldGlow : .orange
                            )
                        }
                        Text("Allows AuraSense to enter your Mac password on unlock and fill Keychain prompts.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(lockController.isAccessibilityTrusted ? "Granted" : "Open Settings…") {
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
                        Text("Wake External Monitor Input on Unlock")
                            .font(.system(size: 13.5, weight: .semibold))
                        Text("Automatically wakes DisplayPort, HDMI, and USB-C monitors before typing your password.")
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
                Text("Step 3: Save Password & Calibrate Desk Signal (10s)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Mac Login Password (Encrypted in Keychain)", systemImage: "key.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                        Spacer()
                        if savedPasswordSuccess {
                            AuraStatusPill(title: "Saved", symbol: "checkmark.circle.fill", color: AuraTheme.emeraldGlow)
                        }
                    }

                    HStack(spacing: 10) {
                        SecureField("Enter your Mac login password…", text: $quickPassword)
                            .textFieldStyle(.roundedBorder)

                        Button("Save Password") {
                            try? KeychainManager.shared.savePassword(quickPassword)
                            savedPasswordSuccess = KeychainManager.shared.hasStoredPassword()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AuraTheme.emeraldGlow)
                        .disabled(quickPassword.isEmpty)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("10-Second Desk Signal Calibration", systemImage: "scope")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(AuraTheme.cyanGlow)
                        Spacer()
                        if engine.hasNotedDeskRSSI {
                            AuraStatusPill(
                                title: "Desk RSSI: \(engine.notedDeskRSSI) dBm",
                                symbol: "checkmark.seal.fill",
                                color: AuraTheme.emeraldGlow
                            )
                        }
                    }

                    Text("Place your iPhone or Watch on your desk and click Scan to automatically set your unlock and lock range.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)

                    if engine.isCalibratingDeskSignal {
                        ProgressView(value: engine.deskCalibrationProgress, total: 1.0)
                            .tint(AuraTheme.cyanGlow)
                        HStack {
                            Text("Sampling desk signal… (\(engine.deskCalibrationSamplesCollected) samples)")
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
                                Label("Scan Desk Signal (10s)", systemImage: "waveform.badge.magnifyingglass")
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
                    Label("Next", systemImage: "arrow.right")
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
                    Label("Done", systemImage: "checkmark.seal.fill")
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
        installStatusMessage = "Preparing AuraSense.app…"

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            installProgress = 0.65
            installStatusMessage = "Copying to /Applications/AuraSense.app…"

            do {
                let fm = FileManager.default
                if bundlePath.hasSuffix(".app") && bundlePath != destPath {
                    if fm.fileExists(atPath: destPath) {
                        try fm.removeItem(atPath: destPath)
                    }
                    try fm.copyItem(atPath: bundlePath, toPath: destPath)
                }
                installProgress = 1.0
                installStatusMessage = "Installed AuraSense to /Applications."
                isInstalledInApplications = true
                engine.appendLog(
                    kind: .systemState,
                    title: "Installed AuraSense to /Applications",
                    detail: "Bundle copied to /Applications/AuraSense.app."
                )
            } catch {
                installProgress = 1.0
                installStatusMessage = "Drag AuraSense.app to Applications in Finder."
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                isInstallingToApplications = false
            }
        }
    }
}
