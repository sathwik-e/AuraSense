import Testing
import Foundation
@testable import AuraSenseCore

struct SecurityActionGateTests {

    @Test func testGateBlocksWhenNoCandidateRegistered() {
        let store = InMemoryCandidateTrustStore()
        let gate = SecurityActionGate(trustStore: store)

        let peripheral = DiscoveredPeripheral(id: UUID(), name: "Random Device", latestRSSI: -50)
        let decision = gate.evaluate(peripheral: peripheral, allActivePeripherals: [peripheral])

        #expect(!decision.isAdmitted)
        #expect(decision == .blocked(.noCandidateRegistered))
        #expect(gate.admittedCount == 0)
        #expect(gate.blockedCount == 1)
    }

    @Test func testGateAdmitsOnlyRegisteredCandidate() throws {
        let store = InMemoryCandidateTrustStore()
        let targetID = UUID()
        let candidate = CandidateDevice(id: targetID, name: "Target Phone")
        try store.register(candidate: candidate)

        let gate = SecurityActionGate(trustStore: store)

        let targetPeripheral = DiscoveredPeripheral(id: targetID, name: "Target Phone", latestRSSI: -55)
        let otherPeripheral = DiscoveredPeripheral(id: UUID(), name: "Other Phone", latestRSSI: -45)

        // Evaluate target
        let targetDecision = gate.evaluate(peripheral: targetPeripheral, allActivePeripherals: [targetPeripheral])
        #expect(targetDecision.isAdmitted)
        #expect(targetDecision == .admitted(candidate: candidate, peripheralID: targetID, rssi: -55))

        // Evaluate other
        let otherDecision = gate.evaluate(peripheral: otherPeripheral, allActivePeripherals: [targetPeripheral, otherPeripheral])
        #expect(!otherDecision.isAdmitted)
        #expect(gate.admittedCount == 1)
        #expect(gate.blockedCount == 1)
    }

    @Test func testGateBlocksAmbiguousConflictingPeers() throws {
        let store = InMemoryCandidateTrustStore()
        let targetID = UUID()
        let candidate = CandidateDevice(id: targetID, name: "Target Phone")
        try store.register(candidate: candidate)

        let gate = SecurityActionGate(trustStore: store)

        let realDevice = DiscoveredPeripheral(id: targetID, name: "Target Phone", latestRSSI: -50)
        let spoofedDevice = DiscoveredPeripheral(id: UUID(), name: "Target Phone", latestRSSI: -45)

        let allActive = [realDevice, spoofedDevice]

        let decision = gate.evaluate(peripheral: realDevice, allActivePeripherals: allActive)
        #expect(!decision.isAdmitted)

        switch decision {
        case .blocked(let reason):
            switch reason {
            case .ambiguousCandidate(let count, _):
                #expect(count == 2)
            default:
                Issue.record("Expected .ambiguousCandidate reason")
            }
        default:
            Issue.record("Expected gate to block ambiguous device")
        }

        #expect(gate.ambiguityCount == 1)
        #expect(gate.admittedCount == 0)
    }

    @Test func testResetMetricsClearsCounters() throws {
        let store = InMemoryCandidateTrustStore()
        let targetID = UUID()
        let candidate = CandidateDevice(id: targetID, name: "Phone")
        try store.register(candidate: candidate)

        let gate = SecurityActionGate(trustStore: store)
        let p = DiscoveredPeripheral(id: targetID, name: "Phone", latestRSSI: -60)
        _ = gate.evaluate(peripheral: p, allActivePeripherals: [p])

        #expect(gate.admittedCount == 1)
        gate.resetMetrics()
        #expect(gate.admittedCount == 0)
        #expect(gate.blockedCount == 0)
        #expect(gate.ambiguityCount == 0)
    }
}
