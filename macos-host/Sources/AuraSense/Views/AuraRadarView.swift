import SwiftUI

public struct AuraRadarView: View {
    @ObservedObject var engine = BLEProximityEngine.shared
    @ObservedObject var lockController = MacLockUnlockController.shared
    @Binding var selectedTab: DashboardSection

    @AuraState private var radarPulsePhase: Bool = false
    @AuraState private var orbitAngle: Double = -35.0

    public init(selectedTab: Binding<DashboardSection>) {
        self._selectedTab = selectedTab
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerStatusCard

                HStack(alignment: .top, spacing: 20) {
                    interactiveRadarCard
                        .frame(maxWidth: .infinity)

                    VStack(spacing: 20) {
                        boundDeviceSummaryCard
                        quickTestAndSimulatorCard
                    }
                    .frame(width: 340)
                }

                signalTelemetryChartCard
            }
            .padding(24)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                radarPulsePhase = true
            }
        }
    }

    // MARK: - Top Status Banner

    private var headerStatusCard: some View {
        let stateColor = AuraTheme.stateAccentColor(for: engine.proximityState)

        return AuraGlassCard(padding: 20, borderColor: stateColor.opacity(0.35)) {
            HStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(stateColor.opacity(0.16))
                        .frame(width: 54, height: 54)
                    Circle()
                        .strokeBorder(stateColor.opacity(0.5), lineWidth: 1.5)
                        .frame(width: 54, height: 54)
                        .scaleEffect(radarPulsePhase ? 1.12 : 0.96)
                        .opacity(radarPulsePhase ? 0.5 : 0.95)
                    Image(systemName: engine.proximityState.statusSymbol)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(stateColor)
                        .symbolEffect(.pulse)
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 10) {
                        Text(engine.proximityState.title)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                        AuraStatusPill(
                            title: engine.monitoringEnabled ? "Aura Active" : "Paused",
                            symbol: engine.monitoringEnabled ? "bolt.shield.fill" : "pause.fill",
                            color: engine.monitoringEnabled ? stateColor : .orange
                        )
                    }
                    Text(engine.proximityState.subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    Toggle("Aura Protection", isOn: $engine.monitoringEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                    Text(engine.monitoringEnabled ? "Monitoring Enabled" : "Monitoring Disabled")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Interactive Concentric Aura Radar

    private var interactiveRadarCard: some View {
        let stateColor = AuraTheme.stateAccentColor(for: engine.proximityState)
        let currentRSSI = engine.trackedDevice?.smoothedRSSI ?? -75.0
        // Map RSSI (-35 to -95 dBm) to normalized radius (0.15 to 0.92)
        let normalizedRadius = min(max((-35.0 - currentRSSI) / 60.0, 0.14), 0.92)
        let unlockRadius = min(max((-35.0 - engine.unlockThresholdRSSI) / 60.0, 0.22), 0.78)
        let lockRadius = min(max((-35.0 - engine.lockThresholdRSSI) / 60.0, 0.35), 0.90)

        return AuraGlassCard(padding: 22) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Live Proximity Field")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                        Text("Concentric thresholds visualize your Unlock Aura (inner) and Auto-Lock Boundary (outer)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let dev = engine.trackedDevice {
                        AuraStatusPill(
                            title: "\(Int(dev.smoothedRSSI.rounded())) dBm • \(dev.formattedDistance)",
                            symbol: "dot.radiowaves.left.and.right",
                            color: stateColor
                        )
                    }
                }

                GeometryReader { geo in
                    let size = min(geo.size.width, geo.size.height)
                    let maxR = (size / 2.0) - 24.0

                    ZStack {
                        // Subtle radial ambient backdrop
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        stateColor.opacity(0.20),
                                        AuraTheme.indigoGlow.opacity(0.08),
                                        Color.clear
                                    ],
                                    center: .center,
                                    startRadius: 8,
                                    endRadius: maxR
                                )
                            )
                            .frame(width: maxR * 2, height: maxR * 2)

                        // Outer Lock Boundary Ring
                        Circle()
                            .strokeBorder(
                                AuraTheme.crimsonGlow.opacity(0.45),
                                style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                            )
                            .frame(width: maxR * 2 * lockRadius, height: maxR * 2 * lockRadius)

                        // Inner Unlock Zone Ring
                        Circle()
                            .fill(AuraTheme.emeraldGlow.opacity(0.06))
                            .frame(width: maxR * 2 * unlockRadius, height: maxR * 2 * unlockRadius)
                            .overlay(
                                Circle()
                                    .strokeBorder(AuraTheme.emeraldGlow.opacity(0.55), lineWidth: 1.5)
                            )

                        // Ring Labels
                        VStack {
                            Text("LOCK BOUNDARY (\(Int(engine.lockThresholdRSSI)) dBm)")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(AuraTheme.crimsonGlow.opacity(0.85))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.ultraThinMaterial))
                            Spacer()
                        }
                        .frame(height: maxR * 2 * lockRadius)

                        VStack {
                            Spacer()
                            Text("UNLOCK AURA (\(Int(engine.unlockThresholdRSSI)) dBm)")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(AuraTheme.emeraldGlow)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.ultraThinMaterial))
                        }
                        .frame(height: maxR * 2 * unlockRadius)

                        // Center Mac Node
                        VStack(spacing: 4) {
                            ZStack {
                                Circle()
                                    .fill(AuraTheme.deepMidnight)
                                    .frame(width: 52, height: 52)
                                    .shadow(color: stateColor.opacity(0.5), radius: 12)
                                Circle()
                                    .strokeBorder(AuraTheme.auraLinearGradient, lineWidth: 2)
                                    .frame(width: 52, height: 52)
                                Image(systemName: lockController.isScreenLocked ? "lock.laptopcomputer" : "laptopcomputer")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                            Text("This Mac")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                        }

                        // Orbiting Bound BLE Device Node
                        if let device = engine.trackedDevice {
                            let pointRadius = maxR * normalizedRadius
                            let angleRad = orbitAngle * .pi / 180.0
                            let offsetX = cos(angleRad) * pointRadius
                            let offsetY = sin(angleRad) * pointRadius

                            VStack(spacing: 4) {
                                ZStack {
                                    Circle()
                                        .fill(stateColor.opacity(0.25))
                                        .frame(width: 48, height: 48)
                                        .scaleEffect(radarPulsePhase ? 1.18 : 0.92)
                                    Circle()
                                        .fill(.regularMaterial)
                                        .frame(width: 38, height: 38)
                                        .overlay(
                                            Circle().strokeBorder(stateColor, lineWidth: 2)
                                        )
                                    Image(systemName: device.category.symbolName)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(stateColor)
                                }
                                Text(device.name)
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .lineLimit(1)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(.ultraThinMaterial))
                            }
                            .offset(x: offsetX, y: offsetY)
                            .animation(.spring(response: 0.45, dampingFraction: 0.78), value: normalizedRadius)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(height: 300)
            }
        }
    }

    // MARK: - Bound Device Card

    private var boundDeviceSummaryCard: some View {
        AuraGlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Bound Aura Key", systemImage: "key.radiowaves.forward.fill")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Spacer()
                    Button(engine.selectedDeviceID.isEmpty ? "Select Device" : "Change") {
                        selectedTab = .devices
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if let device = engine.trackedDevice {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(device.category.accentColor.opacity(0.18))
                                .frame(width: 44, height: 44)
                            Image(systemName: device.category.symbolName)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(device.category.accentColor)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.name)
                                .font(.system(size: 15, weight: .semibold))
                                .lineLimit(1)
                            Text("\(device.category.rawValue) • \(device.formattedDistance)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        SignalBarsView(bars: device.signalQualityBars, tint: device.category.accentColor)
                    }

                    HStack(spacing: 12) {
                        metricTile(title: "Filtered RSSI", value: "\(Int(device.smoothedRSSI.rounded())) dBm")
                        metricTile(title: "Raw RSSI", value: "\(device.rawRSSI) dBm")
                        metricTile(title: "Hysteresis", value: "\(Int(engine.unlockThresholdRSSI - engine.lockThresholdRSSI)) dB")
                    }
                } else if !engine.selectedDeviceName.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(engine.selectedDeviceName)
                            .font(.system(size: 15, weight: .semibold))
                        Text("Searching for BLE advertisements from this device…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No device bound yet")
                            .font(.system(size: 14, weight: .medium))
                        Text("Bind your iPhone, Apple Watch, or BLE tag to unlock automatically when in range.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Button {
                            selectedTab = .devices
                        } label: {
                            Label("Choose Bluetooth Device…", systemImage: "dot.radiowaves.left.and.right")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AuraTheme.indigoGlow)
                    }
                }
            }
        }
    }

    private func metricTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    // MARK: - Quick Actions & Walk-Away Simulator Card

    private var quickTestAndSimulatorCard: some View {
        AuraGlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Instant Actions & Radar Sim", systemImage: "sparkles.tv")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Spacer()
                    Toggle("Sim Mode", isOn: $engine.isSimulationMode)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                if engine.isSimulationMode {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Simulated Distance / RSSI:")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(engine.simulatedRSSI)) dBm")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(AuraTheme.cyanGlow)
                        }
                        Slider(value: $engine.simulatedRSSI, in: -92 ... -40, step: 1)
                            .tint(AuraTheme.cyanGlow)
                        HStack {
                            Button("Simulate Approach (-50 dBm)") {
                                withAnimation { engine.simulatedRSSI = -50 }
                            }
                            .controlSize(.small)
                            Spacer()
                            Button("Simulate Walk-Away (-84 dBm)") {
                                withAnimation { engine.simulatedRSSI = -84 }
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(AuraTheme.cyanGlow.opacity(0.08))
                    )
                } else {
                    Text("Test locking your Mac or verify the Accessibility Keychain unlock sequence anytime.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button {
                        engine.triggerManualLock()
                    } label: {
                        Label("Lock Mac Now", systemImage: "lock.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AuraTheme.crimsonGlow)

                    Button {
                        engine.triggerTestUnlockSequence()
                    } label: {
                        Label("Verify Unlock", systemImage: "lock.open.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: - Live RSSI History Sparkline Card

    private var signalTelemetryChartCard: some View {
        let samples = engine.trackedDevice?.rssiHistory ?? []

        return AuraGlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Kalman-Smoothed RSSI Telemetry")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                        Text("Real-time signal trajectory against Unlock (\(Int(engine.unlockThresholdRSSI)) dBm) and Lock (\(Int(engine.lockThresholdRSSI)) dBm) boundaries")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 14) {
                        legendDot(title: "Filtered RSSI", color: AuraTheme.cyanGlow)
                        legendDot(title: "Unlock Zone", color: AuraTheme.emeraldGlow)
                        legendDot(title: "Lock Threshold", color: AuraTheme.crimsonGlow)
                    }
                }

                GeometryReader { geo in
                    let w = geo.size.width
                    let h = geo.size.height
                    let minDB = -95.0
                    let maxDB = -35.0
                    let yForDB: (Double) -> CGFloat = { db in
                        let clamped = min(max(db, minDB), maxDB)
                        let ratio = (maxDB - clamped) / (maxDB - minDB)
                        return CGFloat(ratio) * h
                    }

                    ZStack(alignment: .topLeading) {
                        // Unlock Threshold Line
                        Path { path in
                            let y = yForDB(engine.unlockThresholdRSSI)
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: w, y: y))
                        }
                        .stroke(AuraTheme.emeraldGlow.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))

                        // Lock Threshold Line
                        Path { path in
                            let y = yForDB(engine.lockThresholdRSSI)
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: w, y: y))
                        }
                        .stroke(AuraTheme.crimsonGlow.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))

                        if samples.count >= 2 {
                            // Smoothed RSSI Line
                            Path { path in
                                for (idx, sample) in samples.enumerated() {
                                    let x = w * CGFloat(idx) / CGFloat(max(samples.count - 1, 1))
                                    let y = yForDB(sample.smoothedRSSI)
                                    if idx == 0 {
                                        path.move(to: CGPoint(x: x, y: y))
                                    } else {
                                        path.addLine(to: CGPoint(x: x, y: y))
                                    }
                                }
                            }
                            .stroke(
                                LinearGradient(
                                    colors: [AuraTheme.cyanGlow, AuraTheme.indigoGlow],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ),
                                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                            )
                        } else {
                            Text("Waiting for BLE RSSI telemetry samples… (Or enable 'Sim Mode' above to preview)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                .frame(height: 110)
            }
        }
    }

    private func legendDot(title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}
