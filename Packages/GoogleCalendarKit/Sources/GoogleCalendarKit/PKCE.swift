import CryptoKit
import Foundation
import Security

/// A PKCE (RFC 7636) code verifier and its S256 challenge.
struct PKCE: Sendable, Equatable {
    let verifier: String
    let challenge: String
    let method = "S256"

    init(verifier: String) {
        self.verifier = verifier
        self.challenge = Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// A fresh verifier made from 64 random bytes (86 characters, within 43...128).
    static func generate() -> PKCE {
        PKCE(verifier: Base64URL.encode(randomBytes(count: 64)))
    }
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Cryptographically random bytes from the system CSPRNG.
func randomBytes(count: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    if status != errSecSuccess {
        // SystemRandomNumberGenerator is also a CSPRNG on Apple platforms.
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices { bytes[index] = generator.next() }
    }
    return Data(bytes)
}

/// Random, URL-safe `state` value for CSRF protection.
func makeOAuthState() -> String {
    Base64URL.encode(randomBytes(count: 32))
}
