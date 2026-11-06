import Foundation
import Security

/// Tamper-resistant record of the trusted (bound) BLE device.
///
/// `selectedDeviceID` lives in UserDefaults, which any process running as the user can rewrite
/// (`defaults write/delete`). The authoritative copy is kept here in the Keychain, and the engine
/// restores UserDefaults from it whenever they disagree, so the binding can only be changed through
/// the Mac-password-gated bind/unbind flow.
///
/// The record is stored in the item's attributes (`kSecAttrGeneric`), which can be read without
/// decrypting the item. A Keychain access prompt (for example after an app update changes the
/// code signature) therefore never blocks reading it.
public struct TrustedDeviceRecord: Codable, Equatable {
    public let id: String
    public let name: String
    public let category: String
}

public enum TrustedDeviceRecordStore {
    private static let service = "com.aurasense.mac.trusted-device"
    private static let account = "binding"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public static func load() -> TrustedDeviceRecord? {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attrs = result as? [String: Any],
              let blob = attrs[kSecAttrGeneric as String] as? Data,
              let record = try? JSONDecoder().decode(TrustedDeviceRecord.self, from: blob),
              UUID(uuidString: record.id) != nil else {
            return nil
        }
        return record
    }

    @discardableResult
    public static func save(_ record: TrustedDeviceRecord) -> Bool {
        guard let blob = try? JSONEncoder().encode(record) else { return false }
        let update: [String: Any] = [
            kSecAttrGeneric as String: blob,
            kSecAttrLabel as String: "AuraSense Trusted Device",
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }

        var add = baseQuery
        add[kSecAttrGeneric as String] = blob
        add[kSecAttrLabel as String] = "AuraSense Trusted Device"
        add[kSecValueData as String] = Data("bound".utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public static func clear() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
