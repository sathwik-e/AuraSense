import Foundation

/// Core proximity engine implementing the state machine, signal filtering,
/// dual-gate hysteresis, dwell debouncing, and cancellable 5-second countdown.
public final class ProximityEngine: @unchecked Sendable {
    private let lock = NSLock()
    public let config: ProximityEngineConfig
    public let filter: RSSIFilter

    // State
    private var _state: ProximityState = .unknown(reason: "System initializing")
    private var isScannerHealthy: Bool = false
    private var hasCandidate: Bool = false

    // Timing tracking
    private var lastAdmittedSampleTime: Date?
    private var nearDwellStartTime: Date?
    private var farDwellStartTime: Date?
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

    public init(config: ProximityEngineConfig = .default) {
        self.config = config
        self.filter = RSSIFilter(config: config)
    }

    // MARK: - Health and Lifecycle

    /// Updates the health status of the scanner (radio state, permissions).
    /// If health is lost, immediately forces UNKNOWN and cancels any active countdown per ARCHITECTURE.md.
    public func updateScannerHealth(isHealthy: Bool, reason: String = "Scanner health changed") {
        lock.lock()
        defer { lock.unlock() }

        self.isScannerHealthy = isHealthy
        if !isHealthy {
            cancelCountdownUnderLock(reason: "Monitoring unhealthy: \(reason)")
            transitionUnderLock(to: .unknown(reason: reason), reason: reason)
            filter.reset()
            nearDwellStartTime = nil
            farDwellStartTime = nil
        }
    }

    /// Updates whether a valid candidate is configured.
    public func updateCandidateAvailability(hasCandidate: Bool) {
        lock.lock()
        defer { lock.unlock() }

        self.hasCandidate = hasCandidate
        if !hasCandidate {
            cancelCountdownUnderLock(reason: "Candidate removed")
            transitionUnderLock(to: .unknown(reason: "No candidate registered"), reason: "No candidate registered")
            filter.reset()
        }
    }

    // MARK: - Ingestion of Admitted Candidate Samples

    /// Ingests an admitted candidate BLE sample passed by the SecurityActionGate.
    public func processSample(rssi: Int, timestamp: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }

        guard isScannerHealthy, hasCandidate else {
            return
        }

        lastAdmittedSampleTime = timestamp
        guard let smoothed = filter.addSample(rssi: rssi, timestamp: timestamp) else {
            return
        }

