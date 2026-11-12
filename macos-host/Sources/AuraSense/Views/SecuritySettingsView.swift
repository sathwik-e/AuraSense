import SwiftUI

public struct SecuritySettingsView: View {
    @ObservedObject var engine = BLEProximityEngine.shared
    @ObservedObject var lockController = MacLockUnlockController.shared
    @ObservedObject var dockManager = DockVisibilityManager.shared
    @ObservedObject var persistence = BackgroundPersistenceManager.shared

    @AuraState private var passwordInput: String = ""
    @AuraState private var showPassword: Bool = false
    @AuraState private var hasStoredPassword: Bool = KeychainManager.shared.hasStoredPassword()
    @AuraState private var statusBannerText: String? = nil
    @AuraState private var statusBannerIsError: Bool = false
    @AuraState private var keychainOptimizerStatus: String? = nil

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                permissionsOverviewCard
                keychainPasswordCard
                simplerKeychainAlternativesCard
                externalMonitorAndBehaviorCard
            }
            .padding(24)
        }
        .onAppear {
            lockController.refreshAccessibilityStatus(prompt: false)
            lockController.refreshExternalMonitorTopology()
            hasStoredPassword = KeychainManager.shared.hasStoredPassword()
            // Never pre-fill the stored secret: the reveal button would expose it to anyone at the Mac.
            passwordInput = ""
        }
        .onReceive(NotificationCenter.default.publisher(for: KeychainManager.passwordDidChangeNotification)) { _ in
            hasStoredPassword = KeychainManager.shared.hasStoredPassword()
        }
    }

    // MARK: - Accessibility & Bluetooth Permissions Card

    private var permissionsOverviewCard: some View {
        AuraGlassCard(padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Permissions")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("AuraSense uses Accessibility to wake your displays and type your password when your device comes into range.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill((lockController.isAccessibilityTrusted ? AuraTheme.emeraldGlow : .orange).opacity(0.16))
                            .frame(width: 42, height: 42)
                        Image(systemName: lockController.isAccessibilityTrusted ? "checkmark.shield.fill" : "hand.raised.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(lockController.isAccessibilityTrusted ? AuraTheme.emeraldGlow : .orange)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text("Accessibility")
                                .font(.system(size: 14, weight: .semibold))
                            AuraStatusPill(
                                title: lockController.isAccessibilityTrusted ? "Granted" : "Action Needed",
                                symbol: lockController.isAccessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                color: lockController.isAccessibilityTrusted ? AuraTheme.emeraldGlow : .orange
                            )
                        }
                        Text("Needed to type your password on the lock screen, wake external displays and use Instant Fill.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        lockController.openAccessibilitySettings()
                    } label: {
                        Label(lockController.isAccessibilityTrusted ? "Open Settings" : "Grant Permission…", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(lockController.isAccessibilityTrusted ? .secondary : AuraTheme.indigoGlow)
                }
            }
        }
    }

    // MARK: - macOS Keychain Vault Card

    private var keychainPasswordCard: some View {
        AuraGlassCard(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 10) {
                            Text("Mac Login Password")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                            AuraStatusPill(
                                title: hasStoredPassword ? "Stored in Keychain" : "Not Configured",
                                symbol: hasStoredPassword ? "key.fill" : "key.slash",
                                color: hasStoredPassword ? AuraTheme.emeraldGlow : .orange
                            )
                        }
                        Text("Stored encrypted in this Mac's login Keychain. Never written anywhere in plain text.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                HStack(spacing: 10) {
                    Group {
                        if showPassword {
                            TextField(hasStoredPassword ? "Saved. Type a new password to replace it…" : "Enter your macOS login password…", text: $passwordInput)
                        } else {
                            SecureField(hasStoredPassword ? "Saved. Type a new password to replace it…" : "Enter your macOS login password…", text: $passwordInput)
                        }
                    }
                    .textFieldStyle(.roundedBorder)

                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        savePasswordToKeychain()
                    } label: {
                        Label("Save to Keychain", systemImage: "lock.doc.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AuraTheme.emeraldGlow)
                    .disabled(passwordInput.isEmpty)

                    if hasStoredPassword {
                        Button(role: .destructive) {
                            clearPasswordFromKeychain()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if let banner = statusBannerText {
                    HStack(spacing: 6) {
                        Image(systemName: statusBannerIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        Text(banner)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(statusBannerIsError ? AuraTheme.crimsonGlow : AuraTheme.emeraldGlow)
                }
            }
        }
    }

    // MARK: - Simpler, Non-Fickle Alternatives to Automatic iCloud Keychain Auto-Fill

    private var simplerKeychainAlternativesCard: some View {
        AuraGlassCard(padding: 20, borderColor: AuraTheme.indigoGlow.opacity(0.4)) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Password Prompts While Unlocked")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text("macOS does not let apps detect its password prompts reliably, so AuraSense fills them only when you ask. These options cover the prompts you see during the day.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                // Alternative 1: Global Hotkey (⌃⌥⌘Space)
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "command.square.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(AuraTheme.cyanGlow)
                        .frame(width: 34)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Instant Fill hotkey (⌃⌥⌘Space)")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Press ⌃⌥⌘Space on a macOS password prompt to type your password and press Return. It fills only genuine system prompts, never web pages, other apps or AuraSense's own prompts, and never uses the clipboard.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Toggle("Instant Fill hotkey", isOn: $lockController.enableGlobalInstantFillHotkey)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))

                // Alternative 2: Keep macOS login.keychain-db Unlocked While Mac is Unlocked
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "key.radiowaves.forward.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(AuraTheme.emeraldGlow)
                        .frame(width: 34)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep the login Keychain unlocked")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Stops the login Keychain re-locking after sleep or inactivity, so macOS asks for the Keychain password less often.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        if let status = keychainOptimizerStatus {
                            Text(status)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(AuraTheme.emeraldGlow)
                        }
                    }

                    Spacer()

                    Button("Apply") {
                        let (_, msg) = lockController.optimizeLoginKeychainStayUnlocked()
                        keychainOptimizerStatus = msg
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AuraTheme.emeraldGlow)
                    .controlSize(.small)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))

                // Alternative 3: Native Apple Watch / Magic Keyboard Touch ID
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "applewatch.side.right")
                        .font(.system(size: 24))
                        .foregroundStyle(AuraTheme.indigoGlow)
                        .frame(width: 34)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Apple Watch or Touch ID approval")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Turn on Apple Watch unlock in System Settings to approve password prompts with a double-click, including with the lid closed.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Open Settings…") {
                        lockController.openTouchIdAndAppleWatchSettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            }
        }
    }

    // MARK: - External Monitor Input & Menu Bar Behavior Card

    private var externalMonitorAndBehaviorCard: some View {
        AuraGlassCard(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Behaviour")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Spacer()
                    AuraStatusPill(
                        title: lockController.hasExternalMonitorConnected
                            ? "\(lockController.connectedDisplayCount) displays connected"
                            : "Built-in display only",
                        symbol: "display.2",
                        color: lockController.hasExternalMonitorConnected ? AuraTheme.emeraldGlow : .secondary
                    )
                }

                Toggle(isOn: $dockManager.hideDockWhenWindowClosed) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hide the Dock icon when the window is closed")
                            .font(.system(size: 13, weight: .medium))
                        Text("AuraSense then lives only in the menu bar.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Divider()

                Toggle(isOn: $lockController.sendMonitorInputSignal) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wake external displays before unlocking")
                            .font(.system(size: 13, weight: .medium))
                        Text("Wakes HDMI, DisplayPort and USB-C monitors so the lock screen is ready for the password.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Divider()

                Toggle(isOn: $engine.autoUnlockEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Unlock automatically when my device arrives")
                            .font(.system(size: 13, weight: .medium))
                        Text("Wakes the display and types your saved password on the lock screen.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Divider()

                Toggle(isOn: $engine.autoLockEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lock automatically when my device leaves")
                            .font(.system(size: 13, weight: .medium))
                        Text("Locks the screen after the grace period ends.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Divider()

                Toggle(isOn: Binding(
                    get: { persistence.keepRunningInBackground },
                    set: { newValue in
                        if newValue {
                            persistence.enableKeepRunningInBackground()
                        } else {
                            persistence.requestDisableKeepRunningInBackground()
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Keep AuraSense running after Quit")
                                .font(.system(size: 13, weight: .medium))
                            Image(systemName: "lock.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .help("Turning this off requires your Mac password")
                        }
                        Text("Quit hides AuraSense but proximity lock and unlock keep working from the menu bar. macOS relaunches it if it's force-quit or crashes, and starts it at login. Use Stop Completely (Mac password) to fully quit.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        if let status = persistence.statusMessage {
                            Text(status)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(AuraTheme.amberGlow)
                        }
                    }
                }
                .toggleStyle(.switch)

                if persistence.keepRunningInBackground {
                    HStack {
                        Spacer()
                        Button {
                            persistence.requestStopCompletely()
                        } label: {
                            Label("Stop AuraSense Completely…", systemImage: "stop.circle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                Divider()

                Toggle(isOn: Binding(
                    get: { persistence.keepRunningInBackground || engine.launchAtLogin },
                    set: { engine.setLaunchAtLogin($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open AuraSense at login")
                            .font(.system(size: 13, weight: .medium))
                        Text(persistence.keepRunningInBackground
                             ? "Included with Keep AuraSense running after Quit."
                             : "Starts quietly in the menu bar when you log in.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(persistence.keepRunningInBackground)
            }
        }
    }

    // MARK: - Keychain Actions

    private func savePasswordToKeychain() {
        do {
            try KeychainManager.shared.savePassword(passwordInput)
            passwordInput = ""
            showPassword = false
            hasStoredPassword = true
            statusBannerIsError = false
            statusBannerText = "Password securely saved in macOS login Keychain."
            engine.appendLog(
                kind: .permission,
                title: "Keychain Password Updated",
                detail: "macOS login credentials stored in Keychain for automatic proximity unlock."
            )
        } catch {
            statusBannerIsError = true
            statusBannerText = error.localizedDescription
        }
    }

    private func clearPasswordFromKeychain() {
        do {
            try KeychainManager.shared.deletePassword()
            passwordInput = ""
            hasStoredPassword = false
            statusBannerIsError = false
            statusBannerText = "Password removed from macOS Keychain."
            engine.appendLog(
                kind: .permission,
                title: "Keychain Password Cleared",
                detail: "Removed stored unlock password from macOS Keychain."
            )
        } catch {
            statusBannerIsError = true
            statusBannerText = error.localizedDescription
        }
    }
}
