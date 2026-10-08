import Testing
import Foundation
@testable import AuraSenseCore

struct SecurityConstraintTests {

    @Test func testLockAndCredentialNotSupportedInPhase1() {
        let provider = Phase1RestrictedActionProvider()
        #expect(!provider.isLockSupported)
        #expect(!provider.isWakeSupported)
        #expect(!provider.isCredentialEntrySupported)
    }

    @Test func testRequestLockThrowsPhase1Violation() async {
        let provider = Phase1RestrictedActionProvider()
        do {
            _ = try await provider.requestLock()
            Issue.record("Expected requestLock to throw ActionError.phase1ConstraintViolation")
        } catch let error as ActionError {
            switch error {
            case .phase1ConstraintViolation:
                #expect(true)
            default:
                Issue.record("Unexpected ActionError: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func testRequestCredentialEntryThrowsPhase1Violation() async {
        let provider = Phase1RestrictedActionProvider()
        do {
            _ = try await provider.requestCredentialEntry()
            Issue.record("Expected requestCredentialEntry to throw ActionError.phase1ConstraintViolation")
        } catch let error as ActionError {
            switch error {
            case .phase1ConstraintViolation:
                #expect(true)
            default:
                Issue.record("Unexpected ActionError: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func testCandidateDeviceExplicitlyNotCryptographicallyVerified() {
        let candidate = CandidateDevice(id: UUID(), name: "Sathwik's iPhone")
        // Enforce ARCHITECTURE.md rule: UI/Code must NEVER claim cryptographic verification for Mac-only BLE
        #expect(!candidate.isCryptographicallyVerified)
        #expect(!candidate.securityDisclaimer.isEmpty)
    }

    @Test func testPhase1TrustStoreBlocksAllPeripherals() {
        let trustStore = Phase1TrustStore()
        let randomDeviceID = UUID()

        #expect(!trustStore.isCandidate(peripheralID: randomDeviceID))
        #expect(trustStore.selectedCandidate() == nil)
    }

    @Test func testClassifierDetectsDirectMatch() {
        let candidateID = UUID()
        let candidate = CandidateDevice(id: candidateID, name: "Target iPhone")
        let classifier = AdvertisementClassifier(candidate: candidate)

        let targetPeripheral = DiscoveredPeripheral(id: candidateID, name: "Target iPhone", latestRSSI: -55)
        let classification = classifier.classify(peripheral: targetPeripheral, allActivePeripherals: [targetPeripheral])

        #expect(classification == .matched(candidate))
    }

    @Test func testClassifierDetectsAmbiguityOnMultipleMatchingPeers() {
        let candidateID = UUID()
        let candidate = CandidateDevice(id: candidateID, name: "Sathwik's iPhone")
        let classifier = AdvertisementClassifier(candidate: candidate)

        let realDevice = DiscoveredPeripheral(id: candidateID, name: "Sathwik's iPhone", latestRSSI: -50)
        let spoofedDevice = DiscoveredPeripheral(id: UUID(), name: "Sathwik's iPhone", latestRSSI: -45)

        let allActive = [realDevice, spoofedDevice]
        let classification = classifier.classify(peripheral: realDevice, allActivePeripherals: allActive)

        switch classification {
        case .ambiguous(let count, _):
            #expect(count == 2)
        default:
            Issue.record("Expected ambiguous classification when multiple devices advertise the same candidate name")
        }
    }
}
