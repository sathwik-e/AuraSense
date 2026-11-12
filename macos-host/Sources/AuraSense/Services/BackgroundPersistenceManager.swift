import Foundation
import AppKit
import ServiceManagement

/// Keeps AuraSense protecting the Mac after the user chooses Quit.
///
/// * **Quit (⌘Q / menu)** hides AuraSense's windows and keeps proximity lock/unlock running
///   from the menu bar.
/// * A per-user LaunchAgent (`~/Library/LaunchAgents/com.aurasense.mac.agent.plist`) with
///   `KeepAlive.SuccessfulExit = false` makes launchd relaunch AuraSense if it is
///   force-quit, killed, or crashes, and starts it at login.
/// * **Stop Completely** (Mac password required) exits with status 0, which launchd treats
///   as intentional, so it is not relaunched until the next login or manual launch.
/// * Logout, restart, and shutdown always terminate normally.
@MainActor
public final class BackgroundPersistenceManager: ObservableObject {
    public static let shared = BackgroundPersistenceManager()

    public static let agentLabel = "com.aurasense.mac.agent"
    public static let agentLaunchArgument = "--launched-by-agent"
    public static let installedAppPath = "/Applications/AuraSense.app"
    static let showDashboardNotification = Notification.Name("com.aurasense.mac.showDashboard")
    static let requestExitNotification = Notification.Name("com.aurasense.mac.requestExit")
    private static let pendingShowDashboardKey = "aurasense.pendingShowDashboardOnAgentLaunch"

    @Published public private(set) var keepRunningInBackground: Bool
    @Published public private(set) var isAgentInstalled: Bool = false
    @Published public private(set) var statusMessage: String?

    /// Set once termination is genuinely intended (Stop Completely, logout, hand-off).
    public private(set) var allowTermination = false

    public let launchedByAgent: Bool = CommandLine.arguments.contains(BackgroundPersistenceManager.agentLaunchArgument)
    private var terminatedStalePIDs = Set<pid_t>()
    /// When a logout/restart/shutdown began. Honored only briefly, so a cancelled logout
    /// doesn't leave Quit permanently able to stop protection without the password.
    private var powerOffRequestedAt: Date?
    /// The launchd instance replaced a manually opened one, so it must show its UI.
    private var forceVisibleStart = false

