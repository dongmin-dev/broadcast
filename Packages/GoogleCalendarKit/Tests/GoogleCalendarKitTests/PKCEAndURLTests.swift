import Foundation
import Testing
@testable import GoogleCalendarKit

@Suite("PKCE")
struct PKCETests {
    @Test("S256 challenge matches the RFC 7636 Appendix B vector")
    func rfcVector() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(pkce.method == "S256")
    }

    @Test("Generated verifiers are 43–128 unreserved characters and unique")
    func generated() {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let verifiers = (0..<50).map { _ in PKCE.generate() }
        for pkce in verifiers {
            #expect((43...128).contains(pkce.verifier.count))
            #expect(pkce.verifier.allSatisfy(allowed.contains))
            #expect(!pkce.challenge.contains("="))
            #expect(pkce.challenge.count == 43)
            #expect(PKCE(verifier: pkce.verifier).challenge == pkce.challenge)
        }
        #expect(Set(verifiers.map(\.verifier)).count == verifiers.count)
    }

    @Test("State values are random and URL-safe")
    func state() {
        let a = makeOAuthState(), b = makeOAuthState()
        #expect(a != b)
        #expect(a.count >= 43)
        #expect(a.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }
}

@Suite("Authorization URL")
struct AuthorizationURLTests {
    let redirect = URL(string: "http://127.0.0.1:53682/oauth2redirect")!

    @Test("Contains every required parameter")
    func parameters() throws {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let request = AuthorizationRequest(configuration: testConfiguration, redirectURI: redirect, pkce: pkce, state: "xyz")
        let url = request.url
        #expect(url.scheme == "https")
        #expect(url.host == "accounts.google.com")
        #expect(url.path == "/o/oauth2/v2/auth")
        let query = queryItems(url)
        #expect(query["client_id"] == "test-client.apps.googleusercontent.com")
        #expect(query["redirect_uri"] == "http://127.0.0.1:53682/oauth2redirect")
        #expect(query["response_type"] == "code")
        #expect(query["scope"] == "https://www.googleapis.com/auth/calendar.events.readonly https://www.googleapis.com/auth/calendar.calendarlist.readonly")
        #expect(query["code_challenge"] == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["state"] == "xyz")
        #expect(query["access_type"] == "offline")
        #expect(query["prompt"] == "consent")
        #expect(query["login_hint"] == nil)
        // The client secret never goes into the browser URL.
        #expect(!url.absoluteString.contains("test-secret"))
        #expect(query["client_secret"] == nil)
    }

    @Test("Spaces, colons and slashes are percent-encoded")
    func encoding() {
        let request = AuthorizationRequest(configuration: testConfiguration, redirectURI: redirect)
        let query = request.url.query(percentEncoded: true) ?? ""
        #expect(query.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A53682%2Foauth2redirect"))
        #expect(query.contains("calendar.events.readonly%20https%3A%2F%2F"))
    }

    @Test("Includes login_hint when configured")
    func loginHint() {
        var configuration = testConfiguration
        configuration.loginHint = "someone+test@example.com"
        let request = AuthorizationRequest(configuration: configuration, redirectURI: redirect)
        #expect(queryItems(request.url)["login_hint"] == "someone+test@example.com")
    }

    @Test("Redirect URI is a loopback URL with the bound port")
    func redirectURI() throws {
        #expect(try testConfiguration.redirectURI(port: 61000).absoluteString == "http://127.0.0.1:61000/oauth2redirect")
        let custom = GoogleAuthConfiguration(clientID: "id", redirectPath: "callback")
        #expect(try custom.redirectURI(port: 1).absoluteString == "http://127.0.0.1:1/callback")
        let ipv6 = GoogleAuthConfiguration(clientID: "id", redirectHost: "::1")
        #expect(try ipv6.redirectURI(port: 5000).absoluteString == "http://[::1]:5000/oauth2redirect")
        let bad = GoogleAuthConfiguration(clientID: "id", redirectHost: "bad host/")
        #expect(throws: GoogleCalendarError.self) { try bad.redirectURI(port: 5000) }
    }

    @Test("Redirect parsing validates state and surfaces errors")
    func redirectParsing() throws {
        let request = AuthorizationRequest(configuration: testConfiguration, redirectURI: redirect, state: "s1")
        #expect(try request.authorizationCode(from: URL(string: "\(redirect)?state=s1&code=4%2F0abc")!) == "4/0abc")
        #expect(throws: GoogleCalendarError.stateMismatch) {
            try request.authorizationCode(from: URL(string: "\(redirect)?state=other&code=c")!)
        }
        #expect(throws: GoogleCalendarError.authorizationFailed(error: "access_denied", description: nil)) {
            try request.authorizationCode(from: URL(string: "\(redirect)?state=s1&error=access_denied")!)
        }
        #expect(throws: GoogleCalendarError.missingAuthorizationCode) {
            try request.authorizationCode(from: URL(string: "\(redirect)?state=s1")!)
        }
    }

    @Test("Configuration from Info.plist ignores unexpanded build settings")
    func plistValues() {
        #expect(GoogleAuthConfiguration.resolvedValue("$(GOOGLE_CLIENT_ID)") == nil)
        #expect(GoogleAuthConfiguration.resolvedValue("  ") == nil)
        #expect(GoogleAuthConfiguration.resolvedValue(nil) == nil)
        #expect(GoogleAuthConfiguration.resolvedValue(" abc.apps.googleusercontent.com ") == "abc.apps.googleusercontent.com")
    }
}
