import SwiftUI
import AppKit
import CoreBluetooth

/// Four-step Guided Setup for AuraSense.
/// Runs inside the real app (`com.aurasense.mac.app`) so device binding, calibration, TCC grants and
/// the Keychain item all belong to /Applications/AuraSense.app.
///
/// It is shown two ways: embedded in the dashboard window (with `onComplete`, which swaps the
/// dashboard back in) and in its own "Guided Setup" window (no `onComplete`; finishing closes it).
public struct InstallerWindowView: View {
    @ObservedObject var engine = BLEProximityEngine.shared
    @ObservedObject var lockController = MacLockUnlockController.shared
    @ObservedObject var bridge = FaceIdKeychainBridgeService.shared
    @Environment(\.dismiss) private var dismiss

    @AuraState private var currentStep: Int = 0
    @AuraState private var hasChosenInitialStep: Bool = false
    @AuraState private var isInstallingToApplications: Bool = false
    @AuraState private var installStatusMessage: String = ""
    @AuraState private var installFailed: Bool = false
    @AuraState private var isInstalledInApplications: Bool = false
    @AuraState private var quickPassword: String = ""
    @AuraState private var showPasswordPlain: Bool = false
    @AuraState private var savedPasswordSuccess: Bool = KeychainManager.shared.hasStoredPassword()
    @AuraState private var passwordSaveError: String = ""
    @AuraState private var didCopyPairingURL: Bool = false

    public var onComplete: (() -> Void)?

    private static let lastStepIndex = 3

    public init(onComplete: (() -> Void)? = nil) {
        self.onComplete = onComplete
    }

    private var permissionsReady: Bool {
        lockController.isAccessibilityTrusted && engine.bluetoothState == .poweredOn
    }

    private var deviceReady: Bool {
        !engine.selectedDeviceID.isEmpty && engine.hasNotedDeskRSSI
    }

