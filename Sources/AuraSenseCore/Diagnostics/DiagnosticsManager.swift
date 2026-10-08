import Foundation

/// Complete diagnostic snapshot representing runtime state and peripheral observations.
public struct DiagnosticsSnapshot: Sendable, Codable {
    public let timestamp: Date
    public let radioState: RadioState
    public let authorizationStatus: AuthorizationStatus
    public let isScanning: Bool
    public let candidate: CandidateDevice?
    public let totalDiscoveredCount: Int
    public let activeCount: Int
    public let staleCount: Int
    public let lostCount: Int
    public let gateAdmittedCount: Int
    public let gateBlockedCount: Int
    public let gateAmbiguityCount: Int
    public let peripherals: [PeripheralDiagnosticsRecord]
    public let recentEvents: [DiagnosticEvent]

    public init(
        timestamp: Date = Date(),
        radioState: RadioState,
        authorizationStatus: AuthorizationStatus,
        isScanning: Bool,
        candidate: CandidateDevice? = nil,
        gateAdmittedCount: Int = 0,
        gateBlockedCount: Int = 0,
        gateAmbiguityCount: Int = 0,
        peripherals: [PeripheralDiagnosticsRecord],
        recentEvents: [DiagnosticEvent]
    ) {
        self.timestamp = timestamp
        self.radioState = radioState
        self.authorizationStatus = authorizationStatus
        self.isScanning = isScanning
        self.candidate = candidate
        self.gateAdmittedCount = gateAdmittedCount
        self.gateBlockedCount = gateBlockedCount
        self.gateAmbiguityCount = gateAmbiguityCount
        self.peripherals = peripherals
        self.recentEvents = recentEvents
        self.totalDiscoveredCount = peripherals.count
        self.activeCount = peripherals.filter { $0.liveness == .active }.count
        self.staleCount = peripherals.filter { $0.liveness == .stale }.count
        self.lostCount = peripherals.filter { $0.liveness == .lost }.count
    }

    /// Formats the snapshot into a human-readable ASCII status report.
    public var formattedReport: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let timeString = formatter.string(from: timestamp)

        var lines: [String] = []
        lines.append("================================================================================")
        lines.append(" AuraSense BLE Discovery Diagnostics - \(timeString)")
        lines.append("================================================================================")
        lines.append(" Radio State:          \(radioState.rawValue)")
        lines.append(" Authorization:        \(authorizationStatus.rawValue)")
        lines.append(" Scanning Active:      \(isScanning ? "YES" : "NO")")

        if let candidate = candidate {
            lines.append(" Selected Candidate:   \(candidate.name) [\(candidate.id.uuidString)]")
            lines.append(" Candidate Security:   UNVERIFIED (Local peer selection; public BLE is not cryptographic proof)")
        } else {
            lines.append(" Selected Candidate:   None (No device candidate enrolled)")
        }

        lines.append(" Security Gate Filter: Admitted: \(gateAdmittedCount) | Blocked: \(gateBlockedCount) | Ambiguities: \(gateAmbiguityCount)")
        lines.append(" Discovered Devices:   \(totalDiscoveredCount) (Active: \(activeCount), Stale: \(staleCount), Lost: \(lostCount))")
        lines.append(" Security Action Lock: INACTIVE (Enforced Phase 2 constraint: No lock/unlock actions)")
        lines.append("--------------------------------------------------------------------------------")
        let hID = Self.pad("Peripheral Identifier", length: 36)
        let hName = Self.pad("Device Name", length: 18)
        let hRSSI = Self.pad("RSSI", length: 8, rightAligned: true)
        let hAvg = Self.pad("Avg", length: 7, rightAligned: true)
        let hStatus = Self.pad("Status", length: 7)
        let hPkts = Self.pad("Pkts", length: 6, rightAligned: true)
        lines.append("\(hID) | \(hName) | \(hRSSI) | \(hAvg) | \(hStatus) | \(hPkts)")
        lines.append("--------------------------------------------------------------------------------")

        if peripherals.isEmpty {
            lines.append("  (No Bluetooth peripherals discovered yet)")
        } else {
            for record in peripherals {
                let idStr = Self.pad(record.id.uuidString, length: 36)
                let nameStr = Self.pad(record.name ?? "<unnamed>", length: 18)
                let rssiStr = Self.pad("\(record.latestRSSI) dBm", length: 8, rightAligned: true)
                let avgStr = Self.pad("\(Int(record.averageRSSI.rounded())) dBm", length: 7, rightAligned: true)
                let statusStr = Self.pad(record.liveness.rawValue, length: 7)
                let pktsStr = Self.pad("\(record.packetCount)", length: 6, rightAligned: true)
                lines.append("\(idStr) | \(nameStr) | \(rssiStr) | \(avgStr) | \(statusStr) | \(pktsStr)")
            }
        }
        lines.append("================================================================================")
        return lines.joined(separator: "\n")
    }

    private static func pad(_ text: String, length: Int, rightAligned: Bool = false) -> String {
        if text.count >= length {
            return String(text.prefix(length))
        }
        let padding = String(repeating: " ", count: length - text.count)
        return rightAligned ? padding + text : text + padding
    }

    /// Returns snapshot formatted as indented JSON.
    public func toJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}

