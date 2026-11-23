import Foundation
import Security
import Synchronization

/// Secure key-value storage for OAuth credentials. The production implementation is
/// ``KeychainCredentialStore``; tests use ``InMemoryCredentialStore``.
public protocol CredentialStore: Sendable {
    func data(forKey key: String) throws -> Data?
    func setData(_ data: Data, forKey key: String) throws
    func removeData(forKey key: String) throws
}

/// Stores items as generic passwords in the Keychain.
///
/// It prefers the data protection keychain. When the process lacks the entitlement for it
/// (e.g. an ad-hoc signed debug build, `errSecMissingEntitlement`), it falls back to the
/// login keychain.
public struct KeychainCredentialStore: CredentialStore {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    private func baseQuery(key: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    /// Runs `body` against the data protection keychain, falling back to the file keychain.
    private func withKeychain<T>(_ body: (_ dataProtection: Bool) throws -> T) throws -> T {
        do {
            return try body(true)
        } catch GoogleCalendarError.keychain(errSecMissingEntitlement) {
            return try body(false)
        }
    }

    public func data(forKey key: String) throws -> Data? {
        try withKeychain { dataProtection in
            var query = baseQuery(key: key, dataProtection: dataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            switch status {
            case errSecSuccess: return result as? Data
            case errSecItemNotFound: return nil
            default: throw GoogleCalendarError.keychain(status)
            }
        }
    }

    public func setData(_ data: Data, forKey key: String) throws {
        try withKeychain { dataProtection in
            let query = baseQuery(key: key, dataProtection: dataProtection)
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var addQuery = query
                addQuery.merge(attributes) { _, new in new }
                addQuery[kSecAttrLabel as String] = "\(service) (\(key))"
                status = SecItemAdd(addQuery as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw GoogleCalendarError.keychain(status) }
        }
    }

    public func removeData(forKey key: String) throws {
        try withKeychain { dataProtection in
            let status = SecItemDelete(baseQuery(key: key, dataProtection: dataProtection) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw GoogleCalendarError.keychain(status)
            }
        }
    }
}

/// A non-persistent store for tests and SwiftUI previews.
public final class InMemoryCredentialStore: CredentialStore {
    private let storage: Mutex<[String: Data]>

    public init(_ initial: [String: Data] = [:]) {
        storage = Mutex(initial)
    }

    public func data(forKey key: String) throws -> Data? {
        storage.withLock { $0[key] }
    }

    public func setData(_ data: Data, forKey key: String) throws {
        storage.withLock { $0[key] = data }
    }

    public func removeData(forKey key: String) throws {
        storage.withLock { $0[key] = nil }
    }
}

/// What the package persists for a signed-in account.
struct StoredCredential: Codable, Sendable, Equatable {
    static let storageKey = "google-oauth-credential"

    var accessToken: String
    var accessTokenExpiry: Date
    var refreshToken: String
    var grantedScopes: [String]
    var email: String?

    func isAccessTokenValid(at now: Date, leeway: TimeInterval = 60) -> Bool {
        accessTokenExpiry.timeIntervalSince(now) > leeway
    }
}

extension CredentialStore {
    func loadCredential() throws -> StoredCredential? {
        guard let data = try data(forKey: StoredCredential.storageKey) else { return nil }
        return try JSONDecoder().decode(StoredCredential.self, from: data)
    }

    func saveCredential(_ credential: StoredCredential) throws {
        try setData(JSONEncoder().encode(credential), forKey: StoredCredential.storageKey)
    }

    func removeCredential() throws {
        try removeData(forKey: StoredCredential.storageKey)
    }
}
