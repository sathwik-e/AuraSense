import Testing
import Foundation
@testable import AuraSenseCore

struct SecureAuthenticationTests {

    @Test func testSessionStateDefaults() {
        let state = SessionState()
        #expect(!state.isScreenLocked)
        #expect(state.isOnConsole)
        #expect(state.isLoginDone)
        #expect(state.username == nil)
    }

    @Test func testMacOSLockScreenDetectorQuery() {
        let detector = MacOSLockScreenStateDetector()
        let state = detector.currentSessionState()

        // Verify query executes safely without throwing or crashing
        #expect(state.isOnConsole || !state.isOnConsole)
        if let username = state.username {
            #expect(!username.isEmpty)
        }
    }

    @Test func testMockLockScreenDetectorToggle() {
        let detector = MockLockScreenStateDetector(state: SessionState(isScreenLocked: false))
        #expect(!detector.currentSessionState().isScreenLocked)

        detector.state = SessionState(isScreenLocked: true, isOnConsole: true, username: "testuser")
        let updated = detector.currentSessionState()
        #expect(updated.isScreenLocked)
        #expect(updated.username == "testuser")
    }

    @Test func testSecureAuthenticationCoordinatorPath() {
        let coordinator = SecureAuthenticationCoordinator()
        let path = coordinator.evaluateUnlockPath()

        #expect(path == .nativeDisplayWakeBiometric)
        #expect(path != .plaintextPasswordInjectionProhibited)
    }

    @Test func testCredentialEntryAttemptIsStrictlyRejected() {
        let coordinator = SecureAuthenticationCoordinator()

        do {
            try coordinator.validateCredentialEntryAttempt()
            Issue.record("Expected credential entry validation to throw ActionError")
        } catch let error as ActionError {
            if case .actionDisabled(let reason) = error {
                #expect(reason.contains("Plaintext password storage and injection are strictly prohibited"))
            } else {
                Issue.record("Expected ActionError.actionDisabled")
            }
        } catch {
            Issue.record("Unexpected error thrown: \(error)")
        }
    }

    @Test func testMacOSActionAdapterCredentialEntryRemainsDisabled() async {
        let adapter = MacOSActionAdapter(isDryRun: true)
        #expect(!adapter.isCredentialEntrySupported)

        do {
            _ = try await adapter.requestCredentialEntry()
            Issue.record("Expected requestCredentialEntry to throw ActionError")
        } catch let error as ActionError {
            if case .actionDisabled(let reason) = error {
                #expect(reason.contains("Phase 5") || reason.contains("Phase 6"))
            } else {
                Issue.record("Expected ActionError.actionDisabled")
            }
        } catch {
            Issue.record("Unexpected error thrown: \(error)")
        }
    }

    @Test func testDiagnosticsReportIncludesAuthAndZeroPlaintextPolicy() {
        let scanner = MockBLEScanner(initialRadioState: .poweredOn, initialAuthorization: .allowedAlways)
        let mockDetector = MockLockScreenStateDetector(state: SessionState(isScreenLocked: true, isOnConsole: true))
        let coordinator = SecureAuthenticationCoordinator(detector: mockDetector)
        let diagnostics = DiagnosticsManager(authCoordinator: coordinator)
        scanner.delegate = diagnostics

        let snapshot = diagnostics.snapshot(from: scanner)
        let report = snapshot.formattedReport

        #expect(snapshot.sessionState.isScreenLocked)
        #expect(report.contains("Secure Auth Path:     Native Display Wake & Biometric/Touch ID Prompt"))
        #expect(report.contains("Session State:        Locked: YES | Console: YES"))
        #expect(report.contains("Credential Policy:    ZERO_PLAINTEXT"))
    }
}
