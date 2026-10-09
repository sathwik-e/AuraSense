import Testing
import Foundation
@testable import AuraSenseCore

struct BLEDiscoveryTests {

    @Test func testScanLifecycle() throws {
        let scanner = MockBLEScanner(initialRadioState: .poweredOn, initialAuthorization: .allowedAlways)
        #expect(!scanner.isScanning)

        try scanner.startScanning()
        #expect(scanner.isScanning)

        scanner.stopScanning()
        #expect(!scanner.isScanning)
    }

    @Test func testScanFailsWhenRadioOff() {
        let scanner = MockBLEScanner(initialRadioState: .poweredOff, initialAuthorization: .allowedAlways)
        #expect(throws: BLEScannerError.self) {
            try scanner.startScanning()
        }
    }

    @Test func testScanFailsWhenUnauthorized() {
        let scanner = MockBLEScanner(initialRadioState: .poweredOn, initialAuthorization: .denied)
        #expect(throws: BLEScannerError.self) {
            try scanner.startScanning()
        }
    }

    @Test func testPeripheralDiscoveryAndRSSI() throws {
        let scanner = MockBLEScanner()
        let diagnostics = DiagnosticsManager()
        scanner.delegate = diagnostics

        try scanner.startScanning()

        let deviceID = UUID()
        _ = scanner.simulatePeripheralDiscovery(
            id: deviceID,
            name: "Test iPhone",
            rssi: -62,
            services: ["180D"]
        )

        let registered = diagnostics.registry.peripheral(for: deviceID)
        #expect(registered != nil)
        #expect(registered?.name == "Test iPhone")
        #expect(registered?.latestRSSI == -62)
        #expect(registered?.latestAdvertisement.serviceUUIDs.contains("180D") == true)

        // Continuous RSSI observations
        scanner.simulateRSSIUpdate(peripheralID: deviceID, rssi: -58)
        scanner.simulateRSSIUpdate(peripheralID: deviceID, rssi: -60)

        let updated = diagnostics.registry.peripheral(for: deviceID)
        #expect(updated?.latestRSSI == -60)
        #expect(updated?.rssiHistory.count == 3)
        #expect(updated?.averageRSSI == (-62.0 - 58.0 - 60.0) / 3.0)
    }

    @Test func testRSSIHistoryCap() {
        var peripheral = DiscoveredPeripheral(
            id: UUID(),
            name: "Device",
            latestRSSI: -70
        )

        for i in 1...60 {
            peripheral.recordReading(rssi: -70 + (i % 5), timestamp: Date(), advertisement: nil, maxHistory: 20)
        }

        #expect(peripheral.rssiHistory.count == 20)
    }

    @Test func testUnauthorizedStartDoesNotAutoScanOnRadioRecovery() {
        // Finding 17: Unauthorized scan attempt must clear monitoring intent and not auto-start
        let scanner = MockBLEScanner(initialRadioState: .poweredOn, initialAuthorization: .denied)
        #expect(!scanner.isScanning)
        #expect(!scanner.isMonitoringRequested)

        #expect(throws: BLEScannerError.self) {
            try scanner.startScanning()
        }
        #expect(!scanner.isMonitoringRequested)

        // Radio cycles off and then back on
        scanner.simulateRadioStateChange(.poweredOff)
        scanner.simulateRadioStateChange(.poweredOn)

        // Since intent was not granted, scanner MUST NOT auto-start
        #expect(!scanner.isScanning)
        #expect(!scanner.isMonitoringRequested)
    }

    @Test func testMockScannerClearsMonitoringIntentOnAuthorizationDenial() throws {
        let scanner = MockBLEScanner(initialRadioState: .poweredOn, initialAuthorization: .allowedAlways)
        try scanner.startScanning()
        #expect(scanner.isMonitoringRequested)
        #expect(scanner.isScanning)

        scanner.simulateAuthorizationChange(.denied)
        #expect(!scanner.isMonitoringRequested)
        #expect(!scanner.isScanning)
        scanner.simulateRadioStateChange(.poweredOff)
        scanner.simulateRadioStateChange(.poweredOn)
        #expect(!scanner.isScanning)
    }

    @Test func testNonCandidateDuplicateBurstIsCoalescedWhileCandidatePreserved() throws {
        // Finding 16: Coalesce rapid non-candidate duplicate bursts while preserving candidate packet cadence
        let scanner = MockBLEScanner()
        let trustStore = InMemoryCandidateTrustStore()
        let diagnostics = DiagnosticsManager(trustStore: trustStore)
        scanner.delegate = diagnostics

        let candidateID = UUID()
        let candidate = CandidateDevice(id: candidateID, name: "Trusted Phone")
        try diagnostics.registerCandidate(candidate)

        let nonCandidateID = UUID()
        let now = Date()

        // Non-candidate bursts 10 discovery packets within 100ms
        for i in 0..<10 {
            _ = scanner.simulatePeripheralDiscovery(
                id: nonCandidateID,
                name: "Noisy Beacon",
                rssi: -75,
                timestamp: now.addingTimeInterval(Double(i) * 0.01)
            )
        }

        // Candidate bursts 10 discovery packets within 100ms
        for i in 0..<10 {
            _ = scanner.simulatePeripheralDiscovery(
                id: candidateID,
                name: "Trusted Phone",
                rssi: -55,
                timestamp: now.addingTimeInterval(Double(i) * 0.01)
            )
        }

        // Non-candidate must be coalesced (only 1 packet registered in 1s window)
        let nonCandidateRecord = diagnostics.registry.peripheral(for: nonCandidateID)
        #expect(nonCandidateRecord?.advertisementCount == 1)

        // Candidate must NOT be coalesced (all 10 packets preserved for proximity accuracy)
        let candidateRecord = diagnostics.registry.peripheral(for: candidateID)
        #expect(candidateRecord?.advertisementCount == 10)
    }
}
