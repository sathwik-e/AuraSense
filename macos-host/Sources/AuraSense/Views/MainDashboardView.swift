import SwiftUI

public enum DashboardSection: String, CaseIterable, Identifiable {
    case radar = "Aura Radar"
    case devices = "BLE Devices"
    case thresholds = "Range & Thresholds"
    case faceIdBridge = "Face ID Keychain"
    case security = "Security & Keychain"
    case activity = "Activity Log"

    public var id: String { rawValue }

    public var symbol: String {
        switch self {
        case .radar: return "dot.radiowaves.left.and.right"
        case .devices: return "iphone.radiowaves.left.and.right"
        case .thresholds: return "slider.horizontal.below.waveform"
        case .faceIdBridge: return "faceid"
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
                // Brand Identity Header in Sidebar
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(AuraTheme.auraLinearGradient)
                            .frame(width: 34, height: 34)
                            .shadow(color: AuraTheme.cyanGlow.opacity(0.35), radius: 6)
                        Image(systemName: "lock.open.rotation")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("AuraSense")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                        Text("BLE Proximity Lock")
                            .font(.system(size: 11))
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
                        Label("Setup & Installer Guide", systemImage: "sparkles")
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(12)
            }
            .navigationSplitViewColumnWidth(min: 205, ideal: 220, max: 250)
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
                        AuraTheme.deepMidnight.opacity(0.32),
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
                        Label("Setup Wizard", systemImage: "wand.and.stars")
                    }
                    .help("Open AuraSense Custom Installer & Setup Assistant")
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
