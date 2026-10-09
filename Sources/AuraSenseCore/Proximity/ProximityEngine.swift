import Foundation

/// Core proximity engine implementing the state machine, signal filtering,
/// dual-gate hysteresis, dwell debouncing, and cancellable 5-second countdown.
/// Guarantees callbacks execute strictly outside locks and enforces robust absence/dwell boundaries.
public final class ProximityEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var _config: ProximityEngineConfig
    public let filter: RSSIFilter

    public var config: ProximityEngineConfig {
        lock.lock()
        defer { lock.unlock() }
        return _config
    }

    // State
    private var _state: ProximityState = .unknown(reason: "System initializing")
    private var isScannerHealthy: Bool = false
    private var hasCandidate: Bool = false

    // Timing & observation tracking
    private var lastAdmittedSampleTime: Date?
    private var nearDwellStartTime: Date?
    private var farDwellStartTime: Date?
    private var farObservationCount: Int = 0
    private var countdownStartTime: Date?
    private var lastCountdownSecondEmitted: Int?

    // Callbacks
    public var onStateTransition: (@Sendable (ProximityState, ProximityState, String) -> Void)?
    public var onCountdownTick: (@Sendable (Int) -> Void)?
    public var onEvaluation: (@Sendable (ProximityEvaluation) -> Void)?

    public var currentState: ProximityState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    public var isReadyForEvaluation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isScannerHealthy && hasCandidate
    }

    public static func isValidRSSI(_ rssi: Int) -> Bool {
        return rssi >= -120 && rssi <= 0
    }

    public init(config: ProximityEngineConfig = .default) {
        self._config = config
        self.filter = RSSIFilter(config: config)
    }

    @discardableResult
    public func updateConfiguration(_ configuration: ProximityEngineConfig) -> Bool {
        guard configuration.isValid else { return false }
        lock.lock()
        guard configuration != _config else {
            lock.unlock()
            return true
        }
        _config = configuration
        cancelCountdownUnderLock(reason: "Proximity settings changed")
        filter.reset()
        resetObservationTimingUnderLock()
        var callbacks: [() -> Void] = []
        transitionUnderLock(
            to: .unknown(reason: "Proximity settings changed; waiting for fresh signal"),
            reason: "Proximity settings changed",
            callbacks: &callbacks
        )
        lock.unlock()
        callbacks.forEach { $0() }
        return true
    }

    // MARK: - Health and Lifecycle

    /// Updates the health status of the scanner (radio state, permissions).
    /// If health is lost, immediately forces UNKNOWN and cancels any active countdown per ARCHITECTURE.md.
    public func updateScannerHealth(isHealthy: Bool, reason: String = "Scanner health changed") {
        lock.lock()
        var callbacks: [() -> Void] = []

        self.isScannerHealthy = isHealthy
        if !isHealthy {
            cancelCountdownUnderLock(reason: "Monitoring unhealthy: \(reason)")
            transitionUnderLock(to: .unknown(reason: reason), reason: reason, callbacks: &callbacks)
            filter.reset()
            resetObservationTimingUnderLock()
        }

        lock.unlock()
        for cb in callbacks { cb() }
    }

    /// Updates whether a valid candidate is configured.
    public func updateCandidateAvailability(hasCandidate: Bool) {
        lock.lock()
        var callbacks: [() -> Void] = []

        self.hasCandidate = hasCandidate
        if !hasCandidate {
            cancelCountdownUnderLock(reason: "Candidate removed")
            transitionUnderLock(to: .unknown(reason: "No candidate registered"), reason: "No candidate registered", callbacks: &callbacks)
            filter.reset()
            resetObservationTimingUnderLock()
        }

        lock.unlock()
        for cb in callbacks { cb() }
    }

    // MARK: - Ingestion of Admitted Candidate Samples

    /// Ingests an admitted candidate BLE sample passed by the SecurityActionGate.
    /// Strictly validates RSSI before updating liveness, sample freshness, or filters.
    public func processSample(rssi: Int, timestamp: Date = Date()) {
        guard Self.isValidRSSI(rssi) else {
            return
        }

        lock.lock()
        var callbacks: [() -> Void] = []

        guard isScannerHealthy, hasCandidate else {
            lock.unlock()
            return
        }

        if let lastSample = lastAdmittedSampleTime, timestamp <= lastSample {
            lock.unlock()
            return
        }

        lastAdmittedSampleTime = timestamp
        guard let smoothed = filter.addSample(rssi: rssi, timestamp: timestamp) else {
            lock.unlock()
            return
        }

        evaluateSignalUnderLock(rawRSSI: rssi, smoothedRSSI: smoothed, timestamp: timestamp, callbacks: &callbacks)
        lock.unlock()

        for cb in callbacks { cb() }
    }

    // MARK: - Periodic Tick Evaluation (for time progression & countdowns)

    /// Advances the engine's internal time evaluation.
    /// Drives countdown progression and absence detection.
    public func tick(currentTime: Date = Date()) {
        lock.lock()
        var callbacks: [() -> Void] = []

        guard isScannerHealthy, hasCandidate else {
            cancelCountdownUnderLock(reason: "Monitoring unavailable")
            filter.reset()
            resetObservationTimingUnderLock()
            if !_state.isUnknown {
                transitionUnderLock(to: .unknown(reason: "Monitoring unavailable"), reason: "Monitoring unavailable", callbacks: &callbacks)
            }
            lock.unlock()
            for cb in callbacks { cb() }
            return
        }

        // 1. If currently in COUNTDOWN: manage countdown timer
        if case .countdown(let currentSec) = _state {
            if let start = countdownStartTime {
                let elapsed = currentTime.timeIntervalSince(start)
                let remaining = max(0, _config.countdownDuration - Int(elapsed))

                if remaining != lastCountdownSecondEmitted {
                    lastCountdownSecondEmitted = remaining
                    callbacks.append { [weak self] in
                        self?.onCountdownTick?(remaining)
                    }
                }

                if remaining <= 0 {
                    // Countdown completed successfully with healthy scanner -> Transition to FAR
                    countdownStartTime = nil
                    lastCountdownSecondEmitted = nil
                    transitionUnderLock(
                        to: .far(dwellDuration: _config.farDwellDuration + Double(_config.countdownDuration)),
                        reason: "Departure countdown elapsed (5s) with sustained absence",
                        callbacks: &callbacks
                    )
                    lock.unlock()
                    for cb in callbacks { cb() }
                    return
                } else if remaining != currentSec {
                    _state = .countdown(secondsRemaining: remaining)
                }
            }
            lock.unlock()
            for cb in callbacks { cb() }
            return
        }

        // 2. Check for stale evidence / missing candidate packets (Absence Policy)
        if let lastSample = lastAdmittedSampleTime {
            let silenceDuration = currentTime.timeIntervalSince(lastSample)

            if silenceDuration >= _config.staleTimeout {
                // Extended silence: initiate departure countdown if currently NEAR
                if _state.isNear {
                    initiateCountdownUnderLock(
                        timestamp: currentTime,
                        reason: "Departure countdown initiated: candidate absent for \(Int(silenceDuration))s (stale timeout exceeded)",
                        callbacks: &callbacks
                    )
                }
                lock.unlock()
                for cb in callbacks { cb() }
                return
            }
        } else {
            // No sample ever received yet
            if !_state.isUnknown {
                transitionUnderLock(to: .unknown(reason: "Awaiting initial candidate evidence"), reason: "Startup", callbacks: &callbacks)
            }
            lock.unlock()
            for cb in callbacks { cb() }
            return
        }

        // 3. Clear unconfirmed single far dwell if sample gap exceeds maxGapDuration
        if let lastSample = lastAdmittedSampleTime, currentTime.timeIntervalSince(lastSample) > _config.maxGapDuration {
            farDwellStartTime = nil
            farObservationCount = 0
        }

        lock.unlock()
        for cb in callbacks { cb() }
    }

    /// Allows explicit cancellation of an active departure countdown (e.g. user clicks "I'm Here").
    public func userCancelCountdown() {
        lock.lock()
        var callbacks: [() -> Void] = []

        guard _state.isCountdown else {
            lock.unlock()
            return
        }
        cancelCountdownUnderLock(reason: "User cancelled countdown")
        let rssi = filter.currentSmoothedRSSI ?? -65.0
        transitionUnderLock(to: .near(smoothedRSSI: rssi), reason: "User confirmed presence during countdown", callbacks: &callbacks)

        lock.unlock()
        for cb in callbacks { cb() }
    }

    /// Cancels any active departure countdown and transitions to UNKNOWN due to system interruptions.
    public func cancelActiveCountdown(reason: String) {
        lock.lock()
        var callbacks: [() -> Void] = []

        cancelCountdownUnderLock(reason: reason)
        transitionUnderLock(to: .unknown(reason: reason), reason: reason, callbacks: &callbacks)

        lock.unlock()
        for cb in callbacks { cb() }
    }

    // MARK: - Internal State Evaluation Logic

    private func evaluateSignalUnderLock(
        rawRSSI: Int,
        smoothedRSSI: Double,
        timestamp: Date,
        callbacks: inout [() -> Void]
    ) {
        let isRawNear = Double(rawRSSI) >= _config.nearGateRSSI
        let isSmoothedNear = smoothedRSSI >= _config.nearGateRSSI
        let isRawFar = Double(rawRSSI) <= _config.farGateRSSI
        let isSmoothedFar = smoothedRSSI <= _config.farGateRSSI

        // 1. If currently in COUNTDOWN:
        if _state.isCountdown {
            if isRawNear || isSmoothedNear {
                // Immediate cancellation on near return
                cancelCountdownUnderLock(reason: "Candidate returned above near gate (\(rawRSSI) dBm)")
                transitionUnderLock(
                    to: .near(smoothedRSSI: smoothedRSSI),
                    reason: "Candidate returned during countdown",
                    callbacks: &callbacks
                )
                nearDwellStartTime = timestamp
                farDwellStartTime = nil
                farObservationCount = 0
                return
            }
        }

        // 2. Evaluate FAR departure condition:
        if isRawFar || isSmoothedFar {
            nearDwellStartTime = nil // Reset near dwell

            if _state.isNear {
                if let start = farDwellStartTime {
                    farObservationCount += 1
                    // Require multiple valid far observations across dwell window
                    if farObservationCount >= 2 && timestamp.timeIntervalSince(start) >= _config.farDwellDuration {
                        initiateCountdownUnderLock(
                            timestamp: timestamp,
                            reason: "Departure dwell met with \(farObservationCount) far readings over \(_config.farDwellDuration)s",
                            callbacks: &callbacks
                        )
                    }
                } else {
                    farDwellStartTime = timestamp
                    farObservationCount = 1
                }
            }
            return
        }

        // 3. Evaluate NEAR condition:
        if isRawNear && isSmoothedNear {
            farDwellStartTime = nil // Reset departure dwell
            farObservationCount = 0

            if _state.isNear {
                _state = .near(smoothedRSSI: smoothedRSSI)
            } else {
                if let start = nearDwellStartTime {
                    if timestamp.timeIntervalSince(start) >= _config.nearDwellDuration {
                        transitionUnderLock(
                            to: .near(smoothedRSSI: smoothedRSSI),
                            reason: "Signal sustained above near gate (\(_config.nearGateRSSI) dBm) for \(_config.nearDwellDuration)s",
                            callbacks: &callbacks
                        )
                    }
                } else {
                    nearDwellStartTime = timestamp
                }
            }
            return
        }

        // 4. Hysteresis dead band (between farGateRSSI and nearGateRSSI).
        // Departure dwell is continuous evidence below the far gate, not accumulated
        // across dead-band observations.
        farDwellStartTime = nil
        farObservationCount = 0
        nearDwellStartTime = nil
    }

    private func initiateCountdownUnderLock(
        timestamp: Date,
        reason: String = "Departure dwell met; initiating 5-second cancellable countdown",
        callbacks: inout [() -> Void]
    ) {
        guard isScannerHealthy, hasCandidate, _state.isNear else { return }
        countdownStartTime = timestamp
        lastCountdownSecondEmitted = _config.countdownDuration
        let initialSeconds = _config.countdownDuration
        transitionUnderLock(
            to: .countdown(secondsRemaining: initialSeconds),
            reason: reason,
            callbacks: &callbacks
        )
        callbacks.append { [weak self] in
            self?.onCountdownTick?(initialSeconds)
        }
    }

    private func cancelCountdownUnderLock(reason: String) {
        countdownStartTime = nil
        lastCountdownSecondEmitted = nil
        farDwellStartTime = nil
        farObservationCount = 0
    }

    private func resetObservationTimingUnderLock() {
        nearDwellStartTime = nil
        farDwellStartTime = nil
        farObservationCount = 0
        lastAdmittedSampleTime = nil
    }

    private func transitionUnderLock(
        to newState: ProximityState,
        reason: String,
        callbacks: inout [() -> Void]
    ) {
        guard _state != newState else { return }
        let oldState = _state
        _state = newState

        let eval = ProximityEvaluation(
            state: newState,
            smoothedRSSI: filter.currentSmoothedRSSI,
            rawRSSI: nil,
            sampleCount: filter.sampleCount,
            confidence: computeConfidence(state: newState),
            reason: reason,
            timestamp: Date()
        )

        callbacks.append { [weak self] in
            self?.onStateTransition?(oldState, newState, reason)
            self?.onEvaluation?(eval)
        }
    }

    private func computeConfidence(state: ProximityState) -> Double {
        switch state {
        case .near:
            return min(1.0, Double(filter.sampleCount) / 10.0)
        case .far:
            return 0.90
        case .countdown:
            return 0.70
        case .unknown:
            return 0.0
        case .authAttempt, .unlocked:
            return 1.0
        }
    }
}
