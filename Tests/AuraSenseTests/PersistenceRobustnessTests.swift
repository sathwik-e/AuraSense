import Testing
import Foundation
@testable import AuraSenseCore

struct PersistenceRobustnessTests {

    @Test func testCorruptJSONInTrustStoreFailsClosedAndReportsError() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storeURL = tempDir.appendingPathComponent("corrupt_candidate.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Write corrupt/malformed bytes to the candidate file
        let corruptData = "{\"not_a_valid_candidate\": 12345, incomplete".data(using: .utf8)!
        try corruptData.write(to: storeURL)

        // Initialize store pointing to corrupt file
        let store = PersistentCandidateTrustStore(storageURL: storeURL)

        // Must fail closed with no candidate admitted
        #expect(store.registeredCandidate == nil)
        #expect(store.lastLoadError == .invalidCandidateData)

        // Recovery path
        try store.recoverCorruptStore()
        #expect(store.registeredCandidate == nil)
        #expect(store.lastLoadError == nil)
        #expect(!FileManager.default.fileExists(atPath: storeURL.path))
    }

    @Test func testTrustStoreWriteFailureProducesExplicitError() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a regular file where the directory would be expected, causing write collision
        let blockingFilePath = tempDir.appendingPathComponent("blocked_dir")
        try "blocker".write(to: blockingFilePath, atomically: true, encoding: .utf8)

        let unwritableURL = blockingFilePath.appendingPathComponent("candidate.json")
        let store = PersistentCandidateTrustStore(storageURL: unwritableURL)

        let candidate = CandidateDevice(id: UUID(), name: "Unwritable Phone")
        do {
            try store.register(candidate: candidate)
            Issue.record("Expected registration to throw error for unwritable path")
        } catch let error as TrustStoreError {
            if case .persistenceFailed = error {
                // Expected explicit error
            } else {
                Issue.record("Expected .persistenceFailed error")
            }
        } catch {
            Issue.record("Unexpected error thrown: \(error)")
        }
    }

    @Test func testCredentialVaultImportStatusIsNotImportedBeforeActualHandoff() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("vault_import_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let vault = LocalCredentialVault(fileURL: tempURL)
        #expect(vault.status == .uninitialized)

        // Selecting import existing credentials must NOT claim .imported
        let status = try vault.selectOnboardingChoice(.importExistingCredentials)
        #expect(status == .pendingImport)
        #expect(vault.status == .pendingImport)

        // Cancellation returns to uninitialized
        let cancelStatus = try vault.cancelImport()
        #expect(cancelStatus == .uninitialized)
        #expect(vault.status == .uninitialized)
    }

    @Test func testCredentialVaultMetadataWriteFailureProducesExplicitError() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let blockerPath = tempDir.appendingPathComponent("vault_blocker")
        try "blocking file".write(to: blockerPath, atomically: true, encoding: .utf8)

        let unwritableVaultURL = blockerPath.appendingPathComponent("vault_metadata.json")
        let vault = LocalCredentialVault(fileURL: unwritableVaultURL)

        do {
            _ = try vault.selectOnboardingChoice(.startFresh)
            Issue.record("Expected write failure to throw error")
        } catch let error as VaultError {
            if case .persistenceFailed = error {
                #expect(vault.lastPersistenceError != nil)
            } else {
                Issue.record("Expected VaultError.persistenceFailed")
            }
        } catch {
            Issue.record("Unexpected error thrown: \(error)")
        }
    }
}
