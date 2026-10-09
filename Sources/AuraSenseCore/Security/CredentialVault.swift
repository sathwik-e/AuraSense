import Foundation
import Security

/// Choices presented to the user during first-launch credential onboarding per ARCHITECTURE.md.
public enum VaultOnboardingChoice: String, Sendable, Codable, CaseIterable {
    case importExistingCredentials = "Import existing credentials"
    case startFresh = "Start fresh"
    case skipForNow = "Skip for now"

    public var title: String { rawValue }

    public var detailDescription: String {
        switch self {
        case .importExistingCredentials:
            return "Bring compatible passwords and passkeys from an existing credential manager via system exchange flow."
        case .startFresh:
            return "Create a new local AuraSense credential vault with device-bound encryption."
        case .skipForNow:
            return "Continue without configuring a credential vault. You can set it up anytime in Settings."
        }
    }
}

/// Status of the local AuraSense credential vault.
public enum VaultStatus: String, Sendable, Codable {
    case uninitialized = "Uninitialized"
    case configuredEmpty = "Configured (Empty)"
    case pendingImport = "Pending Import"
    case imported = "Active (Imported)"
    case skipped = "Skipped"
}

/// Errors raised by local credential vault operations.
public enum VaultError: LocalizedError, Sendable {
    case persistenceFailed(String)
    case resetFailed(String)

    public var errorDescription: String? {
        switch self {
        case .persistenceFailed(let reason):
            return "Failed to persist vault metadata: \(reason)"
        case .resetFailed(let reason):
            return "Failed to reset vault storage: \(reason)"
        }
    }
}

/// Metadata record for stored credentials in AuraSense vault.
/// Plaintext secret material is NEVER exposed in telemetry, logs, or stored files.
public struct VaultCredentialRecord: Sendable, Codable, Identifiable, Equatable {
    public let id: UUID
    public let relyingParty: String
    public let username: String
    public let isPasskey: Bool
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        relyingParty: String,
        username: String,
        isPasskey: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.relyingParty = relyingParty
        self.username = username
        self.isPasskey = isPasskey
        self.createdAt = createdAt
    }
}

/// Protocol defining the AuraSense credential vault abstraction per ARCHITECTURE.md.
public protocol CredentialVaultProtocol: Sendable {
    var status: VaultStatus { get }
    var recordCount: Int { get }
    var lastPersistenceError: Error? { get }
    func selectOnboardingChoice(_ choice: VaultOnboardingChoice) throws -> VaultStatus
    func listRecords() -> [VaultCredentialRecord]
    func resetVault() throws
}

/// Thread-safe local credential vault adhering strictly to ARCHITECTURE.md security bounds.
/// Stores only non-secret metadata; does not claim imported until system import succeeds.
public final class LocalCredentialVault: CredentialVaultProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: VaultStatus
    private var _records: [VaultCredentialRecord]
    private var _lastPersistenceError: Error?
    public let vaultFileURL: URL

    public var status: VaultStatus {
        lock.lock()
        defer { lock.unlock() }
        return _status
    }

    public var recordCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _records.count
    }

    public var lastPersistenceError: Error? {
        lock.lock()
        defer { lock.unlock() }
        return _lastPersistenceError
    }

    public init(fileURL: URL? = nil) {
        let url: URL
        if let custom = fileURL {
            url = custom
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("AuraSense")
                ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AuraSense")
            try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
            url = appSupport.appendingPathComponent("vault_metadata.json")
        }
        self.vaultFileURL = url
        self._status = .uninitialized
        self._records = []

        loadMetadata()
    }

    public func selectOnboardingChoice(_ choice: VaultOnboardingChoice) throws -> VaultStatus {
        lock.lock()
        defer { lock.unlock() }

        switch choice {
        case .importExistingCredentials:
            // Remains pending import until actual system exchange succeeds
            self._status = .pendingImport
            try saveMetadataUnderLock()
            return .pendingImport

        case .startFresh:
            // Initialize empty local vault hierarchy
            self._status = .configuredEmpty
            self._records = []
            try saveMetadataUnderLock()
            return .configuredEmpty

        case .skipForNow:
            self._status = .skipped
            try saveMetadataUnderLock()
            return .skipped
        }
    }

    /// Marks the import flow complete once system-mediated credentials are confirmed.
    public func completeImport(records: [VaultCredentialRecord]) throws -> VaultStatus {
        lock.lock()
        defer { lock.unlock() }
        self._status = .imported
        self._records = records
        try saveMetadataUnderLock()
        return .imported
    }

    /// Cancels a pending import flow and returns the vault to uninitialized.
    public func cancelImport() throws -> VaultStatus {
        lock.lock()
        defer { lock.unlock() }
        self._status = .uninitialized
        try saveMetadataUnderLock()
        return .uninitialized
    }

    public func addRecord(_ record: VaultCredentialRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        _records.append(record)
        try saveMetadataUnderLock()
    }

    public func listRecords() -> [VaultCredentialRecord] {
        lock.lock()
        defer { lock.unlock() }
        return _records
    }

    public func resetVault() throws {
        lock.lock()
        defer { lock.unlock() }
        _status = .uninitialized
        _records.removeAll()
        _lastPersistenceError = nil

        if FileManager.default.fileExists(atPath: vaultFileURL.path) {
            do {
                try FileManager.default.removeItem(at: vaultFileURL)
            } catch {
                _lastPersistenceError = VaultError.resetFailed(error.localizedDescription)
                throw VaultError.resetFailed(error.localizedDescription)
            }
        }
    }

    private func saveMetadataUnderLock() throws {
        struct VaultMetadata: Codable {
            let status: VaultStatus
            let records: [VaultCredentialRecord]
        }
        let meta = VaultMetadata(status: _status, records: _records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(meta)
            let parentDir = vaultFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            try data.write(to: vaultFileURL, options: .atomic)
            _lastPersistenceError = nil
        } catch {
            _lastPersistenceError = VaultError.persistenceFailed(error.localizedDescription)
            throw VaultError.persistenceFailed(error.localizedDescription)
        }
    }

    private func loadMetadata() {
        guard FileManager.default.fileExists(atPath: vaultFileURL.path) else {
            return  // Genuinely empty store — not an error
        }

        let data: Data
        do {
            data = try Data(contentsOf: vaultFileURL)
        } catch {
            // Read failure is distinguishable from an empty store
            _lastPersistenceError = VaultError.persistenceFailed("Read failed: \(error.localizedDescription)")
            return
        }

        struct VaultMetadata: Codable {
            let status: VaultStatus
            let records: [VaultCredentialRecord]
        }
        do {
            let decoded = try JSONDecoder().decode(VaultMetadata.self, from: data)
            self._status = decoded.status
            self._records = decoded.records
        } catch {
            // Decode failure is distinguishable — fail closed (do not accept corrupt data)
            _lastPersistenceError = VaultError.persistenceFailed("Corrupt vault metadata: \(error.localizedDescription)")
            // Leave status as .uninitialized so caller sees the error
        }
    }
}
