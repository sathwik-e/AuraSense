import Foundation
import Security

/// Manages secure storage and retrieval of the macOS login password in the system Keychain.
/// Used exclusively by MacLockUnlockController when typing credentials via Accessibility events.
public final class KeychainManager: @unchecked Sendable {
    public static let shared = KeychainManager()

    private let serviceName = "com.aurasense.mac.unlock-credentials"
    private let accountName = "macOSLoginPassword"

    private init() {}

    public enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)
        case invalidDataEncoding

        public var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                if let msg = SecCopyErrorMessageString(status, nil) as String? {
                    return "Keychain error (\(status)): \(msg)"
                }
                return "Keychain error status: \(status)"
            case .invalidDataEncoding:
                return "Unable to encode or decode password data in UTF-8."
            }
        }
    }

    /// Saves or updates the macOS unlock password inside the user's login Keychain.
    public func savePassword(_ password: String) throws {
        guard let data = password.data(using: .utf8) else {
            throw KeychainError.invalidDataEncoding
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let attributesToUpdate: [String: Any] = [
                kSecValueData as String: data
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(updateStatus)
            }
        } else if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            addQuery[kSecAttrLabel as String] = "AuraSense Proximity Unlock Password"
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        } else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Reads the stored macOS password from the Keychain, or returns nil if none is saved.
    public func retrievePassword() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let password = String(data: data, encoding: .utf8) else {
            return nil
        }
        return password
    }

    /// Returns true if a non-empty password is currently stored in the Keychain.
    public func hasStoredPassword() -> Bool {
        guard let pw = retrievePassword() else { return false }
        return !pw.isEmpty
    }

    /// Removes the stored password from the Keychain.
    public func deletePassword() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
