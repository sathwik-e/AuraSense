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
                    Text("macOS System Permissions")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("AuraSense uses macOS Accessibility events to wake external monitor inputs and enter your Keychain password when your device enters range.")
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
                            Text("Accessibility Control (AXIsProcessTrusted)")
                                .font(.system(size: 14, weight: .semibold))
                            AuraStatusPill(
                                title: lockController.isAccessibilityTrusted ? "Granted" : "Action Needed",
                                symbol: lockController.isAccessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                color: lockController.isAccessibilityTrusted ? AuraTheme.emeraldGlow : .orange
                            )
                        }
                        Text("Required for lock screen password entry, external monitor input wake nudges, and ⌃⌥⌘Space instant fill.")
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
                            Text("macOS Keychain Unlock Credentials")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                            AuraStatusPill(
                                title: hasStoredPassword ? "Stored in Keychain" : "Not Configured",
                                symbol: hasStoredPassword ? "key.fill" : "key.slash",
                                color: hasStoredPassword ? AuraTheme.emeraldGlow : .orange
                            )
                        }
                        Text("Encrypted inside your local macOS login Keychain (`com.aurasense.mac.unlock-credentials`). Never stored in plain text.")
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
                    Text("Simpler, Rock-Solid Keychain Alternatives (No Fickle Auto-Detection)")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text("macOS SecurityAgent & CoreAuthUI dialogs use Secure Input, which can make automatic background focus guessing fickle. Use these rock-solid alternatives instead:")
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
                        Text("1. On-Demand Instant Fill Hotkey (⌃⌥⌘Space)")
                            .font(.system(size: 13, weight: .semibold))
                        Text("When a macOS system password prompt (Keychain, admin authorization) appears, press ⌃⌥⌘Space to type your password + Return. For your security it only fills genuine macOS system prompts — never web pages, other apps, or AuraSense's own prompts — and the password is never copied to the clipboard.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Toggle("Enable Hotkeys", isOn: $lockController.enableGlobalInstantFillHotkey)
                        .toggleStyle(.switch)
                        .controlSize(.small)
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
                        Text("2. Stop Login Keychain From Re-Locking While Mac is Unlocked")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Disables inactivity/sleep re-locking on login.keychain-db so macOS doesn't repeatedly ask for your Keychain password while AuraSense keeps your Mac unlocked.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        if let status = keychainOptimizerStatus {
                            Text(status)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(AuraTheme.emeraldGlow)
                        }
                    }

                    Spacer()

                    Button("Optimize Keychain") {
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
                        Text("3. Native Apple Watch Approval or Magic Keyboard with Touch ID")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Enable 'Use Apple Watch to unlock your applications and your Mac' in System Settings so double-clicking your Watch approves iCloud Keychain prompts in clamshell mode.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Open Touch ID Settings") {
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
                    Text("Menu Bar Mode & External Monitor Input Signaling")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Spacer()
                    AuraStatusPill(
                        title: lockController.hasExternalMonitorConnected
                            ? "External Monitor Connected (\(lockController.connectedDisplayCount) Displays)"
                            : "Built-In Display Only",
                        symbol: "display.2",
                        color: lockController.hasExternalMonitorConnected ? AuraTheme.emeraldGlow : .secondary
                    )
                }

                Toggle(isOn: $dockManager.hideDockWhenWindowClosed) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hide Dock Icon When Window is Closed (Menu-Bar-Only Mode)")
                            .font(.system(size: 13, weight: .medium))
                        Text("Removes AuraSense from the Dock and Cmd+Tab switcher whenever you close the dashboard window.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Divider()

                Toggle(isOn: $lockController.sendMonitorInputSignal) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Send Active DisplayPort / HDMI Input Wake Signal to External Monitors")
                            .font(.system(size: 13, weight: .medium))
                        Text("Wakes IODisplayWrangler, triggers caffeinate link wake, and nudges the external monitor framebuffer before unlocking.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Divider()

                Toggle(isOn: $engine.autoUnlockEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automatically Unlock Mac When Device Enters Aura")
                            .font(.system(size: 13, weight: .medium))
                        Text("Wakes external monitor input and enters your Keychain password via Accessibility events.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Divider()

                Toggle(isOn: $engine.autoLockEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automatically Lock Mac When Device Leaves Aura")
                            .font(.system(size: 13, weight: .medium))
                        Text("Invokes SACLockScreenImmediate after the departure grace countdown completes.")
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
                            Text("Keep AuraSense Running After Quit")
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
                        Text("Launch AuraSense Automatically at Login")
                            .font(.system(size: 13, weight: .medium))
                        Text(persistence.keepRunningInBackground
                             ? "Included with Keep AuraSense Running After Quit."
                             : "Starts quietly in the macOS Menu Bar when you log in.")
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
