import Foundation
import Security
import LocalAuthentication

/// Manages secure storage and retrieval of the macOS login password in the system Keychain.
/// Used exclusively by MacLockUnlockController when typing credentials via Accessibility events.
public final class KeychainManager: @unchecked Sendable {
    public static let shared = KeychainManager()

    /// Posted on `NotificationCenter.default` (main thread) after the stored password is saved or deleted.
    public static let passwordDidChangeNotification = Notification.Name("com.aurasense.keychainPasswordDidChange")

    private let serviceName = "com.aurasense.mac.unlock-credentials"
    private let accountName = "macOSLoginPassword"

    /// Cached result of the attribute-only existence query; invalidated on save/delete.
    private let cacheLock = NSLock()
    private var cachedHasStoredPassword: Bool?

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
        passwordDidChange(nowStored: true)
    }

    /// Reads the stored macOS password from the Keychain, or returns nil if none is saved.
    /// Pass `allowUserInteraction: false` from automated paths (proximity unlock, bridge, BLE) so a
    /// Keychain ACL prompt can never block the caller while the screen is locked; the read fails fast instead.
    public func retrievePassword(allowUserInteraction: Bool = true) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if !allowUserInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let password = String(data: data, encoding: .utf8) else {
            return nil
        }
        return password
    }

    /// Returns true if a password item is currently stored in the Keychain.
    /// Attribute-only query: never decrypts the secret, so it cannot raise a Keychain ACL prompt.
    /// The result is cached until the next save/delete, so it is cheap to call from view bodies.
    public func hasStoredPassword() -> Bool {
        cacheLock.lock()
        if let cached = cachedHasStoredPassword {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        let exists = status == errSecSuccess

        // Only cache definitive answers; transient errors (e.g. keychain locked) are re-queried.
        if status == errSecSuccess || status == errSecItemNotFound {
            cacheLock.lock()
            cachedHasStoredPassword = exists
            cacheLock.unlock()
        }
        return exists
    }

    private func passwordDidChange(nowStored: Bool) {
        cacheLock.lock()
        cachedHasStoredPassword = nowStored
        cacheLock.unlock()

        let post = {
            NotificationCenter.default.post(name: KeychainManager.passwordDidChangeNotification, object: nil)
        }
        if Thread.isMainThread {
            post()
        } else {
            DispatchQueue.main.async(execute: post)
        }
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
        passwordDidChange(nowStored: false)
    }
}
