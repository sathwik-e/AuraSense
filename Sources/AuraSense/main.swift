import Foundation
import AppKit
import AuraSenseCore

@MainActor
final class AuraSenseCLI: @unchecked Sendable {
    private let scanner: any BLEScannerProtocol
    private let trustStore: any CandidateTrustStoreProtocol
    private let diagnostics: DiagnosticsManager
    private let logger: FileLogger
    private let settingsStore: FileSettingsStore
    private let sleepWakeMonitor: SystemSleepWakeMonitor
    private let recoveryCoordinator: BluetoothRecoveryCoordinator
    private let launchAtLoginManager: SMAppServiceLaunchAtLoginManager
    private var isRunning: Bool = false
    private let runLoop = RunLoop.current

    init(
        scanner: any BLEScannerProtocol = CoreBluetoothScanner(),
        trustStore: any CandidateTrustStoreProtocol = PersistentCandidateTrustStore()
    ) {
        self.scanner = scanner
        self.trustStore = trustStore
        self.logger = FileLogger()
        self.settingsStore = FileSettingsStore()
        self.launchAtLoginManager = SMAppServiceLaunchAtLoginManager()

        let settings = settingsStore.currentSettings
        let config = ProximityEngineConfig(
            nearGateRSSI: settings.nearGateRSSI,
            farGateRSSI: settings.farGateRSSI,
            farDwellDuration: settings.farDwellDuration,
            countdownDuration: settings.countdownDuration
        )

        let proximityEngine = ProximityEngine(config: config)
        let adapter = MacOSActionAdapter(isDryRun: true)
        let policyEngine = PolicyEngine(
            actionProvider: adapter,
            isAutoLockEnabled: settings.isAutoLockEnabled,
            isAutoWakeEnabled: settings.isAutoWakeEnabled
        )

        self.diagnostics = DiagnosticsManager(
            trustStore: trustStore,
            proximityEngine: proximityEngine,
            policyEngine: policyEngine
        )
        self.scanner.delegate = diagnostics

        self.recoveryCoordinator = BluetoothRecoveryCoordinator(
            scanner: scanner,
            proximityEngine: proximityEngine,
            actionExecutor: diagnostics.actionExecutor
        )
        self.sleepWakeMonitor = SystemSleepWakeMonitor()

        setupLifecycleObservers()
    }

    private func setupLifecycleObservers() {
        diagnostics.onEventLogged = { [weak self] event in
            self?.logger.log(event: event)
        }

        sleepWakeMonitor.onWillSleep = { [weak self] in
            self?.diagnostics.log(category: "System.Power", message: "System entering sleep. Cancelling countdown and pausing scanner.")
            self?.recoveryCoordinator.handleSystemSleep()
        }

        sleepWakeMonitor.onDidWake = { [weak self] in
            self?.diagnostics.log(category: "System.Power", message: "System awakened. Resetting proximity filter and resuming scanner.")
            self?.recoveryCoordinator.handleSystemWake()
        }

        sleepWakeMonitor.startMonitoring()
    }

