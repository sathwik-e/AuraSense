import Foundation

/// Specific reason why a Bluetooth observation was blocked at the security boundary.
public enum GateBlockReason: Sendable, Codable, Equatable {
    case noCandidateRegistered
    case untrustedDevice(id: UUID, name: String?)
    case ambiguousCandidate(peerCount: Int, reason: String)
}

/// The decision made by the SecurityActionGate for an incoming BLE sample.
public enum GateDecision: Sendable, Codable, Equatable {
    case admitted(candidate: CandidateDevice, peripheralID: UUID, rssi: Int)
    case blocked(GateBlockReason)

    public var isAdmitted: Bool {
        if case .admitted = self { return true }
        return false
    }
}

/// Security boundary enforcing that ONLY registered, non-ambiguous candidate Bluetooth devices
/// can enter the proximity evaluation and security action layers.
public final class SecurityActionGate: @unchecked Sendable {
    private let lock = NSLock()
    private let trustStore: any CandidateTrustStoreProtocol
    private let classifier: AdvertisementClassifier

    private var _admittedCount: Int = 0
    private var _blockedCount: Int = 0
    private var _ambiguityCount: Int = 0

    public var admittedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _admittedCount
    }

    public var blockedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _blockedCount
    }

    public var ambiguityCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _ambiguityCount
    }

    public init(
        trustStore: any CandidateTrustStoreProtocol,
        classifier: AdvertisementClassifier = AdvertisementClassifier()
    ) {
        self.trustStore = trustStore
        self.classifier = classifier
        if let registered = trustStore.registeredCandidate {
            self.classifier.setCandidate(registered)
        }
    }

    /// Synchronizes the classifier with the trust store's registered candidate.
    public func syncCandidate() {
        lock.lock()
        defer { lock.unlock() }
        let current = trustStore.registeredCandidate
        classifier.setCandidate(current)
    }

    /// Evaluates an incoming BLE peripheral observation.
    /// Strictly filters out non-trusted devices and ambiguous peer signals.
    public func evaluate(
        peripheral: DiscoveredPeripheral,
        allActivePeripherals: [DiscoveredPeripheral]
    ) -> GateDecision {
        lock.lock()
        defer { lock.unlock() }

        guard let candidate = trustStore.registeredCandidate else {
            _blockedCount += 1
            return .blocked(.noCandidateRegistered)
        }

        // Direct UUID check
        guard peripheral.id == candidate.id else {
            _blockedCount += 1
            return .blocked(.untrustedDevice(id: peripheral.id, name: peripheral.name))
        }

        // Check for identity ambiguity across all active BLE peers
        let classification = classifier.classify(
            peripheral: peripheral,
            allActivePeripherals: allActivePeripherals
        )

        switch classification {
        case .matched(let matchedCandidate):
            _admittedCount += 1
            return .admitted(
                candidate: matchedCandidate,
                peripheralID: peripheral.id,
                rssi: peripheral.latestRSSI
            )

        case .ambiguous(let count, let reason):
            _blockedCount += 1
            _ambiguityCount += 1
            return .blocked(.ambiguousCandidate(peerCount: count, reason: reason))

        case .untrusted(let reason):
            _blockedCount += 1
            return .blocked(.untrustedDevice(id: peripheral.id, name: reason))
        }
    }

    /// Resets admission and rejection metrics.
    public func resetMetrics() {
        lock.lock()
        defer { lock.unlock() }
        _admittedCount = 0
        _blockedCount = 0
        _ambiguityCount = 0
    }
}
