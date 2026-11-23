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
    private let api: KeychainAPI

    public init(service: String) {
        self.init(service: service, api: .system)
    }

    init(service: String, api: KeychainAPI) {
        self.service = service
        self.api = api
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

    /// Runs `body` against the data protection keychain, falling back to the file keychain
    /// when the process lacks the entitlement for it.
    private func withKeychain<T>(_ body: (_ dataProtection: Bool) throws -> T) throws -> T {
        do {
            return try body(true)
        } catch GoogleCalendarError.keychain(errSecMissingEntitlement) {
            return try body(false)
        }
    }

    private func read(key: String, dataProtection: Bool) throws -> Data? {
        var query = baseQuery(key: key, dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = api.copyMatching(query)
        switch status {
        case errSecSuccess: return result
        case errSecItemNotFound: return nil
        default: throw GoogleCalendarError.keychain(status)
        }
    }

    public func data(forKey key: String) throws -> Data? {
        // Without the entitlement, a data protection lookup can report "not found" (rather
        // than errSecMissingEntitlement) while writes fell back to the file keychain, so a
        // miss there is not final: always look in the file keychain too.
        let protected: Data?
        do {
            protected = try read(key: key, dataProtection: true)
        } catch GoogleCalendarError.keychain(errSecMissingEntitlement) {
            protected = nil
        }
        if let protected { return protected }
        return try read(key: key, dataProtection: false)
    }

    public func setData(_ data: Data, forKey key: String) throws {
        let wroteToDataProtection = try withKeychain { dataProtection in
            let query = baseQuery(key: key, dataProtection: dataProtection)
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            var status = api.update(query, attributes)
            if status == errSecItemNotFound {
                var addQuery = query
                addQuery.merge(attributes) { _, new in new }
                addQuery[kSecAttrLabel as String] = "\(service) (\(key))"
                status = api.add(addQuery)
            }
            guard status == errSecSuccess else { throw GoogleCalendarError.keychain(status) }
            return dataProtection
        }
        // Don't leave an older copy in the file keychain that a later read could return.
        if wroteToDataProtection { try? delete(key: key, dataProtection: false) }
    }

    private func delete(key: String, dataProtection: Bool) throws {
        let status = api.delete(baseQuery(key: key, dataProtection: dataProtection))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GoogleCalendarError.keychain(status)
        }
    }

    /// Deletes the item from both keychains.
    public func removeData(forKey key: String) throws {
        do {
            try delete(key: key, dataProtection: true)
        } catch GoogleCalendarError.keychain(errSecMissingEntitlement) {
            // Nothing can be stored there either.
        }
        try delete(key: key, dataProtection: false)
    }
}

/// The Security framework calls the Keychain store makes; replaceable in tests.
struct KeychainAPI: Sendable {
    var copyMatching: @Sendable (_ query: [String: Any]) -> (OSStatus, Data?)
    var add: @Sendable (_ attributes: [String: Any]) -> OSStatus
    var update: @Sendable (_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus
    var delete: @Sendable (_ query: [String: Any]) -> OSStatus

    static let system = KeychainAPI(
        copyMatching: { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
        },
        add: { SecItemAdd($0 as CFDictionary, nil) },
        update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
        delete: { SecItemDelete($0 as CFDictionary) }
    )
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