    private init() {
        if UserDefaults.standard.object(forKey: "aurasense.keepRunningInBackground") == nil {
            UserDefaults.standard.set(true, forKey: "aurasense.keepRunningInBackground")
        }
        keepRunningInBackground = UserDefaults.standard.bool(forKey: "aurasense.keepRunningInBackground")
        isAgentInstalled = FileManager.default.fileExists(atPath: Self.agentPlistURL.path)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.powerOffRequestedAt = Date() }
        }
    }

    // MARK: - Environment

    public var isMainAppBundle: Bool {
        Bundle.main.bundleIdentifier == "com.aurasense.mac.app"
    }

    public var isRunningFromApplications: Bool {
        Bundle.main.bundlePath == Self.installedAppPath
    }

    static var agentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    private var guiDomain: String { "gui/\(getuid())" }

    // MARK: - Settings

    public func enableKeepRunningInBackground() {
        keepRunningInBackground = true
        UserDefaults.standard.set(true, forKey: "aurasense.keepRunningInBackground")
        if isMainAppBundle, !launchedByAgent, isRunningFromApplications {
            // Hand protection to launchd now so force-quit/crash relaunch works this session.
            // The launchd instance asks this one to exit and reopens the dashboard.
            statusMessage = "Moving AuraSense under macOS launch management…"
            installOrRefreshAgent(loadNow: true)
        } else {
            installOrRefreshAgent(loadNow: false)
        }
    }

    /// Turning protection off requires the Mac password, because it lets AuraSense be quit for good.
    public func requestDisableKeepRunningInBackground() {
        MacPasswordAuthorizer.shared.authorize(.disableBackgroundProtection) { [weak self] granted in
            guard let self, granted else { return }
            self.keepRunningInBackground = false
            UserDefaults.standard.set(false, forKey: "aurasense.keepRunningInBackground")
            self.removeAgentPlist()
            if self.launchedByAgent {
                // Booting out our own job would SIGTERM this process. Quit now exits with status 0,
                // which launchd does not relaunch; the job is not loaded again at next login.
                self.statusMessage = "Background protection is off. Quit now closes AuraSense; it won't start at login. (Until you quit, a crash could still relaunch it once.)"
            } else {
                _ = self.runLaunchctl(["bootout", "\(self.guiDomain)/\(Self.agentLabel)"])
                self.statusMessage = "Background protection is off. Quit now closes AuraSense."
            }
        }
    }

    // MARK: - LaunchAgent

    /// Writes the LaunchAgent plist (pointing at /Applications/AuraSense.app) when appropriate.
    /// The job is registered with launchd for the current session only when `loadNow` is true,
    /// because bootstrapping starts a new launchd-owned instance immediately.
    @discardableResult
    public func installOrRefreshAgent(loadNow: Bool) -> Bool {
        guard isMainAppBundle, keepRunningInBackground else { return false }
        guard FileManager.default.fileExists(atPath: "\(Self.installedAppPath)/Contents/MacOS/AuraSense") else {
            statusMessage = "Install AuraSense in /Applications to enable relaunch after force quit."
            return false
        }

        let plist: [String: Any] = [
            "Label": Self.agentLabel,
            "ProgramArguments": ["\(Self.installedAppPath)/Contents/MacOS/AuraSense", Self.agentLaunchArgument],
            "KeepAlive": ["SuccessfulExit": false],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
            "ThrottleInterval": 10,
        ]
        do {
            let url = Self.agentPlistURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            let existing = try? Data(contentsOf: url)
            if existing != data {
                try data.write(to: url, options: .atomic)
            }
            isAgentInstalled = true
        } catch {
            statusMessage = "Couldn't write the LaunchAgent: \(error.localizedDescription)"
            return false
        }

        if loadNow {
            if isAgentLoaded() {
                _ = runLaunchctl(["kickstart", "\(guiDomain)/\(Self.agentLabel)"])
            } else {
                _ = runLaunchctl(["bootstrap", guiDomain, Self.agentPlistURL.path])
            }
        }
        return true
    }

    private func removeAgentPlist() {
        // Deliberately no `launchctl bootout`: that would SIGTERM this very process when it is
        // the launchd-owned instance. Removing the plist stops future loads; the current job
        // simply isn't relaunched after a normal (status 0) exit.
        try? FileManager.default.removeItem(at: Self.agentPlistURL)
        isAgentInstalled = false
    }

    func isAgentLoaded() -> Bool {
        runLaunchctl(["print", "\(guiDomain)/\(Self.agentLabel)"]) == 0
    }

    @discardableResult
    private func runLaunchctl(_ args: [String]) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus
        } catch {
            return -1
        }
    }

    // MARK: - Launch Coordination

    public enum LaunchDecision {
        case continueLaunching
        case exitHandedOff
    }

    /// Resolves duplicate instances at launch. Returns `.exitHandedOff` when this process
    /// should exit because another (launchd-managed or current) instance owns protection.
    public func coordinateLaunch() -> LaunchDecision {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let myExecutableDate = Self.executableModificationDate(Bundle.main.executableURL)

        // Installer instances are always replaced by the real app.
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.aurasense.mac.installer")
        where app.processIdentifier != currentPID && isMainAppBundle {
            app.forceTerminate()
        }

        let peers = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.aurasense.mac.app")
            .filter { $0.processIdentifier != currentPID }

        var livePeers: [NSRunningApplication] = []
        for peer in peers {
            // A peer launched before the binary on disk was replaced is a stale build: replace it.
            if let launched = peer.launchDate, let built = myExecutableDate, launched < built {
                peer.forceTerminate()
                terminatedStalePIDs.insert(peer.processIdentifier)
                continue
            }
            livePeers.append(peer)
            guard isMainAppBundle else { continue }
            if launchedByAgent {
                // launchd's instance owns protection; ask the manually launched one to step aside
                // and take over its UI (decided here, not via a racy flag written by the peer).
                forceVisibleStart = true
                DistributedNotificationCenter.default().postNotificationName(
                    Self.requestExitNotification,
                    object: String(peer.processIdentifier),
                    userInfo: nil,
                    deliverImmediately: true
                )
            } else {
                // Someone opened AuraSense while it is already running: show that instance instead.
                DistributedNotificationCenter.default().postNotificationName(
                    Self.showDashboardNotification,
                    object: nil,
                    userInfo: AuraLaunchMode.requestedGuidedSetup ? ["setup": "1"] : nil,
                    deliverImmediately: true
                )
                return .exitHandedOff
            }
        }

        // A manual launch from /Applications hands protection to launchd so it is relaunched after force quit.
        if isMainAppBundle, !launchedByAgent, keepRunningInBackground, isRunningFromApplications, livePeers.isEmpty {
            UserDefaults.standard.set(true, forKey: Self.pendingShowDashboardKey)
            if installOrRefreshAgent(loadNow: true), waitForAgentInstance(timeout: 4.0) {
                return .exitHandedOff
            }
            // launchd didn't start it: keep running ourselves.
            UserDefaults.standard.removeObject(forKey: Self.pendingShowDashboardKey)
        }
        return .continueLaunching
    }

    /// Whether this (agent) launch should open the dashboard because the user opened the app.
    public func consumePendingShowDashboard() -> Bool {
        let pending = UserDefaults.standard.bool(forKey: Self.pendingShowDashboardKey)
        UserDefaults.standard.removeObject(forKey: Self.pendingShowDashboardKey)
        return pending || forceVisibleStart
    }

    private func waitForAgentInstance(timeout: TimeInterval) -> Bool {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: "com.aurasense.mac.app")
                .filter { $0.processIdentifier != currentPID && !$0.isTerminated && !terminatedStalePIDs.contains($0.processIdentifier) }
            if !others.isEmpty { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    /// When the executable on disk last changed. ditto/rename preserve the build mtime, so the
    /// inode change time (ctime, set at install) is included to detect an updated install.
    private static func executableModificationDate(_ url: URL?) -> Date? {
        guard let url,
              let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .attributeModificationDateKey]) else {
            return nil
        }
        return [values.contentModificationDate, values.attributeModificationDate].compactMap { $0 }.max()
    }

    /// Listens for hand-off requests from other AuraSense processes.
    public func startListening(showDashboard: @escaping @MainActor (_ openGuidedSetup: Bool) -> Void) {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Self.showDashboardNotification, object: nil, queue: .main) { note in
            let wantsSetup = (note.userInfo?["setup"] as? String) == "1"
            Task { @MainActor in showDashboard(wantsSetup) }
        }
        dnc.addObserver(
            forName: Self.requestExitNotification,
            object: String(ProcessInfo.processInfo.processIdentifier),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.launchedByAgent else { return }
                // The launchd instance already decided to show its UI (forceVisibleStart).
                self.allowTermination = true
                NSApplication.shared.terminate(nil)
            }
        }
    }

    // MARK: - Reopen From /Applications

    /// Quits this copy of AuraSense (for example one running from the disk image) and reopens the
    /// copy installed in /Applications. A small helper waits for this process to exit first, so
    /// the installed copy is not treated as a duplicate instance and handed back to this one.
    /// Returns false, leaving this copy running, if the installed app is missing or the helper
    /// could not be started.
    @discardableResult
    public func relaunchFromApplications(openGuidedSetup: Bool) -> Bool {
        guard FileManager.default.fileExists(atPath: "\(Self.installedAppPath)/Contents/MacOS/AuraSense") else {
            return false
        }

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c",
            "i=0; while /bin/kill -0 \"$1\" 2>/dev/null && [ \"$i\" -lt 50 ]; do /bin/sleep 0.2; i=$((i+1)); done; /usr/bin/open -n \"$0\"",
            Self.installedAppPath,
            String(ProcessInfo.processInfo.processIdentifier)
        ]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do {
            try helper.run()
        } catch {
            statusMessage = "Couldn't reopen AuraSense from Applications: \(error.localizedDescription)"
            return false
        }

        if openGuidedSetup {
            // Both copies share the same preferences, so the installed copy picks this up.
            UserDefaults.standard.set(true, forKey: WindowRouter.pendingGuidedSetupDefaultsKey)
        }
        allowTermination = true
        NSApplication.shared.terminate(nil)
        return true
    }

    // MARK: - Quit Handling

    /// Decides whether a terminate request should really quit.
    public func shouldTerminate() -> NSApplication.TerminateReply {
        if allowTermination || !keepRunningInBackground || !isMainAppBundle {
            return .terminateNow
        }
        if let started = powerOffRequestedAt, Date().timeIntervalSince(started) < 60 {
            allowTermination = true
            return .terminateNow
        }
        if Self.isSystemInitiatedQuit() {
            allowTermination = true
            return .terminateNow
        }
        DockVisibilityManager.shared.hideFromDockImmediately()
        BLEProximityEngine.shared.appendLog(
            kind: .systemState,
            title: "AuraSense Keeps Running in the Background",
            detail: "Quit hid AuraSense. Proximity protection is still active from the menu bar. Use Stop Completely to fully quit."
        )
        return .terminateCancel
    }

    /// Fully quits AuraSense after Mac password verification.
    public func requestStopCompletely() {
        MacPasswordAuthorizer.shared.authorize(.stopAuraSenseCompletely) { [weak self] granted in
            guard let self, granted else { return }
            self.allowTermination = true
            NSApplication.shared.terminate(nil)
        }
    }

    private static func isSystemInitiatedQuit() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == kCoreEventClass,
              event.eventID == kAEQuitApplication,
              let reason = event.attributeDescriptor(forKeyword: kAEQuitReason) else {
            return false
        }
        switch reason.enumCodeValue {
        case kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAEShowShutdownDialog,
             kAERestart, kAEShutDown:
            return true
        default:
            return false
        }
    }
}
