import Testing
import Foundation
@testable import AuraSenseCore

struct CredentialVaultTests {

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

        vault.addRecord(VaultCredentialRecord(relyingParty: "apple.com", username: "user@example.com", isPasskey: true))
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
}
