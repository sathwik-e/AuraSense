import Foundation

/// Immutable snapshot of live Bluetooth diagnostics, capabilities, security gate metrics, and action states.
public struct DiagnosticsSnapshot: Sendable, Codable {
    public let timestamp: Date
    public let radioState: RadioState
    public let authorizationStatus: AuthorizationStatus
    public let isScanning: Bool
    public let candidate: CandidateDevice?
    public let proximityState: ProximityState
    public let smoothedRSSI: Double?
    public let isAutoLockEnabled: Bool
    public let locksExecutedCount: Int
    public let isAutoWakeEnabled: Bool
    public let wakesExecutedCount: Int
    public let sessionState: SessionState
    public let authPath: SupportedAuthenticationPath
    public let gateAdmittedCount: Int
    public let gateBlockedCount: Int
    public let gateAmbiguityCount: Int
    public let peripherals: [PeripheralDiagnosticsRecord]
    public let recentEvents: [DiagnosticEvent]

    public var totalDiscoveredCount: Int {
        peripherals.count
    }

    public var activeCount: Int {
        peripherals.filter { $0.liveness == .active }.count
    }

    public var staleCount: Int {
        peripherals.filter { $0.liveness == .stale }.count
    }

    public var lostCount: Int {
        peripherals.filter { $0.liveness == .lost }.count
    }

    public init(
        timestamp: Date = Date(),
        radioState: RadioState,
        authorizationStatus: AuthorizationStatus,
        isScanning: Bool,
        candidate: CandidateDevice? = nil,
        proximityState: ProximityState = .unknown(reason: "Initial"),
        smoothedRSSI: Double? = nil,
        isAutoLockEnabled: Bool = false,
        locksExecutedCount: Int = 0,
        isAutoWakeEnabled: Bool = false,
        wakesExecutedCount: Int = 0,
        sessionState: SessionState = SessionState(),
        authPath: SupportedAuthenticationPath = .nativeDisplayWakeBiometric,
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
        self.proximityState = proximityState
        self.smoothedRSSI = smoothedRSSI
        self.isAutoLockEnabled = isAutoLockEnabled
        self.locksExecutedCount = locksExecutedCount
        self.isAutoWakeEnabled = isAutoWakeEnabled
        self.wakesExecutedCount = wakesExecutedCount
        self.sessionState = sessionState
        self.authPath = authPath
        self.gateAdmittedCount = gateAdmittedCount
        self.gateBlockedCount = gateBlockedCount
        self.gateAmbiguityCount = gateAmbiguityCount
        self.peripherals = peripherals
        self.recentEvents = recentEvents
    }