    func run() {
        let args = CommandLine.arguments

        if args.contains("--help") || args.contains("-h") {
            printHelp()
            return
        }

        if args.contains("register") {
            handleRegister(args: args)
            return
        }

        if args.contains("unregister") {
            handleUnregister()
            return
        }

        if args.contains("candidate") {
            handleShowCandidate(asJSON: args.contains("--json"))
            return
        }

        if args.contains("logs") {
            handleLogs()
            return
        }

        if args.contains("settings") {
            handleSettings(args: args)
            return
        }

        if let candidateArg = parseCandidateArg(args: args) {
            let candidateUUID = UUID(uuidString: candidateArg) ?? UUID()
            let candidate = CandidateDevice(id: candidateUUID, name: candidateArg)
            try? trustStore.register(candidate: candidate)
            diagnostics.gate.syncCandidate()
        }

        if let adapter = diagnostics.policyEngine.actionProvider as? MacOSActionAdapter {
            let isLive = args.contains("--live-action") || args.contains("--live-lock") || args.contains("--live-wake")
            adapter.isDryRun = !isLive
            if let synth = adapter.inputSynthesizer as? MacOSInputSynthesizer {
                synth.isDryRun = !isLive
            }
        }

        if args.contains("--no-wake") {
            diagnostics.policyEngine.isAutoWakeEnabled = false
        }

        if args.contains("--auto-lock") || args.contains("--enable-lock") {
            let isLive = args.contains("--live-lock") || args.contains("--live-action")
            diagnostics.policyEngine.isAutoLockEnabled = true
            diagnostics.policyEngine.reset()
            if isLive {
                print("Notice: LIVE system auto-lock enabled. Mac will lock upon confirmed departure.")
            } else {
                print("Notice: Auto-lock policy enabled in Dry-Run mode (simulated without locking display).")
            }
        }

        if args.contains("diagnostics") {
            runDiagnostics(asJSON: args.contains("--json"))
            return
        }

        if args.contains("scan") {
            let duration = parseScanDuration(args: args) ?? 5.0
            runTimedScan(duration: duration, asJSON: args.contains("--json"))
            return
        }

        if args.contains("menu") || args.contains("--menu") || (args.count == 1 && Bundle.main.bundlePath.hasSuffix(".app")) {
            runMenuBarMode()
            return
        }

        runAgentMode()
    }

    private func printHelp() {
        print("""
        AuraSense - Native macOS Bluetooth Proximity & Discovery Agent

        USAGE:
            aurasense [command] [options]

        COMMANDS:
            agent (default)        Run continuous BLE discovery and live diagnostics monitoring
            menu                   Launch the native macOS Menu Bar status item application
            scan                   Scan for nearby BLE peripherals for a set duration and report
            diagnostics            Inspect Bluetooth radio state, authorization, and capabilities
            candidate              Show currently registered candidate device and security disclaimers
            register <UUID>        Register a discovered BLE peripheral as the trusted candidate
            unregister             Unregister the current candidate device
            settings               Inspect or modify persisted application settings
            logs                   View recent persistent diagnostic log entries

        OPTIONS:
            --name <name>          Optional friendly name for registration (e.g. "Sathwik's iPhone")
            --candidate <name|id>  Ad-hoc track a specific candidate for this session
            --auto-lock            Enable automatic locking upon completed departure countdown (dry-run by default)
            --live-lock            With --auto-lock: execute real macOS screen locking via SACLockScreenImmediate
            --no-wake              Disable automatic display wake when returning to NEAR proximity
            --live-wake            Execute real macOS display wake via IOPMAssertion / caffeinate
            --duration <seconds>   Scan duration in seconds (for 'scan' command, default: 5)
            --json                 Output diagnostic reports in structured JSON format
            -h, --help             Show this help message

        SECURITY NOTICE:
            Phase 4/5 introduces automatic Mac locking and display wake triggered by proximity transitions.
            Display wake and input synthesis operate in an isolated action layer.
            Plaintext credential injection is strictly disabled. Auto-lock requires explicit opt-in (--auto-lock).
        """)
    }

    private func handleRegister(args: [String]) {
        guard let regIdx = args.firstIndex(of: "register"), regIdx + 1 < args.count else {
            print("Error: Please specify the peripheral UUID to register. Example: aurasense register <UUID>")
            return
        }

        let rawUUID = args[regIdx + 1]
        guard let uuid = UUID(uuidString: rawUUID) else {
            print("Error: Invalid UUID format: '\(rawUUID)'")
            return
        }

        let name: String
        if let nameIdx = args.firstIndex(of: "--name"), nameIdx + 1 < args.count {
            name = args[nameIdx + 1]
        } else {
            name = "Candidate-\(uuid.uuidString.prefix(6))"
        }

        let candidate = CandidateDevice(id: uuid, name: name)
        do {
            try diagnostics.registerCandidate(candidate)
            print("Successfully registered candidate device:")
            print("  ID:                  \(candidate.id.uuidString)")
            print("  Name:                \(candidate.name)")
            print("  Security Disclaimer: \(candidate.securityDisclaimer)")
        } catch {
            print("Failed to register candidate: \(error.localizedDescription)")
        }
    }

