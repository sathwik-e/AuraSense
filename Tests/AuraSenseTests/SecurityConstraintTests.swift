import Testing
import Foundation
@testable import AuraSenseCore

struct SecurityConstraintTests {

    @Test func testLockNotSupportedInPhase1() {
        let provider = Phase1RestrictedActionProvider()
        #expect(!provider.isLockSupported)
    }

    @Test func testLockScreenThrowsViolation() async {
        let provider = Phase1RestrictedActionProvider()
        do {
            _ = try await provider.lockScreen()
            Issue.record("Expected lockScreen to throw ActionError.phase1ConstraintViolation")
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

    @Test func testUntrustedPeripheralsBlocked() {
        let trustStore = Phase1TrustStore()
        let randomDeviceID = UUID()

        #expect(!trustStore.isTrusted(peripheralID: randomDeviceID))
        #expect(trustStore.enrolledIdentity() == nil)
    }

    @Test func testUntrustedDiscoveryOnlyPopulatesDiagnostics() {
        let scanner = MockBLEScanner()
        let diagnostics = DiagnosticsManager()
        scanner.delegate = diagnostics

        let unknownPeripheralID = UUID()
        _ = scanner.simulatePeripheralDiscovery(
            id: unknownPeripheralID,
            name: "Malicious / Unknown Device",
            rssi: -40
        )

        // Verify device is in diagnostics registry
        #expect(diagnostics.registry.peripheral(for: unknownPeripheralID) != nil)

        // Verify it remains untrusted
        let trustStore = Phase1TrustStore()
        #expect(!trustStore.isTrusted(peripheralID: unknownPeripheralID))
    }
}
