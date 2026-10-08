import Foundation

/// User-configurable application preferences.
public struct UserSettings: Codable, Sendable, Equatable {
    public var isAutoLockEnabled: Bool
    public var isAutoWakeEnabled: Bool
    public var isLaunchAtLoginEnabled: Bool
    public var nearGateRSSI: Double
    public var farGateRSSI: Double
    public var farDwellDuration: TimeInterval
    public var countdownDuration: Int

    public init(
        isAutoLockEnabled: Bool = false,
        isAutoWakeEnabled: Bool = true,
        isLaunchAtLoginEnabled: Bool = false,
        nearGateRSSI: Double = -60.0,
        farGateRSSI: Double = -75.0,
        farDwellDuration: TimeInterval = 10.0,
        countdownDuration: Int = 5
    ) {
        self.isAutoLockEnabled = isAutoLockEnabled
        self.isAutoWakeEnabled = isAutoWakeEnabled
        self.isLaunchAtLoginEnabled = isLaunchAtLoginEnabled
        self.nearGateRSSI = nearGateRSSI
        self.farGateRSSI = farGateRSSI
        self.farDwellDuration = farDwellDuration
        self.countdownDuration = countdownDuration
    }

    public static let `default` = UserSettings()
}

/// Interface for storing and retrieving user preferences.
public protocol SettingsStoreProtocol: Sendable {
    var currentSettings: UserSettings { get }
    func save(settings: UserSettings) throws
}

/// Persistent JSON file settings store in Application Support.
public final class FileSettingsStore: SettingsStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    public let settingsFileURL: URL
    private var cachedSettings: UserSettings

    public var currentSettings: UserSettings {
        lock.lock()
        defer { lock.unlock() }
        return cachedSettings
    }

    public init(fileURL: URL? = nil) {
        let url: URL
        if let custom = fileURL {
            url = custom
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("AuraSense")
                ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AuraSense")
            try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
            url = appSupport.appendingPathComponent("settings.json")
        }

        self.settingsFileURL = url

        if FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(UserSettings.self, from: data) {
            self.cachedSettings = decoded
        } else {
            self.cachedSettings = .default
        }
    }

    public func save(settings: UserSettings) throws {
        lock.lock()
        defer { lock.unlock() }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: settingsFileURL, options: .atomic)
        self.cachedSettings = settings
    }
}

/// In-memory settings store for testing.
public final class InMemorySettingsStore: SettingsStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var settings: UserSettings

    public var currentSettings: UserSettings {
        lock.lock()
        defer { lock.unlock() }
        return settings
    }

    public init(initialSettings: UserSettings = .default) {
        self.settings = initialSettings
    }

    public func save(settings: UserSettings) throws {
        lock.lock()
        defer { lock.unlock() }
        self.settings = settings
    }
}
