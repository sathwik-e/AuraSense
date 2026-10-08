import Foundation

/// Classifies incoming BLE advertisements against the user's selected candidate.
/// Detects ambiguity (multiple matching devices) and enforces UNKNOWN transitions per ARCHITECTURE.md.
public final class AdvertisementClassifier: @unchecked Sendable {
    private let lock = NSLock()
    private var candidate: CandidateDevice?

    public init(candidate: CandidateDevice? = nil) {
        self.candidate = candidate
    }

    /// Sets or clears the active candidate device.
    public func setCandidate(_ newCandidate: CandidateDevice?) {
        lock.lock()
        defer { lock.unlock() }
        self.candidate = newCandidate
    }

    /// Returns the currently active candidate.
    public func currentCandidate() -> CandidateDevice? {
        lock.lock()
        defer { lock.unlock() }
        return candidate
    }

    /// Classifies an observed peripheral against the selected candidate.
    /// Also checks a list of other active peers to detect identity ambiguity (e.g. duplicate names/spoofing).
    public func classify(
        peripheral: DiscoveredPeripheral,
        allActivePeripherals: [DiscoveredPeripheral] = []
    ) -> CandidateClassification {
        lock.lock()
        defer { lock.unlock() }

        guard let candidate = candidate else {
            return .untrusted(reason: "No candidate device has been selected by the user.")
        }

        // Direct UUID match
        let isDirectIDMatch = (peripheral.id == candidate.id)

        // Name match check
        let isNameMatch = (peripheral.name != nil && peripheral.name == candidate.name)

        // Ambiguity check: Count how many active peripherals match the candidate's name or UUID
        let matchingPeers = allActivePeripherals.filter { peer in
            peer.id == candidate.id || (peer.name != nil && peer.name == candidate.name)
        }

        if matchingPeers.count > 1 {
            return .ambiguous(
                candidateCount: matchingPeers.count,
                reason: "Multiple nearby BLE devices match the candidate profile (\(candidate.name)). Enforcing UNKNOWN to prevent spoofing or misdirected actions."
            )
        }

        if isDirectIDMatch {
            return .matched(candidate)
        }

        if isNameMatch {
            // Note: If ID differs but name matches and it's the only one, flag as unverified match or untrusted if strict ID match is enforced
            return .untrusted(reason: "Peripheral name matches but peer identifier differs.")
        }

        return .untrusted(reason: "Peripheral does not match selected candidate.")
    }
}
