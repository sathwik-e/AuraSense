import SwiftUI
import CoreBluetooth

public struct DeviceScannerView: View {
    @ObservedObject var engine = BLEProximityEngine.shared
    @AuraState private var searchText: String = ""

    public init() {}

    private var filteredDevices: [BLEDevice] {
        engine.discoveredDevices.filter { dev in
            if engine.onlyShowNamedDevices && !dev.hasAdvertisedName && dev.id.uuidString != engine.selectedDeviceID {
                return false
            }
            if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                let query = searchText.lowercased()
                return dev.name.lowercased().contains(query)
                    || dev.category.rawValue.lowercased().contains(query)
                    || dev.id.uuidString.lowercased().contains(query)
            }
            return true
        }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                scannerHeaderCard
                deviceListSection
            }
            .padding(24)
        }
    }

    private var scannerHeaderCard: some View {
        AuraGlassCard(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 10) {
                            Text("Bluetooth Low Energy Scanner")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                            AuraStatusPill(
                                title: engine.bluetoothStateDescription,
                                symbol: engine.bluetoothState == .poweredOn ? "antenna.radiowaves.left.and.right" : "exclamationmark.triangle.fill",
                                color: engine.bluetoothState == .poweredOn ? AuraTheme.cyanGlow : .orange
                            )
                        }
                        Text("Select the iPhone, Apple Watch, AirPods, or BLE security tag that should unlock your Mac when nearby.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()

                    if !engine.selectedDeviceID.isEmpty {
                        Button(role: .destructive) {
                            engine.unbindDevice()
                        } label: {
                            Label("Unbind Current Key", systemImage: "xmark.circle")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                HStack(spacing: 16) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Filter by device name, category, or UUID…", text: $searchText)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )

                    Toggle("Named Devices Only", isOn: $engine.onlyShowNamedDevices)
                        .toggleStyle(.switch)
                        .controlSize(.small)

                    Button {
                        engine.startScanning()
                    } label: {
                        Label("Refresh Scan", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var deviceListSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if filteredDevices.isEmpty {
                AuraGlassCard(padding: 36) {
                    VStack(spacing: 12) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 36))
                            .foregroundStyle(AuraTheme.cyanGlow)
                            .symbolEffect(.variableColor.iterative)
                        Text(engine.bluetoothState == .poweredOn ? "Scanning for nearby Bluetooth LE devices…" : engine.bluetoothStateDescription)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                        Text("Wake your iPhone or Apple Watch screen, or toggle off 'Named Devices Only' to see all nearby BLE advertisements.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)

                        HStack(spacing: 12) {
                            Button("Show All BLE Signals") {
                                engine.onlyShowNamedDevices = false
                            }
                            .buttonStyle(.bordered)

                            Button("Add Simulated iPhone Key") {
                                engine.isSimulationMode = true
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(AuraTheme.indigoGlow)
                        }
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                ForEach(filteredDevices) { device in
                    deviceRowCard(device)
                }
            }
        }
    }

    private func deviceRowCard(_ device: BLEDevice) -> some View {
        let isBound = (device.id.uuidString == engine.selectedDeviceID)
        let borderColor = isBound ? AuraTheme.emeraldGlow.opacity(0.6) : Color.primary.opacity(0.10)

        return AuraGlassCard(padding: 16, borderColor: borderColor) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(device.category.accentColor.opacity(0.16))
                        .frame(width: 46, height: 46)
                    Image(systemName: device.category.symbolName)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(device.category.accentColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(device.name)
                            .font(.system(size: 15, weight: .semibold))
                        if isBound {
                            AuraStatusPill(
                                title: "Bound Aura Key",
                                symbol: "checkmark.seal.fill",
                                color: AuraTheme.emeraldGlow
                            )
                        }
                        if device.isConnected {
                            AuraStatusPill(
                                title: "System Connected",
                                symbol: "link",
                                color: AuraTheme.cyanGlow
                            )
                        }
                    }

                    HStack(spacing: 12) {
                        Text(device.category.rawValue)
                        Text("•")
                        Text(device.formattedDistance)
                        Text("•")
                        Text("UUID: \(device.id.uuidString.prefix(8))…")
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 14) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(Int(device.smoothedRSSI.rounded())) dBm")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                        Text("Raw: \(device.rawRSSI) dBm")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    SignalBarsView(bars: device.signalQualityBars, tint: device.category.accentColor)

                    if isBound {
                        Button("Active Key") {}
                            .buttonStyle(.borderedProminent)
                            .tint(AuraTheme.emeraldGlow)
                            .disabled(true)
                    } else {
                        Button {
                            engine.bindDevice(device)
                        } label: {
                            Label("Bind as Aura Key", systemImage: "key.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AuraTheme.indigoGlow)
                    }
                }
            }
        }
    }
}
