import Testing
import Foundation
@testable import AuraSenseCore

struct RSSIAndAbsenceTests {

    @Test func testInvalidRSSIFollowedBySilenceExpiresEvidence() {
        let config = ProximityEngineConfig(
            nearGateRSSI: -60.0,
            farGateRSSI: -75.0,
            nearDwellDuration: 0.1,
            countdownDuration: 5,
            staleTimeout: 4.0
        )
        let engine = ProximityEngine(config: config)
        engine.updateScannerHealth(isHealthy: true)
        engine.updateCandidateAvailability(hasCandidate: true)

        let t0 = Date()
        // Establish NEAR at t0
        engine.processSample(rssi: -50, timestamp: t0)
        engine.processSample(rssi: -50, timestamp: t0.addingTimeInterval(0.2))
        #expect(engine.currentState.isNear)

        // Submit invalid RSSI values (+10 dBm, -125 dBm, 127 dummy)
        engine.processSample(rssi: 10, timestamp: t0.addingTimeInterval(2.0))
        engine.processSample(rssi: -125, timestamp: t0.addingTimeInterval(2.5))

        // At t = 3.0s (less than 4s stale timeout from t0)
        engine.tick(currentTime: t0.addingTimeInterval(3.0))
        #expect(engine.currentState.isNear)

        // At t = 4.3s (greater than 4s stale timeout from t0)
        // Invalid readings must not have kept evidence alive
        engine.tick(currentTime: t0.addingTimeInterval(4.3))
        #expect(engine.currentState.isCountdown)
    }

    @Test func testOneFarSampleFollowedBySilenceDoesNotStartCountdownEarly() {
        let config = ProximityEngineConfig(
            nearGateRSSI: -60.0,
            farGateRSSI: -75.0,
            nearDwellDuration: 0.1,
            farDwellDuration: 1.0, // Short far dwell
            countdownDuration: 5,
            staleTimeout: 5.0      // Long absence threshold
        )
        let engine = ProximityEngine(config: config)
        engine.updateScannerHealth(isHealthy: true)
        engine.updateCandidateAvailability(hasCandidate: true)

        let t0 = Date()
        engine.processSample(rssi: -50, timestamp: t0)
        engine.processSample(rssi: -50, timestamp: t0.addingTimeInterval(0.2))
        #expect(engine.currentState.isNear)

        // Single isolated FAR sample at t = 1.0s
        engine.processSample(rssi: -85, timestamp: t0.addingTimeInterval(1.0))

        // Silence follows. At t = 2.5s (1.5s since far sample > 1.0s far dwell, but silence 1.5s < 5.0s stale)
        engine.tick(currentTime: t0.addingTimeInterval(2.5))
        // Must NOT start countdown early! Single far sample + silence must not accelerate departure
        #expect(engine.currentState.isNear)

        // At t = 4.0s: still within grace period (< 5s stale)
        engine.tick(currentTime: t0.addingTimeInterval(4.0))
        #expect(engine.currentState.isNear)

        // At t = 6.1s (> 5s stale timeout from t = 1.0s)
        engine.tick(currentTime: t0.addingTimeInterval(6.1))
        #expect(engine.currentState.isCountdown)
    }

    @Test func testBurstOfValidFarReadingsTriggersCountdown() {
        let config = ProximityEngineConfig(
            nearGateRSSI: -60.0,
            farGateRSSI: -75.0,
            nearDwellDuration: 0.1,
            farDwellDuration: 1.5,
            countdownDuration: 5,
            staleTimeout: 10.0
        )
        let engine = ProximityEngine(config: config)
        engine.updateScannerHealth(isHealthy: true)
        engine.updateCandidateAvailability(hasCandidate: true)

        let t0 = Date()
        engine.processSample(rssi: -50, timestamp: t0)
        engine.processSample(rssi: -50, timestamp: t0.addingTimeInterval(0.2))
        #expect(engine.currentState.isNear)

        // Multiple far readings across dwell window
        engine.processSample(rssi: -82, timestamp: t0.addingTimeInterval(1.0))
        engine.processSample(rssi: -85, timestamp: t0.addingTimeInterval(1.8))
        engine.processSample(rssi: -88, timestamp: t0.addingTimeInterval(2.6)) // 1.6s > 1.5s dwell with 3 samples

        #expect(engine.currentState.isCountdown)
    }

    private final class SafeCounter: @unchecked Sendable {
        private var count = 0
        private let lock = NSLock()
        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }
        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    @Test func testCallbacksExecuteOutsideLockWithoutDeadlock() {
        let config = ProximityEngineConfig(nearDwellDuration: 0.1, farDwellDuration: 0.5, countdownDuration: 3)
        let engine = ProximityEngine(config: config)
        engine.updateScannerHealth(isHealthy: true)
        engine.updateCandidateAvailability(hasCandidate: true)

        let transitionCounter = SafeCounter()
        let evaluationCounter = SafeCounter()
        let countdownCounter = SafeCounter()

        // Synchronously query engine inside callbacks to verify no deadlock occurs
        engine.onStateTransition = { oldState, newState, reason in
            transitionCounter.increment()
            // Reentrant read of engine properties that acquire the engine lock
            _ = engine.currentState
            _ = engine.filter.sampleCount
        }

        engine.onEvaluation = { eval in
            evaluationCounter.increment()
            _ = engine.currentState
            _ = engine.filter.currentSmoothedRSSI
        }

        engine.onCountdownTick = { remaining in
            countdownCounter.increment()
            _ = engine.currentState
        }

        let start = Date()
        // 1. Transition to NEAR
        engine.processSample(rssi: -50, timestamp: start)
        engine.processSample(rssi: -50, timestamp: start.addingTimeInterval(0.2))
        #expect(engine.currentState.isNear)
        #expect(transitionCounter.value >= 1)
        #expect(evaluationCounter.value >= 1)

        // 2. Transition to COUNTDOWN
        engine.processSample(rssi: -85, timestamp: start.addingTimeInterval(1.0))
        engine.processSample(rssi: -85, timestamp: start.addingTimeInterval(2.0))
        engine.tick(currentTime: start.addingTimeInterval(2.0))
        #expect(engine.currentState.isCountdown)
        #expect(countdownCounter.value >= 1)

        // 3. Tick countdown
        engine.tick(currentTime: start.addingTimeInterval(3.0))
        #expect(countdownCounter.value >= 2)
    }
}
