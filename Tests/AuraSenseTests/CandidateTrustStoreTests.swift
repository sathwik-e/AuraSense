import Testing
import Foundation
@testable import AuraSenseCore

struct CandidateTrustStoreTests {

    @Test func testInMemoryTrustStoreLifecycle() throws {
        let store = InMemoryCandidateTrustStore()
        #expect(store.registeredCandidate == nil)

        let candidateID = UUID()
        let candidate = CandidateDevice(id: candidateID, name: "Test iPhone")

        try store.register(candidate: candidate)
        #expect(store.registeredCandidate == candidate)
        #expect(store.isRegistered(peripheralID: candidateID))
        #expect(!store.isRegistered(peripheralID: UUID()))

        try store.unregister()
        #expect(store.registeredCandidate == nil)
        #expect(!store.isRegistered(peripheralID: candidateID))
    }

    @Test func testPersistentTrustStoreSavesAndReloads() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storeURL = tempDir.appendingPathComponent("test_candidate.json")

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let candidateID = UUID()
        let candidate = CandidateDevice(id: candidateID, name: "Persistent iPhone")

        // First instance saves
        let store1 = PersistentCandidateTrustStore(storageURL: storeURL)
        #expect(store1.registeredCandidate == nil)
        try store1.register(candidate: candidate)
        #expect(store1.registeredCandidate == candidate)

        // Second instance loads from disk
        let store2 = PersistentCandidateTrustStore(storageURL: storeURL)
        #expect(store2.registeredCandidate?.id == candidateID)
        #expect(store2.registeredCandidate?.name == "Persistent iPhone")
        #expect(store2.isRegistered(peripheralID: candidateID))

        // Unregister removes file
        try store2.unregister()
        #expect(store2.registeredCandidate == nil)
        #expect(!FileManager.default.fileExists(atPath: storeURL.path))
    }
}
