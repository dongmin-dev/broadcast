import Foundation
import Synchronization
import Testing
@testable import GoogleCalendarKit

private let tokenJSON = json("""
{"access_token":"ya29.first","expires_in":3599,"refresh_token":"1//refresh-1",
 "scope":"https://www.googleapis.com/auth/calendar.calendarlist.readonly https://www.googleapis.com/auth/calendar.events.readonly",
 "token_type":"Bearer"}
""")

/// Answers the token endpoint, the primary-calendar lookup and the revocation endpoint.
private func googleStub(
    token: @escaping @Sendable (_ form: [String: String]) -> (Int, Data) = { _ in (200, tokenJSON) },
    revokeStatus: Int = 200
) -> StubTransport {
    StubTransport { request in
        switch (request.url?.host, request.url?.path) {
        case ("oauth2.googleapis.com", "/token"):
            let (status, body) = token(formBody(request))
            return (status, ["Content-Type": "application/json"], body)
        case ("oauth2.googleapis.com", "/revoke"):
            return (revokeStatus, [:], Data())
        case ("www.googleapis.com", "/calendar/v3/users/me/calendarList/primary"):
            return (200, [:], json(#"{"id":"me@example.com","summary":"me@example.com","primary":true}"#))
        default:
            return (404, [:], Data())
        }
    }
}

private func signedInCredential(expiry: Date, refreshToken: String = "1//stored", email: String? = "me@example.com") -> StoredCredential {
    StoredCredential(accessToken: "ya29.stored", accessTokenExpiry: expiry, refreshToken: refreshToken,
                     grantedScopes: GoogleAuthConfiguration.defaultScopes, email: email)
}

@MainActor
@Suite("GoogleAuth")
struct GoogleAuthTests {
    @Test("Sign-in exchanges the code with PKCE and stores tokens")
    func signIn() async throws {
        let transport = googleStub()
        let store = InMemoryCredentialStore()
        let agent = StubUserAgent()
        let clock = TestClock()
        let auth = GoogleAuth(configuration: testConfiguration, store: store, transport: transport, userAgent: agent, now: { clock.now })
        #expect(!auth.isSignedIn)

        try await auth.signIn()

        #expect(auth.isSignedIn)
        #expect(auth.accountEmail == "me@example.com")
        #expect(!auth.isSigningIn)

        let tokenRequest = try #require(transport.requests(to: "oauth2.googleapis.com", path: "/token").first)
        #expect(tokenRequest.httpMethod == "POST")
        #expect(tokenRequest.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let form = formBody(tokenRequest)
        #expect(form["grant_type"] == "authorization_code")
        #expect(form["code"] == "auth-code-123")
        #expect(form["client_id"] == "test-client.apps.googleusercontent.com")
        #expect(form["client_secret"] == "test-secret")
        #expect(form["redirect_uri"] == "http://127.0.0.1:49152/oauth2redirect")
        // The verifier sent to the token endpoint matches the challenge sent to the browser.
        let authURL = try #require(agent.capturedURL.withLock { $0 })
        let verifier = try #require(form["code_verifier"])
        #expect(PKCE(verifier: verifier).challenge == queryItems(authURL)["code_challenge"])

        let stored = try #require(try store.loadCredential())
        #expect(stored.accessToken == "ya29.first")
        #expect(stored.refreshToken == "1//refresh-1")
        #expect(stored.email == "me@example.com")
        #expect(stored.accessTokenExpiry == clock.now.addingTimeInterval(3599))
        #expect(try await auth.accessToken(forceRefresh: false) == "ya29.first")
    }

    @Test("Omits client_secret when the configuration has none")
    func noSecret() async throws {
        let transport = googleStub()
        let auth = GoogleAuth(configuration: GoogleAuthConfiguration(clientID: "id"), store: InMemoryCredentialStore(),
                              transport: transport, userAgent: StubUserAgent())
        try await auth.signIn()
        let form = formBody(try #require(transport.requests(to: "oauth2.googleapis.com", path: "/token").first))
        #expect(form["client_secret"] == nil)
    }

    @Test("A redirect with the wrong state is rejected without exchanging the code")
    func stateMismatch() async throws {
        let transport = googleStub()
        let auth = GoogleAuth(configuration: testConfiguration, store: InMemoryCredentialStore(), transport: transport,
                              userAgent: StubUserAgent(overrideState: "forged"))
        await #expect(throws: GoogleCalendarError.stateMismatch) { try await auth.signIn() }
        #expect(transport.requests.isEmpty)
        #expect(!auth.isSignedIn)
    }

    @Test("User declining consent surfaces access_denied")
    func accessDenied() async throws {
        let auth = GoogleAuth(configuration: testConfiguration, store: InMemoryCredentialStore(), transport: googleStub(),
                              userAgent: StubUserAgent(code: nil, error: "access_denied"))
        await #expect(throws: GoogleCalendarError.authorizationFailed(error: "access_denied", description: nil)) {
            try await auth.signIn()
        }
    }

    @Test("Cancelling the browser step maps to signInCancelled")
    func cancelled() async throws {
        let auth = GoogleAuth(configuration: testConfiguration, store: InMemoryCredentialStore(), transport: googleStub(),
                              userAgent: CancellingUserAgent())
        await #expect(throws: GoogleCalendarError.signInCancelled) { try await auth.signIn() }
        #expect(!auth.isSigningIn)
    }

    @Test("Unchecked scopes on the consent screen are reported and the grant revoked")
    func missingScopes() async throws {
        let transport = googleStub(token: { _ in
            (200, json(#"{"access_token":"a","expires_in":3600,"refresh_token":"r","scope":"https://www.googleapis.com/auth/calendar.calendarlist.readonly"}"#))
        })
        let store = InMemoryCredentialStore()
        let auth = GoogleAuth(configuration: testConfiguration, store: store, transport: transport, userAgent: StubUserAgent())
        await #expect(throws: GoogleCalendarError.missingScopes([GoogleAuthConfiguration.eventsReadOnlyScope])) {
            try await auth.signIn()
        }
        #expect(!auth.isSignedIn)
        #expect(try store.loadCredential() == nil)
        #expect(formBody(try #require(transport.requests(to: "oauth2.googleapis.com", path: "/revoke").first))["token"] == "r")
    }

    @Test("Token endpoint errors are typed")
    func tokenErrors() async throws {
        let transport = googleStub(token: { _ in (400, json(#"{"error":"invalid_client","error_description":"The OAuth client was not found."}"#)) })
        let auth = GoogleAuth(configuration: testConfiguration, store: InMemoryCredentialStore(), transport: transport, userAgent: StubUserAgent())
        await #expect(throws: GoogleCalendarError.oauth(error: "invalid_client", description: "The OAuth client was not found.")) {
            try await auth.signIn()
        }
    }

    @Test("Restores a stored session at init")
    func restoresSession() throws {
        let store = InMemoryCredentialStore()
        try store.saveCredential(signedInCredential(expiry: .distantFuture))
        let auth = GoogleAuth(configuration: testConfiguration, store: store, transport: googleStub(), userAgent: StubUserAgent())
        #expect(auth.isSignedIn)
        #expect(auth.accountEmail == "me@example.com")
    }

    @Test("Valid access tokens are returned without a network call")
    func validTokenNoRefresh() async throws {
        let clock = TestClock()
        let store = InMemoryCredentialStore()
        try store.saveCredential(signedInCredential(expiry: clock.now.addingTimeInterval(600)))
        let transport = googleStub()
        let auth = GoogleAuth(configuration: testConfiguration, store: store, transport: transport, userAgent: StubUserAgent(), now: { clock.now })
        #expect(try await auth.accessToken(forceRefresh: false) == "ya29.stored")
        #expect(transport.requests.isEmpty)
    }

    @Test("Expired access tokens are refreshed and the refresh token kept")
    func refresh() async throws {
        let clock = TestClock()
        let store = InMemoryCredentialStore()
        try store.saveCredential(signedInCredential(expiry: clock.now.addingTimeInterval(30)))
        let transport = googleStub(token: { _ in (200, json(#"{"access_token":"ya29.refreshed","expires_in":3600,"token_type":"Bearer"}"#)) })
        let auth = GoogleAuth(configuration: testConfiguration, store: store, transport: transport, userAgent: StubUserAgent(), now: { clock.now })

        #expect(try await auth.accessToken(forceRefresh: false) == "ya29.refreshed")

        let form = formBody(try #require(transport.requests(to: "oauth2.googleapis.com", path: "/token").first))
        #expect(form["grant_type"] == "refresh_token")
        #expect(form["refresh_token"] == "1//stored")
        #expect(form["client_id"] == "test-client.apps.googleusercontent.com")
        #expect(form["client_secret"] == "test-secret")
        let stored = try #require(try store.loadCredential())
        #expect(stored.accessToken == "ya29.refreshed")
        #expect(stored.refreshToken == "1//stored")
        #expect(stored.accessTokenExpiry == clock.now.addingTimeInterval(3600))
    }

    @Test("A rotated refresh token replaces the stored one")
    func rotatedRefreshToken() async throws {
        let store = InMemoryCredentialStore()
        try store.saveCredential(signedInCredential(expiry: .distantPast))
        let transport = googleStub(token: { _ in (200, json(#"{"access_token":"a2","expires_in":3600,"refresh_token":"1//rotated"}"#)) })
        let auth = GoogleAuth(configuration: testConfiguration, store: store, transport: transport, userAgent: StubUserAgent())
        _ = try await auth.accessToken(forceRefresh: false)
        #expect(try store.loadCredential()?.refreshToken == "1//rotated")
    }

    @Test("forceRefresh refreshes even when the token looks valid")
    func forceRefresh() async throws {
        let store = InMemoryCredentialStore()
        try store.saveCredential(signedInCredential(expiry: .distantFuture))
        let transport = googleStub(token: { _ in (200, json(#"{"access_token":"forced","expires_in":3600}"#)) })
        let auth = GoogleAuth(configuration: testConfiguration, store: store, transport: transport, userAgent: StubUserAgent())
        #expect(try await auth.accessToken(forceRefresh: true) == "forced")
    }

    @Test("Concurrent callers share one refresh request")
    func coalescedRefresh() async throws {
        let store = InMemoryCredentialStore()
        try store.saveCredential(signedInCredential(expiry: .distantPast))
        let transport = StubTransport { request in
            try await Task.sleep(for: .milliseconds(50))
            return (200, [:], json(#"{"access_token":"shared","expires_in":3600}"#))
        }
        let auth = GoogleAuth(configuration: testConfiguration, store: store, transport: transport, userAgent: StubUserAgent())
        async let a = auth.accessToken(forceRefresh: false)
        async let b = auth.accessToken(forceRefresh: false)
        async let c = auth.accessToken(forceRefresh: false)
        let tokens = try await [a, b, c]
        #expect(tokens == ["shared", "shared", "shared"])
        #expect(transport.requests(to: "oauth2.googleapis.com", path: "/token").count == 1)
    }

    @Test("invalid_grant clears the session and asks for re-authentication")
    func invalidGrant() async throws {
        let store = InMemoryCredentialStore()
        try store.saveCredential(signedInCredential(expiry: .distantPast))
        let transport = googleStub(token: { _ in (400, json(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#)) })
        let auth = GoogleAuth(configuration: testConfiguration, store: store, transport: transport, userAgent: StubUserAgent())
        await #expect(throws: GoogleCalendarError.reauthenticationRequired) { try await auth.accessToken(forceRefresh: false) }
        #expect(!auth.isSignedIn)
        #expect(auth.accountEmail == nil)
        #expect(try store.loadCredential() == nil)
        await #expect(throws: GoogleCalendarError.notSignedIn) { try await auth.accessToken(forceRefresh: false) }
    }

    @Test("Refresh while offline throws offline and keeps the session")
    func refreshOffline() async throws {
        let store = InMemoryCredentialStore()
        try store.saveCredential(signedInCredential(expiry: .distantPast))
        let transport = StubTransport { _ in throw URLError(.notConnectedToInternet) }
        let auth = GoogleAuth(configuration: testConfiguration, store: store, transport: transport, userAgent: StubUserAgent())
        await #expect(throws: GoogleCalendarError.offline) { try await auth.accessToken(forceRefresh: false) }
        #expect(auth.isSignedIn)
        #expect(try store.loadCredential() != nil)
    }

    @Test("Sign-out revokes the refresh token and deletes it")
    func signOut() async throws {
        let store = InMemoryCredentialStore()
        try store.saveCredential(signedInCredential(expiry: .distantFuture))
        let transport = googleStub()
        let auth = GoogleAuth(configuration: testConfiguration, store: store, transport: transport, userAgent: StubUserAgent())
        try await auth.signOut()
        #expect(!auth.isSignedIn)
        #expect(auth.accountEmail == nil)
        #expect(try store.loadCredential() == nil)
        let revoke = try #require(transport.requests(to: "oauth2.googleapis.com", path: "/revoke").first)
        #expect(revoke.httpMethod == "POST")
        #expect(formBody(revoke)["token"] == "1//stored")
        await #expect(throws: GoogleCalendarError.notSignedIn) { try await auth.accessToken(forceRefresh: false) }
    }

    @Test("Sign-out still deletes local tokens when revocation fails offline")
    func signOutOffline() async throws {
        let store = InMemoryCredentialStore()
        try store.saveCredential(signedInCredential(expiry: .distantFuture))
        let transport = StubTransport { _ in throw URLError(.notConnectedToInternet) }
        let auth = GoogleAuth(configuration: testConfiguration, store: store, transport: transport, userAgent: StubUserAgent())
        try await auth.signOut()
        #expect(!auth.isSignedIn)
        #expect(try store.loadCredential() == nil)
    }

    @Test("Signing in again replaces and revokes the previous account")
    func reSignIn() async throws {
        let store = InMemoryCredentialStore()
        try store.saveCredential(signedInCredential(expiry: .distantFuture, refreshToken: "1//old", email: "old@example.com"))
        let transport = googleStub()
        let auth = GoogleAuth(configuration: testConfiguration, store: store, transport: transport, userAgent: StubUserAgent())
        try await auth.signIn()
        #expect(auth.accountEmail == "me@example.com")
        #expect(try store.loadCredential()?.refreshToken == "1//refresh-1")
        #expect(transport.requests(to: "oauth2.googleapis.com", path: "/revoke").map { formBody($0)["token"] } == ["1//old"])
    }
}
