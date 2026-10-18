import SwiftUI

public enum DashboardSection: String, CaseIterable, Identifiable {
    case radar = "Aura Radar"
    case devices = "BLE Devices"
    case thresholds = "Range & Thresholds"
    case faceIdBridge = "Instant Auto-Fill"
    case security = "Security & Keychain"
    case activity = "Activity Log"

    public var id: String { rawValue }

    public var symbol: String {
        switch self {
        case .radar: return "dot.radiowaves.left.and.right"
        case .devices: return "iphone.radiowaves.left.and.right"
        case .thresholds: return "slider.horizontal.below.waveform"
        case .faceIdBridge: return "bolt.horizontal.circle.fill"
        case .security: return "lock.shield.fill"
        case .activity: return "clock.arrow.circlepath"
        }
    }
}

public struct MainDashboardView: View {
    @ObservedObject var engine = BLEProximityEngine.shared
    @ObservedObject var lockController = MacLockUnlockController.shared
    @AuraState private var selectedSection: DashboardSection = .radar
    @AuraState private var showGuidedSetupWizard: Bool = BLEProximityEngine.shared.needsGuidedSetup

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
        .onAppear {
            if engine.needsGuidedSetup {
                showGuidedSetupWizard = true
            }
        }
    }

    private var dashboardSplitView: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 14) {
                // Brand Identity Header in Sidebar using Neon Orbit Eclipse & Λ U R Λ S E N S E Typography
                HStack(spacing: 10) {
                    AuraEclipseLogoView(size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        AuraBrandWordmarkView(size: 13, tracking: 2.2)
                        Text("BLE Proximity v1")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
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
                            .fill(lockController.isAccessibilityTrusted ? AuraTheme.emeraldGlow : .orange)
                            .frame(width: 8, height: 8)
                        Text(lockController.isAccessibilityTrusted ? "Accessibility Trusted" : "Accessibility Required")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    if !lockController.isAccessibilityTrusted {
                        Button {
                            lockController.promptForAccessibilityPermission(resetStaleEntryIfNeeded: true, openSettingsPane: true)
                        } label: {
                            Label("Prompt Permission", systemImage: "hand.raised.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AuraTheme.indigoGlow)
                        .controlSize(.small)
                    }

                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showGuidedSetupWizard = true
                        }
                    } label: {
                        Label("Guided Setup Wizard", systemImage: "slider.horizontal.3")
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(12)
            }
            .navigationSplitViewColumnWidth(min: 215, ideal: 230, max: 260)
        } detail: {
            VStack(spacing: 0) {
                if !lockController.isAccessibilityTrusted || !KeychainManager.shared.hasStoredPassword() || engine.selectedDeviceID.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(AuraTheme.amberGlow)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(
                                !lockController.isAccessibilityTrusted
                                    ? "Accessibility Permission Required for Auto-Unlock & Password Fill"
                                    : (engine.selectedDeviceID.isEmpty ? "No Bluetooth Device Selected Yet" : "Save Your Mac Login Password in Keychain")
                            )
                            .font(.system(size: 12.5, weight: .bold))
                            Text("Click 'Open Guided Setup' or 'Prompt Accessibility' to complete setup.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if !lockController.isAccessibilityTrusted {
                            Button("Prompt Accessibility…") {
                                lockController.promptForAccessibilityPermission(resetStaleEntryIfNeeded: true, openSettingsPane: true)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(AuraTheme.indigoGlow)
                            .controlSize(.small)
                        }

                        Button("Open Guided Setup") {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                showGuidedSetupWizard = true
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AuraTheme.cyanGlow)
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Color.orange.opacity(0.12))
                }

                Group {
                    switch selectedSection {
                    case .radar:
                        AuraRadarView(selectedTab: $selectedSection)
                    case .devices:
                        DeviceScannerView()
                    case .thresholds:
                        ThresholdsView()
                    case .faceIdBridge:
                        FaceIdKeychainBridgeView()
                    case .security:
                        SecuritySettingsView()
                    case .activity:
                        ActivityLogView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(
                LinearGradient(
                    colors: [
                        AuraTheme.deepMidnight.opacity(0.45),
                        Color(nsColor: .windowBackgroundColor)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if let dev = engine.trackedDevice {
                        AuraStatusPill(
                            title: "\(dev.name): \(Int(dev.smoothedRSSI.rounded())) dBm",
                            symbol: dev.category.symbolName,
                            color: AuraTheme.stateAccentColor(for: engine.proximityState)
                        )
                    }

                    Button {
                        engine.triggerManualLock()
                    } label: {
                        Label("Lock Mac", systemImage: "lock.fill")
                    }
                    .help("Immediately lock the Mac screen")

                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showGuidedSetupWizard = true
                        }
                    } label: {
                        Label("Setup Guide", systemImage: "slider.horizontal.3")
                    }
                    .help("Open AuraSense Guided Setup")
                }
            }
        }
        .frame(minWidth: 940, minHeight: 620)
    }
}