    public var body: some View {
        ZStack {
            AuraTheme.deepMidnight
                .ignoresSafeArea()

            backgroundRings

            VStack(spacing: 16) {
                header
                stepIndicator
                stepContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                footer
            }
            .padding(24)
            // The content keeps its designed size and stays centred when the window is larger
            // (the wizard is also shown inside the resizable dashboard window).
            .frame(maxWidth: 760, maxHeight: 600)
        }
        .frame(minWidth: 760, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
        .preferredColorScheme(.dark)
        .onAppear {
            isInstalledInApplications = lockController.isInstalledInApplications
            // Never pre-fill the stored secret into a revealable field.
            savedPasswordSuccess = KeychainManager.shared.hasStoredPassword()
            engine.startScanning()
            if !hasChosenInitialStep {
                hasChosenInitialStep = true
                currentStep = firstIncompleteStep()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: KeychainManager.passwordDidChangeNotification)) { _ in
            savedPasswordSuccess = KeychainManager.shared.hasStoredPassword()
        }
        .onChange(of: currentStep) { _, newStep in
            // System prompts and System Settings only open when the user presses a button.
            if newStep == 1 {
                lockController.refreshAccessibilityStatus(prompt: false)
                engine.promptForBluetoothPermission()
            } else if newStep == 2 {
                engine.startScanning()
            }
        }
    }

    /// Opens on the first step that still needs attention, so reopening Setup from the dashboard
    /// lands on what is missing instead of always starting at the beginning.
    private func firstIncompleteStep() -> Int {
        if !lockController.isRunningFromApplications { return 0 }
        if !permissionsReady { return 1 }
        if !deviceReady { return 2 }
        if !savedPasswordSuccess { return 3 }
        return 1
    }

    // MARK: - Background

    private var backgroundRings: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .strokeBorder(AuraTheme.cyanGlow.opacity(0.10 - Double(index) * 0.025), lineWidth: 1)
                    .frame(
                        width: CGFloat(420 + index * 190),
                        height: CGFloat(420 + index * 190)
                    )
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            AuraEclipseLogoView(size: 46)

            VStack(alignment: .leading, spacing: 4) {
                AuraBrandWordmarkView(size: 18, tracking: 3.2)
                Text("Set up proximity lock and unlock in four short steps.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("Version \(AuraTheme.appVersion)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Step Indicator

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            stepBadge(index: 0, title: "Install", done: lockController.isRunningFromApplications)
            stepBadge(index: 1, title: "Permissions", done: permissionsReady)
            stepBadge(index: 2, title: "Device", done: deviceReady)
            stepBadge(index: 3, title: "Password", done: savedPasswordSuccess)
        }
    }

    private func stepBadge(index: Int, title: String, done: Bool) -> some View {
        let isActive = (currentStep == index)
        let tint: Color = done ? AuraTheme.emeraldGlow : (isActive ? AuraTheme.cyanGlow : Color.white.opacity(0.55))
        let badgeFill: Color = tint.opacity((isActive || done) ? 0.22 : 0.10)
        let cardFill: Color = isActive ? tint.opacity(0.14) : Color.white.opacity(0.04)
        let cardStroke: Color = isActive ? tint.opacity(0.60) : Color.white.opacity(0.08)
        let spokenLabel: String = done ? "Step \(index + 1), \(title), done" : "Step \(index + 1), \(title)"

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                currentStep = index
            }
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(badgeFill)
                        .frame(width: 22, height: 22)
                    if done {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                    } else {
                        Text("\(index + 1)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                    }
                }
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(cardStroke, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(spokenLabel))
    }

    // MARK: - Shared Pieces

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case 0:
            installStep
        case 1:
            permissionsStep
        case 2:
            deviceStep
        default:
            passwordStep
        }
    }

    private func stepHeading(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 17, weight: .bold, design: .rounded))
            Text(subtitle)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func setupRow<Trailing: View>(
        symbol: String,
        tint: Color,
        title: String,
        detail: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            trailing()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    private func grantedPill(_ title: String) -> some View {
        AuraStatusPill(title: title, symbol: "checkmark.circle.fill", color: AuraTheme.emeraldGlow)
    }

    // MARK: - Step 1: Install

    private var installStep: some View {
        let runningInstalled = lockController.isRunningFromApplications

        return AuraGlassCard(padding: 22, borderColor: AuraTheme.cyanGlow.opacity(0.30)) {
            VStack(alignment: .leading, spacing: 18) {
                stepHeading(
                    title: "Install AuraSense",
                    subtitle: "AuraSense runs from your Applications folder so it can start at login and keep the permissions you grant it."
                )

                installGraphic
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)

                installStatus(runningInstalled: runningInstalled)

                if !runningInstalled {
                    HStack(spacing: 12) {
                        Button {
                            performCopyToApplications()
                        } label: {
                            Label(
                                isInstalledInApplications ? "Update and Reopen from Applications" : "Install in Applications",
                                systemImage: "arrow.down.app.fill"
                            )
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AuraTheme.indigoGlow)
                        .disabled(isInstallingToApplications)

                        Button("Show Applications Folder") {
                            _ = NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
                        }
                        .buttonStyle(.bordered)
                        .disabled(isInstallingToApplications)
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var installGraphic: some View {
        HStack(spacing: 26) {
            VStack(spacing: 8) {
                AuraEclipseLogoView(size: 64)
                Text("AuraSense")
                    .font(.system(size: 12, weight: .semibold))
            }

            Image(systemName: "arrow.right")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(AuraTheme.cyanGlow.opacity(0.8))

            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(AuraTheme.indigoGlow.opacity(0.18))
                        .frame(width: 64, height: 64)
                    Image(systemName: "folder.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(AuraTheme.cyanGlow)
                }
                Text("Applications")
                    .font(.system(size: 12, weight: .semibold))
            }
        }
    }

    @ViewBuilder
    private func installStatus(runningInstalled: Bool) -> some View {
        if runningInstalled {
            Label("AuraSense is running from Applications. Nothing to do here.", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(AuraTheme.emeraldGlow)
        } else if isInstallingToApplications {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(installStatusMessage)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
        } else if installFailed {
            Label(installStatusMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(AuraTheme.amberGlow)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("You are running AuraSense from outside Applications (for example the disk image). Install it, and Setup reopens from there.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Step 2: Permissions

    private var permissionsStep: some View {
        let axTrusted = lockController.isAccessibilityTrusted
        let btReady = (engine.bluetoothState == .poweredOn)

        return AuraGlassCard(padding: 22, borderColor: AuraTheme.indigoGlow.opacity(0.30)) {
            VStack(alignment: .leading, spacing: 12) {
                stepHeading(
                    title: "Allow two permissions",
                    subtitle: "macOS asks you to approve these. AuraSense cannot lock or unlock your Mac without them."
                )

                setupRow(
                    symbol: axTrusted ? "checkmark.shield.fill" : "hand.raised.fill",
                    tint: axTrusted ? AuraTheme.emeraldGlow : AuraTheme.amberGlow,
                    title: "Accessibility",
                    detail: axTrusted
                        ? "AuraSense can type your password on the lock screen."
                        : "Lets AuraSense type your password on the lock screen. Open Settings, then switch AuraSense on."
                ) {
                    if axTrusted {
                        grantedPill("Granted")
                    } else {
                        Button("Open Settings…") {
                            lockController.promptForAccessibilityPermission(resetStaleEntryIfNeeded: false, openSettingsPane: true)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AuraTheme.indigoGlow)
                    }
                }

                setupRow(
                    symbol: btReady ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash",
                    tint: btReady ? AuraTheme.emeraldGlow : AuraTheme.amberGlow,
                    title: "Bluetooth",
                    detail: btReady
                        ? "AuraSense can measure how close your device is."
                        : "\(engine.bluetoothStateDescription). Turn Bluetooth on and allow AuraSense under Privacy & Security."
                ) {
                    if btReady {
                        grantedPill("Ready")
                    } else {
                        Button("Open Settings…") {
                            lockController.openBluetoothSettings()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AuraTheme.indigoGlow)
                    }
                }

                setupRow(
                    symbol: "display.2",
                    tint: AuraTheme.cyanGlow,
                    title: "Wake external displays",
                    detail: "Optional. Wakes HDMI, DisplayPort and USB-C monitors before unlocking."
                ) {
                    Toggle("Wake external displays", isOn: $lockController.sendMonitorInputSignal)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                if !axTrusted {
                    Text("This step updates by itself as soon as macOS reports the permission.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Step 3: Device & Desk Calibration

    private var deviceStep: some View {
        AuraGlassCard(padding: 20, borderColor: AuraTheme.cyanGlow.opacity(0.30)) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    stepHeading(
                        title: "Choose your device",
                        subtitle: "Pick the iPhone or Apple Watch you carry, leave it on your desk, then run the 10-second signal scan."
                    )
                    Spacer(minLength: 12)
                    if !engine.selectedDeviceName.isEmpty {
                        AuraStatusPill(
                            title: engine.selectedDeviceName,
                            symbol: "checkmark.circle.fill",
                            color: AuraTheme.emeraldGlow
                        )
                        .lineLimit(1)
                        .frame(maxWidth: 220, alignment: .trailing)
                    }
                }

                deviceList

                calibrationBox

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var deviceList: some View {
        ScrollView {
            VStack(spacing: 6) {
                if engine.discoveredDevices.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text(engine.bluetoothState == .poweredOn
                             ? "Looking for nearby devices… Wake your iPhone or Apple Watch."
                             : engine.bluetoothStateDescription)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        #if DEBUG
                        Button("Use Simulated iPhone") {
                            engine.isSimulationMode = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        #endif
                    }
                    .padding(10)
                } else {
                    ForEach(engine.discoveredDevices.prefix(12)) { dev in
                        deviceRow(dev)
                    }
                }
            }
            .padding(6)
        }
        .frame(height: 168)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.22))
        )
    }

    private func deviceRow(_ dev: BLEDevice) -> some View {
        let isBound = (dev.id.uuidString == engine.selectedDeviceID)
        let tint: Color = isBound ? AuraTheme.emeraldGlow : AuraTheme.cyanGlow
        let rowFill: Color = isBound ? AuraTheme.emeraldGlow.opacity(0.12) : Color.white.opacity(0.04)

        return HStack(spacing: 10) {
            Image(systemName: dev.category.symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
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

            SignalBarsView(bars: dev.signalQualityBars, tint: tint)

            if isBound {
                grantedPill("Selected")
            } else {
                Button("Select") {
                    engine.bindDevice(dev)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowFill)
        )
    }

    private var calibrationBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Desk signal scan", systemImage: "scope")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AuraTheme.cyanGlow)
                Spacer()
                if engine.hasNotedDeskRSSI && !engine.isCalibratingDeskSignal {
                    grantedPill("Calibrated at \(engine.notedDeskRSSI) dBm")
                }
            }

            if engine.isCalibratingDeskSignal {
                ProgressView(value: engine.deskCalibrationProgress, total: 1.0)
                    .tint(AuraTheme.cyanGlow)
                HStack {
                    Text("Keep your device still on the desk (\(engine.deskCalibrationSamplesCollected) readings)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(engine.deskCalibrationRemainingSeconds)s")
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    Text(calibrationHint)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button {
                        engine.startTenSecondDeskCalibration()
                    } label: {
                        Label(
                            engine.hasNotedDeskRSSI ? "Scan Again" : "Start 10s Scan",
                            systemImage: "waveform.badge.magnifyingglass"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AuraTheme.indigoGlow)
                    .disabled(engine.selectedDeviceID.isEmpty)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    private var calibrationHint: String {
        if engine.selectedDeviceID.isEmpty {
            return "Select a device above first."
        }
        if engine.hasNotedDeskRSSI {
            return "Unlocks at \(Int(engine.unlockThresholdRSSI)) dBm or stronger, locks at \(Int(engine.lockThresholdRSSI)) dBm or weaker. Fine-tune later under Range & Thresholds."
        }
        return engine.deskCalibrationSummary
    }

    // MARK: - Step 4: Password & iPhone Auto-Fill

    private var passwordStep: some View {
        AuraGlassCard(padding: 22, borderColor: AuraTheme.emeraldGlow.opacity(0.30)) {
            VStack(alignment: .leading, spacing: 12) {
                stepHeading(
                    title: "Save your Mac password",
                    subtitle: "AuraSense types it on the lock screen when your device comes back. It is stored only in this Mac's Keychain."
                )

                passwordBox

                iPhoneBox

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var passwordBox: some View {
        let placeholder = savedPasswordSuccess ? "Saved. Type a new password to replace it" : "Mac login password"

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Mac login password", systemImage: "key.fill")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if savedPasswordSuccess {
                    grantedPill("Saved in Keychain")
                }
            }

            HStack(spacing: 10) {
                Group {
                    if showPasswordPlain {
                        TextField(placeholder, text: $quickPassword)
                    } else {
                        SecureField(placeholder, text: $quickPassword)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    _ = saveQuickPassword()
                }

                Button {
                    showPasswordPlain.toggle()
                } label: {
                    Image(systemName: showPasswordPlain ? "eye.slash" : "eye")
                }
                .buttonStyle(.bordered)
                .help(showPasswordPlain ? "Hide what you typed" : "Show what you typed")

                Button("Save") {
                    _ = saveQuickPassword()
                }
                .buttonStyle(.borderedProminent)
                .tint(AuraTheme.indigoGlow)
                .disabled(quickPassword.isEmpty)
            }

            if !passwordSaveError.isEmpty {
                Label(passwordSaveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(AuraTheme.crimsonGlow)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    private var iPhoneBox: some View {
        HStack(alignment: .top, spacing: 14) {
            AuraQRCodeView(text: bridge.passkeyRelayURL, side: 92)

            VStack(alignment: .leading, spacing: 6) {
                Text("Optional: fill the password from your iPhone")
                    .font(.system(size: 13, weight: .semibold))
                Text("Scan this code with your iPhone camera while on the same Wi-Fi, then use Share › Add to Home Screen in Safari. Opening it fills the Mac password prompt.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Keep the link private. It contains this Mac's pairing token.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)

                Button(didCopyPairingURL ? "Copied" : "Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(bridge.passkeyRelayURL, forType: .string)
                    didCopyPairingURL = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if currentStep > 0 {
                Button("Back") {
                    withAnimation(.easeInOut(duration: 0.2)) { currentStep -= 1 }
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            if currentStep < Self.lastStepIndex {
                Button("Finish Later") {
                    finishSetup()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close Setup. You can reopen it from the dashboard or the menu bar at any time.")

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { currentStep += 1 }
                } label: {
                    Label("Continue", systemImage: "arrow.right")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(AuraTheme.indigoGlow)
                .keyboardShortcut(.defaultAction)
            } else {
                Button {
                    finishSetup()
                } label: {
                    Label("Finish Setup", systemImage: "checkmark")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(AuraTheme.emeraldGlow)
            }
        }
    }

    /// Marks onboarding as done. Embedded in the dashboard window this swaps the dashboard back in;
    /// in the standalone Setup window it closes that window. (Calling `dismiss()` while embedded
    /// would close the dashboard window itself.)
    private func finishSetup() {
        if !quickPassword.isEmpty, !saveQuickPassword() {
            // Stay on the password step so the failure is visible.
            withAnimation(.easeInOut(duration: 0.2)) { currentStep = Self.lastStepIndex }
            return
        }
        engine.hasCompletedOnboarding = true
        if let onComplete {
            onComplete()
        } else {
            dismiss()
        }
    }

    // MARK: - Keychain Helper

    /// Saves the typed password. Reports success only when the Keychain write itself succeeded,
    /// and shows the error otherwise (a stale saved password must not read as "Saved").
    @discardableResult
    private func saveQuickPassword() -> Bool {
        guard !AuraLaunchMode.isInstallerBundle else {
            // The installer bundle must never own the Keychain item (its ACL would name the installer).
            passwordSaveError = "Open AuraSense from Applications to save your password."
            return false
        }
        guard !quickPassword.isEmpty else { return false }
        do {
            try KeychainManager.shared.savePassword(quickPassword)
            savedPasswordSuccess = true
            passwordSaveError = ""
            quickPassword = ""
            showPasswordPlain = false
            return true
        } catch {
            passwordSaveError = "Could not save the password: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Installation Helper

    /// Copies this app into /Applications, then reopens it from there. Setup must continue in the
    /// installed copy: the login LaunchAgent, permissions and Keychain item all refer to it.
    private func performCopyToApplications() {
        guard !isInstallingToApplications else { return }
        isInstallingToApplications = true
        installFailed = false
        installStatusMessage = "Copying AuraSense to Applications…"

        Task { @MainActor in
            let (ok, message) = await lockController.installToApplicationsFolder()
            isInstalledInApplications = lockController.isInstalledInApplications

            guard ok, isInstalledInApplications else {
                installFailed = true
                installStatusMessage = message
                isInstallingToApplications = false
                return
            }

            engine.appendLog(
                kind: .systemState,
                title: "Installed AuraSense in Applications",
                detail: message
            )

            if lockController.isRunningFromApplications {
                installStatusMessage = message
                isInstallingToApplications = false
                return
            }

            installStatusMessage = "Installed. Reopening AuraSense from Applications…"
            try? await Task.sleep(nanoseconds: 700_000_000)
            if !BackgroundPersistenceManager.shared.relaunchFromApplications(openGuidedSetup: true) {
                installFailed = true
                installStatusMessage = "AuraSense was installed but could not reopen itself. Open it from Applications."
                isInstallingToApplications = false
            }
        }
    }
}

// MARK: - Installer Bundle ("Install AuraSense.app" on the DMG)

/// Shown when the DMG's "Install AuraSense.app" bundle runs. It only installs:
/// copies AuraSense.app into /Applications, launches `/Applications/AuraSense.app --setup` (which runs
/// the Guided Setup under the real bundle identifier) and quits. It never binds devices, requests
/// permissions or stores the Keychain password.
public struct InstallerBundleView: View {
    private enum Phase: Equatable {
        case installing
        case launching
        case failed(String)
    }

    @AuraState private var phase: Phase = .installing
    @AuraState private var hasStarted: Bool = false

    private static let installedAppPath = "/Applications/AuraSense.app"

    public init() {}

    public var body: some View {
        ZStack {
            AuraTheme.deepMidnight
                .ignoresSafeArea()

            VStack(spacing: 18) {
                AuraEclipseLogoView(size: 72)
                AuraBrandWordmarkView(size: 19, tracking: 3.4)

                switch phase {
                case .installing:
                    ProgressView()
                        .controlSize(.regular)
                    Text("Installing AuraSense.app into /Applications…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.80))
                case .launching:
                    ProgressView()
                        .controlSize(.regular)
                    Text("Installed. Opening AuraSense to finish setup…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AuraTheme.emeraldGlow)
                case .failed(let message):
                    failureContent(message)
                }
            }
            .padding(28)
        }
        .frame(width: 520, height: 400)
        .preferredColorScheme(.dark)
        .onAppear {
            guard !hasStarted else { return }
            hasStarted = true
            runInstall()
        }
    }

    private func failureContent(_ message: String) -> some View {
        VStack(spacing: 12) {
            Label("Automatic installation didn't finish", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(AuraTheme.amberGlow)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.78))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("You can drag AuraSense.app into the Applications folder yourself, then open it from /Applications.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    runInstall()
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .tint(AuraTheme.indigoGlow)

                Button {
                    revealSourceAppInFinder()
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .buttonStyle(.bordered)

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: 440)
    }

    private func runInstall() {
        phase = .installing
        Task { @MainActor in
            let (ok, message) = await MacLockUnlockController.shared.installToApplicationsFolder()
            let installed = FileManager.default.fileExists(atPath: "\(Self.installedAppPath)/Contents/MacOS/AuraSense")
            guard ok, installed else {
                phase = .failed(message)
                return
            }
            phase = .launching
            launchInstalledAppAndQuit()
        }
    }

    private func launchInstalledAppAndQuit() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--setup"]
        configuration.activates = true
        // A stale running copy must not simply be re-activated; the fresh one replaces it.
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: Self.installedAppPath),
            configuration: configuration
        ) { _, error in
            Task { @MainActor in
                if let error {
                    phase = .failed("AuraSense was installed but could not be opened: \(error.localizedDescription). Open it from /Applications.")
                    return
                }
                // The installer bundle isn't the main app, so termination is always allowed.
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func revealSourceAppInFinder() {
        let parentDir = (Bundle.main.bundlePath as NSString).deletingLastPathComponent
        let sibling = (parentDir as NSString).appendingPathComponent("AuraSense.app")
        if FileManager.default.fileExists(atPath: sibling) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: sibling)])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: parentDir))
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
    }
}
