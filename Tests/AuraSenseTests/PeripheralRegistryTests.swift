import Testing
import Foundation
@testable import AuraSenseCore

struct PeripheralRegistryTests {

    @Test func testSignalCalculations() {
        let registry = PeripheralRegistry()
        let id = UUID()

        let peripheral = DiscoveredPeripheral(
            id: id,
            name: "Beacon",
            latestRSSI: -80,
            firstSeen: Date(),
            lastSeen: Date(),
            advertisementCount: 1,
            latestAdvertisement: AdvertisementData(),
            rssiHistory: [
                RSSIReading(rssi: -80),
                RSSIReading(rssi: -70),
                RSSIReading(rssi: -60)
            ]
        )

        registry.registerOrUpdate(peripheral)

        let records = registry.diagnosticsRecords()
        #expect(records.count == 1)
        #expect(records[0].minRSSI == -80)
        #expect(records[0].maxRSSI == -60)
        #expect(records[0].averageRSSI == -70.0)
    }

    @Test func testLivenessCategorization() {
        let now = Date()
        let idActive = UUID()
        let idStale = UUID()
        let idLost = UUID()

        let activeDev = DiscoveredPeripheral(
            id: idActive,
            name: "ActiveDev",
            latestRSSI: -50,
            firstSeen: now.addingTimeInterval(-20),
            lastSeen: now.addingTimeInterval(-2)
        )

        let staleDev = DiscoveredPeripheral(
            id: idStale,
            name: "StaleDev",
            latestRSSI: -75,
            firstSeen: now.addingTimeInterval(-60),
            lastSeen: now.addingTimeInterval(-15)
        )

        let lostDev = DiscoveredPeripheral(
            id: idLost,
            name: "LostDev",
            latestRSSI: -90,
            firstSeen: now.addingTimeInterval(-120),
            lastSeen: now.addingTimeInterval(-45)
        )

        let recordActive = PeripheralDiagnosticsRecord(from: activeDev, referenceDate: now)
        let recordStale = PeripheralDiagnosticsRecord(from: staleDev, referenceDate: now)
        let recordLost = PeripheralDiagnosticsRecord(from: lostDev, referenceDate: now)

        #expect(recordActive.liveness == .active)
        #expect(recordStale.liveness == .stale)
        #expect(recordLost.liveness == .lost)
    }

    @Test func testSortingByRSSI() {
        let registry = PeripheralRegistry()
        let pWeak = DiscoveredPeripheral(id: UUID(), name: "Weak", latestRSSI: -85)
        let pStrong = DiscoveredPeripheral(id: UUID(), name: "Strong", latestRSSI: -45)
        let pMedium = DiscoveredPeripheral(id: UUID(), name: "Medium", latestRSSI: -65)

        registry.registerOrUpdate(pWeak)
        registry.registerOrUpdate(pStrong)
        registry.registerOrUpdate(pMedium)

        let records = registry.diagnosticsRecords()
        #expect(records.count == 3)
        #expect(records[0].name == "Strong")
        #expect(records[1].name == "Medium")
        #expect(records[2].name == "Weak")
    }
}
