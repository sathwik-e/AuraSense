import Testing
import Foundation
@testable import AuraSenseCore

struct SettingsTests {

    @Test func testUserSettingsDefaults() {
        let settings = UserSettings.default
        #expect(!settings.isAutoLockEnabled)
        #expect(settings.isAutoWakeEnabled)
        #expect(!settings.isLaunchAtLoginEnabled)
        #expect(settings.nearGateRSSI == -60.0)
        #expect(settings.farGateRSSI == -75.0)
        #expect(settings.farDwellDuration == 10.0)
        #expect(settings.countdownDuration == 5)
        #expect(settings.signalLossTimeout == 15)
    }

    @Test func testInMemorySettingsStore() throws {
        let store = InMemorySettingsStore()
        #expect(store.currentSettings == .default)

        var modified = store.currentSettings
        modified.isAutoLockEnabled = true
        modified.countdownDuration = 3
        try store.save(settings: modified)

        #expect(store.currentSettings.isAutoLockEnabled)
        #expect(store.currentSettings.countdownDuration == 3)
    }

    @Test func testFileSettingsStorePersistence() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aurasense_test_settings_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let store1 = FileSettingsStore(fileURL: tempURL)
        var settings = store1.currentSettings
        settings.isAutoLockEnabled = true
        settings.nearGateRSSI = -55.0
        settings.signalLossTimeout = 45
        try store1.save(settings: settings)

        // Reload in new store instance
        let store2 = FileSettingsStore(fileURL: tempURL)
        #expect(store2.currentSettings.isAutoLockEnabled)
        #expect(store2.currentSettings.nearGateRSSI == -55.0)
        #expect(store2.currentSettings.signalLossTimeout == 45)
    }

    @Test func testLegacySettingsDecodeSignalLossTimeoutDefault() throws {
        let legacy = Data("""
        {"isAutoLockEnabled":true,"isAutoWakeEnabled":false,"isLaunchAtLoginEnabled":false,"nearGateRSSI":-58,"farGateRSSI":-76,"farDwellDuration":8,"countdownDuration":6}
        """.utf8)
        let settings = try JSONDecoder().decode(UserSettings.self, from: legacy)
        #expect(settings.isAutoLockEnabled)
        #expect(settings.signalLossTimeout == 15)
        #expect(settings.hasValidProximitySettings)
    }

    @Test func testSettingsStoreRejectsInvalidThresholdOrdering() {
        let store = InMemorySettingsStore()
        var settings = store.currentSettings
        settings.nearGateRSSI = -70
        settings.farGateRSSI = -68
        #expect(throws: SettingsStoreError.self) {
            try store.save(settings: settings)
        }
    }
}
