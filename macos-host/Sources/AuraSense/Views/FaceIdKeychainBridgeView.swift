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
                pairingTokenCard
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
                        Text("iPhone Password Auto-Fill Bridge")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                        AuraStatusPill(
                            title: bridge.isBridgeEnabled
                                ? (bridge.isRelayListening ? "Port \(bridge.relayPort) Listening" : bridge.relayListenerStatus)
                                : "Paused",
                            symbol: bridge.isRelayListening ? "checkmark.shield.fill" : "exclamationmark.triangle.fill",
                            color: bridge.isRelayListening ? AuraTheme.emeraldGlow : AuraTheme.amberGlow
                        )
                    }
                    Text("Your iPhone can fill the Mac password only with this Mac's pairing token, and only into the lock screen or a focused macOS system password prompt (never web pages or other apps).")
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
                        copyToPasteboard(bridge.passkeyRelayURL)
                    } label: {
                        Label("Copy Bookmark URL", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AuraTheme.indigoGlow)
                    .controlSize(.small)

                    Button("Open in Browser") {
                        if let url = URL(string: bridge.passkeyRelayURL) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                urlRow(label: "BOOKMARK URL", value: bridge.passkeyRelayURL)
                urlRow(label: "SHORTCUT POST", value: bridge.shortcutWebhookBaseURL)

                VStack(alignment: .leading, spacing: 10) {
                    stepRow(num: "1", text: "Open the **Bookmark URL** above in Safari on your iPhone (it already contains your pairing token). Each time the page opens it fills your Mac password once; tap the button on the page to fill again.")
                    stepRow(num: "2", text: "Tap **Share > Add to Home Screen** in Safari to save it as a one-tap icon on your iPhone.")
                    stepRow(num: "3", text: "Optional iOS Shortcut: add **Get Contents of URL** with the **Shortcut POST** URL, set Method to **POST**, and add a header **X-AuraSense-Token** whose value is the pairing token below.")
                    stepRow(num: "!", text: "After updating AuraSense (or regenerating the token), delete and re-add the Home Screen icon and update the Shortcut. Old links without the token are refused.")
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
            }
        }
    }

    // MARK: - Pairing Token Card

    private var pairingTokenCard: some View {
        AuraGlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Pairing Token")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Spacer()
                    Button {
                        copyToPasteboard(bridge.pairingToken)
                    } label: {
                        Label("Copy Token", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(role: .destructive) {
                        bridge.regeneratePairingToken()
                    } label: {
                        Label("Regenerate Token", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Text(verbatim: bridge.pairingToken)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.32)))

                Text("Keep this secret: anyone on your network with this token can ask AuraSense to fill your password. Regenerating it immediately invalidates existing bookmarks and Shortcuts.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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
                            // Hand focus back to the previous app so the fill targets its password field.
                            NSApp.hide(nil)
                            try? await Task.sleep(nanoseconds: 400_000_000)
                            _ = await bridge.autoFillActiveKeychainPrompt(triggerSource: "Manual Test")
                        }
                    } label: {
                        Label("Test Auto-Fill Now", systemImage: "key.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AuraTheme.indigoGlow)
                    .help("Hides AuraSense and fills the password field focused in the previous app.")
                }

                Divider()

                Toggle(isOn: $bridge.requireDeviceInRangeForPost) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Only Fill When Bound BLE Device Is in Range")
                            .font(.system(size: 13, weight: .medium))
                        Text("On by default: requests are refused unless your bound iPhone was seen recently with a usable signal.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
        }
    }

    private func urlRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.black)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(AuraTheme.cyanGlow))
            Text(verbatim: value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.32)))
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
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
