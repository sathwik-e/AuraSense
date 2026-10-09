import Foundation
import Security
import AuthenticationServices
import LocalAuthentication

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
    case secretStoreFailed(String)

    public var errorDescription: String? {
        switch self {
        case .persistenceFailed(let reason):
            return "Failed to persist vault metadata: \(reason)"
        case .resetFailed(let reason):
            return "Failed to reset vault storage: \(reason)"
        case .secretStoreFailed(let reason):
            return "Failed to access protected credential storage: \(reason)"
        }
    }
}

public protocol CredentialSecretStoreProtocol: Sendable {
    func save(_ secret: String, for id: UUID) throws
    func secret(for id: UUID) throws -> String?
    func delete(for id: UUID) throws
}

public final class KeychainCredentialSecretStore: CredentialSecretStoreProtocol, @unchecked Sendable {
    private let service: String

    public init(service: String = "com.aurasense.credentials") {
        self.service = service
    }

    public func save(_ secret: String, for id: UUID) throws {
        let data = Data(secret.utf8)
        var accessControlError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &accessControlError
        ) else {
            let reason = accessControlError?.takeRetainedValue().localizedDescription ?? "Unknown access-control error"
            throw VaultError.secretStoreFailed(reason)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessControl as String: accessControl
        ]
        var insert = query
        attributes.forEach { insert[$0.key] = $0.value }
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw VaultError.secretStoreFailed("Keychain update failed (status \(updateStatus))")
            }
        } else if addStatus != errSecSuccess {
            throw VaultError.secretStoreFailed("Keychain write failed (status \(addStatus))")
        }
    }

    public func secret(for id: UUID) throws -> String? {
        let authenticationContext = LAContext()
        authenticationContext.localizedReason = "Authenticate to access an AuraSense credential"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: authenticationContext
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw VaultError.secretStoreFailed("Keychain read failed (status \(status))")
        }
        return value
    }

    public func delete(for id: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VaultError.secretStoreFailed("Keychain deletion failed (status \(status))")
        }
    }
}

public struct VaultImportResult: Sendable, Equatable {
    public let importedPasswordCount: Int
    public let skippedItemCount: Int
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

/// Thread-safe local vault. Metadata is kept in the app-support file; secrets remain in Keychain.
public final class LocalCredentialVault: CredentialVaultProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: VaultStatus
    private var _records: [VaultCredentialRecord]
    private var _lastPersistenceError: Error?
    private let secretStore: any CredentialSecretStoreProtocol
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

    public init(fileURL: URL? = nil, secretStore: any CredentialSecretStoreProtocol = KeychainCredentialSecretStore()) {
        self.secretStore = secretStore
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

    public func storePassword(_ password: String, relyingParty: String, username: String) throws -> VaultCredentialRecord {
        try storePasswords([(password: password, relyingParty: relyingParty, username: username)])[0]
    }

    private func storePasswords(
        _ credentials: [(password: String, relyingParty: String, username: String)]
    ) throws -> [VaultCredentialRecord] {
        guard credentials.allSatisfy({ !$0.password.isEmpty && !$0.relyingParty.isEmpty }) else {
            throw VaultError.secretStoreFailed("A non-empty password and relying party are required")
        }
        let newRecords = credentials.map {
            VaultCredentialRecord(relyingParty: $0.relyingParty, username: $0.username)
        }
        lock.lock()
        defer { lock.unlock() }
        let previousRecords = _records
        let previousStatus = _status
        do {
            for (credential, record) in zip(credentials, newRecords) {
                try secretStore.save(credential.password, for: record.id)
            }
            _records.append(contentsOf: newRecords)
            if !newRecords.isEmpty && (_status == .uninitialized || _status == .configuredEmpty || _status == .pendingImport) {
                _status = .imported
            }
            try saveMetadataUnderLock()
            return newRecords
        } catch {
            _records = previousRecords
            _status = previousStatus
            for record in newRecords {
                try? secretStore.delete(for: record.id)
            }
            throw error
        }
    }

    public func password(for id: UUID) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard _records.contains(where: { $0.id == id && !$0.isPasskey }) else { return nil }
        return try secretStore.secret(for: id)
    }

    /// Imports supported password items from Apple's consent-driven credential exchange result.
    /// Passkeys and other item categories remain unimported until AuraSense can preserve their semantics.
    @available(macOS 26.0, *)
    public func importPasswords(from data: ASExportedCredentialData) throws -> VaultImportResult {
        var passwords: [(relyingParty: String, username: String, password: String)] = []
        var skipped = 0
        for account in data.accounts {
            for item in account.items {
                guard let url = item.scope?.urls.first, let host = url.host else {
                    skipped += 1
                    continue
                }
                var foundPassword = false
                for credential in item.credentials {
                    guard case .basicAuthentication(let basic) = credential,
                          let password = basic.password?.value, !password.isEmpty else { continue }
                    let username = basic.userName?.value ?? account.userName
                    passwords.append((host, username, password))
                    foundPassword = true
                }
                if !foundPassword { skipped += 1 }
            }
        }

        let preparedPasswords = passwords.map {
            (password: $0.password, relyingParty: $0.relyingParty, username: $0.username)
        }
        _ = try storePasswords(preparedPasswords)
        return VaultImportResult(importedPasswordCount: passwords.count, skippedItemCount: skipped)
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
        for record in _records {
            try secretStore.delete(for: record.id)
        }
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
