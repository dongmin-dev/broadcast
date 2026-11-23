import Foundation
import Security
import Synchronization
import Testing
@testable import GoogleCalendarKit

/// An in-memory stand-in for the two macOS keychains.
private final class FakeKeychain: Sendable {
    /// Simulates a process without the data protection keychain entitlement: writes there
    /// fail with errSecMissingEntitlement, while lookups only report "not found".
    let hasDataProtectionEntitlement: Bool
    private let items = Mutex<[String: Data]>([:])

    init(hasDataProtectionEntitlement: Bool) {
        self.hasDataProtectionEntitlement = hasDataProtectionEntitlement
    }

    func contents() -> [String: Data] { items.withLock { $0 } }

    private static func slot(_ query: [String: Any]) -> String {
        let dataProtection = (query[kSecUseDataProtectionKeychain as String] as? Bool) == true
        return "\(dataProtection ? "dp" : "file"):\(query[kSecAttrService as String] as! String):\(query[kSecAttrAccount as String] as! String)"
    }

    private func isDataProtection(_ query: [String: Any]) -> Bool {
        (query[kSecUseDataProtectionKeychain as String] as? Bool) == true
    }

    var api: KeychainAPI {
        KeychainAPI(
            copyMatching: { query in
                let data = self.items.withLock { $0[Self.slot(query)] }
                return data.map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
            },
            add: { attributes in
                if self.isDataProtection(attributes) && !self.hasDataProtectionEntitlement { return errSecMissingEntitlement }
                self.items.withLock { $0[Self.slot(attributes)] = attributes[kSecValueData as String] as? Data }
                return errSecSuccess
            },
            update: { query, attributes in
                if self.isDataProtection(query) && !self.hasDataProtectionEntitlement { return errSecMissingEntitlement }
                return self.items.withLock { items in
                    guard items[Self.slot(query)] != nil else { return errSecItemNotFound }
                    items[Self.slot(query)] = attributes[kSecValueData as String] as? Data
                    return errSecSuccess
                }
            },
            delete: { query in
                self.items.withLock { $0.removeValue(forKey: Self.slot(query)) } == nil ? errSecItemNotFound : errSecSuccess
            }
        )
    }
}

@Suite("Keychain credential store")
struct KeychainCredentialStoreTests {
    @Test("Without the data protection entitlement, items written to the file keychain are read back")
    func fallbackRoundTrip() throws {
        let keychain = FakeKeychain(hasDataProtectionEntitlement: false)
        let store = KeychainCredentialStore(service: "svc", api: keychain.api)
        try store.setData(Data("one".utf8), forKey: "k")
        #expect(keychain.contents().keys.sorted() == ["file:svc:k"])
        #expect(try store.data(forKey: "k") == Data("one".utf8))
        try store.setData(Data("two".utf8), forKey: "k")
        #expect(try store.data(forKey: "k") == Data("two".utf8))
        try store.removeData(forKey: "k")
        #expect(try store.data(forKey: "k") == nil)
        #expect(keychain.contents().isEmpty)
    }

    @Test("With the entitlement, the data protection keychain is used and a stale file copy removed")
    func dataProtection() throws {
        let keychain = FakeKeychain(hasDataProtectionEntitlement: true)
        let store = KeychainCredentialStore(service: "svc", api: keychain.api)
        // A copy written earlier to the file keychain by a build without the entitlement.
        _ = keychain.api.add([
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "svc",
            kSecAttrAccount as String: "k", kSecValueData as String: Data("old".utf8),
        ])
        #expect(try store.data(forKey: "k") == Data("old".utf8))

        try store.setData(Data("new".utf8), forKey: "k")
        #expect(keychain.contents().keys.sorted() == ["dp:svc:k"])
        #expect(try store.data(forKey: "k") == Data("new".utf8))
        try store.removeData(forKey: "k")
        #expect(keychain.contents().isEmpty)
    }

    @Test("A credential saved by GoogleAuth survives a relaunch without the entitlement")
    @MainActor
    func relaunch() async throws {
        let keychain = FakeKeychain(hasDataProtectionEntitlement: false)
        let transport = StubTransport { request in
            if request.url?.path == "/token" {
                return (200, [:], json(#"{"access_token":"a","expires_in":3600,"refresh_token":"r"}"#))
            }
            return (200, [:], json(#"{"id":"me@example.com"}"#))
        }
        let first = GoogleAuth(configuration: testConfiguration, store: KeychainCredentialStore(service: "svc", api: keychain.api),
                               transport: transport, userAgent: StubUserAgent())
        try await first.signIn()
        let relaunched = GoogleAuth(configuration: testConfiguration, store: KeychainCredentialStore(service: "svc", api: keychain.api),
                                    transport: transport, userAgent: StubUserAgent())
        #expect(relaunched.isSignedIn)
        #expect(relaunched.accountEmail == "me@example.com")
    }
}