        evaluateSignalUnderLock(rawRSSI: rssi, smoothedRSSI: smoothed, timestamp: timestamp)
    }

    // MARK: - Periodic Tick Evaluation (for time progression & countdowns)

    /// Advances the engine's internal time evaluation.
    /// Drives countdown progression, absence dwell, and stale detection.
    public func tick(currentTime: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }

        guard isScannerHealthy, hasCandidate else {
            if !_state.isUnknown {
                transitionUnderLock(to: .unknown(reason: "Monitoring unavailable"), reason: "Monitoring unavailable")
            }
            return
        }

        let smoothed = filter.currentSmoothedRSSI

        // 1. If currently in COUNTDOWN: manage countdown timer
        if case .countdown(let currentSec) = _state {
            if let start = countdownStartTime {
                let elapsed = currentTime.timeIntervalSince(start)
                let remaining = max(0, config.countdownDuration - Int(elapsed))

                if remaining != lastCountdownSecondEmitted {
                    lastCountdownSecondEmitted = remaining
                    onCountdownTick?(remaining)
                }

                if remaining <= 0 {
                    // Countdown completed successfully with healthy scanner -> Transition to FAR
                    countdownStartTime = nil
                    lastCountdownSecondEmitted = nil
                    transitionUnderLock(
                        to: .far(dwellDuration: config.farDwellDuration + Double(config.countdownDuration)),
                        reason: "Departure countdown elapsed (5s) with sustained absence"
                    )
                    return
                } else if remaining != currentSec {
                    _state = .countdown(secondsRemaining: remaining)
                }
            }
            return
        }

        // 2. Check for stale evidence / missing candidate packets
        if let lastSample = lastAdmittedSampleTime {
            let silenceDuration = currentTime.timeIntervalSince(lastSample)

            if silenceDuration >= config.staleTimeout {
                // Extended silence: initiate departure countdown if currently NEAR or hold state
                handleAbsenceUnderLock(silenceDuration: silenceDuration, timestamp: currentTime)
                return
            }
        } else {
            // No sample ever received yet
            if !_state.isUnknown {
                transitionUnderLock(to: .unknown(reason: "Awaiting initial candidate evidence"), reason: "Startup")
            }
            return
        }

        // 3. Evaluate dwell progression for current smoothed signal
        if let smoothed = smoothed {
            evaluateDwellTimersUnderLock(smoothedRSSI: smoothed, timestamp: currentTime)
        }
    }

    /// Allows explicit cancellation of an active departure countdown (e.g. user clicks "I'm Here").
    public func userCancelCountdown() {
        lock.lock()
        defer { lock.unlock() }

        guard _state.isCountdown else { return }
        cancelCountdownUnderLock(reason: "User cancelled countdown")
        let rssi = filter.currentSmoothedRSSI ?? -65.0
        transitionUnderLock(to: .near(smoothedRSSI: rssi), reason: "User confirmed presence during countdown")
    }

    /// Cancels any active departure countdown and transitions to UNKNOWN due to system interruptions.
    public func cancelActiveCountdown(reason: String) {
        lock.lock()
        defer { lock.unlock() }

        cancelCountdownUnderLock(reason: reason)
        transitionUnderLock(to: .unknown(reason: reason), reason: reason)
    }

    // MARK: - Internal State Evaluation Logic

    private func evaluateSignalUnderLock(rawRSSI: Int, smoothedRSSI: Double, timestamp: Date) {
        let isRawNear = Double(rawRSSI) >= config.nearGateRSSI
        let isSmoothedNear = smoothedRSSI >= config.nearGateRSSI
        let isRawFar = Double(rawRSSI) <= config.farGateRSSI
        let isSmoothedFar = smoothedRSSI <= config.farGateRSSI

        // 1. If currently in COUNTDOWN:
        if _state.isCountdown {
            if isRawNear || isSmoothedNear {
                // Immediate cancellation on near return
                cancelCountdownUnderLock(reason: "Candidate returned above near gate (\(rawRSSI) dBm)")
                transitionUnderLock(to: .near(smoothedRSSI: smoothedRSSI), reason: "Candidate returned during countdown")
                nearDwellStartTime = timestamp
                farDwellStartTime = nil
                return
            }
        }

        // 2. Evaluate FAR departure condition (raw is far OR smoothed is far):
        if isRawFar || isSmoothedFar {
            nearDwellStartTime = nil // Reset near dwell

            if _state.isNear {
                // Begin or advance departure dwell (debounce)
                if let start = farDwellStartTime {
                    if timestamp.timeIntervalSince(start) >= config.farDwellDuration {
                        initiateCountdownUnderLock(timestamp: timestamp)
                    }
                } else {
                    farDwellStartTime = timestamp
                }
            }
            return
        }

        // 3. Evaluate NEAR condition:
        if isRawNear && isSmoothedNear {
            farDwellStartTime = nil // Reset departure dwell (debounce)

            if _state.isNear {
                _state = .near(smoothedRSSI: smoothedRSSI)
            } else {
                if let start = nearDwellStartTime {
                    if timestamp.timeIntervalSince(start) >= config.nearDwellDuration {
                        transitionUnderLock(
                            to: .near(smoothedRSSI: smoothedRSSI),
                            reason: "Signal sustained above near gate (\(config.nearGateRSSI) dBm) for \(config.nearDwellDuration)s"
                        )
                    }
                } else {
                    nearDwellStartTime = timestamp
                }
            }
            return
        }

        // 4. Hysteresis dead band (between -75 dBm and -60 dBm):
        // Maintain current state to prevent flutter
        nearDwellStartTime = nil
    }

    private func handleAbsenceUnderLock(silenceDuration: TimeInterval, timestamp: Date) {
        if _state.isNear {
            initiateCountdownUnderLock(timestamp: timestamp)
        }
    }

    private func evaluateDwellTimersUnderLock(smoothedRSSI: Double, timestamp: Date) {
        if _state.isNear {
            if let start = farDwellStartTime, timestamp.timeIntervalSince(start) >= config.farDwellDuration {
                initiateCountdownUnderLock(timestamp: timestamp)
            }
        }
    }

    private func initiateCountdownUnderLock(timestamp: Date) {
        countdownStartTime = timestamp
        lastCountdownSecondEmitted = config.countdownDuration
        let initialSeconds = config.countdownDuration
        transitionUnderLock(
            to: .countdown(secondsRemaining: initialSeconds),
            reason: "Departure dwell met; initiating 5-second cancellable countdown"
        )
        onCountdownTick?(initialSeconds)
    }

    private func cancelCountdownUnderLock(reason: String) {
        countdownStartTime = nil
        lastCountdownSecondEmitted = nil
        farDwellStartTime = nil
    }

    private func transitionUnderLock(to newState: ProximityState, reason: String) {
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

        onStateTransition?(oldState, newState, reason)
        onEvaluation?(eval)
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
