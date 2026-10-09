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
        #expect(controller.statusItem.menu == nil)
        #expect(controller.popover.contentViewController != nil)

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

    @Test @MainActor func testPopoverShowsTrustedPhoneAndSecurityState() throws {
        let candidate = CandidateDevice(id: UUID(), name: "Sathwik's iPhone")
        let trustStore = InMemoryCandidateTrustStore()
        let diagnostics = DiagnosticsManager(
            trustStore: trustStore,
            policyEngine: PolicyEngine(actionProvider: MockActionProvider(isLockSupported: false))
        )
        try diagnostics.registerCandidate(candidate)

        let settingsStore = InMemorySettingsStore()
        let launchManager = MockLaunchAtLoginManager()

        let controller = MenuBarController(
            diagnostics: diagnostics,
            settingsStore: settingsStore,
            launchAtLoginManager: launchManager
        )

        guard let root = controller.popover.contentViewController?.view else {
            Issue.record("Expected popover content")
            return
        }
        let strings = textValues(in: root)
        #expect(strings.contains(where: { $0.contains("Sathwik's iPhone") }))
        #expect(strings.contains(where: { $0.contains("not unlock") }))
        #expect(strings.contains(where: { $0.contains("Change trusted iPhone") }))
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

    @Test @MainActor func testPopoverShowsLivePhoneSetupAction() throws {
        let trustStore = InMemoryCandidateTrustStore()
        let diagnostics = DiagnosticsManager(trustStore: trustStore)
        let peerID = UUID()
        diagnostics.registry.registerOrUpdate(DiscoveredPeripheral(
            id: peerID,
            name: "My iPhone",
            latestRSSI: -54,
            latestAdvertisement: AdvertisementData(serviceUUIDs: ["180F"])
        ))
        let controller = MenuBarController(
            diagnostics: diagnostics,
            settingsStore: InMemorySettingsStore(),
            launchAtLoginManager: MockLaunchAtLoginManager()
        )
        guard let button = controller.statusItem.button else {
            Issue.record("Expected status item button")
            return
        }
        #expect(button.action != nil)
        controller.showPopover()
        guard let root = controller.popover.contentViewController?.view else {
            Issue.record("Expected popover content")
            return
        }
        #expect(textValues(in: root).contains(where: { $0.contains("Choose your iPhone") }))
        #expect(textValues(in: root).contains(where: { $0.contains("Open AuraSense") }))
        #expect(trustStore.registeredCandidate == nil)
        #expect(MenuBarController.createMenuBarTemplateImage().isTemplate)
        controller.popover.performClose(nil)
    }

    @Test @MainActor func testDashboardShowsTrustedDeviceAndUnlockBoundary() throws {
        let peerID = UUID()
        let trustStore = InMemoryCandidateTrustStore()
        let diagnostics = DiagnosticsManager(
            trustStore: trustStore,
            policyEngine: PolicyEngine(actionProvider: MockActionProvider(isLockSupported: false))
        )
        try diagnostics.registerCandidate(CandidateDevice(id: peerID, name: "My iPhone"))
        diagnostics.registry.registerOrUpdate(DiscoveredPeripheral(
            id: peerID,
            name: "My iPhone",
            latestRSSI: -48,
            latestAdvertisement: AdvertisementData(serviceUUIDs: ["180F"])
        ))

        let dashboard = AuraSenseDashboardWindowController(
            diagnostics: diagnostics,
            scanner: MockBLEScanner(),
            settingsStore: InMemorySettingsStore(),
            launchAtLoginManager: MockLaunchAtLoginManager(),
            onSetupPhone: {},
            onClose: {}
        )

        let strings = textValues(in: dashboard.window!.contentView!)
        #expect(strings.contains("My iPhone"))
        #expect(strings.contains(where: { $0.contains("-48 dBm") }))
        #expect(strings.contains(where: { $0.contains("cannot unlock a macOS session") }))
        #expect(strings.contains("Lock this Mac when my iPhone leaves"))
    }

    private func textValues(in view: NSView) -> [String] {
        let value = (view as? NSTextField)?.stringValue ?? (view as? NSButton)?.title ?? ""
        return [value] + view.subviews.flatMap(textValues(in:))
    }
}
