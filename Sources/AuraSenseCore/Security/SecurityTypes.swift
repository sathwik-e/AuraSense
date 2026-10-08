import Foundation

/// Represents the user-selected companion BLE device candidate.
/// Per ARCHITECTURE.md: Mac-only detection uses CoreBluetooth identifier and advertisement attributes.
/// This is convenience presence, NEVER a cryptographic proof of identity or physical distance.
public struct CandidateDevice: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let selectedAt: Date
    public let serviceUUIDs: [String]

    /// Always false per ARCHITECTURE.md specifications: Mac-only BLE cannot cryptographically prove device ownership.
    public let isCryptographicallyVerified: Bool

    /// User-facing disclaimer explaining security limits.
    public let securityDisclaimer: String

    public init(
        id: UUID,
        name: String,
        selectedAt: Date = Date(),
        serviceUUIDs: [String] = []
    ) {
        self.id = id
        self.name = name
        self.selectedAt = selectedAt
        self.serviceUUIDs = serviceUUIDs
        self.isCryptographicallyVerified = false
        self.securityDisclaimer = "Local unverified candidate. Public BLE advertisements can be spoofed or relayed; not an authenticated security factor."
    }
}

/// Classification outcome of observed BLE peripherals against user candidates.
public enum CandidateClassification: Sendable, Codable, Equatable {
    case matched(CandidateDevice)
    case ambiguous(candidateCount: Int, reason: String)
    case untrusted(reason: String)
}

/// Boundary protocol governing device selection and candidate admission.
public protocol TrustStoreProtocol: Sendable {
    func isCandidate(peripheralID: UUID) -> Bool
    func selectedCandidate() -> CandidateDevice?
}

/// Phase 1 stub trust store where no device is trusted until Phase 2 candidate selection.
public final class Phase1TrustStore: TrustStoreProtocol, @unchecked Sendable {
    public init() {}

    public func isCandidate(peripheralID: UUID) -> Bool {
        return false // Untrusted / non-candidate by default
    }

    public func selectedCandidate() -> CandidateDevice? {
        return nil
    }
}
