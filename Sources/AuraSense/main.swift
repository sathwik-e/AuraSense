import Foundation
import AuraSenseCore

final class AuraSenseCLI: @unchecked Sendable {
    private let scanner: any BLEScannerProtocol
    private let diagnostics: DiagnosticsManager
    private var isRunning: Bool = false
    private let runLoop = RunLoop.current

    init(scanner: any BLEScannerProtocol = CoreBluetoothScanner()) {
        self.scanner = scanner
        self.diagnostics = DiagnosticsManager()
        self.scanner.delegate = diagnostics
    }

    func run() {
        let args = CommandLine.arguments

        if args.contains("--help") || args.contains("-h") {
            printHelp()
            return
        }

        if let candidateArg = parseCandidateArg(args: args) {
            let candidateUUID = UUID(uuidString: candidateArg) ?? UUID()
            let candidate = CandidateDevice(id: candidateUUID, name: candidateArg)
            diagnostics.classifier.setCandidate(candidate)
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

        OPTIONS:
            --candidate <name|id>  Track a specific companion device candidate (unverified local candidate)
            --duration <seconds>   Scan duration in seconds (for 'scan' command, default: 5)
            --json                 Output diagnostic reports in structured JSON format
            -h, --help             Show this help message

        NOTE:
            Security lock and unlock actions are disabled in Phase 1.
            Candidate device identity is local and non-cryptographic per ARCHITECTURE.md.
        """)
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

        // Timer for periodic status printouts every 5 seconds
        let timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let snapshot = self.diagnostics.snapshot(from: self.scanner)
            print("\n[Telemetry Heartbeat]")
            print(ConsoleDiagnosticsView.renderSnapshot(snapshot))
        }

        while isRunning {
            runLoop.run(until: Date(timeIntervalSinceNow: 1.0))
        }

        timer.invalidate()
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