    private func handleUnregister() {
        do {
            try diagnostics.unregisterCandidate()
            print("Candidate device cleared. Security gate is now blocking all peripherals.")
        } catch {
            print("Failed to unregister candidate: \(error.localizedDescription)")
        }
    }

    private func handleShowCandidate(asJSON: Bool) {
        guard let candidate = trustStore.registeredCandidate else {
            if asJSON {
                print("{\"registered\": false}")
            } else {
                print("No candidate device currently registered. Run 'aurasense register <UUID>' to enroll one.")
            }
            return
        }

        if asJSON {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(candidate), let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        } else {
            print("Registered Candidate Device:")
            print("  Identifier:                 \(candidate.id.uuidString)")
            print("  Name:                       \(candidate.name)")
            print("  Enrolled Date:              \(candidate.selectedAt)")
            print("  Cryptographically Verified: \(candidate.isCryptographicallyVerified)")
            print("  Security Disclaimer:        \(candidate.securityDisclaimer)")
        }
    }

    private func handleLogs() {
        let lines = logger.readRecentLogs(maxLines: 40)
        if lines.isEmpty {
            print("No log entries recorded yet in \(logger.logFileURL.path).")
        } else {
            print("Recent AuraSense Diagnostic Logs (\(logger.logFileURL.path)):")
            print("--------------------------------------------------------------------------------")
            for line in lines {
                print(line)
            }
        }
    }

    private func handleSettings(args: [String]) {
        var settings = settingsStore.currentSettings

        if let lockIdx = args.firstIndex(of: "--auto-lock"), lockIdx + 1 < args.count {
            settings.isAutoLockEnabled = (args[lockIdx + 1].lowercased() == "true")
            try? settingsStore.save(settings: settings)
            print("Updated autoLockEnabled: \(settings.isAutoLockEnabled)")
        }

        if let wakeIdx = args.firstIndex(of: "--auto-wake"), wakeIdx + 1 < args.count {
            settings.isAutoWakeEnabled = (args[wakeIdx + 1].lowercased() == "true")
            try? settingsStore.save(settings: settings)
            print("Updated autoWakeEnabled: \(settings.isAutoWakeEnabled)")
        }

        print("Current AuraSense Settings:")
        print("  Auto-Lock Enabled:       \(settings.isAutoLockEnabled)")
        print("  Auto-Wake Enabled:       \(settings.isAutoWakeEnabled)")
        print("  Launch at Login:         \(launchAtLoginManager.isEnabled)")
        print("  Near Gate RSSI:          \(settings.nearGateRSSI) dBm")
        print("  Far Gate RSSI:           \(settings.farGateRSSI) dBm")
        print("  Far Dwell Duration:      \(settings.farDwellDuration) s")
        print("  Departure Countdown:     \(settings.countdownDuration) s")
    }

    private func runDiagnostics(asJSON: Bool) {
        let snapshot = diagnostics.snapshot(from: scanner)
        if asJSON {
            print(snapshot.toJSON())
        } else {
            print(ConsoleDiagnosticsView.renderLiveHeader())
            print(ConsoleDiagnosticsView.renderSnapshot(snapshot))
        }
    }

    private func runTimedScan(duration: TimeInterval, asJSON: Bool) {
        print(ConsoleDiagnosticsView.renderLiveHeader())
        print("Starting BLE scan for \(String(format: "%.1f", duration)) seconds...")

        do {
            try scanner.startScanning(serviceUUIDs: nil)
        } catch {
            print("Failed to start scanning: \(error.localizedDescription)")
            return
        }

        diagnostics.onEventLogged = { event in
            if event.level != .debug {
                print(event.logLine)
            }
        }

        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            runLoop.run(until: Date(timeIntervalSinceNow: 0.1))
            diagnostics.proximityEngine.tick()
        }

