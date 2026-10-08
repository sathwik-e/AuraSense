import Testing
import Foundation
@testable import AuraSenseCore

struct ProximityEngineTests {

    @Test func testInitialStateIsUnknown() {
        let engine = ProximityEngine()
        #expect(engine.currentState.isUnknown)
    }

    @Test func testNearGateTransitionWithDwell() {
        let config = ProximityEngineConfig(
            nearGateRSSI: -60.0,
            nearDwellDuration: 2.0,
            medianWindowSize: 3,
            ewmaAlpha: 0.5
        )
        let engine = ProximityEngine(config: config)
        engine.updateScannerHealth(isHealthy: true)
        engine.updateCandidateAvailability(hasCandidate: true)

        let start = Date()

        // 1. First sample above near gate (-55 dBm)
        engine.processSample(rssi: -55, timestamp: start)
        #expect(engine.currentState.isUnknown) // Still within dwell window

        // 2. Sample within dwell window (1.0 second elapsed < 2.0s dwell)
        engine.processSample(rssi: -54, timestamp: start.addingTimeInterval(1.0))
        #expect(engine.currentState.isUnknown)

        // 3. Sample after dwell requirement satisfied (2.1 seconds elapsed)
        engine.processSample(rssi: -52, timestamp: start.addingTimeInterval(2.1))
        #expect(engine.currentState.isNear)
    }

    @Test func testHysteresisDeadBandHoldsNear() {
        let config = ProximityEngineConfig(
            nearGateRSSI: -60.0,
            farGateRSSI: -75.0,
            nearDwellDuration: 0.1
        )
        let engine = ProximityEngine(config: config)
        engine.updateScannerHealth(isHealthy: true)
        engine.updateCandidateAvailability(hasCandidate: true)

        let start = Date()
        // Establish NEAR state
        engine.processSample(rssi: -50, timestamp: start)
        engine.processSample(rssi: -50, timestamp: start.addingTimeInterval(0.2))
        #expect(engine.currentState.isNear)

        // Signal drops into hysteresis dead band (-68 dBm, between -60 and -75)
        engine.processSample(rssi: -68, timestamp: start.addingTimeInterval(1.0))
        engine.processSample(rssi: -68, timestamp: start.addingTimeInterval(2.0))

        // State remains NEAR without flapping
        #expect(engine.currentState.isNear)
    }

    @Test func testTemporarySignalLossRecoversWithoutCountdown() {
        let config = ProximityEngineConfig(
            nearGateRSSI: -60.0,
            farGateRSSI: -75.0,
            nearDwellDuration: 0.1,
            farDwellDuration: 5.0
        )
        let engine = ProximityEngine(config: config)
        engine.updateScannerHealth(isHealthy: true)
        engine.updateCandidateAvailability(hasCandidate: true)

        let start = Date()
        engine.processSample(rssi: -55, timestamp: start)
        engine.processSample(rssi: -55, timestamp: start.addingTimeInterval(0.2))
        #expect(engine.currentState.isNear)

        // Temporary weak signal or packet loss for 2 seconds (< 5s far dwell)
        engine.processSample(rssi: -85, timestamp: start.addingTimeInterval(2.0))
        engine.tick(currentTime: start.addingTimeInterval(2.5))
        #expect(engine.currentState.isNear) // Has not entered countdown yet

        // Signal recovers to -55 dBm
        engine.processSample(rssi: -55, timestamp: start.addingTimeInterval(3.0))
        #expect(engine.currentState.isNear)
        #expect(!engine.currentState.isCountdown)
    }

    @Test func testSustainedAbsenceTriggers5SecondCountdownAndFar() {
        let config = ProximityEngineConfig(
            nearGateRSSI: -60.0,
            farGateRSSI: -75.0,
            nearDwellDuration: 0.1,
            farDwellDuration: 4.0,
            countdownDuration: 5
        )
        let engine = ProximityEngine(config: config)
        engine.updateScannerHealth(isHealthy: true)
        engine.updateCandidateAvailability(hasCandidate: true)

        let start = Date()
        engine.processSample(rssi: -50, timestamp: start)
        engine.processSample(rssi: -50, timestamp: start.addingTimeInterval(0.2))
        #expect(engine.currentState.isNear)

        // Start departure dwell at t = 1.0s (signal below -75 dBm)
        engine.processSample(rssi: -80, timestamp: start.addingTimeInterval(1.0))

        // t = 3.0s (2s elapsed < 4s far dwell)
        engine.processSample(rssi: -80, timestamp: start.addingTimeInterval(3.0))
        engine.tick(currentTime: start.addingTimeInterval(3.0))
        #expect(engine.currentState.isNear)

        // t = 5.1s (4.1s elapsed > 4.0s far dwell) -> Should enter COUNTDOWN
        engine.processSample(rssi: -80, timestamp: start.addingTimeInterval(5.1))
        engine.tick(currentTime: start.addingTimeInterval(5.1))
        #expect(engine.currentState.isCountdown)

        // Tick countdown: 2 seconds into countdown -> still in countdown
        engine.tick(currentTime: start.addingTimeInterval(7.1))
        #expect(engine.currentState.isCountdown)

        // Tick past 5 seconds of countdown (t = 10.5s) -> Transitions to FAR
        engine.tick(currentTime: start.addingTimeInterval(10.5))
        #expect(engine.currentState.isFar)
    }

