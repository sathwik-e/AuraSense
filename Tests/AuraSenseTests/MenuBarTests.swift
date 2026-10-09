import Testing
import Foundation
import AppKit
@testable import AuraSenseCore

struct MenuBarTests {

    @Test @MainActor func testMenuBarControllerInitAndStatusUpdates() {
        let trustStore = InMemoryCandidateTrustStore()
        let diagnostics = DiagnosticsManager(trustStore: trustStore)
        let settingsStore = InMemorySettingsStore()
        let launchManager = MockLaunchAtLoginManager()

        let controller = MenuBarController(
            diagnostics: diagnostics,
            settingsStore: settingsStore,
            launchAtLoginManager: launchManager
        )

        #expect(controller.statusItem.button != nil)
        #expect(controller.statusItem.menu != nil)

        // Initial state is UNKNOWN -> Compact button title is empty, accessibility describes state
        #expect(controller.statusItem.button?.title == "")
        #expect(controller.statusItem.button?.accessibilityLabel()?.contains("Unknown") == true)

        // Test status update to NEAR -> Compact button title remains empty, accessibility reflects NEAR
        controller.updateStatus(state: .near(smoothedRSSI: -50.0))
        #expect(controller.statusItem.button?.title == "")
        #expect(controller.statusItem.button?.accessibilityLabel()?.contains("NEAR") == true)

        // Test status update to COUNTDOWN -> Shows short countdown seconds in button, accessibility reflects countdown
        controller.updateCountdown(secondsRemaining: 4)
        #expect(controller.statusItem.button?.title == " ⏳ 4s")
        #expect(controller.statusItem.button?.accessibilityLabel()?.contains("4 seconds remaining") == true)

        // Test status update to FAR -> Compact button title is empty, accessibility reflects FAR
        controller.updateStatus(state: .far(dwellDuration: 10.0))
        #expect(controller.statusItem.button?.title == "")
        #expect(controller.statusItem.button?.accessibilityLabel()?.contains("FAR") == true)
    }

    @Test @MainActor func testMenuBarHierarchyAndSecurityLabels() throws {
        let candidate = CandidateDevice(id: UUID(), name: "Sathwik's iPhone")
        let trustStore = InMemoryCandidateTrustStore()
        let diagnostics = DiagnosticsManager(trustStore: trustStore)
        try diagnostics.registerCandidate(candidate)

        let settingsStore = InMemorySettingsStore()
        let launchManager = MockLaunchAtLoginManager()

        let controller = MenuBarController(
            diagnostics: diagnostics,
            settingsStore: settingsStore,
            launchAtLoginManager: launchManager
        )

        let menu = controller.statusItem.menu
        #expect(menu != nil)

        // Check that candidate menu item is present with honest security label
        let candidateItem = menu?.items.first(where: { $0.title.contains("Sathwik's iPhone") })
        #expect(candidateItem != nil)

        let securityItem = menu?.items.first(where: { $0.title.contains("Not cryptographically verified") })
        #expect(securityItem != nil)
    }

    @Test @MainActor func testMenuBarCountdownCancellation() throws {
        let candidate = CandidateDevice(id: UUID(), name: "Test Phone")
        let trustStore = InMemoryCandidateTrustStore()
        let config = ProximityEngineConfig(nearDwellDuration: 0.1, farDwellDuration: 1.0, countdownDuration: 5)
        let engine = ProximityEngine(config: config)
        let diagnostics = DiagnosticsManager(trustStore: trustStore, proximityEngine: engine)
        try diagnostics.registerCandidate(candidate)
        let settingsStore = InMemorySettingsStore()
        let launchManager = MockLaunchAtLoginManager()

        let controller = MenuBarController(
            diagnostics: diagnostics,
            settingsStore: settingsStore,
            launchAtLoginManager: launchManager
        )

        let start = Date()
        diagnostics.proximityEngine.updateScannerHealth(isHealthy: true)
        diagnostics.proximityEngine.processSample(rssi: -50, timestamp: start)
        diagnostics.proximityEngine.processSample(rssi: -50, timestamp: start.addingTimeInterval(0.2))
        #expect(diagnostics.proximityEngine.currentState.isNear)

        // Enter countdown
        diagnostics.proximityEngine.processSample(rssi: -85, timestamp: start.addingTimeInterval(1.0))
        diagnostics.proximityEngine.processSample(rssi: -85, timestamp: start.addingTimeInterval(2.5))
        diagnostics.proximityEngine.tick(currentTime: start.addingTimeInterval(2.5))

        controller.updateStatus(state: diagnostics.proximityEngine.currentState)
        #expect(diagnostics.proximityEngine.currentState.isCountdown)

        // Cancel countdown via user action
        diagnostics.proximityEngine.userCancelCountdown()
        controller.updateStatus(state: diagnostics.proximityEngine.currentState)
        #expect(diagnostics.proximityEngine.currentState.isNear)
        #expect(controller.statusItem.button?.title == "")
    }
}
