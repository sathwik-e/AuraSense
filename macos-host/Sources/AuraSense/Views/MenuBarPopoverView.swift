import SwiftUI
import AppKit

/// MenuBarExtra popover window featuring the Neon Orbit Eclipse emblem and Λ U R Λ S E N S E typography.
public struct MenuBarPopoverView: View {
    @ObservedObject var engine = BLEProximityEngine.shared
    @ObservedObject var lockController = MacLockUnlockController.shared
    @ObservedObject var dockManager = DockVisibilityManager.shared
    @ObservedObject var persistence = BackgroundPersistenceManager.shared
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some View {
        let stateColor = AuraTheme.stateAccentColor(for: engine.proximityState)

        VStack(alignment: .leading, spacing: 12) {
            // Top Header with Eclipse Logo & Λ U R Λ S E N S E Typography
            HStack(spacing: 12) {
                AuraEclipseLogoView(size: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text("AuraSense")
                        .font(.system(size: 13, weight: .semibold))
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
                    Text(engine.selectedDeviceName.isEmpty ? "No device selected" : "Searching for \(engine.selectedDeviceName)…")
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

            // Quick Lock & Pause Grid
            HStack(spacing: 8) {
                Button {
                    engine.triggerManualLock()
                } label: {
                    Label("Lock Now", systemImage: "lock.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
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
                    .controlSize(.small)
                }
            }

            Divider()

            // Footer Navigation
            VStack(spacing: 4) {
                Button {
                    // Reuses the existing dashboard window instead of opening a duplicate.
                    WindowRouter.shared.register(openWindow)
                    WindowRouter.shared.showDashboard()
                } label: {
                    HStack {
                        Label("Open AuraSense…", systemImage: "macwindow")
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)

                Button {
                    Task { @MainActor in
                        await UpdateManager.shared.checkForUpdates(userInitiated: true)
                    }
                } label: {
                    HStack {
                        Label("Check for Updates…", systemImage: "arrow.down.circle")
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
                        VStack(alignment: .leading, spacing: 1) {
                            Label("Quit AuraSense", systemImage: "power")
                            if persistence.keepRunningInBackground {
                                Text("Protection keeps running in the background")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 22)
                            }
                        }
                        Spacer()
                        Text("⌘Q")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)

                if persistence.keepRunningInBackground {
                    Button {
                        persistence.requestStopCompletely()
                    } label: {
                        HStack {
                            Label("Stop Completely…", systemImage: "stop.circle")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: "lock.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                    .help("Requires your Mac password")
                }
            }
        }
        .padding(16)
        .frame(width: 290)
        .onAppear { WindowRouter.shared.register(openWindow) }
    }
}