    @Test func testCandidateReturnCancelsCountdownImmediately() {
        let config = ProximityEngineConfig(
            nearGateRSSI: -60.0,
            farGateRSSI: -75.0,
            nearDwellDuration: 0.1,
            farDwellDuration: 2.0,
            countdownDuration: 5
        )
        let engine = ProximityEngine(config: config)
        engine.updateScannerHealth(isHealthy: true)
        engine.updateCandidateAvailability(hasCandidate: true)

        let start = Date()
        engine.processSample(rssi: -50, timestamp: start)
        engine.processSample(rssi: -50, timestamp: start.addingTimeInterval(0.2))
        #expect(engine.currentState.isNear)

        // Trigger countdown after 2.5s below far gate
        engine.processSample(rssi: -85, timestamp: start.addingTimeInterval(1.0))
        engine.processSample(rssi: -85, timestamp: start.addingTimeInterval(3.5))
        engine.tick(currentTime: start.addingTimeInterval(3.5))
        #expect(engine.currentState.isCountdown)

        // Candidate returns at t = 5.0s with -50 dBm signal during countdown
        engine.processSample(rssi: -50, timestamp: start.addingTimeInterval(5.0))
        // Immediate cancellation on near return
        #expect(engine.currentState.isNear)
        #expect(!engine.currentState.isCountdown)
    }

    @Test func testUserCanCancelCountdown() {
        let config = ProximityEngineConfig(
            nearGateRSSI: -60.0,
            farGateRSSI: -75.0,
            nearDwellDuration: 0.1,
            farDwellDuration: 1.0,
            countdownDuration: 5
        )
        let engine = ProximityEngine(config: config)
        engine.updateScannerHealth(isHealthy: true)
        engine.updateCandidateAvailability(hasCandidate: true)

        let start = Date()
        engine.processSample(rssi: -50, timestamp: start)
        engine.processSample(rssi: -50, timestamp: start.addingTimeInterval(0.2))
        #expect(engine.currentState.isNear)

        // Enter countdown
        engine.processSample(rssi: -85, timestamp: start.addingTimeInterval(1.0))
        engine.processSample(rssi: -85, timestamp: start.addingTimeInterval(2.5))
        engine.tick(currentTime: start.addingTimeInterval(2.5))
        #expect(engine.currentState.isCountdown)

        // User explicitly cancels countdown
        engine.userCancelCountdown()
        #expect(engine.currentState.isNear)
    }

    @Test func testHealthLossCancelsCountdownAndForcesUnknown() {
        let config = ProximityEngineConfig(
            nearGateRSSI: -60.0,
            farGateRSSI: -75.0,
            nearDwellDuration: 0.1,
            farDwellDuration: 1.0,
            countdownDuration: 5
        )
        let engine = ProximityEngine(config: config)
        engine.updateScannerHealth(isHealthy: true)
        engine.updateCandidateAvailability(hasCandidate: true)

        let start = Date()
        engine.processSample(rssi: -50, timestamp: start)
        engine.processSample(rssi: -50, timestamp: start.addingTimeInterval(0.2))
        #expect(engine.currentState.isNear)

        // Enter countdown
        engine.processSample(rssi: -85, timestamp: start.addingTimeInterval(1.0))
        engine.processSample(rssi: -85, timestamp: start.addingTimeInterval(2.5))
        engine.tick(currentTime: start.addingTimeInterval(2.5))
        #expect(engine.currentState.isCountdown)

        // Scanner loses health (e.g. Bluetooth turned off or permission revoked)
        engine.updateScannerHealth(isHealthy: false, reason: "Bluetooth radio powered off")
        #expect(engine.currentState.isUnknown)
    }
}
