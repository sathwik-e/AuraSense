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

        // Test status update to NEAR
        controller.updateStatus(state: .near(smoothedRSSI: -50.0))
        #expect(controller.statusItem.button?.title == "AuraSense: NEAR")

        // Test status update to COUNTDOWN
        controller.updateCountdown(secondsRemaining: 4)
        #expect(controller.statusItem.button?.title == "AuraSense: ⏳ 4s")

        // Test status update to FAR
        controller.updateStatus(state: .far(dwellDuration: 10.0))
        #expect(controller.statusItem.button?.title == "AuraSense: FAR")
    }
}
