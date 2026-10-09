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
    public var signalLossTimeout: TimeInterval

    public init(
        isAutoLockEnabled: Bool = false,
        isAutoWakeEnabled: Bool = true,
        isLaunchAtLoginEnabled: Bool = false,
        nearGateRSSI: Double = -60.0,
        farGateRSSI: Double = -75.0,
        farDwellDuration: TimeInterval = 10.0,
        countdownDuration: Int = 5,
        signalLossTimeout: TimeInterval = 15
    ) {
        self.isAutoLockEnabled = isAutoLockEnabled
        self.isAutoWakeEnabled = isAutoWakeEnabled
        self.isLaunchAtLoginEnabled = isLaunchAtLoginEnabled
        self.nearGateRSSI = nearGateRSSI
        self.farGateRSSI = farGateRSSI
        self.farDwellDuration = farDwellDuration
        self.countdownDuration = countdownDuration
        self.signalLossTimeout = signalLossTimeout
    }

    private enum CodingKeys: String, CodingKey {
        case isAutoLockEnabled, isAutoWakeEnabled, isLaunchAtLoginEnabled
        case nearGateRSSI, farGateRSSI, farDwellDuration, countdownDuration, signalLossTimeout
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isAutoLockEnabled: try values.decodeIfPresent(Bool.self, forKey: .isAutoLockEnabled) ?? false,
            isAutoWakeEnabled: try values.decodeIfPresent(Bool.self, forKey: .isAutoWakeEnabled) ?? true,
            isLaunchAtLoginEnabled: try values.decodeIfPresent(Bool.self, forKey: .isLaunchAtLoginEnabled) ?? false,
            nearGateRSSI: try values.decodeIfPresent(Double.self, forKey: .nearGateRSSI) ?? -60,
            farGateRSSI: try values.decodeIfPresent(Double.self, forKey: .farGateRSSI) ?? -75,
            farDwellDuration: try values.decodeIfPresent(TimeInterval.self, forKey: .farDwellDuration) ?? 10,
            countdownDuration: try values.decodeIfPresent(Int.self, forKey: .countdownDuration) ?? 5,
            signalLossTimeout: try values.decodeIfPresent(TimeInterval.self, forKey: .signalLossTimeout) ?? 15
        )
    }

    public var hasValidProximitySettings: Bool {
        nearGateRSSI.isFinite && farGateRSSI.isFinite &&
        nearGateRSSI <= -40 && nearGateRSSI >= -85 &&
        farGateRSSI <= -45 && farGateRSSI >= -120 &&
        nearGateRSSI - farGateRSSI >= 3 &&
        farDwellDuration.isFinite && (1...120).contains(farDwellDuration) &&
        (3...30).contains(countdownDuration) &&
        signalLossTimeout.isFinite && (5...300).contains(signalLossTimeout)
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
           let decoded = try? JSONDecoder().decode(UserSettings.self, from: data),
           decoded.hasValidProximitySettings {
            self.cachedSettings = decoded
        } else {
            self.cachedSettings = .default
        }
    }

    public func save(settings: UserSettings) throws {
        guard settings.hasValidProximitySettings else {
            throw SettingsStoreError.invalidProximitySettings
        }
        lock.lock()
        defer { lock.unlock() }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: settingsFileURL, options: .atomic)
        self.cachedSettings = settings
    }
}

public enum SettingsStoreError: LocalizedError {
    case invalidProximitySettings

    public var errorDescription: String? {
        "Proximity thresholds and timeouts are outside the supported range."
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
        guard settings.hasValidProximitySettings else {
            throw SettingsStoreError.invalidProximitySettings
        }
        lock.lock()
        defer { lock.unlock() }
        self.settings = settings
    }
}
