import Testing
import Foundation
import AuthenticationServices
@testable import AuraSenseCore

struct CredentialVaultTests {

    private final class MemorySecretStore: CredentialSecretStoreProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [UUID: String] = [:]

        func save(_ secret: String, for id: UUID) throws {
            lock.lock()
            defer { lock.unlock() }
            values[id] = secret
        }

        func secret(for id: UUID) throws -> String? {
            lock.lock()
            defer { lock.unlock() }
            return values[id]
        }

        func delete(for id: UUID) throws {
            lock.lock()
            defer { lock.unlock() }
            values.removeValue(forKey: id)
        }
    }

    @Test func testVaultOnboardingChoices() {
        let choices = VaultOnboardingChoice.allCases
        #expect(choices.count == 3)
        #expect(choices.contains(.importExistingCredentials))
        #expect(choices.contains(.startFresh))
        #expect(choices.contains(.skipForNow))

        for choice in choices {
            #expect(!choice.title.isEmpty)
            #expect(!choice.detailDescription.isEmpty)
        }
    }

    @Test func testLocalCredentialVaultStartFresh() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aurasense_vault_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let vault = LocalCredentialVault(fileURL: tempURL)
        #expect(vault.status == .uninitialized)
        #expect(vault.recordCount == 0)

        let newStatus = try vault.selectOnboardingChoice(.startFresh)
        #expect(newStatus == .configuredEmpty)
        #expect(vault.status == .configuredEmpty)

        try vault.addRecord(VaultCredentialRecord(relyingParty: "apple.com", username: "user@example.com", isPasskey: true))
        #expect(vault.recordCount == 1)

        // Reload from disk
        let vault2 = LocalCredentialVault(fileURL: tempURL)
        #expect(vault2.status == .configuredEmpty)
        #expect(vault2.recordCount == 1)
        #expect(vault2.listRecords().first?.isPasskey == true)
    }

    @Test func testLocalCredentialVaultSkipForNow() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aurasense_vault_skip_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let vault = LocalCredentialVault(fileURL: tempURL)
        let status = try vault.selectOnboardingChoice(.skipForNow)
        #expect(status == .skipped)
        #expect(vault.status == .skipped)
    }

    @Test func testPasswordSecretsAreStoredOutsideMetadata() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aurasense_vault_secret_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let vault = LocalCredentialVault(fileURL: fileURL, secretStore: MemorySecretStore())

        let record = try vault.storePassword("never-write-this", relyingParty: "example.com", username: "person")

        #expect(try vault.password(for: record.id) == "never-write-this")
        #expect(vault.listRecords().count == 1)
        #expect(!(try String(contentsOf: fileURL, encoding: .utf8)).contains("never-write-this"))
    }

    @Test func testSystemCredentialExchangeImportsPasswordItems() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aurasense_vault_import_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let vault = LocalCredentialVault(fileURL: fileURL, secretStore: MemorySecretStore())
        let username = ASImportableEditableField(id: nil, fieldType: .string, value: "person@example.com")
        let password = ASImportableEditableField(id: nil, fieldType: .concealedString, value: "imported-secret")
        let credential = ASImportableCredential.basicAuthentication(
            .init(userName: username, password: password)
        )
        let item = ASImportableItem(
            id: Data("item-1".utf8),
            created: Date(),
            lastModified: Date(),
            title: "Example account",
            scope: ASImportableCredentialScope(urls: [URL(string: "https://example.com/login")!]),
            credentials: [credential]
        )
        let account = ASImportableAccount(
            id: Data("account-1".utf8),
            userName: "person@example.com",
            email: "person@example.com",
            collections: [],
            items: [item]
        )
        let payload = ASExportedCredentialData(
            accounts: [account],
            formatVersion: .v1,
            exporterRelyingPartyIdentifier: "source.example",
            exporterDisplayName: "Source",
            timestamp: Date()
        )

        let result = try vault.importPasswords(from: payload)

        #expect(result.importedPasswordCount == 1)
        #expect(result.skippedItemCount == 0)
        #expect(vault.listRecords().first?.relyingParty == "example.com")
        #expect(try vault.password(for: vault.listRecords()[0].id) == "imported-secret")
    }
}
