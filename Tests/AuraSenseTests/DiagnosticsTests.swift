import Testing
import Foundation
@testable import AuraSenseCore

struct DiagnosticsTests {

    @Test func testRingBufferCap() {
        let diagnostics = DiagnosticsManager(maxEvents: 5)
        for i in 1...10 {
            diagnostics.log(category: "Test", message: "Event \(i)")
        }

        let events = diagnostics.recentEvents()
        #expect(events.count == 5)
        #expect(events.first?.message == "Event 6")
        #expect(events.last?.message == "Event 10")
    }

    @Test func testJSONSerialization() throws {
        let scanner = MockBLEScanner(initialRadioState: .poweredOn, initialAuthorization: .allowedAlways)
        let diagnostics = DiagnosticsManager()
        scanner.delegate = diagnostics

        _ = scanner.simulatePeripheralDiscovery(name: "JSON Device", rssi: -55)

        let snapshot = diagnostics.snapshot(from: scanner)
        let jsonString = snapshot.toJSON()
        #expect(!jsonString.isEmpty)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = jsonString.data(using: .utf8) else {
            Issue.record("Failed to extract utf8 data")
            return
        }

        let decoded = try decoder.decode(DiagnosticsSnapshot.self, from: data)
        #expect(decoded.radioState == .poweredOn)
        #expect(decoded.totalDiscoveredCount == 1)
        #expect(decoded.peripherals.first?.name == "JSON Device")
    }

    @Test func testFormattedReportOutput() {
        let scanner = MockBLEScanner(initialRadioState: .poweredOn, initialAuthorization: .allowedAlways)
        let diagnostics = DiagnosticsManager()
        scanner.delegate = diagnostics

        _ = scanner.simulatePeripheralDiscovery(name: "Table Device", rssi: -60)

        let snapshot = diagnostics.snapshot(from: scanner)
        let report = snapshot.formattedReport
        #expect(report.contains("AuraSense Proximity & BLE Diagnostics"))
        #expect(report.contains("Table Device"))
        #expect(report.contains("Auto-Lock Policy:     DISABLED"))
    }

    @Test func testSecurityGateReportingInSnapshot() throws {
        let scanner = MockBLEScanner(initialRadioState: .poweredOn, initialAuthorization: .allowedAlways)
        let store = InMemoryCandidateTrustStore()
        let candidateID = UUID()
        let candidate = CandidateDevice(id: candidateID, name: "VIP iPhone")
        try store.register(candidate: candidate)

        let diagnostics = DiagnosticsManager(trustStore: store)
        scanner.delegate = diagnostics

        // Discover candidate (admitted)
        _ = scanner.simulatePeripheralDiscovery(id: candidateID, name: "VIP iPhone", rssi: -50)
        // Discover untrusted device (blocked)
        _ = scanner.simulatePeripheralDiscovery(id: UUID(), name: "Unknown Rogue Device", rssi: -80)

        let snapshot = diagnostics.snapshot(from: scanner)
        #expect(snapshot.candidate?.id == candidateID)
        #expect(snapshot.gateAdmittedCount == 1)
        #expect(snapshot.gateBlockedCount == 1)
        #expect(snapshot.formattedReport.contains("VIP iPhone"))
        #expect(snapshot.formattedReport.contains("Security Gate Filter: Admitted: 1 | Blocked: 1"))
    }
}
