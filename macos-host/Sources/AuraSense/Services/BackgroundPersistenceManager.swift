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
    /// File descriptor holding the single-instance lock, or -1 when this copy doesn't hold it.
    private var instanceLockFD: Int32 = -1

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
    ///
    /// The running-apps list can lag behind a process that started a moment ago, so two copies
    /// launched together (the LaunchAgent and a manual open) could each miss the other and both
    /// keep running. An exclusive lock file decides instead: only one copy can hold it, the
    /// launchd copy always waits for it, and a manually opened copy yields to whoever has it.
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

        for peer in peers {
            // A peer launched before the binary on disk was replaced is a stale build: replace it.
            if let launched = peer.launchDate, let built = myExecutableDate, launched < built {
                peer.forceTerminate()
                terminatedStalePIDs.insert(peer.processIdentifier)
            }
        }

        guard isMainAppBundle else { return .continueLaunching }

        // A stale copy we just terminated releases the lock as it exits.
        let staleGrace: TimeInterval = terminatedStalePIDs.isEmpty ? 0 : 3

        if launchedByAgent {
            if acquireInstanceLock(timeout: staleGrace) { return .continueLaunching }
            // A manually opened copy owns the lock. launchd's instance owns protection, so ask that
            // copy to step aside and take over its UI. It may still be starting up and not yet
            // listening, so keep asking until the lock is free.
            forceVisibleStart = true
            if acquireInstanceLock(timeout: 8, whileWaiting: { [weak self] in self?.requestManualPeersExit() }) {
                return .continueLaunching
            }
            // It never answered: stop it rather than run two copies.
            for peer in otherInstances() { peer.forceTerminate() }
            _ = acquireInstanceLock(timeout: 3)
            return .continueLaunching
        }

        guard acquireInstanceLock(timeout: staleGrace) else {
            // Someone opened AuraSense while it is already running: show that instance instead.
            DistributedNotificationCenter.default().postNotificationName(
                Self.showDashboardNotification,
                object: nil,
                userInfo: AuraLaunchMode.requestedGuidedSetup ? ["setup": "1"] : nil,
                deliverImmediately: true
            )
            return .exitHandedOff
        }

        // A manual launch from /Applications hands protection to launchd so it is relaunched after force quit.
        if !launchedByAgent, keepRunningInBackground, isRunningFromApplications {
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

    // MARK: - Single-Instance Lock

    /// ~/Library/Application Support/AuraSense/instance.lock
    private static var instanceLockURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("AuraSense", isDirectory: true).appendingPathComponent("instance.lock")
    }

    /// Takes the exclusive instance lock, retrying until `timeout`. The lock is held for the life
    /// of the process; the system releases it when the process exits, crashes or is killed.
    /// If the lock file can't be opened at all, this returns true so AuraSense still starts.
    private func acquireInstanceLock(timeout: TimeInterval, whileWaiting: (() -> Void)? = nil) -> Bool {
        if instanceLockFD >= 0 { return true }
        let url = Self.instanceLockURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // O_CLOEXEC: helper processes (launchctl, the reopen script) must not inherit the lock.
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return true }

        let deadline = Date().addingTimeInterval(timeout)
        var lastNudge = Date.distantPast
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                instanceLockFD = fd
                let pid = "\(ProcessInfo.processInfo.processIdentifier)\n"
                _ = ftruncate(fd, 0)
                _ = pid.withCString { write(fd, $0, strlen($0)) }
                return true
            }
            if Date() >= deadline { break }
            if let whileWaiting, Date().timeIntervalSince(lastNudge) >= 0.5 {
                whileWaiting()
                lastNudge = Date()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        close(fd)
        return false
    }

    /// Other running copies of the main app, excluding ones already terminated as stale.
    private func otherInstances() -> [NSRunningApplication] {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: "com.aurasense.mac.app")
            .filter { $0.processIdentifier != currentPID && !$0.isTerminated && !terminatedStalePIDs.contains($0.processIdentifier) }
    }

    /// Asks every other copy to exit. Only manually opened copies obey (see `startListening`).
    private func requestManualPeersExit() {
        for peer in otherInstances() {
            DistributedNotificationCenter.default().postNotificationName(
                Self.requestExitNotification,
                object: String(peer.processIdentifier),
                userInfo: nil,
                deliverImmediately: true
            )
        }
    }

    /// Waits for launchd's instance to come up. While this copy holds the lock, that instance
    /// keeps asking it to exit, which is the signal. (Any other AuraSense copy seen here could
    /// be a second manual open that is about to yield, so its presence alone proves nothing.)
    private func waitForAgentInstance(timeout: TimeInterval) -> Bool {
        var agentAsked = false
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.requestExitNotification,
            object: String(ProcessInfo.processInfo.processIdentifier),
            queue: nil
        ) { _ in agentAsked = true }
        defer { DistributedNotificationCenter.default().removeObserver(observer) }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !agentAsked {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return agentAsked
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
