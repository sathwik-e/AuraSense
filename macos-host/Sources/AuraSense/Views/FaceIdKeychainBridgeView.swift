import SwiftUI
import AppKit

public struct FaceIdKeychainBridgeView: View {
    @ObservedObject var bridge = FaceIdKeychainBridgeService.shared
    @ObservedObject var engine = BLEProximityEngine.shared

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerStatusCard
                prioritizedPostShortcutCard
                unlockedWebpageTriggerCard
                proximityGuardAndDetectorCard
            }
            .padding(24)
        }
    }

    // MARK: - Top Status Banner

    private var headerStatusCard: some View {
        AuraGlassCard(padding: 20, borderColor: AuraTheme.cyanGlow.opacity(0.45)) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(AuraTheme.cyanGlow.opacity(0.18))
                        .frame(width: 52, height: 52)
                    Image(systemName: "bolt.horizontal.circle.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(AuraTheme.cyanGlow)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Text("iPhone POST Trigger & Unlocked Web Page Bridge")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                        AuraStatusPill(
                            title: "Active on Port \(bridge.relayPort)",
                            symbol: "checkmark.shield.fill",
                            color: AuraTheme.emeraldGlow
                        )
                    }
                    Text("Prioritizes POST \(bridge.shortcutWebhookURL) and serves an unlocked instant-fill webpage at \(bridge.passkeyRelayURL).")
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

    // MARK: - Prioritized Method #2: POST Endpoint + Home Screen Shortcut

    private var prioritizedPostShortcutCard: some View {
        AuraGlassCard(padding: 20, borderColor: AuraTheme.emeraldGlow.opacity(0.45)) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Prioritized Method: POST Shortcut on iPhone Home Screen", systemImage: "bolt.shield.fill")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(AuraTheme.emeraldGlow)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(bridge.shortcutWebhookURL, forType: .string)
                    } label: {
                        Label("Copy POST URL", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AuraTheme.indigoGlow)
                    .controlSize(.small)
                }

                HStack {
                    Text("POST")
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(AuraTheme.emeraldGlow))
                    Text(bridge.shortcutWebhookURL)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(AuraTheme.cyanGlow)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Open Guide in Browser") {
                        if let url = URL(string: bridge.shortcutWebhookURL) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.28)))

                VStack(alignment: .leading, spacing: 8) {
                    Text("Add the POST Shortcut to Your iPhone Home Screen:")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(AuraTheme.cyanGlow)

                    stepRow(num: "1", text: "Open the **Shortcuts** app on your iPhone, tap **+** (New Shortcut), and name it **\"Mac Keychain Fill\"**.")
                    stepRow(num: "2", text: "Tap **Add Action** → search for **\"Get Contents of URL\"** → set the URL to **\(bridge.shortcutWebhookURL)**.")
                    stepRow(num: "3", text: "Tap the arrow **(>)** next to the URL and change **Method** from `GET` to **`POST`**.")
                    stepRow(num: "4", text: "Tap the **ⓘ (Info)** or **Share** icon at the bottom → tap **\"Add to Home Screen\"** → tap **Add**.")
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
            }
        }
    }

    // MARK: - Unlocked Webpage Trigger Card

    private var unlockedWebpageTriggerCard: some View {
        AuraGlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Unlocked iPhone Webpage Trigger: \(bridge.passkeyRelayURL)", systemImage: "iphone.radiowaves.left.and.right")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Spacer()
                    Button("Copy /faceid URL") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(bridge.passkeyRelayURL, forType: .string)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Open Webpage") {
                        if let url = URL(string: bridge.passkeyRelayURL) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AuraTheme.cyanGlow)
                    .controlSize(.small)
                }

                Text("Open \(bridge.passkeyRelayURL) directly on your iPhone with zero app locking — just tap '⚡ Fill Mac Password Now (POST)' to immediately enter your password on your Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Proximity Guard & Live Detector Card

    private var proximityGuardAndDetectorCard: some View {
        AuraGlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Password Fill Diagnostics")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                        Text(bridge.lastBridgeEvent)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { @MainActor in
                            _ = await bridge.autoFillActiveKeychainPrompt(triggerSource: "Manual POST Diagnostic")
                        }
                    } label: {
                        Label("Test POST Password Fill Now", systemImage: "key.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AuraTheme.indigoGlow)
                }

                Divider()

                Toggle(isOn: $bridge.requireDeviceInRangeForPost) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Optional: Only Enter Password When Selected BLE Device Is Within Range")
                            .font(.system(size: 13, weight: .medium))
                        Text("Disabled by default so the iPhone webpage button always works without locking or blocking.")
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
