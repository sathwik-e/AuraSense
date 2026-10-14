import SwiftUI
import AppKit

public struct ActivityLogView: View {
    @ObservedObject var engine = BLEProximityEngine.shared
    @AuraState private var selectedFilter: ActivityLogEntry.EventKind? = nil
    @AuraState private var searchQuery: String = ""

    public init() {}

    private var filteredEntries: [ActivityLogEntry] {
        engine.activityLog.filter { entry in
            if let filter = selectedFilter, entry.kind != filter {
                return false
            }
            if !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                let q = searchQuery.lowercased()
                return entry.title.lowercased().contains(q)
                    || entry.detail.lowercased().contains(q)
                    || entry.kind.rawValue.lowercased().contains(q)
            }
            return true
        }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerFilterCard
                timelineSection
            }
            .padding(24)
        }
    }

    private var headerFilterCard: some View {
        AuraGlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Proximity Security Activity Log")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                        Text("Real-time audit trail of BLE RSSI transitions, grace period countdowns, and macOS lock/unlock events.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()

                    Button {
                        copyLogToClipboard()
                    } label: {
                        Label("Copy Log", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        engine.clearActivityLog()
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search events…", text: $searchQuery)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )

                    Picker("Category", selection: $selectedFilter) {
                        Text("All Events").tag(ActivityLogEntry.EventKind?.none)
                        ForEach(ActivityLogEntry.EventKind.allCases, id: \.self) { kind in
                            Text(kind.rawValue).tag(ActivityLogEntry.EventKind?.some(kind))
                        }
                    }
                    .frame(width: 180)
                }
            }
        }
    }

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if filteredEntries.isEmpty {
                AuraGlassCard(padding: 32) {
                    VStack(spacing: 8) {
                        Image(systemName: "list.bullet.rectangle.portrait")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text("No matching activity events")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                ForEach(filteredEntries) { entry in
                    AuraGlassCard(padding: 14) {
                        HStack(alignment: .center, spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(entry.kind.tintColor.opacity(0.18))
                                    .frame(width: 36, height: 36)
                                Image(systemName: entry.kind.symbol)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(entry.kind.tintColor)
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    Text(entry.title)
                                        .font(.system(size: 14, weight: .semibold))
                                    if let rssi = entry.rssi {
                                        AuraStatusPill(
                                            title: "\(rssi) dBm",
                                            symbol: "waveform",
                                            color: entry.kind.tintColor
                                        )
                                    }
                                }
                                Text(entry.detail)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text(entry.timestamp, style: .time)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func copyLogToClipboard() {
        let formatter = ISO8601DateFormatter()
        let lines = engine.activityLog.map { entry in
            "[\(formatter.string(from: entry.timestamp))] [\(entry.kind.rawValue)] \(entry.title) — \(entry.detail)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines, forType: .string)
    }
}
