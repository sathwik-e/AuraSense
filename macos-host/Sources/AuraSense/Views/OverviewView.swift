import SwiftUI

/// The main page: current state, the bound device, one signal meter and two actions.
public struct OverviewView: View {
    @ObservedObject var engine = BLEProximityEngine.shared

    public init() {}

    public var body: some View {
        let stateColor = AuraTheme.stateAccentColor(for: engine.proximityState)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Status
                AuraGlassCard(padding: 20) {
                    HStack(spacing: 16) {
                        Image(systemName: engine.proximityState.statusSymbol)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(stateColor)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(stateColor.opacity(0.14)))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(engine.proximityState.title)
                                .font(.system(size: 18, weight: .semibold))
                            Text(engine.proximityState.subtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Spacer()

                        Toggle("Protection", isOn: $engine.monitoringEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .help("Turn proximity lock and unlock on or off")
                    }
                }

                // Device + signal
                AuraGlassCard(padding: 20) {
                    VStack(alignment: .leading, spacing: 14) {
                        if let device = engine.trackedDevice {
                            HStack(spacing: 12) {
                                Image(systemName: device.category.symbolName)
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name)
                                        .font(.system(size: 14, weight: .semibold))
                                    Text("\(Int(device.smoothedRSSI.rounded())) dBm · \(device.formattedDistance)")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                SignalBarsView(bars: device.signalQualityBars, tint: stateColor)
                            }

                            SignalMeter(
                                rssi: device.smoothedRSSI,
                                unlock: engine.unlockThresholdRSSI,
                                lock: engine.lockThresholdRSSI,
                                tint: stateColor
                            )
                        } else {
                            HStack(spacing: 10) {
                                Image(systemName: "iphone.slash")
                                    .foregroundStyle(.secondary)
                                Text(engine.selectedDeviceName.isEmpty
                                     ? "No device selected. Choose one under Device."
                                     : "Looking for \(engine.selectedDeviceName)…")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // Actions
                HStack(spacing: 10) {
                    Button {
                        engine.triggerManualLock()
                    } label: {
                        Label("Lock Now", systemImage: "lock.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    if engine.pauseUntilDate == nil {
                        Button {
                            engine.pauseMonitoring(forMinutes: 30)
                        } label: {
                            Label("Pause 30 min", systemImage: "pause")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    } else {
                        Button {
                            engine.resumeMonitoring()
                        } label: {
                            Label("Resume", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }

                Text(engine.lockOnlyWhenIdle
                     ? "Auto-lock waits until you have stopped using the keyboard and mouse."
                     : "Auto-lock follows the Bluetooth signal only.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Horizontal meter from weak (-100 dBm) to strong (-35 dBm) with lock/unlock marks.
private struct SignalMeter: View {
    let rssi: Double
    let unlock: Double
    let lock: Double
    let tint: Color

    private func fraction(_ value: Double) -> CGFloat {
        CGFloat(min(max((value + 100.0) / 65.0, 0.0), 1.0))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(tint).frame(width: max(w * fraction(rssi), 6))
                    Rectangle().fill(Color.red.opacity(0.8))
                        .frame(width: 2, height: 14)
                        .offset(x: w * fraction(lock) - 1)
                    Rectangle().fill(Color.green.opacity(0.8))
                        .frame(width: 2, height: 14)
                        .offset(x: w * fraction(unlock) - 1)
                }
                .frame(height: 8)
            }
            .frame(height: 14)

            HStack {
                Text("Lock ≤ \(Int(lock)) dBm")
                Spacer()
                Text("Unlock ≥ \(Int(unlock)) dBm")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
        }
    }
}
