import SwiftUI
import AppKit

public struct FaceIdKeychainBridgeView: View {
    @ObservedObject var bridge = FaceIdKeychainBridgeService.shared
    @ObservedObject var engine = BLEProximityEngine.shared

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerStatusCard
                simpleInstructionsCard
                diagnosticsCard
            }
            .padding(24)
        }
    }

    // MARK: - Top Status Banner

    private var headerStatusCard: some View {
        AuraGlassCard(padding: 20, borderColor: AuraTheme.cyanGlow.opacity(0.45)) {
            HStack(spacing: 16) {
                AuraEclipseLogoView(size: 48)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Text("Instant Browser & POST Password Auto-Fill")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                        AuraStatusPill(
                            title: "Port \(bridge.relayPort) Active",
                            symbol: "checkmark.shield.fill",
                            color: AuraTheme.emeraldGlow
                        )
                    }
                    Text("Opening \(bridge.shortcutWebhookURL) or \(bridge.passkeyRelayURL) immediately fills your Mac password.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("", isOn: $bridge.isBridgeEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
    }

    // MARK: - Simple Instructions Card

    private var simpleInstructionsCard: some View {
        AuraGlassCard(padding: 20, borderColor: AuraTheme.emeraldGlow.opacity(0.40)) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Simple iPhone Setup")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(AuraTheme.cyanGlow)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(bridge.shortcutWebhookURL, forType: .string)
                    } label: {
                        Label("Copy URL", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AuraTheme.indigoGlow)
                    .controlSize(.small)

                    Button("Open in Browser") {
                        if let url = URL(string: bridge.shortcutWebhookURL) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                HStack {
                    Text("AUTO-FILL URL")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(AuraTheme.cyanGlow))
                    Text(bridge.shortcutWebhookURL)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .textSelection(.enabled)
                    Spacer()
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.32)))

                VStack(alignment: .leading, spacing: 10) {
                    stepRow(num: "1", text: "Open **\(bridge.shortcutWebhookURL)** (or **\(bridge.passkeyRelayURL)**) in Safari on your iPhone. Your Mac password auto-fills as soon as the page opens.")
                    stepRow(num: "2", text: "Tap **Share > Add to Home Screen** in Safari to save it as a one-tap icon on your iPhone.")
                    stepRow(num: "3", text: "Optional iOS Shortcut: In the **Shortcuts** app, add **Get Contents of URL** with **\(bridge.shortcutWebhookURL)**, set Method to **POST**, and add it to your Home Screen.")
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
            }
        }
    }

    // MARK: - Diagnostics Card

    private var diagnosticsCard: some View {
        AuraGlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Status")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                        Text(bridge.lastBridgeEvent)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { @MainActor in
                            _ = await bridge.autoFillActiveKeychainPrompt(triggerSource: "Manual Test")
                        }
                    } label: {
                        Label("Test Auto-Fill Now", systemImage: "key.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AuraTheme.indigoGlow)
                }

                Divider()

                Toggle(isOn: $bridge.requireDeviceInRangeForPost) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Only Fill When Bound BLE Device Is in Range")
                            .font(.system(size: 13, weight: .medium))
                        Text("Off by default so opening the URL on your iPhone always works immediately.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
        }
    }

    private func stepRow(num: String, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(num)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(AuraTheme.indigoGlow))
            Text(text)
                .font(.system(size: 12.5))
        }
    }
}
