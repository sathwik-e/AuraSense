import Foundation

/// Represents the trusted identity of an enrolled companion device.
public struct DeviceIdentity: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let label: String
    public let enrolledAt: Date
    public let publicKeyRepresentation: String

    public init(
        id: UUID,
        label: String,
        enrolledAt: Date = Date(),
        publicKeyRepresentation: String
    ) {
        self.id = id
        self.label = label
        self.enrolledAt = enrolledAt
        self.publicKeyRepresentation = publicKeyRepresentation
    }
}

/// Boundary protocol governing which devices can contribute to security state.
public protocol TrustStoreProtocol: Sendable {
    func isTrusted(peripheralID: UUID) -> Bool
    func enrolledIdentity() -> DeviceIdentity?
}

/// Phase 1 stub trust store where no device is trusted until Phase 2 enrollment is implemented.
public final class Phase1TrustStore: TrustStoreProtocol, @unchecked Sendable {
    public init() {}

    public func isTrusted(peripheralID: UUID) -> Bool {
        return false // Untrusted by default
    }

    public func enrolledIdentity() -> DeviceIdentity? {
        return nil
    }
}
