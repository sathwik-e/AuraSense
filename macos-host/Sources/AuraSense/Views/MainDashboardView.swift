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
    @AuraState private var showInstallerSheet: Bool = false

    public init() {}

    public var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 14) {
                // Brand Identity Header in Sidebar using Neon Orbit Eclipse & Λ U R Λ S E N S E Typography
                HStack(spacing: 10) {
                    AuraEclipseLogoView(size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        AuraBrandWordmarkView(size: 13, tracking: 2.2)
                        Text("BLE Proximity v1.0")
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

                    Button {
                        showInstallerSheet = true
                    } label: {
                        Label("Quick Setup Guide", systemImage: "slider.horizontal.3")
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
                        showInstallerSheet = true
                    } label: {
                        Label("Setup Guide", systemImage: "slider.horizontal.3")
                    }
                    .help("Open AuraSense Setup Guide")
                }
            }
        }
        .frame(minWidth: 940, minHeight: 620)
        .sheet(isPresented: $showInstallerSheet) {
            InstallerWindowView {
                showInstallerSheet = false
            }
        }
        .onAppear {
            if !engine.hasCompletedOnboarding {
                showInstallerSheet = true
            }
        }
    }
}