        scanner.stopScanning()

        let snapshot = diagnostics.snapshot(from: scanner)
        if asJSON {
            print(snapshot.toJSON())
        } else {
            print("\nScan completed. Discovered \(snapshot.totalDiscoveredCount) peripherals:")
            print(ConsoleDiagnosticsView.renderSnapshot(snapshot))
        }
    }

    private func runMenuBarMode() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let menuBarController = MenuBarController(
            diagnostics: diagnostics,
            settingsStore: settingsStore,
            launchAtLoginManager: launchAtLoginManager
        )

        do {
            try scanner.startScanning(serviceUUIDs: nil)
        } catch {
            diagnostics.log(level: .warning, category: "BLE", message: "Deferred scan start: \(error.localizedDescription)")
        }

        _ = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, self.diagnostics.canProcessProximityTicks else { return }
            let now = Date()
            self.diagnostics.proximityEngine.tick(currentTime: now)
            self.diagnostics.purgeStalePeriodically(referenceDate: now)
        }

        _ = menuBarController // Retain controller
        app.run()
    }

    private func runAgentMode() {
        print(ConsoleDiagnosticsView.renderLiveHeader())
        print("Starting AuraSense background agent...")
        if let candidate = trustStore.registeredCandidate {
            print("Monitoring candidate: \(candidate.name) [\(candidate.id.uuidString)]")
        } else {
            print("Notice: No candidate registered. Security gate will reject all incoming devices.")
        }
        print("Press Ctrl+C to terminate.")

        setupSignalHandlers()

        diagnostics.onEventLogged = { [weak self] event in
            self?.logger.log(event: event)
            if event.level != .debug {
                print(event.logLine)
            }
        }

        do {
            try scanner.startScanning(serviceUUIDs: nil)
        } catch {
            print("Warning: Initial scan start deferred: \(error.localizedDescription)")
        }

        isRunning = true

        let tickTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // canProcessProximityTicks gates idle wakeups (Finding 11)
            guard self.diagnostics.canProcessProximityTicks else { return }
            let now = Date()
            self.diagnostics.proximityEngine.tick(currentTime: now)
            // Opportunistic bounded registry purge without a separate timer (Finding 18)
            self.diagnostics.purgeStalePeriodically(referenceDate: now)
        }

        let heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let snapshot = self.diagnostics.snapshot(from: self.scanner)
            print("\n[Telemetry Heartbeat]")
            print(ConsoleDiagnosticsView.renderSnapshot(snapshot))
        }

        while isRunning {
            runLoop.run(until: Date(timeIntervalSinceNow: 0.5))
        }

        tickTimer.invalidate()
        heartbeatTimer.invalidate()
        scanner.stopScanning()
        print("\nAuraSense agent stopped.")
    }

    private func setupSignalHandlers() {
        signal(SIGINT) { _ in
            print("\nInterrupt signal (SIGINT) received. Shutting down...")
            exit(0)
        }
        signal(SIGTERM) { _ in
            print("\nTermination signal (SIGTERM) received. Shutting down...")
            exit(0)
        }
    }

    private func parseScanDuration(args: [String]) -> TimeInterval? {
        if let idx = args.firstIndex(of: "--duration"), idx + 1 < args.count {
            return TimeInterval(args[idx + 1])
        }
        return nil
    }

    private func parseCandidateArg(args: [String]) -> String? {
        if let idx = args.firstIndex(of: "--candidate"), idx + 1 < args.count {
            return args[idx + 1]
        }
        return nil
    }
}

MainActor.assumeIsolated {
    let cli = AuraSenseCLI()
    cli.run()
}
