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
        try store1.save(settings: settings)

        // Reload in new store instance
        let store2 = FileSettingsStore(fileURL: tempURL)
        #expect(store2.currentSettings.isAutoLockEnabled)
        #expect(store2.currentSettings.nearGateRSSI == -55.0)
    }
}
