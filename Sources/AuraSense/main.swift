import Foundation
import AuraSenseCore

final class AuraSenseCLI: @unchecked Sendable {
    private let scanner: any BLEScannerProtocol
    private let trustStore: any CandidateTrustStoreProtocol
    private let diagnostics: DiagnosticsManager
    private var isRunning: Bool = false
    private let runLoop = RunLoop.current

    init(
        scanner: any BLEScannerProtocol = CoreBluetoothScanner(),
        trustStore: any CandidateTrustStoreProtocol = PersistentCandidateTrustStore()
    ) {
        self.scanner = scanner
        self.trustStore = trustStore
        self.diagnostics = DiagnosticsManager(trustStore: trustStore)
        self.scanner.delegate = diagnostics
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

        if let candidateArg = parseCandidateArg(args: args) {
            let candidateUUID = UUID(uuidString: candidateArg) ?? UUID()
            let candidate = CandidateDevice(id: candidateUUID, name: candidateArg)
            try? trustStore.register(candidate: candidate)
            diagnostics.gate.syncCandidate()
        }

        if args.contains("--auto-lock") || args.contains("--enable-lock") {
            let isLive = args.contains("--live-lock")
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

        runAgentMode()
    }

    private func printHelp() {
        print("""
        AuraSense - Native macOS Bluetooth Proximity & Discovery Agent

        USAGE:
            aurasense [command] [options]

        COMMANDS:
            agent (default)        Run continuous BLE discovery and live diagnostics monitoring
            scan                   Scan for nearby BLE peripherals for a set duration and report
            diagnostics            Inspect Bluetooth radio state, authorization, and capabilities
            candidate              Show currently registered candidate device and security disclaimers
            register <UUID>        Register a discovered BLE peripheral as the trusted candidate
            unregister             Unregister the current candidate device

        OPTIONS:
            --name <name>          Optional friendly name for registration (e.g. "Sathwik's iPhone")
            --candidate <name|id>  Ad-hoc track a specific candidate for this session
            --auto-lock            Enable automatic locking upon completed departure countdown (dry-run by default)
            --live-lock            With --auto-lock: execute real macOS screen locking via SACLockScreenImmediate
            --duration <seconds>   Scan duration in seconds (for 'scan' command, default: 5)
            --json                 Output diagnostic reports in structured JSON format
            -h, --help             Show this help message

        SECURITY NOTICE:
            Phase 4 introduces automatic Mac locking triggered strictly upon completed departure countdown.
            Locking is idempotent and disabled during UNKNOWN states or identity ambiguity.
            Auto-lock requires explicit opt-in (--auto-lock).
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
            try trustStore.register(candidate: candidate)
            diagnostics.gate.syncCandidate()
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
            try trustStore.unregister()
            diagnostics.gate.syncCandidate()
            print("Candidate device unregistered successfully. Security gate is now closed to all devices.")
        } catch {
            print("Failed to unregister candidate: \(error.localizedDescription)")
        }
    }

    private func handleShowCandidate(asJSON: Bool) {
        guard let candidate = trustStore.registeredCandidate else {
            if asJSON {
                print("{\"registered\": false}")
            } else {
                print("No candidate device is currently registered.")
                print("Use 'aurasense scan' to discover devices, then 'aurasense register <UUID>' to register.")
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
            print("================================================================================")
            print(" Registered Candidate Companion Device")
            print("================================================================================")
            print(" Identifier:           \(candidate.id.uuidString)")
            print(" Name:                 \(candidate.name)")
            print(" Enrolled At:          \(candidate.selectedAt)")
            print(" Cryptographic Proof:  NONE (Local unverified peer; public BLE is not authenticated)")
            print(" Security Disclaimer:  \(candidate.securityDisclaimer)")
            print("================================================================================")
        }
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

        diagnostics.onEventLogged = { event in
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
            self?.diagnostics.proximityEngine.tick()
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

let cli = AuraSenseCLI()
cli.run()
