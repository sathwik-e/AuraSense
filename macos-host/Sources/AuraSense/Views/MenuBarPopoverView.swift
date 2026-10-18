import SwiftUI
import AppKit

/// MenuBarExtra popover window featuring the Neon Orbit Eclipse emblem and Λ U R Λ S E N S E typography.
public struct MenuBarPopoverView: View {
    @ObservedObject var engine = BLEProximityEngine.shared
    @ObservedObject var lockController = MacLockUnlockController.shared
    @ObservedObject var dockManager = DockVisibilityManager.shared
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some View {
        let stateColor = AuraTheme.stateAccentColor(for: engine.proximityState)

        VStack(alignment: .leading, spacing: 12) {
            // Top Header with Eclipse Logo & Λ U R Λ S E N S E Typography
            HStack(spacing: 12) {
                AuraEclipseLogoView(size: 38)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        AuraBrandWordmarkView(size: 12.5, tracking: 2.0)
                        if lockController.hasExternalMonitorConnected {
                            Image(systemName: "display.2")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AuraTheme.cyanGlow)
                                .help("External Monitor Connected — Display Input Wake Active")
                        }
                    }
                    Text(engine.proximityState.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(stateColor)
                }

                Spacer()

                Toggle("", isOn: $engine.monitoringEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            Divider()

            // Active Device & Live Signal Card
            if let device = engine.trackedDevice {
                HStack(spacing: 10) {
                    Image(systemName: device.category.symbolName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(device.category.accentColor)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text("\(Int(device.smoothedRSSI.rounded())) dBm • \(device.formattedDistance)")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    SignalBarsView(bars: device.signalQualityBars, tint: device.category.accentColor)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "sensor.tag.radiowaves.forward")
                        .foregroundStyle(.secondary)
                    Text(engine.selectedDeviceName.isEmpty ? "No BLE key bound yet" : "Searching for \(engine.selectedDeviceName)…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
            }

            // 10-Second Desk Calibration Quick Bar
            if engine.isCalibratingDeskSignal {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Scanning Desk Signal…")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AuraTheme.cyanGlow)
                        Spacer()
                        Text("\(engine.deskCalibrationRemainingSeconds)s")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    ProgressView(value: engine.deskCalibrationProgress, total: 1.0)
                        .tint(AuraTheme.cyanGlow)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(AuraTheme.cyanGlow.opacity(0.10)))
            } else {
                Button {
                    engine.startTenSecondDeskCalibration()
                } label: {
                    HStack {
                        Image(systemName: "scope")
                        Text(engine.hasNotedDeskRSSI
                             ? "Re-Calibrate Desk (\(engine.notedDeskRSSI) dBm noted)"
                             : "Calibrate Desk Signal (10s Scan)")
                        Spacer()
                        Text("10s")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            // Instant Keychain Fill Actions
            HStack(spacing: 8) {
                Button {
                    Task { @MainActor in
                        _ = await lockController.instantFillActivePasswordField()
                    }
                } label: {
                    Label("Fill Password", systemImage: "key.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(AuraTheme.indigoGlow)
                .controlSize(.small)
                .help("Instant-fill Keychain password into active prompt (⌃⌥⌘Space)")

                Button {
                    lockController.copyPasswordTemporarilyForPaste()
                } label: {
                    Label("4s Copy (⌘V)", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Copy Keychain password for 4 seconds then auto-wipe (⌃⌥⌘V)")
            }

            // Quick Lock & Pause Grid
            HStack(spacing: 8) {
                Button {
                    engine.triggerManualLock()
                } label: {
                    Label("Lock Now", systemImage: "lock.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(AuraTheme.crimsonGlow)
                .controlSize(.small)

                if engine.pauseUntilDate == nil {
                    Button {
                        engine.pauseMonitoring(forMinutes: 30)
                    } label: {
                        Label("Pause 30m", systemImage: "pause.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button {
                        engine.resumeMonitoring()
                    } label: {
                        Label("Resume", systemImage: "play.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AuraTheme.emeraldGlow)
                    .controlSize(.small)
                }
            }

            Divider()

            // Footer Navigation
            VStack(spacing: 4) {
                Button {
                    dockManager.showAppInForeground()
                    openWindow(id: "main-dashboard")
                } label: {
                    HStack {
                        Label("Open AuraSense Dashboard…", systemImage: "macwindow")
                        Spacer()
                        Text("⌘D")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)

                Button {
                    dockManager.showAppInForeground()
                    openWindow(id: "installer-wizard")
                } label: {
                    HStack {
                        Label("Quick Setup Guide…", systemImage: "slider.horizontal.3")
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)

                Divider()

                Button(role: .destructive) {
                    NSApplication.shared.terminate(nil)
                } label: {
                    HStack {
                        Label("Quit AuraSense", systemImage: "power")
                        Spacer()
                        Text("⌘Q")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 330)
    }
}
