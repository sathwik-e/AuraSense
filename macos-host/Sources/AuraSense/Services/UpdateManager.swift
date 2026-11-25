import Foundation
import AppKit
import SwiftUI

/// Checks GitHub Releases for a newer AuraSense, downloads `AuraSense.app.zip`, and swaps the
/// app in /Applications with a small helper script that runs after AuraSense exits.
@MainActor
public final class UpdateManager: ObservableObject {
    public static let shared = UpdateManager()

    private static let repository = "sathwik-e/AuraSense"
    private static let assetName = "AuraSense.app.zip"
    private static let checkInterval: TimeInterval = 24 * 60 * 60
    private static let skippedVersionKey = "aurasense.update.skippedVersion"
    private static let lastCheckKey = "aurasense.update.lastCheck"

    @AppStorage("aurasense.update.autoCheck") public var automaticallyChecks: Bool = true

    @Published public private(set) var isChecking = false
    @Published public private(set) var isInstalling = false
    @Published public private(set) var statusText: String = ""

    private var timer: Timer?

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    private init() {}

    public var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    /// Starts the background schedule: first check shortly after launch, then once a day.
    public func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.backgroundCheckIfDue() }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            self.backgroundCheckIfDue()
        }
    }

    private func backgroundCheckIfDue() {
        guard automaticallyChecks, !isChecking, !isInstalling else { return }
        // Never put an alert over the lock screen.
        guard !MacLockUnlockController.shared.isScreenLocked else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard Date().timeIntervalSince1970 - last >= Self.checkInterval else { return }
        Task { await checkForUpdates(userInitiated: false) }
    }

    // MARK: - Checking

    public func checkForUpdates(userInitiated: Bool) async {
        guard !isChecking, !isInstalling else { return }
        isChecking = true
        statusText = "Checking for updates…"
        defer { isChecking = false }

        do {
            let release = try await fetchLatestRelease()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
            let latest = Self.normalized(release.tag_name)

            guard !release.draft, !release.prerelease,
                  Self.isVersion(latest, newerThan: currentVersion) else {
                statusText = "AuraSense \(currentVersion) is up to date."
                if userInitiated { showInfo("You're up to date", "AuraSense \(currentVersion) is the latest version.") }
                return
            }
            if !userInitiated, UserDefaults.standard.string(forKey: Self.skippedVersionKey) == latest {
                statusText = "Version \(latest) skipped."
                return
            }
            guard let asset = release.assets.first(where: { $0.name == Self.assetName }) else {
                statusText = "Version \(latest) has no app download yet."
                if userInitiated { showInfo("Update not ready", "Version \(latest) was found, but its download isn't attached yet. Try again later.") }
                return
            }
            statusText = "Version \(latest) is available."
            promptToInstall(version: latest, notes: release.body, url: asset.browser_download_url)
        } catch {
            statusText = "Couldn't check for updates."
            if userInitiated { showInfo("Couldn't check for updates", error.localizedDescription) }
        }
    }

    private func fetchLatestRelease() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AuraSense/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Self.error("GitHub answered with status \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    // MARK: - Prompt

    private func promptToInstall(version: String, notes: String?, url: URL) {
        DockVisibilityManager.shared.showAppInForeground()
        NSApplication.shared.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "AuraSense \(version) is available"
        var info = "You have \(currentVersion). AuraSense will restart to finish the update."
        if let notes, !notes.isEmpty {
            let trimmed = notes.count > 600 ? String(notes.prefix(600)) + "…" : notes
            info += "\n\n" + trimmed
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Install and Restart")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { await install(version: version, from: url) }
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(version, forKey: Self.skippedVersionKey)
        default:
            break
        }
    }

    // MARK: - Installing

    private func install(version: String, from url: URL) async {
        guard MacLockUnlockController.shared.isRunningFromApplications else {
            showInfo("Move AuraSense to Applications first", "Automatic updates replace /Applications/AuraSense.app. Install AuraSense there, then check again.")
            return
        }
        isInstalling = true
        statusText = "Downloading AuraSense \(version)…"
        defer { isInstalling = false }

        do {
            let fm = FileManager.default
            let workDir = fm.temporaryDirectory.appendingPathComponent("AuraSenseUpdate-\(UUID().uuidString)")
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

            let (downloaded, response) = try await URLSession.shared.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw Self.error("The download failed.")
            }
            let zipURL = workDir.appendingPathComponent(Self.assetName)
            try fm.moveItem(at: downloaded, to: zipURL)

            statusText = "Preparing update…"
            let extractDir = workDir.appendingPathComponent("extracted")
            try Self.run("/usr/bin/ditto", ["-x", "-k", zipURL.path, extractDir.path])

            let newApp = extractDir.appendingPathComponent("AuraSense.app")
            guard let bundle = Bundle(url: newApp),
                  bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
                  let newVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
                  Self.isVersion(newVersion, newerThan: currentVersion) else {
                throw Self.error("The downloaded app isn't a newer AuraSense.")
            }
            // Refuse a damaged or tampered bundle.
            try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])

            let script = workDir.appendingPathComponent("install.sh")
            try Self.installerScript.write(to: script, atomically: true, encoding: .utf8)

            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/bash")
            helper.arguments = [
                script.path,
                String(ProcessInfo.processInfo.processIdentifier),
                newApp.path,
                Bundle.main.bundleURL.path,
                workDir.path
            ]
            try helper.run()

            statusText = "Restarting…"
            CredentialInjectionGuard.shared.wipeTransientClipboardNow()
            // Exit status 0 so the KeepAlive agent doesn't relaunch the old copy in the meantime.
            exit(0)
        } catch {
            statusText = "Update failed."
            showInfo("Update failed", error.localizedDescription)
        }
    }

    /// Waits for AuraSense to exit, swaps the bundle (restoring the old one if the copy fails),
    /// reloads the background agent and reopens the app.
    private static let installerScript = """
    #!/bin/bash
    PID="$1"; NEW="$2"; DEST="$3"; WORK="$4"
    for _ in $(seq 1 100); do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
    launchctl bootout "gui/$(id -u)/com.aurasense.mac.agent" 2>/dev/null
    rm -rf "$DEST.old"
    mv "$DEST" "$DEST.old" || exit 1
    if ditto "$NEW" "$DEST"; then
        rm -rf "$DEST.old"
    else
        rm -rf "$DEST"; mv "$DEST.old" "$DEST"
    fi
    xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
    AGENT="$HOME/Library/LaunchAgents/com.aurasense.mac.agent.plist"
    [ -f "$AGENT" ] && launchctl bootstrap "gui/$(id -u)" "$AGENT" 2>/dev/null
    open "$DEST"
    rm -rf "$WORK"
    """

    // MARK: - Helpers

    private func showInfo(_ title: String, _ message: String) {
        DockVisibilityManager.shared.showAppInForeground()
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw error("\((tool as NSString).lastPathComponent) failed (status \(p.terminationStatus)).")
        }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "AuraSenseUpdate", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// "v1.3" -> "1.3"
    static func normalized(_ tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    /// Numeric, component-wise comparison: 1.10 > 1.9, 1.3 == 1.3.0.
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// Settings tab for updates.
public struct UpdatesSettingsView: View {
    @ObservedObject private var updater = UpdateManager.shared

    public init() {}

    public var body: some View {
        Form {
            Section {
                LabeledContent("Current version", value: updater.currentVersion)
                Toggle("Check for updates automatically", isOn: $updater.automaticallyChecks)
            }
            Section {
                HStack {
                    Button("Check Now") {
                        Task { await updater.checkForUpdates(userInitiated: true) }
                    }
                    .disabled(updater.isChecking || updater.isInstalling)
                    if updater.isChecking || updater.isInstalling {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    Text(updater.statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