    /// Returns human-readable formatted ASCII table diagnostics report.
    public var formattedReport: String {
        var lines: [String] = []
        lines.append("================================================================================")
        lines.append(" AuraSense Proximity & BLE Diagnostics")
        lines.append("================================================================================")
        lines.append(" Timestamp:           \(ISO8601DateFormatter().string(from: timestamp))")
        lines.append(" Radio State:         \(radioState.rawValue)")
        lines.append(" Authorization:       \(authorizationStatus.rawValue)")
        lines.append(" Scanning Active:     \(isScanning)")
        if let candidate = candidate {
            lines.append(" Candidate:           \(candidate.name) [\(candidate.id.uuidString)]")
            lines.append(" Proximity State:     \(proximityState.displayLabel)")
            if let smoothed = smoothedRSSI {
                lines.append(" Smoothed RSSI:       \(String(format: "%.1f", smoothed)) dBm")
            }
        } else {
            lines.append(" Candidate:           None configured (All peripherals blocked)")
            lines.append(" Proximity State:     UNKNOWN (Fail-closed)")
        }
        lines.append(" Security Gate Filter: Admitted: \(gateAdmittedCount) | Blocked: \(gateBlockedCount) | Ambiguity: \(gateAmbiguityCount)")
        lines.append(" Auto-Lock Policy:     \(isAutoLockEnabled ? "ENABLED" : "DISABLED") (Executed: \(locksExecutedCount))")
        lines.append(" Auto-Wake Policy:     \(isAutoWakeEnabled ? "ENABLED" : "DISABLED") (Executed: \(wakesExecutedCount))")
        lines.append(" Session State:        Locked: \(sessionState.isScreenLocked ? "YES" : "NO") | Console: \(sessionState.isOnConsole ? "YES" : "NO")")
        lines.append(" Secure Auth Path:     \(authPath.rawValue)")
        lines.append(" Credential Policy:    ZERO_PLAINTEXT (Zero plaintext credentials stored, logged, or injected)")
        lines.append(" Tracked Peripherals: \(totalDiscoveredCount) total (\(activeCount) active, \(staleCount) stale, \(lostCount) lost)")
        lines.append("--------------------------------------------------------------------------------")
        lines.append(" UUID                                 | Name            | RSSI    | Avg RSSI| Status  | Pkts  ")
        lines.append("--------------------------------------------------------------------------------")
        if peripherals.isEmpty {
            lines.append(" (No peripherals discovered yet)")
        } else {
            for record in peripherals {
                let idStr = record.id.uuidString
                let nameStr = Self.pad(record.name ?? "<unnamed>", length: 15)
                let rssiStr = Self.pad("\(record.latestRSSI) dBm", length: 7, rightAligned: true)
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
/// Coordinates centralized candidate lifecycle, serialized actions, and authoritative scanner health.
public final class DiagnosticsManager: BLEScannerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DiagnosticEvent] = []
    private let maxEvents: Int
    public let registry: PeripheralRegistry
    public let trustStore: any CandidateTrustStoreProtocol
    public let classifier: AdvertisementClassifier
    public let gate: SecurityActionGate
    public let proximityEngine: ProximityEngine
    public let policyEngine: PolicyEngine
    public let authCoordinator: SecureAuthenticationCoordinator
    public let actionExecutor: ActionExecutor

    private var lastRadioState: RadioState = .poweredOn
    private var lastAuthorizationStatus: AuthorizationStatus? = nil
    private var lastLoggedPeripheralEvent: [UUID: Date] = [:]
    /// Per-peer last full-process time for non-candidate coalescing (Finding 16).
    /// Candidate peripherals always process every advertisement; non-candidates are
    /// coalesced to at most one registry/gate/log cycle per peer per second.
    private var lastNonCandidateProcess: [UUID: Date] = [:]
    private let nonCandidateCoalesceInterval: TimeInterval = 1.0

    /// Tracks last purge time for Finding 18 — scheduled bounded registry purge
    private var lastRegistryPurge: Date = Date()
    private let registryPurgeInterval: TimeInterval = 60.0  // Purge once per minute

    /// Currently pending policy dispatch task (Findings 19 & 20).
    /// Stored so it can be cancelled when a newer transition supersedes it.
    private var currentPolicyTask: Task<Void, Never>?

    public var onEventLogged: (@Sendable (DiagnosticEvent) -> Void)?
    public var onGateDecision: (@Sendable (GateDecision) -> Void)?

    /// True when the tick timer can do meaningful work (Finding 11).
    /// Callers should gate their 0.5s timer on this flag instead of waking unconditionally.
    public var canProcessProximityTicks: Bool {
        lock.lock()
        defer { lock.unlock() }
        return lastRadioState.isAvailable && trustStore.registeredCandidate != nil
    }

    /// Opportunistically purges stale registry entries. Called from tick path so no separate timer is needed (Finding 18).
    public func purgeStalePeriodically(referenceDate: Date = Date()) {
        lock.lock()
        let shouldPurge = referenceDate.timeIntervalSince(lastRegistryPurge) >= registryPurgeInterval
        if shouldPurge {
            lastRegistryPurge = referenceDate
            // Bound per-peer tracking dictionaries to prevent memory growth (Findings 16 & 18)
            lastNonCandidateProcess = lastNonCandidateProcess.filter { referenceDate.timeIntervalSince($0.value) <= 60.0 }
            lastLoggedPeripheralEvent = lastLoggedPeripheralEvent.filter { referenceDate.timeIntervalSince($0.value) <= 60.0 }
        }
        lock.unlock()

        guard shouldPurge else { return }
        let purged = registry.purgeStalePeripherals(olderThan: 60.0, referenceDate: referenceDate)
        if purged > 0 {
            log(level: .debug, category: "Registry.Purge", message: "Purged \(purged) stale peripheral(s) from registry")
        }
    }


    public init(
        maxEvents: Int = 200,
        registry: PeripheralRegistry = PeripheralRegistry(),
        trustStore: any CandidateTrustStoreProtocol = InMemoryCandidateTrustStore(),
        classifier: AdvertisementClassifier = AdvertisementClassifier(),
        proximityEngine: ProximityEngine = ProximityEngine(),
        policyEngine: PolicyEngine? = nil,
        authCoordinator: SecureAuthenticationCoordinator? = nil,
        actionExecutor: ActionExecutor = ActionExecutor()
    ) {
        self.maxEvents = maxEvents
        self.registry = registry
        self.trustStore = trustStore
        self.classifier = classifier
        self.gate = SecurityActionGate(trustStore: trustStore, classifier: classifier)
        self.proximityEngine = proximityEngine
        self.policyEngine = policyEngine ?? PolicyEngine(actionProvider: MacOSActionAdapter(isDryRun: true))
        self.authCoordinator = authCoordinator ?? SecureAuthenticationCoordinator()
        self.actionExecutor = actionExecutor

        self.proximityEngine.updateCandidateAvailability(hasCandidate: trustStore.registeredCandidate != nil)

        self.proximityEngine.onStateTransition = { [weak self] oldState, newState, reason in
            guard let self = self else { return }
            self.log(
                level: .info,
                category: "Proximity.FSM",
                message: "Transition [\(oldState.displayLabel)] -> [\(newState.displayLabel)]: \(reason)"
            )

            // Advance generation ONCE for this transition.
            // This implicitly cancels any prior pending action whose generation is now stale.
            // Do NOT additionally call invalidate() here — that would self-cancel the NEAR token.
            let generation = self.actionExecutor.advanceGeneration(reason: "State changed to \(newState.displayLabel)")

            // Cancel any previously pending dispatch task and store new one (Findings 19 & 20)
            self.lock.lock()
            self.currentPolicyTask?.cancel()
            let task = Task { [weak self] in
                guard let self = self else { return }
                await self.dispatchPolicyTransition(
                    from: oldState,
                    to: newState,
                    reason: reason,
                    generation: generation
                )
            }
            self.currentPolicyTask = task
            self.lock.unlock()
        }

        self.proximityEngine.onCountdownTick = { [weak self] sec in
            self?.log(
                level: .warning,
                category: "Proximity.Countdown",
                message: "Departure countdown active: \(sec)s remaining"
            )
        }
    }

    // MARK: - Serialized Policy Dispatch

    private func dispatchPolicyTransition(
        from oldState: ProximityState,
        to newState: ProximityState,
        reason: String,
        generation: Int64
    ) async {
        guard !Task.isCancelled else { return }
        let targetAction: SecurityAction = newState.isFar ? .requestLock : (newState.isNear ? .wakeDisplay : .noOp)
        let result = await actionExecutor.executeSerialized(
            action: targetAction,
            generation: generation,
            validate: { [weak self] in
                guard let self = self else { return false }
                guard !Task.isCancelled else { return false }
                let current = self.proximityEngine.currentState
                if newState.isFar {
                    guard current.isFar else { return false }
                    guard self.trustStore.registeredCandidate != nil else { return false }
                    guard self.lastRadioState.isAvailable else { return false }
                    guard self.policyEngine.isAutoLockEnabled else { return false }
                } else if newState.isNear {
                    guard current.isNear else { return false }
                    guard self.policyEngine.isAutoWakeEnabled else { return false }
                }
                return true
            },
            perform: { [weak self] isValid in
                guard let self = self else { return .rejected(targetAction, reason: "Deallocated") }
                guard !Task.isCancelled else { return .rejected(targetAction, reason: "Task cancelled") }
                return await self.policyEngine.handleStateTransition(
                    from: oldState,
                    to: newState,
                    reason: reason,
                    generation: generation,
                    isValid: isValid
                ) ?? .rejected(targetAction, reason: "No policy action executed")
            }
        )

        if case .executed = result {
            self.log(
                level: .info,
                category: "Policy.Action",
                message: "Policy action executed [Gen \(generation)]: \(result)"
            )
        }
    }

    // MARK: - Centralized Candidate Lifecycle

    public func registerCandidate(_ candidate: CandidateDevice) throws {
        try trustStore.register(candidate: candidate)
        classifier.setCandidate(candidate)
        gate.syncCandidate()
        proximityEngine.updateCandidateAvailability(hasCandidate: true)
        recomputeScannerHealth(reason: "Candidate registered")
        log(
            level: .info,
            category: "Candidate.Lifecycle",
            message: "Successfully registered candidate \(candidate.name) [\(candidate.id.uuidString)]"
        )
    }

    public func unregisterCandidate() throws {
        lock.lock()
        currentPolicyTask?.cancel()
        currentPolicyTask = nil
        lock.unlock()

        try trustStore.unregister()
        classifier.setCandidate(nil)
        gate.syncCandidate()
        proximityEngine.updateCandidateAvailability(hasCandidate: false)
        proximityEngine.filter.reset()
        proximityEngine.cancelActiveCountdown(reason: "Candidate unregistered")
        actionExecutor.invalidate(reason: "Candidate unregistered")
        policyEngine.reset()
        recomputeScannerHealth(reason: "Candidate unregistered")
        log(
            level: .info,
            category: "Candidate.Lifecycle",
            message: "Candidate unregistered. Proximity reset to UNKNOWN and pending actions cleared."
        )
    }

    // MARK: - Authoritative Scanner Health Recomputation

    public func recomputeScannerHealth(reason: String, referenceDate: Date = Date()) {
        lock.lock()
        let radioOk = lastRadioState.isAvailable
        let canScan = lastAuthorizationStatus?.canScan ?? true
        let hasCand = trustStore.registeredCandidate != nil
        let activePeers = registry.activePeripherals(timeout: 15.0, referenceDate: referenceDate)

        let isAmbiguous: Bool
        if let cand = trustStore.registeredCandidate {
            let matching = activePeers.filter { peer in
                peer.id == cand.id || (peer.name != nil && peer.name == cand.name)
            }
            isAmbiguous = matching.count > 1
        } else {
            isAmbiguous = false
        }

        let isHealthy = radioOk && canScan && hasCand && !isAmbiguous
        let explanation: String
        if !radioOk {
            explanation = "Radio unavailable: \(lastRadioState.rawValue)"
        } else if !canScan {
            explanation = "Bluetooth unauthorized"
        } else if !hasCand {
            explanation = "No candidate registered"
        } else if isAmbiguous {
            explanation = "Identity ambiguity detected (\(activePeers.count) active peers)"
        } else {
            explanation = "Monitoring healthy"
        }
        lock.unlock()

        proximityEngine.updateScannerHealth(isHealthy: isHealthy, reason: explanation)
    }

    // MARK: - Logging & Ring Buffer

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

    public func recentEvents() -> [DiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    public func snapshot(from scanner: any BLEScannerProtocol) -> DiagnosticsSnapshot {
        let records = registry.diagnosticsRecords()
        let recent = recentEvents()
        return DiagnosticsSnapshot(
            radioState: scanner.radioState,
            authorizationStatus: scanner.authorizationStatus,
            isScanning: scanner.isScanning,
            candidate: trustStore.registeredCandidate,
            proximityState: proximityEngine.currentState,
            smoothedRSSI: proximityEngine.filter.currentSmoothedRSSI,
            isAutoLockEnabled: policyEngine.isAutoLockEnabled,
            locksExecutedCount: policyEngine.locksExecutedCount,
            isAutoWakeEnabled: policyEngine.isAutoWakeEnabled,
            wakesExecutedCount: policyEngine.wakesExecutedCount,
            sessionState: authCoordinator.detector.currentSessionState(),
            authPath: authCoordinator.evaluateUnlockPath(),
            gateAdmittedCount: gate.admittedCount,
            gateBlockedCount: gate.blockedCount,
            gateAmbiguityCount: gate.ambiguityCount,
            peripherals: records,
            recentEvents: recent
        )
    }

    // MARK: - BLEScannerDelegate

    public func scannerDidChangeRadioState(_ state: RadioState) {
        lock.lock()
        lastRadioState = state
        if !state.isAvailable {
            currentPolicyTask?.cancel()
            currentPolicyTask = nil
        }
        lock.unlock()

        if !state.isAvailable {
            actionExecutor.invalidate(reason: "Radio state \(state.rawValue)")
        }

        recomputeScannerHealth(reason: "Radio state: \(state.rawValue)")
        log(
            level: state.isAvailable ? .info : .warning,
            category: "BLE.Radio",
            message: "Radio state updated to \(state.rawValue)",
            metadata: ["state": state.rawValue]
        )
    }

    public func scannerDidDiscover(peripheral: DiscoveredPeripheral) {
        // Coalescing non-candidate discoveries (Finding 16):
        // Candidate peripherals must receive every observation for accurate RSSI cadence and dwell.
        // Non-candidate peripherals are throttled to at most once per second per peer before
        // incurring registry updates, active-peripheral filtering, and security gate evaluation.
        let isCandidatePeer: Bool
        let shouldProcessNonCandidate: Bool
        lock.lock()
        if let cand = trustStore.registeredCandidate {
            isCandidatePeer = (peripheral.id == cand.id)
        } else {
            isCandidatePeer = false
        }

        if !isCandidatePeer {
            let now = peripheral.lastSeen
            if let lastProcess = lastNonCandidateProcess[peripheral.id],
               now.timeIntervalSince(lastProcess) < nonCandidateCoalesceInterval {
                shouldProcessNonCandidate = false
            } else {
                lastNonCandidateProcess[peripheral.id] = now
                shouldProcessNonCandidate = true
            }
        } else {
            shouldProcessNonCandidate = true
        }
        lock.unlock()

        guard shouldProcessNonCandidate else {
            // Coalesced non-candidate observation: skip redundant processing
            return
        }

        registry.registerOrUpdate(peripheral)

        let allActive = registry.activePeripherals(timeout: 15.0, referenceDate: peripheral.lastSeen)
        let decision = gate.evaluate(peripheral: peripheral, allActivePeripherals: allActive)
        onGateDecision?(decision)

        var meta = [
            "id": peripheral.id.uuidString,
            "name": peripheral.name ?? "",
            "rssi": "\(peripheral.latestRSSI)"
        ]

        switch decision {
        case .admitted(let candidate, _, let rssi):
            meta["gate"] = "ADMITTED"
            meta["candidate"] = candidate.name
            recomputeScannerHealth(reason: "Candidate admitted", referenceDate: peripheral.lastSeen)
            proximityEngine.processSample(rssi: rssi, timestamp: peripheral.lastSeen)
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
                recomputeScannerHealth(reason: "Identity ambiguity detected", referenceDate: peripheral.lastSeen)
                log(
                    level: .warning,
                    category: "Security.Gate",
                    message: "Ambiguous identity detected for candidate. Forcing UNKNOWN: \(explanation)",
                    metadata: meta
                )
            }

            // Rate-limit debug logging for non-candidate peripherals
            let shouldLog: Bool
            lock.lock()
            let lastLog = lastLoggedPeripheralEvent[peripheral.id]
            let now = Date()
            if lastLog == nil || now.timeIntervalSince(lastLog!) > 3.0 {
                lastLoggedPeripheralEvent[peripheral.id] = now
                shouldLog = true
            } else {
                shouldLog = false
            }
            lock.unlock()

            if shouldLog {
                log(
                    level: .debug,
                    category: "BLE.Discovery",
                    message: "[Gate: BLOCKED] Discovered non-candidate peripheral \(peripheral.name ?? "<unnamed>") [\(peripheral.id.uuidString)] RSSI: \(peripheral.latestRSSI) dBm",
                    metadata: meta
                )
            }
        }
    }

    public func scannerDidUpdateRSSI(peripheralID: UUID, rssi: Int, timestamp: Date) {
        registry.updateRSSI(peripheralID: peripheralID, rssi: rssi, timestamp: timestamp)

        if let peripheral = registry.peripheral(for: peripheralID) {
            let allActive = registry.activePeripherals(timeout: 15.0)
            let decision = gate.evaluate(peripheral: peripheral, allActivePeripherals: allActive)
            onGateDecision?(decision)

            if case .admitted = decision {
                proximityEngine.processSample(rssi: rssi, timestamp: timestamp)
            }
        }
    }

    public func scannerDidEncounterError(_ error: Error) {
        lock.lock()
        currentPolicyTask?.cancel()
        currentPolicyTask = nil
        lock.unlock()

        proximityEngine.updateScannerHealth(isHealthy: false, reason: error.localizedDescription)
        actionExecutor.invalidate(reason: "Scanner error: \(error.localizedDescription)")
        log(
            level: .error,
            category: "BLE.Error",
            message: error.localizedDescription
        )
    }
}
