import SwiftUI

public struct ThresholdsView: View {
    @ObservedObject var engine = BLEProximityEngine.shared
    @AuraState private var selectedPreset: ProximityPreset = .standardOffice

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                tenSecondDeskCalibrationCard
                presetsCard
                dualThresholdCalibrationCard
                timingAndFilteringCard
            }
            .padding(24)
        }
    }

    // MARK: - 10-Second Desk Signal Calibration Card

    private var tenSecondDeskCalibrationCard: some View {
        AuraGlassCard(padding: 20, borderColor: AuraTheme.cyanGlow.opacity(0.45)) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(AuraTheme.cyanGlow.opacity(0.18))
                            .frame(width: 48, height: 48)
                        Image(systemName: engine.isCalibratingDeskSignal ? "dot.radiowaves.up.forward" : "scope")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(AuraTheme.cyanGlow)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 10) {
                            Text("10-Second Desk Signal Calibration")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                            if engine.hasNotedDeskRSSI {
                                AuraStatusPill(
                                    title: "Noted Desk Baseline: \(engine.notedDeskRSSI) dBm (±\(String(format: "%.1f", engine.notedDeskJitterDB)) dB)",
                                    symbol: "checkmark.seal.fill",
                                    color: AuraTheme.emeraldGlow
                                )
                            }
                        }
                        Text(engine.deskCalibrationSummary)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if engine.isCalibratingDeskSignal {
                        Button(role: .destructive) {
                            engine.cancelDeskCalibration()
                        } label: {
                            Label("Cancel (\(engine.deskCalibrationRemainingSeconds)s)", systemImage: "xmark.circle.fill")
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button {
                            engine.startTenSecondDeskCalibration()
                        } label: {
                            Label("Scan Desk Signal (10s)", systemImage: "waveform.badge.magnifyingglass")
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AuraTheme.cyanGlow)
                    }
                }

                if engine.isCalibratingDeskSignal {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: engine.deskCalibrationProgress, total: 1.0)
                            .tint(AuraTheme.cyanGlow)
                        HStack {
                            Text("Sampling desk RSSI & multipath reflections… (\(engine.deskCalibrationSamplesCollected) samples captured)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(AuraTheme.cyanGlow)
                            Spacer()
                            Text("\(engine.deskCalibrationRemainingSeconds)s remaining")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(AuraTheme.cyanGlow.opacity(0.08)))
                }
            }
        }
    }

    // MARK: - Quick Presets Card

    private var presetsCard: some View {
        AuraGlassCard(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Aura Range Presets")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("Choose a calibrated RSSI profile with built-in hysteresis to prevent accidental lock/unlock cycling.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 14) {
                    ForEach([ProximityPreset.deskTight, .standardOffice, .studioRoom]) { preset in
                        let isMatched = (Int(engine.unlockThresholdRSSI) == Int(preset.unlockRSSI) &&
                                         Int(engine.lockThresholdRSSI) == Int(preset.lockRSSI))

                        Button {
                            selectedPreset = preset
                            engine.applyPreset(preset)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(preset.rawValue)
                                        .font(.system(size: 13, weight: .bold, design: .rounded))
                                    Spacer()
                                    if isMatched {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(AuraTheme.emeraldGlow)
                                    }
                                }
                                Text(preset.description)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(2)
                                Divider()
                                HStack {
                                    Text("Unlock ≥ \(Int(preset.unlockRSSI)) dBm")
                                        .foregroundStyle(AuraTheme.emeraldGlow)
                                    Spacer()
                                    Text("Lock ≤ \(Int(preset.lockRSSI)) dBm")
                                        .foregroundStyle(AuraTheme.crimsonGlow)
                                }
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(isMatched ? AuraTheme.indigoGlow.opacity(0.16) : Color.primary.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(isMatched ? AuraTheme.indigoGlow : Color.clear, lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Dual Threshold Hysteresis Sliders

    private var dualThresholdCalibrationCard: some View {
        AuraGlassCard(padding: 20) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("RSSI Threshold & Hysteresis Calibration")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                        Text("AuraSense maintains at least a 6 dB hysteresis deadband between Unlock and Lock thresholds.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let current = engine.trackedDevice {
                        AuraStatusPill(
                            title: "Live Key: \(Int(current.smoothedRSSI.rounded())) dBm",
                            symbol: "waveform.path.ecg",
                            color: AuraTheme.cyanGlow
                        )
                    }
                }

                // Unlock Threshold Slider
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Unlock Aura Threshold (Approach)", systemImage: "lock.open.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AuraTheme.emeraldGlow)
                        Spacer()
                        Text("\(Int(engine.unlockThresholdRSSI)) dBm")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(AuraTheme.emeraldGlow)
                    }
                    Slider(value: $engine.unlockThresholdRSSI, in: -82 ... -42, step: 1)
                        .tint(AuraTheme.emeraldGlow)
                    Text("Mac wakes external monitor input and unlocks via Accessibility when smoothed RSSI rises to or above \(Int(engine.unlockThresholdRSSI)) dBm.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Divider()

                // Lock Threshold Slider
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Auto-Lock Boundary (Departure)", systemImage: "lock.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AuraTheme.crimsonGlow)
                        Spacer()
                        Text("\(Int(engine.lockThresholdRSSI)) dBm")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(AuraTheme.crimsonGlow)
                    }
                    Slider(value: $engine.lockThresholdRSSI, in: -95 ... -50, step: 1)
                        .tint(AuraTheme.crimsonGlow)
                    Text("Departure grace countdown begins when smoothed RSSI drops to or below \(Int(engine.lockThresholdRSSI)) dBm.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Timing & Kalman Smoothing Controls

    private var timingAndFilteringCard: some View {
        AuraGlassCard(padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Grace Timers & Signal Smoothing")
                    .font(.system(size: 16, weight: .bold, design: .rounded))

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Departure Grace Period")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text("\(Int(engine.lockGracePeriodSeconds)) seconds")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(AuraTheme.amberGlow)
                    }
                    Slider(value: $engine.lockGracePeriodSeconds, in: 2 ... 45, step: 1)
                        .tint(AuraTheme.amberGlow)
                    Text("Duration your device must remain below the Lock Threshold before macOS locks the screen.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Signal Loss Timeout")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text("\(Int(engine.signalLossTimeoutSeconds)) seconds")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                    }
                    Slider(value: $engine.signalLossTimeoutSeconds, in: 6 ... 60, step: 1)
                    Text("If no BLE packet is received from your device for this duration, AuraSense treats it as out of range.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Kalman / EMA Responsiveness")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text(String(format: "α = %.2f", engine.smoothingFactor))
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(AuraTheme.cyanGlow)
                    }
                    Slider(value: $engine.smoothingFactor, in: 0.10 ... 0.80, step: 0.05)
                        .tint(AuraTheme.cyanGlow)
                    Text("Automatically tuned during the 10-second Desk Signal Calibration based on wireless reflections.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