/// Central manager for collecting, storing, and exporting diagnostics.
public final class DiagnosticsManager: BLEScannerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DiagnosticEvent] = []
    private let maxEvents: Int
    public let registry: PeripheralRegistry
    public let trustStore: any CandidateTrustStoreProtocol
    public let classifier: AdvertisementClassifier
    public let gate: SecurityActionGate

    public var onEventLogged: (@Sendable (DiagnosticEvent) -> Void)?
    public var onGateDecision: (@Sendable (GateDecision) -> Void)?

    public init(
        maxEvents: Int = 200,
        registry: PeripheralRegistry = PeripheralRegistry(),
        trustStore: any CandidateTrustStoreProtocol = InMemoryCandidateTrustStore(),
        classifier: AdvertisementClassifier = AdvertisementClassifier()
    ) {
        self.maxEvents = maxEvents
        self.registry = registry
        self.trustStore = trustStore
        self.classifier = classifier
        self.gate = SecurityActionGate(trustStore: trustStore, classifier: classifier)
    }

    /// Records a diagnostic event into the bounded ring buffer.
    public func log(
        level: DiagnosticLevel = .info,
        category: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        let event = DiagnosticEvent(
            level: level,
            category: category,
            message: message,
            metadata: metadata
        )

        lock.lock()
        events.append(event)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
        lock.unlock()

        onEventLogged?(event)
    }

    /// Retrieves all recorded diagnostic events.
    public func recentEvents() -> [DiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    /// Creates an immutable diagnostic snapshot using current scanner and registry state.
    public func snapshot(from scanner: any BLEScannerProtocol) -> DiagnosticsSnapshot {
        let records = registry.diagnosticsRecords()
        let recent = recentEvents()
        return DiagnosticsSnapshot(
            radioState: scanner.radioState,
            authorizationStatus: scanner.authorizationStatus,
            isScanning: scanner.isScanning,
            candidate: trustStore.registeredCandidate,
            gateAdmittedCount: gate.admittedCount,
            gateBlockedCount: gate.blockedCount,
            gateAmbiguityCount: gate.ambiguityCount,
            peripherals: records,
            recentEvents: recent
        )
    }

    // MARK: - BLEScannerDelegate

    public func scannerDidChangeRadioState(_ state: RadioState) {
        log(
            level: state.isAvailable ? .info : .warning,
            category: "BLE.Radio",
            message: "Radio state updated to \(state.rawValue)",
            metadata: ["state": state.rawValue]
        )
    }

    public func scannerDidDiscover(peripheral: DiscoveredPeripheral) {
        registry.registerOrUpdate(peripheral)

        let allActive = registry.allPeripherals()
        let decision = gate.evaluate(peripheral: peripheral, allActivePeripherals: allActive)
        onGateDecision?(decision)

        var meta = [
            "id": peripheral.id.uuidString,
            "name": peripheral.name ?? "",
            "rssi": "\(peripheral.latestRSSI)"
        ]

        switch decision {
        case .admitted(let candidate, _, _):
            meta["gate"] = "ADMITTED"
            meta["candidate"] = candidate.name
            log(
                level: .info,
                category: "BLE.Discovery",
                message: "[Gate: ADMITTED] Observed candidate \(candidate.name) [\(peripheral.id.uuidString)] RSSI: \(peripheral.latestRSSI) dBm",
                metadata: meta
            )

        case .blocked(let reason):
            meta["gate"] = "BLOCKED"
            switch reason {
            case .noCandidateRegistered:
                meta["reason"] = "No candidate registered"
            case .untrustedDevice:
                meta["reason"] = "Untrusted device"
            case .ambiguousCandidate(let count, let explanation):
                meta["reason"] = "Ambiguous candidate (\(count) peers)"
                log(
                    level: .warning,
                    category: "Security.Gate",
                    message: "Ambiguous identity detected for candidate. Forcing UNKNOWN: \(explanation)",
                    metadata: meta
                )
            }
            log(
                level: .debug,
                category: "BLE.Discovery",
                message: "[Gate: BLOCKED] Discovered non-candidate peripheral \(peripheral.name ?? "<unnamed>") [\(peripheral.id.uuidString)] RSSI: \(peripheral.latestRSSI) dBm",
                metadata: meta
            )
        }
    }

    public func scannerDidUpdateRSSI(peripheralID: UUID, rssi: Int, timestamp: Date) {
        registry.updateRSSI(peripheralID: peripheralID, rssi: rssi, timestamp: timestamp)

        if let peripheral = registry.peripheral(for: peripheralID) {
            let allActive = registry.allPeripherals()
            let decision = gate.evaluate(peripheral: peripheral, allActivePeripherals: allActive)
            onGateDecision?(decision)
        }

        log(
            level: .debug,
            category: "BLE.RSSI",
            message: "RSSI updated for \(peripheralID.uuidString): \(rssi) dBm",
            metadata: ["id": peripheralID.uuidString, "rssi": "\(rssi)"]
        )
    }

    public func scannerDidEncounterError(_ error: Error) {
        log(
            level: .error,
            category: "BLE.Error",
            message: error.localizedDescription
        )
    }
}
