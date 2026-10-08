import Testing
import Foundation
@testable import AuraSenseCore

struct RSSIFilterTests {

    @Test func testMedianFilterRejectsSpikeOutlier() {
        let config = ProximityEngineConfig(medianWindowSize: 5, ewmaAlpha: 0.5)
        let filter = RSSIFilter(config: config)
        let now = Date()

        // Feed consistent baseline around -70 dBm
        _ = filter.addSample(rssi: -70, timestamp: now)
        _ = filter.addSample(rssi: -71, timestamp: now.addingTimeInterval(0.2))
        _ = filter.addSample(rssi: -69, timestamp: now.addingTimeInterval(0.4))

        // Inject sudden isolated RF spike outlier (e.g. -20 dBm)
        let smoothedWithSpike = filter.addSample(rssi: -20, timestamp: now.addingTimeInterval(0.6))
        #expect(smoothedWithSpike != nil)

        // Median among [-70, -71, -69, -20] is around -70, NOT -20!
        // Smoothed RSSI should remain near -70 dBm
        #expect(smoothedWithSpike! <= -60.0)
    }

    @Test func testEWMASmoothingGradualConvergence() {
        let config = ProximityEngineConfig(medianWindowSize: 3, ewmaAlpha: 0.25)
        let filter = RSSIFilter(config: config)
        let now = Date()

        // Start at -80 dBm
        _ = filter.addSample(rssi: -80, timestamp: now)
        _ = filter.addSample(rssi: -80, timestamp: now.addingTimeInterval(0.1))
        _ = filter.addSample(rssi: -80, timestamp: now.addingTimeInterval(0.2))
        let initial = filter.currentSmoothedRSSI
        #expect(initial == -80.0)

        // Step change to -50 dBm
        _ = filter.addSample(rssi: -50, timestamp: now.addingTimeInterval(0.3))
        _ = filter.addSample(rssi: -50, timestamp: now.addingTimeInterval(0.4))
        let intermediate = filter.currentSmoothedRSSI!

        // Smoothed value gradually climbs towards -50 without jumping instantly
        #expect(intermediate > -80.0)
        #expect(intermediate < -50.0)
    }

    @Test func testLargeTimeGapResetsFilterMemory() {
        let config = ProximityEngineConfig(maxGapDuration: 5.0)
        let filter = RSSIFilter(config: config)
        let start = Date()

        _ = filter.addSample(rssi: -50, timestamp: start)
        #expect(filter.currentSmoothedRSSI == -50.0)

        // Add sample after 10-second absence (> 5s maxGap)
        _ = filter.addSample(rssi: -85, timestamp: start.addingTimeInterval(10.0))

        // Memory was reset, smoothed value starts directly from new sample
        #expect(filter.currentSmoothedRSSI == -85.0)
    }

    @Test func testInvalidRSSIValuesIgnored() {
        let filter = RSSIFilter()
        let now = Date()

        // Positive or impossibly low RSSI
        _ = filter.addSample(rssi: 10, timestamp: now)
        #expect(filter.currentSmoothedRSSI == nil)

        _ = filter.addSample(rssi: -150, timestamp: now)
        #expect(filter.currentSmoothedRSSI == nil)
    }
}
