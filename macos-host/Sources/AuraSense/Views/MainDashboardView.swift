import SwiftUI

public enum DashboardSection: String, CaseIterable, Identifiable {
    case radar = "Overview"
    case devices = "Device"
    case thresholds = "Range & Locking"
    case security = "Password"
    case sound = "Sound"
    case activity = "Activity"

    public var id: String { rawValue }

    public var symbol: String {
        switch self {
        case .radar: return "house"
        case .devices: return "iphone"
        case .thresholds: return "slider.horizontal.3"
        case .security: return "key"
        case .sound: return "speaker.wave.2"
        case .activity: return "list.bullet"
        }
    }
}

public struct MainDashboardView: View {
    @ObservedObject var engine = BLEProximityEngine.shared
    @ObservedObject var lockController = MacLockUnlockController.shared
    @Environment(\.openWindow) private var openWindow
    @AuraState private var selectedSection: DashboardSection = .radar
    /// Setup takes over the window only until it has been finished once (or when asked for).
    /// Later gaps (a permission revoked by an update, a missing password) show the banner instead.
    @AuraState private var showGuidedSetupWizard: Bool = !BLEProximityEngine.shared.hasCompletedOnboarding || !BLEProximityEngine.shared.hasNotedDeskRSSI || AuraLaunchMode.requestedGuidedSetup
    /// Cached so `body` never queries the Keychain; refreshed on KeychainManager change notifications.
    @AuraState private var hasStoredPassword: Bool = KeychainManager.shared.hasStoredPassword()

    public init() {}

    public var body: some View {
        Group {
            if showGuidedSetupWizard {
                InstallerWindowView {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showGuidedSetupWizard = false
                    }
                }
            } else {
                dashboardSplitView
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            WindowRouter.shared.register(openWindow)
            if WindowRouter.shared.consumeInitialWindowSuppression() {
                // Quiet relaunch by launchd: keep protecting from the menu bar only.
                DispatchQueue.main.async {
                    DockVisibilityManager.shared.hideFromDockImmediately()
                }
                return
            }
            hasStoredPassword = KeychainManager.shared.hasStoredPassword()
            if let section = WindowRouter.shared.pendingSection {
                selectedSection = section
                WindowRouter.shared.pendingSection = nil
            }
            // `--setup` (installer hand-off) always opens Guided Setup once.
            if WindowRouter.shared.consumeGuidedSetupRequest() || !engine.hasCompletedOnboarding || !engine.hasNotedDeskRSSI {
                showGuidedSetupWizard = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: WindowRouter.showSectionNotification)) { note in
            if let raw = note.object as? String, let section = DashboardSection(rawValue: raw) {
                selectedSection = section
                WindowRouter.shared.pendingSection = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: KeychainManager.passwordDidChangeNotification)) { _ in
            hasStoredPassword = KeychainManager.shared.hasStoredPassword()
        }
    }

    private var dashboardSplitView: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    AuraEclipseLogoView(size: 24)
                    Text("AuraSense")
                        .font(.system(size: 14, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)

                List(DashboardSection.allCases, selection: $selectedSection) { section in
                    Label(section.rawValue, systemImage: section.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .tag(section)
                }
                .listStyle(.sidebar)

                Spacer()

                // Sidebar Bottom Status Footer
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(lockController.isAccessibilityTrusted ? Color.secondary : AuraTheme.amberGlow)
                            .frame(width: 8, height: 8)
                        Text(lockController.isAccessibilityTrusted ? "Accessibility granted" : "Accessibility needed")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showGuidedSetupWizard = true
                        }
                    } label: {
                        Label("Guided Setup", systemImage: "slider.horizontal.3")
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(12)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 220)
        } detail: {
            VStack(spacing: 0) {
                if !lockController.isAccessibilityTrusted || !hasStoredPassword || engine.selectedDeviceID.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(AuraTheme.amberGlow)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(
                                !lockController.isAccessibilityTrusted
                                    ? "Accessibility permission is off"
                                    : (engine.selectedDeviceID.isEmpty ? "No device selected" : "Mac password not saved")
                            )
                            .font(.system(size: 12.5, weight: .bold))
                            Text("Automatic unlock is paused until this is fixed.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if !lockController.isAccessibilityTrusted {
                            Button("Open Settings…") {
                                lockController.promptForAccessibilityPermission(resetStaleEntryIfNeeded: false, openSettingsPane: true)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }

                        Button("Open Setup") {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                showGuidedSetupWizard = true
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Color.primary.opacity(0.05))
                }

                Group {
                    switch selectedSection {
                    case .radar:
                        OverviewView()
                    case .devices:
                        DeviceScannerView()
                    case .thresholds:
                        ThresholdsView()
                    case .security:
                        SecuritySettingsView()
                    case .sound:
                        UnlockExperienceView()
                    case .activity:
                        ActivityLogView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        engine.triggerManualLock()
                    } label: {
                        Label("Lock Mac", systemImage: "lock.fill")
                    }
                    .help("Immediately lock the Mac screen")
                }
            }
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}
